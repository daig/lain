// glconv: BGRx -> NV12 (BT.709 full range) in one OpenGL compute pass, on the AMD iGPU only.
//
// Input: a ring of GBM BOs (XRGB8888 = BGRx in memory, Mutter's modifier 0x200000000401b03), imported as
// EGLImages. Output: NV12 VA surfaces created for the HEVC encoder, exported (DRM PRIME 2, separate layers)
// and imported as R8 / GR88 EGLImages written with imageStore. Every frame ends with a GL fence (or an
// exported sync file) that is waited on before the surface would go to the encoder.
//
// Usage: glconv [--wg 16x8] [--input texel|image|u32] [--frames 600] [--ring 8] [--pace 120]
//               [--sync gl|fd] [--verify 3] [--size WxH] [--sweep] [--info]
// --sweep runs 15 cases (about 75 s at the defaults): pass --frames 120 or run cases one by one.
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/glcorearb.h>
#include <drm_fourcc.h>
#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <math.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>

#define DEVICE "/dev/dri/by-path/pci-0000:79:00.0-render"
#define MUTTER_MOD 0x0200000000401b03ULL
#define MAXRING 32
#define NOUT 3

#define DIE(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); exit(1); } while (0)
#define VACHECK(x) do { VAStatus s_ = (x); if (s_ != VA_STATUS_SUCCESS) DIE("%s: %s", #x, vaErrorStr(s_)); } while (0)

// ---- GL entry points, all through eglGetProcAddress (EGL 1.5 returns core functions too) ----
#define GLFUNCS(X) \
    X(PFNGLGETSTRINGPROC, glGetString) X(PFNGLGETSTRINGIPROC, glGetStringi) X(PFNGLGETINTEGERVPROC, glGetIntegerv) \
    X(PFNGLGETERRORPROC, glGetError) X(PFNGLGENTEXTURESPROC, glGenTextures) X(PFNGLBINDTEXTUREPROC, glBindTexture) \
    X(PFNGLTEXPARAMETERIPROC, glTexParameteri) X(PFNGLTEXSTORAGE2DPROC, glTexStorage2D) \
    X(PFNGLTEXSUBIMAGE2DPROC, glTexSubImage2D) X(PFNGLCOPYIMAGESUBDATAPROC, glCopyImageSubData) \
    X(PFNGLCREATESHADERPROC, glCreateShader) X(PFNGLSHADERSOURCEPROC, glShaderSource) \
    X(PFNGLCOMPILESHADERPROC, glCompileShader) X(PFNGLGETSHADERIVPROC, glGetShaderiv) \
    X(PFNGLGETSHADERINFOLOGPROC, glGetShaderInfoLog) X(PFNGLCREATEPROGRAMPROC, glCreateProgram) \
    X(PFNGLATTACHSHADERPROC, glAttachShader) X(PFNGLLINKPROGRAMPROC, glLinkProgram) \
    X(PFNGLGETPROGRAMIVPROC, glGetProgramiv) X(PFNGLGETPROGRAMINFOLOGPROC, glGetProgramInfoLog) \
    X(PFNGLUSEPROGRAMPROC, glUseProgram) X(PFNGLDELETEPROGRAMPROC, glDeleteProgram) \
    X(PFNGLDELETESHADERPROC, glDeleteShader) X(PFNGLUNIFORM2IPROC, glUniform2i) \
    X(PFNGLBINDIMAGETEXTUREPROC, glBindImageTexture) X(PFNGLACTIVETEXTUREPROC, glActiveTexture) \
    X(PFNGLDISPATCHCOMPUTEPROC, glDispatchCompute) X(PFNGLMEMORYBARRIERPROC, glMemoryBarrier) \
    X(PFNGLFENCESYNCPROC, glFenceSync) X(PFNGLCLIENTWAITSYNCPROC, glClientWaitSync) \
    X(PFNGLDELETESYNCPROC, glDeleteSync) X(PFNGLFLUSHPROC, glFlush) X(PFNGLFINISHPROC, glFinish) \
    X(PFNGLGENQUERIESPROC, glGenQueries) X(PFNGLQUERYCOUNTERPROC, glQueryCounter) \
    X(PFNGLGETQUERYOBJECTUI64VPROC, glGetQueryObjectui64v) X(PFNGLGETTEXLEVELPARAMETERIVPROC, glGetTexLevelParameteriv) \
    X(PFNGLGENFRAMEBUFFERSPROC, glGenFramebuffers) X(PFNGLBINDFRAMEBUFFERPROC, glBindFramebuffer) \
    X(PFNGLFRAMEBUFFERTEXTURE2DPROC, glFramebufferTexture2D) X(PFNGLBLITFRAMEBUFFERPROC, glBlitFramebuffer) \
    X(PFNGLCHECKFRAMEBUFFERSTATUSPROC, glCheckFramebufferStatus)
