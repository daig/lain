// Spike A, candidate (c): HEVC Main 4:2:0 8-bit encode straight through libva on the AMD iGPU, with no
// GStreamer in between, to find the hardware floor and what per-frame control libva gives.
//
// A ring of NV12 surfaces with scrolling terminal-like content is filled once on the CPU; the timed loop
// never touches pixels. Each frame: parameter buffers → vaBeginPicture/RenderPicture/EndPicture →
// vaSyncBuffer → vaMapBuffer, one frame at a time (lain's one request outstanding), ticked at --fps.
// All times are CLOCK_MONOTONIC.
//
// Build: make -C vaenc     Run: vaenc/vaenc --help
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_enc_hevc.h>

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
    printf("  %s: n=%d p50=%.2f p95=%.2f p99=%.2f max=%.2f mean=%.2f ms\n", label, n, P(0.5), P(0.95), P(0.99),
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

// Terminal-like content scrolled by `offset` rows, periodic every `period` rows (like encbench's "text").
static void fill_nv12(VADisplay dpy, VASurfaceID surf, int w, int h, int offset, int period) {
    VAImage img;
    CHECK(vaDeriveImage(dpy, surf, &img));
    uint8_t *p;
    CHECK(vaMapBuffer(dpy, img.buf, (void **)&p));
    for (int y = 0; y < h; y++) {
        int ty = (y + offset) % period, line = ty / 18, gy = ty % 18;
        int len = 40 + (int)(hash64(line * 7ull + 1) % 300);
        uint8_t *row = p + img.offsets[0] + (size_t)y * img.pitches[0];
        for (int x = 0; x < w; x++) {
            int col = x / 9, gx = x % 9;
            uint8_t v = 36; // background luma
            if (col < len && gy >= 1 && gy < 15 && gx < 8) {
                uint64_t g = hash64(((uint64_t)line << 20) | col);
                int bit = (gy - 1) / 2 * 4 + gx / 2;
                if (g % 7 && ((g >> (bit % 64)) & 1)) v = 140 + (hash64(line * 31ull + col / 12) % 5) * 22;
            }
            row[x] = v;
        }
    }
    for (int y = 0; y < h / 2; y++) {
        uint8_t *row = p + img.offsets[1] + (size_t)y * img.pitches[1];
        int line = ((2 * y + offset) % period) / 18;
        for (int x = 0; x < w / 2; x++) {
            int c = (int)(hash64(line * 31ull + (2 * x / 9) / 12) % 5);
            row[2 * x] = 128 + (c - 2) * 12;
            row[2 * x + 1] = 136 - (c - 2) * 8;
        }
    }
    CHECK(vaUnmapBuffer(dpy, img.buf));
    CHECK(vaDestroyImage(dpy, img.image_id));
}

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

static void usage(void) {
    puts("vaenc [--device /dev/dri/renderD130] [--width 2752] [--height 2064] [--fps 120] [--seconds 10]\n"
         "      [--rc cbr|cqp] [--bitrate 60000 (kbps)] [--qp 26 (cqp)] [--quality 0..7 (0 = driver default)]\n"
         "      [--idr-every N] [--refine-every N] [--refine-qp Q (qp of refinement re-encodes; cbr: max_qp)]\n"
         "      [--ring 32] [--step 18] [--dump out.h265] [--query]");
}

int main(int argc, char **argv) {
    const char *device = "/dev/dri/renderD130", *rc_name = "cbr", *dump = NULL;
    int w = 2752, h = 2064, fps = 120, qp = 26, quality = 0, idr_every = 0, refine_every = 0, refine_qp = -1;
    int ring_n = 32, step = 18, query_only = 0;
    double seconds = 10;
    unsigned kbps = 60000;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
#define OPT(name, stmt) else if (!strcmp(a, name)) { stmt; i++; }
        if (!strcmp(a, "--help")) { usage(); return 0; }
        else if (!strcmp(a, "--query")) query_only = 1;
        OPT("--device", device = v) OPT("--width", w = atoi(v)) OPT("--height", h = atoi(v)) OPT("--fps", fps = atoi(v))
        OPT("--seconds", seconds = atof(v)) OPT("--rc", rc_name = v) OPT("--bitrate", kbps = atoi(v))
        OPT("--qp", qp = atoi(v)) OPT("--quality", quality = atoi(v)) OPT("--idr-every", idr_every = atoi(v))
        OPT("--refine-every", refine_every = atoi(v)) OPT("--refine-qp", refine_qp = atoi(v))
        OPT("--ring", ring_n = atoi(v)) OPT("--step", step = atoi(v)) OPT("--dump", dump = v)
        else { usage(); return 2; }
#undef OPT
    }
    int cqp = !strcmp(rc_name, "cqp");

    // Never an NVIDIA device: check the render node's PCI vendor.
    char path[256];
    snprintf(path, sizeof path, "/sys/class/drm/%s/device/vendor", strrchr(device, '/') + 1);
    FILE *vf = fopen(path, "r");
    char vendor[16] = {0};
    if (!vf || !fgets(vendor, sizeof vendor, vf) || strncmp(vendor, "0x1002", 6)) {
        fprintf(stderr, "%s is not the AMD GPU (vendor %s)\n", device, vendor);
        return 1;
    }
    fclose(vf);
    loadavg("before");
    int fd = open(device, O_RDWR);
    VADisplay dpy = vaGetDisplayDRM(fd);
    int major, minor;
    CHECK(vaInitialize(dpy, &major, &minor));
    printf("device %s: VA-API %d.%d, %s\n", device, major, minor, vaQueryVendorString(dpy));

    VAConfigAttribType types[] = {
        VAConfigAttribRTFormat, VAConfigAttribRateControl, VAConfigAttribEncPackedHeaders,
        VAConfigAttribEncMaxRefFrames, VAConfigAttribEncQualityRange, VAConfigAttribEncIntraRefresh,
        VAConfigAttribEncROI, VAConfigAttribEncMaxSlices, VAConfigAttribEncSliceStructure,
        VAConfigAttribMaxFrameSize, VAConfigAttribEncHEVCFeatures, VAConfigAttribEncHEVCBlockSizes,
        VAConfigAttribEncTileSupport, VAConfigAttribPredictionDirection,
    };
    VAConfigAttrib attrs[sizeof types / sizeof *types];
    for (unsigned i = 0; i < sizeof types / sizeof *types; i++) attrs[i] = (VAConfigAttrib){.type = types[i]};
    const char *names[] = {"RTFormat", "RateControl", "PackedHeaders", "MaxRefFrames (l0 | l1<<16)", "QualityRange",
                           "IntraRefresh", "ROI", "MaxSlices", "SliceStructure", "MaxFrameSize", "HEVCFeatures",
                           "HEVCBlockSizes", "TileSupport", "PredictionDirection"};
    int nattr = sizeof attrs / sizeof *attrs;
    CHECK(vaGetConfigAttributes(dpy, VAProfileHEVCMain, VAEntrypointEncSlice, attrs, nattr));
    for (int i = 0; i < nattr; i++)
        printf("  attr %-26s = %s0x%x\n", names[i], attrs[i].value == VA_ATTRIB_NOT_SUPPORTED ? "unsupported " : "",
               attrs[i].value);

    VAConfigAttrib cfg_attrs[2] = {{VAConfigAttribRTFormat, VA_RT_FORMAT_YUV420},
                                   {VAConfigAttribRateControl, cqp ? VA_RC_CQP : VA_RC_CBR}};
    VAConfigID cfg;
    CHECK(vaCreateConfig(dpy, VAProfileHEVCMain, VAEntrypointEncSlice, cfg_attrs, 2, &cfg));
    unsigned nsa = 0;
    vaQuerySurfaceAttributes(dpy, cfg, NULL, &nsa);
    VASurfaceAttrib *sa = calloc(nsa, sizeof *sa);
    vaQuerySurfaceAttributes(dpy, cfg, sa, &nsa);
    printf("  input pixel formats:");
    for (unsigned i = 0; i < nsa; i++)
        if (sa[i].type == VASurfaceAttribPixelFormat) {
            uint32_t f = sa[i].value.value.i;
            printf(" %.4s", (char *)&f);
        }
    printf("\n");
    if (query_only) return 0;

    // Surfaces: the content ring, plus two reconstructed pictures (current and reference) ping-ponged.
    VASurfaceID *ring = calloc(ring_n, sizeof *ring), recon[2];
    CHECK(vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, w, h, ring, ring_n, NULL, 0));
    CHECK(vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, w, h, recon, 2, NULL, 0));
    uint64_t t = now_ns();
    for (int i = 0; i < ring_n; i++) fill_nv12(dpy, ring[i], w, h, i * step, ring_n * step);
    printf("filled %d NV12 surfaces in %.0f ms\n", ring_n, (now_ns() - t) / 1e6);
    VAContextID ctx;
    CHECK(vaCreateContext(dpy, cfg, w, h, VA_PROGRESSIVE, recon, 2, &ctx));
    VABufferID coded;
    CHECK(vaCreateBuffer(dpy, ctx, VAEncCodedBufferType, w * h * 3 / 2, 1, NULL, &coded));
    FILE *out = dump ? fopen(dump, "wb") : NULL;

    const int ctb = 64, ctus = ((w + ctb - 1) / ctb) * ((h + ctb - 1) / ctb);
    int frames = (int)(seconds * fps);
    uint64_t *lat = calloc(frames, 8), *lat_idr = calloc(frames, 8), *lat_ref = calloc(frames, 8);
    uint64_t *submit = calloc(frames, 8);
    int n_lat = 0, n_idr = 0, n_ref = 0, idr_ok = 0, idr_bad = 0, idr_vps = 0;
    double bytes_total = 0, bytes_normal = 0, bytes_ref = 0;
    int poc = 0, cur = 0, normal_count = 0, refine_pending = 0, ring_idx = 0, prev_refine = 0;
    uint64_t period = 1000000000ull / fps, start = now_ns(), cpu0 = cpu_ns();
    for (int f = 0; f < frames; f++) {
        // Tick: one frame at a time, no earlier than its tick.
        uint64_t due = start + f * period, now = now_ns();
        if (now < due) {
            struct timespec ts = {due / 1000000000ull, due % 1000000000ull};
            clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
        }
        int refine = refine_pending > 0;
        if (refine) refine_pending--;
        else ring_idx = f % ring_n;
        int idr = f == 0 || (!refine && idr_every && normal_count && normal_count % idr_every == 0);
        if (idr) poc = 0;
        int frame_qp = cqp ? qp : 26;
        if (refine && refine_qp >= 0) frame_qp = refine_qp;

        uint64_t t0 = now_ns();
        VABufferID bufs[8];
        int nb = 0;
        if (idr) {
            VAEncSequenceParameterBufferHEVC seq = {0};
            seq.general_profile_idc = 1;
            seq.general_level_idc = 153; // 5.1
            seq.intra_period = 0;        // no periodic intra: an infinite GOP
            seq.intra_idr_period = 0;
            seq.ip_period = 1;
            seq.bits_per_second = kbps * 1000;
            seq.pic_width_in_luma_samples = w;
            seq.pic_height_in_luma_samples = h;
            seq.seq_fields.bits.chroma_format_idc = 1;
            seq.seq_fields.bits.amp_enabled_flag = 1;
            seq.seq_fields.bits.sample_adaptive_offset_enabled_flag = 0;
            seq.seq_fields.bits.low_delay_seq = 1;
            seq.log2_min_luma_coding_block_size_minus3 = 0;
            seq.log2_diff_max_min_luma_coding_block_size = 3;
            seq.log2_min_transform_block_size_minus2 = 0;
            seq.log2_diff_max_min_transform_block_size = 3;
            seq.max_transform_hierarchy_depth_inter = 3;
            seq.max_transform_hierarchy_depth_intra = 3;
            seq.vui_parameters_present_flag = 1;
            seq.vui_fields.bits.vui_timing_info_present_flag = 1;
            seq.vui_num_units_in_tick = 1;
            seq.vui_time_scale = fps;
            bufs[nb++] = make_buf(dpy, ctx, VAEncSequenceParameterBufferType, sizeof seq, &seq);
        }
        if (!cqp) {
            VAEncMiscParameterRateControl rc = {0};
            rc.bits_per_second = kbps * 1000;
            rc.target_percentage = 100;
            rc.window_size = 1000;
            rc.initial_qp = 26;
            rc.min_qp = 1;
            rc.max_qp = refine && refine_qp >= 0 ? refine_qp : 51;
            bufs[nb++] = misc_buf(dpy, ctx, VAEncMiscParameterTypeRateControl, &rc, sizeof rc);
            VAEncMiscParameterFrameRate fr = {.framerate = fps};
            bufs[nb++] = misc_buf(dpy, ctx, VAEncMiscParameterTypeFrameRate, &fr, sizeof fr);
            VAEncMiscParameterHRD hrd = {.initial_buffer_fullness = kbps * 1000 / fps, .buffer_size = kbps * 1000 / fps * 2};
            bufs[nb++] = misc_buf(dpy, ctx, VAEncMiscParameterTypeHRD, &hrd, sizeof hrd);
        }
        if (quality) {
            VAEncMiscParameterBufferQualityLevel ql = {.quality_level = quality};
            bufs[nb++] = misc_buf(dpy, ctx, VAEncMiscParameterTypeQualityLevel, &ql, sizeof ql);
        }
        VAEncPictureParameterBufferHEVC pic = {0};
        pic.decoded_curr_pic.picture_id = recon[cur];
        pic.decoded_curr_pic.pic_order_cnt = poc;
        for (int i = 0; i < 15; i++) {
            pic.reference_frames[i].picture_id = VA_INVALID_SURFACE;
            pic.reference_frames[i].flags = VA_PICTURE_HEVC_INVALID;
        }
        if (!idr) {
            pic.reference_frames[0].picture_id = recon[cur ^ 1];
            pic.reference_frames[0].pic_order_cnt = poc - 1;
            pic.reference_frames[0].flags = 0;
        }
        pic.coded_buf = coded;
        pic.collocated_ref_pic_index = 0xff;
        pic.pic_init_qp = frame_qp;
        pic.nal_unit_type = idr ? 19 : 1; // IDR_W_RADL : TRAIL_R
        pic.pic_fields.bits.idr_pic_flag = idr;
        pic.pic_fields.bits.coding_type = idr ? 1 : 2;
        pic.pic_fields.bits.reference_pic_flag = 1;
        pic.pic_fields.bits.cu_qp_delta_enabled_flag = !cqp;
        pic.pic_fields.bits.pps_loop_filter_across_slices_enabled_flag = 1;
        bufs[nb++] = make_buf(dpy, ctx, VAEncPictureParameterBufferType, sizeof pic, &pic);
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
        bufs[nb++] = make_buf(dpy, ctx, VAEncSliceParameterBufferType, sizeof sl, &sl);

        CHECK(vaBeginPicture(dpy, ctx, ring[ring_idx]));
        CHECK(vaRenderPicture(dpy, ctx, bufs, nb));
        CHECK(vaEndPicture(dpy, ctx));
        uint64_t t1 = now_ns();
        CHECK(vaSyncBuffer(dpy, coded, VA_TIMEOUT_INFINITE));
        VACodedBufferSegment *seg;
        CHECK(vaMapBuffer(dpy, coded, (void **)&seg));
        size_t size = 0;
        int has_irap = 0, has_vps = 0;
        for (VACodedBufferSegment *s = seg; s; s = s->next) {
            uint8_t *b = s->buf;
            for (unsigned i = 0; i + 3 < s->size; i++)
                if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
                    int type = (b[i + 3] >> 1) & 0x3f;
                    if (type >= 16 && type <= 21) has_irap = 1;
                    if (type == 32) has_vps = 1;
                }
            if (out) fwrite(s->buf, 1, s->size, out);
            size += s->size;
        }
        CHECK(vaUnmapBuffer(dpy, coded));
        uint64_t t2 = now_ns();
        for (int i = 0; i < nb; i++) vaDestroyBuffer(dpy, bufs[i]);
        if (f == 0) printf("first AU: %zu bytes, IRAP %d, VPS %d\n", size, has_irap, has_vps);
        bytes_total += size;
        submit[n_lat] = t1 - t0;
        if (idr && f > 0) {
            lat_idr[n_idr++] = t2 - t0;
            if (has_irap) idr_ok++;
            else idr_bad++;
            if (has_vps) idr_vps++;
        } else if (refine) {
            lat_ref[n_ref++] = t2 - t0;
            bytes_ref += size;
        } else if (f > 0) {
            lat[n_lat++] = t2 - t0;
            bytes_normal += size;
        }
        // Around each of the first two refinements: the frame before, the refinements, the frame after.
        if (refine_every && f < 2 * (refine_every + 2) + 2 &&
            (refine || prev_refine || refine_pending || (normal_count + 1) % refine_every == 0))
            printf("  sequence: %s %zu B%s\n", refine ? "refine" : idr ? "idr" : "normal", size,
                   has_irap ? " (IRAP)" : "");
        prev_refine = refine;
        if (!refine) {
            normal_count++;
            if (refine_every && normal_count % refine_every == 0) refine_pending = 2;
        }
        poc++;
        cur ^= 1;
    }
    uint64_t wall = now_ns() - start, cpu = cpu_ns() - cpu0;
    printf("run: %dx%d %s%s at %d Hz ticks, %d frames in %.2f s = %.1f fps; cpu %.1f%% of one core; %.1f Mbps\n", w,
           h, rc_name, quality ? " (quality level set)" : "", fps, frames, wall / 1e9, frames * 1e9 / wall,
           cpu * 100.0 / wall, bytes_total * 8 / (wall / 1e9) / 1e6);
    summary("normal: params → AU mapped", lat, n_lat);
    summary("normal: CPU submit (params + Begin/Render/End)", submit, n_lat);
    printf("  normal AU mean %.1f KB\n", n_lat ? bytes_normal / n_lat / 1e3 : 0);
    if (n_idr) {
        summary("forced IDR", lat_idr, n_idr);
        printf("  forced IDR: %d IRAP on the requested frame, %d not; %d carried a VPS\n", idr_ok, idr_bad, idr_vps);
    }
    if (n_ref) {
        summary("refinement", lat_ref, n_ref);
        printf("  refinement AU mean %.1f KB\n", bytes_ref / n_ref / 1e3);
    }
    loadavg("after");
    if (out) fclose(out);
    vaDestroyBuffer(dpy, coded);
    vaDestroyContext(dpy, ctx);
    vaDestroySurfaces(dpy, recon, 2);
    vaDestroySurfaces(dpy, ring, ring_n);
    vaDestroyConfig(dpy, cfg);
    vaTerminate(dpy);
    close(fd);
    return 0;
}
