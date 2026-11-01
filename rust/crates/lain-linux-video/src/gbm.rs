//! The safe wrapper over GBM (the raw bindings are `ffi::gbm`): the device EGL runs on, on the render node's fd
//! (as `spikes/linux-convert/gl/glconv.c`), and buffer objects at Mutter's modifier for the GPU tests' synthetic
//! input. No Swift counterpart.
#![allow(unsafe_code)]

use std::ffi::CStr;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::rc::Rc;
use std::sync::Arc;

use crate::ffi::gbm as sys;

/// DRM fourcc `XR24` (`DRM_FORMAT_XRGB8888`, BGRx in memory) and `AR24` (`DRM_FORMAT_ARGB8888`, BGRA).
pub const DRM_FORMAT_XRGB8888: u32 = u32::from_le_bytes(*b"XR24");
pub const DRM_FORMAT_ARGB8888: u32 = u32::from_le_bytes(*b"AR24");
/// The modifier Mutter's BGRx buffers carried on this iGPU (spike A, SL5): AMD GFX10.3 tiled, DCC off.
pub const MUTTER_MODIFIER: u64 = 0x0200_0000_0040_1b03;

/// A GBM device on the render node's fd. Destroyed on drop, after every buffer object made from it.
pub struct GbmDevice {
    dev: *mut sys::gbm_device,
    _fd: Arc<OwnedFd>,
}

impl GbmDevice {
    /// `gbm_create_device` on `fd`, the AMD render node (GBM loads Mesa's backend for an amdgpu fd).
    pub fn new(fd: Arc<OwnedFd>) -> Result<Rc<Self>, String> {
        // SAFETY: the fd is open, and stays open for the device's life (we hold it).
        let dev = unsafe { sys::gbm_create_device(fd.as_raw_fd()) };
        if dev.is_null() {
            return Err(format!("gbm_create_device: {}", std::io::Error::last_os_error()));
        }
        Ok(Rc::new(Self { dev, _fd: fd }))
    }

    /// The pointer EGL's GBM platform takes as its native display.
    pub fn as_ptr(&self) -> *mut std::ffi::c_void {
        self.dev.cast()
    }

    pub fn backend_name(&self) -> String {
        // SAFETY: a live device; the name is a static string.
        let p = unsafe { sys::gbm_device_get_backend_name(self.dev) };
        if p.is_null() {
            return String::new();
        }
        // SAFETY: a NUL-terminated static string.
        unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
    }

    /// A buffer object of `width × height` in `format` with exactly `modifier`, for rendering, validated: one
    /// plane, that modifier, that size, a stride covering a row, offset 0 (as `glconv.c` checks its input ring).
    pub fn create_bo(self: &Rc<Self>, width: u32, height: u32, format: u32, modifier: u64) -> Result<Bo, String> {
        let modifiers = [modifier];
        // SAFETY: a live device; the modifier list holds one entry.
        let bo = unsafe {
            sys::gbm_bo_create_with_modifiers2(
                self.dev,
                width,
                height,
                format,
                modifiers.as_ptr(),
                1,
                sys::GBM_BO_USE_RENDERING,
            )
        };
        if bo.is_null() {
            return Err(format!(
                "gbm_bo_create_with_modifiers2 ({width}×{height}, modifier {modifier:#x}): {}",
                std::io::Error::last_os_error()
            ));
        }
        let bo = Bo { bo, _dev: self.clone() };
        let (planes, got) = (bo.plane_count(), bo.modifier());
        if got != modifier
            || planes != 1
            || bo.width() != width
            || bo.height() != height
            || bo.stride() < width * 4
            || bo.offset() != 0
        {
            return Err(format!(
                "the buffer object came out unexpected: modifier {got:#x}, {planes} planes, {}×{}, stride {}, offset {}",
                bo.width(),
                bo.height(),
                bo.stride(),
                bo.offset()
            ));
        }
        Ok(bo)
    }
}

impl Drop for GbmDevice {
    fn drop(&mut self) {
        // SAFETY: created in new; every Bo holds an Rc of this device, so none outlives it.
        unsafe { sys::gbm_device_destroy(self.dev) };
    }
}

/// One GBM buffer object (single plane).
pub struct Bo {
    bo: *mut sys::gbm_bo,
    _dev: Rc<GbmDevice>,
}

impl Bo {
    pub fn width(&self) -> u32 {
        // SAFETY: a live buffer object.
        unsafe { sys::gbm_bo_get_width(self.bo) }
    }

    pub fn height(&self) -> u32 {
        // SAFETY: a live buffer object.
        unsafe { sys::gbm_bo_get_height(self.bo) }
    }

    pub fn modifier(&self) -> u64 {
        // SAFETY: a live buffer object.
        unsafe { sys::gbm_bo_get_modifier(self.bo) }
    }

    pub fn plane_count(&self) -> i32 {
        // SAFETY: a live buffer object.
        unsafe { sys::gbm_bo_get_plane_count(self.bo) }
    }

    pub fn stride(&self) -> u32 {
        // SAFETY: plane 0 of a live buffer object.
        unsafe { sys::gbm_bo_get_stride_for_plane(self.bo, 0) }
    }

    pub fn offset(&self) -> u32 {
        // SAFETY: plane 0 of a live buffer object.
        unsafe { sys::gbm_bo_get_offset(self.bo, 0) }
    }

    /// A new DMA-BUF fd for plane 0, owned by the caller.
    pub fn fd(&self) -> Result<OwnedFd, String> {
        // SAFETY: plane 0 of a live buffer object; the result is a new fd or -1.
        let fd = unsafe { sys::gbm_bo_get_fd_for_plane(self.bo, 0) };
        if fd < 0 {
            return Err(format!("gbm_bo_get_fd_for_plane: {}", std::io::Error::last_os_error()));
        }
        // SAFETY: a fresh fd that nothing else owns.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }
}

impl Drop for Bo {
    fn drop(&mut self) {
        // SAFETY: created by create_bo and destroyed once, before the device (we hold an Rc of it).
        unsafe { sys::gbm_bo_destroy(self.bo) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fourccs() {
        assert_eq!(DRM_FORMAT_XRGB8888, 0x3432_5258);
        assert_eq!(DRM_FORMAT_ARGB8888, 0x3432_5241);
    }
}
