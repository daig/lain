// Input Lab — spike S4/S5. Logs every keyboard/trackpad event source iPadOS offers, with and
// without pointer lock, so we learn what the lain client can actually capture.
//
// Every event goes to stdout (visible via `devicectl ... --console`) and Documents/inputlab.log.
// Ctrl-Opt-Cmd-L toggles the pointer-lock request. Ctrl-Opt-Cmd-C clears the screen log.
// Ctrl-Opt-Cmd-M toggles stripping the app's own main menu (to see which Cmd combos it owns).

import GameController
import UIKit

// MARK: - Logging

final class Log: @unchecked Sendable {
    static let shared = Log()
    private let lock = NSLock()
    private var lines: [String] = []
    private var dirty = false
    private let file: FileHandle?
    private let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    private init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inputlab.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    func add(_ tag: String, _ message: String, screen: Bool = true) {
        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6
        let line = String(format: "%10.2f  %-8@ %@", ms, tag as NSString, message as NSString)
        print(line)
        lock.lock()
        file?.write((line + "\n").data(using: .utf8)!)
        if screen {
            lines.append(line)
            if lines.count > 60 { lines.removeFirst(lines.count - 60) }
            dirty = true
        }
        lock.unlock()
    }

    func clearScreen() { lock.lock(); lines.removeAll(); dirty = true; lock.unlock() }

    /// Returns the screen lines if they changed since the last call.
    func takeIfDirty() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard dirty else { return nil }
        dirty = false
        return lines
    }
}

/// High-rate counters (mouse motion, scroll) summarized on screen instead of flooding it.
final class Stats: @unchecked Sendable {
    static let shared = Stats()
    private let lock = NSLock()
    var moveCount = 0, moveDX: Float = 0, moveDY: Float = 0, lastMoveNs: UInt64 = 0, minGapMs = 1e9, maxGapMs = 0.0
    var gcScrollCount = 0, gcScrollX: Float = 0, gcScrollY: Float = 0
    var panCount = 0, hoverCount = 0

    func with<T>(_ body: (Stats) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }

    func recordMove(_ dx: Float, _ dy: Float) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        with { s in
            if s.lastMoveNs != 0 {
                let gap = Double(now - s.lastMoveNs) / 1e6
                if gap < 100 { s.minGapMs = min(s.minGapMs, gap); s.maxGapMs = max(s.maxGapMs, gap) }
            }
            s.lastMoveNs = now; s.moveCount += 1; s.moveDX += dx; s.moveDY += dy
        }
    }
}

// MARK: - Combo checklist (S5)

struct Combo {
    let name: String
    let mods: Set<String>   // "cmd", "shift", "opt", "ctrl"
    let key: Int            // HID usage
    var seenGC = false, seenUIKit = false, seenKeyCommand = false
}

enum HID {
    static let names: [Int: String] = [
        0x04: "A", 0x07: "D", 0x0B: "H", 0x14: "Q", 0x1A: "W", 0x20: "3", 0x21: "4", 0x22: "5",
        0x28: "Return", 0x29: "Esc", 0x2A: "Delete", 0x2B: "Tab", 0x2C: "Space", 0x35: "`", 0x39: "CapsLock",
        0x4F: "Right", 0x50: "Left", 0x51: "Down", 0x52: "Up",
        0xE0: "LCtrl", 0xE1: "LShift", 0xE2: "LOpt", 0xE3: "LCmd", 0xE4: "RCtrl", 0xE5: "RShift", 0xE6: "ROpt", 0xE7: "RCmd",
    ]
    static func name(_ u: Int) -> String { names[u] ?? String(format: "0x%02X", u) }
    static func modifier(_ u: Int) -> String? {
        switch u {
        case 0xE0, 0xE4: return "ctrl"
        case 0xE1, 0xE5: return "shift"
        case 0xE2, 0xE6: return "opt"
        case 0xE3, 0xE7: return "cmd"
        default: return nil
        }
    }
    static func mods(_ f: UIKeyModifierFlags) -> Set<String> {
        var s = Set<String>()
        if f.contains(.command) { s.insert("cmd") }
        if f.contains(.shift) { s.insert("shift") }
        if f.contains(.alternate) { s.insert("opt") }
        if f.contains(.control) { s.insert("ctrl") }
        return s
    }
}

