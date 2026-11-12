import LainInput
import LainProtocol
import UIKit

/// Takes the system keyboard's typing for the host while there is no Magic Keyboard: an invisible view that is
/// first responder while the keyboard shows. What is typed (or dictated with the keyboard's microphone key)
/// goes to the host as text; `KeyRow`, above the keyboard, adds the keys the system keyboard lacks.
/// Everything that would change the text is off: what reaches the host is what was typed.
final class KeyCaptureView: UIView, UIKeyInput {
    var onText: (String) -> Void = { _ in }
    var onBackspace: () -> Void = {}
    let keyRow = KeyRow()

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { keyRow }

    // UIKeyInput
    var hasText: Bool { true }   // so the delete key is always live
    func insertText(_ text: String) { onText(text) }
    func deleteBackward() { onBackspace() }

    // UITextInputTraits
    var autocorrectionType = UITextAutocorrectionType.no
    var autocapitalizationType = UITextAutocapitalizationType.none
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var inlinePredictionType = UITextInlinePredictionType.no
    var keyboardAppearance = UIKeyboardAppearance.dark
}

/// The row above the system keyboard: Esc, Tab, the arrows, and Control, Option and Command, which stay
/// lit until the next key and then apply to it (Control, then C: Control-C).
final class KeyRow: UIInputView {
    /// A key that isn't a character: pressed with the lit modifiers, which it clears.
    var onKey: (PhysicalKey) -> Void = { _ in }
    var onHide: () -> Void = {}
    var onDictate: () -> Void = {}
    private var micButton: UIButton?

    private var lit: ModifierFlags = []
    private var modifierButtons: [(ModifierFlags, UIButton)] = []

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            heightAnchor.constraint(equalToConstant: 48),
        ])
        let keys: [(String, PhysicalKey)] = [("esc", .escape), ("tab", .tab)]
        for (title, key) in keys { stack.addArrangedSubview(button(title) { [weak self] in self?.onKey(key) }) }
        for (title, flag) in [("⌃", ModifierFlags.control), ("⌥", .option), ("⌘", .command)] {
            let b = button(title) { [weak self] in self?.toggle(flag) }
            modifierButtons.append((flag, b))
            stack.addArrangedSubview(b)
        }
        // HID keyboard-page usages: right, left, down, up arrows.
        for (title, usage) in [("←", UInt16(0x50)), ("↓", 0x51), ("↑", 0x52), ("→", 0x4F)] {
            stack.addArrangedSubview(button(title) { [weak self] in self?.onKey(.key(usage)) })
        }
        let mic = button("") { [weak self] in self?.onDictate() }
        mic.setImage(UIImage(systemName: "mic"), for: .normal)
        mic.accessibilityLabel = "Dictate"
        micButton = mic
        stack.addArrangedSubview(mic)
        let hide = button("") { [weak self] in self?.onHide() }
        hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hide.accessibilityLabel = "Hide keyboard"
        stack.addArrangedSubview(hide)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The lit modifiers, which go out: they apply to one key.
    func takeModifiers() -> ModifierFlags {
        defer { lit = []; render() }
        return lit
    }

    /// Lights the microphone key while dictation is on.
    func setDictating(_ on: Bool) {
        micButton?.backgroundColor = on ? .systemRed : UIColor(white: 1, alpha: 0.16)
        micButton?.setImage(UIImage(systemName: on ? "mic.fill" : "mic"), for: .normal)
    }

    private func toggle(_ flag: ModifierFlags) {
        lit.formSymmetricDifference(flag)
        render()
    }

    private func render() {
        for (flag, b) in modifierButtons {
            b.backgroundColor = lit.contains(flag) ? .systemBlue : UIColor(white: 1, alpha: 0.16)
        }
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        b.tintColor = .white
        b.backgroundColor = UIColor(white: 1, alpha: 0.16)
        b.layer.cornerRadius = 7
        return b
    }
}