#define DECL(t, n) static t n;
GLFUNCS(DECL)
typedef void (*PFNEGLIMAGETARGETTEXSTORAGE)(GLenum, GLeglImageOES, const GLint *);
typedef void (*PFNEGLIMAGETARGETTEX2D)(GLenum, GLeglImageOES);
static PFNEGLIMAGETARGETTEXSTORAGE glEGLImageTargetTexStorageEXT_;
static PFNEGLIMAGETARGETTEX2D glEGLImageTargetTexture2DOES_;
static PFNEGLDUPNATIVEFENCEFDANDROIDPROC dupFenceFd;

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static void loadavg(const char *when) {
    char b[128] = {0};
    FILE *f = fopen("/proc/loadavg", "r");
    if (f && fgets(b, sizeof b, f)) printf("loadavg %s: %s", when, b);
    if (f) fclose(f);
}
static void gpubusy(const char *when) {
    char b[32] = {0};
    FILE *f = fopen("/sys/class/drm/renderD130/device/gpu_busy_percent", "r");
    if (f && fgets(b, sizeof b, f)) printf("gpu_busy_percent %s: %s", when, b);
    if (f) fclose(f);
}

// ---- content: a scrolling terminal (18 px lines, 9 px cells, five colours on dark purple) ----
static uint32_t hash3(uint32_t a, uint32_t b, uint32_t c) {
    uint32_t h = a * 0x9E3779B1u ^ (b + 0x7F4A7C15u) * 0x85EBCA77u ^ (c + 0x165667B1u) * 0xC2B2AE3Du;
    h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
    return h;
}
static const uint8_t palette[5][3] = {{230, 230, 230}, {120, 220, 120}, {250, 200, 80}, {110, 170, 250}, {240, 110, 140}};
// BGRx, with junk in x (Mutter leaves it undefined).
static void gen_frame(uint8_t *dst, int w, int h, int frame) {
    int scroll = frame * 18;
    for (int y = 0; y < h; y++) {
        int yy = y + scroll, line = yy / 18, r = yy % 18;
        uint8_t *row = dst + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            int col = x / 9, cx = x % 9;
            uint8_t R = 40, G = 16, B = 58;
            uint32_t ch = hash3(line, col, 1);
            int len = 20 + hash3(line, 0, 7) % 280;
            if (col < len && (ch & 7) != 0 && r >= 2 && r < 16 && cx >= 1 && cx < 8) {
                uint32_t g = hash3(line * 31 + col, r, cx);
                if (g & 3) {
                    const uint8_t *p = palette[hash3(line, col / 12, 3) % 5];
                    float a = (g & 0x30) == 0 ? 0.45f : 1.0f; // antialiased edges
                    R = (uint8_t)(R + a * (p[0] - R) + 0.5f);
                    G = (uint8_t)(G + a * (p[1] - G) + 0.5f);
                    B = (uint8_t)(B + a * (p[2] - B) + 0.5f);
                }
            }
            row[4 * x] = B; row[4 * x + 1] = G; row[4 * x + 2] = R; row[4 * x + 3] = (uint8_t)(x * 7 + y);
        }
    }
}

// ---- CPU reference ----
static uint8_t q8(double v) { v = floor(v + 0.5); return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }
static void ref_nv12(const uint8_t *bgrx, int w, int h, uint8_t *Y, uint8_t *UV) {
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            const uint8_t *p = bgrx + ((size_t)y * w + x) * 4;
            Y[(size_t)y * w + x] = q8(0.2126 * p[2] + 0.7152 * p[1] + 0.0722 * p[0]);
        }
    for (int by = 0; by < h / 2; by++)
        for (int bx = 0; bx < w / 2; bx++) {
            double r = 0, g = 0, b = 0;
            for (int j = 0; j < 2; j++)
                for (int i = 0; i < 2; i++) {
                    const uint8_t *p = bgrx + ((size_t)(2 * by + j) * w + 2 * bx + i) * 4;
                    r += p[2]; g += p[1]; b += p[0];
                }
            r /= 4; g /= 4; b /= 4;
            double yy = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            UV[((size_t)by * (w / 2) + bx) * 2] = q8((b - yy) / 1.8556 + 128);
            UV[((size_t)by * (w / 2) + bx) * 2 + 1] = q8((r - yy) / 1.5748 + 128);
        }
}

