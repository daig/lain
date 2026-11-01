//! Spike 6, candidate "vk": BGRx -> NV12 (BT.709 full range, 2x2-block chroma) in one Vulkan compute pass on
//! RADV, on the AMD render node only.
//!
//! - Input: a ring of BGRx (XRGB8888) DMA-BUFs allocated with GBM at exactly the modifier Mutter's screen-cast
//!   streams offer (0x200000000401b03), imported into Vulkan as images (VK_EXT_image_drm_format_modifier),
//!   and filled once with scrolling-text content by a buffer-to-image copy.
//! - Output (`--out`): `buffer`, a plain Vulkan storage buffer; `va-export`, NV12 surfaces created by libva
//!   (the kind the encoder takes) exported as DMA-BUFs and imported as Vulkan buffers, written in place
//!   (needs a LINEAR surface); `va-import`, a Vulkan buffer exported as a DMA-BUF and imported into libva as
//!   an NV12 surface.
//! - Timing: timestamp queries around the dispatch, and CPU time from submit to fence, one frame in flight.
//! - Correctness: NV12 read back for `--check` frames (through libva for the va modes) and compared with a CPU
//!   reference.
//!
//! Every size, pitch, offset and modifier is checked against what was allocated or imported before any
//! submission, the descriptors cover exactly the validated range, and the shader is compiled with naga's
//! `Restrict` bounds-check policy on top.

use std::ffi::{CStr, c_char, c_void};
use std::time::{Duration, Instant};

use ash::vk;

const RENDER_NODE: &str = "/dev/dri/by-path/pci-0000:79:00.0-render";
const MODIFIER: u64 = 0x0200_0000_0040_1b03;
const LINEAR: u64 = 0;
const VA_FOURCC_NV12: u32 = 0x3231_564e;

// --- native.c -------------------------------------------------------------------------------------------

#[repr(C)]
#[derive(Default, Debug)]
struct LcBo {
    bo: usize,
    fd: i32,
    stride: u32,
    offset: u32,
    planes: u32,
    modifier: u64,
}

#[repr(C)]
#[derive(Default, Debug, Clone, Copy)]
struct LcNv12 {
    surface: u32,
    fd: i32,
    size: u32,
    modifier: u64,
    fourcc: u32,
    num_objects: u32,
    num_layers: u32,
    offset: [u32; 2],
    pitch: [u32; 2],
}

unsafe extern "C" {
    fn lc_gbm_device(drm_fd: i32) -> *mut c_void;
    fn lc_gbm_alloc(dev: *mut c_void, w: u32, h: u32, modifier: u64, out: *mut LcBo) -> i32;
    fn lc_va_open(drm_fd: i32, vendor: *mut c_char, vendor_len: i32) -> *mut c_void;
    fn lc_va_create_export(dpy: *mut c_void, w: u32, h: u32, out: *mut LcNv12) -> i32;
    fn lc_va_import(
        dpy: *mut c_void,
        w: u32,
        h: u32,
        fd: i32,
        size: u32,
        modifier: u64,
        offset: *const u32,
        pitch: *const u32,
        surface: *mut u32,
    ) -> i32;
    fn lc_va_readback(dpy: *mut c_void, surface: u32, w: u32, h: u32, y: *mut u8, uv: *mut u8) -> i32;
}

// --- arguments ------------------------------------------------------------------------------------------

struct Args(Vec<(String, String)>);

impl Args {
    fn parse() -> Self {
        let raw: Vec<String> = std::env::args().skip(1).collect();
        let mut v = Vec::new();
        let mut i = 0;
        while i < raw.len() {
            let k = raw[i].strip_prefix("--").unwrap_or_else(|| panic!("bad argument {}", raw[i]));
            let val = raw.get(i + 1).cloned().unwrap_or_else(|| panic!("--{k} needs a value"));
            v.push((k.to_string(), val));
            i += 2;
        }
        Args(v)
    }
    fn str(&self, k: &str, d: &str) -> String {
        self.0.iter().rev().find(|(a, _)| a == k).map(|(_, b)| b.clone()).unwrap_or_else(|| d.to_string())
    }
    fn get<T: std::str::FromStr>(&self, k: &str, d: T) -> T {
        match self.0.iter().rev().find(|(a, _)| a == k) {
            Some((_, b)) => b.parse().unwrap_or_else(|_| panic!("bad --{k} {b}")),
            None => d,
        }
    }
}

// --- content and reference ------------------------------------------------------------------------------

/// Spike A's terminal-like tile (spikes/linux-encoder/src/synth.rs), BGRx, periodic every `period` rows.
fn text_frame(w: usize, h: usize, offset: usize, period: usize) -> Vec<u8> {
    let hash = |a: u64| {
        let mut x = a.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        x ^= x >> 29;
        x = x.wrapping_mul(0xBF58_476D_1CE4_E5B9);
        x ^ (x >> 32)
    };
    let palette: [[u8; 3]; 5] = [[220, 220, 220], [120, 220, 120], [240, 200, 90], [110, 160, 255], [230, 110, 200]];
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let ty = (y + offset) % period;
        let line = ty / 18;
        let gy = ty % 18;
        let len = 40 + (hash(line as u64 * 7 + 1) % 300) as usize;
        for x in 0..w {
            let px = &mut out[(y * w + x) * 4..(y * w + x) * 4 + 4];
            let (mut b, mut g, mut r) = (40u8, 30u8, 48u8);
            let col = x / 9;
            let gx = x % 9;
            if col < len && (1..15).contains(&gy) && gx < 8 {
                let glyph = hash((line as u64) << 20 | col as u64);
                if glyph % 7 != 0 {
                    let bit = (gy - 1) / 2 * 4 + gx / 2;
                    if (glyph >> (bit % 64)) & 1 == 1 {
                        let c = palette[(hash(line as u64 * 31 + col as u64 / 12) % 5) as usize];
                        (r, g, b) = (c[0], c[1], c[2]);
                    }
                }
            }
            px[0] = b;
            px[1] = g;
            px[2] = r;
            px[3] = 255;
        }
    }
    out
}

/// The CPU reference: tightly packed Y (w*h) and interleaved CbCr (w*h/2), in f64.
fn reference(bgrx: &[u8], w: usize, h: usize) -> (Vec<u8>, Vec<u8>) {
    let q = |v: f64| (v + 0.5).floor().clamp(0.0, 255.0) as u8;
    let luma = |r: f64, g: f64, b: f64| 0.2126 * r + 0.7152 * g + 0.0722 * b;
    let px = |x: usize, y: usize| {
        let i = (y * w + x) * 4;
        (bgrx[i + 2] as f64, bgrx[i + 1] as f64, bgrx[i] as f64)
    };
    let mut yp = vec![0u8; w * h];
    let mut uv = vec![0u8; w * h / 2];
    for y in 0..h {
        for x in 0..w {
            let (r, g, b) = px(x, y);
            yp[y * w + x] = q(luma(r, g, b));
        }
    }
    for by in 0..h / 2 {
        for bx in 0..w / 2 {
            let (mut r, mut g, mut b) = (0.0, 0.0, 0.0);
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let p = px(bx * 2 + dx, by * 2 + dy);
                r += p.0;
                g += p.1;
                b += p.2;
            }
            let (r, g, b) = (r / 4.0, g / 4.0, b / 4.0);
            let ym = luma(r, g, b);
            uv[by * w + bx * 2] = q((b - ym) / 1.8556 + 128.0);
            uv[by * w + bx * 2 + 1] = q((r - ym) / 1.5748 + 128.0);
        }
    }
    (yp, uv)
}

fn compare(name: &str, got: &[u8], want: &[u8]) -> (u32, f64) {
    assert_eq!(got.len(), want.len(), "{name}: length");
    let mut max = 0u32;
    let mut sum = 0u64;
    let mut over1 = 0usize;
    for (a, b) in got.iter().zip(want) {
        let d = (*a as i32 - *b as i32).unsigned_abs();
        max = max.max(d);
        sum += d as u64;
        if d > 1 {
            over1 += 1;
        }
    }
    let mean = sum as f64 / got.len() as f64;
    print!(" {name}: max {max} mean {mean:.5} (>1: {over1})");
    (max, mean)
}

// --- shader ---------------------------------------------------------------------------------------------

