// e2e: the whole capture -> convert -> encode path on the AMD iGPU, for the conversion spike.
//
// A PipeWire consumer of one Mutter screen-cast node (DMA-BUF BGRx, modifier 0x200000000401b03, 2752x2064,
// max 120 fps). It keeps only the newest picture (one slot, latest wins), and whenever no request is
// outstanding converts that picture to NV12 and encodes it with libva as spike A's vaenc does (HEVC Main,
// CBR 60 Mbps, a two-frame HRD, one reference, no B-frames, no periodic IDR). It writes its own VPS, SPS and
// PPS as packed headers so the stream decodes.
//
// Conversion (--conv):
//   gl  : one GL 4.6 compute pass (spikes/linux-convert/gl): the PipeWire DMA-BUF imported as an EGLImage
//         (texelFetch), written with imageStore into an NV12 VA surface exported to GL (zero-copy).
//   vpp : VA video processing (spikes/linux-convert/vpp): the DMA-BUF imported as a BGRX VA surface, BT.709
//         input, BT.709 full-range output.
// Sync between conversion and encode (--sync): cpu waits for the conversion's fence (GL) or vaSyncSurface
// (VPP) before the encode is submitted; implicit (GL only) only flushes and leaves the ordering to the
// kernel's implicit sync on the shared buffer.
//
// Times are CLOCK_MONOTONIC. Capture time is the PipeWire buffer's spa_meta_header PTS (Mutter's frame
// time); the arrival time is also kept. Opens only the AMD render node (checked by PCI vendor); run under
// spikes/linux-encoder/nvidia-guard.sh.
//
// Usage: e2e <node-id> [--conv gl|vpp] [--sync cpu|implicit] [--seconds 10] [--warmup 2] [--fps 120]
//            [--loop main|thread] [--pipeline] [--dump out.h265] [--refdump out.nv12]
// --loop thread runs PipeWire on its own thread, so Mutter's buffers are taken and returned while we convert or
// encode (with main, the stream is serviced only between requests). --pipeline converts the next picture on the
// GFX engine while the previous one encodes on VCN (still one encode outstanding). While a conversion is waited
// for and an encode is in flight, the conversion's fence and the encode's coded buffer are polled alternately in
// 50 us steps, so the AU is collected and timed when the encode finishes, not when the conversion does.
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/glcorearb.h>
#include <drm_fourcc.h>
#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <va/va_enc_hevc.h>
#include <va/va_vpp.h>

#include <pipewire/pipewire.h>
#include <pipewire/thread-loop.h>
#include <spa/buffer/meta.h>
#include <spa/param/buffers.h>
#include <spa/param/video/format-utils.h>

#define DEVICE "/dev/dri/by-path/pci-0000:79:00.0-render"
#define MUTTER_MOD 0x0200000000401b03ULL
#define W 2752
#define H 2064
#define NOUT 3
#define MAXF 4096

#define DIE(...) do { fprintf(stderr, "e2e: " __VA_ARGS__); fputc('\n', stderr); exit(1); } while (0)
#define CHECK(x) do { VAStatus s_ = (x); if (s_ != VA_STATUS_SUCCESS) DIE("%s:%d %s: %s", __FILE__, __LINE__, #x, vaErrorStr(s_)); } while (0)

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static uint64_t cpu_ns(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000000000ull + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) * 1000ull;
}
static int cmp_i64(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : x > y;
}
static void summary(const char *label, int64_t *v, int n) {
    if (!n) { printf("  %-40s none\n", label); return; }
    qsort(v, n, sizeof *v, cmp_i64);
    double s = 0;
    for (int i = 0; i < n; i++) s += v[i];
#define P(q) (v[(int)((n - 1) * (q) + 0.5)] / 1e6)
    printf("  %-40s n=%d p50=%.2f p95=%.2f p99=%.2f max=%.2f mean=%.2f ms\n", label, n, P(0.5), P(0.95), P(0.99),
           v[n - 1] / 1e6, s / n / 1e6);
#undef P
}

// ---------------------------------------------------------------- GL (compute conversion)
#define GLFUNCS(X) \
    X(PFNGLGETSTRINGPROC, glGetString) X(PFNGLGETERRORPROC, glGetError) X(PFNGLGENTEXTURESPROC, glGenTextures) \
    X(PFNGLDELETETEXTURESPROC, glDeleteTextures) X(PFNGLBINDTEXTUREPROC, glBindTexture) \
    X(PFNGLTEXPARAMETERIPROC, glTexParameteri) X(PFNGLCREATESHADERPROC, glCreateShader) \
    X(PFNGLSHADERSOURCEPROC, glShaderSource) X(PFNGLCOMPILESHADERPROC, glCompileShader) \
    X(PFNGLGETSHADERIVPROC, glGetShaderiv) X(PFNGLGETSHADERINFOLOGPROC, glGetShaderInfoLog) \
    X(PFNGLCREATEPROGRAMPROC, glCreateProgram) X(PFNGLATTACHSHADERPROC, glAttachShader) \
    X(PFNGLLINKPROGRAMPROC, glLinkProgram) X(PFNGLGETPROGRAMIVPROC, glGetProgramiv) \
    X(PFNGLUSEPROGRAMPROC, glUseProgram) X(PFNGLUNIFORM2IPROC, glUniform2i) \
    X(PFNGLBINDIMAGETEXTUREPROC, glBindImageTexture) X(PFNGLACTIVETEXTUREPROC, glActiveTexture) \
    X(PFNGLDISPATCHCOMPUTEPROC, glDispatchCompute) X(PFNGLFENCESYNCPROC, glFenceSync) \
    X(PFNGLCLIENTWAITSYNCPROC, glClientWaitSync) X(PFNGLDELETESYNCPROC, glDeleteSync) X(PFNGLFLUSHPROC, glFlush) \
    X(PFNGLGENQUERIESPROC, glGenQueries) X(PFNGLQUERYCOUNTERPROC, glQueryCounter) \
    X(PFNGLGETQUERYOBJECTUI64VPROC, glGetQueryObjectui64v)
#define DECL(t, n) static t n;
GLFUNCS(DECL)
typedef void (*PFNEGLIMAGETARGETTEXSTORAGE)(GLenum, GLeglImageOES, const GLint *);
static PFNEGLIMAGETARGETTEXSTORAGE glEGLImageTargetTexStorageEXT_;

static const char *shader_src =
    "#version 430\n"
    "layout(local_size_x = 16, local_size_y = 8) in;\n"
    "layout(binding = 0) uniform sampler2D src;\n"
    "layout(binding = 1, r8) writeonly uniform image2D ypl;\n"
    "layout(binding = 2, rg8) writeonly uniform image2D uvpl;\n"
    "layout(location = 0) uniform ivec2 blocks;\n"
    "const vec3 K = vec3(0.2126, 0.7152, 0.0722);\n"
    "vec3 load(ivec2 p) { return texelFetch(src, p, 0).rgb; }\n"
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

static EGLDisplay edpy;

