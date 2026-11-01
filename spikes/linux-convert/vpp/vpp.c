// Speedup spike, candidate "vpp": BGRx -> NV12 at 2752x2064 through Mesa's VA video processing
// (VAProfileNone / VAEntrypointVideoProc), called straight through libva with no GStreamer, to find out
// whether the 3.5-7 ms GStreamer's vapostproc showed in spike A is the driver's cost or GStreamer's.
//
// Input: a ring of BGRx frames with scrolling-text content, either GBM buffer objects on the AMD node with
// Mutter's modifier (0x0200000000401b03, or LINEAR) imported as VA surfaces through DRM PRIME 2, or
// driver-allocated BGRX VA surfaces. The ring is filled once on the CPU; the timed loop never touches pixels.
// Output: NV12 surfaces created for VPP write and encode; --encode also runs the HEVC encoder on each one
// (CBR 60 Mbps, as spike A's vaenc), which proves the encoder takes them and times convert + encode.
// Correctness: --check reads back the NV12 of several frames and compares with a CPU BT.709 full-range
// reference (Y = 0.2126 R + 0.7152 G + 0.0722 B, Cb = (B - Y) / 1.8556 + 128, Cr = (R - Y) / 1.5748 + 128,
// chroma = mean of each 2x2 block, rounded, clamped).
//
// Opens only the AMD render node (checked by PCI vendor). Run under spikes/linux-encoder/nvidia-guard.sh.
// Build: make     Run: ./vpp --help
#define _GNU_SOURCE
#include <drm_fourcc.h>
#include <fcntl.h>
#include <gbm.h>
#include <math.h>
#include <pthread.h>
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

