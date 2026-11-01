//! Pinning GStreamer's VA plugin to the AMD render node.
//!
//! With no display context, every `va*` element probes the DRM render nodes when it reaches READY
//! (`vadisplaydrm` opens renderD128 and renderD129, the NVIDIA cards, and tries to load a VA driver for
//! them). That only fails harmlessly because no NVIDIA VA driver is installed. So this:
//! 1. picks the render node whose PCI vendor is 0x1002 from sysfs (never opening another node);
//! 2. picks the per-device element factories whose class `device-path` is that node (the plain names
//!    `vapostproc` and `vah265enc` belong to whichever device the registry scan listed first);
//! 3. builds a `GstVaDisplayDrm` on that node (`gst_va_display_drm_new_from_path`) and wraps it in a
//!    `gst.va.display.handle` context, which every pipeline gets before it leaves NULL, so no element
//!    queries for, or opens, a display of its own.
//!
//! `nvidia-guard.sh` checks the result: it fails any open of a non-AMD GPU node.

use std::ffi::{CString, c_char};

use gstreamer as gst;
use gstreamer::glib::translate::FromGlibPtrFull;
use gstreamer::prelude::*;

#[allow(unsafe_code)]
unsafe extern "C" {
    // libgstva-1.0 (no development package here, so declared by hand; linked in build.rs).
    fn gst_va_display_drm_new_from_path(path: *const c_char) -> *mut gst::ffi::GstObject;
    fn gst_context_set_va_display(context: *mut gst::ffi::GstContext, display: *mut gst::ffi::GstObject);
}

pub struct Va {
    pub node: String,
    pub postproc: String,
    pub h265enc: String,
    pub h264enc: Option<String>,
    pub context: gst::Context,
}

fn vendor_of(node: &str) -> Option<String> {
    let name = node.trim_start_matches("/dev/dri/");
    std::fs::read_to_string(format!("/sys/class/drm/{name}/device/vendor")).ok().map(|v| v.trim().to_string())
}

/// The AMD render node: `wanted` if given (and AMD), else the only render node with vendor 0x1002.
pub fn amd_render_node(wanted: Option<&str>) -> String {
    if let Some(w) = wanted {
        assert_eq!(vendor_of(w).as_deref(), Some("0x1002"), "{w} is not an AMD render node");
        return w.to_string();
    }
    let mut amd: Vec<String> = std::fs::read_dir("/sys/class/drm")
        .expect("/sys/class/drm")
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n.starts_with("renderD"))
        .map(|n| format!("/dev/dri/{n}"))
        .filter(|n| vendor_of(n).as_deref() == Some("0x1002"))
        .collect();
    amd.sort();
    assert!(!amd.is_empty(), "no AMD render node");
    amd.remove(0)
}

/// The `va` element factory of `suffix` (e.g. "postproc", "h265enc") whose device is `node`. Creating an
/// element doesn't open its device; that happens at READY.
fn factory_for(node: &str, suffix: &str) -> Option<String> {
    let reg = gst::Registry::get();
    let mut names: Vec<String> = reg
        .features_by_plugin("va")
        .into_iter()
        .filter_map(|f| f.downcast::<gst::ElementFactory>().ok())
        .map(|f| f.name().to_string())
        .filter(|n| n.ends_with(suffix) && !n.ends_with(&format!("lp{suffix}")))
        .collect();
    names.sort();
    names.into_iter().find(|n| {
        gst::ElementFactory::make(n)
            .build()
            .ok()
            .is_some_and(|e| e.find_property("device-path").is_some() && e.property::<String>("device-path") == node)
    })
}

impl Va {
    pub fn new(wanted: Option<&str>) -> Va {
        let node = amd_render_node(wanted);
        let postproc = factory_for(&node, "postproc").unwrap_or_else(|| panic!("no VA postproc on {node}"));
        let h265enc = factory_for(&node, "h265enc").unwrap_or_else(|| panic!("no VA HEVC encoder on {node}"));
        let h264enc = factory_for(&node, "h264enc");
        let mut context = gst::Context::new("gst.va.display.handle", true);
        let path = CString::new(node.as_str()).unwrap();
        // SAFETY: the path is a valid C string. The display is a new GstObject (full ref) or NULL;
        // gst_context_set_va_display takes its own ref, so ours is released after.
        #[allow(unsafe_code)]
        unsafe {
            let display = gst_va_display_drm_new_from_path(path.as_ptr());
            assert!(!display.is_null(), "VA display on {node} failed");
            gst_context_set_va_display(context.get_mut().unwrap().as_mut_ptr(), display);
            drop(gst::Object::from_glib_full(display));
        }
        println!("va: {node} ({postproc}, {h265enc}), display context pinned");
        Va { node, postproc, h265enc, h264enc, context }
    }

    /// Gives `pipeline` the pinned display, before it leaves NULL.
    pub fn pin(&self, pipeline: &gst::Pipeline) {
        assert_eq!(pipeline.current_state(), gst::State::Null, "pin the VA display before starting");
        pipeline.set_context(&self.context);
    }
}

/// Panics if this process holds any GPU device node that isn't AMD (a probe that opens and closes a node
/// is caught by `nvidia-guard.sh`, not by this).
pub fn assert_no_foreign_gpu_fds() {
    for fd in std::fs::read_dir("/proc/self/fd").into_iter().flatten().flatten() {
        let Ok(target) = std::fs::read_link(fd.path()) else { continue };
        let t = target.to_string_lossy();
        if t.starts_with("/dev/nvidia") || (t.starts_with("/dev/dri/") && vendor_of(&t).as_deref() != Some("0x1002")) {
            panic!("this process holds {t}, which is not the AMD GPU");
        }
    }
}
