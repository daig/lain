import LainHostCore
import LainProtocol
import Testing

@Suite struct TextInputTests {
    @Test func theRouterHandsTextToTheSinkWithItsModifiers() {
        let sink = RecordingSink()
        var router = HostInputRouter(sink: sink)
        #expect(router.handle(.textInput(TextInput(text: "héllo\n"))) == .injected(pointer: nil))
        #expect(router.handle(.textInput(TextInput(text: "c", modifiers: [.control]))) == .injected(pointer: nil))
        #expect(sink.inputCalls == [.text("héllo\n", []), .text("c", [.control])])
    }

    /// The layout's keys, for chords: every letter and digit is typed by some key, shifted or not.
    @Test @MainActor func theCurrentLayoutHasAKeyForEveryLetterAndDigit() {
        let keys = InputInjector.currentLayoutKeys()
        guard !keys.isEmpty else { return }   // no keyboard layout in this environment
        for c in "abcdefghijklmnopqrstuvwxyz0123456789" { #expect(keys[c] != nil, "\(c)") }
        #expect(keys["a"]?.shift == false && keys["A"]?.shift == true)
    }
}
