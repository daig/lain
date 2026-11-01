//! The desktop's cursor image (Swift: `CursorImage`, `CursorImageSource`).

use std::hash::{Hash, Hasher};
use std::sync::Arc;

/// One cursor image as it goes on the wire: premultiplied BGRA, rows packed, rendered at `scale`; the
/// hotspot in logical pixels from the top-left.
#[derive(Debug, Clone)]
pub struct CursorImage {
    pub pixel_width: u16,
    pub pixel_height: u16,
    pub scale: u8,
    pub hotspot_x: f32,
    pub hotspot_y: f32,
    pub pixels: Vec<u8>,
}

impl CursorImage {
    /// Panics unless `pixels` holds exactly `pixel_width × pixel_height` BGRA pixels (Swift: a
    /// precondition).
    pub fn new(
        pixel_width: u16,
        pixel_height: u16,
        scale: u8,
        hotspot_x: f32,
        hotspot_y: f32,
        pixels: Vec<u8>,
    ) -> Self {
        assert_eq!(
            pixels.len(),
            usize::from(pixel_width) * usize::from(pixel_height) * 4,
            "cursor pixels must be width × height × 4 bytes"
        );
        Self { pixel_width, pixel_height, scale, hotspot_x, hotspot_y, pixels }
    }
}

// Equality and hashing compare the hotspot by bit pattern, so equal images always hash alike (the
// shape tracker keys its table by image).
impl PartialEq for CursorImage {
    fn eq(&self, other: &Self) -> bool {
        self.pixel_width == other.pixel_width
            && self.pixel_height == other.pixel_height
            && self.scale == other.scale
            && self.hotspot_x.to_bits() == other.hotspot_x.to_bits()
            && self.hotspot_y.to_bits() == other.hotspot_y.to_bits()
            && self.pixels == other.pixels
    }
}

impl Eq for CursorImage {}

impl Hash for CursorImage {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.pixel_width.hash(state);
        self.pixel_height.hash(state);
        self.scale.hash(state);
        self.hotspot_x.to_bits().hash(state);
        self.hotspot_y.to_bits().hash(state);
        self.pixels.hash(state);
    }
}

/// Where the core reads the current cursor image (Swift: `CursorImageSource`).
pub trait CursorSource: Send + Sync + 'static {
    /// The current cursor, or `None` while it is hidden. Polled about 60 times a second: return the
    /// shared image (the same `Arc` while it is unchanged), never render one per call, never block.
    fn current(&self) -> Option<Arc<CursorImage>>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn equal_images_hash_alike() {
        let a = CursorImage::new(1, 1, 2, 0.5, 0.5, vec![1, 2, 3, 4]);
        let b = CursorImage::new(1, 1, 2, 0.5, 0.5, vec![1, 2, 3, 4]);
        let c = CursorImage::new(1, 1, 2, 0.5, 0.75, vec![1, 2, 3, 4]);
        assert_eq!(a, b);
        assert_ne!(a, c);
        let set: HashSet<CursorImage> = [a, b, c].into_iter().collect();
        assert_eq!(set.len(), 2);
    }

    #[test]
    #[should_panic(expected = "width × height × 4")]
    fn pixel_count_is_checked() {
        let _ = CursorImage::new(2, 1, 1, 0.0, 0.0, vec![0; 4]);
    }
}
