#if os(macOS)
import Foundation

/// `LainHost --bench <name>` (D16): benchmarks run inside the host app so macOS attributes permissions
/// to it, not to the terminal. Output goes to stdout; the process exits when the bench finishes.
public enum BenchCommand {
    public static let names = ["usbmux"]

    /// The bench requested on the command line, if any.
    public static func requested(in arguments: [String] = CommandLine.arguments) -> String? {
        guard let i = arguments.firstIndex(of: "--bench") else { return nil }
        return i + 1 < arguments.count ? arguments[i + 1] : ""
    }

    public static func run(_ name: String) -> Never {
        Task {
            do {
                switch name {
                case "usbmux":
                    print(try await USBMuxBench.run())
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
        dispatchMain()
    }
}
#endif
