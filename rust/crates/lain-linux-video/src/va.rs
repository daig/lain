//! The safe wrapper over libva (the raw bindings are `ffi::va`): one display on the render node's fd, and the
//! calls the encoder and the converter make. Mirrors what `spikes/linux-encoder/vaenc` and
//! `spikes/linux-convert/e2e/e2e.c` call; no Swift counterpart (VideoToolbox).
//!
//! Objects are libva's plain ids (config, context, surface, buffer). libva looks every id up in its own tables
//! and answers an unknown one with an error status, so passing ids is safe; the owner destroys what it created.
//! A [`Display`] is used from one thread at a time (the video thread): it is `Send`, not `Sync`.
#![allow(unsafe_code)]

use std::ffi::CStr;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::ptr;
use std::sync::Arc;

use crate::ffi::va as sys;

pub(crate) use sys::{VABufferID, VAConfigID, VAContextID, VASurfaceID};

/// A failed libva call: the function and libva's message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaError {
    pub call: &'static str,
    pub status: i32,
    pub message: String,
}

impl std::fmt::Display for VaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {} ({})", self.call, self.message, self.status)
    }
}

impl std::error::Error for VaError {}

/// libva's text for a status.
pub fn error_str(status: i32) -> String {
    // SAFETY: vaErrorStr accepts any status and returns a pointer to a static NUL-terminated string.
    unsafe { CStr::from_ptr(sys::vaErrorStr(status)) }.to_string_lossy().into_owned()
}

fn check(call: &'static str, status: sys::VAStatus) -> Result<(), VaError> {
    if status == sys::VA_STATUS_SUCCESS as sys::VAStatus {
        Ok(())
    } else {
        Err(VaError { call, status, message: error_str(status) })
    }
}

/// One NV12 surface exported as DRM PRIME 2 with separate layers (`vaExportSurfaceHandle`): its objects' fds,
/// owned here, and its two layers (R8 luma, GR88 chroma).
#[derive(Debug)]
pub struct Nv12Export {
    pub width: u32,
    pub height: u32,
    pub objects: Vec<ExportObject>,
    /// `[Y, CbCr]`.
    pub layers: [ExportLayer; 2],
}

