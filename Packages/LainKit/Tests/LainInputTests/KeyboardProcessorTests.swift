import LainProtocol
import Testing
@testable import LainInput

/// Compact form of output events: "+E3" = down, "-E3" = up, with the Mac's modifiers after the event.
private func fmt(_ events: [KeyEvent]) -> [String] {
    events.map { e in
        var mods = ""
        if e.modifiers.contains(.control) { mods += "⌃" }
        if e.modifiers.contains(.option) { mods += "⌥" }
        if e.modifiers.contains(.shift) { mods += "⇧" }
        if e.modifiers.contains(.command) { mods += "⌘" }
        let page = e.usagePage == PhysicalKey.keyboardPage ? "" : "\(String(e.usagePage, radix: 16)):"
        return (e.isDown ? "+" : "-") + page + String(e.usage, radix: 16, uppercase: true) + (mods.isEmpty ? "" : " " + mods)
    }
}

private let keyH = PhysicalKey.key(0x0B), keyQ = PhysicalKey.key(0x14), keyC = PhysicalKey.key(0x06)
private let keyU = PhysicalKey.key(0x18), keyL = PhysicalKey.key(0x0F), key3 = PhysicalKey.key(0x20)
private let grave = PhysicalKey.key(0x35)

@Suite struct Passthrough {
    @Test func plainTypingIsForwardedWithModifiers() {
        var k = KeyboardProcessor()
        #expect(fmt(k.process(.leftCommand, isDown: true)) == ["+E3 ⌘"])
        #expect(fmt(k.process(keyC, isDown: true)) == ["+6 ⌘"])
        #expect(fmt(k.process(keyC, isDown: false)) == ["-6 ⌘"])
        #expect(fmt(k.process(.leftCommand, isDown: false)) == ["-E3"])
    }

    @Test func orphanKeyUpsAndDuplicateDownsAreDropped() {
        var k = KeyboardProcessor()
        // After returning from the background, GCKeyboard delivers Cmd-up with no down (§13).
        #expect(k.process(.leftCommand, isDown: false).isEmpty)
        #expect(k.process(keyC, isDown: false).isEmpty)
        #expect(k.process(keyC, isDown: true).count == 1)
        #expect(k.process(keyC, isDown: true).isEmpty)
    }

    @Test func ctrlClickStyleModifiersPassRaw() {
        var k = KeyboardProcessor()
        #expect(fmt(k.process(.leftControl, isDown: true)) == ["+E0 ⌃"])
        #expect(fmt(k.process(.rightOption, isDown: true)) == ["+E6 ⌃⌥"])
        #expect(k.physicalModifiers == [.control, .option])
    }

    @Test func capsLockToggles() {
        var k = KeyboardProcessor()
        _ = k.process(.capsLock, isDown: true)
        _ = k.process(.capsLock, isDown: false)
        #expect(k.macModifiers == .capsLock)
        _ = k.process(.capsLock, isDown: true)
        #expect(k.macModifiers == [])
    }
}

@Suite struct Remaps {
    @Test func optTabHoldsCmdWhileOptIsDown() {
        var k = KeyboardProcessor()
        #expect(fmt(k.process(.leftOption, isDown: true)) == ["+E2 ⌥"])
        // Opt-Tab: the Mac sees Opt released, Cmd pressed, then Tab with Cmd.
        #expect(fmt(k.process(.tab, isDown: true)) == ["-E2", "+E3 ⌘", "+2B ⌘"])
        #expect(fmt(k.process(.tab, isDown: false)) == ["-2B ⌘"])
        // Tab again while Opt is still held cycles the switcher.
        #expect(fmt(k.process(.tab, isDown: true)) == ["+2B ⌘"])
        #expect(fmt(k.process(.tab, isDown: false)) == ["-2B ⌘"])
        // Shift joins: Cmd-Shift-Tab goes backwards.
        #expect(fmt(k.process(.leftShift, isDown: true)) == ["+E1 ⇧⌘"])
        #expect(fmt(k.process(.tab, isDown: true)) == ["+2B ⇧⌘"])
        #expect(fmt(k.process(.tab, isDown: false)) == ["-2B ⇧⌘"])
        #expect(fmt(k.process(.leftShift, isDown: false)) == ["-E1 ⌘"])
        // Releasing Opt releases Cmd: the switcher commits.
        #expect(fmt(k.process(.leftOption, isDown: false)) == ["-E3"])
        #expect(k.macHeldKeys.isEmpty)
        #expect(!k.isHoldingRemap)
    }

    @Test func optShiftTabStartsReversed() {
        var k = KeyboardProcessor()
        _ = k.process(.leftShift, isDown: true)
        _ = k.process(.leftOption, isDown: true)
        #expect(fmt(k.process(.tab, isDown: true)) == ["-E2 ⇧", "+E3 ⇧⌘", "+2B ⇧⌘"])
    }

    @Test(arguments: [(PhysicalKey.space, "2C"), (keyH, "B"), (keyQ, "14"), (grave, "35")])
    func defaultSingleKeyRemaps(key: PhysicalKey, hex: String) {
        var k = KeyboardProcessor()
        _ = k.process(.rightOption, isDown: true)
        #expect(fmt(k.process(key, isDown: true)) == ["-E6", "+E3 ⌘", "+\(hex) ⌘"])
        _ = k.process(key, isDown: false)
        #expect(fmt(k.process(.rightOption, isDown: false)) == ["-E3"])
    }

