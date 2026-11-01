//! One captured picture as the converter takes it, its import validation, and the CPU reference of the
//! conversion (SL5's f64 reference, `spikes/linux-convert/gl/glconv.c`'s `ref_nv12`). No Swift counterpart:
//! ScreenCaptureKit hands over a `CVPixelBuffer` that is already 4:4:4 YCbCr.

use std::os::fd::OwnedFd;

/// Where a captured picture's pixels are.
#[derive(Debug)]
pub enum Pixels {
    /// A DMA-BUF (zero-copy): our own duplicate of the buffer's fd, so it stays valid whatever PipeWire does
    /// with its buffer, and the layout PipeWire gave.
    DmaBuf(DmaBufPlane),
    /// Shared memory (the fallback), copied out of PipeWire's buffer on its thread: `stride` bytes per row.
    Memory { data: Vec<u8>, stride: u32 },
}

/// One single-plane DMA-BUF.
#[derive(Debug)]
pub struct DmaBufPlane {
    pub fd: OwnedFd,
    /// DRM fourcc (`XR24` for BGRx).
    pub fourcc: u32,
    pub modifier: u64,
    pub offset: u32,
    pub stride: u32,
    /// The DMA-BUF's real size (`lseek(fd, 0, SEEK_END)`).
    pub size: u64,
}

/// A captured picture: its pixels, its size, and when it was captured.
#[derive(Debug)]
pub struct Picture {
    pub width: u32,
    pub height: u32,
    pub pixels: Pixels,
}

/// Checks a DMA-BUF's layout before it is imported (SL5: "validate every import"): the modifier negotiated, a
/// pitch covering a row, and `offset + pitch × rows` within the buffer's real size.
pub fn validate_dmabuf(plane: &DmaBufPlane, width: u32, height: u32, modifier: u64) -> Result<(), String> {
    if plane.modifier != modifier {
        return Err(format!("modifier {:#x}, not the {modifier:#x} negotiated", plane.modifier));
    }
    if plane.stride < width.saturating_mul(4) {
        return Err(format!("stride {} is below a row of {width} pixels", plane.stride));
    }
    let end = u64::from(plane.offset) + u64::from(plane.stride) * u64::from(height);
    if end > plane.size {
        return Err(format!(
            "offset {} + stride {} × {height} rows = {end} exceeds the buffer's {} bytes",
            plane.offset, plane.stride, plane.size
        ));
    }
    Ok(())
}

/// Checks a shared-memory picture: enough bytes for every row at its stride.
pub fn validate_memory(data: &[u8], stride: u32, width: u32, height: u32) -> Result<(), String> {
    if stride < width.saturating_mul(4) {
        return Err(format!("stride {stride} is below a row of {width} pixels"));
    }
    let need = u64::from(stride) * u64::from(height.saturating_sub(1)) + u64::from(width) * 4;
    if (data.len() as u64) < need {
        return Err(format!("{} bytes, {need} needed", data.len()));
    }
    Ok(())
}

fn q8(v: f64) -> u8 {
    (v + 0.5).floor().clamp(0.0, 255.0) as u8
}

/// The CPU reference of the conversion, in f64: BT.709 full range on the non-linear values, Y = 0.2126 R +
/// 0.7152 G + 0.0722 B per pixel, Cb = (B − Y)/1.8556 + 128 and Cr = (R − Y)/1.5748 + 128 of each 2×2 block's
/// mean, rounded and clamped. Input: packed BGRx rows (`width × 4` bytes each); output: packed NV12.
pub fn reference_nv12(bgrx: &[u8], width: usize, height: usize) -> Vec<u8> {
    assert_eq!(bgrx.len(), width * height * 4);
    let mut out = vec![0u8; width * height * 3 / 2];
    let (y_plane, uv_plane) = out.split_at_mut(width * height);
    for (p, y) in bgrx.as_chunks::<4>().0.iter().zip(y_plane.iter_mut()) {
        *y = q8(0.2126 * f64::from(p[2]) + 0.7152 * f64::from(p[1]) + 0.0722 * f64::from(p[0]));
    }
    for by in 0..height / 2 {
        for bx in 0..width / 2 {
            let (mut r, mut g, mut b) = (0.0, 0.0, 0.0);
            for j in 0..2 {
                for i in 0..2 {
                    let p = &bgrx[((2 * by + j) * width + 2 * bx + i) * 4..][..4];
                    r += f64::from(p[2]);
                    g += f64::from(p[1]);
                    b += f64::from(p[0]);
                }
            }
            let (r, g, b) = (r / 4.0, g / 4.0, b / 4.0);
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            let at = (by * (width / 2) + bx) * 2;
            uv_plane[at] = q8((b - y) / 1.8556 + 128.0);
            uv_plane[at + 1] = q8((r - y) / 1.5748 + 128.0);
        }
    }
    out
}

