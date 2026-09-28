import LainProtocol

/// One lain remap (§6.4, D18): when a key whose layout character is `character` is pressed with
/// exactly `modifiers` held, the Mac sees `from` replaced by `to` for as long as the `from` keys stay
/// down. Only modifiers change; the physical key is kept, so the output doesn't depend on the layout.
public struct RemapEntry: Sendable, Equatable, Hashable {
    public var name: String
    /// The iPad layout's base character, lowercased ("\t" for Tab, " " for Space).
    public var character: String
    /// Exact set of held modifiers (shift, control, option, command) required.
    public var modifiers: ModifierFlags
    public var from: ModifierFlags
    public var to: ModifierFlags
    public var isEnabled: Bool

    public init(name: String, character: String, modifiers: ModifierFlags, from: ModifierFlags = .option,
                to: ModifierFlags = .command, isEnabled: Bool = true) {
        self.name = name
        self.character = character.lowercased()
        self.modifiers = modifiers
        self.from = from
        self.to = to
        self.isEnabled = isEnabled
    }
}

public struct RemapTable: Sendable, Equatable {
    public var entries: [RemapEntry]

    public init(entries: [RemapEntry]) { self.entries = entries }

    /// Modifiers that take part in matching.
    public static let matchedModifiers: ModifierFlags = [.shift, .control, .option, .command]

    public func match(character: String?, modifiers: ModifierFlags) -> RemapEntry? {
        guard let character = character?.lowercased() else { return nil }
        let held = modifiers.intersection(Self.matchedModifiers)
        return entries.first { $0.isEnabled && $0.character == character && $0.modifiers == held }
    }

    /// Defaults from S5: the Cmd combos iPadOS never delivers, reached with Opt instead.
    public static let `default` = RemapTable(entries: [
        RemapEntry(name: "App switcher", character: "\t", modifiers: .option),
        RemapEntry(name: "App switcher (reverse)", character: "\t", modifiers: [.option, .shift]),
        RemapEntry(name: "Spotlight", character: " ", modifiers: .option),
        RemapEntry(name: "Hide", character: "h", modifiers: .option),
        RemapEntry(name: "Quit", character: "q", modifiers: .option),
        RemapEntry(name: "Next window", character: "`", modifiers: .option),
        // Cmd-Shift-5 is delivered and covers screenshots; these are available but off.
        RemapEntry(name: "Screenshot", character: "3", modifiers: [.option, .shift], isEnabled: false),
        RemapEntry(name: "Screenshot area", character: "4", modifiers: [.option, .shift], isEnabled: false),
    ])
}
