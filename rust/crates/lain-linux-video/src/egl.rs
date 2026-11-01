//! The safe wrapper over EGL (`khronos-egl`, loaded at run time): a surfaceless GL 4.6 core context on the GBM
//! device, and DMA-BUF imports as EGLImages. A port of `spikes/linux-convert/gl/glconv.c`'s EGL setup; no Swift
//! counterpart.
//!
//! libEGL is loaded only by [`EglContext::new`], which refuses unless [`crate::env::check_environment`] passes,
//! so glvnd can only ever load Mesa's vendor library (decision L7). The context is made current on the thread
//! that creates it and is used only there: [`EglContext`] is neither `Send` nor `Sync`.
#![allow(unsafe_code)]

use std::ffi::c_void;
use std::os::fd::AsRawFd;
use std::rc::Rc;

use khronos_egl as egl;

use crate::frame::DmaBufPlane;
use crate::gbm::GbmDevice;

type Instance = egl::DynamicInstance<egl::EGL1_5>;

const PLATFORM_GBM_KHR: egl::Enum = 0x31D7;
const LINUX_DMA_BUF_EXT: egl::Enum = 0x3270;
const LINUX_DRM_FOURCC_EXT: egl::Attrib = 0x3271;
const DMA_BUF_PLANE0_FD_EXT: egl::Attrib = 0x3272;
const DMA_BUF_PLANE0_OFFSET_EXT: egl::Attrib = 0x3273;
const DMA_BUF_PLANE0_PITCH_EXT: egl::Attrib = 0x3274;
const DMA_BUF_PLANE0_MODIFIER_LO_EXT: egl::Attrib = 0x3443;
const DMA_BUF_PLANE0_MODIFIER_HI_EXT: egl::Attrib = 0x3444;

/// The EGL extensions the converter needs (as `glconv.c` checks them).
pub const REQUIRED_EXTENSIONS: &[&str] = &[
    "EGL_KHR_surfaceless_context",
    "EGL_KHR_no_config_context",
    "EGL_EXT_image_dma_buf_import",
    "EGL_EXT_image_dma_buf_import_modifiers",
];

/// Whether a space-separated extension list holds `name` exactly.
pub fn has_extension(list: &str, name: &str) -> bool {
    list.split_ascii_whitespace().any(|e| e == name)
}

/// An EGL display on the GBM device with a current GL 4.6 core context and no surface.
pub struct EglContext {
    egl: Instance,
    display: egl::Display,
    context: egl::Context,
    vendor: String,
    _gbm: Rc<GbmDevice>,
}

impl EglContext {
    /// Loads libEGL (after checking the environment pin), opens the GBM platform display on `gbm`, checks the
    /// extensions, creates the context and makes it current on this thread.
    pub fn new(gbm: Rc<GbmDevice>) -> Result<Rc<Self>, String> {
        crate::env::check_environment().map_err(|e| e.to_string())?;
        // SAFETY: libEGL.so.1 is glvnd's EGL, a conforming EGL 1.5 library; the environment check above means it
        // can only load Mesa's vendor library.
        let egl = unsafe { Instance::load_required() }.map_err(|e| format!("loading libEGL: {e}"))?;
        // SAFETY: the native display of the GBM platform is a live gbm_device, held by us for the display's life.
        let display = unsafe { egl.get_platform_display(PLATFORM_GBM_KHR, gbm.as_ptr(), &[egl::ATTRIB_NONE]) }
            .map_err(|e| format!("eglGetPlatformDisplay(GBM): {e}"))?;
        let (major, minor) = egl.initialize(display).map_err(|e| format!("eglInitialize: {e}"))?;
        let fail = |egl: &Instance, why: String| {
            let _ = egl.terminate(display);
            Err(why)
        };
        let query = |what| egl.query_string(Some(display), what).map(|s| s.to_string_lossy().into_owned());
        let extensions = query(egl::EXTENSIONS).unwrap_or_default();
        let vendor = format!("{} (EGL {major}.{minor})", query(egl::VENDOR).unwrap_or_default());
        if let Some(missing) = REQUIRED_EXTENSIONS.iter().find(|e| !has_extension(&extensions, e)) {
            return fail(&egl, format!("EGL lacks {missing}"));
        }
        if let Err(e) = egl.bind_api(egl::OPENGL_API) {
            return fail(&egl, format!("eglBindAPI(OpenGL): {e}"));
        }
        let attribs = [
            egl::CONTEXT_MAJOR_VERSION,
            4,
            egl::CONTEXT_MINOR_VERSION,
            6,
            egl::CONTEXT_OPENGL_PROFILE_MASK,
            egl::CONTEXT_OPENGL_CORE_PROFILE_BIT,
            egl::NONE,
        ];
        // SAFETY: EGL_NO_CONFIG_KHR (null) is a valid config with EGL_KHR_no_config_context, checked above.
        let no_config = unsafe { egl::Config::from_ptr(std::ptr::null_mut()) };
        let context = match egl.create_context(display, no_config, None, &attribs) {
            Ok(c) => c,
            Err(e) => return fail(&egl, format!("eglCreateContext(GL 4.6 core): {e}")),
        };
        if let Err(e) = egl.make_current(display, None, None, Some(context)) {
            let _ = egl.destroy_context(display, context);
            return fail(&egl, format!("eglMakeCurrent(surfaceless): {e}"));
        }
        Ok(Rc::new(Self { egl, display, context, vendor, _gbm: gbm }))
    }

