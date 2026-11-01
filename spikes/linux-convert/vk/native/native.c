// The C side of the spike: GBM allocation of BGRx DMA-BUFs, and libva NV12 surfaces (export, import,
// read-back). Plain C against the system headers, because bindgen (libclang-dev) isn't installed.
#include <gbm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>

struct lc_bo {
    void *bo;
    int fd;
    uint32_t stride, offset, planes;
    uint64_t modifier;
};

void *lc_gbm_device(int drm_fd) { return gbm_create_device(drm_fd); }

// A BGRx (XRGB8888) buffer with exactly `modifier`, as Mutter's screen-cast streams offer it.
int lc_gbm_alloc(void *dev, uint32_t w, uint32_t h, uint64_t modifier, struct lc_bo *out) {
    struct gbm_bo *bo = gbm_bo_create_with_modifiers2(dev, w, h, GBM_FORMAT_XRGB8888, &modifier, 1,
                                                      GBM_BO_USE_RENDERING);
    if (!bo) return -1;
    out->bo = bo;
    out->fd = gbm_bo_get_fd(bo);
    out->stride = gbm_bo_get_stride_for_plane(bo, 0);
    out->offset = gbm_bo_get_offset(bo, 0);
    out->planes = gbm_bo_get_plane_count(bo);
    out->modifier = gbm_bo_get_modifier(bo);
    return out->fd < 0 ? -2 : 0;
}

// --- libva -------------------------------------------------------------------------------------------

struct lc_nv12 {
    uint32_t surface;
    int fd;                 // one object (the spike requires it)
    uint32_t size;
    uint64_t modifier;
    uint32_t fourcc, num_objects, num_layers;
    uint32_t offset[2], pitch[2];  // Y, then UV
};

void *lc_va_open(int drm_fd, char *vendor, int vendor_len) {
    VADisplay dpy = vaGetDisplayDRM(drm_fd);
    if (!dpy) return NULL;
    int major, minor;
    if (vaInitialize(dpy, &major, &minor) != VA_STATUS_SUCCESS) return NULL;
    snprintf(vendor, vendor_len, "%s", vaQueryVendorString(dpy));
    return dpy;
}

static int describe(VADisplay dpy, VASurfaceID s, struct lc_nv12 *out) {
    VADRMPRIMESurfaceDescriptor d;
    memset(&d, 0, sizeof d);
    VAStatus st = vaExportSurfaceHandle(dpy, s, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                        VA_EXPORT_SURFACE_READ_WRITE | VA_EXPORT_SURFACE_SEPARATE_LAYERS, &d);
    if (st != VA_STATUS_SUCCESS) return -(int)st;
    out->surface = s;
    out->fourcc = d.fourcc;
    out->num_objects = d.num_objects;
    out->num_layers = d.num_layers;
    out->fd = d.objects[0].fd;
    out->size = d.objects[0].size;
    out->modifier = d.objects[0].drm_format_modifier;
    for (uint32_t i = 1; i < d.num_objects; i++) close(d.objects[i].fd);
    if (d.num_objects != 1 || d.num_layers != 2) return -1000;
    out->offset[0] = d.layers[0].offset[0];
    out->pitch[0] = d.layers[0].pitch[0];
    out->offset[1] = d.layers[1].offset[0];
    out->pitch[1] = d.layers[1].pitch[0];
    return 0;
}

// A driver-allocated NV12 surface (the kind the encoder takes), exported as a DMA-BUF.
int lc_va_create_export(void *dpy, uint32_t w, uint32_t h, struct lc_nv12 *out) {
    VASurfaceID s;
    VASurfaceAttrib a = {.type = VASurfaceAttribPixelFormat, .flags = VA_SURFACE_ATTRIB_SETTABLE,
                         .value = {.type = VAGenericValueTypeInteger, .value.i = VA_FOURCC_NV12}};
    VAStatus st = vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, w, h, &s, 1, &a, 1);
    if (st != VA_STATUS_SUCCESS) return -(int)st;
    return describe(dpy, s, out);
}

