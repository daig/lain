import LainClientCore
import LainInput
import UIKit

/// Focus-driven tvOS overlay combining Quick Actions (Type/Dictate, 2× Zoom, Drag Lock, common host
/// shortcuts) with Lain's `ControlPanel` status, host picker, and settings.
final class TVOverlayViewController: UIViewController {
    var onTypeText: ((String, Bool) -> Void)?
    var onToggleDictation: (() -> Void)?
    var onProbeDictation: (() -> Void)?
    var onTapKey: ((PhysicalKey, [PhysicalKey]) -> Void)?
    var onToggleZoom: (() -> Void)?
    var onToggleDragLock: (() -> Void)?
    var onToggleHUD: (() -> Void)?
    var onSelectRow: ((Int) -> Void)?
    var onPairHost: ((ClientSession.UnpairedHost?) -> Void)?
    var onClose: (() -> Void)?

    private var remoteState = ClientInputPipeline.RemoteState()
    private var hudVisible = false
    private var canType = false
    private var isDictating = false
    private var dictationProbeText = ""
    private var sheet = ControlPanel.Sheet()
    private var unpairedHosts: [ClientSession.UnpairedHost] = []

    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let probeLabel = UILabel()
    private let quickStack = UIStackView()
    private let settingsStack = UIStackView()

    private var dictationButton: UIButton?
    private var zoomButton: UIButton?
    private var dragLockButton: UIButton?
    private var hudButton: UIButton?
    private var typeButton: UIButton?
    private var settingsButtons: [(row: Int, button: UIButton)] = []
    private var renderedUnpairedIds: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        overrideUserInterfaceStyle = .dark