static EGLImage import_plane(int w, int h, uint32_t fourcc, int fd, uint32_t offset, uint32_t pitch, uint64_t mod) {
    EGLAttrib a[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_LINUX_DRM_FOURCC_EXT, fourcc, EGL_DMA_BUF_PLANE0_FD_EXT, fd,
                     EGL_DMA_BUF_PLANE0_OFFSET_EXT, offset, EGL_DMA_BUF_PLANE0_PITCH_EXT, pitch,
                     EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, (EGLAttrib)(mod & 0xffffffff),
                     EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, (EGLAttrib)(mod >> 32), EGL_NONE};
    EGLImage img = eglCreateImage(edpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, a);
    if (img == EGL_NO_IMAGE) DIE("eglCreateImage %.4s %dx%d: 0x%x", (char *)&fourcc, w, h, eglGetError());
    return img;
}
static GLuint tex_of(EGLImage img) {
    GLuint t;
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glEGLImageTargetTexStorageEXT_(GL_TEXTURE_2D, img, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    GLenum e = glGetError();
    if (e) DIE("EGLImage -> texture: GL error 0x%x", e);
    return t;
}

// ---------------------------------------------------------------- bit writer for VPS/SPS/PPS
typedef struct { uint8_t b[256]; int bits; } bw;
static void put(bw *w, uint32_t v, int n) {
    for (int i = n - 1; i >= 0; i--) {
        if (w->bits / 8 >= (int)sizeof w->b) DIE("bit writer overflow");
        if ((v >> i) & 1) w->b[w->bits / 8] |= 0x80 >> (w->bits % 8);
        w->bits++;
    }
}
static void ue(bw *w, uint32_t v) {
    uint32_t x = v + 1;
    int n = 0;
    while ((x >> n) > 1) n++;
    put(w, 0, n);
    put(w, x, n + 1);
}
static void se(bw *w, int32_t v) { ue(w, v <= 0 ? (uint32_t)(-2 * v) : (uint32_t)(2 * v - 1)); }
static void trailing(bw *w) { put(w, 1, 1); while (w->bits % 8) put(w, 0, 1); }
static void ptl(bw *w) {
    put(w, 0, 2); put(w, 0, 1); put(w, 1, 5);  // profile space, tier Main, profile Main
    put(w, 0x60000000, 32);                     // compatible with Main and Main 10
    put(w, 1, 1); put(w, 0, 1); put(w, 0, 1); put(w, 1, 1); // progressive, not interlaced, not non-packed, frame only
    put(w, 0, 32); put(w, 0, 12);               // 43 reserved bits + inbld flag
    put(w, 153, 8);                             // level 5.1
}
// NAL with start code and emulation prevention; returns its length in bytes.
static int nal(uint8_t *out, int type, bw *rbsp) {
    int n = 0;
    out[n++] = 0; out[n++] = 0; out[n++] = 0; out[n++] = 1;
    out[n++] = type << 1; out[n++] = 1;
    int zeros = 0;
    for (int i = 0; i < rbsp->bits / 8; i++) {
        if (zeros >= 2 && rbsp->b[i] <= 3) { out[n++] = 3; zeros = 0; }
        out[n++] = rbsp->b[i];
        zeros = rbsp->b[i] == 0 ? zeros + 1 : 0;
    }
    return n;
}
static int build_vps(uint8_t *out) {
    bw w = {0};
    put(&w, 0, 4); put(&w, 1, 1); put(&w, 1, 1); put(&w, 0, 6); put(&w, 0, 3); put(&w, 1, 1); put(&w, 0xffff, 16);
    ptl(&w);
    put(&w, 1, 1); ue(&w, 1); ue(&w, 0); ue(&w, 0); // sub-layer ordering: dpb 2, no reorder, no latency limit
    put(&w, 0, 6); ue(&w, 0); put(&w, 0, 1); put(&w, 0, 1); // max layer id, layer sets, no timing, no extension
    trailing(&w);
    return nal(out, 32, &w);
}
static int build_sps(uint8_t *out, int fps) {
    bw w = {0};
    put(&w, 0, 4); put(&w, 0, 3); put(&w, 1, 1);
    ptl(&w);
    ue(&w, 0); ue(&w, 1); ue(&w, W); ue(&w, H); put(&w, 0, 1); // id, 4:2:0, size, no conformance window
    ue(&w, 0); ue(&w, 0); ue(&w, 4);                         // 8-bit, log2_max_poc_lsb 8
    put(&w, 1, 1); ue(&w, 1); ue(&w, 0); ue(&w, 0);
    ue(&w, 0); ue(&w, 3); ue(&w, 0); ue(&w, 3); ue(&w, 3); ue(&w, 3); // CB 8..64, TB 4..32, depths 3
    put(&w, 0, 1); put(&w, 1, 1); put(&w, 0, 1); put(&w, 0, 1); // no scaling lists, AMP, no SAO, no PCM
    ue(&w, 0); put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1);      // no st RPS in SPS, no LT, no TMVP, no strong intra
    put(&w, 1, 1);                                               // VUI
    put(&w, 0, 1); put(&w, 0, 1);                                // no aspect ratio, no overscan
    put(&w, 1, 1); put(&w, 5, 3); put(&w, 1, 1); put(&w, 1, 1);  // video signal: unspecified format, FULL range
    put(&w, 1, 8); put(&w, 1, 8); put(&w, 1, 8);                 // BT.709 primaries, transfer, matrix
    put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1); // chroma loc, neutral, field, ffi, ddw
    put(&w, 1, 1); put(&w, 1, 32); put(&w, fps, 32); put(&w, 0, 1); put(&w, 0, 1); // timing 1/fps, no poc, no HRD
    put(&w, 0, 1);                                               // no bitstream restriction
    put(&w, 0, 1);                                               // no SPS extension
    trailing(&w);
    return nal(out, 33, &w);
}
static int build_pps(uint8_t *out) {
    bw w = {0};
    ue(&w, 0); ue(&w, 0);
    put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 3); put(&w, 0, 1); put(&w, 0, 1); // dep slices, output flag, extra bits, SDH, cabac init
    ue(&w, 0); ue(&w, 0); se(&w, 0);                                           // ref idx defaults, init_qp 26
    put(&w, 0, 1); put(&w, 0, 1); put(&w, 1, 1); ue(&w, 0);                     // no CIP, no TS, cu_qp_delta, depth 0
    se(&w, 0); se(&w, 0);
    put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1); // chroma offsets, WP, WBP, bypass, tiles, WPP
    put(&w, 1, 1);                                                             // loop filter across slices
    put(&w, 0, 1); put(&w, 0, 1); put(&w, 0, 1); ue(&w, 0); put(&w, 0, 1); put(&w, 0, 1); // deblock ctl, lists, mod, merge, ext hdr, ext
    trailing(&w);
    return nal(out, 34, &w);
}

// The slice segment header for our SPS/PPS: one slice per picture, IDR (I) or TRAIL_R (P, one reference: the
// previous picture). Mesa writes VPS/SPS/PPS only when a packed slice header comes with them (radeonsi's
// radeon_vcn_enc_encode_headers returns early without one), and it parses this header for the slice's values.
static int build_slice(uint8_t *out, int idr, int poc) {
    bw w = {0};
    put(&w, 1, 1);                    // first_slice_segment_in_pic_flag
    if (idr) put(&w, 0, 1);           // no_output_of_prior_pics_flag
    ue(&w, 0);                        // slice_pic_parameter_set_id
    ue(&w, idr ? 2 : 1);              // slice_type I / P
    if (!idr) {
        put(&w, poc & 0xff, 8);       // slice_pic_order_cnt_lsb (log2_max_poc_lsb 8)
        put(&w, 0, 1);                // short_term_ref_pic_set_sps_flag: coded here
        ue(&w, 1); ue(&w, 0);         // one negative picture, no positive
        ue(&w, 0); put(&w, 1, 1);     // delta POC -1, used by the current picture
        put(&w, 0, 1);                // num_ref_idx_active_override_flag
        ue(&w, 0);                    // five_minus_max_num_merge_cand
    }
    se(&w, 0);                        // slice_qp_delta
    put(&w, 1, 1);                    // slice_loop_filter_across_slices_enabled_flag
    put(&w, 1, 1); while (w.bits % 8) put(&w, 0, 1); // byte_alignment()
    return nal(out, idr ? 19 : 1, &w);
}