#[derive(Debug)]
pub struct ExportObject {
    pub fd: OwnedFd,
    pub size: u32,
    pub modifier: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExportLayer {
    pub drm_format: u32,
    pub object: usize,
    pub offset: u32,
    pub pitch: u32,
}

/// DRM fourcc `R8  ` and `GR88`.
pub const DRM_FORMAT_R8: u32 = u32::from_le_bytes(*b"R8  ");
pub const DRM_FORMAT_GR88: u32 = u32::from_le_bytes(*b"GR88");

impl Nv12Export {
    /// Checks the export before any shader may write it (as `glconv.c` and `e2e.c` do): NV12 at the size asked
    /// for, two single-plane layers R8 then GR88, each lying wholly inside its object (`offset + pitch × rows ≤
    /// size`, the pitch at least a row). Pure, so it is unit-tested.
    pub fn validate(desc: &sys::VADRMPRIMESurfaceDescriptor, width: u32, height: u32) -> Result<(), String> {
        if desc.fourcc != sys::VA_FOURCC_NV12 || desc.width != width || desc.height != height {
            return Err(format!(
                "the export is {:?} {}×{}, not NV12 {width}×{height}",
                desc.fourcc.to_le_bytes().map(char::from),
                desc.width,
                desc.height
            ));
        }
        if desc.num_layers != 2 || desc.num_objects < 1 || desc.num_objects > 2 {
            return Err(format!("the export has {} layers and {} objects", desc.num_layers, desc.num_objects));
        }
        for (l, want) in [DRM_FORMAT_R8, DRM_FORMAT_GR88].into_iter().enumerate() {
            let layer = &desc.layers[l];
            let o = layer.object_index[0];
            let rows = u64::from(if l == 0 { height } else { height / 2 });
            if layer.num_planes != 1 || layer.drm_format != want || o >= desc.num_objects {
                return Err(format!("export layer {l}: format, planes or object unexpected"));
            }
            let size = u64::from(desc.objects[o as usize].size);
            if layer.pitch[0] < width || u64::from(layer.offset[0]) + u64::from(layer.pitch[0]) * rows > size {
                return Err(format!(
                    "export layer {l}: offset {} + pitch {} × {rows} rows exceeds the object's {size} bytes",
                    layer.offset[0], layer.pitch[0]
                ));
            }
        }
        Ok(())
    }
}

/// The NV12 picture read back from a surface (`vaGetImage`), rows packed: `width × height` luma, then
/// `width × height / 2` interleaved CbCr.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Nv12Picture {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

/// An initialised libva display on the render node's fd. Terminated on drop.
pub struct Display {
    dpy: sys::VADisplay,
    /// The fd stays open as long as the display uses it.
    _fd: Arc<OwnedFd>,
    vendor: String,
}

// SAFETY: a VADisplay is a pointer to libva's per-display state, which libva protects with its own locks for
// the calls made here; this crate uses each display from one thread at a time (the video thread, or a test) and
// never shares it (`Display` isn't `Sync`), so moving it to another thread is sound.
unsafe impl Send for Display {}

impl Display {
    /// `vaGetDisplayDRM` and `vaInitialize` on `fd`, which must be the AMD render node (on an amdgpu fd libva
    /// loads radeonsi; it opens no other device).
    pub fn open(fd: Arc<OwnedFd>) -> Result<Self, VaError> {
        // SAFETY: the fd is open (we hold it for the display's life); vaGetDisplayDRM only stores it.
        let dpy = unsafe { sys::vaGetDisplayDRM(fd.as_raw_fd()) };
        if dpy.is_null() {
            return Err(VaError { call: "vaGetDisplayDRM", status: -1, message: "no display".into() });
        }
        let (mut major, mut minor) = (0, 0);
        // SAFETY: dpy came from vaGetDisplayDRM; the out-pointers are valid locals.
        let status = unsafe { sys::vaInitialize(dpy, &mut major, &mut minor) };
        if let Err(e) = check("vaInitialize", status) {
            // SAFETY: vaTerminate releases a display that failed to initialise.
            unsafe { sys::vaTerminate(dpy) };
            return Err(e);
        }
        // SAFETY: an initialised display; the vendor string is static for its life, copied at once.
        let vendor = unsafe {
            let p = sys::vaQueryVendorString(dpy);
            if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
        };
        Ok(Self { dpy, _fd: fd, vendor })
    }

    pub fn vendor(&self) -> &str {
        &self.vendor
    }

    /// The entrypoints of `profile`.
    pub fn entrypoints(&self, profile: sys::VAProfile) -> Result<Vec<sys::VAEntrypoint>, VaError> {
        let mut list = vec![0 as sys::VAEntrypoint; 32];
        let mut n = 0;
        // SAFETY: the list has room for 32 entrypoints, more than libva's maximum (vaMaxNumEntrypoints is ~15).
        check("vaQueryConfigEntrypoints", unsafe {
            sys::vaQueryConfigEntrypoints(self.dpy, profile, list.as_mut_ptr(), &mut n)
        })?;
        list.truncate(n.clamp(0, 32) as usize);
        Ok(list)
    }

    /// The value of each attribute type (`VA_ATTRIB_NOT_SUPPORTED` if not supported).
    pub fn config_attributes(
        &self,
        profile: sys::VAProfile,
        entrypoint: sys::VAEntrypoint,
        types: &[sys::VAConfigAttribType],
    ) -> Result<Vec<u32>, VaError> {
        let mut attrs: Vec<sys::VAConfigAttrib> =
            types.iter().map(|&t| sys::VAConfigAttrib { type_: t, value: 0 }).collect();
        // SAFETY: attrs holds exactly attrs.len() initialised entries for libva to fill in.
        check("vaGetConfigAttributes", unsafe {
            sys::vaGetConfigAttributes(self.dpy, profile, entrypoint, attrs.as_mut_ptr(), attrs.len() as i32)
        })?;
        Ok(attrs.iter().map(|a| a.value).collect())
    }

