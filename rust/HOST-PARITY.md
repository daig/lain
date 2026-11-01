# Host parity: what the Linux host has that the Mac host and the client still need

Written 2026-11-01, after the Linux host's bring-up with a real iPad (iPad16,6, `main` at the time of writing).
The Linux host (`rust/`, `lain-hostd`) is now ahead of the Swift Mac host in a few behaviours the developer asked
for while using it. This note lists them, and the client changes they depend on, so the Mac side can catch up.

## Protocol

- Both hosts and the client must run **protocol v3–v4** (negotiated versions, `HostSetup`): `main` since
  `protocol-versioning` (`58aec59`) was merged. A v2 (pre-negotiation) client or host is refused by design ("update
  it"). Rebuild the Mac host *and* the iPad client from `main` together.
- Sections 1–4 change nothing on the wire. **Protocol v5** (2026-11-01, `host-parity`) adds `StatsRequest`
  (0x10, iPad → host: send `HostStats` every N ms, 0 stops) and `HostStats` (0x11, host → iPad: encode p50/p95,
  ack RTT, frames captured/encoded/sent, dropped before encode, in flight and peak, keyframes, refinements,
  bits per second), behind `ProtocolFeature.hostStats`, for the iPad's system-key overlay (§6). The Swift
  window is now **v4–v5** (the floor rose to 4; v3's golden bytes are gone). **Linux:** `lain-proto`'s
  conformance tests read `GoldenBytes.swift` and fail until the crate has the two messages and the [4, 5]
  window (or keeps [3, 4] and only skips v5 in the golden check). The host doesn't have to send stats: an
  iPad on v5 just shows "waiting for the Mac…" for a v4 host, and nothing breaks.

## 1. Display keep-alive (Linux: done; Mac host: done, not yet on hardware)

When the iPad's app leaves the screen (an app switch), iPadOS drops lain's connections at once. The Mac host then
removes its virtual display, so windows jump to another display and don't come back, and the return rebuilds
everything.

- **Linux:** `lain-host`'s `DisplayKeeper` keeps the display for `keep_alive_seconds` (default 30, 0–600) after
  a session whose link went away. The next session of the same size gets the *same* display back (windows stay
  put; the picture is back about 35 ms after the link). Capture stopped on the desktop, another size, the timeout,
  stopping the host remove it. Video stops while kept; input and power are released as usual.
  Code: `rust/crates/lain-host/src/keeper.rs`, `tests/keepalive.rs`.
- **Mac host (`host-parity`, 2026-11-01):** `DisplayKeeper` holds the `CGVirtualDisplay` for
  `displayKeepAliveSeconds` (default 30; Off, 10 s – 5 min in the menu) after a pipeline is stopped (link gone,
  takeover); the next session's `VirtualStreamedDisplayProvider` takes it back if its geometry (`keeperKey`:
  size and scale) matches and the display is still active. A capture failure removes it; quitting removes it.
  Code: `LainHostCore/Display/DisplayKeeper.swift`, `Video/StreamedDisplay.swift`; tests `DisplayKeeperTests`,
  `M3EndToEndTests.aSessionsEndKeepsItsDisplayForTheNext`.

## 2. Resume after the OS stops screen sharing (Linux: done; Mac host: done, not yet on hardware)

GNOME's top-bar "Stop sharing" ends lain's display; lain then resumes by itself (closes the link, the iPad
reconnects into a fresh session), at most once per 10 s; `resume_after_stop` (on), `lain resume` by hand.
Code: `lain-host` `HostSession::resume_video`, `tests/resume.rs`.

Mac host: macOS's own "Stop" (the screen-recording indicator) ends lain's `SCStream` with `userStopped`; the
display itself stays. The session goes input only, keeps the display (§1), and with **Resume Video After Stop**
(on) closes the link 1 s later, at most once per 10 s, so the iPad reconnects onto the same display; **Resume
Video** in the menu does it by hand. Code: `HostSession.resumeAfterStop`, `resumeVideo`; test
`M3EndToEndTests.captureStoppedByTheUserResumesOnceOnTheKeptDisplay`.

## 3. Settings from the host itself (Linux: done; Mac host: done, not yet on hardware)

Linux: `lain` CLI, a tray menu and the D-Bus interface `dev.sub.lain.Host1`, each written to `config.toml`:
scale (1–3; the closest the desktop supports is applied, live), keep-alive (live), Wi-Fi on/off (live),
resume-after-stop (live), Start at login, bitrate (next start). Mac host: the menu now has Display Scale, Keep Display After Disconnect, Resume Video After Stop and Right
Option Is the System Key (`HostPreferences`, in the app's defaults). Scale presets 1.5–2.5 pixels per point
(2 = 1376×1032 pt); a scale other than 2 renders at 2× of its points and capture scales that to the panel's
2752×2064 (or streams the smaller backing size, above 2). Scale and system key reconnect the live session to
apply; keep-alive applies to the next display kept.

Note on scale: Linux makes lain's display at 2× by default, as the Mac host does (1376×1032 points on a 13" iPad
Pro). GNOME draws its interface larger than macOS at the same scale, which is why Linux needed the setting first.

## 4. Keyboard: Right Option is the system key (Linux host: done; client and Mac host: to do)

iPadOS keeps some Command shortcuts (Cmd-Tab, Cmd-Space, Cmd-H, Cmd-Q, Cmd-`, Cmd-Shift-3/4) and every three- and
four-finger trackpad swipe for itself; they never reach the app. The developer's design: **Right Option is lain's
system key**, standing in for what iPadOS keeps, the same physical keys on both hosts. Left Option is a plain
Option key everywhere.

| You press | Mac host should do | Linux host does |
|---|---|---|
| Right Opt + Tab / ` | Cmd+Tab / Cmd+` | Alt+Tab / Alt+` |
| Right Opt + Space | Cmd+Space (Spotlight) | the overview, with search |
| Right Opt + H / Q | Cmd+H / Cmd+Q | Super+H (minimize) / Ctrl+Q |
| Right Opt + any other key | Cmd + that key | Ctrl + that key |
| Right Opt + Up | Ctrl+Up: Mission Control | the overview (Super tap) |
| Right Opt + Down | Ctrl+Down: App Exposé | the app grid (Super+A) |
| Right Opt + Left / Right | Ctrl+Left/Right: previous / next Space | Ctrl+Alt+Left/Right: workspace |
| Right Opt tap, alone | Mission Control | the overview |

Everything else is as labelled: Command, Control, Option, Shift. On Linux, Command and Control are both Ctrl (Mac
shortcuts in apps, terminal habits in terminals) and Option is Alt.

What is where today:

- **Client (`LainInput/RemapTable.swift`, `KeyboardProcessor`): done** (`host-parity`): the remap matches Right
  Option only (`RemapEntry.sourceKeys`), so Left Option keeps typing accents and Opt-Space, Opt-H… reach the host
  as themselves. The host sees Right Option itself (as `0xE6`) for the arrows and the tap.
- **Tap length:** a release is a tap only within 300 ms of the press (Mac: `SystemKey.tapMaxNs`). The iPad shows
  its overlay after 350 ms held alone (§6), so a hold that showed it never opens Mission Control / the overview
  on release. **Linux should do the same.**
- **Linux host (`lain-input`, `InputConfig::system_key`, on):** does the right-hand column, telling Right from Left
  Option by their own key events. The Cmd+Space and Cmd+H rows also work from the client's remap today.
  Code: `rust/crates/lain-input/src/router.rs`, `tests/router.rs` ("the system key").
- **Mac host (done, not yet on hardware):** `SystemKey` (in `HostInputRouter`) does the middle column itself:
  Right Option never reaches the Mac; held with a key it is Command (Left Command pressed, held while Right
  Option is, so Tab cycles the switcher); with the arrows Ctrl(+fn)+arrow chords; tapped alone, Ctrl+Up; with a
  click, a Command-click. So the client's remap is unnecessary for the Mac host.
- **Both hosts, today's client:** the client's remap sends Right Opt-Tab as *Right Option up, Left Command
  down, Tab*. A host that treats that release as a tap opens Mission Control / the overview before the switch
  (Linux's `the_system_key_taps_and_holds_as_command` doesn't cover it). The Mac host only calls a release a tap
  once the next event isn't a Command press, or 60 ms pass (`SystemKey.tapDelayNs`). Linux should do the same,
  or the client should stop remapping Right Option (the hosts do it now) and keep its remap for Left Option off.

Not yet checked on the iPad: whether Ctrl + arrows, fn + arrows, Globe combos and the function-row keys arrive (a
key log in the client's HUD would settle it in minutes).

## 6. The system-key overlay (client: done, v5)

Right Option held alone for 350 ms shows an overlay on the iPad: the link, the iPad's video numbers, the host's
(`HostStats`, asked for at 4 Hz only while it shows), and the settings in effect. Every key still goes to the host
unchanged; another key or a click hides it. Code: `ClientInputPipeline` (`overlayHoldNs`, `LocalShortcut.overlay`),
`ClientOverlay`, `StreamViewController`.

## 5. Client: choosing a host (planned, client only)

Today the client dials the last host it used (or whichever answers first), one link at a time; a cable always wins.
Agreed direction, step by step: first an explicit host choice (no auto-picking the most recent) with a switcher and
shortcuts in the Ctrl-Opt-Cmd family; later, optionally, links held open to every host with a "park/focus" message
(a v5 feature) for instant switching. Section 1's keep-alive already makes a switch keep each host's windows.

## Open on the Linux side

- Scroll feel; a scroll-momentum bug found by `lain-input`'s property test (its failing case is kept in
  `tests/props.proptest-regressions`).
- The lock screen on lain's display, unlocked from the iPad.
- Moving windows between workspaces from the system key (Right Opt + Shift + Left/Right) is proposed, not built;
  GNOME's own Shift+Ctrl+Alt+Left/Right works from the iPad meanwhile.