        card.layer.cornerRadius = 32
        card.layer.masksToBounds = true
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 1, alpha: 0.16).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, statusLabel, probeLabel])
        header.axis = .vertical
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 40, weight: .semibold)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 22, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.65)
        subtitleLabel.text = "Press Back to resume · Hold Back anytime to reopen"
        statusLabel.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        statusLabel.textColor = UIColor(white: 1, alpha: 0.78)
        statusLabel.numberOfLines = 4
        probeLabel.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        probeLabel.textColor = UIColor(red: 0.65, green: 0.90, blue: 1.0, alpha: 0.92)
        probeLabel.numberOfLines = 0
        probeLabel.isHidden = true

        quickStack.axis = .vertical
        quickStack.spacing = 14
        quickStack.alignment = .fill

        settingsStack.axis = .vertical
        settingsStack.spacing = 14
        settingsStack.alignment = .fill

        let columns = UIStackView(arrangedSubviews: [quickStack, settingsStack])
        columns.axis = .horizontal
        columns.spacing = 48
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.translatesAutoresizingMaskIntoConstraints = false

        card.contentView.addSubview(header)
        card.contentView.addSubview(columns)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.84),
            card.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.86),

            header.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 36),
            header.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 44),
            header.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -44),

            columns.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 28),
            columns.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 44),
            columns.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -44),
            columns.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -36),
        ])

        buildQuickActions()
        applyContent()

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(handleMenu))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)
    }

    func update(sheet: ControlPanel.Sheet, remoteState: ClientInputPipeline.RemoteState, hudVisible: Bool, canType: Bool,
                isDictating: Bool = false, dictationProbeText: String = "",
                unpairedHosts: [ClientSession.UnpairedHost] = []) {
        self.sheet = sheet
        self.remoteState = remoteState
        self.hudVisible = hudVisible
        self.canType = canType
        self.isDictating = isDictating
        self.dictationProbeText = dictationProbeText
        self.unpairedHosts = unpairedHosts
        if isViewLoaded { applyContent() }
    }

    // MARK: Content

    private func buildQuickActions() {
        quickStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        quickStack.addArrangedSubview(sectionHeading("QUICK ACTIONS"))

        let dictBtn = makeActionButton(title: "Start Live Dictation", accessibilityId: "overlay.dictation") { [weak self] in
            self?.onToggleDictation?()
        }
        dictationButton = dictBtn
        quickStack.addArrangedSubview(dictBtn)

        let probeBtn = makeActionButton(title: "Probe Mic & Speech", accessibilityId: "overlay.probeDictation") { [weak self] in
            self?.onProbeDictation?()
        }
        quickStack.addArrangedSubview(probeBtn)

        let typeBtn = makeActionButton(title: "Type / Siri Keyboard…", accessibilityId: "overlay.type") { [weak self] in
            self?.presentTextEntry()
        }
        typeButton = typeBtn
        quickStack.addArrangedSubview(typeBtn)

        let zoomBtn = makeActionButton(title: "2× Cursor Zoom: Off", accessibilityId: "overlay.zoom") { [weak self] in
            self?.onToggleZoom?()
        }
        zoomButton = zoomBtn
        quickStack.addArrangedSubview(zoomBtn)

        let dragBtn = makeActionButton(title: "Drag Lock: Off", accessibilityId: "overlay.dragLock") { [weak self] in
            self?.onToggleDragLock?()
        }
        dragLockButton = dragBtn
        quickStack.addArrangedSubview(dragBtn)

        let hudBtn = makeActionButton(title: "Stats HUD: Off", accessibilityId: "overlay.hud") { [weak self] in
            self?.onToggleHUD?()
        }
        hudButton = hudBtn
        quickStack.addArrangedSubview(hudBtn)

        quickStack.addArrangedSubview(sectionHeading("HOST SHORTCUTS"))
        let shortcutRows: [[(String, PhysicalKey, [PhysicalKey])]] = [
            [("Return", .return, []), ("Backspace", .key(0x2A), []), ("Tab", .tab, [])],
            [("⌘ Space", .space, [.leftCommand]), ("⌘ Tab", .tab, [.leftCommand]), ("Esc", .escape, [])],
        ]
        for row in shortcutRows {
            let h = UIStackView()
            h.axis = .horizontal
            h.spacing = 12
            h.distribution = .fillEqually
            for (label, key, mods) in row {
                h.addArrangedSubview(makeActionButton(title: label) { [weak self] in
                    self?.onTapKey?(key, mods)
                })
            }
            quickStack.addArrangedSubview(h)
        }
    }

    private func applyContent() {
        titleLabel.text = sheet.title.isEmpty ? "lain" : sheet.title
        statusLabel.text = sheet.status.joined(separator: "\n")
        probeLabel.text = dictationProbeText
        probeLabel.isHidden = dictationProbeText.isEmpty

        dictationButton?.setTitle(isDictating ? "Stop Live Dictation" : "Start Live Dictation", for: .normal)
        typeButton?.isEnabled = canType
        zoomButton?.setTitle("2× Cursor Zoom: \(remoteState.zoomed ? "On" : "Off")", for: .normal)
        dragLockButton?.setTitle("Drag Lock: \(remoteState.dragLocked ? "On" : "Off")", for: .normal)
        hudButton?.setTitle("Stats HUD: \(hudVisible ? "On" : "Off")", for: .normal)

        rebuildSettingsColumn()
    }

    private func rebuildSettingsColumn() {
        // Avoid rebuilding buttons (which would disturb tvOS focus) if the row list hasn't changed.
        let desiredItems: [(row: Int?, title: String)] =
            sheet.hosts.map { ($0.row, ($0.isChecked ? "● " : "○ ") + $0.title + ($0.value.isEmpty ? "" : " · \($0.value)")) }
            + sheet.options.map { ($0.row, "\($0.title): \($0.value)") }
        let desiredRows = desiredItems.compactMap(\.row)
        let unpairedIds = unpairedHosts.map(\.id)
        if desiredRows == settingsButtons.map(\.row), unpairedIds == renderedUnpairedIds, !settingsButtons.isEmpty {
            for (item, pair) in zip(desiredItems.filter { $0.row != nil }, settingsButtons) {
                pair.button.setTitle(item.title, for: .normal)
            }
            return
        }

        settingsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        settingsButtons.removeAll()
        renderedUnpairedIds = unpairedIds

        settingsStack.addArrangedSubview(sectionHeading("HOSTS"))
        if let note = sheet.hostsNote, unpairedHosts.isEmpty {
            let label = UILabel()
            label.font = .systemFont(ofSize: 22)
            label.textColor = UIColor(white: 1, alpha: 0.55)
            label.numberOfLines = 0
            label.text = note
            settingsStack.addArrangedSubview(label)
        }
        for host in sheet.hosts {
            let label = (host.isChecked ? "● " : "○ ") + host.title + (host.value.isEmpty ? "" : " · \(host.value)")
            if let row = host.row {
                let button = makeActionButton(title: label) { [weak self] in self?.onSelectRow?(row) }
                settingsButtons.append((row, button))
                settingsStack.addArrangedSubview(button)
            }
        }
        for host in unpairedHosts {
            let verb = host.keyRefused ? "Re-pair" : "Pair"
            let button = makeActionButton(title: "+ \(verb) with \(host.name)…") { [weak self] in
                self?.onPairHost?(host)
            }
            settingsStack.addArrangedSubview(button)
        }
        let pairCodeBtn = makeActionButton(title: "+ Enter Pairing Code…", accessibilityId: "overlay.pairCode") { [weak self] in
            self?.onPairHost?(nil)
        }
        settingsStack.addArrangedSubview(pairCodeBtn)

        settingsStack.addArrangedSubview(sectionHeading("SETTINGS"))
        for option in sheet.options {
            guard let row = option.row else { continue }
            let button = makeActionButton(title: "\(option.title): \(option.value)") { [weak self] in
                self?.onSelectRow?(row)
            }
            settingsButtons.append((row, button))
            settingsStack.addArrangedSubview(button)
        }
    }

    private func sectionHeading(_ title: String) -> UILabel {
        let label = UILabel()
        label.font = .monospacedSystemFont(ofSize: 18, weight: .bold)
        label.textColor = UIColor(white: 1, alpha: 0.5)
        label.text = title
        return label
    }

    private func makeActionButton(title: String, accessibilityId: String? = nil,
                                  action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 24, weight: .medium)
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = accessibilityId
        return button
    }

    private func presentTextEntry() {
        let entry = TVTextInputViewController()
        entry.onSubmit = { [weak self] text, sendReturn in
            self?.onTypeText?(text, sendReturn)
        }
        present(entry, animated: true)
    }

    @objc private func handleMenu() {
        onClose?()
    }
}

