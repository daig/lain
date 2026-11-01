//! The real [`Gpu`]: one render node, opened once, serving GBM, EGL (the converter) and VA (the encoder), with
//! the NV12 surfaces they share (SL5's zero-copy handoff). Built and used on the video thread, where the GL
//! context is current. A port of the setup in `spikes/linux-convert/e2e/e2e.c` (which opened the node three
//! times; here one fd serves all three, as the brief asks). No Swift counterpart.

use std::os::fd::OwnedFd;
use std::rc::Rc;
use std::sync::Arc;

use crate::device::{self, RenderNode};
use crate::egl::EglContext;
use crate::encoder::{self, EncoderSettings, HevcEncoder, PictureKind};
use crate::engine::Gpu;
use crate::frame::Picture;
use crate::gbm::GbmDevice;
use crate::gl::GlConverter;
use crate::va::{Display, VASurfaceID};

/// How many NV12 surfaces: the newest capture, the one encoding, the one converting, and one spare.
pub const SURFACES: usize = 4;

/// What the pipeline is set up for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GpuSettings {
    pub encoder: EncoderSettings,
    /// The DMA-BUF modifier of the captured pictures.
    pub modifier: u64,
}

/// The GPU side of a video session.
pub struct GpuPipeline {
    // Dropped first, in this order: the GL objects, then the encode session; the surfaces in Drop.
    converter: Option<GlConverter>,
    encoder: Option<HevcEncoder>,
    surfaces: Vec<VASurfaceID>,
    egl: Rc<EglContext>,
    va: Rc<Display>,
    gbm: Rc<GbmDevice>,
    node: RenderNode,
    settings: GpuSettings,
}

impl GpuPipeline {
    /// Opens `node` (checking it is that device), and sets up VA, the encoder, GBM, EGL and the converter on its
    /// one fd. The EGL context becomes current on the calling thread.
    pub fn new(node: &RenderNode, settings: GpuSettings) -> Result<Self, String> {
        let fd: Arc<OwnedFd> = Arc::new(device::open_render_node(node).map_err(|e| e.to_string())?);
        let va = Rc::new(Display::open(fd.clone()).map_err(|e| e.to_string())?);
        encoder::check_support(&va)?;
        let s = settings.encoder;
        let (cw, ch) = s.headers().coded_size();
        let hint =
            crate::ffi::va::VA_SURFACE_ATTRIB_USAGE_HINT_ENCODER | crate::ffi::va::VA_SURFACE_ATTRIB_USAGE_HINT_EXPORT;
        let surfaces = va.create_surfaces(cw, ch, SURFACES, Some(hint)).map_err(|e| e.to_string())?;
        let fail = |va: &Display, e: String| {
            va.destroy_surfaces(&surfaces);
            Err(e)
        };
        let encoder = match HevcEncoder::new(va.clone(), s, &surfaces) {
            Ok(e) => e,
            Err(e) => return fail(&va, e.to_string()),
        };
        let mut exports = Vec::new();
        for &surface in &surfaces {
            match va.export_nv12(surface, cw, ch) {
                Ok(x) => exports.push(x),
                Err(e) => {
                    drop(encoder);
                    return fail(&va, e);
                }
            }
        }
        let setup = || -> Result<(Rc<GbmDevice>, Rc<EglContext>, GlConverter), String> {
            let gbm = GbmDevice::new(fd.clone())?;
            let egl = EglContext::new(gbm.clone())?;
            let converter = GlConverter::new(egl.clone(), &exports, (cw, ch), s.width, s.height, settings.modifier)?;
            Ok((gbm, egl, converter))
        };
        let (gbm, egl, converter) = match setup() {
            Ok(x) => x,
            Err(e) => {
                drop(encoder);
                return fail(&va, e);
            }
        };
        tracing::info!(
            node = %node.path.display(),
            pci = node.pci.as_deref().unwrap_or("?"),
            va = va.vendor(),
            egl = egl.vendor(),
            gl = converter.renderer(),
            gbm = gbm.backend_name(),
            "video's GPU pipeline is ready"
        );
        Ok(Self {
            converter: Some(converter),
            encoder: Some(encoder),
            surfaces,
            egl,
            va,
            gbm,
            node: node.clone(),
            settings,
        })
    }

    pub fn node(&self) -> &RenderNode {
        &self.node
    }

    pub fn settings(&self) -> GpuSettings {
        self.settings
    }

    pub fn va(&self) -> &Rc<Display> {
        &self.va
    }

    pub fn gbm(&self) -> &Rc<GbmDevice> {
        &self.gbm
    }

    pub fn egl(&self) -> &Rc<EglContext> {
        &self.egl
    }

    pub fn surface_ids(&self) -> &[VASurfaceID] {
        &self.surfaces
    }

    pub fn converter(&mut self) -> &mut GlConverter {
        self.converter.as_mut().expect("the converter lives until drop")
    }

    pub fn encoder(&mut self) -> &mut HevcEncoder {
        self.encoder.as_mut().expect("the encoder lives until drop")
    }
}

impl Gpu for GpuPipeline {
    fn surfaces(&self) -> usize {
        self.surfaces.len()
    }

    fn start_conversion(&mut self, picture: &Picture, surface: usize) -> Result<(), String> {
        let (w, h) = (self.settings.encoder.width, self.settings.encoder.height);
        if (picture.width, picture.height) != (w, h) {
            return Err(format!("a {}×{} picture for a {w}×{h} stream", picture.width, picture.height));
        }
        self.converter().convert(&picture.pixels, surface)
    }

    fn poll_conversion(&mut self, timeout_ns: u64) -> Result<bool, String> {
        self.converter().poll(timeout_ns)
    }

    fn cancel_conversion(&mut self) {
        self.converter().cancel();
    }

    fn submit_encode(&mut self, surface: usize, kind: PictureKind) -> Result<(), String> {
        let id = *self.surfaces.get(surface).ok_or("no such surface")?;
        self.encoder().submit(id, kind).map_err(|e| e.to_string())
    }

    fn poll_encode(&mut self, timeout_ns: u64) -> Option<Result<Vec<u8>, String>> {
        self.encoder().poll(timeout_ns).map(|r| r.map(|p| p.annexb).map_err(|e| e.to_string()))
    }

    fn rebuild_encoder(&mut self) -> Result<(), String> {
        self.encoder().rebuild().map_err(|e| e.to_string())
    }
}

impl Drop for GpuPipeline {
    fn drop(&mut self) {
        self.converter = None;
        self.encoder = None;
        self.va.destroy_surfaces(&self.surfaces);
    }
}