    pub fn create_config(
        &self,
        profile: sys::VAProfile,
        entrypoint: sys::VAEntrypoint,
        attribs: &[(sys::VAConfigAttribType, u32)],
    ) -> Result<VAConfigID, VaError> {
        let mut list: Vec<sys::VAConfigAttrib> =
            attribs.iter().map(|&(t, v)| sys::VAConfigAttrib { type_: t, value: v }).collect();
        let mut id = sys::VA_INVALID_ID;
        // SAFETY: list holds list.len() attributes; id is a valid out-pointer.
        check("vaCreateConfig", unsafe {
            sys::vaCreateConfig(self.dpy, profile, entrypoint, list.as_mut_ptr(), list.len() as i32, &mut id)
        })?;
        Ok(id)
    }

    pub fn destroy_config(&self, id: VAConfigID) {
        // SAFETY: an unknown id is answered with an error status, which is ignored on teardown.
        unsafe { sys::vaDestroyConfig(self.dpy, id) };
    }

    /// `n` YUV 4:2:0 surfaces of `width × height`; with `nv12_hint` (Some(usage hint)), NV12 pixels and that
    /// usage hint (`ENCODER | EXPORT` for the converter's targets), as `glconv.c` asks.
    pub fn create_surfaces(
        &self,
        width: u32,
        height: u32,
        n: usize,
        nv12_hint: Option<u32>,
    ) -> Result<Vec<VASurfaceID>, VaError> {
        let mut ids = vec![sys::VA_INVALID_SURFACE; n];
        let mut attrs: Vec<sys::VASurfaceAttrib> = Vec::new();
        if let Some(hint) = nv12_hint {
            for (t, v) in [
                (sys::VASurfaceAttribPixelFormat, sys::VA_FOURCC_NV12 as i32),
                (sys::VASurfaceAttribUsageHint, hint as i32),
            ] {
                attrs.push(sys::VASurfaceAttrib {
                    type_: t,
                    flags: sys::VA_SURFACE_ATTRIB_SETTABLE,
                    value: sys::VAGenericValue {
                        type_: sys::VAGenericValueTypeInteger,
                        value: sys::_VAGenericValue__bindgen_ty_1 { i: v },
                    },
                });
            }
        }
        let attr_ptr = if attrs.is_empty() { ptr::null_mut() } else { attrs.as_mut_ptr() };
        // SAFETY: ids has room for n surfaces; attrs (if any) are initialised integer attributes.
        check("vaCreateSurfaces", unsafe {
            sys::vaCreateSurfaces(
                self.dpy,
                sys::VA_RT_FORMAT_YUV420,
                width,
                height,
                ids.as_mut_ptr(),
                n as u32,
                attr_ptr,
                attrs.len() as u32,
            )
        })?;
        Ok(ids)
    }

    pub fn destroy_surfaces(&self, ids: &[VASurfaceID]) {
        if ids.is_empty() {
            return;
        }
        let mut ids = ids.to_vec();
        // SAFETY: ids is a valid array of ids.len() entries; unknown ids give an error status (ignored).
        unsafe { sys::vaDestroySurfaces(self.dpy, ids.as_mut_ptr(), ids.len() as i32) };
    }

    pub fn create_context(
        &self,
        config: VAConfigID,
        width: u32,
        height: u32,
        targets: &[VASurfaceID],
    ) -> Result<VAContextID, VaError> {
        let mut targets = targets.to_vec();
        let mut id = sys::VA_INVALID_ID;
        // SAFETY: targets is a valid array; id a valid out-pointer.
        check("vaCreateContext", unsafe {
            sys::vaCreateContext(
                self.dpy,
                config,
                width as i32,
                height as i32,
                sys::VA_PROGRESSIVE as i32,
                targets.as_mut_ptr(),
                targets.len() as i32,
                &mut id,
            )
        })?;
        Ok(id)
    }

    pub fn destroy_context(&self, id: VAContextID) {
        // SAFETY: as destroy_config.
        unsafe { sys::vaDestroyContext(self.dpy, id) };
    }

    /// A buffer holding a copy of `value` (a libva parameter structure).
    pub fn create_buffer<T: Copy>(
        &self,
        ctx: VAContextID,
        kind: sys::VABufferType,
        value: &T,
    ) -> Result<VABufferID, VaError> {
        let mut id = sys::VA_INVALID_ID;
        // SAFETY: libva copies size_of::<T>() bytes from the pointer, which points at a live T; it never writes
        // through it (the C prototype isn't const).
        check("vaCreateBuffer", unsafe {
            sys::vaCreateBuffer(
                self.dpy,
                ctx,
                kind,
                std::mem::size_of::<T>() as u32,
                1,
                (value as *const T).cast_mut().cast(),
                &mut id,
            )
        })?;
        Ok(id)
    }

