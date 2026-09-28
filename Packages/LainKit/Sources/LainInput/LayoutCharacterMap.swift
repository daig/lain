/// What character each physical key types in the iPad's current layout, ignoring modifiers (D18).
///
/// GCKeyboard (the primary key source) reports only positions; UIKit's `charactersIgnoringModifiers`
/// arrives ~1.5 ms later with the layout's character. The capture layer teaches this map from UIKit
/// presses, and lain's own shortcuts and remaps match against it. Until a key has been seen, the US
/// QWERTY character for that position is assumed.
public struct LayoutCharacterMap: Sendable {
    private var learned: [PhysicalKey: String] = [:]

    public init() {}

    /// Records the layout's base character for a key (lowercased). Empty strings are ignored.
    public mutating func learn(_ key: PhysicalKey, character: String) {
        guard !character.isEmpty else { return }
        learned[key] = character.lowercased()
    }

    public func character(for key: PhysicalKey) -> String? {
        learned[key] ?? Self.qwerty[key]
    }

    public mutating func reset() { learned.removeAll() }

    static let qwerty: [PhysicalKey: String] = {
        var m: [PhysicalKey: String] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { m[.key(0x04 + UInt16(i))] = String(c) }
        for (i, c) in "1234567890".enumerated() { m[.key(0x1E + UInt16(i))] = String(c) }
        let punctuation: [(UInt16, String)] = [
            (0x28, "\r"), (0x29, "\u{1B}"), (0x2B, "\t"), (0x2C, " "), (0x2D, "-"), (0x2E, "="), (0x2F, "["),
            (0x30, "]"), (0x31, "\\"), (0x33, ";"), (0x34, "'"), (0x35, "`"), (0x36, ","), (0x37, "."), (0x38, "/"),
        ]
        for (u, c) in punctuation { m[.key(u)] = c }
        return m
    }()
}