// ---- shader ----
static const char *shader_fmt =
    "#version 430\n"
    "layout(local_size_x = %d, local_size_y = %d) in;\n"
    "#define INPUT %d\n"
    "#if INPUT == 0\n"
    "layout(binding = 0) uniform sampler2D src;\n"
    "vec3 load(ivec2 p) { return texelFetch(src, p, 0).rgb; }\n"
    "#elif INPUT == 1\n"
    "layout(binding = 0, rgba8) readonly uniform image2D src;\n"
    "vec3 load(ivec2 p) { return imageLoad(src, p).rgb; }\n"
    "#else\n"
    "layout(binding = 0, r32ui) readonly uniform uimage2D src;\n"
    "vec3 load(ivec2 p) { return unpackUnorm4x8(imageLoad(src, p).r).bgr; }\n" // word = x<<24|R<<16|G<<8|B
    "#endif\n"
    "layout(binding = 1, r8) writeonly uniform image2D ypl;\n"
    "layout(binding = 2, rg8) writeonly uniform image2D uvpl;\n"
    "layout(location = 0) uniform ivec2 blocks;\n"
    "const vec3 K = vec3(0.2126, 0.7152, 0.0722);\n"
    "void main() {\n"
    "    ivec2 b = ivec2(gl_GlobalInvocationID.xy);\n"
    "    if (b.x >= blocks.x || b.y >= blocks.y) return;\n"
    "    ivec2 p = b * 2;\n"
    "    vec3 c00 = load(p), c10 = load(p + ivec2(1, 0)), c01 = load(p + ivec2(0, 1)), c11 = load(p + ivec2(1, 1));\n"
    "    imageStore(ypl, p, vec4(dot(K, c00)));\n"
    "    imageStore(ypl, p + ivec2(1, 0), vec4(dot(K, c10)));\n"
    "    imageStore(ypl, p + ivec2(0, 1), vec4(dot(K, c01)));\n"
    "    imageStore(ypl, p + ivec2(1, 1), vec4(dot(K, c11)));\n"
    "    vec3 m = (c00 + c10 + c01 + c11) * 0.25;\n"
    "    float ym = dot(K, m);\n"
    "    imageStore(uvpl, b, vec4((m.b - ym) / 1.8556 + 128.0 / 255.0, (m.r - ym) / 1.5748 + 128.0 / 255.0, 0.0, 0.0));\n"
    "}\n";

static GLuint build_program(int wx, int wy, int input) {
    char src[8192];
    snprintf(src, sizeof src, shader_fmt, wx, wy, input);
    const char *s = src;
    GLuint sh = glCreateShader(GL_COMPUTE_SHADER);
    glShaderSource(sh, 1, &s, NULL);
    uint64_t t = now_ns();
    glCompileShader(sh);
    GLint ok;
    char log[4096];
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) { glGetShaderInfoLog(sh, sizeof log, NULL, log); DIE("compile: %s", log); }
    GLuint p = glCreateProgram();
    glAttachShader(p, sh);
    glLinkProgram(p);
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) { glGetProgramInfoLog(p, sizeof log, NULL, log); DIE("link: %s", log); }
    glDeleteShader(sh);
    printf("  shader %dx%d %s compiled+linked in %.1f ms\n", wx, wy, input == 0 ? "texel" : input == 1 ? "image" : "u32",
           (now_ns() - t) / 1e6);
    return p;
}

static int has_ext(const char *list, const char *e) {
    size_t n = strlen(e);
    for (const char *p = list; (p = strstr(p, e)); p += n)
        if ((p == list || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0)) return 1;
    return 0;
}

static EGLDisplay edpy;

static EGLImageKHR import_dmabuf(int w, int h, uint32_t fourcc, int fd, uint32_t offset, uint32_t pitch, uint64_t mod) {
    EGLAttrib a[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_LINUX_DRM_FOURCC_EXT, fourcc,
                     EGL_DMA_BUF_PLANE0_FD_EXT, fd, EGL_DMA_BUF_PLANE0_OFFSET_EXT, offset,
                     EGL_DMA_BUF_PLANE0_PITCH_EXT, pitch,
                     EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, (EGLAttrib)(mod & 0xffffffff),
                     EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, (EGLAttrib)(mod >> 32), EGL_NONE};
    EGLImage img = eglCreateImage(edpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, a);
    if (img == EGL_NO_IMAGE) DIE("eglCreateImage %.4s %dx%d mod 0x%llx: 0x%x", (char *)&fourcc, w, h,
                                 (unsigned long long)mod, eglGetError());
    return img;
}