#define CHECK(x)                                                                                    \
    do {                                                                                            \
        VAStatus s_ = (x);                                                                          \
        if (s_ != VA_STATUS_SUCCESS) {                                                              \
            fprintf(stderr, "%s:%d %s failed: %s\n", __FILE__, __LINE__, #x, vaErrorStr(s_));       \
            exit(1);                                                                                \
        }                                                                                           \
    } while (0)

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static uint64_t cpu_ns(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return (ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000000000ull +
           (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) * 1000ull;
}

static uint64_t hash64(uint64_t a) {
    uint64_t x = a * 0x9E3779B97F4A7C15ull;
    x ^= x >> 29;
    x *= 0xBF58476D1CE4E5B9ull;
    return x ^ (x >> 32);
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

static void summary(const char *label, uint64_t *v, int n) {
    if (n == 0) {
        printf("  %s: none\n", label);
        return;
    }
    qsort(v, n, sizeof *v, cmp_u64);
    double sum = 0;
    for (int i = 0; i < n; i++) sum += v[i];
#define P(q) (v[(int)((n - 1) * (q) + 0.5)] / 1e6)
    printf("  %s: n=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f mean=%.3f ms\n", label, n, P(0.5), P(0.95), P(0.99),
           v[n - 1] / 1e6, sum / n / 1e6);
#undef P
}

static void loadavg(const char *when) {
    char buf[128] = {0};
    FILE *f = fopen("/proc/loadavg", "r");
    if (f) {
        if (!fgets(buf, sizeof buf, f)) buf[0] = 0;
        fclose(f);
    }
    buf[strcspn(buf, "\n")] = 0;
    printf("loadavg %s: %s\n", when, buf);
}

// ---- GPU busy sampling (amdgpu's gpu_busy_percent of the AMD card, every 5 ms) ----
static char busy_path[256];
static volatile int busy_run;
static double busy_sum;
static int busy_n, busy_max;
static void *busy_thread(void *arg) {
    (void)arg;
    while (busy_run) {
        FILE *f = fopen(busy_path, "r");
        int v;
        if (f) {
            if (fscanf(f, "%d", &v) == 1) {
                busy_sum += v;
                busy_n++;
                if (v > busy_max) busy_max = v;
            }
            fclose(f);
        }
        usleep(5000);
    }
    return NULL;
}
static pthread_t busy_tid;
static void busy_start(void) {
    busy_sum = 0;
    busy_n = busy_max = 0;
    busy_run = 1;
    pthread_create(&busy_tid, NULL, busy_thread, NULL);
}
static void busy_stop(const char *label) {
    busy_run = 0;
    pthread_join(busy_tid, NULL);
    printf("gpu_busy_percent %s: mean %.0f%%, max %d%% (%d samples)\n", label, busy_n ? busy_sum / busy_n : 0,
           busy_max, busy_n);
}

// ---- Content: a scrolling terminal, BGRx, periodic every `period` rows ----
// Dark purple background, rows of glyph-sized high-frequency blobs in six colours, among them pure red,
// pure blue and white so the conversion's clamping and extremes are exercised.
static const uint8_t palette[6][3] = {// R, G, B
                                      {255, 255, 255}, {255, 0, 0}, {0, 0, 255}, {80, 220, 120}, {250, 200, 60},
                                      {120, 160, 255}};
static void gen_bgrx(uint8_t *dst, size_t pitch, int w, int h, int offset, int period) {
    for (int y = 0; y < h; y++) {
        int ty = (y + offset) % period, line = ty / 18, gy = ty % 18;
        int len = 40 + (int)(hash64(line * 7ull + 1) % 300);
        uint8_t *row = dst + (size_t)y * pitch;
        for (int x = 0; x < w; x++) {
            int col = x / 9, gx = x % 9;
            uint8_t r = 30, g = 16, b = 44;
            if (col < len && gy >= 1 && gy < 15 && gx < 8) {
                uint64_t gh = hash64(((uint64_t)line << 20) | col);
                int bit = (gy - 1) / 2 * 4 + gx / 2;
                if (gh % 7 && ((gh >> (bit % 64)) & 1)) {
                    const uint8_t *c = palette[hash64(line * 31ull + col / 12) % 6];
                    r = c[0], g = c[1], b = c[2];
                }
            }
            row[4 * x + 0] = b;
            row[4 * x + 1] = g;
            row[4 * x + 2] = r;
            row[4 * x + 3] = 0xff;
        }
    }
}

// ---- CPU reference and comparison ----
static uint8_t clamp_round(double v) { return v <= 0 ? 0 : v >= 255 ? 255 : (uint8_t)lrint(v); }
typedef struct {
    int maxe[3];
    double sum[3];
    long n[3];
    long hist[3][4]; // |err| = 0, 1, 2, >2
} errs;
static void compare(const uint8_t *bgrx, int w, int h, const uint8_t *yp, size_t ypitch, const uint8_t *uvp,
                    size_t uvpitch, errs *e) {
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            const uint8_t *p = bgrx + ((size_t)y * w + x) * 4;
            double Y = 0.2126 * p[2] + 0.7152 * p[1] + 0.0722 * p[0];
            int d = abs((int)yp[(size_t)y * ypitch + x] - clamp_round(Y));
            if (d > e->maxe[0]) e->maxe[0] = d;
            e->sum[0] += d;
            e->n[0]++;
            e->hist[0][d > 2 ? 3 : d]++;
        }
    for (int y = 0; y < h / 2; y++)
        for (int x = 0; x < w / 2; x++) {
            double cb = 0, cr = 0;
            for (int dy = 0; dy < 2; dy++)
                for (int dx = 0; dx < 2; dx++) {
                    const uint8_t *p = bgrx + ((size_t)(2 * y + dy) * w + 2 * x + dx) * 4;
                    double Y = 0.2126 * p[2] + 0.7152 * p[1] + 0.0722 * p[0];
                    cb += (p[0] - Y) / 1.8556 + 128;
                    cr += (p[2] - Y) / 1.5748 + 128;
                }
            int dcb = abs((int)uvp[(size_t)y * uvpitch + 2 * x] - clamp_round(cb / 4));
            int dcr = abs((int)uvp[(size_t)y * uvpitch + 2 * x + 1] - clamp_round(cr / 4));
            if (dcb > e->maxe[1]) e->maxe[1] = dcb;
            if (dcr > e->maxe[2]) e->maxe[2] = dcr;
            e->sum[1] += dcb;
            e->sum[2] += dcr;
            e->n[1]++;
            e->n[2]++;
            e->hist[1][dcb > 2 ? 3 : dcb]++;
            e->hist[2][dcr > 2 ? 3 : dcr]++;
        }
}

// Prints the first few pixels whose error exceeds `lim`, for diagnosis.
static void show_outliers(const uint8_t *bgrx, int w, int h, const uint8_t *yp, size_t ypitch, const uint8_t *uvp,
                          size_t uvpitch, int lim) {
    int shown = 0;
    for (int y = 0; y < h / 2 && shown < 6; y++)
        for (int x = 0; x < w / 2 && shown < 6; x++) {
            double cb = 0, cr = 0;
            int px[4][3];
            for (int k = 0; k < 4; k++) {
                const uint8_t *p = bgrx + ((size_t)(2 * y + k / 2) * w + 2 * x + k % 2) * 4;
                double Y = 0.2126 * p[2] + 0.7152 * p[1] + 0.0722 * p[0];
                cb += (p[0] - Y) / 1.8556 + 128;
                cr += (p[2] - Y) / 1.5748 + 128;
                px[k][0] = p[2], px[k][1] = p[1], px[k][2] = p[0];
            }
            int gcb = uvp[(size_t)y * uvpitch + 2 * x], gcr = uvp[(size_t)y * uvpitch + 2 * x + 1];
            if (abs(gcb - clamp_round(cb / 4)) > lim || abs(gcr - clamp_round(cr / 4)) > lim) {
                printf("    chroma outlier at (%d,%d): got Cb %d Cr %d, want %d %d; RGB", 2 * x, 2 * y, gcb, gcr,
                       clamp_round(cb / 4), clamp_round(cr / 4));
                for (int k = 0; k < 4; k++) printf(" (%d,%d,%d)", px[k][0], px[k][1], px[k][2]);
                printf("; Y row0 %d %d\n", yp[(size_t)2 * y * ypitch + 2 * x], yp[(size_t)2 * y * ypitch + 2 * x + 1]);
                shown++;
            }
        }
}

// ---- HEVC encode of one NV12 surface (spike A's vaenc settings: CBR 60 Mbps, two-frame HRD) ----
typedef struct {
    VAConfigID cfg;
    VAContextID ctx;
    VASurfaceID recon[2];
    VABufferID coded;
    int w, h, fps, poc, cur;
    unsigned kbps;
} encoder;

static VABufferID make_buf(VADisplay dpy, VAContextID ctx, VABufferType type, unsigned size, void *data) {
    VABufferID id;
    CHECK(vaCreateBuffer(dpy, ctx, type, size, 1, data, &id));
    return id;
}

static VABufferID misc_buf(VADisplay dpy, VAContextID ctx, VAEncMiscParameterType type, void *data, unsigned size) {
    VABufferID id;
    CHECK(vaCreateBuffer(dpy, ctx, VAEncMiscParameterBufferType, sizeof(VAEncMiscParameterBuffer) + size, 1, NULL,
                         &id));
    VAEncMiscParameterBuffer *m;
    CHECK(vaMapBuffer(dpy, id, (void **)&m));
    m->type = type;
    memcpy(m->data, data, size);
    CHECK(vaUnmapBuffer(dpy, id));
    return id;
}

static void enc_init(VADisplay dpy, encoder *e, int w, int h, int fps) {
    *e = (encoder){.w = w, .h = h, .fps = fps ? fps : 120, .kbps = 60000};
    VAConfigAttrib a[2] = {{VAConfigAttribRTFormat, VA_RT_FORMAT_YUV420}, {VAConfigAttribRateControl, VA_RC_CBR}};
    CHECK(vaCreateConfig(dpy, VAProfileHEVCMain, VAEntrypointEncSlice, a, 2, &e->cfg));
    CHECK(vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, w, h, e->recon, 2, NULL, 0));
    CHECK(vaCreateContext(dpy, e->cfg, w, h, VA_PROGRESSIVE, e->recon, 2, &e->ctx));
    CHECK(vaCreateBuffer(dpy, e->ctx, VAEncCodedBufferType, w * h * 3 / 2, 1, NULL, &e->coded));
}

// Encodes `src`; returns the AU size; *t_end is set after vaEndPicture.
static size_t enc_frame(VADisplay dpy, encoder *e, VASurfaceID src, FILE *out, uint64_t *t_end) {
    int idr = e->poc == 0, w = e->w, h = e->h, ctus = ((w + 63) / 64) * ((h + 63) / 64);
    VABufferID bufs[8];
    int nb = 0;
    if (idr) {
        VAEncSequenceParameterBufferHEVC seq = {0};
        seq.general_profile_idc = 1;
        seq.general_level_idc = 153;
        seq.ip_period = 1;
        seq.bits_per_second = e->kbps * 1000;
        seq.pic_width_in_luma_samples = w;
        seq.pic_height_in_luma_samples = h;
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
        bufs[nb++] = make_buf(dpy, e->ctx, VAEncSequenceParameterBufferType, sizeof seq, &seq);
    }
    VAEncMiscParameterRateControl rc = {.bits_per_second = e->kbps * 1000, .target_percentage = 100,
                                        .window_size = 1000, .initial_qp = 26, .min_qp = 1, .max_qp = 51};
    bufs[nb++] = misc_buf(dpy, e->ctx, VAEncMiscParameterTypeRateControl, &rc, sizeof rc);
    VAEncMiscParameterFrameRate fr = {.framerate = e->fps};
    bufs[nb++] = misc_buf(dpy, e->ctx, VAEncMiscParameterTypeFrameRate, &fr, sizeof fr);
    VAEncMiscParameterHRD hrd = {.initial_buffer_fullness = e->kbps * 1000 / e->fps,
                                 .buffer_size = e->kbps * 1000 / e->fps * 2};
    bufs[nb++] = misc_buf(dpy, e->ctx, VAEncMiscParameterTypeHRD, &hrd, sizeof hrd);
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
    bufs[nb++] = make_buf(dpy, e->ctx, VAEncPictureParameterBufferType, sizeof pic, &pic);
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
    bufs[nb++] = make_buf(dpy, e->ctx, VAEncSliceParameterBufferType, sizeof sl, &sl);
    CHECK(vaBeginPicture(dpy, e->ctx, src));
    CHECK(vaRenderPicture(dpy, e->ctx, bufs, nb));
    CHECK(vaEndPicture(dpy, e->ctx));
    *t_end = now_ns();
    CHECK(vaSyncBuffer(dpy, e->coded, VA_TIMEOUT_INFINITE));
    VACodedBufferSegment *seg;
    CHECK(vaMapBuffer(dpy, e->coded, (void **)&seg));
    size_t size = 0;
    for (VACodedBufferSegment *s = seg; s; s = s->next) {
        if (out) fwrite(s->buf, 1, s->size, out);
        size += s->size;
    }
    CHECK(vaUnmapBuffer(dpy, e->coded));
    for (int i = 0; i < nb; i++) vaDestroyBuffer(dpy, bufs[i]);
    e->poc++;
    e->cur ^= 1;
    return size;
}

// Refuses to go on if a buffer's geometry can't hold a w x h plane of `bpp` bytes per pixel.
static void check_plane(const char *what, size_t size, size_t offset, size_t pitch, int w, int h, int bpp) {
    if (pitch < (size_t)w * bpp || offset > size || (size_t)h * pitch > size - offset) {
        fprintf(stderr, "validation: %s too small: size %zu, offset %zu, pitch %zu for %dx%d x%d bytes\n", what, size,
                offset, pitch, w, h, bpp);
        exit(1);
    }
}

static void usage(void) {
    puts("vpp [--device /dev/dri/by-path/pci-0000:79:00.0-render] [--width 2752] [--height 2064]\n"
         "    [--src gbm|gbm-linear|va] (input: GBM BOs with Mutter's modifier, GBM LINEAR, or driver BGRX surfaces)\n"
         "    [--ring 8] [--seconds 2] [--fps 120 (0 = back to back)] [--inflight 1]\n"
         "    [--filter default|fast|hq|nearest|bilinear] [--pipeline-fast]\n"
         "    [--out-std bt709|bt601|explicit|none] [--range full|limited|none] [--in-std srgb|bt709|explicit|none]\n"
         "    [--siting center|left|none] [--sync surface|surface2]\n"
         "    [--check 3 (frames compared with the CPU reference; 0 = none)] [--encode] [--dump out.h265] [--query]");
}

int main(int argc, char **argv) {
    const char *device = "/dev/dri/by-path/pci-0000:79:00.0-render", *src_kind = "gbm", *filter = "default";
    const char *out_std = "bt709", *range = "full", *in_std = "srgb", *siting = "center", *sync_kind = "surface";
    const char *dump = NULL;
    int w = 2752, h = 2064, ring_n = 8, fps = 120, inflight = 1, nchecks = 3, do_encode = 0, query_only = 0;
    int pipeline_fast = 0;
    double seconds = 2;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
#define OPT(name, stmt) else if (!strcmp(a, name)) { stmt; i++; }
        if (!strcmp(a, "--help")) { usage(); return 0; }
        else if (!strcmp(a, "--query")) query_only = 1;
        else if (!strcmp(a, "--encode")) do_encode = 1;
        else if (!strcmp(a, "--pipeline-fast")) pipeline_fast = 1;
        OPT("--device", device = v) OPT("--width", w = atoi(v)) OPT("--height", h = atoi(v))
        OPT("--src", src_kind = v) OPT("--ring", ring_n = atoi(v)) OPT("--seconds", seconds = atof(v))
        OPT("--fps", fps = atoi(v)) OPT("--inflight", inflight = atoi(v)) OPT("--filter", filter = v)
        OPT("--out-std", out_std = v) OPT("--range", range = v) OPT("--in-std", in_std = v)
        OPT("--siting", siting = v) OPT("--sync", sync_kind = v) OPT("--check", nchecks = atoi(v))
        OPT("--dump", dump = v)
        else { usage(); return 2; }
#undef OPT
    }
    if (w < 16 || h < 16 || w > 8192 || h > 4352 || (w | h) & 1 || ring_n < 1 || ring_n > 64 || seconds > 10) {
        fprintf(stderr, "validation: need even 16..8192 x 16..4352, ring 1..64, seconds <= 10\n");
        return 2;
    }
    if (inflight < 1) inflight = 1;
    if (inflight > ring_n) ring_n = inflight;

    // Never an NVIDIA device: resolve the node and check its PCI vendor before opening it.
    char real[4096], path[4200], vendor[16] = {0};
    if (!realpath(device, real)) { perror(device); return 1; }
    snprintf(path, sizeof path, "/sys/class/drm/%s/device/vendor", strrchr(real, '/') + 1);
    FILE *vf = fopen(path, "r");
    if (!vf || !fgets(vendor, sizeof vendor, vf) || strncmp(vendor, "0x1002", 6)) {
        fprintf(stderr, "%s (%s) is not the AMD GPU (vendor %s)\n", device, real, vendor);
        return 1;
    }
    fclose(vf);
    snprintf(busy_path, sizeof busy_path, "/sys/class/drm/%s/device/gpu_busy_percent", strrchr(real, '/') + 1);
    loadavg("before");
    int fd = open(real, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror(real); return 1; }
    VADisplay dpy = vaGetDisplayDRM(fd);
    int major, minor;
    CHECK(vaInitialize(dpy, &major, &minor));
    printf("device %s (%s): VA-API %d.%d, %s\n", device, real, major, minor, vaQueryVendorString(dpy));

    // VPP capabilities.
    VAConfigID vcfg;
    CHECK(vaCreateConfig(dpy, VAProfileNone, VAEntrypointVideoProc, NULL, 0, &vcfg));
    {
        unsigned nsa = 0;
        vaQuerySurfaceAttributes(dpy, vcfg, NULL, &nsa);
        VASurfaceAttrib *sa = calloc(nsa, sizeof *sa);
        vaQuerySurfaceAttributes(dpy, vcfg, sa, &nsa);
        printf("  vpp surface formats:");
        for (unsigned i = 0; i < nsa; i++)
            if (sa[i].type == VASurfaceAttribPixelFormat) printf(" %.4s", (char *)&sa[i].value.value.i);
            else if (sa[i].type == VASurfaceAttribMemoryType) printf(" [mem 0x%x]", sa[i].value.value.i);
        printf("\n");
        free(sa);
    }

    // Input ring.
    size_t frame_bytes = (size_t)w * h * 4;
    uint8_t *ref = malloc(frame_bytes); // scratch for generating and for the reference
    VASurfaceID *in = calloc(ring_n, sizeof *in);
    struct gbm_device *gbm = NULL;
    struct gbm_bo **bos = calloc(ring_n, sizeof *bos);
    int step = 18, period = ring_n * step;
    uint64_t t = now_ns();
    if (!strncmp(src_kind, "gbm", 3)) {
        gbm = gbm_create_device(fd);
        if (!gbm) { fprintf(stderr, "gbm_create_device failed\n"); return 1; }
        uint64_t mod = !strcmp(src_kind, "gbm-linear") ? DRM_FORMAT_MOD_LINEAR : 0x0200000000401b03ull;
        for (int i = 0; i < ring_n; i++) {
            bos[i] = gbm_bo_create_with_modifiers2(gbm, w, h, GBM_FORMAT_XRGB8888, &mod, 1, GBM_BO_USE_RENDERING);
            if (!bos[i]) { fprintf(stderr, "gbm_bo_create_with_modifiers2 (mod 0x%llx) failed\n", (unsigned long long)mod); return 1; }
            int planes = gbm_bo_get_plane_count(bos[i]);
            uint64_t got = gbm_bo_get_modifier(bos[i]);
            if (i == 0)
                printf("  gbm bo: modifier 0x%016llx, %d plane(s), stride %u, offset %u\n", (unsigned long long)got,
                       planes, gbm_bo_get_stride_for_plane(bos[i], 0), gbm_bo_get_offset(bos[i], 0));
            if (got != mod || planes != 1 || gbm_bo_get_width(bos[i]) != (uint32_t)w ||
                gbm_bo_get_height(bos[i]) != (uint32_t)h) {
                fprintf(stderr, "validation: gbm bo is %ux%u, modifier 0x%llx, %d planes; wanted %dx%d, 0x%llx, 1 plane\n",
                        gbm_bo_get_width(bos[i]), gbm_bo_get_height(bos[i]), (unsigned long long)got, planes, w, h,
                        (unsigned long long)mod);
                return 1;
            }
            // Fill through a GBM map (radeonsi blits a linear staging copy into the tiled BO on unmap).
            uint32_t stride;
            void *map_data = NULL;
            uint8_t *p = gbm_bo_map(bos[i], 0, 0, w, h, GBM_BO_TRANSFER_WRITE, &stride, &map_data);
            if (!p) { fprintf(stderr, "gbm_bo_map failed\n"); return 1; }
            if (stride < (uint32_t)w * 4) { fprintf(stderr, "validation: map stride %u < %d\n", stride, w * 4); return 1; }
            gen_bgrx(p, stride, w, h, i * step, period);
            gbm_bo_unmap(bos[i], map_data);
            // Import as a VA surface through DRM PRIME 2.
            VADRMPRIMESurfaceDescriptor d = {0};
            d.fourcc = VA_FOURCC_BGRX;
            d.width = w;
            d.height = h;
            d.num_objects = 1;
            d.objects[0].fd = gbm_bo_get_fd(bos[i]);
            off_t fsize = d.objects[0].fd >= 0 ? lseek(d.objects[0].fd, 0, SEEK_END) : -1;
            if (fsize <= 0 || fsize > 0xffffffffll) { fprintf(stderr, "validation: dma-buf size %lld\n", (long long)fsize); return 1; }
            d.objects[0].size = (uint32_t)fsize;
            // A tiled BO's pitch is the padded row pitch; offset + pitch * height must fit in the dma-buf.
            check_plane("gbm dma-buf", fsize, gbm_bo_get_offset(bos[i], 0), gbm_bo_get_stride_for_plane(bos[i], 0), w, h, 4);
            d.objects[0].drm_format_modifier = got;
            d.num_layers = 1;
            d.layers[0].drm_format = DRM_FORMAT_XRGB8888;
            d.layers[0].num_planes = planes;
            for (int pl = 0; pl < planes; pl++) {
                d.layers[0].object_index[pl] = 0;
                d.layers[0].offset[pl] = gbm_bo_get_offset(bos[i], pl);
                d.layers[0].pitch[pl] = gbm_bo_get_stride_for_plane(bos[i], pl);
            }
            VASurfaceAttrib sa[2] = {
                {.type = VASurfaceAttribMemoryType, .flags = VA_SURFACE_ATTRIB_SETTABLE,
                 .value = {.type = VAGenericValueTypeInteger, .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2}},
                {.type = VASurfaceAttribExternalBufferDescriptor, .flags = VA_SURFACE_ATTRIB_SETTABLE,
                 .value = {.type = VAGenericValueTypePointer, .value.p = &d}},
            };
            CHECK(vaCreateSurfaces(dpy, VA_RT_FORMAT_RGB32, w, h, &in[i], 1, sa, 2));
            close(d.objects[0].fd);
        }
    } else {
        VASurfaceAttrib sa[2] = {
            {.type = VASurfaceAttribPixelFormat, .flags = VA_SURFACE_ATTRIB_SETTABLE,
             .value = {.type = VAGenericValueTypeInteger, .value.i = VA_FOURCC_BGRX}},
            {.type = VASurfaceAttribUsageHint, .flags = VA_SURFACE_ATTRIB_SETTABLE,
             .value = {.type = VAGenericValueTypeInteger, .value.i = VA_SURFACE_ATTRIB_USAGE_HINT_VPP_READ}},
        };
        CHECK(vaCreateSurfaces(dpy, VA_RT_FORMAT_RGB32, w, h, in, ring_n, sa, 2));
        VAImageFormat fmt = {.fourcc = VA_FOURCC_BGRX, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 32,
                             .depth = 24, .red_mask = 0xff0000, .green_mask = 0xff00, .blue_mask = 0xff};
        VAImage img;
        CHECK(vaCreateImage(dpy, &fmt, w, h, &img));
        check_plane("BGRX VAImage", img.data_size, img.offsets[0], img.pitches[0], w, h, 4);
        if (img.width != (unsigned)w || img.height != (unsigned)h) { fprintf(stderr, "validation: image size\n"); return 1; }
        for (int i = 0; i < ring_n; i++) {
            uint8_t *p;
            CHECK(vaMapBuffer(dpy, img.buf, (void **)&p));
            gen_bgrx(p + img.offsets[0], img.pitches[0], w, h, i * step, period);
            CHECK(vaUnmapBuffer(dpy, img.buf));
            CHECK(vaPutImage(dpy, in[i], img.image_id, 0, 0, w, h, 0, 0, w, h));
        }
        CHECK(vaDestroyImage(dpy, img.image_id));
        VADRMPRIMESurfaceDescriptor d = {0};
        if (vaExportSurfaceHandle(dpy, in[0], VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                  VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_COMPOSED_LAYERS, &d) == VA_STATUS_SUCCESS) {
            printf("  driver BGRX surface: modifier 0x%016llx, pitch %u\n",
                   (unsigned long long)d.objects[0].drm_format_modifier, d.layers[0].pitch[0]);
            for (unsigned o = 0; o < d.num_objects; o++) close(d.objects[o].fd);
        }
    }
    CHECK(vaSyncSurface(dpy, in[ring_n - 1]));
    printf("filled %d BGRx %s surfaces in %.0f ms\n", ring_n, src_kind, (now_ns() - t) / 1e6);

    // Output NV12 surfaces, one per conversion in flight.
    VASurfaceID *out = calloc(inflight, sizeof *out);
    {
        VASurfaceAttrib sa[2] = {
            {.type = VASurfaceAttribPixelFormat, .flags = VA_SURFACE_ATTRIB_SETTABLE,
             .value = {.type = VAGenericValueTypeInteger, .value.i = VA_FOURCC_NV12}},
            {.type = VASurfaceAttribUsageHint, .flags = VA_SURFACE_ATTRIB_SETTABLE,
             .value = {.type = VAGenericValueTypeInteger,
                       .value.i = VA_SURFACE_ATTRIB_USAGE_HINT_VPP_WRITE | VA_SURFACE_ATTRIB_USAGE_HINT_ENCODER}},
        };
        CHECK(vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, w, h, out, inflight, sa, 2));
        VADRMPRIMESurfaceDescriptor d = {0};
        if (vaExportSurfaceHandle(dpy, out[0], VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                  VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS, &d) == VA_STATUS_SUCCESS) {
            printf("  NV12 output surface: modifier 0x%016llx, Y pitch %u, UV pitch %u\n",
                   (unsigned long long)d.objects[0].drm_format_modifier, d.layers[0].pitch[0], d.layers[1].pitch[0]);
            for (unsigned o = 0; o < d.num_objects; o++) close(d.objects[o].fd);
        }
    }
    VAContextID vctx;
    CHECK(vaCreateContext(dpy, vcfg, w, h, VA_PROGRESSIVE, out, inflight, &vctx));
    {
        VAProcPipelineCaps caps = {0};
        VAProcColorStandardType ins[VAProcColorStandardCount], outs[VAProcColorStandardCount];
        caps.input_color_standards = ins;
        caps.num_input_color_standards = VAProcColorStandardCount;
        caps.output_color_standards = outs;
        caps.num_output_color_standards = VAProcColorStandardCount;
        if (vaQueryVideoProcPipelineCaps(dpy, vctx, NULL, 0, &caps) == VA_STATUS_SUCCESS) {
            printf("  pipeline caps: input standards");
            for (unsigned i = 0; i < caps.num_input_color_standards; i++) printf(" %d", ins[i]);
            printf("; output standards");
            for (unsigned i = 0; i < caps.num_output_color_standards; i++) printf(" %d", outs[i]);
            printf("; pipeline_flags 0x%x filter_flags 0x%x\n", caps.pipeline_flags, caps.filter_flags);
        }
    }
    if (query_only) return 0;

    encoder enc;
    FILE *dumpf = dump ? fopen(dump, "wb") : NULL;
    if (do_encode) enc_init(dpy, &enc, w, h, fps);

    // The pipeline parameters.
    VAProcPipelineParameterBuffer pp = {0};
    pp.output_background_color = 0xff000000;
    pp.filter_flags = !strcmp(filter, "fast")       ? VA_FILTER_SCALING_FAST
                      : !strcmp(filter, "hq")       ? VA_FILTER_SCALING_HQ
                      : !strcmp(filter, "nearest")  ? VA_FILTER_INTERPOLATION_NEAREST_NEIGHBOR
                      : !strcmp(filter, "bilinear") ? VA_FILTER_INTERPOLATION_BILINEAR
                                                    : VA_FILTER_SCALING_DEFAULT;
    if (pipeline_fast) pp.pipeline_flags |= VA_PROC_PIPELINE_FAST;
    pp.surface_color_standard = !strcmp(in_std, "srgb")       ? VAProcColorStandardSRGB
                                : !strcmp(in_std, "bt709")    ? VAProcColorStandardBT709
                                : !strcmp(in_std, "explicit") ? VAProcColorStandardExplicit
                                                              : VAProcColorStandardNone;
    pp.input_color_properties.color_range = VA_SOURCE_RANGE_FULL;
    if (pp.surface_color_standard == VAProcColorStandardExplicit) {
        pp.input_color_properties.colour_primaries = 1;
        pp.input_color_properties.transfer_characteristics = 13;
        pp.input_color_properties.matrix_coefficients = 0; // identity (RGB)
    }
    pp.output_color_standard = !strcmp(out_std, "bt709")      ? VAProcColorStandardBT709
                               : !strcmp(out_std, "bt601")    ? VAProcColorStandardBT601
                               : !strcmp(out_std, "explicit") ? VAProcColorStandardExplicit
                                                              : VAProcColorStandardNone;
    pp.output_color_properties.color_range = !strcmp(range, "full")      ? VA_SOURCE_RANGE_FULL
                                             : !strcmp(range, "limited") ? VA_SOURCE_RANGE_REDUCED
                                                                         : VA_SOURCE_RANGE_UNKNOWN;
    pp.output_color_properties.chroma_sample_location =
        !strcmp(siting, "center") ? VA_CHROMA_SITING_VERTICAL_CENTER | VA_CHROMA_SITING_HORIZONTAL_CENTER
        : !strcmp(siting, "left") ? VA_CHROMA_SITING_VERTICAL_CENTER | VA_CHROMA_SITING_HORIZONTAL_LEFT
                                  : VA_CHROMA_SITING_UNKNOWN;
    if (pp.output_color_standard == VAProcColorStandardExplicit) {
        pp.output_color_properties.colour_primaries = 1;
        pp.output_color_properties.transfer_characteristics = 13;
        pp.output_color_properties.matrix_coefficients = 1;
    }
    int use_sync2 = !strcmp(sync_kind, "surface2");
    printf("config: src %s, filter %s%s, in-std %s, out-std %s, range %s, siting %s, sync %s, inflight %d, fps %d%s\n",
           src_kind, filter, pipeline_fast ? " +pipeline-fast" : "", in_std, out_std, range, siting, sync_kind,
           inflight, fps, do_encode ? ", encode" : "");

    // One conversion: Begin/Render/End; returns the time after vaEndPicture.
    VABufferID ppbuf;
    CHECK(vaCreateBuffer(dpy, vctx, VAProcPipelineParameterBufferType, sizeof pp, 1, NULL, &ppbuf));
