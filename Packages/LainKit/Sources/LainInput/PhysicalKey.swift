import LainProtocol

/// A physical key position as iPadOS reports it: HID usage page + usage (D18).
public struct PhysicalKey: Hashable, Sendable, CustomStringConvertible {
    public var page: UInt16
    public var usage: UInt16

    public init(page: UInt16 = PhysicalKey.keyboardPage, usage: UInt16) {
        self.page = page
        self.usage = usage
    }

    public static let keyboardPage: UInt16 = 0x07
    public static let consumerPage: UInt16 = 0x0C
    public static let appleVendorTopCasePage: UInt16 = 0xFF

    public static func key(_ usage: UInt16) -> PhysicalKey { PhysicalKey(usage: usage) }

    public static let tab = key(0x2B), space = key(0x2C), escape = key(0x29), `return` = key(0x28)
    public static let capsLock = key(0x39)
    public static let leftControl = key(0xE0), leftShift = key(0xE1), leftOption = key(0xE2), leftCommand = key(0xE3)
    public static let rightControl = key(0xE4), rightShift = key(0xE5), rightOption = key(0xE6), rightCommand = key(0xE7)
    /// Globe/fn: UIKit reports it on the consumer page as "AC Next Keyboard Layout Select" (§6.4).
    public static let globe = PhysicalKey(page: consumerPage, usage: 0x29D)
    /// Apple keyboards' fn on the vendor top-case page.
    public static let appleFn = PhysicalKey(page: appleVendorTopCasePage, usage: 0x03)

    /// The modifier this key controls, if it is a modifier key. Caps Lock is a toggle, not a held modifier.
    public var modifier: ModifierFlags? {
        switch self {
        case .leftControl, .rightControl: .control
        case .leftShift, .rightShift: .shift
        case .leftOption, .rightOption: .option
        case .leftCommand, .rightCommand: .command
        case .globe, .appleFn: .function
        default: nil
        }
    }

    public var isModifier: Bool { modifier != nil }

    /// The key to press on the Mac for a modifier the remap engine synthesizes (left-hand variants).
    public static func keys(for modifiers: ModifierFlags) -> [PhysicalKey] {
        var out: [PhysicalKey] = []
        if modifiers.contains(.control) { out.append(.leftControl) }
        if modifiers.contains(.option) { out.append(.leftOption) }
        if modifiers.contains(.shift) { out.append(.leftShift) }
        if modifiers.contains(.command) { out.append(.leftCommand) }
        if modifiers.contains(.function) { out.append(.globe) }
        return out
    }

    public var description: String { "\(String(page, radix: 16)):\(String(usage, radix: 16))" }
}