// ---------------------------------------------------------------- encoder (spike A's settings)
typedef struct {
    VAConfigID cfg;
    VAContextID ctx;
    VASurfaceID recon[2];
    VABufferID coded;
    int fps, poc, cur;
    unsigned kbps;
    VABufferID bufs[20]; // the parameter buffers of the encode in flight
    int nb;
} encoder;
static VABufferID make_buf(VADisplay d, VAContextID c, VABufferType t, unsigned size, void *data) {
    VABufferID id;
    CHECK(vaCreateBuffer(d, c, t, size, 1, data, &id));
    return id;
}
static VABufferID misc_buf(VADisplay d, VAContextID c, VAEncMiscParameterType t, void *data, unsigned size) {
    VABufferID id;
    CHECK(vaCreateBuffer(d, c, VAEncMiscParameterBufferType, sizeof(VAEncMiscParameterBuffer) + size, 1, NULL, &id));
    VAEncMiscParameterBuffer *m;
    CHECK(vaMapBuffer(d, id, (void **)&m));
    m->type = t;
    memcpy(m->data, data, size);
    CHECK(vaUnmapBuffer(d, id));
    return id;
}
static void packed(VADisplay d, VAContextID c, VABufferID *bufs, int *nb, int type, uint8_t *data, int len) {
    VAEncPackedHeaderParameterBuffer p = {.type = type, .bit_length = len * 8, .has_emulation_bytes = 1};
    bufs[(*nb)++] = make_buf(d, c, VAEncPackedHeaderParameterBufferType, sizeof p, &p);
    bufs[(*nb)++] = make_buf(d, c, VAEncPackedHeaderDataBufferType, len, data);
}
static void enc_init(VADisplay d, encoder *e, int fps, VASurfaceID *inputs, int n_inputs) {
    *e = (encoder){.fps = fps, .kbps = 60000};
    VAConfigAttrib a[3] = {{VAConfigAttribRTFormat, VA_RT_FORMAT_YUV420}, {VAConfigAttribRateControl, VA_RC_CBR},
                           {VAConfigAttribEncPackedHeaders, VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE | VA_ENC_PACKED_HEADER_SLICE}};
    CHECK(vaCreateConfig(d, VAProfileHEVCMain, VAEntrypointEncSlice, a, 3, &e->cfg));
    CHECK(vaCreateSurfaces(d, VA_RT_FORMAT_YUV420, W, H, e->recon, 2, NULL, 0));
    VASurfaceID all[2 + NOUT];
    memcpy(all, e->recon, sizeof e->recon);
    memcpy(all + 2, inputs, n_inputs * sizeof *inputs);
    CHECK(vaCreateContext(d, e->cfg, W, H, VA_PROGRESSIVE, all, 2 + n_inputs, &e->ctx));
    CHECK(vaCreateBuffer(d, e->ctx, VAEncCodedBufferType, W * H * 3 / 2, 1, NULL, &e->coded));
}
// Submits the encode of `src` (one at a time: enc_collect must follow before the next submit).
static void enc_submit(VADisplay d, encoder *e, VASurfaceID src) {
    int idr = e->poc == 0, ctus = ((W + 63) / 64) * ((H + 63) / 64);
    VABufferID *bufs = e->bufs;
    int nb = 0;
    if (idr) {
        VAEncSequenceParameterBufferHEVC seq = {0};
        seq.general_profile_idc = 1;
        seq.general_level_idc = 153;
        seq.ip_period = 1;
        seq.bits_per_second = e->kbps * 1000;
        seq.pic_width_in_luma_samples = W;
        seq.pic_height_in_luma_samples = H;
        seq.seq_fields.bits.chroma_format_idc = 1;
        seq.seq_fields.bits.amp_enabled_flag = 1;
        seq.seq_fields.bits.low_delay_seq = 1;
        seq.log2_diff_max_min_luma_coding_block_size = 3;
        seq.log2_diff_max_min_transform_block_size = 3;
        seq.max_transform_hierarchy_depth_inter = 3;
        seq.max_transform_hierarchy_depth_intra = 3;
        seq.vui_parameters_present_flag = 1;
        seq.vui_fields.bits.vui_timing_info_present_flag = 1;
        seq.vui_num_units_in_tick = 1;
        seq.vui_time_scale = e->fps;
        bufs[nb++] = make_buf(d, e->ctx, VAEncSequenceParameterBufferType, sizeof seq, &seq);
    }
    VAEncMiscParameterRateControl rc = {.bits_per_second = e->kbps * 1000, .target_percentage = 100,
                                        .window_size = 1000, .initial_qp = 26, .min_qp = 1, .max_qp = 51};
    bufs[nb++] = misc_buf(d, e->ctx, VAEncMiscParameterTypeRateControl, &rc, sizeof rc);
    VAEncMiscParameterFrameRate fr = {.framerate = e->fps};
    bufs[nb++] = misc_buf(d, e->ctx, VAEncMiscParameterTypeFrameRate, &fr, sizeof fr);
    VAEncMiscParameterHRD hrd = {.initial_buffer_fullness = e->kbps * 1000 / e->fps, .buffer_size = e->kbps * 1000 / e->fps * 2};
    bufs[nb++] = misc_buf(d, e->ctx, VAEncMiscParameterTypeHRD, &hrd, sizeof hrd);
    VAEncPictureParameterBufferHEVC pic = {0};
    pic.decoded_curr_pic.picture_id = e->recon[e->cur];
    pic.decoded_curr_pic.pic_order_cnt = e->poc;
    for (int i = 0; i < 15; i++) {
        pic.reference_frames[i].picture_id = VA_INVALID_SURFACE;
        pic.reference_frames[i].flags = VA_PICTURE_HEVC_INVALID;
    }
    if (!idr) {
        pic.reference_frames[0].picture_id = e->recon[e->cur ^ 1];
        pic.reference_frames[0].pic_order_cnt = e->poc - 1;
        pic.reference_frames[0].flags = 0;
    }
    pic.coded_buf = e->coded;
    pic.collocated_ref_pic_index = 0xff;
    pic.pic_init_qp = 26;
    pic.nal_unit_type = idr ? 19 : 1;
    pic.pic_fields.bits.idr_pic_flag = idr;
    pic.pic_fields.bits.coding_type = idr ? 1 : 2;
    pic.pic_fields.bits.reference_pic_flag = 1;
    pic.pic_fields.bits.cu_qp_delta_enabled_flag = 1;
    pic.pic_fields.bits.pps_loop_filter_across_slices_enabled_flag = 1;
    bufs[nb++] = make_buf(d, e->ctx, VAEncPictureParameterBufferType, sizeof pic, &pic);
    if (idr) {
        uint8_t hdr[512];
        int n = build_vps(hdr);
        packed(d, e->ctx, bufs, &nb, VAEncPackedHeaderSequence, hdr, n);
        n = build_sps(hdr, e->fps);
        packed(d, e->ctx, bufs, &nb, VAEncPackedHeaderSequence, hdr, n);
        n = build_pps(hdr);
        packed(d, e->ctx, bufs, &nb, VAEncPackedHeaderPicture, hdr, n);
    }
    VAEncSliceParameterBufferHEVC sl = {0};
    sl.num_ctu_in_slice = ctus;
    sl.slice_type = idr ? 2 : 1;
    for (int i = 0; i < 15; i++) {
        sl.ref_pic_list0[i].picture_id = sl.ref_pic_list1[i].picture_id = VA_INVALID_SURFACE;
        sl.ref_pic_list0[i].flags = sl.ref_pic_list1[i].flags = VA_PICTURE_HEVC_INVALID;
    }
    if (!idr) sl.ref_pic_list0[0] = pic.reference_frames[0];
    sl.max_num_merge_cand = 5;
    sl.slice_fields.bits.last_slice_of_pic_flag = 1;
    sl.slice_fields.bits.slice_loop_filter_across_slices_enabled_flag = 1;
    bufs[nb++] = make_buf(d, e->ctx, VAEncSliceParameterBufferType, sizeof sl, &sl);
    {
        uint8_t hdr[64];
        int n = build_slice(hdr, idr, e->poc);
        packed(d, e->ctx, bufs, &nb, VAEncPackedHeaderSlice, hdr, n);
    }
    CHECK(vaBeginPicture(d, e->ctx, src));
    CHECK(vaRenderPicture(d, e->ctx, bufs, nb));
    CHECK(vaEndPicture(d, e->ctx));
    e->nb = nb;
}
// Waits up to timeout_ns for the encode in flight; returns 0 if it has not finished, else 1 with the AU written,
// its size in *size and *irap / *vps set.
static int enc_collect(VADisplay d, encoder *e, uint64_t timeout_ns, FILE *out, size_t *size_out, int *irap, int *vps) {
    VAStatus st = vaSyncBuffer(d, e->coded, timeout_ns);
    if (st == VA_STATUS_ERROR_TIMEDOUT) return 0;
    if (st != VA_STATUS_SUCCESS) DIE("vaSyncBuffer: %s", vaErrorStr(st));
    VACodedBufferSegment *seg;
    CHECK(vaMapBuffer(d, e->coded, (void **)&seg));
    size_t size = 0;
    *irap = *vps = 0;
    for (VACodedBufferSegment *s = seg; s; s = s->next) {
        uint8_t *b = s->buf;
        for (unsigned i = 0; i + 3 < s->size; i++)
            if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
                int t = (b[i + 3] >> 1) & 0x3f;
                if (t >= 16 && t <= 21) *irap = 1;
                if (t == 32) *vps = 1;
            }
        if (out) fwrite(s->buf, 1, s->size, out);
        size += s->size;
    }
    CHECK(vaUnmapBuffer(d, e->coded));
    for (int i = 0; i < e->nb; i++) vaDestroyBuffer(d, e->bufs[i]);
    e->nb = 0;
    e->poc++;
    e->cur ^= 1;
    *size_out = size;
    return 1;
}