    @Test func screenshotRemapsAreOffByDefault() {
        var k = KeyboardProcessor()
        _ = k.process(.leftOption, isDown: true)
        _ = k.process(.leftShift, isDown: true)
        #expect(fmt(k.process(key3, isDown: true)) == ["+20 ⌥⇧"])
        var enabled = RemapTable.default
        for i in enabled.entries.indices { enabled.entries[i].isEnabled = true }
        var k2 = KeyboardProcessor(table: enabled)
        _ = k2.process(.leftOption, isDown: true)
        _ = k2.process(.leftShift, isDown: true)
        #expect(fmt(k2.process(key3, isDown: true)) == ["-E2 ⇧", "+E3 ⇧⌘", "+20 ⇧⌘"])
    }

    @Test func extraModifiersPreventAMatch() {
        var k = KeyboardProcessor()
        _ = k.process(.leftControl, isDown: true)
        _ = k.process(.leftOption, isDown: true)
        #expect(fmt(k.process(.tab, isDown: true)) == ["+2B ⌃⌥"])   // Ctrl-Opt-Tab is not a remap
    }

    @Test func secondOptionKeyDuringHoldStaysHidden() {
        var k = KeyboardProcessor()
        _ = k.process(.leftOption, isDown: true)
        _ = k.process(.tab, isDown: true)
        #expect(k.process(.rightOption, isDown: true).isEmpty)
        #expect(k.process(.leftOption, isDown: false).isEmpty)          // right Opt still holds Cmd
        _ = k.process(.tab, isDown: false)
        #expect(fmt(k.process(.rightOption, isDown: false)) == ["-E3"])
    }
}

@Suite struct ColemakMatching {
    /// The owner's layout: Colemak on QWERTY-labelled keys (§13 InputLab second run).
    static func colemak() -> LayoutCharacterMap {
        var m = LayoutCharacterMap()
        m.learn(keyU, character: "l")   // key labelled U types l
        m.learn(keyL, character: "i")   // key labelled L types i
        m.learn(keyH, character: "h")   // H and Q stay put in Colemak
        m.learn(keyQ, character: "Q")   // stored lowercased
        return m
    }

    @Test func remapsMatchTheTypedCharacterNotThePosition() {
        let table = RemapTable(entries: [RemapEntry(name: "Location bar", character: "l", modifiers: .option)])
        var k = KeyboardProcessor(table: table, layout: Self.colemak())
        _ = k.process(.leftOption, isDown: true)
        // The key labelled L types "i" in Colemak: no match, forwarded as Opt-(physical L).
        #expect(fmt(k.process(keyL, isDown: true)) == ["+F ⌥"])
        _ = k.process(keyL, isDown: false)
        // The key labelled U types "l": match. The output keeps the physical U key; the Mac, also set to
        // Colemak, turns it into Cmd-L.
        #expect(fmt(k.process(keyU, isDown: true)) == ["-E2", "+E3 ⌘", "+18 ⌘"])
    }

    @Test func defaultsStillWorkUnderColemak() {
        var k = KeyboardProcessor(layout: Self.colemak())
        _ = k.process(.leftOption, isDown: true)
        #expect(fmt(k.process(keyQ, isDown: true)) == ["-E2", "+E3 ⌘", "+14 ⌘"])
    }

    @Test func unlearnedKeysFallBackToQWERTY() {
        let m = LayoutCharacterMap()
        #expect(m.character(for: keyU) == "u")
        #expect(m.character(for: .tab) == "\t")
        #expect(m.character(for: .space) == " ")
        #expect(m.character(for: .globe) == nil)
    }
}

@Suite struct ReleaseAllBehavior {
    @Test func releasesKeysThenModifiers() {
        var k = KeyboardProcessor()
        _ = k.process(.leftShift, isDown: true)
        _ = k.process(.leftCommand, isDown: true)
        _ = k.process(keyC, isDown: true)
        _ = k.process(keyH, isDown: true)
        #expect(fmt(k.releaseAll()) == ["-B ⇧⌘", "-6 ⇧⌘", "-E3 ⇧", "-E1"])
        #expect(k.macHeldKeys.isEmpty)
        #expect(k.releaseAll().isEmpty)
    }

    @Test func releaseDuringHoldReleasesSynthesizedCmd() {
        var k = KeyboardProcessor()
        _ = k.process(.leftOption, isDown: true)
        _ = k.process(.tab, isDown: true)          // Cmd-Tab held, app switcher open
        #expect(fmt(k.releaseAll()) == ["-2B ⌘", "-E3"])
        #expect(!k.isHoldingRemap)
    }

    @Test func keyUpsAfterReleaseAllAreOrphans() {
        var k = KeyboardProcessor()
        _ = k.process(.leftCommand, isDown: true)
        _ = k.process(.tab, isDown: true)
        _ = k.releaseAll()                         // scene resigned active
        #expect(k.process(.tab, isDown: false).isEmpty)
        #expect(k.process(.leftCommand, isDown: false).isEmpty)
        #expect(fmt(k.process(keyC, isDown: true)) == ["+6"])
    }
}