    /// A buffer holding a copy of `bytes` (packed header data).
    pub fn create_buffer_bytes(
        &self,
        ctx: VAContextID,
        kind: sys::VABufferType,
        bytes: &[u8],
    ) -> Result<VABufferID, VaError> {
        let mut id = sys::VA_INVALID_ID;
        // SAFETY: libva copies bytes.len() bytes from a live slice and doesn't write through the pointer.
        check("vaCreateBuffer", unsafe {
            sys::vaCreateBuffer(self.dpy, ctx, kind, bytes.len() as u32, 1, bytes.as_ptr().cast_mut().cast(), &mut id)
        })?;
        Ok(id)
    }

    /// A `VAEncMiscParameterBuffer` of `misc_type` carrying `value` (the C idiom: create, map, write the type
    /// word and the structure after it, unmap).
    pub fn create_misc_buffer<T: Copy>(
        &self,
        ctx: VAContextID,
        misc_type: sys::VAEncMiscParameterType,
        value: &T,
    ) -> Result<VABufferID, VaError> {
        let size = std::mem::size_of::<sys::VAEncMiscParameterBuffer>() + std::mem::size_of::<T>();
        let mut id = sys::VA_INVALID_ID;
        // SAFETY: a NULL data pointer asks libva for an uninitialised buffer of `size` bytes.
        check("vaCreateBuffer", unsafe {
            sys::vaCreateBuffer(self.dpy, ctx, sys::VAEncMiscParameterBufferType, size as u32, 1, ptr::null_mut(), &mut id)
        })?;
        let mut p: *mut std::ffi::c_void = ptr::null_mut();
        // SAFETY: id is the buffer just made; p a valid out-pointer.
        if let Err(e) = check("vaMapBuffer", unsafe { sys::vaMapBuffer(self.dpy, id, &mut p) }) {
            self.destroy_buffer(id);
            return Err(e);
        }
        // SAFETY: the mapping holds `size` bytes: the misc header (a u32 type, then the data) followed by room
        // for one T. Unaligned writes, since the data starts 4 bytes in.
        unsafe {
            let header = p.cast::<sys::VAEncMiscParameterBuffer>();
            ptr::addr_of_mut!((*header).type_).write_unaligned(misc_type);
            let data = p.cast::<u8>().add(std::mem::size_of::<sys::VAEncMiscParameterBuffer>()).cast::<T>();
            data.write_unaligned(*value);
        }
        // SAFETY: unmaps the mapping made above.
        check("vaUnmapBuffer", unsafe { sys::vaUnmapBuffer(self.dpy, id) })?;
        Ok(id)
    }

    /// A coded buffer of `size` bytes for the encoder's output.
    pub fn create_coded_buffer(&self, ctx: VAContextID, size: u32) -> Result<VABufferID, VaError> {
        let mut id = sys::VA_INVALID_ID;
        // SAFETY: NULL data: libva allocates `size` bytes.
        check("vaCreateBuffer", unsafe {
            sys::vaCreateBuffer(self.dpy, ctx, sys::VAEncCodedBufferType, size, 1, ptr::null_mut(), &mut id)
        })?;
        Ok(id)
    }

    pub fn destroy_buffer(&self, id: VABufferID) {
        // SAFETY: as destroy_config.
        unsafe { sys::vaDestroyBuffer(self.dpy, id) };
    }

    /// `vaBeginPicture`, `vaRenderPicture(buffers)`, `vaEndPicture`: submits one picture of `ctx` into `target`.
    pub fn submit_picture(
        &self,
        ctx: VAContextID,
        target: VASurfaceID,
        buffers: &[VABufferID],
    ) -> Result<(), VaError> {
        let mut buffers = buffers.to_vec();
        // SAFETY: ids only; buffers is a valid array of buffers.len() ids.
        unsafe {
            check("vaBeginPicture", sys::vaBeginPicture(self.dpy, ctx, target))?;
            let render = check("vaRenderPicture", sys::vaRenderPicture(self.dpy, ctx, buffers.as_mut_ptr(), buffers.len() as i32));
            // End the picture whatever the render said, so the context isn't left mid-picture.
            let end = check("vaEndPicture", sys::vaEndPicture(self.dpy, ctx));
            render.and(end)
        }
    }