/// The largest absolute difference between two NV12 pictures, luma and chroma apart, and how many samples
/// differ at all.
pub fn max_error(a: &[u8], b: &[u8], width: usize, height: usize) -> (u8, u8, usize) {
    assert_eq!(a.len(), b.len());
    let luma = width * height;
    let diff = |x: &[u8], y: &[u8]| x.iter().zip(y).map(|(p, q)| p.abs_diff(*q)).max().unwrap_or(0);
    let off = a.iter().zip(b).filter(|(p, q)| p != q).count();
    (diff(&a[..luma], &b[..luma]), diff(&a[luma..], &b[luma..]), off)
}

/// Synthetic BGRx content for the GPU tests, as `glconv.c` makes it: by default a scrolling-terminal pattern
/// (`gen_frame`: five colours on dark purple, antialiased edges, junk in the x byte); with `all_colours`, the
/// colour of pixel `p` of frame `f` is `f × width × height + p` while that is below 2^24 (so frames 0–2 of
/// 2752×2064 hold every 24-bit colour once), random pixels after (`gen_allcolors`).
pub fn synthetic_bgrx(width: usize, height: usize, frame: u32, all_colours: bool) -> Vec<u8> {
    fn hash3(a: u32, b: u32, c: u32) -> u32 {
        let mut h = a.wrapping_mul(0x9E37_79B1)
            ^ b.wrapping_add(0x7F4A_7C15).wrapping_mul(0x85EB_CA77)
            ^ c.wrapping_add(0x1656_67B1).wrapping_mul(0xC2B2_AE3D);
        h ^= h >> 15;
        h = h.wrapping_mul(0x2C1B_3C6D);
        h ^= h >> 12;
        h = h.wrapping_mul(0x297A_2D39);
        h ^= h >> 15;
        h
    }
    const PALETTE: [[u8; 3]; 5] = [[230, 230, 230], [120, 220, 120], [250, 200, 80], [110, 170, 250], [240, 110, 140]];
    let mut out = vec![0u8; width * height * 4];
    if all_colours {
        for (p, px) in out.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let mut c = u64::from(frame) * (width * height) as u64 + p as u64;
            if frame >= 3 || c >= 1 << 24 {
                c = u64::from(hash3(p as u32, frame, 11) & 0xFF_FFFF);
            }
            px.copy_from_slice(&[c as u8, (c >> 8) as u8, (c >> 16) as u8, (p * 13) as u8]);
        }
        return out;
    }
    let scroll = frame as usize * 18;
    for y in 0..height {
        let yy = y + scroll;
        let (line, r) = ((yy / 18) as u32, yy % 18);
        for x in 0..width {
            let (col, cx) = ((x / 9) as u32, x % 9);
            let (mut rr, mut gg, mut bb) = (40.0f32, 16.0f32, 58.0f32);
            let ch = hash3(line, col, 1);
            let len = 20 + hash3(line, 0, 7) % 280;
            if col < len && (ch & 7) != 0 && (2..16).contains(&r) && (1..8).contains(&cx) {
                let g = hash3(line * 31 + col, r as u32, cx as u32);
                if g & 3 != 0 {
                    let p = PALETTE[(hash3(line, col / 12, 3) % 5) as usize];
                    let a = if g & 0x30 == 0 { 0.45 } else { 1.0 };
                    rr = (rr + a * (f32::from(p[0]) - rr) + 0.5).floor();
                    gg = (gg + a * (f32::from(p[1]) - gg) + 0.5).floor();
                    bb = (bb + a * (f32::from(p[2]) - bb) + 0.5).floor();
                }
            }
            let at = (y * width + x) * 4;
            out[at..at + 4].copy_from_slice(&[bb as u8, gg as u8, rr as u8, (x * 7 + y) as u8]);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plane(stride: u32, offset: u32, size: u64, modifier: u64) -> DmaBufPlane {
        let file = tempfile::tempfile().unwrap();
        DmaBufPlane { fd: file.into(), fourcc: crate::gbm::DRM_FORMAT_XRGB8888, modifier, offset, stride, size }
    }

    #[test]
    fn dmabuf_validation() {
        let m = crate::gbm::MUTTER_MODIFIER;
        let ok = plane(11008, 0, 11008 * 2064, m);
        assert_eq!(validate_dmabuf(&ok, 2752, 2064, m), Ok(()));
        assert!(validate_dmabuf(&ok, 2752, 2064, 0).unwrap_err().contains("modifier"));
        assert!(validate_dmabuf(&plane(11000, 0, 1 << 30, m), 2752, 2064, m).unwrap_err().contains("stride"));
        assert!(validate_dmabuf(&plane(11008, 4096, 11008 * 2064, m), 2752, 2064, m).unwrap_err().contains("exceeds"));
        assert!(validate_dmabuf(&plane(11008, 0, 11008 * 2063, m), 2752, 2064, m).is_err());
    }

    #[test]
    fn memory_validation() {
        assert_eq!(validate_memory(&[0; 16 * 3 + 8], 16, 2, 4), Ok(()));
        assert!(validate_memory(&[0; 16 * 3 + 7], 16, 2, 4).is_err());
        assert!(validate_memory(&[0; 1024], 4, 2, 4).is_err());
    }

    #[test]
    fn reference_of_known_colours() {
        // A 2×2 block of one colour gives its Y in all four and its CbCr.
        let px = |b: u8, g: u8, r: u8| [b, g, r, 0x5A];
        let block = |c: [u8; 4]| [c, c, c, c].concat();
        let white = reference_nv12(&block(px(255, 255, 255)), 2, 2);
        assert_eq!(white, [255, 255, 255, 255, 128, 128]);
        let black = reference_nv12(&block(px(0, 0, 0)), 2, 2);
        assert_eq!(black, [0, 0, 0, 0, 128, 128]);
        let red = reference_nv12(&block(px(0, 0, 255)), 2, 2);
        // Y 54.2, Cb (0 − 54.2)/1.8556 + 128 = 98.8, Cr (255 − 54.2)/1.5748 + 128 = 255.5 → clamped.
        assert_eq!(red, [54, 54, 54, 54, 99, 255]);
        let blue = reference_nv12(&block(px(255, 0, 0)), 2, 2);
        assert_eq!(&blue[4..], &[255, 116]);
        // Chroma is the block's mean: two white, two black pixels.
        let mixed = [px(255, 255, 255), px(0, 0, 0), px(0, 0, 0), px(255, 255, 255)].concat();
        assert_eq!(reference_nv12(&mixed, 2, 2), [255, 0, 0, 255, 128, 128]);
        // The x byte never matters.
        let mut junk = block(px(10, 200, 30));
        junk[3] = 0;
        junk[7] = 255;
        assert_eq!(reference_nv12(&junk, 2, 2), reference_nv12(&block(px(10, 200, 30)), 2, 2));
    }

    #[test]
    fn errors_and_content() {
        let a = [10, 10, 10, 10, 128, 128];
        let b = [10, 11, 10, 10, 128, 126];
        assert_eq!(max_error(&a, &b, 2, 2), (1, 2, 2));
        let t = synthetic_bgrx(64, 36, 0, false);
        assert_eq!(t.len(), 64 * 36 * 4);
        assert_ne!(synthetic_bgrx(64, 36, 1, false), t, "it scrolls");
        let all = synthetic_bgrx(64, 64, 0, true);
        assert_eq!(&all[..8], &[0, 0, 0, 0, 1, 0, 0, 13]);
        assert_eq!(&all[4095 * 4..4095 * 4 + 3], &[255, 15, 0], "colour = pixel index, R in the high byte");
        assert_eq!(&synthetic_bgrx(64, 64, 1, true)[..3], &[0, 16, 0], "frame 1 continues at 4096");
    }
}