#define SUBMIT(src, dst, t_begin, t_end)                                                                   \
    do {                                                                                                  \
        pp.surface = (src);                                                                               \
        VAProcPipelineParameterBuffer *m_;                                                                \
        t_begin = now_ns();                                                                               \
        CHECK(vaMapBuffer(dpy, ppbuf, (void **)&m_));                                                     \
        *m_ = pp;                                                                                         \
        CHECK(vaUnmapBuffer(dpy, ppbuf));                                                                 \
        CHECK(vaBeginPicture(dpy, vctx, (dst)));                                                          \
        CHECK(vaRenderPicture(dpy, vctx, &ppbuf, 1));                                                     \
        CHECK(vaEndPicture(dpy, vctx));                                                                   \
        t_end = now_ns();                                                                                 \
    } while (0)
#define SYNC(s)                                                                                           \
    do {                                                                                                  \
        if (use_sync2) CHECK(vaSyncSurface2(dpy, (s), VA_TIMEOUT_INFINITE));                              \
        else CHECK(vaSyncSurface(dpy, (s)));                                                              \
    } while (0)

    // Correctness first (also warms up): convert frames 0, ring/3, 2*ring/3 and read them back.
    if (nchecks > 0) {
        VAImageFormat nv12 = {.fourcc = VA_FOURCC_NV12, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12};
        VAImage img;
        CHECK(vaCreateImage(dpy, &nv12, w, h, &img));
        if (img.num_planes != 2 || img.width != (unsigned)w || img.height != (unsigned)h) {
            fprintf(stderr, "validation: NV12 image has %u planes, %ux%u\n", img.num_planes, img.width, img.height);
            return 1;
        }
        check_plane("NV12 image Y", img.data_size, img.offsets[0], img.pitches[0], w, h, 1);
        check_plane("NV12 image UV", img.data_size, img.offsets[1], img.pitches[1], w / 2, h / 2, 2);
        errs all = {0};
        for (int c = 0; c < nchecks; c++) {
            int k = (c * ring_n / nchecks) % ring_n;
            uint64_t tb __attribute__((unused)), te __attribute__((unused));
            SUBMIT(in[k], out[0], tb, te);
            SYNC(out[0]);
            CHECK(vaGetImage(dpy, out[0], 0, 0, w, h, img.image_id));
            uint8_t *p;
            CHECK(vaMapBuffer(dpy, img.buf, (void **)&p));
            gen_bgrx(ref, (size_t)w * 4, w, h, k * step, period);
            errs e = {0};
            compare(ref, w, h, p + img.offsets[0], img.pitches[0], p + img.offsets[1], img.pitches[1], &e);
            printf("check frame %d: Y max %d mean %.4f | Cb max %d mean %.4f | Cr max %d mean %.4f "
                   "(|err| 0/1/2/>2: Y %ld/%ld/%ld/%ld Cb %ld/%ld/%ld/%ld Cr %ld/%ld/%ld/%ld)\n",
                   k, e.maxe[0], e.sum[0] / e.n[0], e.maxe[1], e.sum[1] / e.n[1], e.maxe[2], e.sum[2] / e.n[2],
                   e.hist[0][0], e.hist[0][1], e.hist[0][2], e.hist[0][3], e.hist[1][0], e.hist[1][1], e.hist[1][2],
                   e.hist[1][3], e.hist[2][0], e.hist[2][1], e.hist[2][2], e.hist[2][3]);
            if (c == 0) {
                // A few raw samples: the background, and the first outliers.
                printf("    background pixel (0,0): Y %d Cb %d Cr %d (reference %d %d %d)\n", p[img.offsets[0]],
                       p[img.offsets[1]], p[img.offsets[1] + 1], clamp_round(0.2126 * 30 + 0.7152 * 16 + 0.0722 * 44),
                       clamp_round((44 - (0.2126 * 30 + 0.7152 * 16 + 0.0722 * 44)) / 1.8556 + 128),
                       clamp_round((30 - (0.2126 * 30 + 0.7152 * 16 + 0.0722 * 44)) / 1.5748 + 128));
                if (e.maxe[1] > 1 || e.maxe[2] > 1)
                    show_outliers(ref, w, h, p + img.offsets[0], img.pitches[0], p + img.offsets[1], img.pitches[1], 1);
            }
            CHECK(vaUnmapBuffer(dpy, img.buf));
            for (int pl = 0; pl < 3; pl++) {
                if (e.maxe[pl] > all.maxe[pl]) all.maxe[pl] = e.maxe[pl];
                all.sum[pl] += e.sum[pl];
                all.n[pl] += e.n[pl];
            }
        }
        printf("check overall (%d frames): Y max %d mean %.4f | Cb max %d mean %.4f | Cr max %d mean %.4f\n", nchecks,
               all.maxe[0], all.sum[0] / all.n[0], all.maxe[1], all.sum[1] / all.n[1], all.maxe[2],
               all.sum[2] / all.n[2]);
        CHECK(vaDestroyImage(dpy, img.image_id));
    }
    if (do_encode) {
        // Prove the encoder takes the VPP output: one IDR from a converted frame.
        uint64_t tb __attribute__((unused)), te __attribute__((unused));
        SUBMIT(in[0], out[0], tb, te);
        SYNC(out[0]);
        size_t sz = enc_frame(dpy, &enc, out[0], dumpf, &te);
        printf("encoder accepted the VPP NV12 surface: first AU (IDR) %zu bytes\n", sz);
    }
    if (seconds <= 0) return 0;

    // Timed run. Paced (--fps N): every tick takes the newest ring frame; with inflight K the K conversions
    // of a tick go out back to back (K consecutive ring frames) and are then synced in order. --fps 0 runs
    // back to back for throughput.
    int max_conv = (int)(seconds * (fps ? fps : 2000)) * inflight + 16;
    uint64_t *lat = calloc(max_conv, 8), *sub = calloc(max_conv, 8), *batch = calloc(max_conv, 8);
    uint64_t *elat = calloc(max_conv, 8), *total = calloc(max_conv, 8);
    uint64_t *t_end = calloc(inflight, 8);
    int n_lat = 0, n_batch = 0, n_enc = 0, conversions = 0, skipped = 0, ring_pos = 0;
    long last_tick = -1;
    uint64_t period_ns = fps ? 1000000000ull / fps : 0, start = now_ns(), cpu0 = cpu_ns();
    uint64_t end = start + (uint64_t)(seconds * 1e9);
    busy_start();
    for (;;) {
        if (fps) {
            long tick = (long)((now_ns() - start) / period_ns);
            if (tick <= last_tick) {
                uint64_t due = start + (last_tick + 1) * period_ns;
                struct timespec ts = {due / 1000000000ull, due % 1000000000ull};
                clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
                tick = (long)((now_ns() - start) / period_ns);
            }
            skipped += last_tick >= 0 ? (int)(tick - last_tick - 1) : 0;
            last_tick = tick;
            ring_pos = (int)(tick % ring_n);
        }
        if (now_ns() >= end || n_lat + inflight > max_conv) break;
        uint64_t b0 = now_ns(), tb;
        for (int k = 0; k < inflight; k++) {
            SUBMIT(in[(ring_pos + k) % ring_n], out[k], tb, t_end[k]);
            sub[n_lat + k] = t_end[k] - tb;
        }
        for (int k = 0; k < inflight; k++) {
            SYNC(out[k]);
            lat[n_lat++] = now_ns() - t_end[k];
        }
        uint64_t b1 = now_ns();
        batch[n_batch++] = b1 - b0;
        conversions += inflight;
        if (do_encode) {
            uint64_t te;
            enc_frame(dpy, &enc, out[inflight - 1], dumpf, &te);
            uint64_t e1 = now_ns();
            elat[n_enc] = e1 - te;
            total[n_enc++] = e1 - b0;
        }
        if (!fps) ring_pos = (ring_pos + inflight) % ring_n;
    }
    uint64_t wall = now_ns() - start, cpu = cpu_ns() - cpu0;
    busy_stop("during the run");
    printf("run: %d conversions in %.2f s = %.1f conversions/s (%d ticks skipped); cpu %.1f%% of one core\n",
           conversions, wall / 1e9, conversions * 1e9 / wall, skipped, cpu * 100.0 / wall);
    summary("vaEndPicture -> sync (per conversion)", lat, n_lat);
    summary("CPU submit (map params + Begin/Render/End)", sub, n_lat);
    if (inflight > 1) {
        summary("batch: first submit -> last sync", batch, n_batch);
        uint64_t s = 0;
        for (int i = 0; i < n_batch; i++) s += batch[i];
        printf("  batch mean per conversion: %.3f ms\n", n_batch ? s / 1e6 / n_batch / inflight : 0);
    }
    if (do_encode) {
        summary("encode: vaEndPicture -> AU mapped", elat, n_enc);
        summary("convert + encode: submit -> AU mapped", total, n_enc);
    }
    loadavg("after");
    if (dumpf) fclose(dumpf);
    return 0;
}
