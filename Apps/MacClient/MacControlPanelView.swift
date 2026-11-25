import AppKit
import LainClientCore

/// Native AppKit rendering of `ControlPanel.Line` (opened by holding Right Option alone, or from the menu).
/// Supports keyboard navigation (via `ControlPanel.key`), direct mouse clicks on rows, and a simulated
/// pointer dot when relative pointer capture is active.
final class MacControlPanelView: NSView {
    var lastStats = VideoStats()
    var onClickRow: ((Int) -> Void)?

    private let stack = NSStackView()
    private var rowViews: [(row: Int, view: NSView)] = []
    private let pointerDot = NSView()
    private var pointerPos = CGPoint.zero
    private var showsPointerDot = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])

        pointerDot.wantsLayer = true
        pointerDot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        pointerDot.layer?.cornerRadius = 6
        pointerDot.layer?.borderWidth = 1.5
        pointerDot.layer?.borderColor = NSColor.black.cgColor
        pointerDot.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        pointerDot.isHidden = true
        addSubview(pointerDot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ lines: [ControlPanel.Line]) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        rowViews.removeAll()

        for line in lines {
            let label = NSTextField(labelWithString: line.text)
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
            switch line.style {
            case .title:
                label.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
                label.textColor = .white
            case .heading:
                label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
                label.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
            case .text:
                label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                label.textColor = line.isSelected ? .white : NSColor(calibratedWhite: 0.9, alpha: 1)
            case .dim:
                label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                label.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
            }

            if let row = line.row {
                let container = PanelRowContainer(row: row, isSelected: line.isSelected) { [weak self] r in
                    self?.onClickRow?(r)
                }
                label.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                    label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                    label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
                    label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
                ])
                stack.addArrangedSubview(container)
                container.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                rowViews.append((row, container))
            } else {
                if line.style == .heading {
                    let spacer = NSView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
                    stack.addArrangedSubview(spacer)
                }
                stack.addArrangedSubview(label)
            }
        }
    }

    /// Shows and centres the simulated cursor dot (used when the hardware pointer is captured).
    func centerCursor(showDot: Bool) {
        showsPointerDot = showDot
        pointerDot.isHidden = !showDot
        pointerPos = CGPoint(x: bounds.midX, y: bounds.midY)
        updatePointerDot()
    }

    /// Moves the simulated cursor dot by relative deltas (y up-positive, matching `LocalShortcut.panelPointer`).
    func moveCursor(dx: Double, dy: Double) {
        guard showsPointerDot else { return }
        pointerPos.x = min(max(pointerPos.x + dx, 6), max(bounds.width - 6, 6))
        pointerPos.y = min(max(pointerPos.y + dy, 6), max(bounds.height - 6, 6))
        updatePointerDot()
    }

    func rowUnderCursor() -> Int? {
        guard showsPointerDot else { return nil }
        for entry in rowViews {
            let rect = entry.view.convert(entry.view.bounds, to: self)
            if rect.contains(pointerPos) { return entry.row }
        }
        return nil
    }

    private func updatePointerDot() {
        pointerDot.frame.origin = CGPoint(x: pointerPos.x - 6, y: pointerPos.y - 6)
    }
}

private final class PanelRowContainer: NSView {
    private let row: Int
    private let onClick: (Int) -> Void

    init(row: Int, isSelected: Bool, onClick: @escaping (Int) -> Void) {
        self.row = row
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            : NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        onClick(row)
    }
}