fn compile_shader(tiled: bool, wx: u32, wy: u32, words: u32, strided: bool) -> Vec<u32> {
    let src = if tiled { include_str!("convert_img.wgsl") } else { include_str!("convert.wgsl") }
        .replace("__WX__", &wx.to_string())
        .replace("__WY__", &wy.to_string())
        .replace("__WORDS__", &words.to_string())
        .replace("__STRIDED__", if strided { "true" } else { "false" });
    let module = naga::front::wgsl::parse_str(&src).unwrap_or_else(|e| panic!("{}", e.emit_to_string(&src)));
    let info = naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::IMMEDIATES)
        .validate(&module)
        .unwrap_or_else(|e| panic!("{}", e.emit_to_string(&src)));
    let restrict = naga::proc::BoundsCheckPolicy::Restrict;
    let options = naga::back::spv::Options {
        lang_version: (1, 3),
        flags: naga::back::spv::WriterFlags::empty(),
        bounds_check_policies: naga::proc::BoundsCheckPolicies {
            index: restrict,
            buffer: restrict,
            image_load: restrict,
            binding_array: restrict,
        },
        force_loop_bounding: false,
        ..Default::default()
    };
    let pipeline = naga::back::spv::PipelineOptions {
        shader_stage: naga::ShaderStage::Compute,
        entry_point: "cs_main".into(),
    };
    naga::back::spv::write_vec(&module, &info, &options, Some(&pipeline)).expect("SPIR-V")
}

// --- Vulkan ---------------------------------------------------------------------------------------------

struct Gpu {
    _entry: ash::Entry, // owns libvulkan: dropping it unloads every function pointer below
    instance: ash::Instance,
    pdev: vk::PhysicalDevice,
    dev: ash::Device,
    queue: vk::Queue,
    mem: vk::PhysicalDeviceMemoryProperties,
    fd_ext: ash::khr::external_memory_fd::Device,
    mod_ext: ash::ext::image_drm_format_modifier::Device,
    ts_period: f64,
    ts_mask: u64,
    pool: vk::CommandPool,
}

fn fd_size(fd: i32) -> u64 {
    let s = unsafe { libc::lseek(fd, 0, libc::SEEK_END) };
    assert!(s > 0, "lseek on DMA-BUF fd {fd}");
    unsafe { libc::lseek(fd, 0, libc::SEEK_SET) };
    s as u64
}

/// Opens the AMD render node and checks it is what we think: a DRM render node of PCI vendor 0x1002.
fn open_render_node() -> (i32, u32, u32) {
    let path = std::ffi::CString::new(RENDER_NODE).unwrap();
    let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
    assert!(fd >= 0, "open {RENDER_NODE}");
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    assert_eq!(unsafe { libc::fstat(fd, &mut st) }, 0);
    let (maj, min) = (libc::major(st.st_rdev), libc::minor(st.st_rdev));
    let vendor = std::fs::read_to_string(format!("/sys/dev/char/{maj}:{min}/device/vendor")).unwrap_or_default();
    assert_eq!(vendor.trim(), "0x1002", "{RENDER_NODE} is not an AMD device");
    assert!(min >= 128, "{RENDER_NODE} is not a render node");
    (fd, maj, min)
}

impl Gpu {
    fn new(maj: u32, min: u32, want_compute: bool) -> Gpu {
        unsafe {
            let entry = ash::Entry::load().expect("Vulkan loader");
            let app = vk::ApplicationInfo::default().api_version(vk::API_VERSION_1_3);
            let instance = entry
                .create_instance(&vk::InstanceCreateInfo::default().application_info(&app), None)
                .expect("instance");
            let mut chosen = None;
            for pdev in instance.enumerate_physical_devices().unwrap() {
                let props = instance.get_physical_device_properties(pdev);
                let exts = instance.enumerate_device_extension_properties(pdev).unwrap();
                let has = |n: &CStr| exts.iter().any(|e| e.extension_name_as_c_str() == Ok(n));
                if props.vendor_id != 0x1002 || !has(ash::ext::physical_device_drm::NAME) {
                    continue;
                }
                let mut drm = vk::PhysicalDeviceDrmPropertiesEXT::default();
                let mut p2 = vk::PhysicalDeviceProperties2::default().push_next(&mut drm);
                instance.get_physical_device_properties2(pdev, &mut p2);
                if drm.has_render != 0 && drm.render_major as u32 == maj && drm.render_minor as u32 == min {
                    let name = props.device_name_as_c_str().unwrap().to_string_lossy().into_owned();
                    chosen = Some((pdev, props, name));
                }
            }
            let (pdev, props, name) = chosen.expect("no Vulkan device on the AMD render node");
            let mut drv = vk::PhysicalDeviceDriverProperties::default();
            let mut p2 = vk::PhysicalDeviceProperties2::default().push_next(&mut drv);
            instance.get_physical_device_properties2(pdev, &mut p2);
            assert_eq!(drv.driver_id, vk::DriverId::MESA_RADV, "not RADV");
            let qf = instance.get_physical_device_queue_family_properties(pdev);
            let pick = |compute_only: bool| {
                qf.iter().position(|q| {
                    q.queue_flags.contains(vk::QueueFlags::COMPUTE)
                        && q.queue_flags.contains(vk::QueueFlags::GRAPHICS) != compute_only
                        && q.timestamp_valid_bits > 0
                })
            };
            let qfi = pick(want_compute).or_else(|| pick(!want_compute)).expect("queue family") as u32;
            let qflags = qf[qfi as usize].queue_flags;
            println!(
                "device: {name} (RADV {}), render {maj}:{min}, queue family {qfi} ({}), timestamp period {} ns",
                drv.driver_info_as_c_str().unwrap().to_string_lossy(),
                if qflags.contains(vk::QueueFlags::GRAPHICS) { "graphics" } else { "compute-only" },
                props.limits.timestamp_period
            );
            let bits = qf[qfi as usize].timestamp_valid_bits;
            let ts_mask = if bits >= 64 { u64::MAX } else { (1u64 << bits) - 1 };

            let ext_names = [
                ash::khr::external_memory_fd::NAME.as_ptr(),
                ash::ext::external_memory_dma_buf::NAME.as_ptr(),
                ash::ext::image_drm_format_modifier::NAME.as_ptr(),
            ];
            let prio = [1.0f32];
            let qci = [vk::DeviceQueueCreateInfo::default().queue_family_index(qfi).queue_priorities(&prio)];
            let features = vk::PhysicalDeviceFeatures::default()
                .robust_buffer_access(true)
                .shader_storage_image_extended_formats(true);
            let dev = instance
                .create_device(
                    pdev,
                    &vk::DeviceCreateInfo::default()
                        .queue_create_infos(&qci)
                        .enabled_extension_names(&ext_names)
                        .enabled_features(&features),
                    None,
                )
                .expect("device");
            let queue = dev.get_device_queue(qfi, 0);
            let pool = dev
                .create_command_pool(
                    &vk::CommandPoolCreateInfo::default()
                        .queue_family_index(qfi)
                        .flags(vk::CommandPoolCreateFlags::RESET_COMMAND_BUFFER),
                    None,
                )
                .unwrap();
            Gpu {
                _entry: entry,
                mem: instance.get_physical_device_memory_properties(pdev),
                fd_ext: ash::khr::external_memory_fd::Device::new(&instance, &dev),
                mod_ext: ash::ext::image_drm_format_modifier::Device::new(&instance, &dev),
                ts_period: props.limits.timestamp_period as f64,
                ts_mask,
                instance,
                pdev,
                dev,
                queue,
                pool,
            }
        }
    }

    fn mem_type(&self, bits: u32, want: vk::MemoryPropertyFlags, avoid: vk::MemoryPropertyFlags) -> u32 {
        let n = self.mem.memory_type_count as usize;
        let ok = |i: usize, avoid: vk::MemoryPropertyFlags| {
            let f = self.mem.memory_types[i].property_flags;
            bits & (1 << i) != 0 && f.contains(want) && !f.intersects(avoid)
        };
        (0..n)
            .find(|&i| ok(i, avoid))
            .or_else(|| (0..n).find(|&i| ok(i, vk::MemoryPropertyFlags::empty())))
            .unwrap_or_else(|| panic!("no memory type in {bits:#x} with {want:?}")) as u32
    }