// ---------------------------------------------------------------- state
enum { CONV_GL, CONV_VPP };
struct slot {               // per PipeWire buffer: its import, made on first use
    int imported;
    int fd;
    uint32_t offset, stride;
    EGLImage img;
    GLuint tex;
    VASurfaceID surf;
};
static struct {
    struct pw_main_loop *loop;
    struct pw_thread_loop *tl; // --loop thread: PipeWire on its own thread, so delivery never waits on us
    int pipeline;              // --pipeline: convert the next picture while the previous one encodes
    struct pw_stream *stream;
    struct spa_hook listener;
    struct spa_video_info_raw info;
    int have_format, conv, implicit_sync, fps;
    struct pw_buffer *newest;   // the one-slot, latest-wins holder
    uint64_t newest_pts, newest_arrival;
    // counters (whole run and the measured window)
    long delivered, cursor_only, dropped, encoded;
    long w_delivered, w_dropped, w_encoded;
    int measuring;
    int64_t arrival_minus_pts[MAXF], cap_au[MAXF], arr_au[MAXF], conv_t[MAXF], conv_gpu[MAXF], enc_t[MAXF], ready_wait[MAXF],
        interval[MAXF];
    int n, nd; // encodes and delivered pictures recorded in the window
    uint64_t last_pts;
    VADisplay va;
    VASurfaceID out[NOUT];
    VAContextID vpp_ctx;
    VABufferID ppbuf;
    VAProcPipelineParameterBuffer pp;
    GLuint ytex[NOUT], uvtex[NOUT], prog, q[2];
    int oi;
} S;

static void lock(void) { if (S.tl) pw_thread_loop_lock(S.tl); }
static void unlock(void) { if (S.tl) pw_thread_loop_unlock(S.tl); }

// The loop's run state. A job is one picture: converted into out[oi] ("ready"), then encoding ("ej").
struct job { struct pw_buffer *pb; uint64_t pts, arrival, c0, c1, submit, gpu; int oi; };
static struct {
    encoder enc;
    struct job ej;
    int enc_busy;
    FILE *out;
    size_t bytes, first_au;
    int first_vps, first_irap, last_out;
    long last_enc_index;
    long collected_in_conv; // AUs collected while a conversion was in flight (pipelined)
} R = {.last_out = -1, .last_enc_index = -1};

// Collects the AU of the encode in flight if it finishes within timeout_ns; 1 if it did. The AU's time is taken
// here, so it must be called as soon as possible after the encode finishes: also from inside the conversion's
// wait (see wait_conversion), not only after it, or an AU that finishes during a conversion is timestamped when the
// conversion ends.
static int collect(uint64_t timeout_ns) {
    size_t au;
    int irap, vps;
    if (!enc_collect(S.va, &R.enc, timeout_ns, R.out, &au, &irap, &vps)) return 0;
    uint64_t t_au = now_ns();
    struct job *ej = &R.ej;
    R.enc_busy = 0;
    if (ej->pb) { lock(); pw_stream_queue_buffer(S.stream, ej->pb); unlock(); }
    if (S.conv == CONV_GL && S.implicit_sync) {
        GLuint64 a = 0, z = 0;
        glGetQueryObjectui64v(S.q[0], GL_QUERY_RESULT, &a);
        glGetQueryObjectui64v(S.q[1], GL_QUERY_RESULT, &z);
        ej->gpu = z - a;
    }
    if (S.encoded == 0) { R.first_au = au; R.first_vps = vps; R.first_irap = irap; }
    S.encoded++;
    R.bytes += au;
    R.last_enc_index = S.encoded - 1;
    R.last_out = ej->oi;
    if (S.measuring && S.n < MAXF) {
        S.w_encoded++;
        S.cap_au[S.n] = (int64_t)(t_au - ej->pts);
        S.arr_au[S.n] = (int64_t)(t_au - ej->arrival);
        S.conv_t[S.n] = (int64_t)(ej->c1 - ej->c0);
        S.conv_gpu[S.n] = (int64_t)ej->gpu;
        S.ready_wait[S.n] = (int64_t)(ej->submit - ej->c1);
        S.enc_t[S.n] = (int64_t)(t_au - ej->submit);
        S.n++;
    }
    return 1;
}