static GLuint tex_from_image(EGLImageKHR img) {
    GLuint t;
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    if (glEGLImageTargetTexStorageEXT_) glEGLImageTargetTexStorageEXT_(GL_TEXTURE_2D, img, NULL);
    else glEGLImageTargetTexture2DOES_(GL_TEXTURE_2D, img);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    GLenum e = glGetError();
    if (e) DIE("EGLImage -> texture: GL error 0x%x", e);
    return t;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}
static void stats(const char *name, uint64_t *v, int n) {
    qsort(v, n, sizeof *v, cmp_u64);
    double sum = 0;
    for (int i = 0; i < n; i++) sum += v[i];
    printf("    %-22s p50 %.3f  p95 %.3f  p99 %.3f  max %.3f  mean %.3f ms\n", name, v[n / 2] / 1e6,
           v[(int)(n * 0.95)] / 1e6, v[(int)(n * 0.99)] / 1e6, v[n - 1] / 1e6, sum / n / 1e6);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    int W = 2752, H = 2064, wx = 16, wy = 8, input = 0, frames = 600, ring_n = 8, verify = 3, sweep = 0, info = 0;
    double pace = 120;
    int use_fd = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(a, "--wg")) { if (sscanf(v, "%dx%d", &wx, &wy) != 2) DIE("--wg WxH"); i++; }
        else if (!strcmp(a, "--input")) { input = !strcmp(v, "texel") ? 0 : !strcmp(v, "image") ? 1 : !strcmp(v, "u32") ? 2 : -1; if (input < 0) DIE("--input texel|image|u32"); i++; }
        else if (!strcmp(a, "--frames")) { frames = atoi(v); i++; }
        else if (!strcmp(a, "--ring")) { ring_n = atoi(v); i++; }
        else if (!strcmp(a, "--pace")) { pace = atof(v); i++; }
        else if (!strcmp(a, "--verify")) { verify = atoi(v); i++; }
        else if (!strcmp(a, "--size")) { if (sscanf(v, "%dx%d", &W, &H) != 2) DIE("--size WxH"); i++; }
        else if (!strcmp(a, "--sync")) { use_fd = !strcmp(v, "fd"); i++; }
        else if (!strcmp(a, "--sweep")) sweep = 1;
        else if (!strcmp(a, "--info")) info = 1;
        else DIE("unknown option %s", a);
    }
    if (ring_n < 1 || ring_n > MAXRING || (W | H) & 1) DIE("bad ring/size");

    // Never an NVIDIA device: the render node's PCI vendor must be AMD.
    char real[4096];
    if (!realpath(DEVICE, real)) DIE("%s: %s", DEVICE, strerror(errno));
    char path[4200], vendor[16] = {0};
    snprintf(path, sizeof path, "/sys/class/drm/%s/device/vendor", strrchr(real, '/') + 1);
    FILE *vf = fopen(path, "r");
    if (!vf || !fgets(vendor, sizeof vendor, vf) || strncmp(vendor, "0x1002", 6)) DIE("%s is not AMD", real);
    fclose(vf);
    loadavg("before");
    gpubusy("before");

    int fd = open(DEVICE, O_RDWR | O_CLOEXEC);
    if (fd < 0) DIE("open %s: %s", DEVICE, strerror(errno));
    struct gbm_device *gbm = gbm_create_device(fd);
    if (!gbm) DIE("gbm_create_device");
    printf("device %s (%s), gbm backend %s\n", DEVICE, real, gbm_device_get_backend_name(gbm));

    // ---- EGL / GL on the GBM device ----
    edpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    EGLint maj, min;
    if (!eglInitialize(edpy, &maj, &min)) DIE("eglInitialize 0x%x", eglGetError());
    const char *eext = eglQueryString(edpy, EGL_EXTENSIONS);
    printf("EGL %d.%d %s %s\n", maj, min, eglQueryString(edpy, EGL_VENDOR), eglQueryString(edpy, EGL_VERSION));
    const char *need[] = {"EGL_KHR_surfaceless_context", "EGL_KHR_no_config_context", "EGL_EXT_image_dma_buf_import",
                          "EGL_EXT_image_dma_buf_import_modifiers"};
    for (unsigned i = 0; i < 4; i++) if (!has_ext(eext, need[i])) DIE("missing %s", need[i]);
    int have_native_fence = has_ext(eext, "EGL_ANDROID_native_fence_sync");
    if (!eglBindAPI(EGL_OPENGL_API)) DIE("eglBindAPI");
    EGLint cattr[] = {EGL_CONTEXT_MAJOR_VERSION, 4, EGL_CONTEXT_MINOR_VERSION, 6, EGL_CONTEXT_OPENGL_PROFILE_MASK,
                      EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
    EGLContext ctx = eglCreateContext(edpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, cattr);
    if (ctx == EGL_NO_CONTEXT) DIE("eglCreateContext 0x%x", eglGetError());
    if (!eglMakeCurrent(edpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) DIE("eglMakeCurrent");
#define LOAD(t, n) n = (t)eglGetProcAddress(#n); if (!n) DIE("no %s", #n);
    GLFUNCS(LOAD)
    glEGLImageTargetTexStorageEXT_ = (PFNEGLIMAGETARGETTEXSTORAGE)eglGetProcAddress("glEGLImageTargetTexStorageEXT");
    glEGLImageTargetTexture2DOES_ = (PFNEGLIMAGETARGETTEX2D)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    printf("GL %s | %s | %s\n", glGetString(GL_VERSION), glGetString(GL_RENDERER), glGetString(GL_VENDOR));
    GLint next = 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, &next);
    int has_storage = 0, has_oes = 0, has_timer = 0;
    for (int i = 0; i < next; i++) {
        const char *e = (const char *)glGetStringi(GL_EXTENSIONS, i);
        has_storage |= !strcmp(e, "GL_EXT_EGL_image_storage");
        has_oes |= !strcmp(e, "GL_OES_EGL_image");
        has_timer |= !strcmp(e, "GL_ARB_timer_query");
    }
    printf("GL_EXT_EGL_image_storage %d, GL_OES_EGL_image %d, GL_ARB_timer_query %d (core in 3.3), "
           "EGL_ANDROID_native_fence_sync %d\n", has_storage, has_oes, has_timer, have_native_fence);
    if (!has_storage) glEGLImageTargetTexStorageEXT_ = NULL;
    if (!glEGLImageTargetTexStorageEXT_ && !(has_oes && glEGLImageTargetTexture2DOES_)) DIE("no EGLImage -> texture");
    dupFenceFd = (PFNEGLDUPNATIVEFENCEFDANDROIDPROC)eglGetProcAddress("eglDupNativeFenceFDANDROID");
    if (use_fd && (!have_native_fence || !dupFenceFd)) DIE("--sync fd needs EGL_ANDROID_native_fence_sync");

    // ---- VA on the same node: the encoder's config and NV12 input surfaces ----
    int vfd = open(DEVICE, O_RDWR | O_CLOEXEC);
    VADisplay va = vaGetDisplayDRM(vfd);
    int vmaj, vmin;
    VACHECK(vaInitialize(va, &vmaj, &vmin));
    printf("VA %d.%d %s\n", vmaj, vmin, vaQueryVendorString(va));
    VAConfigAttrib cfg_attrs[2] = {{VAConfigAttribRTFormat, VA_RT_FORMAT_YUV420}, {VAConfigAttribRateControl, VA_RC_CBR}};
    VAConfigID cfg;
    VACHECK(vaCreateConfig(va, VAProfileHEVCMain, VAEntrypointEncSlice, cfg_attrs, 2, &cfg));
    VASurfaceAttrib sattr[2] = {
        {.type = VASurfaceAttribPixelFormat, .flags = VA_SURFACE_ATTRIB_SETTABLE,
         .value = {.type = VAGenericValueTypeInteger, .value.i = VA_FOURCC_NV12}},
        {.type = VASurfaceAttribUsageHint, .flags = VA_SURFACE_ATTRIB_SETTABLE,
         .value = {.type = VAGenericValueTypeInteger,
                   .value.i = VA_SURFACE_ATTRIB_USAGE_HINT_ENCODER | VA_SURFACE_ATTRIB_USAGE_HINT_EXPORT}}};
    VASurfaceID out[NOUT];
    VACHECK(vaCreateSurfaces(va, VA_RT_FORMAT_YUV420, W, H, out, NOUT, sattr, 2));
    // The encoder accepts them as input: a context with them as render targets.
    VAContextID vctx;
    VACHECK(vaCreateContext(va, cfg, W, H, VA_PROGRESSIVE, out, NOUT, &vctx));
    GLuint ytex[NOUT], uvtex[NOUT];
    for (int i = 0; i < NOUT; i++) {
        VADRMPRIMESurfaceDescriptor d;
        VACHECK(vaExportSurfaceHandle(va, out[i], VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                      VA_EXPORT_SURFACE_WRITE_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS, &d));
        if (i == 0) {
            printf("VA surface export: %.4s %ux%u, %u objects, %u layers\n", (char *)&d.fourcc, d.width, d.height,
                   d.num_objects, d.num_layers);
            for (unsigned o = 0; o < d.num_objects; o++)
                printf("  object %u: size %u, modifier 0x%016llx\n", o, d.objects[o].size,
                       (unsigned long long)d.objects[o].drm_format_modifier);
            for (unsigned l = 0; l < d.num_layers; l++)
                printf("  layer %u: %.4s, object %u, offset %u, pitch %u\n", l, (char *)&d.layers[l].drm_format,
                       d.layers[l].object_index[0], d.layers[l].offset[0], d.layers[l].pitch[0]);
        }
        // Validate the export before any shader can touch it: two single-plane layers R8 + GR88, each lying
        // wholly inside its object (offset + pitch * rows <= size, pitch >= row bytes), at the size we asked for.
        if (d.fourcc != VA_FOURCC_NV12 || d.width != (uint32_t)W || d.height != (uint32_t)H) DIE("export: not NV12 %dx%d", W, H);
        if (d.num_layers != 2 || d.num_objects < 1 || d.num_objects > 2) DIE("expected two layers, 1-2 objects");
        for (int l = 0; l < 2; l++) {
            uint32_t want = l ? DRM_FORMAT_GR88 : DRM_FORMAT_R8, o = d.layers[l].object_index[0];
            uint64_t rows = l ? H / 2 : H, rowbytes = l ? W : W; // GR88 at W/2 texels = W bytes
            if (d.layers[l].num_planes != 1 || d.layers[l].drm_format != want || o >= d.num_objects)
                DIE("export layer %d: unexpected format/planes/object", l);
            if (d.layers[l].pitch[0] < rowbytes ||
                (uint64_t)d.layers[l].offset[0] + (uint64_t)d.layers[l].pitch[0] * rows > d.objects[o].size)
                DIE("export layer %d: offset %u + pitch %u x %llu rows exceeds object size %u", l, d.layers[l].offset[0],
                    d.layers[l].pitch[0], (unsigned long long)rows, d.objects[o].size);
        }
        for (int l = 0; l < 2; l++) {
            int o = d.layers[l].object_index[0];
            EGLImageKHR img = import_dmabuf(l ? W / 2 : W, l ? H / 2 : H, d.layers[l].drm_format, d.objects[o].fd,
                                            d.layers[l].offset[0], d.layers[l].pitch[0],
                                            d.objects[o].drm_format_modifier);
            (l ? uvtex : ytex)[i] = tex_from_image(img);
        }
        for (unsigned o = 0; o < d.num_objects; o++) close(d.objects[o].fd);
    }
    GLint ifmt = 0;
    glBindTexture(GL_TEXTURE_2D, ytex[0]);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &ifmt);
    printf("Y texture internal format 0x%x", ifmt);
    glBindTexture(GL_TEXTURE_2D, uvtex[0]);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &ifmt);
    printf(", UV 0x%x\n", ifmt);

    // ---- input ring: GBM BOs with Mutter's modifier, filled once ----
    uint64_t mod = MUTTER_MOD;
    struct gbm_bo *bo[MAXRING];
    GLuint intex[MAXRING];
    GLuint stage, fbo[2];
    glGenFramebuffers(2, fbo);
    glGenTextures(1, &stage);
    glBindTexture(GL_TEXTURE_2D, stage);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H);
    uint8_t *cpu = malloc((size_t)W * H * 4);
    uint64_t t0 = now_ns();
    for (int i = 0; i < ring_n; i++) {
        bo[i] = gbm_bo_create_with_modifiers2(gbm, W, H, GBM_FORMAT_XRGB8888, &mod, 1, GBM_BO_USE_RENDERING);
        if (!bo[i]) DIE("gbm_bo_create_with_modifiers2 (0x%llx): %s", (unsigned long long)mod, strerror(errno));
        if (i == 0)
            printf("input BO: XR24 %dx%d, modifier 0x%016llx, %d plane(s), stride %u\n", W, H,
                   (unsigned long long)gbm_bo_get_modifier(bo[i]), gbm_bo_get_plane_count(bo[i]),
                   gbm_bo_get_stride_for_plane(bo[i], 0));
        // Validate: one plane, the modifier we asked for, the size we asked for, a stride covering a row.
        if (gbm_bo_get_modifier(bo[i]) != mod || gbm_bo_get_plane_count(bo[i]) != 1 ||
            gbm_bo_get_width(bo[i]) != (uint32_t)W || gbm_bo_get_height(bo[i]) != (uint32_t)H ||
            gbm_bo_get_stride_for_plane(bo[i], 0) < (uint32_t)W * 4 || gbm_bo_get_offset(bo[i], 0) != 0)
            DIE("input BO %d: unexpected modifier/planes/size/stride", i);
        int bfd = gbm_bo_get_fd_for_plane(bo[i], 0);
        EGLImageKHR img = import_dmabuf(W, H, DRM_FORMAT_XRGB8888, bfd, gbm_bo_get_offset(bo[i], 0),
                                        gbm_bo_get_stride_for_plane(bo[i], 0), gbm_bo_get_modifier(bo[i]));
        close(bfd);
        intex[i] = tex_from_image(img);
        gen_frame(cpu, W, H, i);
        glBindTexture(GL_TEXTURE_2D, stage);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_BGRA, GL_UNSIGNED_BYTE, cpu);
        // glCopyImageSubData refuses RGBA8 -> the imported XR24 texture (GL_RGB8): blit instead.
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo[0]);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, stage, 0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo[1]);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, intex[i], 0);
        if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) DIE("input FBO incomplete");
        glBlitFramebuffer(0, 0, W, H, 0, 0, W, H, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        GLenum e = glGetError();
        if (e) DIE("filling ring %d: GL error 0x%x", i, e);
    }
    glFinish();
    glBindTexture(GL_TEXTURE_2D, intex[0]);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &ifmt);
    printf("filled %d input BOs in %.0f ms (input texture internal format 0x%x)\n", ring_n, (now_ns() - t0) / 1e6, ifmt);
    if (ifmt == GL_RGB8)
        printf("note: the imported XR24 texture is GL_RGB8, which is not an image-unit format: --input image|u32 "
               "read garbage (verification fails); use --input texel\n");
    if (info) return 0;

    struct { int wx, wy, input; } cases[16];
    int ncase = 0;
    if (sweep) {
        int shapes[][2] = {{8, 8}, {16, 8}, {32, 4}, {16, 16}, {64, 1}};
        for (int in = 0; in < 3; in++)
            for (int s = 0; s < 5; s++) cases[ncase++] = (typeof(cases[0])){shapes[s][0], shapes[s][1], in};
    } else
        cases[ncase++] = (typeof(cases[0])){wx, wy, input};

    int BX = W / 2, BY = H / 2;
    GLuint q[2 * MAXRING];
    glGenQueries(2 * MAXRING, q);
    uint64_t *gpu = calloc(frames, sizeof *gpu), *cpu_t = calloc(frames, sizeof *cpu_t),
             *sub = calloc(frames, sizeof *sub);
    uint8_t *Yref = malloc((size_t)W * H), *UVref = malloc((size_t)W * H / 2);
    VAImageFormat nv12fmt = {.fourcc = VA_FOURCC_NV12, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12};
    VAImage vimg;
    VACHECK(vaCreateImage(va, &nv12fmt, W, H, &vimg));

    for (int c = 0; c < ncase; c++) {
        printf("case wg %dx%d input %s, %d frames, pace %.0f Hz, sync %s\n", cases[c].wx, cases[c].wy,
               cases[c].input == 0 ? "texelFetch" : cases[c].input == 1 ? "imageLoad rgba8" : "imageLoad r32ui",
               frames, pace, use_fd ? "sync-file" : "glClientWaitSync");
        GLuint prog = build_program(cases[c].wx, cases[c].wy, cases[c].input);
        glUseProgram(prog);
        glUniform2i(0, BX, BY); // location 0: the only uniform
        int gx = (BX + cases[c].wx - 1) / cases[c].wx, gy = (BY + cases[c].wy - 1) / cases[c].wy;
        GLenum e;
        uint64_t run0 = 0;
        // Warm-up (first dispatch compiles the variant's final ISA state).
        for (int f = -8; f < frames; f++) {
            int ri = (f + 8) % ring_n, oi = (f + 8) % NOUT;
            if (pace > 0 && f >= 0) {
                static uint64_t tick0;
                if (f == 0) tick0 = now_ns();
                uint64_t due = tick0 + (uint64_t)(f * 1e9 / pace);
                uint64_t n = now_ns();
                if (n < due) {
                    struct timespec ts = {(due - n) / 1000000000ull, (due - n) % 1000000000ull};
                    nanosleep(&ts, NULL);
                }
            }
            uint64_t ts = now_ns();
            if (f == 0) run0 = ts;
            if (cases[c].input == 0) {
                glActiveTexture(GL_TEXTURE0);
                glBindTexture(GL_TEXTURE_2D, intex[ri]);
            } else
                glBindImageTexture(0, intex[ri], 0, GL_FALSE, 0, GL_READ_ONLY,
                                   cases[c].input == 1 ? GL_RGBA8 : GL_R32UI);
            glBindImageTexture(1, ytex[oi], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_R8);
            glBindImageTexture(2, uvtex[oi], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RG8);
            int qi = (f + 8) % MAXRING;
            glQueryCounter(q[2 * qi], GL_TIMESTAMP);
            glDispatchCompute(gx, gy, 1);
            glQueryCounter(q[2 * qi + 1], GL_TIMESTAMP);
            if (use_fd) {
                EGLSync s = eglCreateSync(edpy, EGL_SYNC_NATIVE_FENCE_ANDROID, NULL);
                glFlush();
                int sfd = dupFenceFd(edpy, s);
                if (sfd < 0) DIE("eglDupNativeFenceFDANDROID");
                uint64_t tsub = now_ns();
                struct pollfd pf = {sfd, POLLIN, 0};
                if (poll(&pf, 1, 1000) != 1) DIE("sync file poll");
                close(sfd);
                eglDestroySync(edpy, s);
                if (f >= 0) sub[f] = tsub - ts;
            } else {
                GLsync s = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
                glFlush();
                uint64_t tsub = now_ns();
                if (glClientWaitSync(s, GL_SYNC_FLUSH_COMMANDS_BIT, 1000000000ull) == GL_TIMEOUT_EXPIRED)
                    DIE("fence timeout");
                glDeleteSync(s);
                if (f >= 0) sub[f] = tsub - ts;
            }
            uint64_t te = now_ns();
            GLuint64 a, b;
            glGetQueryObjectui64v(q[2 * qi], GL_QUERY_RESULT, &a);
            glGetQueryObjectui64v(q[2 * qi + 1], GL_QUERY_RESULT, &b);
            if (f >= 0) { gpu[f] = b - a; cpu_t[f] = te - ts; }
        }
        if ((e = glGetError())) DIE("GL error 0x%x", e);
        double run_s = (now_ns() - run0) / 1e9;
        printf("    run: %d conversions in %.2f s = %.1f conversions/s\n", frames, run_s, frames / run_s);
        stats("GPU (timer queries)", gpu, frames);
        stats("CPU dispatch->fence", cpu_t, frames);
        stats("CPU dispatch->flush", sub, frames);

        // ---- correctness: read the VA surfaces back and compare with the CPU reference ----
        for (int v = 0; v < verify; v++) {
            int ri = (v * 3 + 1) % ring_n, oi = v % NOUT;
            if (cases[c].input == 0) {
                glBindTexture(GL_TEXTURE_2D, intex[ri]);
            } else
                glBindImageTexture(0, intex[ri], 0, GL_FALSE, 0, GL_READ_ONLY, cases[c].input == 1 ? GL_RGBA8 : GL_R32UI);
            glBindImageTexture(1, ytex[oi], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_R8);
            glBindImageTexture(2, uvtex[oi], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RG8);
            glDispatchCompute(gx, gy, 1);
            GLsync s = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
            glClientWaitSync(s, GL_SYNC_FLUSH_COMMANDS_BIT, 1000000000ull);
            glDeleteSync(s);
            VACHECK(vaSyncSurface(va, out[oi]));
            VACHECK(vaGetImage(va, out[oi], 0, 0, W, H, vimg.image_id));
            uint8_t *m;
            VACHECK(vaMapBuffer(va, vimg.buf, (void **)&m));
            gen_frame(cpu, W, H, ri);
            ref_nv12(cpu, W, H, Yref, UVref);
            int maxy = 0, maxc = 0;
            double sumy = 0, sumc = 0;
            long hist[3] = {0};
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++) {
                    int d = abs(m[vimg.offsets[0] + (size_t)y * vimg.pitches[0] + x] - Yref[(size_t)y * W + x]);
                    sumy += d; if (d > maxy) maxy = d;
                }
            for (int y = 0; y < H / 2; y++)
                for (int x = 0; x < W; x++) {
                    int d = abs(m[vimg.offsets[1] + (size_t)y * vimg.pitches[1] + x] - UVref[(size_t)y * W + x]);
                    sumc += d; if (d > maxc) maxc = d;
                    hist[d > 2 ? 2 : d]++;
                }
            VACHECK(vaUnmapBuffer(va, vimg.buf));
            printf("    verify ring frame %d via VA surface %d: Y max %d mean %.5f | CbCr max %d mean %.5f "
                   "(CbCr off by 1: %ld, >1: %ld)\n", ri, oi, maxy, sumy / ((double)W * H), maxc,
                   sumc / ((double)W * H / 2), hist[1], hist[2]);
        }
        glDeleteProgram(prog);
    }
    gpubusy("after");
    loadavg("after");
    return 0;
}