    /// Waits up to `timeout_ns` for the coded buffer's encode: `Ok(true)` when it is done, `Ok(false)` on
    /// timeout.
    pub fn sync_buffer(&self, buf: VABufferID, timeout_ns: u64) -> Result<bool, VaError> {
        // SAFETY: an id and a timeout.
        let status = unsafe { sys::vaSyncBuffer(self.dpy, buf, timeout_ns) };
        if status == sys::VA_STATUS_ERROR_TIMEDOUT as i32 {
            return Ok(false);
        }
        check("vaSyncBuffer", status).map(|()| true)
    }

    pub fn sync_surface(&self, surface: VASurfaceID) -> Result<(), VaError> {
        // SAFETY: an id.
        check("vaSyncSurface", unsafe { sys::vaSyncSurface(self.dpy, surface) })
    }

    /// Copies a finished coded buffer out: its segments' bytes, in order, and the OR of their status words.
    /// At most `limit` bytes and 256 segments are read; more is an error (a corrupt segment list).
    pub fn read_coded(&self, buf: VABufferID, limit: usize) -> Result<(Vec<u8>, u32), VaError> {
        let mut p: *mut std::ffi::c_void = ptr::null_mut();
        // SAFETY: id and a valid out-pointer.
        check("vaMapBuffer", unsafe { sys::vaMapBuffer(self.dpy, buf, &mut p) })?;
        let mut out = Vec::new();
        let mut status = 0;
        let mut seg = p.cast::<sys::VACodedBufferSegment>();
        let mut count = 0;
        let mut result = Ok(());
        while !seg.is_null() {
            count += 1;
            // SAFETY: a mapped coded buffer is a NULL-terminated list of VACodedBufferSegment written by the
            // driver; each segment's `buf` holds `size` bytes, valid while the buffer stays mapped.
            let (size, flags, data, next) = unsafe { ((*seg).size as usize, (*seg).status, (*seg).buf, (*seg).next) };
            if count > 256 || out.len() + size > limit || (size > 0 && data.is_null()) {
                result = Err(VaError {
                    call: "vaMapBuffer",
                    status: -1,
                    message: format!("coded buffer: {count} segments, {} bytes, over the limit", out.len() + size),
                });
                break;
            }
            if size > 0 {
                // SAFETY: as above: `data` points at `size` readable bytes.
                out.extend_from_slice(unsafe { std::slice::from_raw_parts(data.cast::<u8>(), size) });
            }
            status |= flags;
            seg = next.cast();
        }
        // SAFETY: unmaps the mapping made above.
        let unmap = check("vaUnmapBuffer", unsafe { sys::vaUnmapBuffer(self.dpy, buf) });
        result.and(unmap)?;
        Ok((out, status))
    }

    /// Exports `surface` for writing (DRM PRIME 2, separate layers) and validates the layout
    /// ([`Nv12Export::validate`]). The objects' fds are owned by the result.
    pub fn export_nv12(&self, surface: VASurfaceID, width: u32, height: u32) -> Result<Nv12Export, String> {
        let mut desc = sys::VADRMPRIMESurfaceDescriptor::default();
        // SAFETY: desc is a valid VADRMPRIMESurfaceDescriptor for libva to fill (the PRIME 2 memory type's
        // descriptor type).
        check("vaExportSurfaceHandle", unsafe {
            sys::vaExportSurfaceHandle(
                self.dpy,
                surface,
                sys::VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                sys::VA_EXPORT_SURFACE_WRITE_ONLY | sys::VA_EXPORT_SURFACE_SEPARATE_LAYERS,
                (&mut desc as *mut sys::VADRMPRIMESurfaceDescriptor).cast(),
            )
        })
        .map_err(|e| e.to_string())?;
        // Take ownership of every fd libva gave us first, so they are closed whatever happens next.
        let n = (desc.num_objects as usize).min(4);
        let objects: Vec<ExportObject> = desc.objects[..n]
            .iter()
            .map(|o| ExportObject {
                // SAFETY: vaExportSurfaceHandle returns a new fd per object, owned by the caller.
                fd: unsafe { OwnedFd::from_raw_fd(o.fd) },
                size: o.size,
                modifier: o.drm_format_modifier,
            })
            .collect();
        Nv12Export::validate(&desc, width, height)?;
        let layer = |l: usize| ExportLayer {
            drm_format: desc.layers[l].drm_format,
            object: desc.layers[l].object_index[0] as usize,
            offset: desc.layers[l].offset[0],
            pitch: desc.layers[l].pitch[0],
        };
        Ok(Nv12Export { width, height, objects, layers: [layer(0), layer(1)] })
    }