// A surface over our own linear NV12 DMA-BUF (one object, two layers).
int lc_va_import(void *dpy, uint32_t w, uint32_t h, int fd, uint32_t size, uint64_t modifier,
                 const uint32_t offset[2], const uint32_t pitch[2], uint32_t *surface) {
    VADRMPRIMESurfaceDescriptor d;
    memset(&d, 0, sizeof d);
    d.fourcc = VA_FOURCC_NV12;
    d.width = w;
    d.height = h;
    d.num_objects = 1;
    d.objects[0].fd = fd;
    d.objects[0].size = size;
    d.objects[0].drm_format_modifier = modifier;
    d.num_layers = 2;
    d.layers[0].drm_format = 0x20203852; // DRM_FORMAT_R8
    d.layers[0].num_planes = 1;
    d.layers[0].offset[0] = offset[0];
    d.layers[0].pitch[0] = pitch[0];
    d.layers[1].drm_format = 0x38384752; // DRM_FORMAT_GR88
    d.layers[1].num_planes = 1;
    d.layers[1].offset[0] = offset[1];
    d.layers[1].pitch[0] = pitch[1];
    VASurfaceAttrib a[2] = {
        {.type = VASurfaceAttribMemoryType, .flags = VA_SURFACE_ATTRIB_SETTABLE,
         .value = {.type = VAGenericValueTypeInteger, .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2}},
        {.type = VASurfaceAttribExternalBufferDescriptor, .flags = VA_SURFACE_ATTRIB_SETTABLE,
         .value = {.type = VAGenericValueTypePointer, .value.p = &d}},
    };
    VAStatus st = vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, w, h, surface, 1, a, 2);
    return st == VA_STATUS_SUCCESS ? 0 : -(int)st;
}

// Reads an NV12 surface back through libva (vaDeriveImage + map, or vaGetImage into a VA image), tightly packed into y (w*h) and uv
// (w*h/2): an independent check that the encoder's view of the surface is what the shader wrote.
int lc_va_readback(void *dpy, uint32_t surface, uint32_t w, uint32_t h, uint8_t *y, uint8_t *uv) {
    VAStatus st = vaSyncSurface(dpy, surface);
    if (st != VA_STATUS_SUCCESS) return -(int)st;
    VAImage img;
    st = vaDeriveImage(dpy, surface, &img);
    if (st != VA_STATUS_SUCCESS) {
        // Not derivable (an imported or tiled surface): copy it into a VA image instead.
        VAImageFormat fmt = {.fourcc = VA_FOURCC_NV12, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12};
        st = vaCreateImage(dpy, &fmt, w, h, &img);
        if (st != VA_STATUS_SUCCESS) return -(int)st;
        st = vaGetImage(dpy, surface, 0, 0, w, h, img.image_id);
        if (st != VA_STATUS_SUCCESS) { vaDestroyImage(dpy, img.image_id); return -(int)st; }
    }
    if (img.width < w || img.height < h || img.pitches[0] < w || img.pitches[1] < w ||
        (uint64_t)img.offsets[0] + (uint64_t)img.pitches[0] * h > img.data_size ||
        (uint64_t)img.offsets[1] + (uint64_t)img.pitches[1] * (h / 2) > img.data_size) {
        vaDestroyImage(dpy, img.image_id);
        return -2000;
    }
    uint8_t *p;
    st = vaMapBuffer(dpy, img.buf, (void **)&p);
    if (st != VA_STATUS_SUCCESS) { vaDestroyImage(dpy, img.image_id); return -(int)st; }
    for (uint32_t r = 0; r < h; r++) memcpy(y + (size_t)r * w, p + img.offsets[0] + (size_t)r * img.pitches[0], w);
    for (uint32_t r = 0; r < h / 2; r++)
        memcpy(uv + (size_t)r * w, p + img.offsets[1] + (size_t)r * img.pitches[1], w);
    vaUnmapBuffer(dpy, img.buf);
    vaDestroyImage(dpy, img.image_id);
    return 0;
}
