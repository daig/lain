import AppKit
import CoreGraphics
import LainHostCore
import SwiftUI

/// Snapshot of every macOS permission `LainHost` needs to stream video, inject input, and advertise over LAN.
struct HostPermissionStatus: Sendable, Equatable {
    enum LocalNetwork: Sendable, Equatable {
        case allowed
        case denied
        case checking
    }

    var accessibility: Bool
    var screenRecording: Bool
    var localNetwork: LocalNetwork
    var loginAgent: LoginAgent.State

    /// Required permissions that are currently missing or blocked.
    var missingNames: [String] {
        var names: [String] = []
        if !accessibility { names.append("Accessibility") }
        if !screenRecording { names.append("Screen Recording") }
        if localNetwork == .denied { names.append("Local Network") }
        if loginAgent == .requiresApproval { names.append("Start at Login") }
        return names
    }

    var hasMissing: Bool { !missingNames.isEmpty }

    var summaryBadge: String {
        let count = missingNames.count
        return count == 1 ? "1 missing" : "\(count) missing"
    }
}

/// Deep links directly into the exact System Settings Privacy & Security panes.
@MainActor
enum HostPermissionSettings {
    static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenRecordingURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let localNetworkURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    static func openAccessibility() {
        _ = InputInjector.requestAccess()
        NSWorkspace.shared.open(accessibilityURL)
    }

    static func openScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(screenRecordingURL)
    }

    static func openLocalNetwork() {
        NSWorkspace.shared.open(localNetworkURL)
    }

    static func openLoginItems() {
        LoginAgent.openLoginItemsSettings()
    }
}

/// Manages a single native macOS window for reviewing and granting `LainHost` permissions.
/// Uses an explicit `NSWindow` so it reliably comes to the front even though `LainHost` is an `LSUIElement` app.
@MainActor
final class PermissionsWindowController {
    private var window: NSWindow?

    func show(host: HostController) {
        if let existing = window {
            NSApplication.shared.activate()
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let content = PermissionsView(host: host) { [weak self] in
            self?.window?.close()
        }
        let hosting = NSHostingController(rootView: content)
        let win = NSWindow(contentViewController: hosting)
        win.title = "lain Permissions"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("LainPermissionsWindow")
        self.window = win

        NSApplication.shared.activate()
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
    }
}

/// Interactive permissions checklist window shown automatically on startup when any required
/// permission is missing, and always reachable from the lain menu bar tray.
struct PermissionsView: View {
    let host: HostController
    let onClose: () -> Void

    var body: some View {
        let perms = host.permissions
        VStack(alignment: .leading, spacing: 18) {
            header(perms: perms)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                PermissionRow(
                    title: "Accessibility",
                    subtitle: "Lets lain move the mouse and type from your iPad, Mac, or Apple TV.",
                    state: perms.accessibility ? .granted : .missing,
                    buttonTitle: perms.accessibility ? "Open Settings…" : "Allow Accessibility…",
                    action: { host.requestAccessibility() }
                )

                PermissionRow(
                    title: "Screen Recording",
                    subtitle: "Lets lain capture and stream this Mac's display.",
                    state: perms.screenRecording ? .granted : .missing,
                    buttonTitle: perms.screenRecording ? "Open Settings…" : "Allow Screen Recording…",
                    action: { host.requestScreenRecording() }
                )

                PermissionRow(
                    title: "Local Network",
                    subtitle: "Lets lain advertise and connect over Wi-Fi / LAN.",
                    state: localNetworkState(perms.localNetwork),
                    buttonTitle: "Open Settings…",
                    action: { host.openLocalNetworkSettings() }
                )

                if perms.loginAgent == .requiresApproval {
                    PermissionRow(
                        title: "Start at Login",
                        subtitle: "Lets lain launch automatically in the background.",
                        state: .missing,
                        buttonTitle: "Open Login Items…",
                        action: { HostPermissionSettings.openLoginItems() }
                    )
                }
            }

            if !perms.accessibility || !perms.screenRecording {
                Text("Tip: If LainHost is already toggled on after an update, turn it off and back on in System Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if perms.hasMissing {
                    Button("Request All Missing…") {
                        host.requestAllMissingPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Label("All required permissions are active.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                }
                Spacer()
                Button(perms.hasMissing ? "Later" : "Done") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    @ViewBuilder
    private func header(perms: HostPermissionStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: perms.hasMissing ? "lock.shield" : "checkmark.shield.fill")
                .font(.system(size: 32))
                .foregroundStyle(perms.hasMissing ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(perms.hasMissing ? "Finish Setting Up lain" : "lain Permissions Ready")
                    .font(.title3.weight(.semibold))
                Text(perms.hasMissing
                     ? "Grant the permissions below so connected devices can view and control this Mac. Status updates automatically."
                     : "This Mac is ready to stream video and accept input from paired devices.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func localNetworkState(_ state: HostPermissionStatus.LocalNetwork) -> PermissionRow.State {
        switch state {
        case .allowed: .granted
        case .denied: .missing
        case .checking: .checking
        }
    }
}

private struct PermissionRow: View {
    enum State {
        case granted
        case missing
        case checking
    }

    let title: String
    let subtitle: String
    let state: State
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    statusBadge
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(buttonTitle, action: action)
                .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .missing:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
        case .checking:
            Image(systemName: "clock.circle")
                .foregroundStyle(.secondary)
                .font(.title3)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .granted:
            Text("Granted")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .missing:
            Text("Required")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .checking:
            Text("Checking…")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
