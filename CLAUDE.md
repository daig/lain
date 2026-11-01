# lain

Mac ↔ iPad Pro low-latency remote control: the iPad (with Magic Keyboard) is the Mac's display, keyboard, trackpad and speakers. USB-C via usbmux first; peer-to-peer Wi-Fi later; internet out of scope.

**Start every session by reading `docs/STATUS.md`** (current state, next steps, working agreements). **Read `docs/ARCHITECTURE.md` before any design or implementation work.** It is the authoritative spec: invariants (§3), workflow and testing (§12.1–12.2), decisions (§14), milestones (§10), open spikes (§11) and measurements (§13). `docs/PadLink-Design.md` is the superseded exploratory doc — background only.

- Targets: macOS 27 / iPadOS 27 only; Xcode 27; Swift 6 language mode.
- **Xcode workflow reference: `docs/XCODE-WORKFLOW.md`** — what goes through MCP, what's manual, how tests are organized, with the verified reasons. Follow it.
- **Project structure lives only in `project.yml`** (targets, schemes, tests, package links, signing, entitlements, Info.plist). Regenerate with `Scripts/bootstrap.sh`. Never hand-edit the `.xcodeproj`, never ask the user to click through Xcode settings, and never use Xcode MCP editing tools (UpdateTargetBuildSetting, AddEntitlement, AddInfoPlist, XcodeNewTarget, XcodeNewProject).
- Use the `xcode` MCP server for build/run/console/tests/debugger/docs/device interaction (§12.1). If a run fails, stop after one attempt and ask whether the iPad is locked or a popup is showing.
- Tests: logic and pipelines in `LainKit` via `swift test`; hosted/UI tests declared in `project.yml` (§12.2).
- Run anything slower than ~30 s in the background and report progress.
- Private API only inside `*Private` modules via one wrapper each; log it in ARCHITECTURE.md §14.
- Sign with team `8DWR7MSCR6`, never ad hoc (TCC grants reset otherwise).
- Record every spike result and measurement in ARCHITECTURE.md §11/§13, and update the spec when a decision changes.
- Update `docs/STATUS.md` at the end of each session or milestone.

**Linux host (Rust):** the `docs/` files above are kept local on the Mac and are not part of this source distribution; on the Linux machine they don't exist and won't. There, the port's own spec, decisions, architecture, spikes and status are in `docs/LINUX-HOST.md`, and the wave-by-wave build plan with per-crate subagent briefs is in `docs/LINUX-HOST-PLAN.md` (both local: `/docs/` is gitignored); read them at the start of every Linux session, and update the status at the end. The only hard requirement is wire compatibility with the iPad client in this tree: the Swift sources are the protocol reference, and `Packages/LainKit/Tests/LainProtocolTests/GoldenBytes.swift` is the conformance fixture. Decisions L1–L8: a Rust core behind bridge traits, in a Cargo workspace at `rust/`; GNOME/Wayland via Mutter D-Bus; HEVC 4:2:0 on the AMD iGPU, never the NVIDIA GPUs (reserved for other work), so **no GStreamer** (loading its plugins initialises CUDA on them): the `pipewire` crate plus libva directly, on the AMD render node chosen by PCI vendor; Mutter's `ApplyMonitorsConfig` **method 1 only** (method 2 pops up GNOME's revert dialog); Ethernet primary, Wi-Fi supported in development; protocol conformance tested against the Swift tree's golden bytes and digests.
