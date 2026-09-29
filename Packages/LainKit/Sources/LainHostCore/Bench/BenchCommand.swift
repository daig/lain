#if os(macOS)
import AppKit
import Foundation

/// `LainHost --bench <name>` (D16): benchmarks run inside the host app so macOS attributes permissions
/// to it, not to the terminal. Output goes to stdout; the process exits when the bench finishes.
public enum BenchCommand {
    public static let names = ["usbmux", "replug", "inject", "vdisplay"]

    /// The bench requested on the command line, if any.
    public static func requested(in arguments: [String] = CommandLine.arguments) -> String? {
        guard let i = arguments.firstIndex(of: "--bench") else { return nil }
        return i + 1 < arguments.count ? arguments[i + 1] : ""
    }

    public static func run(_ name: String) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even when piped, so progress shows live
        Task {
            do {
                switch name {
                case "usbmux":
                    // Persistent pairing: the first run pairs over USB, later runs authenticate.
                    print(try await USBMuxBench.run(secrets: KeychainSecretStore()))
                case "vdisplay":
                    exit(await VirtualDisplayBench.run())
                case "inject":
                    exit(await InjectBench.run())
                case "replug":
                    try await ReplugBench.run()
                default:
                    print("unknown bench '\(name)'; available: \(names.joined(separator: ", "))")
                    exit(2)
                }
                exit(0)
            } catch {
                print("bench \(name) failed: \(error)")
                exit(1)
            }
        }
        // An AppKit run loop (not dispatchMain) so benches can show windows and Core Animation runs.
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
        exit(0)
    }
}
#endif
