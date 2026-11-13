import UIKit

/// While dictating, in place of a row of keys beside a trackpad (the deck's, the band's): the two keys voice
/// can't press. Delete takes back the last phrase (and dictation goes on); Return sends, and dictation stops.
/// Compact (a narrow place, as beside the Split View strip): their symbols only.
final class DictationKeys: UIStackView {
    var onDeletePhrase: () -> Void = {}
    var onReturn: () -> Void = {}
    private var buttons: [(UIButton, String)] = []

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        distribution = .fillEqually
        spacing = 6
        isHidden = true
        for (symbol, title, color, action) in [
            ("delete.left", "Delete phrase", UIColor(white: 1, alpha: 0.16), { [weak self] in self?.onDeletePhrase() }),
            ("return", "Return", UIColor.systemBlue.withAlphaComponent(0.6), { [weak self] in self?.onReturn() }),
        ] as [(String, String, UIColor, () -> Void)] {
            var c = UIButton.Configuration.plain()
            c.image = UIImage(systemName: symbol)
            c.title = title
            c.imagePadding = 8
            c.baseForegroundColor = .white
            c.titleLineBreakMode = .byClipping
            let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
            b.backgroundColor = color
            b.layer.cornerRadius = 9
            b.accessibilityLabel = title
            addArrangedSubview(b)
            buttons.append((b, title))
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setCompact(_ compact: Bool) {
        for (b, title) in buttons where (b.configuration?.title == nil) != compact {
            b.configuration?.title = compact ? nil : title
        }
    }
}