    fn nv12_image(&self, width: u32, height: u32) -> Result<sys::VAImage, VaError> {
        let mut format = sys::VAImageFormat {
            fourcc: sys::VA_FOURCC_NV12,
            byte_order: sys::VA_LSB_FIRST,
            bits_per_pixel: 12,
            ..Default::default()
        };
        let mut image = sys::VAImage::default();
        // SAFETY: valid in/out structures.
        check("vaCreateImage", unsafe {
            sys::vaCreateImage(self.dpy, &mut format, width as i32, height as i32, &mut image)
        })?;
        Ok(image)
    }

    /// Runs `f` on an NV12 image's mapped bytes, then unmaps and destroys it; the image's planes are checked
    /// to lie inside its data first.
    fn with_image<R>(
        &self,
        width: u32,
        height: u32,
        before: impl FnOnce(&sys::VAImage) -> Result<(), VaError>,
        f: impl FnOnce(&sys::VAImage, &mut [u8]) -> R,
        after: impl FnOnce(&sys::VAImage) -> Result<(), VaError>,
    ) -> Result<R, VaError> {
        let image = self.nv12_image(width, height)?;
        let run = || -> Result<R, VaError> {
            let rows = [u64::from(height), u64::from(height / 2)];
            for (plane, rows) in rows.iter().enumerate() {
                let end = u64::from(image.offsets[plane]) + u64::from(image.pitches[plane]) * rows;
                if image.num_planes != 2 || image.pitches[plane] < width || end > u64::from(image.data_size) {
                    return Err(VaError { call: "vaCreateImage", status: -1, message: "unexpected NV12 layout".into() });
                }
            }
            before(&image)?;
            let mut p: *mut std::ffi::c_void = ptr::null_mut();
            // SAFETY: the image's buffer id and a valid out-pointer.
            check("vaMapBuffer", unsafe { sys::vaMapBuffer(self.dpy, image.buf, &mut p) })?;
            // SAFETY: the mapped image buffer holds data_size bytes, valid until unmapped below; nothing else
            // touches it meanwhile.
            let bytes = unsafe { std::slice::from_raw_parts_mut(p.cast::<u8>(), image.data_size as usize) };
            let r = f(&image, bytes);
            // SAFETY: unmaps the mapping above.
            check("vaUnmapBuffer", unsafe { sys::vaUnmapBuffer(self.dpy, image.buf) })?;
            after(&image)?;
            Ok(r)
        };
        let r = run();
        // SAFETY: destroys the image made above.
        unsafe { sys::vaDestroyImage(self.dpy, image.image_id) };
        r
    }

    /// Reads `surface` back as packed NV12 (`vaGetImage`), for the GPU tests' checks.
    pub fn get_nv12(&self, surface: VASurfaceID, width: u32, height: u32) -> Result<Nv12Picture, VaError> {
        self.sync_surface(surface)?;
        let (w, h) = (width as usize, height as usize);
        self.with_image(
            width,
            height,
            // SAFETY: ids and a size within the surface.
            |img| check("vaGetImage", unsafe { sys::vaGetImage(self.dpy, surface, 0, 0, width, height, img.image_id) }),
            |img, bytes| {
                let mut data = Vec::with_capacity(w * h * 3 / 2);
                for (plane, rows) in [(0, h), (1, h / 2)] {
                    for y in 0..rows {
                        let start = img.offsets[plane] as usize + y * img.pitches[plane] as usize;
                        data.extend_from_slice(&bytes[start..start + w]);
                    }
                }
                Nv12Picture { width, height, data }
            },
            |_| Ok(()),
        )
    }

