//! Positions and rectangles in global logical pixels (top-left origin).

/// A position in global logical pixels.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct PointF {
    pub x: f64,
    pub y: f64,
}

impl PointF {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    pub fn distance(self, other: PointF) -> f64 {
        (self.x - other.x).hypot(self.y - other.y)
    }
}

/// A rectangle in global logical pixels: origin at the top-left corner.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct RectF {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl RectF {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    pub fn origin(&self) -> PointF {
        PointF::new(self.x, self.y)
    }

    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    /// Half-open: the right and bottom edges belong to the next rectangle.
    pub fn contains(&self, p: PointF) -> bool {
        p.x >= self.x && p.x < self.max_x() && p.y >= self.y && p.y < self.max_y()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contains_is_half_open() {
        let r = RectF::new(0.0, 0.0, 10.0, 5.0);
        assert!(r.contains(PointF::new(0.0, 0.0)));
        assert!(r.contains(PointF::new(9.99, 4.99)));
        assert!(!r.contains(PointF::new(10.0, 1.0)));
        assert!(!r.contains(PointF::new(1.0, 5.0)));
        assert!(!r.contains(PointF::new(-0.01, 1.0)));
    }

    #[test]
    fn distance() {
        assert_eq!(PointF::new(0.0, 0.0).distance(PointF::new(3.0, 4.0)), 5.0);
    }
}