final class Checklist: @unchecked Sendable {
    static let shared = Checklist()
    private let lock = NSLock()
    private(set) var combos: [Combo] = [
        Combo(name: "Cmd-Tab", mods: ["cmd"], key: 0x2B),
        Combo(name: "Cmd-Shift-Tab", mods: ["cmd", "shift"], key: 0x2B),
        Combo(name: "Cmd-Space", mods: ["cmd"], key: 0x2C),
        Combo(name: "Cmd-H", mods: ["cmd"], key: 0x0B),
        Combo(name: "Cmd-Q", mods: ["cmd"], key: 0x14),
        Combo(name: "Cmd-W", mods: ["cmd"], key: 0x1A),
        Combo(name: "Cmd-`", mods: ["cmd"], key: 0x35),
        Combo(name: "Cmd-Opt-D", mods: ["cmd", "opt"], key: 0x07),
        Combo(name: "Cmd-Shift-3", mods: ["cmd", "shift"], key: 0x20),
        Combo(name: "Cmd-Shift-4", mods: ["cmd", "shift"], key: 0x21),
        Combo(name: "Cmd-Shift-5", mods: ["cmd", "shift"], key: 0x22),
        Combo(name: "Ctrl-Up", mods: ["ctrl"], key: 0x52),
        Combo(name: "Ctrl-Left", mods: ["ctrl"], key: 0x50),
        Combo(name: "Ctrl-Right", mods: ["ctrl"], key: 0x4F),
        Combo(name: "Opt-Tab", mods: ["opt"], key: 0x2B),
        Combo(name: "Opt-Space", mods: ["opt"], key: 0x2C),
        Combo(name: "Opt-`", mods: ["opt"], key: 0x35),
        Combo(name: "Tab", mods: [], key: 0x2B),
        Combo(name: "Up", mods: [], key: 0x52),
        Combo(name: "Esc", mods: [], key: 0x29),
        Combo(name: "CapsLock", mods: [], key: 0x39),
    ]

    enum Source { case gc, uikit, keyCommand }

    func mark(mods: Set<String>, key: Int, source: Source) {
        lock.lock(); defer { lock.unlock() }
        for i in combos.indices where combos[i].key == key && combos[i].mods == mods {
            switch source {
            case .gc: combos[i].seenGC = true
            case .uikit: combos[i].seenUIKit = true
            case .keyCommand: combos[i].seenKeyCommand = true
            }
        }
    }

    func render() -> String {
        lock.lock(); defer { lock.unlock() }
        var out = "Combo          GC  UIKit KeyCmd\n"
        for c in combos {
            let pad = c.name.padding(toLength: 14, withPad: " ", startingAt: 0)
            out += "\(pad) \(c.seenGC ? "✓" : "·")   \(c.seenUIKit ? "✓" : "·")     \(c.seenKeyCommand ? "✓" : "·")\n"
        }
        return out
    }
}

// MARK: - App

