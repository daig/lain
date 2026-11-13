import LainClientCore
import UIKit

/// lain's controls on a phone's screen (the Duo closed): dictation, the keyboard and the settings, and a
/// ribbon to scroll with. On the Duo's outer display they run down the strip the system keeps
/// clear beside the camera, where its own bars go, upright and turned; on a phone without one, upright, the
/// buttons are in a row under the stream.
final class ControlStrip: UIView {
    var onDictate: () -> Void = {}
    var onKeyboard: () -> Void = {}
    var onSettings: () -> Void = {}
    /// The scroll ribbon, under the buttons where the strip runs down the side and has the room.
    let ribbon = ScrollRibbon()

    private let stack = UIStackView()
    private lazy var mic = button("mic", "Dictate") { [weak self] in self?.onDictate() }
    private lazy var keyboard = button("keyboard", "Keyboard") { [weak self] in self?.onKeyboard() }
    private lazy var settings = button("slider.horizontal.3", "Settings") { [weak self] in self?.onSettings() }
    private var vertical: [NSLayoutConstraint] = []
    private var horizontal: [NSLayoutConstraint] = []
    private static let idle = UIColor(white: 1, alpha: 0.14)

    init() {
        super.init(frame: .zero)
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for b in [mic, keyboard, settings] { stack.addArrangedSubview(b) }
        addSubview(ribbon)
        vertical = [stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.topAnchor.constraint(equalTo: topAnchor, constant: 10)]
        horizontal = [stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor)]
        setVertical(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setVertical(_ isVertical: Bool) {
        guard stack.axis != (isVertical ? .vertical : .horizontal) || !(vertical[0].isActive || horizontal[0].isActive) else { return }
        NSLayoutConstraint.deactivate(vertical + horizontal)
        stack.axis = isVertical ? .vertical : .horizontal
        stack.spacing = isVertical ? 14 : 22
        NSLayoutConstraint.activate(isVertical ? vertical : horizontal)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // What the buttons leave of a side strip; a row has none.
        stack.layoutIfNeeded()
        let top = stack.frame.maxY + 14
        let frame = CGRect(x: 12, y: top, width: bounds.width - 24, height: bounds.height - top - 8)
        let shown = stack.axis == .vertical && frame.height >= ScrollRibbon.minHeight
        if shown { ribbon.frame = frame }
        if ribbon.isHidden == shown { ribbon.isHidden = !shown }
    }

    /// - Parameters:
    ///   - keyboardOffered: there is no hardware keyboard.
    ///   - canType: the host takes typed and dictated text.
    func update(dictating: Bool, keyboardShown: Bool, keyboardOffered: Bool, canType: Bool) {
        mic.backgroundColor = dictating ? UIColor.systemRed.withAlphaComponent(0.85) : Self.idle
        mic.setImage(UIImage(systemName: dictating ? "mic.fill" : "mic"), for: .normal)
        keyboard.isHidden = !keyboardOffered
        keyboard.isEnabled = canType
        keyboard.backgroundColor = keyboardShown ? UIColor.systemBlue.withAlphaComponent(0.75) : Self.idle
        keyboard.setImage(UIImage(systemName: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard"), for: .normal)
        keyboard.accessibilityLabel = keyboardShown ? "Hide keyboard" : "Keyboard"
        setNeedsLayout()   // the keyboard's button comes and goes
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = .white
        b.backgroundColor = Self.idle
        b.layer.cornerRadius = 24
        b.accessibilityLabel = label
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 48), b.heightAnchor.constraint(equalToConstant: 48)])
        return b
    }
}

/// A ribbon to scroll with one thumb: sliding along it scrolls the host as two fingers on a trackpad do (the
/// content follows the finger, and coasts when it lifts). For a phone held in both hands, where a second finger
/// on the glass means letting go.
final class ScrollRibbon: UIView {
    var onBegan: () -> Void = {}
    /// The finger's travel since the last call, in the ribbon's points (y down).
    var onScroll: (CGFloat) -> Void = { _ in }
    var onEnded: () -> Void = {}
    var onCancelled: () -> Void = {}
    static let minHeight: CGFloat = 80
    private var last: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1, alpha: 0.07)
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
        isHidden = true
        accessibilityLabel = "Scroll"
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        let mark = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down"))
        mark.tintColor = UIColor(white: 1, alpha: 0.35)
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        NSLayoutConstraint.activate([mark.centerXAnchor.constraint(equalTo: centerXAnchor), mark.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        last = touch.location(in: self).y
        onBegan()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let y = touch.location(in: self).y
        if y != last { onScroll(y - last) }
        last = y
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { onEnded() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onCancelled() }
}

/// The panel as a sheet, for a window too narrow for the panel's lines and for fingers: the stream's numbers,
/// the hosts and the options (`ControlPanel.Sheet`). A tap on a row acts as a click on the panel's row does.
final class SettingsSheet: UITableViewController {
    /// A row of `ControlPanel.rows` was tapped.
    var onSelect: (Int) -> Void = { _ in }
    var onClose: () -> Void = {}
    private var content = ControlPanel.Sheet()

    init() {
        super.init(style: .insetGrouped)
        title = "lain"
        overrideUserInterfaceStyle = .dark
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.accessibilityIdentifier = "settings.sheet"
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onClose()
    }

    func show(_ new: ControlPanel.Sheet) {
        guard new != content else { return }
        let old = content
        content = new
        guard isViewLoaded else { return }
        // The numbers change four times a second: only their cell is redrawn, so a tap elsewhere isn't lost.
        if old.hosts == new.hosts, old.options == new.options, old.hostsNote == new.hostsNote,
           let cell = tableView.cellForRow(at: IndexPath(row: 0, section: 0)) {
            configureStatus(cell)
        } else {
            tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        [1, content.hosts.count, content.options.count][section]
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [nil, "Hosts", "Options"][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? content.hostsNote : nil
    }

    private func item(at indexPath: IndexPath) -> ControlPanel.Sheet.Item? {
        switch indexPath.section {
        case 1: content.hosts[indexPath.row]
        case 2: content.options[indexPath.row]
        default: nil
        }
    }

    private func configureStatus(_ cell: UITableViewCell) {
        var c = UIListContentConfiguration.subtitleCell()
        c.text = content.title
        c.textProperties.font = .preferredFont(forTextStyle: .headline)
        c.secondaryText = content.status.joined(separator: "\n")
        c.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        c.secondaryTextProperties.color = .secondaryLabel
        c.textToSecondaryTextVerticalPadding = 6
        cell.contentConfiguration = c
        cell.selectionStyle = .none
        cell.accessoryType = .none
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        guard let item = item(at: indexPath) else {
            configureStatus(cell)
            return cell
        }
        var c = UIListContentConfiguration.valueCell()
        c.text = item.title
        c.secondaryText = item.value
        c.textProperties.color = item.row == nil ? .secondaryLabel : .label
        cell.contentConfiguration = c
        cell.accessoryType = item.isChecked ? .checkmark : .none
        cell.selectionStyle = item.row == nil ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let row = item(at: indexPath)?.row { onSelect(row) }
    }
}