    pub fn vendor(&self) -> &str {
        &self.vendor
    }

    /// A GL or EGL entry point (EGL 1.5 returns core GL functions too), or null.
    pub fn proc_address(&self, name: &str) -> *const c_void {
        self.egl.get_proc_address(name).map_or(std::ptr::null(), |f| f as *const c_void)
    }

    /// Whether this context is current on the calling thread.
    pub fn is_current(&self) -> bool {
        self.egl.get_current_context() == Some(self.context)
    }

    /// Imports one plane of a DMA-BUF as an EGLImage of `width × height`. EGL takes its own reference to the
    /// buffer: the fd may be closed after this returns.
    pub fn import(self: &Rc<Self>, plane: &DmaBufPlane, width: u32, height: u32) -> Result<EglImage, String> {
        let attribs = [
            egl::WIDTH as egl::Attrib,
            width as egl::Attrib,
            egl::HEIGHT as egl::Attrib,
            height as egl::Attrib,
            LINUX_DRM_FOURCC_EXT,
            plane.fourcc as egl::Attrib,
            DMA_BUF_PLANE0_FD_EXT,
            plane.fd.as_raw_fd() as egl::Attrib,
            DMA_BUF_PLANE0_OFFSET_EXT,
            plane.offset as egl::Attrib,
            DMA_BUF_PLANE0_PITCH_EXT,
            plane.stride as egl::Attrib,
            DMA_BUF_PLANE0_MODIFIER_LO_EXT,
            (plane.modifier & 0xFFFF_FFFF) as egl::Attrib,
            DMA_BUF_PLANE0_MODIFIER_HI_EXT,
            (plane.modifier >> 32) as egl::Attrib,
            egl::ATTRIB_NONE,
        ];
        // SAFETY: EGL_NO_CONTEXT and a null client buffer are what EGL_LINUX_DMA_BUF_EXT takes; the fd is open
        // for the call.
        let (no_context, no_buffer) =
            unsafe { (egl::Context::from_ptr(egl::NO_CONTEXT), egl::ClientBuffer::from_ptr(std::ptr::null_mut())) };
        let image = self.egl.create_image(self.display, no_context, LINUX_DMA_BUF_EXT, no_buffer, &attribs).map_err(|e| {
            format!(
                "eglCreateImage({:?} {width}×{height}, modifier {:#x}, pitch {}): {e}",
                plane.fourcc.to_le_bytes().map(char::from),
                plane.modifier,
                plane.stride
            )
        })?;
        Ok(EglImage { image, ctx: self.clone() })
    }
}

impl Drop for EglContext {
    fn drop(&mut self) {
        let _ = self.egl.make_current(self.display, None, None, None);
        let _ = self.egl.destroy_context(self.display, self.context);
        let _ = self.egl.terminate(self.display);
    }
}

/// An imported DMA-BUF. Destroyed on drop (after the textures made from it: their owner drops them first).
pub struct EglImage {
    image: egl::Image,
    ctx: Rc<EglContext>,
}

impl EglImage {
    /// The `GLeglImageOES` handle.
    pub fn as_ptr(&self) -> *mut c_void {
        self.image.as_ptr()
    }
}

impl Drop for EglImage {
    fn drop(&mut self) {
        let _ = self.ctx.egl.destroy_image(self.ctx.display, self.image);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_lists() {
        let list = "EGL_KHR_image_base EGL_EXT_image_dma_buf_import EGL_EXT_image_dma_buf_import_modifiers";
        assert!(has_extension(list, "EGL_EXT_image_dma_buf_import"));
        assert!(has_extension(list, "EGL_EXT_image_dma_buf_import_modifiers"));
        assert!(!has_extension(list, "EGL_KHR_image"), "whole names only");
        assert!(!has_extension("", "EGL_KHR_image_base"));
    }
}
