import LainClientCore
import LainInput
import UIKit

/// The deck: the lower half of the Duo folded like a laptop and set down, to watch something long-running (an
/// agent at work) with the hands off (`StreamLayout.Deck`). There is no keyboard; typing on a half that lies
/// flat is no good. Instead: a row of keys that answer a prompt (along the fold, where a laptop's function row
/// is), a large trackpad that acts as a Magic Trackpad does (two fingers scroll, a pinch zooms the picture
/// above), and a large microphone at the front corner, under the hand.
final class DeckView: UIView {
    /// A key pressed with these modifiers held around it.
    var onKey: (PhysicalKey, [PhysicalKey]) -> Void = { _, _ in }
    var onDictate: () -> Void = {}
    var onSettings: () -> Void = {}
    let trackpad = TrackpadStrip()

    private let keys = UIStackView()
    /// While dictating, in place of `keys`.
    let dictationKeys = DictationKeys()
    /// Whether what the picture shows is changing (`ActivityDetector`), in the trackpad's corner.
    private let activity = UILabel()
    private let mic = UIButton(type: .system)
    private let settings = UIButton(type: .system)
    private static let key = UIColor(white: 1, alpha: 0.16)

    /// The answers a coding agent's prompts take: Esc stops it, ⌃C interrupts, ⇧⇥ changes its mode, the
    /// arrows and digits pick from a menu, Return accepts. HID keyboard-page usages.
    private static let answers: [(title: String, key: PhysicalKey, held: [PhysicalKey], label: String)] = [
        ("esc", .escape, [], "Escape"),
        ("⌃C", .key(0x06), [.leftControl], "Control C"),
        ("⇧⇥", .tab, [.leftShift], "Shift Tab"),
        ("↑", .key(0x52), [], "Up"),
        ("↓", .key(0x51), [], "Down"),
        ("1", .key(0x1E), [], "1"),
        ("2", .key(0x1F), [], "2"),
        ("3", .key(0x20), [], "3"),
        ("⏎", .return, [], "Return"),
    ]

    init() {
        super.init(frame: .zero)
        keys.axis = .horizontal
        keys.distribution = .fillEqually
        keys.spacing = 6
        for answer in Self.answers {
            let b = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in self?.onKey(answer.key, answer.held) })
            b.setTitle(answer.title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.tintColor = .white
            b.backgroundColor = answer.key == .return ? UIColor.systemBlue.withAlphaComponent(0.6) : Self.key
            b.layer.cornerRadius = 9
            b.accessibilityLabel = answer.label
            keys.addArrangedSubview(b)
        }

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .regular))
        config.title = "Dictate"
        config.imagePlacement = .top
        config.imagePadding = 10
        config.baseForegroundColor = .white
        mic.configuration = config
        mic.backgroundColor = Self.key
        mic.layer.cornerRadius = 22
        mic.accessibilityLabel = "Dictate"
        mic.addAction(UIAction { [weak self] _ in self?.onDictate() }, for: .touchUpInside)

        settings.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settings.tintColor = .white
        settings.backgroundColor = UIColor(white: 1, alpha: 0.1)
        settings.layer.cornerRadius = 12
        settings.accessibilityLabel = "Settings"
        settings.addAction(UIAction { [weak self] _ in self?.onSettings() }, for: .touchUpInside)

        addSubview(dictationKeys)
        activity.font = .systemFont(ofSize: 15, weight: .semibold)
        activity.isUserInteractionEnabled = false   // the trackpad's, under it
        for v in [keys, trackpad, mic, settings] as [UIView] { addSubview(v) }
        trackpad.addSubview(activity)
        setActivity(.still)
    }

    /// What the picture is doing, readable across a desk: the whole trackpad takes its colour (it is the deck's
    /// largest surface), and its corner says it in words. Watching: the trackpad's own grey. Working: green,
    /// breathing slowly (it is alive). Waiting: orange, steady, with a bright edge (the alert went off).
    func setActivity(_ phase: ActivityDetector.Phase) {
        let (text, color): (String, UIColor) = switch phase {
        case .still: ("○  watching", UIColor(white: 1, alpha: 0.35))
        case .working: ("●  working", .systemGreen)
        case .quiet: ("●  waiting for you", .systemOrange)
        }
        guard activity.text != text else { return }
        activity.text = text
        activity.textColor = color
        let pad = trackpad.layer
        pad.removeAnimation(forKey: "breathing")
        let fill: UIColor = switch phase {
        case .still: TrackpadStrip.restingFill
        case .working: UIColor.systemGreen.withAlphaComponent(0.16)
        case .quiet: UIColor.systemOrange.withAlphaComponent(0.3)
        }
        UIView.animate(withDuration: 0.4) {
            self.trackpad.backgroundColor = fill
            pad.borderColor = phase == .quiet ? UIColor.systemOrange.cgColor : TrackpadStrip.restingBorder.cgColor
            pad.borderWidth = phase == .quiet ? 2 : 1
        }
        if phase == .working, !UIAccessibility.isReduceMotionEnabled {
            let breathe = CABasicAnimation(keyPath: "backgroundColor")
            breathe.fromValue = UIColor.systemGreen.withAlphaComponent(0.08).cgColor
            breathe.toValue = UIColor.systemGreen.withAlphaComponent(0.2).cgColor
            breathe.duration = 1.6
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pad.add(breathe, forKey: "breathing")
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        activity.sizeToFit()
        activity.frame.origin = CGPoint(x: 14, y: trackpad.bounds.height - activity.frame.height - 12)
        trackpad.transcriptBottomInset = trackpad.bounds.height - activity.frame.minY   // above the status
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Places the deck and its parts (the layout's frames are the view's; the parts' are the deck's).
    func apply(_ deck: StreamLayout.Deck) {
        frame = deck.frame
        let o = deck.frame.origin
        keys.frame = deck.keys.offsetBy(dx: -o.x, dy: -o.y)
        dictationKeys.frame = keys.frame
        trackpad.frame = deck.trackpad.offsetBy(dx: -o.x, dy: -o.y)
        mic.frame = deck.mic.offsetBy(dx: -o.x, dy: -o.y)
        settings.frame = deck.settings.offsetBy(dx: -o.x, dy: -o.y)
    }

    /// Dictating: the microphone is lit (a tap on it stops), and the row of keys becomes the two that voice
    /// can't press (`DictationKeys`). What is heard shows in the trackpad (`TrackpadStrip.setTranscript`).
    func setDictating(_ on: Bool) {
        mic.configuration?.image = UIImage(systemName: on ? "mic.fill" : "mic",
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .regular))
        mic.configuration?.title = on ? "Stop" : "Dictate"
        mic.backgroundColor = on ? UIColor.systemRed.withAlphaComponent(0.85) : Self.key
        mic.accessibilityLabel = on ? "Stop dictating" : "Dictate"
        keys.isHidden = on
        dictationKeys.isHidden = !on
    }
}
