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
    var onSettings: () -> Void = {}
    private var micButton: UIButton?
    private var hideButton: UIButton?

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
        let settings = button("") { [weak self] in self?.onSettings() }
        settings.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settings.accessibilityLabel = "Settings"
        stack.addArrangedSubview(settings)
        let hide = button("") { [weak self] in self?.onHide() }
        hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hide.accessibilityLabel = "Hide keyboard"
        hideButton = hide
        stack.addArrangedSubview(hide)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The lit modifiers, which go out: they apply to one key.
    func takeModifiers() -> ModifierFlags {
        defer { lit = []; render() }
        return lit
    }

    /// Whether the keyboard can be put away (not in portrait, where it is always up).
    func setCanHide(_ canHide: Bool) { hideButton?.isHidden = !canHide }

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

/// A trackpad area: in portrait, the space between the stream and the keyboard; in landscape, a small patch in
/// each bottom corner, under the thumbs. A finger that starts on it moves the host's pointer as on a trackpad
/// (drag to move, tap to click, hold then move to drag, two fingers to scroll or right-click) and keeps doing
/// so wherever it goes; the rest of the stream stays direct. It only forwards its touches.
final class TrackpadStrip: UIView {
    var onBegan: (Int, CGPoint) -> Void = { _, _ in }
    var onMoved: (Int, CGPoint) -> Void = { _, _ in }
    var onEnded: (Int) -> Void = { _ in }
    var onCancelled: () -> Void = {}

    /// `corner`: a patch over the stream at a side edge, drawn very faintly and rounded on those corners (the
    /// ones pointing into the screen); nil: the portrait strip.
    init(corner: CACornerMask? = nil) {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(white: 1, alpha: corner == nil ? 0.07 : 0.05)
        layer.cornerRadius = corner == nil ? 14 : 28
        if let corner { layer.maskedCorners = corner }
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 1, alpha: corner == nil ? 0.14 : 0.09).cgColor
        accessibilityLabel = "Trackpad"
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func id(_ touch: UITouch) -> Int { ObjectIdentifier(touch).hashValue }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .direct { onBegan(Self.id(touch), touch.location(in: self)) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .direct { onMoved(Self.id(touch), touch.location(in: self)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .direct { onEnded(Self.id(touch)) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .direct }) { onCancelled() }
    }
}

/// The keys the row above the keyboard has no room for, in the band above the trackpad strip: forward delete,
/// Home, End, Page Up and Down, and Paste (the iPad's clipboard, typed on the host).
final class ExtraKeys: UIStackView {
    var onKey: (PhysicalKey) -> Void = { _ in }

    /// `pasteTarget`: what the system's paste button pastes into (it reads the clipboard without asking).
    init(pasteTarget: UIPasteConfigurationSupporting) {
        super.init(frame: .zero)
        axis = .horizontal
        distribution = .fillEqually
        spacing = 6
        // HID keyboard-page usages.
        for (title, usage) in [("⌦", UInt16(0x4C)), ("home", 0x4A), ("end", 0x4D), ("pg↑", 0x4B), ("pg↓", 0x4E)] {
            let b = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in self?.onKey(.key(usage)) })
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            b.tintColor = .white
            b.backgroundColor = UIColor(white: 1, alpha: 0.16)
            b.layer.cornerRadius = 7
            addArrangedSubview(b)
        }
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        config.cornerStyle = .fixed
        config.cornerRadius = 7
        config.baseBackgroundColor = UIColor(white: 0.26, alpha: 1)
        config.baseForegroundColor = .white
        let paste = UIPasteControl(configuration: config)
        paste.target = pasteTarget
        addArrangedSubview(paste)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
