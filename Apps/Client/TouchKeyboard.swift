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
    /// The row of keys above the keyboard; off when the keys are beside the stream instead (`SideKeys`).
    var showsKeyRow = true {
        didSet { if showsKeyRow != oldValue, isFirstResponder { reloadInputViews() } }
    }
    override var inputAccessoryView: UIView? { showsKeyRow ? keyRow : nil }

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
            // The row's own edges, not the safe area's: a phone's side strip (the camera's, at the top of the
            // screen) would otherwise take 84 points from a row at the bottom.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
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

/// The row's keys beside the stream: in a short landscape window with the keyboard up (a phone's screens), the
/// picture is narrower than the window, and the keys go in the room at its sides so that the picture gets the
/// row's height. Left: Esc, Tab, the modifiers (lit until the next key, as in the row) and forward delete.
/// Right: the arrows as a cluster, and under them dictation, the settings and hiding the keyboard.
@MainActor
final class SideKeys {
    let left = UIView(), right = UIView()
    var onKey: (PhysicalKey) -> Void = { _ in }
    var onHide: () -> Void = {}
    var onDictate: () -> Void = {}
    var onSettings: () -> Void = {}
    private var micButton: UIButton?
    private var lit: ModifierFlags = []
    private var modifierButtons: [(ModifierFlags, UIButton)] = []

    init() {
        func key(_ title: String, _ key: PhysicalKey) -> UIButton { button(title: title) { [weak self] in self?.onKey(key) } }
        func modifier(_ title: String, _ flag: ModifierFlags) -> UIButton {
            let b = button(title: title) { [weak self] in self?.toggle(flag) }
            modifierButtons.append((flag, b))
            return b
        }
        // HID keyboard-page usages: forward delete 0x4C; arrows right 0x4F, left 0x50, down 0x51, up 0x52.
        fill(left, rows: [[key("esc", .escape), key("tab", .tab)],
                          [modifier("⌃", .control), modifier("⌥", .option)],
                          [modifier("⌘", .command), key("⌦", .key(0x4C))]])
        let mic = button(symbol: "mic", label: "Dictate") { [weak self] in self?.onDictate() }
        micButton = mic
        let blank = { () -> UIView in UIView() }
        // The arrows are used least, so they are furthest from the thumb: dictation, the settings and hiding the
        // keyboard are the bottom row.
        fill(right, rows: [[blank(), key("↑", .key(0x52)), blank()],
                           [key("←", .key(0x50)), key("↓", .key(0x51)), key("→", .key(0x4F))],
                           [mic, button(symbol: "slider.horizontal.3", label: "Settings") { [weak self] in self?.onSettings() },
                            button(symbol: "keyboard.chevron.compact.down", label: "Hide keyboard") { [weak self] in self?.onHide() }]])
        left.isHidden = true
        right.isHidden = true
    }

    /// The lit modifiers, which go out: they apply to one key.
    func takeModifiers() -> ModifierFlags {
        defer { lit = []; render() }
        return lit
    }

    func setDictating(_ on: Bool) {
        micButton?.backgroundColor = on ? .systemRed : UIColor(white: 1, alpha: 0.16)
        micButton?.setImage(UIImage(systemName: on ? "mic.fill" : "mic"), for: .normal)
    }

    private func toggle(_ flag: ModifierFlags) {
        lit.formSymmetricDifference(flag)
        render()
    }

    private func render() {
        for (flag, b) in modifierButtons { b.backgroundColor = lit.contains(flag) ? .systemBlue : UIColor(white: 1, alpha: 0.16) }
    }

    private func fill(_ view: UIView, rows: [[UIView]]) {
        let grid = UIStackView(arrangedSubviews: rows.map { row in
            let line = UIStackView(arrangedSubviews: row)
            line.axis = .horizontal
            line.distribution = .fillEqually
            line.spacing = 6
            return line
        })
        grid.axis = .vertical
        grid.distribution = .fillEqually
        grid.spacing = 6
        grid.frame = view.bounds
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(grid)
    }

