//! The cursor on lain's display, from its screen-cast stream's metadata (decision L8; Swift: `CursorMonitor`
//! reads `NSCursor.currentSystem`, and `DisplayProvider.cursorLocation` reads `CGEvent.location`).
//!
//! `lain-linux-video` reads lain's stream and writes [`CursorState`] from its PipeWire thread: the hotspot
//! position in the stream's device pixels and, when the sprite changes, the bitmap (spike B, §6: Mutter sends
//! the bitmap only then, as premultiplied RGBA at the monitor's scale). `lain-gnome` writes where lain's
//! display is, and reads the state for [`CursorSource::current`] and `DisplayBackend::cursor_location`.
//!
//! **Difference from the Mac host:** the position is known only while the pointer is on lain's display (the
//! metadata is invalid elsewhere), so warps off lain's display go undetected (lead's decision 5).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use lain_platform::{CursorImage, CursorSource, PointF, RectF};

/// The pixel layout of a cursor bitmap in the stream's metadata (`spa_meta_bitmap.format`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BitmapFormat {
    /// What Mutter sends (spike B, §6): swapped to BGRA here.
    Rgba,
    /// Copied as is.
    Bgra,
}

/// Where lain's display is: written by `lain-gnome` on each layout change.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StreamGeometry {
    /// lain's display in global logical pixels.
    pub bounds: RectF,
    /// Its scale: device pixels per logical pixel.
    pub scale: f64,
}

/// `(i32::MIN, i32::MIN)`, which [`CursorState::set_position`] never stores.
const INVALID: u64 = 0x8000_0000_8000_0000;

fn pack(x: i32, y: i32) -> u64 {
    (u64::from(x as u32) << 32) | u64::from(y as u32)
}