    /// Writes packed NV12 into `surface` (`vaPutImage`): synthetic encoder input for the GPU tests, as
    /// `hevcfix.c` makes it.
    pub fn put_nv12(&self, surface: VASurfaceID, picture: &Nv12Picture) -> Result<(), VaError> {
        let (width, height) = (picture.width, picture.height);
        let (w, h) = (width as usize, height as usize);
        assert_eq!(picture.data.len(), w * h * 3 / 2, "packed NV12");
        self.with_image(
            width,
            height,
            |_| Ok(()),
            |img, bytes| {
                let mut src = picture.data.chunks_exact(w);
                for (plane, rows) in [(0, h), (1, h / 2)] {
                    for y in 0..rows {
                        let start = img.offsets[plane] as usize + y * img.pitches[plane] as usize;
                        bytes[start..start + w].copy_from_slice(src.next().expect("rows"));
                    }
                }
            },
            // SAFETY: ids and sizes within the image and the surface.
            |img| {
                check("vaPutImage", unsafe {
                    sys::vaPutImage(self.dpy, surface, img.image_id, 0, 0, width, height, 0, 0, width, height)
                })
            },
        )
    }
}

impl Drop for Display {
    fn drop(&mut self) {
        // SAFETY: the display was initialised in open and is terminated once, here; the fd is still open.
        unsafe { sys::vaTerminate(self.dpy) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn desc(width: u32, height: u32) -> sys::VADRMPRIMESurfaceDescriptor {
        // What radeonsi exported in glconv.c for 2752×2064: one object, Y pitch 2816, CbCr at 6 488 064, pitch 3072.
        let mut d = sys::VADRMPRIMESurfaceDescriptor {
            fourcc: sys::VA_FOURCC_NV12,
            width,
            height,
            num_objects: 1,
            num_layers: 2,
            ..Default::default()
        };
        d.objects[0].size = 10_027_008;
        d.objects[0].drm_format_modifier = 0x0200_0000_0040_1b03;
        d.layers[0] = sys::_VADRMPRIMESurfaceDescriptor__bindgen_ty_2 {
            drm_format: DRM_FORMAT_R8,
            num_planes: 1,
            object_index: [0; 4],
            offset: [0; 4],
            pitch: [2816, 0, 0, 0],
        };
        d.layers[1] = sys::_VADRMPRIMESurfaceDescriptor__bindgen_ty_2 {
            drm_format: DRM_FORMAT_GR88,
            num_planes: 1,
            object_index: [0; 4],
            offset: [6_488_064, 0, 0, 0],
            pitch: [3072, 0, 0, 0],
        };
        d
    }

    #[test]
    fn export_validation() {
        assert_eq!(Nv12Export::validate(&desc(2752, 2064), 2752, 2064), Ok(()));
        assert!(Nv12Export::validate(&desc(2752, 2064), 2064, 2752).is_err(), "size");
        let mut d = desc(2752, 2064);
        d.objects[0].size = 6_488_064 + 3072 * 1031;
        assert!(Nv12Export::validate(&d, 2752, 2064).unwrap_err().contains("exceeds"), "CbCr runs past the object");
        let mut d = desc(2752, 2064);
        d.layers[0].pitch[0] = 2000;
        assert!(Nv12Export::validate(&d, 2752, 2064).is_err(), "pitch below a row");
        let mut d = desc(2752, 2064);
        d.layers[1].drm_format = DRM_FORMAT_R8;
        assert!(Nv12Export::validate(&d, 2752, 2064).is_err(), "layer formats");
        let mut d = desc(2752, 2064);
        d.layers[1].object_index[0] = 1;
        assert!(Nv12Export::validate(&d, 2752, 2064).is_err(), "object out of range");
        let mut d = desc(2752, 2064);
        d.num_layers = 1;
        assert!(Nv12Export::validate(&d, 2752, 2064).is_err(), "one layer");
    }

    #[test]
    fn fourccs() {
        assert_eq!(DRM_FORMAT_R8, 0x2020_3852);
        assert_eq!(DRM_FORMAT_GR88, 0x3838_5247);
        assert_eq!(error_str(sys::VA_STATUS_SUCCESS as i32), "success (no error)");
    }
}
