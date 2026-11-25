import Foundation

/// Pure display-sizing calculation for the macOS client: turns an `NSWindow`'s content size and
/// `backingScaleFactor` into the pixel dimensions and scale requested in `Hello`.
///
/// Both Mac hosts (`VirtualDisplay.Spec`, capped at 3840 px backing) and Linux hosts (`480...4096`, even
/// sides) fall back to the iPad's 2752×2064 when a dimension is outside their range. Capping the long
/// side at 3840 px (preserving aspect ratio) and clamping the short side to at least 480 px keeps 5K/6K
/// Retina displays and small windows working cleanly on every host.
public enum MacDisplaySizing {
    public static let maxLongSide = 3840
    public static let minSide = 480

    public struct Spec: Sendable, Equatable {
        public var pixelWidth: UInt32
        public var pixelHeight: UInt32
        /// Whole screen scale for `Hello.scale` (1 or 2).
        public var scale: UInt8
        /// Recommended `Hello.desiredScale` in hundredths (e.g. 200 for 2×, 100 for 1×, 150 for capped 5K).
        public var defaultDesiredScale: UInt16
        /// Streamed display point width at `defaultDesiredScale`, for input reference scaling.
        public var referenceWidth: Double

        public init(pixelWidth: UInt32, pixelHeight: UInt32, scale: UInt8, defaultDesiredScale: UInt16,
                    referenceWidth: Double) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.scale = scale
            self.defaultDesiredScale = defaultDesiredScale
            self.referenceWidth = referenceWidth
        }
    }

    /// Computes the requested host display spec for a window content area of `pointWidth`×`pointHeight` pt
    /// on a display with `backingScale` pixels per point.
    public static func desired(pointWidth: Double, pointHeight: Double, backingScale: Double,
                               maxLongSide: Int = Self.maxLongSide, minSide: Int = Self.minSide) -> Spec {
        let safeScale = backingScale.isFinite && backingScale > 0 ? backingScale : 2.0
        guard pointWidth.isFinite, pointHeight.isFinite, pointWidth > 0, pointHeight > 0 else {
            return Spec(pixelWidth: 2560, pixelHeight: 1600, scale: 2, defaultDesiredScale: 200, referenceWidth: 1280)
        }

        let rawW = pointWidth * safeScale
        let rawH = pointHeight * safeScale
        let maxSide = max(rawW, rawH)
        let capRatio = maxSide > Double(maxLongSide) ? Double(maxLongSide) / maxSide : 1.0

        var w = Int((rawW * capRatio).rounded())
        var h = Int((rawH * capRatio).rounded())
        w = max(minSide, min(maxLongSide, w))
        h = max(minSide, min(maxLongSide, h))
        // Even dimensions for 4:2:0 HEVC and Mutter/VirtualDisplay alignment.
        w = max(minSide, w & ~1)
        h = max(minSide, h & ~1)

        let effectiveScale = safeScale * capRatio
        // Round to nearest 0.25 (25 hundredths), clamped to [100, 300] matching host offered scales.
        let quarterSteps = Int((effectiveScale * 4).rounded())
        let desiredScale = UInt16(max(100, min(300, quarterSteps * 25)))
        let reportedScale = UInt8(max(1, min(3, Int(safeScale.rounded()))))
        let refWidth = Double(w) / (Double(desiredScale) / 100.0)

        return Spec(pixelWidth: UInt32(w), pixelHeight: UInt32(h), scale: reportedScale,
                    defaultDesiredScale: desiredScale, referenceWidth: refWidth)
    }

    /// True if `new` differs enough from `old` to warrant reconnecting the host virtual display.
    public static func needsUpdate(from old: Spec, to new: Spec, pixelTolerance: Int = 8) -> Bool {
        abs(Int(old.pixelWidth) - Int(new.pixelWidth)) > pixelTolerance
            || abs(Int(old.pixelHeight) - Int(new.pixelHeight)) > pixelTolerance
            || old.defaultDesiredScale != new.defaultDesiredScale
    }
}
