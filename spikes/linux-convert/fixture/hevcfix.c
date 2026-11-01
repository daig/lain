// hevcfix: small real HEVC bitstreams for lain-media's tests (the wave-2 fixtures), made with exactly the
// encoder of e2e.c (spike 6): libva on the AMD iGPU, HEVC Main 4:2:0 8-bit, CBR with a two-frame HRD, one
// reference, own VPS/SPS/PPS and slice headers as packed headers. That is the stream lain-linux-video will
// produce. The input is synthetic NV12 (a moving gradient and a square, uploaded with vaPutImage), so no
// PipeWire and no virtual monitor are needed.
//
// Writes, per stream, every access unit as its own file (au-NN.h265), the whole stream (stream.h265), and
// manifest.txt: one line per AU with its NAL units as found by a plain start-code scan here (the oracle the
// Rust tests compare with). Opens only the AMD render node (checked by PCI vendor); run under
// spikes/linux-encoder/nvidia-guard.sh.
//
// Usage: hevcfix <out-dir> <width> <height> <frames> <kbps> [<keyframe-frame>...]
// The bitrate must suit the size: CBR pads every frame to its budget, and a budget above the coded buffer
// (width × height × 1.5 bytes) overflows it (seen at 60 Mbps and 256×144: the AU is the wrapped tail).
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_enc_hevc.h>

#define DEVICE "/dev/dri/by-path/pci-0000:79:00.0-render"
#define NOUT 1
static int W, H;
static int no_stuffing; // HEVCFIX_NO_STUFFING=1: rc_flags.disable_bit_stuffing (no CBR filler)
#define DIE(...) do { fprintf(stderr, "hevcfix: " __VA_ARGS__); fputc('\n', stderr); exit(1); } while (0)
#define CHECK(x) do { VAStatus s_ = (x); if (s_ != VA_STATUS_SUCCESS) DIE("%s:%d %s: %s", __FILE__, __LINE__, #x, vaErrorStr(s_)); } while (0)

// ------------------------------------------------ copied from e2e/e2e.c (lines 158-420); hevcfix's one change is
// marked "hevcfix only"
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
    rc.rc_flags.bits.disable_bit_stuffing = no_stuffing; // hevcfix only: not in e2e.c
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

// ------------------------------------------------ fixture generation
static VADisplay dpy;

static void fill(VASurfaceID s, int f) {
    VAImageFormat fmt = {.fourcc = VA_FOURCC_NV12, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12};
    VAImage img;
    CHECK(vaCreateImage(dpy, &fmt, W, H, &img));
    uint8_t *p;
    CHECK(vaMapBuffer(dpy, img.buf, (void **)&p));
    int sx = (f * 6) % (W - 16), sy = (f * 4) % (H - 16);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            int in_sq = x >= sx && x < sx + 16 && y >= sy && y < sy + 16;
            p[img.offsets[0] + y * img.pitches[0] + x] = in_sq ? 235 : (uint8_t)(16 + (x * 3 + y * 2 + f * 5) % 200);
        }
    for (int y = 0; y < H / 2; y++)
        for (int x = 0; x < W / 2; x++) {
            uint8_t *uv = p + img.offsets[1] + y * img.pitches[1] + 2 * x;
            uv[0] = (uint8_t)(112 + (x + f) % 32);
            uv[1] = (uint8_t)(112 + (2 * y + f) % 32);
        }
    CHECK(vaUnmapBuffer(dpy, img.buf));
    CHECK(vaPutImage(dpy, s, img.image_id, 0, 0, W, H, 0, 0, W, H));
    CHECK(vaDestroyImage(dpy, img.image_id));
}

// One manifest line: every NAL unit's type, the offset of its 2-byte header, its length without trailing zero
// bytes, and the length of the start code before it (3, or 4 with the zero_byte).
static void manifest_line(FILE *m, const char *name, const uint8_t *b, size_t n, int keyframe) {
    fprintf(m, "%s size=%zu keyframe=%d", name, n, keyframe);
    size_t starts[256];
    int sc[256], count = 0;
    for (size_t i = 0; i + 2 < n; i++)
        if (b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1) {
            if (count == 256) DIE("too many NAL units");
            sc[count] = (i > 0 && b[i - 1] == 0) ? 4 : 3;
            starts[count++] = i + 3;
            i += 2;
        }
    for (int k = 0; k < count; k++) {
        size_t end = k + 1 < count ? starts[k + 1] - sc[k + 1] : n;
        while (end > starts[k] && b[end - 1] == 0) end--;
        fprintf(m, " nal=%d,%zu,%zu,%d", (b[starts[k]] >> 1) & 0x3f, starts[k], end - starts[k], sc[k]);
    }
    fputc('\n', m);
}

