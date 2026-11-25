import AppKit
import LainClientCore
import LainTransport

/// Native macOS modal sheets for pairing a new host with a `lain1:...` pairing code and managing saved hosts.
@MainActor
enum PairingDialogs {
    /// Presents a sheet asking the user to paste a `lain1:...` pairing code from `LainHost` (Mac) or
    /// `lain pair-code` (Linux). Calls `onPair` if a valid code is submitted.
    static func presentPairHost(on window: NSWindow, localHostId: String?,
                                onPair: @escaping (PairingCode) throws -> Void) {
        let alert = NSAlert()
        alert.messageText = "Pair a Host"
        alert.informativeText = "In LainHost on a Mac, choose Copy Pairing Code from the menu bar.\nOn Linux, run `lain pair-code` in a terminal."
        alert.alertStyle = .informational
        let pairButton = alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 82))
        let field = NSTextField(frame: NSRect(x: 0, y: 52, width: 326, height: 24))
        field.placeholderString = "lain1:…"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle

        let pasteButton = NSButton(title: "Paste", target: nil, action: nil)
        pasteButton.bezelStyle = .rounded
        pasteButton.frame = NSRect(x: 334, y: 49, width: 86, height: 28)

        let status = NSTextField(wrappingLabelWithString: "")
        status.frame = NSRect(x: 0, y: 0, width: 420, height: 44)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor

        container.addSubview(field)
        container.addSubview(pasteButton)
        container.addSubview(status)
        alert.accessoryView = container

        // Auto-fill if the clipboard already holds a valid pairing code.
        if let clip = NSPasteboard.general.string(forType: .string),
           (try? PairingCode.decode(clip)) != nil {
            field.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let validator = PairingFieldValidator(field: field, status: status, pairButton: pairButton,
                                              localHostId: localHostId)
        field.delegate = validator
        pasteButton.target = validator
        pasteButton.action = #selector(PairingFieldValidator.pasteFromClipboard)
        validator.validate()

        alert.beginSheetModal(for: window) { response in
            // Keep validator alive until sheet closes.
            withExtendedLifetime(validator) {
                guard response == .alertFirstButtonReturn else { return }
                do {
                    let code = try PairingCode.decode(field.stringValue)
                    try onPair(code)
                } catch {
                    let err = NSAlert()
                    err.messageText = "Couldn't Pair Host"
                    err.informativeText = "\(error)"
                    err.alertStyle = .warning
                    err.beginSheetModal(for: window)
                }
            }
        }
    }

    /// Presents a sheet listing saved hosts with a Forget button for each.
    static func presentManageHosts(on window: NSWindow, hosts: [ClientSession.SavedHost],
                                   onForget: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Paired Hosts"
        if hosts.isEmpty {
            alert.informativeText = "No hosts are paired yet. Choose Connection › Pair Host… to add one."
            alert.addButton(withTitle: "Done")
            alert.beginSheetModal(for: window)
            return
        }
        alert.informativeText = "Removing a host deletes its saved Wi-Fi key from this Mac's Keychain."
        alert.addButton(withTitle: "Done")

        let rowHeight: CGFloat = 32
        let height = min(max(CGFloat(hosts.count) * rowHeight, rowHeight), 240)
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: height))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        var targets: [ForgetHostTarget] = []
        for host in hosts {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8

            let stateText = host.isCurrent ? " (connected)" : (host.isSeen ? " (in reach)" : "")
            let label = NSTextField(labelWithString: "\(host.name)\(stateText)")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let button = NSButton(title: "Forget", target: nil, action: nil)
            button.bezelStyle = .rounded
            let target = ForgetHostTarget(hostId: host.id, row: row, button: button, onForget: onForget)
            button.target = target
            button.action = #selector(ForgetHostTarget.forget)
            targets.append(target)

            row.addArrangedSubview(label)
            row.addArrangedSubview(button)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }
        alert.accessoryView = stack

        alert.beginSheetModal(for: window) { _ in
            withExtendedLifetime(targets) {}
        }
    }
}

@MainActor
private final class PairingFieldValidator: NSObject, NSTextFieldDelegate {
    private let field: NSTextField
    private let status: NSTextField
    private let pairButton: NSButton
    private let localHostId: String?

    init(field: NSTextField, status: NSTextField, pairButton: NSButton, localHostId: String?) {
        self.field = field
        self.status = status
        self.pairButton = pairButton
        self.localHostId = localHostId
    }

    func controlTextDidChange(_ obj: Notification) {
        validate()
    }

    @objc func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        field.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        validate()
    }

    func validate() {
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            status.textColor = .secondaryLabelColor
            status.stringValue = "Paste a lain1:… code from the host."
            pairButton.isEnabled = false
            return
        }
        do {
            let code = try PairingCode.decode(raw)
            if let localHostId, code.hostId == localHostId {
                status.textColor = .systemOrange
                status.stringValue = "Warning: this code belongs to LainHost on this same Mac (connecting to yourself will mirror recursively)."
                pairButton.isEnabled = true
                return
            }
            let displayName = code.hostName.isEmpty ? String(code.hostId.prefix(8)) : code.hostName
            status.textColor = .systemGreen
            status.stringValue = "Ready to pair with \(displayName) (\(code.hostId.prefix(8))…)"
            pairButton.isEnabled = true
        } catch {
            status.textColor = .systemRed
            status.stringValue = "Invalid code: \(error)"
            pairButton.isEnabled = false
        }
    }
}

@MainActor
private final class ForgetHostTarget: NSObject {
    private let hostId: String
    private weak var row: NSView?
    private weak var button: NSButton?
    private let onForget: (String) -> Void

    init(hostId: String, row: NSView, button: NSButton, onForget: @escaping (String) -> Void) {
        self.hostId = hostId
        self.row = row
        self.button = button
        self.onForget = onForget
    }

    @objc func forget() {
        button?.isEnabled = false
        button?.title = "Forgotten"
        row?.alphaValue = 0.5
        onForget(hostId)
    }
}