    private func button(title: String = "", symbol: String? = nil, label: String? = nil, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        b.setTitle(title, for: .normal)
        if let symbol { b.setImage(UIImage(systemName: symbol), for: .normal) }
        b.accessibilityLabel = label
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
    /// The strip's look at rest (the deck tints it to say what the picture is doing).
    static let restingFill = UIColor(white: 1, alpha: 0.07)
    static let restingBorder = UIColor(white: 1, alpha: 0.14)
    /// What dictation hears, shown in the strip while it listens (the strip still works under it): several
    /// lines where it is tall, one (the newest words) where it is thin.
    private let transcript = UILabel()
    /// Room kept clear at the bottom (the deck's status line).
    var transcriptBottomInset: CGFloat = 0 { didSet { setNeedsLayout() } }

    /// nil: nothing shown.
    func setTranscript(_ text: String?) {
        guard transcript.text != text || transcript.isHidden != (text == nil) else { return }
        transcript.text = text
        transcript.isHidden = text == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !transcript.isHidden else { return }
        let thin = bounds.height - transcriptBottomInset < 90
        transcript.numberOfLines = thin ? 1 : 0
        transcript.font = .systemFont(ofSize: thin ? min(20, max(13, bounds.height * 0.38)) : 22, weight: .medium)
        let room = CGRect(x: 16, y: thin ? 0 : 14, width: bounds.width - 32,
                          height: thin ? bounds.height - transcriptBottomInset : bounds.height - transcriptBottomInset - 28)
        let fit = transcript.sizeThatFits(CGSize(width: room.width, height: .greatestFiniteMagnitude))
        transcript.frame = thin ? room : CGRect(x: room.minX, y: room.minY, width: room.width, height: min(fit.height, max(room.height, 0)))
    }

    /// `corner`: a patch over the stream at a side edge, drawn very faintly and rounded on those corners (the
    /// ones pointing into the screen); nil: the portrait strip.
    init(corner: CACornerMask? = nil) {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = corner == nil ? Self.restingFill : UIColor(white: 1, alpha: 0.05)
        layer.cornerRadius = corner == nil ? 14 : 28
        if let corner { layer.maskedCorners = corner }
        layer.borderWidth = 1
        layer.borderColor = (corner == nil ? Self.restingBorder : UIColor(white: 1, alpha: 0.09)).cgColor
        accessibilityLabel = "Trackpad"
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        transcript.textColor = UIColor(white: 1, alpha: 0.85)
        transcript.lineBreakMode = .byTruncatingHead   // the newest words, where it overflows
        transcript.isUserInteractionEnabled = false
        transcript.isHidden = true
        addSubview(transcript)
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

/// The row of keys in the band above the trackpad strip, in one of three forms:
/// - `band` (an iPad upright): the keys the row above the keyboard has no room for: forward delete, Home, End,
///   Page Up and Down, and Paste (the device's clipboard, typed on the host).
/// - `remote` (a phone's remote, where no row shows until the keyboard is up): Esc first, and Paste as its icon
///   alone (with its label it doesn't fit a key that narrow and draws nothing).
/// - `shared` (beside another app, at the trackpad strip's left): Esc and Paste only.
final class ExtraKeys: UIStackView {
    enum Form { case band, remote, shared }

    var onKey: (PhysicalKey) -> Void = { _ in }
    private weak var pasteTarget: (any UIPasteConfigurationSupporting)?
    private var escape: UIButton?
    private var navigation: [UIButton] = []
    private var paste: UIPasteControl?
    private var form = Form.band

    /// `pasteTarget`: what the system's paste button pastes into (it reads the clipboard without asking).
    init(pasteTarget: UIPasteConfigurationSupporting) {
        self.pasteTarget = pasteTarget
        super.init(frame: .zero)
        axis = .horizontal
        distribution = .fillEqually
        spacing = 6
        func add(title: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.tintColor = .white
            b.backgroundColor = UIColor(white: 1, alpha: 0.16)
            b.layer.cornerRadius = 7
            addArrangedSubview(b)
            return b
        }
        // HID keyboard-page usages.
        escape = add(title: "esc") { [weak self] in self?.onKey(.key(0x29)) }
        for (title, usage) in [("⌦", UInt16(0x4C)), ("home", 0x4A), ("end", 0x4D), ("pg↑", 0x4B), ("pg↓", 0x4E)] {
            navigation.append(add(title: title) { [weak self] in self?.onKey(.key(usage)) })
        }
        apply()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setForm(_ new: Form) {
        guard new != form else { return }
        form = new
        apply()
    }

    private func apply() {
        escape?.isHidden = form == .band
        for b in navigation { b.isHidden = form == .shared }
        // The paste control's look is fixed when it is made: a new one for each form.
        paste?.removeFromSuperview()
        let config = UIPasteControl.Configuration()
        config.displayMode = form == .band ? .iconAndLabel : .iconOnly
        config.cornerStyle = .fixed
        config.cornerRadius = 7
        config.baseBackgroundColor = UIColor(white: 0.26, alpha: 1)
        config.baseForegroundColor = .white
        let control = UIPasteControl(configuration: config)
        control.target = pasteTarget
        addArrangedSubview(control)
        paste = control
    }
}
