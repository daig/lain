//! The BGRx → NV12 conversion: one GL compute pass written straight into libva's exported NV12 encoder surfaces
//! (SL5; lead's decision, wave 3 prep). A port of `spikes/linux-convert/gl/glconv.c` and the GL path of
//! `e2e/e2e.c`. No Swift counterpart: ScreenCaptureKit delivers YCbCr.
//!
//! - BT.709 full range on the non-linear values, one 2×2 block per invocation, 16×8 workgroups.
//! - The input is read with `texelFetch`: Mesa imports XR24 as `GL_RGB8`, which isn't an image-unit format, so
//!   `imageLoad` silently returns garbage (SL5).
//! - The output is each surface's R8 (luma) and GR88 (chroma) layer, imported from `vaExportSurfaceHandle` and
//!   written with `imageStore`: zero-copy.
//! - Each conversion ends with a GL fence, polled by [`GlConverter::poll`]; the encoder may read the surface
//!   only once it has signalled (SL5: "wait on the conversion's fence before `vaBeginPicture`").
//! - Imports are cached per DMA-BUF (by inode), as `e2e.c` imports each PipeWire buffer once.
//!
//! The GL context is current on the converter's thread only; every call here runs there.
#![allow(unsafe_code)]

use std::ffi::c_void;
use std::rc::Rc;

use glow::HasContext;

use crate::egl::{EglContext, EglImage};
use crate::frame::{DmaBufPlane, Pixels, validate_dmabuf, validate_memory};
use crate::va::Nv12Export;

/// The compute shader of `e2e.c` (16×8, `texelFetch` input).
pub const SHADER: &str = "#version 430
layout(local_size_x = 16, local_size_y = 8) in;
layout(binding = 0) uniform sampler2D src;
layout(binding = 1, r8) writeonly uniform image2D ypl;
layout(binding = 2, rg8) writeonly uniform image2D uvpl;
uniform ivec2 blocks;
const vec3 K = vec3(0.2126, 0.7152, 0.0722);
vec3 load(ivec2 p) { return texelFetch(src, p, 0).rgb; }
void main() {
    ivec2 b = ivec2(gl_GlobalInvocationID.xy);
    if (b.x >= blocks.x || b.y >= blocks.y) return;
    ivec2 p = b * 2;
    vec3 c00 = load(p), c10 = load(p + ivec2(1, 0)), c01 = load(p + ivec2(0, 1)), c11 = load(p + ivec2(1, 1));
    imageStore(ypl, p, vec4(dot(K, c00)));
    imageStore(ypl, p + ivec2(1, 0), vec4(dot(K, c10)));
    imageStore(ypl, p + ivec2(0, 1), vec4(dot(K, c01)));
    imageStore(ypl, p + ivec2(1, 1), vec4(dot(K, c11)));
    vec3 m = (c00 + c10 + c01 + c11) * 0.25;
    float ym = dot(K, m);
    imageStore(uvpl, b, vec4((m.b - ym) / 1.8556 + 128.0 / 255.0, (m.r - ym) / 1.5748 + 128.0 / 255.0, 0.0, 0.0));
}
";

const WORKGROUP: (u32, u32) = (16, 8);
/// How many DMA-BUF imports are kept: PipeWire's pool is a handful of buffers (e2e asked for 3–8).
const IMPORT_CACHE: usize = 8;

/// `glEGLImageTargetTexStorageEXT` (GL_EXT_EGL_image_storage), not in glow.
type ImageTargetTexStorage = unsafe extern "system" fn(target: u32, image: *mut c_void, attribs: *const i32);

struct Target {
    y: glow::NativeTexture,
    uv: glow::NativeTexture,
    _images: [EglImage; 2],
}

struct Import {
    key: (u64, u64, u32, u32, u64),
    texture: glow::NativeTexture,
    _image: EglImage,
    last_used: u64,
}

/// GPU time of a conversion, from timer queries, when they are read.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ConversionTiming {
    pub gpu_ns: u64,
}