    /// Checks the modifier can be imported as a single-plane `format` image with `usage`.
    fn check_modifier(&self, format: vk::Format, usage: vk::ImageUsageFlags, need: vk::FormatFeatureFlags, w: u32, h: u32) {
        unsafe {
            let mut list = vk::DrmFormatModifierPropertiesListEXT::default();
            let mut fp = vk::FormatProperties2::default().push_next(&mut list);
            self.instance.get_physical_device_format_properties2(self.pdev, format, &mut fp);
            let n = list.drm_format_modifier_count as usize;
            let mut mods = vec![vk::DrmFormatModifierPropertiesEXT::default(); n];
            let mut list = vk::DrmFormatModifierPropertiesListEXT::default().drm_format_modifier_properties(&mut mods);
            let mut fp = vk::FormatProperties2::default().push_next(&mut list);
            self.instance.get_physical_device_format_properties2(self.pdev, format, &mut fp);
            let m = mods
                .iter()
                .find(|m| m.drm_format_modifier == MODIFIER)
                .unwrap_or_else(|| panic!("modifier not supported by RADV for {format:?}"));
            assert_eq!(m.drm_format_modifier_plane_count, 1, "modifier has more than one memory plane");
            assert!(m.drm_format_modifier_tiling_features.contains(need), "{format:?} modifier features {:?}", m.drm_format_modifier_tiling_features);
            let mut drm_info = vk::PhysicalDeviceImageDrmFormatModifierInfoEXT::default()
                .drm_format_modifier(MODIFIER)
                .sharing_mode(vk::SharingMode::EXCLUSIVE);
            let mut ext_info = vk::PhysicalDeviceExternalImageFormatInfo::default()
                .handle_type(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
            let info = vk::PhysicalDeviceImageFormatInfo2::default()
                .format(format)
                .ty(vk::ImageType::TYPE_2D)
                .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
                .usage(usage)
                .push_next(&mut drm_info)
                .push_next(&mut ext_info);
            let mut ext_props = vk::ExternalImageFormatProperties::default();
            let mut props = vk::ImageFormatProperties2::default().push_next(&mut ext_props);
            self.instance
                .get_physical_device_image_format_properties2(self.pdev, &info, &mut props)
                .unwrap_or_else(|e| panic!("{format:?} {usage:?} with the modifier: {e}"));
            let e = props.image_format_properties.max_extent;
            assert!(e.width >= w && e.height >= h, "max extent {e:?}");
            assert!(ext_props
                .external_memory_properties
                .external_memory_features
                .contains(vk::ExternalMemoryFeatureFlags::IMPORTABLE));
        }
    }

    fn import_memory(&self, fd: i32, req: vk::MemoryRequirements, fd_len: u64, dedicated: Option<vk::MemoryDedicatedAllocateInfo>) -> vk::DeviceMemory {
        unsafe {
            assert!(req.size <= fd_len, "Vulkan needs {} bytes but the DMA-BUF has {fd_len}", req.size);
            let mut fdp = vk::MemoryFdPropertiesKHR::default();
            self.fd_ext
                .get_memory_fd_properties(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT, fd, &mut fdp)
                .expect("fd properties");
            let ty = self.mem_type(req.memory_type_bits & fdp.memory_type_bits, vk::MemoryPropertyFlags::empty(), vk::MemoryPropertyFlags::empty());
            let dup = libc::dup(fd);
            assert!(dup >= 0);
            let mut import = vk::ImportMemoryFdInfoKHR::default()
                .handle_type(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT)
                .fd(dup);
            let mut ded = dedicated.unwrap_or_default();
            let mut info = vk::MemoryAllocateInfo::default()
                .allocation_size(req.size)
                .memory_type_index(ty)
                .push_next(&mut import);
            if dedicated.is_some() {
                info = info.push_next(&mut ded);
            }
            self.dev.allocate_memory(&info, None).expect("import DMA-BUF")
        }
    }

    /// A GBM BGRx buffer as a Vulkan image, after checking its layout against what GBM reported.
    fn import_image(&self, bo: &LcBo, w: u32, h: u32) -> (vk::Image, vk::ImageView) {
        assert_eq!(bo.modifier, MODIFIER, "GBM gave another modifier");
        assert_eq!(bo.planes, 1, "GBM gave {} planes", bo.planes);
        let usage = vk::ImageUsageFlags::SAMPLED | vk::ImageUsageFlags::TRANSFER_DST;
        self.import_plane(bo.fd, vk::Format::B8G8R8A8_UNORM, 4, usage, w, h, bo.offset, bo.stride)
    }

    /// One plane of a DMA-BUF at `MODIFIER` as a `format` image (`bpp` bytes per texel) whose layout is
    /// checked against the buffer's size before it is bound.
    #[allow(clippy::too_many_arguments)]
    fn import_plane(&self, fd: i32, format: vk::Format, bpp: u32, usage: vk::ImageUsageFlags, w: u32, h: u32, offset: u32, pitch: u32) -> (vk::Image, vk::ImageView) {
        self.import_plane_in(fd, None, format, bpp, usage, w, h, offset, pitch)
    }

    /// As `import_plane`; with `shared`, the image is bound at offset 0 of one non-dedicated import of the
    /// whole DMA-BUF (so a multi-plane buffer is imported once, not once per plane).
    #[allow(clippy::too_many_arguments)]
    fn import_plane_in(&self, fd: i32, shared: Option<&std::cell::Cell<vk::DeviceMemory>>, format: vk::Format, bpp: u32, usage: vk::ImageUsageFlags, w: u32, h: u32, offset: u32, pitch: u32) -> (vk::Image, vk::ImageView) {
        assert!(pitch >= w * bpp && pitch % bpp == 0, "pitch {pitch} for {w} texels of {bpp} bytes");
        let len = fd_size(fd);
        assert!(offset as u64 + pitch as u64 * h as u64 <= len, "plane past the DMA-BUF ({len} bytes)");
        unsafe {
            let layouts = [vk::SubresourceLayout {
                offset: offset as u64,
                size: 0,
                row_pitch: pitch as u64,
                array_pitch: 0,
                depth_pitch: 0,
            }];
            let mut explicit = vk::ImageDrmFormatModifierExplicitCreateInfoEXT::default()
                .drm_format_modifier(MODIFIER)
                .plane_layouts(&layouts);
            let mut ext = vk::ExternalMemoryImageCreateInfo::default().handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
            let info = vk::ImageCreateInfo::default()
                .image_type(vk::ImageType::TYPE_2D)
                .format(format)
                .extent(vk::Extent3D { width: w, height: h, depth: 1 })
                .mip_levels(1)
                .array_layers(1)
                .samples(vk::SampleCountFlags::TYPE_1)
                .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
                .usage(usage)
                .sharing_mode(vk::SharingMode::EXCLUSIVE)
                .initial_layout(vk::ImageLayout::UNDEFINED)
                .push_next(&mut explicit)
                .push_next(&mut ext);
            let image = self.dev.create_image(&info, None).expect("image");
            let mut mp = vk::ImageDrmFormatModifierPropertiesEXT::default();
            self.mod_ext.get_image_drm_format_modifier_properties(image, &mut mp).unwrap();
            assert_eq!(mp.drm_format_modifier, MODIFIER);
            let req = self.dev.get_image_memory_requirements(image);
            if std::env::var_os("VKCONVERT_VERBOSE").is_some() {
                let l = self.dev.get_image_subresource_layout(
                    image,
                    vk::ImageSubresource { aspect_mask: vk::ImageAspectFlags::MEMORY_PLANE_0_EXT, mip_level: 0, array_layer: 0 },
                );
                println!("  import {format:?} {w}x{h}: given offset {offset} pitch {pitch}; RADV layout {l:?}; needs {} bytes of {len}, types {:#x}", req.size, req.memory_type_bits);
            }
            let mem = match shared {
                None => self.import_memory(fd, req, len, Some(vk::MemoryDedicatedAllocateInfo::default().image(image))),
                Some(cell) => {
                    if cell.get() == vk::DeviceMemory::null() {
                        let whole = vk::MemoryRequirements { size: len, ..req };
                        cell.set(self.import_memory(fd, whole, len, None));
                    }
                    assert!(req.size <= len);
                    cell.get()
                }
            };
            self.dev.bind_image_memory(image, mem, 0).unwrap();
            let view = self
                .dev
                .create_image_view(
                    &vk::ImageViewCreateInfo::default()
                        .image(image)
                        .view_type(vk::ImageViewType::TYPE_2D)
                        .format(format)
                        .subresource_range(color_range()),
                    None,
                )
                .unwrap();
            (image, view)
        }
    }

    fn buffer(&self, size: u64, usage: vk::BufferUsageFlags, want: vk::MemoryPropertyFlags) -> (vk::Buffer, vk::DeviceMemory) {
        unsafe {
            let b = self.dev.create_buffer(&vk::BufferCreateInfo::default().size(size).usage(usage), None).unwrap();
            let req = self.dev.get_buffer_memory_requirements(b);
            let ty = self.mem_type(req.memory_type_bits, want, vk::MemoryPropertyFlags::empty());
            let m = self
                .dev
                .allocate_memory(&vk::MemoryAllocateInfo::default().allocation_size(req.size).memory_type_index(ty), None)
                .unwrap();
            self.dev.bind_buffer_memory(b, m, 0).unwrap();
            (b, m)
        }
    }

    /// A DMA-BUF (from libva) as a storage buffer of exactly `size` bytes.
    fn import_buffer(&self, fd: i32, size: u64) -> vk::Buffer {
        let len = fd_size(fd);
        assert!(size <= len, "buffer {size} > DMA-BUF {len}");
        unsafe {
            let mut ext = vk::ExternalMemoryBufferCreateInfo::default().handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
            let b = self
                .dev
                .create_buffer(
                    &vk::BufferCreateInfo::default()
                        .size(size)
                        .usage(vk::BufferUsageFlags::STORAGE_BUFFER | vk::BufferUsageFlags::TRANSFER_SRC)
                        .push_next(&mut ext),
                    None,
                )
                .unwrap();
            let req = self.dev.get_buffer_memory_requirements(b);
            let mem = self.import_memory(fd, req, len, Some(vk::MemoryDedicatedAllocateInfo::default().buffer(b)));
            self.dev.bind_buffer_memory(b, mem, 0).unwrap();
            b
        }
    }

    /// A device-local storage buffer exported as a DMA-BUF; returns the buffer, the fd and its length.
    fn export_buffer(&self, size: u64) -> (vk::Buffer, i32, u64) {
        unsafe {
            let ebi = vk::PhysicalDeviceExternalBufferInfo::default()
                .usage(vk::BufferUsageFlags::STORAGE_BUFFER)
                .handle_type(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
            let mut ebp = vk::ExternalBufferProperties::default();
            self.instance.get_physical_device_external_buffer_properties(self.pdev, &ebi, &mut ebp);
            assert!(
                ebp.external_memory_properties
                    .external_memory_features
                    .contains(vk::ExternalMemoryFeatureFlags::EXPORTABLE),
                "DMA-BUF buffer export unsupported"
            );
            let mut ext = vk::ExternalMemoryBufferCreateInfo::default().handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
            let b = self
                .dev
                .create_buffer(
                    &vk::BufferCreateInfo::default()
                        .size(size)
                        .usage(vk::BufferUsageFlags::STORAGE_BUFFER | vk::BufferUsageFlags::TRANSFER_SRC)
                        .push_next(&mut ext),
                    None,
                )
                .unwrap();
            let req = self.dev.get_buffer_memory_requirements(b);
            let ty = self.mem_type(req.memory_type_bits, vk::MemoryPropertyFlags::DEVICE_LOCAL, vk::MemoryPropertyFlags::empty());
            let mut export = vk::ExportMemoryAllocateInfo::default().handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
            let mut dedicated = vk::MemoryDedicatedAllocateInfo::default().buffer(b);
            let m = self
                .dev
                .allocate_memory(
                    &vk::MemoryAllocateInfo::default()
                        .allocation_size(req.size)
                        .memory_type_index(ty)
                        .push_next(&mut export)
                        .push_next(&mut dedicated),
                    None,
                )
                .expect("exportable memory");
            self.dev.bind_buffer_memory(b, m, 0).unwrap();
            let fd = self
                .fd_ext
                .get_memory_fd(
                    &vk::MemoryGetFdInfoKHR::default()
                        .memory(m)
                        .handle_type(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT),
                )
                .expect("export fd");
            let len = fd_size(fd);
            assert!(len >= size);
            (b, fd, len)
        }
    }

    fn one_shot(&self, f: impl FnOnce(vk::CommandBuffer)) {
        unsafe {
            let cb = self
                .dev
                .allocate_command_buffers(&vk::CommandBufferAllocateInfo::default().command_pool(self.pool).command_buffer_count(1))
                .unwrap()[0];
            self.dev
                .begin_command_buffer(cb, &vk::CommandBufferBeginInfo::default().flags(vk::CommandBufferUsageFlags::ONE_TIME_SUBMIT))
                .unwrap();
            f(cb);
            self.dev.end_command_buffer(cb).unwrap();
            self.submit_wait(cb, Duration::from_secs(5));
            self.dev.free_command_buffers(self.pool, &[cb]);
        }
    }

    /// Submits and waits on a fence; returns submit-to-signalled time. A 5 s timeout panics (and exits)
    /// rather than queueing more work behind a hung submission.
    fn submit_wait(&self, cb: vk::CommandBuffer, timeout: Duration) -> Duration {
        unsafe {
            let fence = self.dev.create_fence(&vk::FenceCreateInfo::default(), None).unwrap();
            let cbs = [cb];
            let t = Instant::now();
            self.dev.queue_submit(self.queue, &[vk::SubmitInfo::default().command_buffers(&cbs)], fence).unwrap();
            self.dev.wait_for_fences(&[fence], true, timeout.as_nanos() as u64).expect("fence (GPU hang?)");
            let d = t.elapsed();
            self.dev.destroy_fence(fence, None);
            d
        }
    }
}

fn color_range() -> vk::ImageSubresourceRange {
    vk::ImageSubresourceRange {
        aspect_mask: vk::ImageAspectFlags::COLOR,
        base_mip_level: 0,
        level_count: 1,
        base_array_layer: 0,
        layer_count: 1,
    }
}

/// An NV12 destination: a storage buffer of `size` bytes with Y at `offset[0]`, CbCr at `offset[1]`.
struct Out {
    buffer: vk::Buffer,
    size: u64,
    offset: [u32; 2],
    pitch: [u32; 2],
    va_surface: Option<u32>,
    /// `va-tiled`: the surface's Y (R8) and CbCr (R8G8) planes as storage images; `buffer` is then null.
    planes: Option<[(vk::Image, vk::ImageView); 2]>,
}

/// The layout check every destination passes before the shader may write it.
fn validate_out(o: &Out, w: u32, h: u32) {
    for i in 0..2 {
        let rows = if i == 0 { h } else { h / 2 };
        assert!(o.offset[i] % 4 == 0 && o.pitch[i] % 4 == 0, "plane {i} not word-aligned: {:?} {:?}", o.offset, o.pitch);
        assert!(o.pitch[i] >= w, "plane {i} pitch {} < width {w}", o.pitch[i]);
        assert!(
            o.offset[i] as u64 + o.pitch[i] as u64 * rows as u64 <= o.size,
            "plane {i} ends past the buffer: {:?} {:?} {}",
            o.offset,
            o.pitch,
            o.size
        );
    }
    let y_end = o.offset[0] as u64 + o.pitch[0] as u64 * h as u64;
    assert!(o.offset[1] as u64 >= y_end || o.offset[1] as u64 + o.pitch[1] as u64 * (h / 2) as u64 <= o.offset[0] as u64, "planes overlap");
}

fn stats(name: &str, v: &mut [f64]) {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize];
    let mean = v.iter().sum::<f64>() / v.len() as f64;
    println!(
        "{name}: n {} mean {mean:.3} p50 {:.3} p95 {:.3} p99 {:.3} max {:.3} ms",
        v.len(),
        p(0.5),
        p(0.95),
        p(0.99),
        v[v.len() - 1]
    );
}

fn main() {
    let args = Args::parse();
    let w: u32 = args.get("width", 2752);
    let h: u32 = args.get("height", 2064);
    let ring: usize = args.get("ring", 8);
    let frames: usize = args.get("frames", 600);
    let fps: f64 = args.get("fps", 120.0);
    let checks: usize = args.get("check", 4);
    let out_mode = args.str("out", "buffer");
    let queue = args.str("queue", "compute");
    let (wx, wy, words): (u32, u32, u32) = (args.get("wx", 64), args.get("wy", 1), args.get("words", 1));
    let strided = args.get::<u32>("strided", 0) != 0;
    assert!(w % 4 == 0 && h % 2 == 0 && w <= 8192 && h <= 4352, "size {w}x{h}");
    assert!((1..=1024).contains(&(wx * wy)) && (1..=16).contains(&words));
    assert!(ring >= 1 && ring <= 32 && frames <= 20_000 && checks <= ring);
    // One timed run stays short: about 10 s at most.
    if fps > 0.0 {
        assert!(frames as f64 / fps <= 12.0, "run longer than ~10 s");
    }

    let out_is_tiled = matches!(out_mode.as_str(), "va-tiled" | "vk-tiled" | "img");
    if let Some(path) = args.0.iter().find(|(k, _)| k == "dump-spv").map(|(_, v)| v.clone()) {
        // Compile only (no device opened), for checking the SPIR-V offline.
        let spv = compile_shader(out_is_tiled, wx, wy, words, strided);
        std::fs::write(&path, spv.iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<u8>>()).unwrap();
        println!("wrote {} SPIR-V words to {path}", spv.len());
        return;
    }
    let (drm_fd, maj, min) = open_render_node();
    let gpu = Gpu::new(maj, min, queue == "compute");
    gpu.check_modifier(
        vk::Format::B8G8R8A8_UNORM,
        vk::ImageUsageFlags::SAMPLED | vk::ImageUsageFlags::TRANSFER_DST,
        vk::FormatFeatureFlags::SAMPLED_IMAGE | vk::FormatFeatureFlags::TRANSFER_DST,
        w,
        h,
    );
    if out_mode == "va-tiled" || out_mode == "vk-tiled" {
        for f in [vk::Format::R8_UNORM, vk::Format::R8G8_UNORM] {
            gpu.check_modifier(
                f,
                vk::ImageUsageFlags::STORAGE | vk::ImageUsageFlags::TRANSFER_SRC | vk::ImageUsageFlags::TRANSFER_DST,
                vk::FormatFeatureFlags::STORAGE_IMAGE | vk::FormatFeatureFlags::TRANSFER_SRC | vk::FormatFeatureFlags::TRANSFER_DST,
                w,
                h,
            );
        }
    }
    let dev = &gpu.dev;

    // Shader and pipeline.
    let spv = compile_shader(out_is_tiled, wx, wy, words, strided);
    if out_is_tiled {
        println!("shader: storage images, workgroup {wx}x{wy}, one 2x2 block per invocation, {} SPIR-V words", spv.len());
    } else {
        println!("shader: buffer, workgroup {wx}x{wy}, {words} 4x2 block(s) per invocation{}, {} SPIR-V words", if strided { " strided" } else { "" }, spv.len());
    }
    let (set_layout, layout, pipeline) = unsafe {
        let bindings = [
            vk::DescriptorSetLayoutBinding::default()
                .binding(0)
                .descriptor_type(vk::DescriptorType::SAMPLED_IMAGE)
                .descriptor_count(1)
                .stage_flags(vk::ShaderStageFlags::COMPUTE),
            vk::DescriptorSetLayoutBinding::default()
                .binding(1)
                .descriptor_type(if out_is_tiled { vk::DescriptorType::STORAGE_IMAGE } else { vk::DescriptorType::STORAGE_BUFFER })
                .descriptor_count(1)
                .stage_flags(vk::ShaderStageFlags::COMPUTE),
            vk::DescriptorSetLayoutBinding::default()
                .binding(2)
                .descriptor_type(vk::DescriptorType::STORAGE_IMAGE)
                .descriptor_count(1)
                .stage_flags(vk::ShaderStageFlags::COMPUTE),
        ];
        let n_bindings = if out_is_tiled { 3 } else { 2 };
        let set_layout = dev
            .create_descriptor_set_layout(&vk::DescriptorSetLayoutCreateInfo::default().bindings(&bindings[..n_bindings]), None)
            .unwrap();
        let pcr = [vk::PushConstantRange { stage_flags: vk::ShaderStageFlags::COMPUTE, offset: 0, size: 24 }];
        let sls = [set_layout];
        let layout = dev
            .create_pipeline_layout(&vk::PipelineLayoutCreateInfo::default().set_layouts(&sls).push_constant_ranges(&pcr), None)
            .unwrap();
        let module = dev.create_shader_module(&vk::ShaderModuleCreateInfo::default().code(&spv), None).unwrap();
        let stage = vk::PipelineShaderStageCreateInfo::default()
            .stage(vk::ShaderStageFlags::COMPUTE)
            .module(module)
            .name(c"cs_main");
        let pipeline = dev
            .create_compute_pipelines(vk::PipelineCache::null(), &[vk::ComputePipelineCreateInfo::default().stage(stage).layout(layout)], None)
            .map_err(|e| e.1)
            .unwrap()[0];
        (set_layout, layout, pipeline)
    };

    // Input ring: GBM BOs at Mutter's modifier, imported, filled once through a staging buffer.
    let gbm = unsafe { lc_gbm_device(drm_fd) };
    assert!(!gbm.is_null(), "gbm device");
    let frame_bytes = w as u64 * h as u64 * 4;
    let (staging, staging_mem) = gpu.buffer(
        frame_bytes,
        vk::BufferUsageFlags::TRANSFER_SRC | vk::BufferUsageFlags::TRANSFER_DST,
        vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_COHERENT,
    );
    let staging_ptr = unsafe { dev.map_memory(staging_mem, 0, frame_bytes, vk::MemoryMapFlags::empty()).unwrap() as *mut u8 };
    let step = 18usize;
    let period = ring * step;
    let mut images = Vec::new();
    let t = Instant::now();
    for i in 0..ring {
        let mut bo = LcBo::default();
        let r = unsafe { lc_gbm_alloc(gbm, w, h, MODIFIER, &mut bo) };
        assert_eq!(r, 0, "gbm alloc");
        if i == 0 {
            println!("input: GBM XRGB8888 modifier {:#x}, stride {}, offset {}, {} bytes", bo.modifier, bo.stride, bo.offset, fd_size(bo.fd));
        }
        let (image, view) = gpu.import_image(&bo, w, h);
        unsafe { libc::close(bo.fd) };
        let content = text_frame(w as usize, h as usize, i * step, period);
        assert_eq!(content.len() as u64, frame_bytes);
        unsafe { std::ptr::copy_nonoverlapping(content.as_ptr(), staging_ptr, content.len()) };
        gpu.one_shot(|cb| unsafe {
            let to_dst = vk::ImageMemoryBarrier::default()
                .image(image)
                .old_layout(vk::ImageLayout::UNDEFINED)
                .new_layout(vk::ImageLayout::TRANSFER_DST_OPTIMAL)
                .dst_access_mask(vk::AccessFlags::TRANSFER_WRITE)
                .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .subresource_range(color_range());
            dev.cmd_pipeline_barrier(cb, vk::PipelineStageFlags::TOP_OF_PIPE, vk::PipelineStageFlags::TRANSFER, vk::DependencyFlags::empty(), &[], &[], &[to_dst]);
            let region = vk::BufferImageCopy::default()
                .image_subresource(vk::ImageSubresourceLayers { aspect_mask: vk::ImageAspectFlags::COLOR, mip_level: 0, base_array_layer: 0, layer_count: 1 })
                .image_extent(vk::Extent3D { width: w, height: h, depth: 1 });
            dev.cmd_copy_buffer_to_image(cb, staging, image, vk::ImageLayout::TRANSFER_DST_OPTIMAL, &[region]);
            let to_general = vk::ImageMemoryBarrier::default()
                .image(image)
                .old_layout(vk::ImageLayout::TRANSFER_DST_OPTIMAL)
                .new_layout(vk::ImageLayout::GENERAL)
                .src_access_mask(vk::AccessFlags::TRANSFER_WRITE)
                .dst_access_mask(vk::AccessFlags::SHADER_READ)
                .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                .subresource_range(color_range());
            dev.cmd_pipeline_barrier(cb, vk::PipelineStageFlags::TRANSFER, vk::PipelineStageFlags::COMPUTE_SHADER, vk::DependencyFlags::empty(), &[], &[], &[to_general]);
        });
        images.push((image, view));
    }
    println!("filled {ring} input frames in {:?}", t.elapsed());

    // Outputs: two NV12 destinations, alternated.
    let va = if out_mode == "buffer" {
        std::ptr::null_mut()
    } else {
        let mut vendor = [0 as c_char; 256];
        let d = unsafe { lc_va_open(drm_fd, vendor.as_mut_ptr(), 256) };
        assert!(!d.is_null(), "vaInitialize");
        println!("libva: {}", unsafe { CStr::from_ptr(vendor.as_ptr()) }.to_string_lossy());
        d
    };
    let nout = 2usize;
    let mut outs: Vec<Out> = Vec::new();
    for _ in 0..nout {
        let o = match out_mode.as_str() {
            "buffer" => {
                let pitch = w;
                let size = pitch as u64 * h as u64 * 3 / 2;
                let (b, _) = gpu.buffer(size, vk::BufferUsageFlags::STORAGE_BUFFER | vk::BufferUsageFlags::TRANSFER_SRC, vk::MemoryPropertyFlags::DEVICE_LOCAL);
                Out { buffer: b, size, offset: [0, pitch * h], pitch: [pitch, pitch], va_surface: None, planes: None }
            }
            "va-export" => {
                let mut s = LcNv12::default();
                let r = unsafe { lc_va_create_export(va, w, h, &mut s) };
                if outs.is_empty() {
                    println!("VA NV12 surface: {s:?} (status {r})");
                }
                assert_eq!(r, 0, "vaExportSurfaceHandle: one object and two layers required");
                assert_eq!(s.fourcc, VA_FOURCC_NV12);
                assert_eq!(s.modifier, LINEAR, "the VA surface is not LINEAR, so a buffer can't address it");
                let len = fd_size(s.fd);
                assert!(s.size as u64 <= len);
                let o = Out { buffer: vk::Buffer::null(), size: s.size as u64, offset: s.offset, pitch: s.pitch, va_surface: Some(s.surface), planes: None };
                validate_out(&o, w, h);
                let b = gpu.import_buffer(s.fd, s.size as u64);
                unsafe { libc::close(s.fd) };
                Out { buffer: b, ..o }
            }
            "va-import" => {
                let align: u32 = args.get("pitch-align", 256);
                let pitch = w.div_ceil(align) * align;
                let uv_off = (pitch * h).div_ceil(4096) * 4096;
                let size = uv_off as u64 + pitch as u64 * h as u64 / 2;
                let (b, fd, len) = gpu.export_buffer(size);
                let o = Out { buffer: b, size, offset: [0, uv_off], pitch: [pitch, pitch], va_surface: None, planes: None };
                validate_out(&o, w, h);
                let mut surface = 0u32;
                let r = unsafe { lc_va_import(va, w, h, fd, len as u32, LINEAR, o.offset.as_ptr(), o.pitch.as_ptr(), &mut surface) };
                assert_eq!(r, 0, "vaCreateSurfaces from our DMA-BUF: status {}", -r);
                if outs.is_empty() {
                    println!("VA surface {surface} over a Vulkan buffer: pitch {pitch}, UV at {uv_off}, {len} bytes");
                }
                Out { va_surface: Some(surface), ..o }
            }
            "va-tiled" => {
                // libva's own NV12 surface, the encoder's input, written in place through two storage images.
                let mut s = LcNv12::default();
                let r = unsafe { lc_va_create_export(va, w, h, &mut s) };
                if outs.is_empty() {
                    println!("VA NV12 surface: {s:?} (modifier {:#x}, status {r})", s.modifier);
                }
                assert_eq!(r, 0, "vaExportSurfaceHandle: one object and two layers required");
                assert_eq!(s.fourcc, VA_FOURCC_NV12);
                assert_eq!(s.modifier, MODIFIER, "the VA surface has another modifier");
                let len = fd_size(s.fd);
                assert!(s.size as u64 <= len);
                let o = Out { buffer: vk::Buffer::null(), size: s.size as u64, offset: s.offset, pitch: s.pitch, va_surface: Some(s.surface), planes: None };
                validate_out(&o, w, h);
                let usage = vk::ImageUsageFlags::STORAGE | vk::ImageUsageFlags::TRANSFER_SRC | vk::ImageUsageFlags::TRANSFER_DST;
                let cell = std::cell::Cell::new(vk::DeviceMemory::null());
                let shared = (args.get::<u32>("shared-import", 1) != 0).then_some(&cell);
                let (yi, yv) = gpu.import_plane_in(s.fd, shared, vk::Format::R8_UNORM, 1, usage, w, h, s.offset[0], s.pitch[0]);
                let (ci, cv) = gpu.import_plane_in(s.fd, shared, vk::Format::R8G8_UNORM, 2, usage, w / 2, h / 2, s.offset[1], s.pitch[1]);
                unsafe { libc::close(s.fd) };
                gpu.one_shot(|cb| unsafe {
                    let b = |img| {
                        vk::ImageMemoryBarrier::default()
                            .image(img)
                            .old_layout(vk::ImageLayout::UNDEFINED)
                            .new_layout(vk::ImageLayout::GENERAL)
                            .dst_access_mask(vk::AccessFlags::SHADER_WRITE)
                            .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .subresource_range(color_range())
                    };
                    dev.cmd_pipeline_barrier(cb, vk::PipelineStageFlags::TOP_OF_PIPE, vk::PipelineStageFlags::COMPUTE_SHADER, vk::DependencyFlags::empty(), &[], &[], &[b(yi), b(ci)]);
                });
                Out { planes: Some([(yi, yv), (ci, cv)]), ..o }
            }
            "vk-tiled" => {
                // Vulkan-owned NV12 at the encoder's own tiled layout (the one libva's surfaces have:
                // MODIFIER, Y pitch 2816, CbCr pitch 3072 at 6488064 for 2752x2064), exported as one DMA-BUF
                // and imported into libva as an NV12 surface.
                let ypitch: u32 = args.get("y-pitch", w.div_ceil(256) * 256);
                let cpitch: u32 = args.get("c-pitch", (w).div_ceil(512) * 512);
                let coff: u32 = args.get("c-offset", (ypitch * h.div_ceil(256) * 256).div_ceil(65536) * 65536);
                let usage = vk::ImageUsageFlags::STORAGE | vk::ImageUsageFlags::TRANSFER_SRC | vk::ImageUsageFlags::TRANSFER_DST;
                let mk = |f: vk::Format, iw: u32, ih: u32, off: u32, pitch: u32| unsafe {
                    let layouts = [vk::SubresourceLayout { offset: off as u64, size: 0, row_pitch: pitch as u64, array_pitch: 0, depth_pitch: 0 }];
                    let mut explicit = vk::ImageDrmFormatModifierExplicitCreateInfoEXT::default().drm_format_modifier(MODIFIER).plane_layouts(&layouts);
                    let mut ext = vk::ExternalMemoryImageCreateInfo::default().handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
                    let img = dev
                        .create_image(
                            &vk::ImageCreateInfo::default()
                                .image_type(vk::ImageType::TYPE_2D)
                                .format(f)
                                .extent(vk::Extent3D { width: iw, height: ih, depth: 1 })
                                .mip_levels(1)
                                .array_layers(1)
                                .samples(vk::SampleCountFlags::TYPE_1)
                                .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
                                .usage(usage)
                                .initial_layout(vk::ImageLayout::UNDEFINED)
                                .push_next(&mut explicit)
                                .push_next(&mut ext),
                            None,
                        )
                        .expect("tiled plane image");
                    let req = dev.get_image_memory_requirements(img);
                    let l = dev.get_image_subresource_layout(img, vk::ImageSubresource { aspect_mask: vk::ImageAspectFlags::MEMORY_PLANE_0_EXT, mip_level: 0, array_layer: 0 });
                    (img, req, l)
                };
                let (yi, yreq, yl) = mk(vk::Format::R8_UNORM, w, h, 0, ypitch);
                let (ci, creq, cl) = mk(vk::Format::R8G8_UNORM, w / 2, h / 2, coff, cpitch);
                assert!(yl.offset + yl.size <= cl.offset, "planes overlap: {yl:?} {cl:?}");
                let size = yreq.size.max(creq.size);
                let (fd, len) = unsafe {
                    let ty = gpu.mem_type(yreq.memory_type_bits & creq.memory_type_bits, vk::MemoryPropertyFlags::DEVICE_LOCAL, vk::MemoryPropertyFlags::empty());
                    let mut export = vk::ExportMemoryAllocateInfo::default().handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
                    let m = dev
                        .allocate_memory(&vk::MemoryAllocateInfo::default().allocation_size(size).memory_type_index(ty).push_next(&mut export), None)
                        .expect("exportable memory");
                    dev.bind_image_memory(yi, m, 0).unwrap();
                    dev.bind_image_memory(ci, m, 0).unwrap();
                    let fd = gpu
                        .fd_ext
                        .get_memory_fd(&vk::MemoryGetFdInfoKHR::default().memory(m).handle_type(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT))
                        .expect("export fd");
                    (fd, fd_size(fd))
                };
                let o = Out { buffer: vk::Buffer::null(), size: len, offset: [yl.offset as u32, cl.offset as u32], pitch: [yl.row_pitch as u32, cl.row_pitch as u32], va_surface: None, planes: None };
                validate_out(&o, w, h);
                let mut surface = 0u32;
                let r = unsafe { lc_va_import(va, w, h, fd, len as u32, MODIFIER, o.offset.as_ptr(), o.pitch.as_ptr(), &mut surface) };
                if outs.is_empty() {
                    println!("Vulkan tiled NV12: Y {yl:?}, CbCr {cl:?}, {len} bytes; vaCreateSurfaces status {}", -r);
                }
                assert_eq!(r, 0, "libva refused the Vulkan NV12 DMA-BUF");
                let v = |img, f| unsafe {
                    dev.create_image_view(&vk::ImageViewCreateInfo::default().image(img).view_type(vk::ImageViewType::TYPE_2D).format(f).subresource_range(color_range()), None)
                        .unwrap()
                };
                let (yv, cv) = (v(yi, vk::Format::R8_UNORM), v(ci, vk::Format::R8G8_UNORM));
                gpu.one_shot(|cb| unsafe {
                    let b = |img| {
                        vk::ImageMemoryBarrier::default()
                            .image(img)
                            .old_layout(vk::ImageLayout::UNDEFINED)
                            .new_layout(vk::ImageLayout::GENERAL)
                            .dst_access_mask(vk::AccessFlags::SHADER_WRITE)
                            .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .subresource_range(color_range())
                    };
                    dev.cmd_pipeline_barrier(cb, vk::PipelineStageFlags::TOP_OF_PIPE, vk::PipelineStageFlags::COMPUTE_SHADER, vk::DependencyFlags::empty(), &[], &[], &[b(yi), b(ci)]);
                });
                Out { va_surface: Some(surface), planes: Some([(yi, yv), (ci, cv)]), ..o }
            }
            "img" => {
                // Vulkan-owned R8 + R8G8 storage images (optimal tiling): the shader without libva.
                let mk = |f: vk::Format, iw: u32, ih: u32| unsafe {
                    let img = dev
                        .create_image(
                            &vk::ImageCreateInfo::default()
                                .image_type(vk::ImageType::TYPE_2D)
                                .format(f)
                                .extent(vk::Extent3D { width: iw, height: ih, depth: 1 })
                                .mip_levels(1)
                                .array_layers(1)
                                .samples(vk::SampleCountFlags::TYPE_1)
                                .tiling(vk::ImageTiling::OPTIMAL)
                                .usage(vk::ImageUsageFlags::STORAGE | vk::ImageUsageFlags::TRANSFER_SRC),
                            None,
                        )
                        .unwrap();
                    let req = dev.get_image_memory_requirements(img);
                    let ty = gpu.mem_type(req.memory_type_bits, vk::MemoryPropertyFlags::DEVICE_LOCAL, vk::MemoryPropertyFlags::empty());
                    let m = dev.allocate_memory(&vk::MemoryAllocateInfo::default().allocation_size(req.size).memory_type_index(ty), None).unwrap();
                    dev.bind_image_memory(img, m, 0).unwrap();
                    let v = dev
                        .create_image_view(&vk::ImageViewCreateInfo::default().image(img).view_type(vk::ImageViewType::TYPE_2D).format(f).subresource_range(color_range()), None)
                        .unwrap();
                    (img, v)
                };
                let (yi, yv) = mk(vk::Format::R8_UNORM, w, h);
                let (ci, cv) = mk(vk::Format::R8G8_UNORM, w / 2, h / 2);
                gpu.one_shot(|cb| unsafe {
                    let b = |img| {
                        vk::ImageMemoryBarrier::default()
                            .image(img)
                            .old_layout(vk::ImageLayout::UNDEFINED)
                            .new_layout(vk::ImageLayout::GENERAL)
                            .dst_access_mask(vk::AccessFlags::SHADER_WRITE)
                            .src_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .dst_queue_family_index(vk::QUEUE_FAMILY_IGNORED)
                            .subresource_range(color_range())
                    };
                    dev.cmd_pipeline_barrier(cb, vk::PipelineStageFlags::TOP_OF_PIPE, vk::PipelineStageFlags::COMPUTE_SHADER, vk::DependencyFlags::empty(), &[], &[], &[b(yi), b(ci)]);
                });
                let pitch = w;
                Out { buffer: vk::Buffer::null(), size: pitch as u64 * h as u64 * 3 / 2, offset: [0, pitch * h], pitch: [pitch, pitch], va_surface: None, planes: Some([(yi, yv), (ci, cv)]) }
            }
            m => panic!("unknown --out {m}"),
        };
        validate_out(&o, w, h);
        outs.push(o);
    }

    // Descriptors, timestamp queries, and one pre-recorded command buffer per ring frame.
    let (sets, qpool, cbs) = unsafe {
        let sizes = [
            vk::DescriptorPoolSize { ty: vk::DescriptorType::SAMPLED_IMAGE, descriptor_count: ring as u32 },
            vk::DescriptorPoolSize { ty: vk::DescriptorType::STORAGE_BUFFER, descriptor_count: ring as u32 },
            vk::DescriptorPoolSize { ty: vk::DescriptorType::STORAGE_IMAGE, descriptor_count: 2 * ring as u32 },
        ];
        let dpool = dev
            .create_descriptor_pool(&vk::DescriptorPoolCreateInfo::default().max_sets(ring as u32).pool_sizes(&sizes), None)
            .unwrap();
        let layouts = vec![set_layout; ring];
        let sets = dev
            .allocate_descriptor_sets(&vk::DescriptorSetAllocateInfo::default().descriptor_pool(dpool).set_layouts(&layouts))
            .unwrap();
        for (i, &set) in sets.iter().enumerate() {
            let o = &outs[i % nout];
            let ii = [vk::DescriptorImageInfo { sampler: vk::Sampler::null(), image_view: images[i].1, image_layout: vk::ImageLayout::GENERAL }];
            let src = vk::WriteDescriptorSet::default().dst_set(set).dst_binding(0).descriptor_type(vk::DescriptorType::SAMPLED_IMAGE).image_info(&ii);
            if let Some([(_, yv), (_, cv)]) = o.planes {
                let yi = [vk::DescriptorImageInfo { sampler: vk::Sampler::null(), image_view: yv, image_layout: vk::ImageLayout::GENERAL }];
                let ci = [vk::DescriptorImageInfo { sampler: vk::Sampler::null(), image_view: cv, image_layout: vk::ImageLayout::GENERAL }];
                dev.update_descriptor_sets(
                    &[
                        src,
                        vk::WriteDescriptorSet::default().dst_set(set).dst_binding(1).descriptor_type(vk::DescriptorType::STORAGE_IMAGE).image_info(&yi),
                        vk::WriteDescriptorSet::default().dst_set(set).dst_binding(2).descriptor_type(vk::DescriptorType::STORAGE_IMAGE).image_info(&ci),
                    ],
                    &[],
                );
            } else {
                let bi = [vk::DescriptorBufferInfo { buffer: o.buffer, offset: 0, range: o.size }];
                dev.update_descriptor_sets(
                    &[src, vk::WriteDescriptorSet::default().dst_set(set).dst_binding(1).descriptor_type(vk::DescriptorType::STORAGE_BUFFER).buffer_info(&bi)],
                    &[],
                );
            }
        }
        let qpool = dev
            .create_query_pool(&vk::QueryPoolCreateInfo::default().query_type(vk::QueryType::TIMESTAMP).query_count(2 * ring as u32), None)
            .unwrap();
        let cbs = dev
            .allocate_command_buffers(&vk::CommandBufferAllocateInfo::default().command_pool(gpu.pool).command_buffer_count(ring as u32))
            .unwrap();
        // Buffer shader: one invocation per `words` 4x2 blocks; image shader: one per 2x2 block.
        let blocks_x = if out_is_tiled { w / 2 } else { (w / 4).div_ceil(words) };
        let gx = blocks_x.div_ceil(wx);
        let gy = (h / 2).div_ceil(wy);
        for (i, &cb) in cbs.iter().enumerate() {
            let o = &outs[i % nout];
            let pc: Vec<u32> = if out_is_tiled { vec![w, h] } else { vec![o.offset[0] / 4, o.pitch[0] / 4, o.offset[1] / 4, o.pitch[1] / 4, w, h] };
            dev.begin_command_buffer(cb, &vk::CommandBufferBeginInfo::default()).unwrap();
            dev.cmd_reset_query_pool(cb, qpool, 2 * i as u32, 2);
            dev.cmd_write_timestamp(cb, vk::PipelineStageFlags::TOP_OF_PIPE, qpool, 2 * i as u32);
            dev.cmd_bind_pipeline(cb, vk::PipelineBindPoint::COMPUTE, pipeline);
            dev.cmd_bind_descriptor_sets(cb, vk::PipelineBindPoint::COMPUTE, layout, 0, &[sets[i]], &[]);
            let bytes: Vec<u8> = pc.iter().flat_map(|v| v.to_ne_bytes()).collect();
            dev.cmd_push_constants(cb, layout, vk::ShaderStageFlags::COMPUTE, 0, &bytes);
            dev.cmd_dispatch(cb, gx, gy, 1);
            dev.cmd_write_timestamp(cb, vk::PipelineStageFlags::BOTTOM_OF_PIPE, qpool, 2 * i as u32 + 1);
            let mb = vk::MemoryBarrier::default()
                .src_access_mask(vk::AccessFlags::SHADER_WRITE)
                .dst_access_mask(vk::AccessFlags::TRANSFER_READ | vk::AccessFlags::HOST_READ | vk::AccessFlags::MEMORY_READ);
            dev.cmd_pipeline_barrier(cb, vk::PipelineStageFlags::COMPUTE_SHADER, vk::PipelineStageFlags::TRANSFER | vk::PipelineStageFlags::HOST | vk::PipelineStageFlags::BOTTOM_OF_PIPE, vk::DependencyFlags::empty(), &[mb], &[], &[]);
            dev.end_command_buffer(cb).unwrap();
        }
        println!("dispatch: {gx}x{gy} workgroups for {w}x{h}");
        (sets, qpool, cbs)
    };
    let _ = sets;

    let gpu_ms = |i: usize| -> f64 {
        let mut ts = [0u64; 2];
        unsafe { dev.get_query_pool_results(qpool, 2 * i as u32, &mut ts, vk::QueryResultFlags::TYPE_64 | vk::QueryResultFlags::WAIT).unwrap() };
        ((ts[1].wrapping_sub(ts[0])) & gpu.ts_mask) as f64 * gpu.ts_period / 1e6
    };

    // Correctness: convert `checks` ring frames, read each back and compare with the CPU reference.
    let (rb, rb_mem) = gpu.buffer(
        outs[0].size.max(outs[1].size),
        vk::BufferUsageFlags::TRANSFER_DST,
        vk::MemoryPropertyFlags::HOST_VISIBLE | vk::MemoryPropertyFlags::HOST_CACHED,
    );
    let mut worst = (0u32, 0u32);
    for c in 0..checks {
        let i = c * ring / checks.max(1);
        let o = &outs[i % nout];
        if let (Some([(yi, _), (ci, _)]), true) = (o.planes, std::env::var_os("VKCONVERT_CLEAR").is_some()) {
            // Diagnostic: clear the planes to Y 100, CbCr (50, 200) instead of converting.
            gpu.one_shot(|cb| unsafe {
                let r = [color_range()];
                let cy = vk::ClearColorValue { float32: [100.0 / 255.0, 0.0, 0.0, 1.0] };
                let cc = vk::ClearColorValue { float32: [50.0 / 255.0, 200.0 / 255.0, 0.0, 1.0] };
                dev.cmd_clear_color_image(cb, yi, vk::ImageLayout::GENERAL, &cy, &r);
                dev.cmd_clear_color_image(cb, ci, vk::ImageLayout::GENERAL, &cc, &r);
                let mb = vk::MemoryBarrier::default().src_access_mask(vk::AccessFlags::TRANSFER_WRITE).dst_access_mask(vk::AccessFlags::MEMORY_READ);
                dev.cmd_pipeline_barrier(cb, vk::PipelineStageFlags::TRANSFER, vk::PipelineStageFlags::ALL_COMMANDS, vk::DependencyFlags::empty(), &[mb], &[], &[]);
            });
            let mut y = vec![0u8; (w * h) as usize];
            let mut uv = vec![0u8; (w * h / 2) as usize];
            if let Some(sfc) = o.va_surface {
                let r = unsafe { lc_va_readback(va, sfc, w, h, y.as_mut_ptr(), uv.as_mut_ptr()) };
                println!("clear test via libva (status {r}): Y[0..4] {:?} Y mid {} CbCr[0..4] {:?}", &y[..4], y[y.len() / 2], &uv[..4]);
            }
        }
        gpu.submit_wait(cbs[i], Duration::from_secs(5));
        let mut got: Vec<(&str, Vec<u8>, Vec<u8>)> = Vec::new();
        if let Some(sfc) = o.va_surface {
            let (mut gy_, mut guv) = (vec![0u8; (w * h) as usize], vec![0u8; (w * h / 2) as usize]);
            let r = unsafe { lc_va_readback(va, sfc, w, h, gy_.as_mut_ptr(), guv.as_mut_ptr()) };
            assert_eq!(r, 0, "VA readback");
            got.push(("libva", gy_, guv));
        }
        if o.va_surface.is_none() || args.get::<u32>("vk-readback", 1) != 0 {
            let (mut gy_, mut guv) = (vec![0u8; (w * h) as usize], vec![0u8; (w * h / 2) as usize]);
            if let Some([(yi, _), (ci, _)]) = o.planes {
                // Detiled by RADV: Y then CbCr, tightly packed.
                gpu.one_shot(|cb| unsafe {
                    let layers = vk::ImageSubresourceLayers { aspect_mask: vk::ImageAspectFlags::COLOR, mip_level: 0, base_array_layer: 0, layer_count: 1 };
                    let ry = vk::BufferImageCopy::default().image_subresource(layers).image_extent(vk::Extent3D { width: w, height: h, depth: 1 });
                    let rc = vk::BufferImageCopy::default()
                        .buffer_offset((w * h) as u64)
                        .image_subresource(layers)
                        .image_extent(vk::Extent3D { width: w / 2, height: h / 2, depth: 1 });
                    dev.cmd_copy_image_to_buffer(cb, yi, vk::ImageLayout::GENERAL, rb, &[ry]);
                    dev.cmd_copy_image_to_buffer(cb, ci, vk::ImageLayout::GENERAL, rb, &[rc]);
                    let mb = vk::MemoryBarrier::default().src_access_mask(vk::AccessFlags::TRANSFER_WRITE).dst_access_mask(vk::AccessFlags::HOST_READ);
                    dev.cmd_pipeline_barrier(cb, vk::PipelineStageFlags::TRANSFER, vk::PipelineStageFlags::HOST, vk::DependencyFlags::empty(), &[mb], &[], &[]);
                });
                unsafe {
                    let n = (w * h * 3 / 2) as u64;
                    let p = dev.map_memory(rb_mem, 0, n, vk::MemoryMapFlags::empty()).unwrap() as *const u8;
                    dev.invalidate_mapped_memory_ranges(&[vk::MappedMemoryRange::default().memory(rb_mem).offset(0).size(vk::WHOLE_SIZE)]).unwrap();
                    let all = std::slice::from_raw_parts(p, n as usize);
                    gy_.copy_from_slice(&all[..(w * h) as usize]);
                    guv.copy_from_slice(&all[(w * h) as usize..]);
                    dev.unmap_memory(rb_mem);
                }
            } else {
                gpu.one_shot(|cb| unsafe {
                    dev.cmd_copy_buffer(cb, o.buffer, rb, &[vk::BufferCopy { src_offset: 0, dst_offset: 0, size: o.size }]);
                    let mb = vk::MemoryBarrier::default().src_access_mask(vk::AccessFlags::TRANSFER_WRITE).dst_access_mask(vk::AccessFlags::HOST_READ);
                    dev.cmd_pipeline_barrier(cb, vk::PipelineStageFlags::TRANSFER, vk::PipelineStageFlags::HOST, vk::DependencyFlags::empty(), &[mb], &[], &[]);
                });
                unsafe {
                    let p = dev.map_memory(rb_mem, 0, o.size, vk::MemoryMapFlags::empty()).unwrap() as *const u8;
                    dev.invalidate_mapped_memory_ranges(&[vk::MappedMemoryRange::default().memory(rb_mem).offset(0).size(vk::WHOLE_SIZE)]).unwrap();
                    let all = std::slice::from_raw_parts(p, o.size as usize);
                    for r in 0..h as usize {
                        let s = o.offset[0] as usize + r * o.pitch[0] as usize;
                        gy_[r * w as usize..][..w as usize].copy_from_slice(&all[s..s + w as usize]);
                    }
                    for r in 0..h as usize / 2 {
                        let s = o.offset[1] as usize + r * o.pitch[1] as usize;
                        guv[r * w as usize..][..w as usize].copy_from_slice(&all[s..s + w as usize]);
                    }
                    dev.unmap_memory(rb_mem);
                }
            }
            got.push(("vulkan", gy_, guv));
        }
        let content = text_frame(w as usize, h as usize, i * step, period);
        let (ry, ruv) = reference(&content, w as usize, h as usize);
        let t = gpu_ms(i);
        for (via, gy_, guv) in &got {
            print!("check frame {i} (read back via {via}, {t:.3} ms GPU):");
            let (my, _) = compare("Y", gy_, &ry);
            let (muv, _) = compare("CbCr", guv, &ruv);
            println!();
            worst = (worst.0.max(my), worst.1.max(muv));
        }
    }
    if checks > 0 {
        println!("correctness: worst max abs error Y {} CbCr {} -> {}", worst.0, worst.1, if worst.0 <= 1 && worst.1 <= 1 { "PASS" } else { "FAIL" });
    }

    // Timed run: one frame in flight, frame f converts ring frame f mod ring, paced at `fps` (0: back to back).
    let mut g = Vec::with_capacity(frames);
    let mut c = Vec::with_capacity(frames);
    let t0 = Instant::now();
    for f in 0..frames {
        if fps > 0.0 {
            let due = t0 + Duration::from_secs_f64(f as f64 / fps);
            let now = Instant::now();
            if due > now {
                std::thread::sleep(due - now);
            }
        }
        let i = f % ring;
        let d = gpu.submit_wait(cbs[i], Duration::from_secs(5));
        c.push(d.as_secs_f64() * 1e3);
        g.push(gpu_ms(i));
    }
    let wall = t0.elapsed().as_secs_f64();
    if frames > 0 {
        println!("timed: {frames} frames in {wall:.2} s ({:.1} fps), pacing {}", frames as f64 / wall, if fps > 0.0 { format!("{fps} Hz") } else { "none".into() });
        stats("GPU (timestamps)", &mut g);
        stats("submit -> fence", &mut c);
        let mb = (w as f64 * h as f64 * 4.0 + w as f64 * h as f64 * 1.5) / 1e6;
        let p50 = g[g.len() / 2];
        println!("effective bandwidth at GPU p50: {:.1} GB/s ({mb:.1} MB per frame)", mb / p50);
    }
    unsafe { dev.device_wait_idle().unwrap() };
}