// Waits for a conversion: the GL fence (fence != 0) or the VPP output surface. While an encode is in flight it
// polls both in 50 us steps, so the AU is collected (and timed) while the conversion runs, not after it.
static void wait_conversion(GLsync fence, VASurfaceID surf) {
    static int no_sync2;
    uint64_t deadline = now_ns() + 1000000000ull;
    GLbitfield flags = GL_SYNC_FLUSH_COMMANDS_BIT;
    for (;;) {
        int poll = R.enc_busy;
        uint64_t step = poll ? 50000ull : 1000000000ull;
        if (fence) {
            GLenum r = glClientWaitSync(fence, flags, step);
            flags = 0;
            if (r == GL_ALREADY_SIGNALED || r == GL_CONDITION_SATISFIED) return;
            if (r == GL_WAIT_FAILED) DIE("glClientWaitSync failed");
        } else if (!no_sync2) {
            VAStatus st = vaSyncSurface2(S.va, surf, step);
            if (st == VA_STATUS_SUCCESS) return;
            if (st == VA_STATUS_ERROR_UNIMPLEMENTED) {
                no_sync2 = 1;
                fprintf(stderr, "note: vaSyncSurface2 unimplemented: VPP waits block, AU times are late\n");
            } else if (st != VA_STATUS_ERROR_TIMEDOUT) DIE("vaSyncSurface2: %s", vaErrorStr(st));
        }
        if (!fence && no_sync2) { CHECK(vaSyncSurface(S.va, surf)); return; }
        if (now_ns() > deadline) DIE("conversion timeout");
        if (poll && collect(50000)) R.collected_in_conv++;
    }
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    (void)data;
    if (!param || id != SPA_PARAM_Format) return;
    uint32_t mt, ms;
    if (spa_format_parse(param, &mt, &ms) < 0) return;
    spa_format_video_raw_parse(param, &S.info);
    printf("{\"ev\":\"format\",\"format\":%u,\"width\":%u,\"height\":%u,\"max_framerate\":\"%u/%u\",\"modifier\":%llu}\n",
           S.info.format, S.info.size.width, S.info.size.height, S.info.max_framerate.num, S.info.max_framerate.denom,
           (unsigned long long)S.info.modifier);
    // Validate the negotiated format before any buffer is used.
    if (S.info.format != SPA_VIDEO_FORMAT_BGRx || S.info.size.width != W || S.info.size.height != H ||
        S.info.modifier != MUTTER_MOD)
        DIE("unexpected format %u %ux%u modifier 0x%llx", S.info.format, S.info.size.width, S.info.size.height,
            (unsigned long long)S.info.modifier);
    S.have_format = 1;
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *params[3];
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
                                           SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(6, 3, 8),
                                           SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int(1 << SPA_DATA_DmaBuf));
    params[1] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type,
                                           SPA_POD_Id(SPA_META_Header), SPA_PARAM_META_size,
                                           SPA_POD_Int(sizeof(struct spa_meta_header)));
#define CURSOR_META_SIZE(w, h) (sizeof(struct spa_meta_cursor) + sizeof(struct spa_meta_bitmap) + (w) * (h) * 4)
    params[2] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta, SPA_PARAM_META_type,
                                           SPA_POD_Id(SPA_META_Cursor), SPA_PARAM_META_size,
                                           SPA_POD_CHOICE_RANGE_Int(CURSOR_META_SIZE(384, 384), CURSOR_META_SIZE(1, 1),
                                                                    CURSOR_META_SIZE(384, 384)));
    pw_stream_update_params(S.stream, params, 3);
}

static void on_state(void *data, enum pw_stream_state old, enum pw_stream_state st, const char *err) {
    (void)data; (void)old;
    printf("{\"ev\":\"state\",\"state\":\"%s\",\"error\":\"%s\"}\n", pw_stream_state_as_string(st), err ? err : "");
    if (st == PW_STREAM_STATE_ERROR && S.loop) pw_main_loop_quit(S.loop);
}

static void on_add_buffer(void *data, struct pw_buffer *b) {
    (void)data;
    b->user_data = calloc(1, sizeof(struct slot));
}
static void on_remove_buffer(void *data, struct pw_buffer *b) {
    (void)data;
    struct slot *s = b->user_data;
    if (S.newest == b) S.newest = NULL;
    // On PipeWire's thread (--loop thread) the GL context isn't current and the main thread may still be
    // converting this buffer: leave its imports to process exit (buffers go away only at renegotiation/teardown).
    if (S.tl) return;
    if (s && s->imported) {
        if (S.conv == CONV_GL) { glDeleteTextures(1, &s->tex); eglDestroyImage(edpy, s->img); }
        else vaDestroySurfaces(S.va, &s->surf, 1);
    }
    if (S.newest == b) S.newest = NULL;
    free(s);
    b->user_data = NULL;
}

static void on_process(void *data) {
    (void)data;
    struct pw_buffer *b;
    while ((b = pw_stream_dequeue_buffer(S.stream))) {
        uint64_t t = now_ns();
        struct spa_buffer *buf = b->buffer;
        struct spa_chunk *c = buf->datas[0].chunk;
        if (!(c->size > 0 && !(c->flags & SPA_CHUNK_FLAG_CORRUPTED))) { // cursor-only or empty
            S.cursor_only++;
            pw_stream_queue_buffer(S.stream, b);
            continue;
        }
        struct spa_meta_header *h = spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof *h);
        uint64_t pts = h && h->pts > 0 ? (uint64_t)h->pts : t;
        S.delivered++;
        if (S.measuring) {
            S.w_delivered++;
            if (S.nd < MAXF) {
                S.arrival_minus_pts[S.nd] = (int64_t)(t - pts);
                S.interval[S.nd] = S.last_pts ? (int64_t)(pts - S.last_pts) : -1;
                S.nd++;
            }
        }
        S.last_pts = pts;
        if (S.newest) { // replaced before it was encoded
            S.dropped++;
            if (S.measuring) S.w_dropped++;
            pw_stream_queue_buffer(S.stream, S.newest);
        }
        S.newest = b;
        S.newest_pts = pts;
        S.newest_arrival = t;
    }
    if (S.tl) pw_thread_loop_signal(S.tl, false);
}

static const struct pw_stream_events events = {
    PW_VERSION_STREAM_EVENTS, .state_changed = on_state, .param_changed = on_param_changed,
    .add_buffer = on_add_buffer, .remove_buffer = on_remove_buffer, .process = on_process,
};