/// The converter: the shader, the target surfaces' layers as images, the import cache, and the fence of the
/// conversion in flight.
pub struct GlConverter {
    gl: glow::Context,
    egl: Rc<EglContext>,
    tex_storage: ImageTargetTexStorage,
    program: glow::NativeProgram,
    blocks: Option<glow::NativeUniformLocation>,
    targets: Vec<Target>,
    imports: Vec<Import>,
    staging: Option<glow::NativeTexture>,
    fence: Option<glow::NativeFence>,
    queries: [glow::NativeQuery; 2],
    width: u32,
    height: u32,
    modifier: u64,
    uses: u64,
    renderer: String,
}

fn gl_error(gl: &glow::Context, what: &str) -> Result<(), String> {
    // SAFETY: the context is current on this thread (the converter's invariant).
    let e = unsafe { gl.get_error() };
    if e == glow::NO_ERROR { Ok(()) } else { Err(format!("{what}: GL error {e:#x}")) }
}

impl GlConverter {
    /// Sets the converter up on `egl` (current on this thread) for `width × height` pictures at `modifier`
    /// (the DMA-BUFs' negotiated modifier), writing into `exports` (the encoder's NV12 surfaces, in order).
    pub fn new(egl: Rc<EglContext>, exports: &[Nv12Export], width: u32, height: u32, modifier: u64) -> Result<Self, String> {
        if !egl.is_current() {
            return Err("the EGL context isn't current on the converter's thread".into());
        }
        if width % 2 != 0 || height % 2 != 0 {
            return Err(format!("{width}×{height}: 4:2:0 needs an even size"));
        }
        // SAFETY: the context is current; the loader returns EGL's entry points (null for missing ones, which
        // glow then reports as missing functions when called; the ones used are all GL 4.3 core).
        let gl = unsafe { glow::Context::from_loader_function(|name| egl.proc_address(name)) };
        let storage = egl.proc_address("glEGLImageTargetTexStorageEXT");
        // SAFETY: the context is current.
        let (renderer, has_storage) = unsafe {
            let renderer = gl.get_parameter_string(glow::RENDERER);
            (renderer, gl.supported_extensions().contains("GL_EXT_EGL_image_storage"))
        };
        if storage.is_null() || !has_storage {
            return Err(format!("{renderer} lacks GL_EXT_EGL_image_storage"));
        }
        // SAFETY: a non-null pointer to glEGLImageTargetTexStorageEXT, whose C type this is.
        let tex_storage = unsafe { std::mem::transmute::<*const c_void, ImageTargetTexStorage>(storage) };
        // SAFETY: the context is current; every object made here is owned by the converter and deleted on drop.
        let (program, blocks, queries) = unsafe {
            let shader = gl.create_shader(glow::COMPUTE_SHADER)?;
            gl.shader_source(shader, SHADER);
            gl.compile_shader(shader);
            if !gl.get_shader_compile_status(shader) {
                let log = gl.get_shader_info_log(shader);
                gl.delete_shader(shader);
                return Err(format!("compiling the conversion shader: {log}"));
            }
            let program = gl.create_program()?;
            gl.attach_shader(program, shader);
            gl.link_program(program);
            gl.delete_shader(shader);
            if !gl.get_program_link_status(program) {
                let log = gl.get_program_info_log(program);
                gl.delete_program(program);
                return Err(format!("linking the conversion shader: {log}"));
            }
            let blocks = gl.get_uniform_location(program, "blocks");
            (program, blocks, [gl.create_query()?, gl.create_query()?])
        };
        let mut conv = Self {
            gl,
            egl,
            tex_storage,
            program,
            blocks,
            targets: Vec::new(),
            imports: Vec::new(),
            staging: None,
            fence: None,
            queries,
            width,
            height,
            modifier,
            uses: 0,
            renderer,
        };
        for export in exports {
            let target = conv.import_target(export)?;
            conv.targets.push(target);
        }
        Ok(conv)
    }

    pub fn renderer(&self) -> &str {
        &self.renderer
    }

