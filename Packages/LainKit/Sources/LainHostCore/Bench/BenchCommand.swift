#if os(macOS)
import AppKit
import Foundation

/// `LainHost --bench <name>` (D16): benchmarks run inside the host app so macOS attributes permissions
/// to it, not to the terminal. Output goes to stdout; the process exits when the bench finishes.
public enum BenchCommand {
    public static let names = ["usbmux", "replug", "inject", "vdisplay", "headless", "vdisplay-identity", "wifi"]

    /// The bench requested on the command line, if any.
    public static func requested(in arguments: [String] = CommandLine.arguments) -> String? {
        guard let i = arguments.firstIndex(of: "--bench") else { return nil }
        return i + 1 < arguments.count ? arguments[i + 1] : ""
    }

    /// The bench's own arguments: the words after its name, up to the next option (a negative number
    /// is kept, for the bench to refuse): `--bench wifi awdl 180` → ["awdl", "180"].
    public static func arguments(in arguments: [String] = CommandLine.arguments) -> [String] {
        guard let i = arguments.firstIndex(of: "--bench"), i + 2 < arguments.count else { return [] }
        return Array(arguments[(i + 2)...].prefix { !$0.hasPrefix("-") || Double($0) != nil })
    }

    public static func run(_ name: String) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even when piped, so progress shows live
        Task {
            do {
                switch name {
                case "usbmux":
                    // Persistent pairing: the first run pairs over USB, later runs authenticate.
                    print(try await USBMuxBench.run(secrets: KeychainSecretStore()))
                case "vdisplay-identity":
                    exit(await DisplayIdentityBench.run())
                case "headless":
                    exit(await HeadlessBench.run())
                case "vdisplay":
                    exit(await VirtualDisplayBench.run())
                case "inject":
                    exit(await InjectBench.run())
                case "replug":
                    try await ReplugBench.run()
                case "wifi":
                    // `wifi [any|awdl|lan] [seconds]`, from Terminal as the app's binary (S9).
                    exit(await WiFiBench.main(arguments: arguments()))
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