/// Native tvOS text entry modal: focusing the `UITextField` automatically activates Siri dictation,
/// iPhone/iPad Continuity Keyboard notifications, and the tvOS on-screen keyboard.
final class TVTextInputViewController: UIViewController, UITextFieldDelegate {
    var onSubmit: ((String, Bool) -> Void)?

    private let field = UITextField()
    private let hintLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        overrideUserInterfaceStyle = .dark

        hintLabel.text = "Type on iPhone/iPad, hold Siri to dictate, or use the on-screen keyboard"
        hintLabel.font = .systemFont(ofSize: 26, weight: .medium)
        hintLabel.textColor = UIColor(white: 1, alpha: 0.78)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        field.placeholder = "Text to type on host…"
        field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: 32)
        field.returnKeyType = .send
        field.delegate = self
        field.accessibilityIdentifier = "textEntry.field"

        let sendBtn = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
            self?.submit(sendReturn: false)
        })
        sendBtn.setTitle("Type Text", for: .normal)

        let sendReturnBtn = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
            self?.submit(sendReturn: true)
        })
        sendReturnBtn.setTitle("Type + Return", for: .normal)

        let cancelBtn = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        cancelBtn.setTitle("Cancel", for: .normal)

        let buttons = UIStackView(arrangedSubviews: [sendBtn, sendReturnBtn, cancelBtn])
        buttons.axis = .horizontal
        buttons.spacing = 24
        buttons.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [hintLabel, field, buttons])
        stack.axis = .vertical
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.62),
            field.heightAnchor.constraint(equalToConstant: 72),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit(sendReturn: true)
        return false
    }

    private func submit(sendReturn: Bool) {
        let text = field.text ?? ""
        dismiss(animated: true) { [onSubmit] in
            guard !text.isEmpty || sendReturn else { return }
            onSubmit?(text, sendReturn)
        }
    }
}

/// Modal pairing-code entry sheet for pairing an Apple TV with a Mac or Linux host over LAN
/// using the shared `lain1:…` pairing code and iPhone/iPad Apple TV Keyboard paste.
final class TVPairHostViewController: UIViewController, UITextFieldDelegate {
    let host: ClientSession.UnpairedHost?
    /// Called with the entered `lain1:…` pairing code; returns `nil` on success or an error message to show inline.
    var onPair: ((String) -> String?)?

    private let titleLabel = UILabel()
    private let stepsCard = UIView()
    private let field = UITextField()
    private let errorLabel = UILabel()