/// Whether the app's main menu (iPadOS menu bar) is stripped. Main-thread only.
enum MenuLab { static var strip = false }

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Logs the whole main menu with key equivalents, then optionally removes it. Any Cmd combo that
    /// the menu owns (e.g. Cmd-Q Quit) is reclaimable by lain; combos not listed are owned by iPadOS.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main, let root = builder.menu(for: .root) else { return }
        Log.shared.add("MENU", "main menu rebuilt (strip=\(MenuLab.strip)), full tree in log file")
        dump(root, depth: 0)
        guard MenuLab.strip else { return }
        let extra: [UIMenu.Identifier] = [.quit, .close, .hide, .bringAllToFront, .minimizeAndZoom, .fullscreen]
        for id in root.children.compactMap({ ($0 as? UIMenu)?.identifier }) + extra { builder.remove(menu: id) }
        let left = builder.menu(for: .root)?.children.count ?? 0
        Log.shared.add("MENU", "stripped; \(left) top-level menus remain")
    }

    private func dump(_ element: UIMenuElement, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        switch element {
        case let menu as UIMenu:
            Log.shared.add("MENU", "\(pad)[\(menu.title)] \(menu.identifier.rawValue)", screen: false)
            menu.children.forEach { dump($0, depth: depth + 1) }
        case let command as UIKeyCommand:
            Log.shared.add("MENU", "\(pad)\(command.title)  ⌨ \(HID.mods(command.modifierFlags).sorted()) \((command.input ?? "").debugDescription)", screen: false)
        case let command as UICommand:
            Log.shared.add("MENU", "\(pad)\(command.title)", screen: false)
        case let action as UIAction:
            Log.shared.add("MENU", "\(pad)\(action.title) (action)", screen: false)
        default:
            Log.shared.add("MENU", "\(pad)\(type(of: element))", screen: false)
        }
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = LabViewController()
        window.makeKeyAndVisible()
        self.window = window
        UIApplication.shared.isIdleTimerDisabled = true
        let device = UIDevice.current
        Log.shared.add("DEVICE", "\(device.model) \(device.systemName) \(device.systemVersion)")
    }

    func sceneDidBecomeActive(_ scene: UIScene) { Log.shared.add("SCENE", "didBecomeActive") }
    func sceneWillResignActive(_ scene: UIScene) { Log.shared.add("SCENE", "willResignActive") }
    func sceneDidEnterBackground(_ scene: UIScene) { Log.shared.add("SCENE", "didEnterBackground") }
}

// MARK: - Lab view controller

