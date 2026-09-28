# lain

Mac ↔ iPad Pro low-latency remote control: the iPad (with Magic Keyboard) is the Mac's display, keyboard, trackpad and speakers. USB-C via usbmux first; peer-to-peer Wi-Fi later; internet out of scope.

**Read `docs/ARCHITECTURE.md` before any design or implementation work.** It is the authoritative spec: invariants (§3), workflow and testing (§12.1–12.2), decisions (§14), milestones (§10), open spikes (§11) and measurements (§13). `docs/PadLink-Design.md` is the superseded exploratory doc — background only.

- Targets: macOS 27 / iPadOS 27 only; Xcode 27; Swift 6 language mode.
- **Xcode workflow reference: `docs/XCODE-WORKFLOW.md`** — what goes through MCP, what's manual, how tests are organized, with the verified reasons. Follow it.
- **Project structure lives only in `project.yml`** (targets, schemes, tests, package links, signing, entitlements, Info.plist). Regenerate with `Scripts/bootstrap.sh`. Never hand-edit the `.xcodeproj`, never ask the user to click through Xcode settings, and never use Xcode MCP editing tools (UpdateTargetBuildSetting, AddEntitlement, AddInfoPlist, XcodeNewTarget, XcodeNewProject).
- Use the `xcode` MCP server for build/run/console/tests/debugger/docs/device interaction (§12.1). If a run fails, stop after one attempt and ask whether the iPad is locked or a popup is showing.
- Tests: logic and pipelines in `LainKit` via `swift test`; hosted/UI tests declared in `project.yml` (§12.2).
- Run anything slower than ~30 s in the background and report progress.
- Private API only inside `*Private` modules via one wrapper each; log it in ARCHITECTURE.md §14.
- Sign with team `8DWR7MSCR6`, never ad hoc (TCC grants reset otherwise).
- Record every spike result and measurement in ARCHITECTURE.md §11/§13, and update the spec when a decision changes.