    init(host: ClientSession.UnpairedHost? = nil) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [field] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        overrideUserInterfaceStyle = .dark

        if let host {
            titleLabel.text = "\(host.keyRefused ? "Re-pair" : "Pair") with \(host.name)"
        } else {
            titleLabel.text = "Pair with a Computer"
        }
        titleLabel.font = .systemFont(ofSize: 44, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        stepsCard.backgroundColor = UIColor(white: 1, alpha: 0.08)
        stepsCard.layer.cornerRadius = 24
        stepsCard.layer.borderWidth = 1
        stepsCard.layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor

        let stepsStack = UIStackView(arrangedSubviews: [
            makeStep(number: "1",
                     heading: "Get a pairing code on your computer",
                     body: "Linux: run  lain pair-code   ·   Mac: click lain in the menu bar → Copy Pairing Code\nCopy the lain1:… code to your iPhone or iPad (Universal Clipboard, Notes, or Messages)."),
            makeStep(number: "2",
                     heading: "Click the code box below",
                     body: "Select the text field below with the Siri Remote to open the Apple TV keyboard."),
            makeStep(number: "3",
                     heading: "Paste from your iPhone or iPad",
                     body: "With your unlocked iPhone/iPad nearby (same Apple Account, Wi-Fi & Bluetooth on), tap the “Apple TV Keyboard” notification on your iPhone/iPad — or open Control Center → Apple TV Remote — Paste the code, and tap Done."),
        ])
        stepsStack.axis = .vertical
        stepsStack.spacing = 18
        stepsStack.translatesAutoresizingMaskIntoConstraints = false
        stepsCard.addSubview(stepsStack)
        NSLayoutConstraint.activate([
            stepsStack.topAnchor.constraint(equalTo: stepsCard.topAnchor, constant: 24),
            stepsStack.bottomAnchor.constraint(equalTo: stepsCard.bottomAnchor, constant: -24),
            stepsStack.leadingAnchor.constraint(equalTo: stepsCard.leadingAnchor, constant: 32),
            stepsStack.trailingAnchor.constraint(equalTo: stepsCard.trailingAnchor, constant: -32),
        ])

        field.placeholder = "Select here, then paste lain1:… from iPhone/iPad"
        field.borderStyle = .roundedRect
        field.font = .monospacedSystemFont(ofSize: 28, weight: .regular)
        field.textAlignment = .left
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .done
        field.delegate = self
        field.accessibilityIdentifier = "pair.codeField"

        errorLabel.font = .systemFont(ofSize: 24, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        let pairBtn = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in self?.submit() })
        pairBtn.setTitle("Pair & Connect", for: .normal)
        pairBtn.accessibilityIdentifier = "pair.submit"

        let cancelBtn = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        cancelBtn.setTitle("Cancel", for: .normal)

        let buttons = UIStackView(arrangedSubviews: [pairBtn, cancelBtn])
        buttons.axis = .horizontal
        buttons.spacing = 24
        buttons.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [titleLabel, stepsCard, field, errorLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.72),
            field.heightAnchor.constraint(equalToConstant: 76),
        ])
    }

    private func makeStep(number: String, heading: String, body: String) -> UIView {
        let badge = UILabel()
        badge.text = number
        badge.font = .systemFont(ofSize: 22, weight: .bold)
        badge.textColor = .black
        badge.backgroundColor = UIColor(white: 1, alpha: 0.88)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 18
        badge.layer.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 36),
            badge.heightAnchor.constraint(equalToConstant: 36),
        ])

        let head = UILabel()
        head.text = heading
        head.font = .systemFont(ofSize: 24, weight: .semibold)
        head.textColor = .white

        let detail = UILabel()
        detail.text = body
        detail.font = .systemFont(ofSize: 21, weight: .regular)
        detail.textColor = UIColor(white: 1, alpha: 0.76)
        detail.numberOfLines = 0

        let textCol = UIStackView(arrangedSubviews: [head, detail])
        textCol.axis = .vertical
        textCol.spacing = 4

        let row = UIStackView(arrangedSubviews: [badge, textCol])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 18
        return row
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }

    private func submit() {
        let code = field.text ?? ""
        if let err = onPair?(code) {
            errorLabel.text = err
            errorLabel.isHidden = false
            return
        }
        dismiss(animated: true)
    }
}