    /// A texture backed by `image`.
    fn texture_of(&self, image: &EglImage, what: &str) -> Result<glow::NativeTexture, String> {
        // SAFETY: the context is current; the image is live; the texture is owned by the caller.
        unsafe {
            let t = self.gl.create_texture()?;
            self.gl.bind_texture(glow::TEXTURE_2D, Some(t));
            (self.tex_storage)(glow::TEXTURE_2D, image.as_ptr(), std::ptr::null());
            self.gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_MIN_FILTER, glow::NEAREST as i32);
            self.gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_MAG_FILTER, glow::NEAREST as i32);
            self.gl.bind_texture(glow::TEXTURE_2D, None);
            if let Err(e) = gl_error(&self.gl, what) {
                self.gl.delete_texture(t);
                return Err(e);
            }
            Ok(t)
        }
    }

    fn import_target(&self, export: &Nv12Export) -> Result<Target, String> {
        if export.width != self.width || export.height != self.height {
            return Err(format!("a surface of {}×{}, not {}×{}", export.width, export.height, self.width, self.height));
        }
        let mut images = Vec::new();
        for (l, layer) in export.layers.iter().enumerate() {
            let object = &export.objects[layer.object];
            let plane = DmaBufPlane {
                fd: object.fd.try_clone().map_err(|e| format!("dup: {e}"))?,
                fourcc: layer.drm_format,
                modifier: object.modifier,
                offset: layer.offset,
                stride: layer.pitch,
                size: u64::from(object.size),
            };
            let (w, h) = if l == 0 { (self.width, self.height) } else { (self.width / 2, self.height / 2) };
            images.push(self.egl.import(&plane, w, h)?);
        }
        let [y_image, uv_image]: [EglImage; 2] = images.try_into().map_err(|_| "two layers")?;
        let y = self.texture_of(&y_image, "the NV12 surface's Y layer")?;
        let uv = match self.texture_of(&uv_image, "the NV12 surface's CbCr layer") {
            Ok(t) => t,
            Err(e) => {
                // SAFETY: the context is current; y is ours.
                unsafe { self.gl.delete_texture(y) };
                return Err(e);
            }
        };
        Ok(Target { y, uv, _images: [y_image, uv_image] })
    }

    /// The texture of a DMA-BUF: imported once and cached by (inode, device, offset, stride, modifier), as
    /// PipeWire cycles through the same few buffers.
    fn dmabuf_texture(&mut self, plane: &DmaBufPlane) -> Result<glow::NativeTexture, String> {
        validate_dmabuf(plane, self.width, self.height, self.modifier)?;
        let st = rustix::fs::fstat(&plane.fd).map_err(|e| format!("fstat of the DMA-BUF: {e}"))?;
        let key = (st.st_ino, st.st_dev, plane.offset, plane.stride, plane.modifier);
        self.uses += 1;
        if let Some(hit) = self.imports.iter_mut().find(|i| i.key == key) {
            hit.last_used = self.uses;
            return Ok(hit.texture);
        }
        let image = self.egl.import(plane, self.width, self.height)?;
        let texture = self.texture_of(&image, "the captured DMA-BUF")?;
        if self.imports.len() >= IMPORT_CACHE
            && let Some(oldest) = self.imports.iter().enumerate().min_by_key(|(_, i)| i.last_used).map(|(n, _)| n)
        {
            let old = self.imports.swap_remove(oldest);
            // SAFETY: the context is current; the texture is ours and no conversion in flight reads it (the
            // caller waits for the fence before starting another conversion).
            unsafe { self.gl.delete_texture(old.texture) };
        }
        self.imports.push(Import { key, texture, _image: image, last_used: self.uses });
        Ok(texture)
    }

    /// The staging texture for shared-memory pictures, uploaded from the CPU (spike A: +6 ms against DMA-BUF).
    fn memory_texture(&mut self, data: &[u8], stride: u32) -> Result<glow::NativeTexture, String> {
        validate_memory(data, stride, self.width, self.height)?;
        let (w, h) = (self.width as i32, self.height as i32);
        // SAFETY: the context is current; the texture is ours; `data` holds `height` rows of `stride` bytes
        // (validated), which GL reads with UNPACK_ROW_LENGTH = stride / 4.
        unsafe {
            let texture = match self.staging {
                Some(t) => t,
                None => {
                    let t = self.gl.create_texture()?;
                    self.gl.bind_texture(glow::TEXTURE_2D, Some(t));
                    self.gl.tex_storage_2d(glow::TEXTURE_2D, 1, glow::RGBA8, w, h);
                    self.staging = Some(t);
                    t
                }
            };
            self.gl.bind_texture(glow::TEXTURE_2D, Some(texture));
            self.gl.pixel_store_i32(glow::UNPACK_ROW_LENGTH, (stride / 4) as i32);
            self.gl.tex_sub_image_2d(
                glow::TEXTURE_2D,
                0,
                0,
                0,
                w,
                h,
                glow::BGRA,
                glow::UNSIGNED_BYTE,
                glow::PixelUnpackData::Slice(Some(data)),
            );
            self.gl.pixel_store_i32(glow::UNPACK_ROW_LENGTH, 0);
            self.gl.bind_texture(glow::TEXTURE_2D, None);
            gl_error(&self.gl, "uploading a shared-memory picture")?;
            Ok(texture)
        }
    }

    /// Starts converting `pixels` into target surface `target`. One conversion at a time: the previous one must
    /// have been polled to completion.
    pub fn convert(&mut self, pixels: &Pixels, target: usize) -> Result<(), String> {
        if self.fence.is_some() {
            return Err("a conversion is already in flight".into());
        }
        let Some(out) = self.targets.get(target).map(|t| (t.y, t.uv)) else {
            return Err(format!("no target surface {target}"));
        };
        let src = match pixels {
            Pixels::DmaBuf(plane) => self.dmabuf_texture(plane)?,
            Pixels::Memory { data, stride } => self.memory_texture(data, *stride)?,
        };
        let (bx, by) = (self.width / 2, self.height / 2);
        // SAFETY: the context is current; every object is ours and live; the dispatch covers the blocks and the
        // shader bounds-checks the rest.
        unsafe {
            let gl = &self.gl;
            gl.use_program(Some(self.program));
            gl.uniform_2_i32(self.blocks.as_ref(), bx as i32, by as i32);
            gl.active_texture(glow::TEXTURE0);
            gl.bind_texture(glow::TEXTURE_2D, Some(src));
            gl.bind_image_texture(1, Some(out.0), 0, false, 0, glow::WRITE_ONLY, glow::R8);
            gl.bind_image_texture(2, Some(out.1), 0, false, 0, glow::WRITE_ONLY, glow::RG8);
            gl.query_counter(self.queries[0], glow::TIMESTAMP);
            gl.dispatch_compute(bx.div_ceil(WORKGROUP.0), by.div_ceil(WORKGROUP.1), 1);
            gl.query_counter(self.queries[1], glow::TIMESTAMP);
            let fence = gl.fence_sync(glow::SYNC_GPU_COMMANDS_COMPLETE, 0)?;
            gl.flush();
            self.fence = Some(fence);
            gl_error(gl, "dispatching the conversion")
        }
    }

    /// Waits up to `timeout_ns` (at most 2 s) for the conversion in flight: `Ok(true)` once it has finished (or if
    /// none is in flight), `Ok(false)` on timeout.
    pub fn poll(&mut self, timeout_ns: u64) -> Result<bool, String> {
        let Some(fence) = self.fence else { return Ok(true) };
        let timeout = timeout_ns.min(2_000_000_000) as i32;
        // SAFETY: the context is current; the fence is ours.
        let status = unsafe { self.gl.client_wait_sync(fence, glow::SYNC_FLUSH_COMMANDS_BIT, timeout) };
        match status {
            glow::ALREADY_SIGNALED | glow::CONDITION_SATISFIED => {
                // SAFETY: as above; the fence is deleted once.
                unsafe { self.gl.delete_sync(fence) };
                self.fence = None;
                Ok(true)
            }
            glow::TIMEOUT_EXPIRED => Ok(false),
            _ => {
                // SAFETY: as above.
                unsafe { self.gl.delete_sync(fence) };
                self.fence = None;
                Err("glClientWaitSync failed".into())
            }
        }
    }

    /// The last finished conversion's GPU time (timer queries). Call after [`poll`](Self::poll) returned true.
    pub fn last_timing(&self) -> ConversionTiming {
        // SAFETY: the context is current; both queries finished with the conversion (its fence signalled).
        let (a, b) = unsafe {
            (
                self.gl.get_query_parameter_u64(self.queries[0], glow::QUERY_RESULT),
                self.gl.get_query_parameter_u64(self.queries[1], glow::QUERY_RESULT),
            )
        };
        ConversionTiming { gpu_ns: b.saturating_sub(a) }
    }

    /// Fills a DMA-BUF (a GBM buffer object at the capture modifier) with packed BGRx, as `glconv.c` fills its
    /// input ring: upload to an RGBA8 texture, then blit into the imported buffer (GL refuses
    /// `glCopyImageSubData` from RGBA8 into the XR24 import, which is `GL_RGB8`). For the GPU tests.
    pub fn fill_dmabuf(&mut self, plane: &DmaBufPlane, bgrx: &[u8]) -> Result<(), String> {
        let stride = self.width * 4;
        let staging = self.memory_texture(bgrx, stride)?;
        let dst = self.dmabuf_texture(plane)?;
        let (w, h) = (self.width as i32, self.height as i32);
        // SAFETY: the context is current; both textures are ours; the framebuffers are made and deleted here.
        unsafe {
            let gl = &self.gl;
            let read = gl.create_framebuffer()?;
            let draw = gl.create_framebuffer()?;
            gl.bind_framebuffer(glow::READ_FRAMEBUFFER, Some(read));
            gl.framebuffer_texture_2d(glow::READ_FRAMEBUFFER, glow::COLOR_ATTACHMENT0, glow::TEXTURE_2D, Some(staging), 0);
            gl.bind_framebuffer(glow::DRAW_FRAMEBUFFER, Some(draw));
            gl.framebuffer_texture_2d(glow::DRAW_FRAMEBUFFER, glow::COLOR_ATTACHMENT0, glow::TEXTURE_2D, Some(dst), 0);
            let complete = gl.check_framebuffer_status(glow::DRAW_FRAMEBUFFER) == glow::FRAMEBUFFER_COMPLETE;
            if complete {
                gl.blit_framebuffer(0, 0, w, h, 0, 0, w, h, glow::COLOR_BUFFER_BIT, glow::NEAREST);
            }
            gl.bind_framebuffer(glow::READ_FRAMEBUFFER, None);
            gl.bind_framebuffer(glow::DRAW_FRAMEBUFFER, None);
            gl.delete_framebuffer(read);
            gl.delete_framebuffer(draw);
            gl.finish();
            if !complete {
                return Err("the imported buffer isn't a complete framebuffer".into());
            }
            gl_error(gl, "filling a DMA-BUF")
        }
    }
}

impl Drop for GlConverter {
    fn drop(&mut self) {
        // SAFETY: the context is still current on this thread (it is dropped after the converter: we hold an Rc
        // of it); every object deleted here is ours, after the GPU is idle (glFinish).
        unsafe {
            let gl = &self.gl;
            gl.finish();
            if let Some(f) = self.fence.take() {
                gl.delete_sync(f);
            }
            for t in self.targets.drain(..) {
                gl.delete_texture(t.y);
                gl.delete_texture(t.uv);
            }
            for i in self.imports.drain(..) {
                gl.delete_texture(i.texture);
            }
            if let Some(t) = self.staging.take() {
                gl.delete_texture(t);
            }
            gl.delete_query(self.queries[0]);
            gl.delete_query(self.queries[1]);
            gl.delete_program(self.program);
        }
    }
}