fn unpack(v: u64) -> Option<(i32, i32)> {
    (v != INVALID).then_some(((v >> 32) as u32 as i32, v as u32 as i32))
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// A bitmap as Mutter sent it: format, width, height, stride, hotspot, bytes.
type SourceBitmap = (BitmapFormat, u32, u32, usize, (i32, i32), Vec<u8>);

/// The latest cursor of lain's stream, shared between `lain-linux-video` (the writer) and `lain-gnome` (the
/// reader). New in the port: Swift reads the cursor from AppKit on demand.
///
/// Writes never allocate unless the bitmap changed, and hold a lock only to swap an `Arc`, so the PipeWire
/// thread never waits for long. The position is one atomic word.
#[derive(Debug)]
pub struct CursorState {
    /// The hotspot in the stream's device pixels, or [`INVALID`].
    position: AtomicU64,
    /// The current image; `None` before the first bitmap and while the sprite is empty (hidden).
    image: Mutex<Option<Arc<CursorImage>>>,
    geometry: Mutex<Option<StreamGeometry>>,
    /// At a fractional scale, the last bitmap as Mutter sent it (format, size, stride, hotspot, bytes), so a
    /// resend isn't resampled again.
    resampled_from: Mutex<Option<SourceBitmap>>,
}

impl Default for CursorState {
    fn default() -> Self {
        Self {
            position: AtomicU64::new(INVALID),
            image: Mutex::new(None),
            geometry: Mutex::new(None),
            resampled_from: Mutex::new(None),
        }
    }
}

impl CursorState {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    // --- written by lain-linux-video, from the stream's `SPA_META_Cursor`

    /// Valid metadata: the hotspot at `(x, y)` in the stream's device pixels (`spa_meta_cursor.position`).
    pub fn set_position(&self, x: i32, y: i32) {
        // i32::MIN is kept for the INVALID sentinel; no stream is that large.
        self.position.store(pack(x.max(i32::MIN + 1), y.max(i32::MIN + 1)), Ordering::Release);
    }

    /// Invalid metadata (`spa_meta_cursor.id == 0`): the pointer is off lain's display, or hidden.
    pub fn set_invalid(&self) {
        self.position.store(INVALID, Ordering::Release);
    }

    /// A new bitmap (`bitmap_offset` set): `width × height` pixels, `stride` bytes per row, premultiplied, the
    /// hotspot in bitmap pixels. An empty bitmap means no sprite. The image is replaced only if it differs, so
    /// a resend of the same sprite allocates nothing and keeps the same `Arc`.
    ///
    /// Short or malformed data is ignored (logged once per call at debug level).
    pub fn set_bitmap(
        &self,
        format: BitmapFormat,
        width: u32,
        height: u32,
        stride: usize,
        hotspot: (i32, i32),
        data: &[u8],
    ) {
        if width == 0 || height == 0 {
            *lock(&self.image) = None;
            return;
        }
        let (Ok(w), Ok(h)) = (u16::try_from(width), u16::try_from(height)) else {
            tracing::debug!(width, height, "cursor bitmap too large");
            return;
        };
        let row = usize::from(w) * 4;
        if stride < row || data.len() < stride * (usize::from(h) - 1) + row {
            tracing::debug!(width, height, stride, len = data.len(), "short cursor bitmap");
            return;
        }
        let fractional = lock(&self.geometry).map(|g| g.scale).filter(|s| (s - s.round()).abs() > 1e-3);
        if let Some(g) = fractional {
            self.set_fractional(format, (w, h), stride, hotspot, data, g);
            return;
        }
        let scale = self.integer_scale();
        let hx = hotspot.0 as f32 / f32::from(scale);
        let hy = hotspot.1 as f32 / f32::from(scale);
        let rows = (0..usize::from(h)).map(|r| &data[r * stride..r * stride + row]);
        {
            let current = lock(&self.image);
            if let Some(img) = current.as_ref()
                && img.pixel_width == w
                && img.pixel_height == h
                && img.scale == scale
                && img.hotspot_x.to_bits() == hx.to_bits()
                && img.hotspot_y.to_bits() == hy.to_bits()
                && rows.clone().zip(img.pixels.chunks_exact(row)).all(|(src, dst)| same_pixels(format, src, dst))
            {
                return;
            }
        }
        let mut pixels = Vec::with_capacity(row * usize::from(h));
        for src in rows {
            match format {
                BitmapFormat::Bgra => pixels.extend_from_slice(src),
                BitmapFormat::Rgba => {
                    for px in src.as_chunks::<4>().0 {
                        pixels.extend_from_slice(&[px[2], px[1], px[0], px[3]]);
                    }
                }
            }
        }
        let image = Arc::new(CursorImage::new(w, h, scale, hx, hy, pixels));
        *lock(&self.image) = Some(image);
    }

    // --- written by lain-gnome

    /// Where lain's display is now (`None`: no display).
    pub fn set_geometry(&self, geometry: Option<StreamGeometry>) {
        *lock(&self.geometry) = geometry;
    }

    /// A new display: nothing known yet.
    pub fn reset(&self) {
        self.set_invalid();
        *lock(&self.image) = None;
        *lock(&self.resampled_from) = None;
    }

    // --- read by lain-gnome

    /// The current image, `None` while the metadata is invalid or there's no sprite. The same `Arc` while
    /// unchanged.
    pub fn image(&self) -> Option<Arc<CursorImage>> {
        unpack(self.position.load(Ordering::Acquire))?;
        lock(&self.image).clone()
    }

    /// The pointer in global logical pixels: lain's origin plus the position over the scale, if it is inside
    /// lain's display. Positions just outside it (the sprite overlapping the stream, spike B §6) are ignored.
    pub fn location(&self) -> Option<PointF> {
        let (x, y) = unpack(self.position.load(Ordering::Acquire))?;
        let g = (*lock(&self.geometry))?;
        let p = device_to_global(g, x, y);
        g.bounds.contains(p).then_some(p)
    }

    /// A bitmap at a fractional monitor scale `g` (owner's choice, `lain-hostd`'s `scale`). The client takes an
    /// integer scale (`CursorShape.scale`) and draws `pixel_width / scale` points, so the bitmap is resampled to
    /// the next integer scale, keeping its size in points and the hotspot. New in the port: the Mac host always
    /// streams at 2×.
    fn set_fractional(
        &self,
        format: BitmapFormat,
        (w, h): (u16, u16),
        stride: usize,
        hotspot: (i32, i32),
        data: &[u8],
        g: f64,
    ) {
        let row = usize::from(w) * 4;
        let used = &data[..stride * (usize::from(h) - 1) + row];
        {
            let mut last = lock(&self.resampled_from);
            if let Some((f, lw, lh, ls, lhot, bytes)) = last.as_ref()
                && (*f, *lw, *lh, *ls, *lhot) == (format, u32::from(w), u32::from(h), stride, hotspot)
                && bytes == used
                && lock(&self.image).is_some()
            {
                return;
            }
            *last = Some((format, u32::from(w), u32::from(h), stride, hotspot, used.to_vec()));
        }
        // BGRA, premultiplied, packed.
        let mut src = Vec::with_capacity(row * usize::from(h));
        for r in 0..usize::from(h) {
            let line = &data[r * stride..r * stride + row];
            match format {
                BitmapFormat::Bgra => src.extend_from_slice(line),
                BitmapFormat::Rgba => {
                    for px in line.as_chunks::<4>().0 {
                        src.extend_from_slice(&[px[2], px[1], px[0], px[3]]);
                    }
                }
            }
        }
        let target = g.ceil().clamp(1.0, 255.0);
        let factor = target / g;
        let nw = ((f64::from(w) * factor).round() as u16).max(1);
        let nh = ((f64::from(h) * factor).round() as u16).max(1);
        let pixels = resample_bilinear(&src, usize::from(w), usize::from(h), usize::from(nw), usize::from(nh));
        let (hx, hy) = ((f64::from(hotspot.0) / g) as f32, (f64::from(hotspot.1) / g) as f32);
        *lock(&self.image) = Some(Arc::new(CursorImage::new(nw, nh, target as u8, hx, hy, pixels)));
    }

    fn integer_scale(&self) -> u8 {
        lock(&self.geometry).map_or(1, |g| g.scale.round().clamp(1.0, 255.0) as u8)
    }
}

/// Bilinear resampling of packed 4-channel premultiplied pixels (premultiplied, so no colour bleeds from clear
/// pixels), sampling at pixel centres.
fn resample_bilinear(src: &[u8], w: usize, h: usize, nw: usize, nh: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(nw * nh * 4);
    let (sx, sy) = (w as f64 / nw as f64, h as f64 / nh as f64);
    for y in 0..nh {
        let fy = ((y as f64 + 0.5) * sy - 0.5).clamp(0.0, (h - 1) as f64);
        let (y0, ty) = (fy.floor() as usize, fy - fy.floor());
        let y1 = (y0 + 1).min(h - 1);
        for x in 0..nw {
            let fx = ((x as f64 + 0.5) * sx - 0.5).clamp(0.0, (w - 1) as f64);
            let (x0, tx) = (fx.floor() as usize, fx - fx.floor());
            let x1 = (x0 + 1).min(w - 1);
            for c in 0..4 {
                let p = |xx: usize, yy: usize| f64::from(src[(yy * w + xx) * 4 + c]);
                let top = p(x0, y0) * (1.0 - tx) + p(x1, y0) * tx;
                let bottom = p(x0, y1) * (1.0 - tx) + p(x1, y1) * tx;
                out.push((top * (1.0 - ty) + bottom * ty).round().clamp(0.0, 255.0) as u8);
            }
        }
    }
    out
}

fn same_pixels(format: BitmapFormat, src: &[u8], dst: &[u8]) -> bool {
    match format {
        BitmapFormat::Bgra => src == dst,
        BitmapFormat::Rgba => src
            .as_chunks::<4>()
            .0
            .iter()
            .zip(dst.as_chunks::<4>().0)
            .all(|(s, d)| s[0] == d[2] && s[1] == d[1] && s[2] == d[0] && s[3] == d[3]),
    }
}

/// A stream position in device pixels → global logical pixels: `origin + position ÷ scale`.
pub fn device_to_global(g: StreamGeometry, x: i32, y: i32) -> PointF {
    let s = if g.scale > 0.0 { g.scale } else { 1.0 };
    PointF::new(g.bounds.x + f64::from(x) / s, g.bounds.y + f64::from(y) / s)
}

/// The cursor image source: lain's stream's cursor (Swift: `CursorImageSource`).
#[derive(Debug, Clone)]
pub struct GnomeCursor {
    state: Arc<CursorState>,
}

impl GnomeCursor {
    pub fn new(state: Arc<CursorState>) -> Self {
        Self { state }
    }
}

impl CursorSource for GnomeCursor {
    fn current(&self) -> Option<Arc<CursorImage>> {
        self.state.image()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn geometry(scale: f64) -> Option<StreamGeometry> {
        Some(StreamGeometry { bounds: RectF::new(3840.0, 0.0, 1376.0, 1032.0), scale })
    }

    /// The owner's fractional scale (1.5): Mutter's 36-pixel bitmap is resampled to 2×, 48 pixels, so the
    /// client still draws it 24 points wide; the hotspot keeps its place in points; a resend is no new image.
    #[test]
    fn a_fractional_scale_resamples_the_bitmap_to_the_next_integer() {
        let c = CursorState::new();
        c.set_geometry(geometry(1.5));
        c.set_position(10, 10);
        let mut data = vec![0u8; 36 * 36 * 4];
        for px in data.as_chunks_mut::<4>().0.iter_mut().take(36 * 18) {
            px.copy_from_slice(&[255, 0, 0, 255]); // opaque red, RGBA, in the top half
        }
        c.set_bitmap(BitmapFormat::Rgba, 36, 36, 36 * 4, (6, 3), &data);
        let img = c.image().unwrap();
        assert_eq!((img.pixel_width, img.pixel_height, img.scale), (48, 48, 2));
        assert_eq!((img.hotspot_x, img.hotspot_y), (4.0, 2.0));
        assert_eq!(&img.pixels[..4], &[0, 0, 255, 255], "swapped to BGRA");
        let last = img.pixels.len() - 4;
        assert_eq!(&img.pixels[last..], &[0, 0, 0, 0], "clear stays clear");
        assert!(
            img.pixels.as_chunks::<4>().0.iter().all(|p| p[0] <= p[3] && p[1] <= p[3] && p[2] <= p[3]),
            "premultiplied"
        );
        c.set_bitmap(BitmapFormat::Rgba, 36, 36, 36 * 4, (6, 3), &data);
        assert!(Arc::ptr_eq(&img, &c.image().unwrap()), "a resend is the same image");
        // An integer scale passes through as before.
        c.set_geometry(geometry(2.0));
        c.set_bitmap(BitmapFormat::Rgba, 36, 36, 36 * 4, (6, 3), &data);
        let img = c.image().unwrap();
        assert_eq!((img.pixel_width, img.scale, img.hotspot_x), (36, 2, 3.0));
    }

    #[test]
    fn location_is_global_logical_and_only_on_lains_display() {
        let c = CursorState::new();
        c.set_geometry(geometry(2.0));
        assert_eq!(c.location(), None);
        c.set_position(1376, 1032);
        assert_eq!(c.location(), Some(PointF::new(3840.0 + 688.0, 516.0)));
        c.set_position(2751, 2063);
        assert_eq!(c.location(), Some(PointF::new(3840.0 + 1375.5, 1031.5)));
        // Just outside the stream (the sprite overlapping it): ignored.
        c.set_position(2752, 10);
        assert_eq!(c.location(), None);
        c.set_position(-3, 10);
        assert_eq!(c.location(), None);
        c.set_position(0, 0);
        assert_eq!(c.location(), Some(PointF::new(3840.0, 0.0)));
        c.set_invalid();
        assert_eq!(c.location(), None);
        // At scale 1 a device pixel is a logical one.
        c.set_geometry(Some(StreamGeometry { bounds: RectF::new(3840.0, 0.0, 2752.0, 2064.0), scale: 1.0 }));
        c.set_position(100, 200);
        assert_eq!(c.location(), Some(PointF::new(3940.0, 200.0)));
        c.set_geometry(None);
        assert_eq!(c.location(), None);
    }

    #[test]
    fn negative_positions_survive_packing() {
        assert_eq!(unpack(pack(-5, 7)), Some((-5, 7)));
        assert_eq!(unpack(pack(-1, -1)), Some((-1, -1)));
        assert_eq!(unpack(INVALID), None);
        let c = CursorState::new();
        c.set_position(i32::MIN, i32::MIN);
        assert_eq!(unpack(c.position.load(Ordering::Relaxed)), Some((i32::MIN + 1, i32::MIN + 1)));
    }

    #[test]
    fn bitmap_is_swapped_to_bgra_and_reused_while_unchanged() {
        let c = CursorState::new();
        c.set_geometry(geometry(2.0));
        // 2×1 premultiplied RGBA, stride 12 (padding after each row).
        let data = [10, 20, 30, 40, 1, 2, 3, 4, 0xEE, 0xEE, 0xEE, 0xEE];
        c.set_bitmap(BitmapFormat::Rgba, 2, 1, 12, (8, 6), &data);
        assert!(c.image().is_none(), "no image while the position is invalid");
        c.set_position(10, 10);
        let a = c.image().unwrap();
        assert_eq!(*a, CursorImage::new(2, 1, 2, 4.0, 3.0, vec![30, 20, 10, 40, 3, 2, 1, 4]));
        // The same sprite again: the same Arc.
        c.set_bitmap(BitmapFormat::Rgba, 2, 1, 12, (8, 6), &data);
        assert!(Arc::ptr_eq(&a, &c.image().unwrap()));
        // A changed pixel or hotspot: a new image.
        c.set_bitmap(BitmapFormat::Rgba, 2, 1, 8, (8, 6), &[10, 20, 30, 40, 1, 2, 3, 5]);
        let b = c.image().unwrap();
        assert!(!Arc::ptr_eq(&a, &b));
        assert_eq!(b.pixels, vec![30, 20, 10, 40, 3, 2, 1, 5]);
        c.set_bitmap(BitmapFormat::Bgra, 2, 1, 8, (2, 2), &[30, 20, 10, 40, 3, 2, 1, 5]);
        let d = c.image().unwrap();
        assert_eq!(d.pixels, b.pixels);
        assert_eq!((d.hotspot_x, d.hotspot_y), (1.0, 1.0));
        // An empty sprite hides it; short data is ignored.
        c.set_bitmap(BitmapFormat::Rgba, 2, 1, 8, (0, 0), &[0; 4]);
        assert_eq!(c.image().unwrap(), d);
        c.set_bitmap(BitmapFormat::Rgba, 0, 0, 0, (0, 0), &[]);
        assert!(c.image().is_none());
        // GnomeCursor reads the same state.
        c.set_bitmap(BitmapFormat::Bgra, 1, 1, 4, (0, 0), &[1, 2, 3, 4]);
        let cursor = GnomeCursor::new(c.clone());
        assert!(Arc::ptr_eq(&cursor.current().unwrap(), &c.image().unwrap()));
        c.reset();
        assert!(cursor.current().is_none());
    }

    #[test]
    fn scale_one_bitmaps() {
        let c = CursorState::new();
        c.set_position(0, 0);
        c.set_bitmap(BitmapFormat::Rgba, 1, 1, 4, (4, 4), &[1, 2, 3, 4]);
        let img = c.image().unwrap();
        assert_eq!((img.scale, img.hotspot_x), (1, 4.0));
    }
}