int main(int argc, char **argv) {
    if (argc < 6) DIE("usage: hevcfix <out-dir> <width> <height> <frames> <kbps> [<keyframe-frame>...]");
    const char *dir = argv[1];
    W = atoi(argv[2]);
    H = atoi(argv[3]);
    int frames = atoi(argv[4]);
    unsigned kbps = (unsigned)atoi(argv[5]);
    no_stuffing = getenv("HEVCFIX_NO_STUFFING") && atoi(getenv("HEVCFIX_NO_STUFFING"));
    if (W < 16 || H < 16 || W % 8 || H % 8 || frames < 1 || frames > 64 || kbps < 16) DIE("bad size, frame count or bitrate");
    if ((double)kbps * 1000 / 8 / 120 * 2 > W * H * 1.5) DIE("two frames' budget exceeds the coded buffer");

    char real[4096], path[4200], vendor[16] = {0};
    if (!realpath(DEVICE, real)) DIE("no %s", DEVICE);
    snprintf(path, sizeof path, "/sys/class/drm/%s/device/vendor", strrchr(real, '/') + 1);
    FILE *vf = fopen(path, "r");
    if (!vf || !fgets(vendor, sizeof vendor, vf) || strncmp(vendor, "0x1002", 6)) DIE("%s is not AMD", real);
    fclose(vf);
    int fd = open(DEVICE, O_RDWR | O_CLOEXEC);
    if (fd < 0) DIE("open %s", DEVICE);
    dpy = vaGetDisplayDRM(fd);
    int vmaj, vmin;
    CHECK(vaInitialize(dpy, &vmaj, &vmin));

    VASurfaceID input;
    CHECK(vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, W, H, &input, 1, NULL, 0));
    encoder e;
    enc_init(dpy, &e, 120, &input, 1);
    e.kbps = kbps;

    mkdir(dir, 0755);
    snprintf(path, sizeof path, "%s/stream.h265", dir);
    FILE *stream = fopen(path, "wb");
    snprintf(path, sizeof path, "%s/manifest.txt", dir);
    FILE *man = fopen(path, "w");
    if (!stream || !man) DIE("can't write in %s", dir);
    fprintf(man, "# hevcfix %dx%d, %d frames, CBR %u kbps, bit stuffing %s; requested keyframes:", W, H, frames, kbps,
            no_stuffing ? "off" : "on");
    for (int i = 6; i < argc; i++) fprintf(man, " %s", argv[i]);
    fprintf(man, "\n");
    for (int f = 0; f < frames; f++) {
        for (int i = 6; i < argc; i++)
            if (atoi(argv[i]) == f) e.poc = 0; // a requested IDR: POC restarts, parameter sets are re-sent
        fill(input, f);
        enc_submit(dpy, &e, input);
        char *buf = NULL;
        size_t len = 0, size = 0;
        FILE *mem = open_memstream(&buf, &len);
        int irap, vps;
        if (!enc_collect(dpy, &e, VA_TIMEOUT_INFINITE, mem, &size, &irap, &vps)) DIE("encode timed out");
        fclose(mem);
        char name[32];
        snprintf(name, sizeof name, "au-%02d.h265", f);
        snprintf(path, sizeof path, "%s/%s", dir, name);
        FILE *au = fopen(path, "wb");
        if (!au || fwrite(buf, 1, len, au) != len || fclose(au)) DIE("write %s", path);
        if (fwrite(buf, 1, len, stream) != len) DIE("write stream");
        manifest_line(man, name, (const uint8_t *)buf, len, irap);
        printf("%s: %zu bytes, IRAP %d, VPS %d\n", name, len, irap, vps);
        free(buf);
    }
    fclose(stream);
    fclose(man);
    vaDestroyBuffer(dpy, e.coded);
    vaDestroyContext(dpy, e.ctx);
    vaDestroyConfig(dpy, e.cfg);
    vaDestroySurfaces(dpy, e.recon, 2);
    vaDestroySurfaces(dpy, &input, 1);
    vaTerminate(dpy);
    close(fd);
    return 0;
}