final class LabViewController: UIViewController, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    private let inputQueue = DispatchQueue(label: "inputlab.input", qos: .userInteractive)
    private let statusLabel = UILabel()
    private let statsLabel = UILabel()
    private let checklistLabel = UILabel()
    private let logView = UITextView()
    private let cursor = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
    private var lockWanted = true
    private var heldGC = Set<Int>()        // HID usages held, per GCKeyboard (touched only on inputQueue)
    private var lockedPos = CGPoint(x: 400, y: 300)
    private var refreshLink: CADisplayLink?

    override var prefersPointerLocked: Bool { lockWanted }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setUpLabels()
        setUpGestures()
        view.addInteraction(UIPointerInteraction(delegate: self))
        cursor.backgroundColor = .systemRed
        cursor.layer.cornerRadius = 7
        cursor.isUserInteractionEnabled = false
        view.addSubview(cursor)

        NotificationCenter.default.addObserver(self, selector: #selector(lockChanged),
                                               name: UIPointerLockState.didChangeNotification, object: nil)
        for name: Notification.Name in [.GCMouseDidConnect, .GCMouseDidDisconnect, .GCMouseDidBecomeCurrent,
                                        .GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(gcChanged(_:)), name: name, object: nil)
        }
        GCMouse.mice().forEach(attach(mouse:))
        if let keyboard = GCKeyboard.coalesced { attach(keyboard: keyboard) }

        let link = CADisplayLink(target: self, selector: #selector(refresh))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15)
        link.add(to: .main, forMode: .common)
        refreshLink = link
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        setNeedsUpdateOfPrefersPointerLocked()
        logGeometry()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in self.logGeometry() }
    }

    private func logGeometry() {
        guard let scene = view.window?.windowScene else { return }
        let screen = scene.screen
        Log.shared.add("SCENE", "scene \(scene.coordinateSpace.bounds.size) screen \(screen.bounds.size) "
            + "native \(screen.nativeBounds.size) scale \(screen.nativeScale) maxFPS \(screen.maximumFramesPerSecond)")
    }

    // MARK: Layout

    private func setUpLabels() {
        let mono = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        for label in [statusLabel, statsLabel, checklistLabel] {
            label.font = mono
            label.textColor = .white
            label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }
        statusLabel.textColor = .systemYellow
        checklistLabel.textColor = .systemGreen
        logView.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .lightGray
        logView.backgroundColor = .clear
        logView.isEditable = false
        logView.isSelectable = false
        logView.isScrollEnabled = false
        logView.isUserInteractionEnabled = false
        logView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: checklistLabel.leadingAnchor, constant: -12),
            statsLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            statsLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            logView.topAnchor.constraint(equalTo: statsLabel.bottomAnchor, constant: 6),
            logView.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            logView.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            logView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            checklistLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            checklistLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            checklistLabel.widthAnchor.constraint(equalToConstant: 250),
        ])
    }

    @objc private func refresh() {
        let scene = view.window?.windowScene
        let locked = scene?.pointerLockState?.isLocked ?? false
        let mice = GCMouse.mice().map { $0.productCategory }.joined(separator: ",")
        let kb = GCKeyboard.coalesced != nil ? "yes" : "no"
        statusLabel.text = "lock wanted=\(lockWanted) granted=\(locked)   GCMouse=[\(mice)] GCKeyboard=\(kb)   "
            + "scene=\(Int(view.bounds.width))×\(Int(view.bounds.height))   menus stripped=\(MenuLab.strip)   "
            + "(Ctrl-Opt-Cmd- L lock, M menus, C clear)"
        statsLabel.text = Stats.shared.with { s in
            String(format: "GCMouse moves %d  Σdx %.1f Σdy %.1f  gap %.2f–%.2f ms | GC scroll %d Σx %.1f Σy %.1f | pan %d hover %d",
                   s.moveCount, s.moveDX, s.moveDY, s.minGapMs == 1e9 ? 0 : s.minGapMs, s.maxGapMs,
                   s.gcScrollCount, s.gcScrollX, s.gcScrollY, s.panCount, s.hoverCount)
        }
        checklistLabel.text = Checklist.shared.render()
        if let lines = Log.shared.takeIfDirty() { logView.text = lines.joined(separator: "\n") }
        if locked { cursor.center = lockedPos }
    }

    // MARK: Pointer lock

    @objc private func lockChanged() {
        let locked = view.window?.windowScene?.pointerLockState?.isLocked ?? false
        Log.shared.add("LOCK", "isLocked=\(locked) (wanted=\(lockWanted))")
    }

    private func toggleLock() {
        lockWanted.toggle()
        setNeedsUpdateOfPrefersPointerLocked()
        Log.shared.add("LOCK", "requested prefersPointerLocked=\(lockWanted)")
    }

    // MARK: GameController

    @objc private func gcChanged(_ note: Notification) {
        Log.shared.add("GC", "\(note.name.rawValue) \(String(describing: note.object.map { type(of: $0) }))")
        if let mouse = note.object as? GCMouse, note.name == .GCMouseDidConnect { attach(mouse: mouse) }
        if let keyboard = note.object as? GCKeyboard, note.name == .GCKeyboardDidConnect { attach(keyboard: keyboard) }
    }

    private func attach(mouse: GCMouse) {
        mouse.handlerQueue = inputQueue
        guard let input = mouse.mouseInput else { return }
        Log.shared.add("GC", "mouse attached: \(mouse.productCategory) vendor=\(mouse.vendorName ?? "?") "
            + "aux=\(input.auxiliaryButtons?.count ?? 0) middle=\(input.middleButton != nil)")
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            Stats.shared.recordMove(dx, dy)
            Log.shared.add("GCMOVE", String(format: "dx %.2f dy %.2f", dx, dy), screen: false)
            DispatchQueue.main.async {
                guard let self else { return }
                let b = self.view.bounds
                self.lockedPos.x = min(max(self.lockedPos.x + CGFloat(dx), 0), b.width)
                self.lockedPos.y = min(max(self.lockedPos.y - CGFloat(dy), 0), b.height)  // GC y is up-positive
            }
        }
        let buttons: [(String, GCControllerButtonInput?)] = [
            ("left", input.leftButton), ("right", input.rightButton), ("middle", input.middleButton),
        ] + (input.auxiliaryButtons ?? []).enumerated().map { ("aux\($0.offset)", $0.element) }
        for (name, button) in buttons {
            button?.pressedChangedHandler = { _, _, pressed in
                Log.shared.add("GCBTN", "\(name) \(pressed ? "DOWN" : "up")")
            }
        }
        input.scroll.valueChangedHandler = { _, x, y in
            Stats.shared.with { s in s.gcScrollCount += 1; s.gcScrollX += x; s.gcScrollY += y }
            Log.shared.add("GCSCRL", String(format: "x %.2f y %.2f", x, y), screen: false)
        }
    }

    private func attach(keyboard: GCKeyboard) {
        keyboard.handlerQueue = inputQueue
        Log.shared.add("GC", "keyboard attached: \(keyboard.vendorName ?? "?")")
        keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard let self else { return }
            let usage = Int(keyCode.rawValue)
            if pressed { self.heldGC.insert(usage) } else { self.heldGC.remove(usage) }
            let mods = Set(self.heldGC.compactMap(HID.modifier))
            Log.shared.add("GCKEY", "\(HID.name(usage)) \(pressed ? "DOWN" : "up") mods=\(mods.sorted())")
            guard pressed, HID.modifier(usage) == nil else { return }
            Checklist.shared.mark(mods: mods, key: usage, source: .gc)
            if mods == ["ctrl", "opt", "cmd"] {
                if usage == 0x0F { DispatchQueue.main.async { self.toggleLock() } }                 // L
                if usage == 0x06 { Log.shared.clearScreen() }                                         // C
                if usage == 0x10 {                                                                     // M
                    DispatchQueue.main.async {
                        MenuLab.strip.toggle()
                        UIMenuSystem.main.setNeedsRebuild()
                    }
                }
            }
        }
    }

    // MARK: UIKit presses and key commands

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { logPresses(presses, event, "DOWN") }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { logPresses(presses, event, "up") }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { logPresses(presses, event, "CANCEL") }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    private func logPresses(_ presses: Set<UIPress>, _ event: UIPressesEvent?, _ phase: String) {
        let lagMs = event.map { (CACurrentMediaTime() - $0.timestamp) * 1000 } ?? -1
        for press in presses {
            guard let key = press.key else { continue }
            let usage = key.keyCode.rawValue
            let mods = HID.mods(key.modifierFlags)
            Log.shared.add("UIPRESS", "\(HID.name(usage)) \(phase) mods=\(mods.sorted()) chars=\(key.charactersIgnoringModifiers.debugDescription) "
                + String(format: "lag %.1f ms", lagMs))
            if phase == "DOWN" { Checklist.shared.mark(mods: mods, key: usage, source: .uikit) }
        }
        // Deliberately not calling super: we want to see what reaches us, not let UIKit act on it.
    }

    override var keyCommands: [UIKeyCommand]? {
        let specs: [(String, UIKeyModifierFlags)] = [
            ("\t", []), ("\t", .shift), ("\t", .command), ("\t", [.command, .shift]), ("\t", .alternate),
            (" ", .command), (" ", .alternate), ("h", .command), ("q", .command), ("w", .command), ("`", .command),
            ("d", [.command, .alternate]), ("3", [.command, .shift]), ("4", [.command, .shift]), ("5", [.command, .shift]),
            (UIKeyCommand.inputUpArrow, []), (UIKeyCommand.inputDownArrow, []), (UIKeyCommand.inputLeftArrow, []),
            (UIKeyCommand.inputRightArrow, []), (UIKeyCommand.inputUpArrow, .control),
            (UIKeyCommand.inputLeftArrow, .control), (UIKeyCommand.inputRightArrow, .control), (UIKeyCommand.inputEscape, []),
        ]
        return specs.map { input, mods in
            let command = UIKeyCommand(input: input, modifierFlags: mods, action: #selector(keyCommandFired(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func keyCommandFired(_ command: UIKeyCommand) {
        let input = command.input ?? "?"
        Log.shared.add("KEYCMD", "\(input.debugDescription) mods=\(HID.mods(command.modifierFlags).sorted())")
        let usage: Int? = switch input {
        case "\t": 0x2B
        case " ": 0x2C
        case "h": 0x0B
        case "q": 0x14
        case "w": 0x1A
        case "`": 0x35
        case "d": 0x07
        case "3": 0x20
        case "4": 0x21
        case "5": 0x22
        case UIKeyCommand.inputUpArrow: 0x52
        case UIKeyCommand.inputLeftArrow: 0x50
        case UIKeyCommand.inputRightArrow: 0x4F
        case UIKeyCommand.inputEscape: 0x29
        default: nil
        }
        if let usage { Checklist.shared.mark(mods: HID.mods(command.modifierFlags), key: usage, source: .keyCommand) }
    }

    // MARK: Gesture recognizers

    private func setUpGestures() {
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []            // scroll events only, not touch drags
        view.addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotate(_:)))
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        let primary = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        primary.buttonMaskRequired = .primary
        primary.name = "primary"
        let secondary = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.name = "secondary"
        let touchTap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        touchTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        touchTap.name = "finger"
        for recognizer in [scroll, pinch, rotate, hover, primary, secondary, touchTap] as [UIGestureRecognizer] {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func name(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .began: "began"
        case .changed: "changed"
        case .ended: "ENDED"
        case .cancelled: "CANCELLED"
        case .failed: "failed"
        case .possible: "possible"
        @unknown default: "?"
        }
    }

    @objc private func scrollPan(_ g: UIPanGestureRecognizer) {
        Stats.shared.with { $0.panCount += 1 }
        let t = g.translation(in: view), v = g.velocity(in: view)
        Log.shared.add("SCROLL", String(format: "%@ t(%.1f, %.1f) v(%.0f, %.0f) touches %d", name(g.state),
                                        t.x, t.y, v.x, v.y, g.numberOfTouches), screen: g.state != .changed)
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        Log.shared.add("PINCH", String(format: "%@ scale %.3f v %.2f", name(g.state), g.scale, g.velocity),
                       screen: g.state != .changed)
    }

    @objc private func rotate(_ g: UIRotationGestureRecognizer) {
        Log.shared.add("ROTATE", String(format: "%@ rot %.3f v %.2f", name(g.state), g.rotation, g.velocity),
                       screen: g.state != .changed)
    }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        Stats.shared.with { $0.hoverCount += 1 }
        let p = g.location(in: view)
        if !(view.window?.windowScene?.pointerLockState?.isLocked ?? false) { cursor.center = p }
        if g.state != .changed { Log.shared.add("HOVER", "\(name(g.state)) at (\(Int(p.x)), \(Int(p.y)))") }
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        let locked = view.window?.windowScene?.pointerLockState?.isLocked ?? false
        Log.shared.add("TAP", "\(g.name ?? "?") tap (locked=\(locked)) at \(g.location(in: view)) \(name(g.state))")
    }

    // MARK: Raw touches (indirect pointer clicks arrive here too)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { logTouches(touches, event, "began") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { logTouches(touches, event, "ended") }

    private func logTouches(_ touches: Set<UITouch>, _ event: UIEvent?, _ phase: String) {
        for touch in touches {
            let type = switch touch.type {
            case .direct: "direct"
            case .indirect: "indirect"
            case .pencil: "pencil"
            case .indirectPointer: "indirectPointer"
            @unknown default: "?"
            }
            Log.shared.add("TOUCH", "\(type) \(phase) buttonMask=\(event?.buttonMask.rawValue ?? 0) tapCount=\(touch.tapCount)")
        }
    }

    // MARK: Pointer interaction — hide the system pointer so only our red dot shows

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }
}