// Imports a PipeWire buffer once, after validating its layout against the DMA-BUF's real size.
static void import(struct pw_buffer *b) {
    struct slot *s = b->user_data;
    struct spa_buffer *buf = b->buffer;
    struct spa_data *d = &buf->datas[0];
    if (buf->n_datas != 1 || d->type != SPA_DATA_DmaBuf || d->fd < 0) DIE("buffer: not a single-plane DMA-BUF");
    uint32_t offset = d->chunk->offset, stride = (uint32_t)d->chunk->stride;
    off_t size = lseek(d->fd, 0, SEEK_END);
    if (size <= 0) DIE("dma-buf size: %s", strerror(errno));
    if (stride < W * 4 || (uint64_t)offset + (uint64_t)stride * H > (uint64_t)size)
        DIE("dma-buf layout: offset %u + stride %u x %d rows exceeds size %lld", offset, stride, H, (long long)size);
    if (s->imported) {
        if (s->fd != d->fd || s->offset != offset || s->stride != stride) DIE("buffer layout changed after import");
        return;
    }
    s->fd = d->fd; s->offset = offset; s->stride = stride;
    if (S.conv == CONV_GL) {
        s->img = import_plane(W, H, DRM_FORMAT_XRGB8888, d->fd, offset, stride, MUTTER_MOD);
        s->tex = tex_of(s->img);
    } else {
        VADRMPRIMESurfaceDescriptor pd = {0};
        pd.fourcc = VA_FOURCC_BGRX; pd.width = W; pd.height = H; pd.num_objects = 1;
        pd.objects[0].fd = d->fd; pd.objects[0].size = (uint32_t)size; pd.objects[0].drm_format_modifier = MUTTER_MOD;
        pd.num_layers = 1;
        pd.layers[0].drm_format = DRM_FORMAT_XRGB8888; pd.layers[0].num_planes = 1;
        pd.layers[0].object_index[0] = 0; pd.layers[0].offset[0] = offset; pd.layers[0].pitch[0] = stride;
        VASurfaceAttrib sa[2] = {
            {.type = VASurfaceAttribMemoryType, .flags = VA_SURFACE_ATTRIB_SETTABLE,
             .value = {.type = VAGenericValueTypeInteger, .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2}},
            {.type = VASurfaceAttribExternalBufferDescriptor, .flags = VA_SURFACE_ATTRIB_SETTABLE,
             .value = {.type = VAGenericValueTypePointer, .value.p = &pd}}};
        CHECK(vaCreateSurfaces(S.va, VA_RT_FORMAT_RGB32, W, H, &s->surf, 1, sa, 2)); // libva dups the fd
    }
    s->imported = 1;
    printf("{\"ev\":\"import\",\"fd\":%d,\"offset\":%u,\"stride\":%u,\"size\":%lld}\n", (int)d->fd, offset, stride, (long long)size);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) DIE("usage: e2e <node-id> [--conv gl|vpp] [--sync cpu|implicit] [--seconds 10] [--warmup 2] [--fps 120] [--dump f] [--refdump f]");
    uint32_t node = (uint32_t)atoi(argv[1]);
    double seconds = 10, warmup = 2;
    int threaded = 0;
    const char *dump = NULL, *refdump = NULL;
    S.fps = 120;
    for (int i = 2; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(a, "--conv")) { S.conv = !strcmp(v, "vpp") ? CONV_VPP : CONV_GL; if (strcmp(v, "vpp") && strcmp(v, "gl")) DIE("--conv gl|vpp"); i++; }
        else if (!strcmp(a, "--sync")) { S.implicit_sync = !strcmp(v, "implicit"); i++; }
        else if (!strcmp(a, "--seconds")) { seconds = atof(v); i++; }
        else if (!strcmp(a, "--warmup")) { warmup = atof(v); i++; }
        else if (!strcmp(a, "--fps")) { S.fps = atoi(v); i++; }
        else if (!strcmp(a, "--dump")) { dump = v; i++; }
        else if (!strcmp(a, "--loop")) { threaded = !strcmp(v, "thread"); if (strcmp(v, "thread") && strcmp(v, "main")) DIE("--loop main|thread"); i++; }
        else if (!strcmp(a, "--pipeline")) S.pipeline = 1;
        else if (!strcmp(a, "--refdump")) { refdump = v; i++; }
        else DIE("unknown option %s", a);
    }
    if (seconds <= 0 || seconds > 15 || warmup < 0 || warmup >= seconds || S.fps < 1 || S.fps > 240) DIE("bad seconds/warmup/fps");
    if (S.implicit_sync && S.conv != CONV_GL) DIE("--sync implicit is for --conv gl");
    if (S.implicit_sync && S.pipeline) DIE("--sync implicit is serial only (the timer queries are reused)");

    char real[4096], path[4200], vendor[16] = {0};
    if (!realpath(DEVICE, real)) DIE("%s: %s", DEVICE, strerror(errno));
    snprintf(path, sizeof path, "/sys/class/drm/%s/device/vendor", strrchr(real, '/') + 1);
    FILE *vf = fopen(path, "r");
    if (!vf || !fgets(vendor, sizeof vendor, vf) || strncmp(vendor, "0x1002", 6)) DIE("%s is not AMD", real);
    fclose(vf);

    // ---- VA: output NV12 surfaces (encoder input), VPP context if needed, the encoder ----
    int vfd = open(DEVICE, O_RDWR | O_CLOEXEC);
    if (vfd < 0) DIE("open %s: %s", DEVICE, strerror(errno));
    S.va = vaGetDisplayDRM(vfd);
    int vmaj, vmin;
    CHECK(vaInitialize(S.va, &vmaj, &vmin));
    VASurfaceAttrib oattr[2] = {
        {.type = VASurfaceAttribPixelFormat, .flags = VA_SURFACE_ATTRIB_SETTABLE,
         .value = {.type = VAGenericValueTypeInteger, .value.i = VA_FOURCC_NV12}},
        {.type = VASurfaceAttribUsageHint, .flags = VA_SURFACE_ATTRIB_SETTABLE,
         .value = {.type = VAGenericValueTypeInteger,
                   .value.i = VA_SURFACE_ATTRIB_USAGE_HINT_ENCODER |
                              (S.conv == CONV_GL ? VA_SURFACE_ATTRIB_USAGE_HINT_EXPORT : VA_SURFACE_ATTRIB_USAGE_HINT_VPP_WRITE)}}};
    CHECK(vaCreateSurfaces(S.va, VA_RT_FORMAT_YUV420, W, H, S.out, NOUT, oattr, 2));
    enc_init(S.va, &R.enc, S.fps, S.out, NOUT);

    if (S.conv == CONV_VPP) {
        VAConfigID vcfg;
        CHECK(vaCreateConfig(S.va, VAProfileNone, VAEntrypointVideoProc, NULL, 0, &vcfg));
        CHECK(vaCreateContext(S.va, vcfg, W, H, VA_PROGRESSIVE, S.out, NOUT, &S.vpp_ctx));
        S.pp.output_background_color = 0xff000000;
        S.pp.filter_flags = VA_FILTER_SCALING_DEFAULT;
        S.pp.surface_color_standard = VAProcColorStandardBT709; // not SRGB: SRGB changes the transfer (vpp README)
        S.pp.input_color_properties.color_range = VA_SOURCE_RANGE_FULL;
        S.pp.output_color_standard = VAProcColorStandardBT709;
        S.pp.output_color_properties.color_range = VA_SOURCE_RANGE_FULL;
        S.pp.output_color_properties.chroma_sample_location = VA_CHROMA_SITING_VERTICAL_CENTER | VA_CHROMA_SITING_HORIZONTAL_CENTER;
        CHECK(vaCreateBuffer(S.va, S.vpp_ctx, VAProcPipelineParameterBufferType, sizeof S.pp, 1, NULL, &S.ppbuf));
    } else {
        // ---- EGL / GL on a GBM device on the same node; the NV12 surfaces exported into GL ----
        int gfd = open(DEVICE, O_RDWR | O_CLOEXEC);
        if (gfd < 0) DIE("open %s", DEVICE);
        struct gbm_device *gbm = gbm_create_device(gfd);
        if (!gbm) DIE("gbm_create_device");
        edpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
        EGLint maj, min;
        if (!eglInitialize(edpy, &maj, &min)) DIE("eglInitialize 0x%x", eglGetError());
        if (!eglBindAPI(EGL_OPENGL_API)) DIE("eglBindAPI");
        EGLint ca[] = {EGL_CONTEXT_MAJOR_VERSION, 4, EGL_CONTEXT_MINOR_VERSION, 6, EGL_CONTEXT_OPENGL_PROFILE_MASK,
                       EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
        EGLContext ctx = eglCreateContext(edpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ca);
        if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(edpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) DIE("EGL context");
#define LOAD(t, n) n = (t)eglGetProcAddress(#n); if (!n) DIE("no %s", #n);
        GLFUNCS(LOAD)
        glEGLImageTargetTexStorageEXT_ = (PFNEGLIMAGETARGETTEXSTORAGE)eglGetProcAddress("glEGLImageTargetTexStorageEXT");
        if (!glEGLImageTargetTexStorageEXT_) DIE("no glEGLImageTargetTexStorageEXT");
        printf("{\"ev\":\"gl\",\"renderer\":\"%s\"}\n", glGetString(GL_RENDERER));
        for (int i = 0; i < NOUT; i++) {
            VADRMPRIMESurfaceDescriptor d;
            CHECK(vaExportSurfaceHandle(S.va, S.out[i], VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                        VA_EXPORT_SURFACE_WRITE_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS, &d));
            // Validate before any shader can write it: NV12 of our size, two single-plane layers R8 + GR88,
            // each wholly inside its object.
            if (d.fourcc != VA_FOURCC_NV12 || d.width != W || d.height != H || d.num_layers != 2 || d.num_objects < 1 ||
                d.num_objects > 2)
                DIE("export: unexpected NV12 layout");
            for (int l = 0; l < 2; l++) {
                uint32_t o = d.layers[l].object_index[0], rows = l ? H / 2 : H;
                if (d.layers[l].num_planes != 1 || d.layers[l].drm_format != (l ? DRM_FORMAT_GR88 : DRM_FORMAT_R8) ||
                    o >= d.num_objects || d.layers[l].pitch[0] < W ||
                    (uint64_t)d.layers[l].offset[0] + (uint64_t)d.layers[l].pitch[0] * rows > d.objects[o].size)
                    DIE("export layer %d: out of bounds", l);
                EGLImage img = import_plane(l ? W / 2 : W, rows, d.layers[l].drm_format, d.objects[o].fd,
                                            d.layers[l].offset[0], d.layers[l].pitch[0], d.objects[o].drm_format_modifier);
                (l ? S.uvtex : S.ytex)[i] = tex_of(img);
            }
            for (unsigned o = 0; o < d.num_objects; o++) close(d.objects[o].fd);
        }
        GLuint sh = glCreateShader(GL_COMPUTE_SHADER);
        glShaderSource(sh, 1, &shader_src, NULL);
        glCompileShader(sh);
        GLint ok;
        char log[2048];
        glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
        if (!ok) { glGetShaderInfoLog(sh, sizeof log, NULL, log); DIE("compile: %s", log); }
        S.prog = glCreateProgram();
        glAttachShader(S.prog, sh);
        glLinkProgram(S.prog);
        glGetProgramiv(S.prog, GL_LINK_STATUS, &ok);
        if (!ok) DIE("link");
        glUseProgram(S.prog);
        glUniform2i(0, W / 2, H / 2);
        glGenQueries(2, S.q);
    }

    // ---- PipeWire: on this thread's main loop (--loop main) or on its own thread (--loop thread) ----
    pw_init(&argc, &argv);
    struct pw_loop *l;
    if (threaded) {
        S.tl = pw_thread_loop_new("lain-e2e-pw", NULL);
        l = pw_thread_loop_get_loop(S.tl);
    } else {
        S.loop = pw_main_loop_new(NULL);
        l = pw_main_loop_get_loop(S.loop);
    }
    lock();
    S.stream = pw_stream_new_simple(l, "lain-convert-e2e",
                                    pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                      PW_KEY_MEDIA_ROLE, "Screen", NULL),
                                    &events, NULL);
    uint8_t pbuf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(pbuf, sizeof pbuf);
    struct spa_pod_frame f;
    struct spa_rectangle size = SPA_RECTANGLE(W, H);
    struct spa_fraction zero = SPA_FRACTION(0, 1), maxf = SPA_FRACTION(S.fps, 1), minf = SPA_FRACTION(1, 1);
    spa_pod_builder_push_object(&b, &f, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
    spa_pod_builder_add(&b, SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video), SPA_FORMAT_mediaSubtype,
                        SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw), SPA_FORMAT_VIDEO_format, SPA_POD_Id(SPA_VIDEO_FORMAT_BGRx),
                        SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&size), SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&zero),
                        SPA_FORMAT_VIDEO_maxFramerate, SPA_POD_CHOICE_RANGE_Fraction(&maxf, &minf, &maxf), 0);
    spa_pod_builder_prop(&b, SPA_FORMAT_VIDEO_modifier, SPA_POD_PROP_FLAG_MANDATORY);
    spa_pod_builder_long(&b, (int64_t)MUTTER_MOD);
    const struct spa_pod *params[1] = {spa_pod_builder_pop(&b, &f)};
    if (pw_stream_connect(S.stream, PW_DIRECTION_INPUT, node, PW_STREAM_FLAG_AUTOCONNECT, params, 1) < 0)
        DIE("pw_stream_connect");
    unlock();
    if (threaded && pw_thread_loop_start(S.tl) < 0) DIE("pw_thread_loop_start");

    R.out = dump ? fopen(dump, "wb") : NULL;
    if (dump && !R.out) DIE("open %s", dump);
    uint64_t start = now_ns(), measure_from = start + (uint64_t)(warmup * 1e9), end = start + (uint64_t)(seconds * 1e9);
    uint64_t cpu0 = 0, wall0 = 0;
    struct job ready = {0};
    int have_ready = 0;
    if (!threaded) pw_loop_enter(l);
    for (;;) {
        uint64_t t = now_ns();
        if (t >= end && !R.enc_busy) break;
        if (!S.measuring && t >= measure_from) {
            lock(); // on_process reads these on PipeWire's thread
            S.measuring = 1;
            S.last_pts = 0;
            unlock();
            cpu0 = cpu_ns();
            wall0 = t;
        }
        // ---- 1. take the newest picture and convert it (when nothing converted waits for the encoder) ----
        struct pw_buffer *pb = NULL;
        uint64_t pts = 0, arrival = 0;
        if (!threaded) pw_loop_iterate(l, (!have_ready && !R.enc_busy && !S.newest) ? 5 : 0);
        if (!have_ready && t < end) {
            lock();
            if (threaded && !S.newest && !R.enc_busy) {
                struct timespec abst;
                pw_thread_loop_get_time(S.tl, &abst, 5 * SPA_NSEC_PER_MSEC);
                pw_thread_loop_timed_wait_full(S.tl, &abst);
            }
            if (S.newest && S.have_format) {
                pb = S.newest;
                pts = S.newest_pts;
                arrival = S.newest_arrival;
                S.newest = NULL;
            }
            unlock();
        }
        if (pb) {
            import(pb);
            struct slot *s = pb->user_data;
            int oi = S.oi; // NOUT = 3 rotating surfaces: never the one encoding, nor the one last encoded
            S.oi = (S.oi + 1) % NOUT;
            uint64_t c0 = now_ns(), gpu = 0;
            if (S.conv == CONV_GL) {
                glActiveTexture(GL_TEXTURE0);
                glBindTexture(GL_TEXTURE_2D, s->tex);
                glBindImageTexture(1, S.ytex[oi], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_R8);
                glBindImageTexture(2, S.uvtex[oi], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RG8);
                glQueryCounter(S.q[0], GL_TIMESTAMP);
                glDispatchCompute((W / 2 + 15) / 16, (H / 2 + 7) / 8, 1);
                glQueryCounter(S.q[1], GL_TIMESTAMP);
                GLsync fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
                glFlush();
                if (!S.implicit_sync) wait_conversion(fence, VA_INVALID_SURFACE);
                glDeleteSync(fence);
            } else {
                S.pp.surface = s->surf;
                VAProcPipelineParameterBuffer *m;
                CHECK(vaMapBuffer(S.va, S.ppbuf, (void **)&m));
                *m = S.pp;
                CHECK(vaUnmapBuffer(S.va, S.ppbuf));
                CHECK(vaBeginPicture(S.va, S.vpp_ctx, S.out[oi]));
                CHECK(vaRenderPicture(S.va, S.vpp_ctx, &S.ppbuf, 1));
                CHECK(vaEndPicture(S.va, S.vpp_ctx));
                wait_conversion(0, S.out[oi]);
            }
            uint64_t c1 = now_ns();
            if (S.conv == CONV_GL && !S.implicit_sync) { // finished: the results are there
                GLuint64 a = 0, z = 0;
                glGetQueryObjectui64v(S.q[0], GL_QUERY_RESULT, &a);
                glGetQueryObjectui64v(S.q[1], GL_QUERY_RESULT, &z);
                gpu = z - a;
            }
            // With cpu sync the conversion has finished reading the capture: give it back to Mutter now. With
            // implicit sync, hand it back after the encode (by then the conversion has certainly finished).
            if (!S.implicit_sync) { lock(); pw_stream_queue_buffer(S.stream, pb); unlock(); pb = NULL; }
            ready = (struct job){.pb = pb, .pts = pts, .arrival = arrival, .c0 = c0, .c1 = c1, .gpu = gpu, .oi = oi};
            have_ready = 1;
        }
        // ---- 2. submit the converted picture when the encoder is free ----
        if (!R.enc_busy && have_ready) {
            ready.submit = now_ns();
            enc_submit(S.va, &R.enc, S.out[ready.oi]);
            R.ej = ready;
            have_ready = 0;
            R.enc_busy = 1;
        }
        // ---- 3. collect the AU: at once (serial) or polling, so step 1 can run meanwhile (--pipeline) ----
        if (R.enc_busy) collect(!S.pipeline ? 1000000000ull : (have_ready ? 1000000ull : 250000ull));
    }
    if (have_ready && ready.pb) { lock(); pw_stream_queue_buffer(S.stream, ready.pb); unlock(); }
    uint64_t wall = now_ns() - wall0, cpu = cpu_ns() - cpu0;
    if (!threaded) pw_loop_leave(l);
    lock();
    if (S.newest) { pw_stream_queue_buffer(S.stream, S.newest); S.newest = NULL; }
    unlock();
    double ws = wall / 1e9;
    printf("{\"ev\":\"summary\",\"conv\":\"%s\",\"sync\":\"%s\",\"loop\":\"%s\",\"pipeline\":%d,\"window_s\":%.2f,\"delivered_per_s\":%.1f,"
           "\"encoded_per_s\":%.1f,\"dropped_per_s\":%.1f,\"cursor_only_total\":%ld,\"encoded_total\":%ld,"
           "\"cpu_pct\":%.1f,\"mbps\":%.1f,\"first_au\":%zu,\"first_irap\":%d,\"first_vps\":%d,\"last_index\":%ld,"
           "\"au_collected_during_conversion\":%ld}\n",
           S.conv == CONV_GL ? "gl" : "vpp", S.implicit_sync ? "implicit" : "cpu", threaded ? "thread" : "main", S.pipeline, ws, S.w_delivered / ws,
           S.w_encoded / ws, S.w_dropped / ws, S.cursor_only, S.encoded, cpu * 100.0 / wall,
           R.bytes * 8 / ((now_ns() - start) / 1e9) / 1e6, R.first_au, R.first_irap, R.first_vps, R.last_enc_index,
           R.collected_in_conv);
    // The interval and arrival arrays are filled per delivered picture; the others per encode.
    int nd = S.nd, ni = 0;
    for (int i = 0; i < nd; i++) if (S.interval[i] >= 0) S.interval[ni++] = S.interval[i];
    summary("capture (PTS) -> AU mapped", S.cap_au, S.n);
    summary("arrival -> AU mapped", S.arr_au, S.n);
    summary("convert (submit -> done, CPU)", S.conv_t, S.n);
    if (S.conv == CONV_GL) summary("convert (GPU timer queries)", S.conv_gpu, S.n);
    summary("converted, waiting for the encoder", S.ready_wait, S.n);
    summary("encode (submit -> AU mapped)", S.enc_t, S.n);
    summary("PTS -> arrival (delivered pictures)", S.arrival_minus_pts, nd);
    summary("PTS interval (delivered pictures)", S.interval, ni);
    if (R.out) fclose(R.out);
    // The last encoded frame's NV12, for the decode check (its surface is not reused after the loop).
    if (refdump && R.last_out >= 0) {
        VAImageFormat fmt = {.fourcc = VA_FOURCC_NV12, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12};
        VAImage img;
        CHECK(vaCreateImage(S.va, &fmt, W, H, &img));
        CHECK(vaGetImage(S.va, S.out[R.last_out], 0, 0, W, H, img.image_id));
        uint8_t *m;
        CHECK(vaMapBuffer(S.va, img.buf, (void **)&m));
        if (img.num_planes != 2 || (uint64_t)img.offsets[1] + (uint64_t)img.pitches[1] * (H / 2) > img.data_size ||
            (uint64_t)img.pitches[0] * H > img.offsets[1])
            DIE("readback image layout");
        FILE *rf = fopen(refdump, "wb");
        if (!rf) DIE("open %s", refdump);
        for (int y = 0; y < H; y++) fwrite(m + img.offsets[0] + (size_t)y * img.pitches[0], 1, W, rf);
        for (int y = 0; y < H / 2; y++) fwrite(m + img.offsets[1] + (size_t)y * img.pitches[1], 1, W, rf);
        fclose(rf);
        CHECK(vaUnmapBuffer(S.va, img.buf));
        printf("{\"ev\":\"refdump\",\"frame_index\":%ld,\"file\":\"%s\"}\n", R.last_enc_index, refdump);
    }
    lock();
    pw_stream_disconnect(S.stream);
    pw_stream_destroy(S.stream);
    unlock();
    if (threaded) { pw_thread_loop_stop(S.tl); pw_thread_loop_destroy(S.tl); }
    else pw_main_loop_destroy(S.loop);
    pw_deinit();
    return 0;
}
