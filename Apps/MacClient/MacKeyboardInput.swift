import AppKit
import Carbon
import LainInput
import LainProtocol

/// Translates macOS AppKit / CoreGraphics keyboard & modifier events into `lain` physical HID keys.
enum MacKeyboardInput {
    // Device-dependent modifier masks from IOKit/hidsystem/IOLLEvent.h so Left and Right modifiers
    // are tracked independently even when both sides (e.g. Left Option + Right Option) are held at once.
    private static let deviceLeftControl: UInt = 0x0000_0001
    private static let deviceLeftShift: UInt = 0x0000_0002
    private static let deviceRightShift: UInt = 0x0000_0004
    private static let deviceLeftCommand: UInt = 0x0000_0008
    private static let deviceRightCommand: UInt = 0x0000_0010
    private static let deviceLeftOption: UInt = 0x0000_0020
    private static let deviceRightOption: UInt = 0x0000_0040
    private static let deviceRightControl: UInt = 0x0000_2000

    /// Queries the Mac's physical keyboard layout family (ANSI / ISO / JIS) for `Hello.keyboardType`.
    static var hostKeyboardType: KeyboardType {
        switch Int(KBGetLayoutType(Int16(LMGetKbdType()))) {
        case kKeyboardANSI: .ansi
        case kKeyboardISO: .iso
        case kKeyboardJIS: .jis
        default: .unknown
        }
    }

    /// Resolves whether a modifier keyCode is currently pressed given raw modifier flags (works for both
    /// `NSEvent.modifierFlags.rawValue` and `CGEventFlags.rawValue`).
    static func isModifierDown(macKeyCode: UInt16, rawFlags: UInt64) -> Bool? {
        let bits = UInt(truncatingIfNeeded: rawFlags)
        let devMask = bits & 0xFFFF
        switch macKeyCode {
        case 0x3B: // Left Control
            return devMask != 0 ? (devMask & deviceLeftControl) != 0 : (rawFlags & CGEventFlags.maskControl.rawValue) != 0
        case 0x3E: // Right Control
            return devMask != 0 ? (devMask & deviceRightControl) != 0 : (rawFlags & CGEventFlags.maskControl.rawValue) != 0
        case 0x38: // Left Shift
            return devMask != 0 ? (devMask & deviceLeftShift) != 0 : (rawFlags & CGEventFlags.maskShift.rawValue) != 0
        case 0x3C: // Right Shift
            return devMask != 0 ? (devMask & deviceRightShift) != 0 : (rawFlags & CGEventFlags.maskShift.rawValue) != 0
        case 0x3A: // Left Option
            return devMask != 0 ? (devMask & deviceLeftOption) != 0 : (rawFlags & CGEventFlags.maskAlternate.rawValue) != 0
        case 0x3D: // Right Option
            return devMask != 0 ? (devMask & deviceRightOption) != 0 : (rawFlags & CGEventFlags.maskAlternate.rawValue) != 0
        case 0x37: // Left Command
            return devMask != 0 ? (devMask & deviceLeftCommand) != 0 : (rawFlags & CGEventFlags.maskCommand.rawValue) != 0
        case 0x36: // Right Command
            return devMask != 0 ? (devMask & deviceRightCommand) != 0 : (rawFlags & CGEventFlags.maskCommand.rawValue) != 0
        case 0x39: // Caps Lock
            return (rawFlags & CGEventFlags.maskAlphaShift.rawValue) != 0
        case 0x3F: // Fn / Globe
            return (rawFlags & CGEventFlags.maskSecondaryFn.rawValue) != 0
        default:
            return nil
        }
    }

    /// `⌃⌥Esc` releases pointer capture (and temporarily disarms system-shortcut interception).
    static func isReleaseChord(macKeyCode: UInt16, rawFlags: UInt64) -> Bool {
        guard macKeyCode == 0x35 else { return false } // kVK_Escape
        let flags = CGEventFlags(rawValue: rawFlags)
        return flags.contains(.maskControl) && flags.contains(.maskAlternate) && !flags.contains(.maskCommand)
    }

    /// Maps `NSEvent.Phase` to wire `GesturePhase`.
    static func gesturePhase(_ phase: NSEvent.Phase) -> GesturePhase {
        if phase.contains(.mayBegin) { return .mayBegin }
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .none
    }

    /// Maps `NSEvent.Phase` momentum to wire `MomentumPhase`.
    static func momentumPhase(_ phase: NSEvent.Phase) -> MomentumPhase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
        return .none
    }
}
