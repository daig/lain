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

## 5. Client: choosing a host (client: done; hosts: nothing new needed)

The iPad's panel (§6) lists every saved host: one it holds a Wi-Fi key for (`mac:<hostId>` in its store, from
a USB pairing) and has a name for (recorded from each `HelloAck`'s `hostName`). Rows: **Automatic** (today's rule:
the cable first, then the last used) and each host; a pick is stored, the Wi-Fi loop dials only that host, and a
Wi-Fi link to another closes at once. The cable always wins: with a USB link up the hosts are listed, not
selectable. Mac and Linux hosts alike. Code: `ClientSession.hostList`/`selectHost`, `WiFiDialPlan(only:)`,
`LastConnectedHost.names`/`selected`, `ControlPanel`.

**What a Linux host needs to be switchable** (all of it exists today, as far as the Swift side knows):
1. Paired once over USB, so the iPad holds its key.
2. `_lain._tcp` advertised with TXT `id` and `vs`, and the TLS-PSK listener (§7.7, D29).
3. A non-empty `hostName` in `HelloAck` (the panel's label; recorded on the next session after the update).
4. A protocol version the iPad offers: v4 or v5 (the iPad now offers [4, 5]).

Later, optionally: links held open to every host with a park/focus message for instant switching, and shortcuts.

## 6. The system-key panel (client: done, v5)

Right Option held alone for 350 ms opens a **latched** panel on the iPad: it stays open until Esc or a Right Option
tap, and takes the keyboard and trackpad meanwhile (nothing reaches the host, except the release of the Right
Option that opened it). Sections: stream (the iPad's numbers and the host's `HostStats`, asked for at 4 Hz only
while open), hosts (§5), the iPad's options (pointer speed, scroll speed, scroll direction, Wi-Fi path, radio
priority), and a shortcut cheat sheet. Code: `ClientInputPipeline` (`overlayHoldNs`, latched panel mode),
`ControlPanel`, `PanelView` in `StreamViewController`.

**What this asks of a host:**
- **The tap length (needed):** a Right Option release is a tap only within **300 ms** of its press (Mac:
  `SystemKey.tapMaxNs`). Without it, closing the panel's hold opens the overview on release.
- **The client's remap (needed):** the iPad remaps Right Opt + Tab, Space, H, Q, ` itself (Right Option only):
  it sends *Right Option up, Left Command down, the key*. That release is not a tap: the Mac waits for the next
  event and drops the tap if it's a Command press, or calls it a tap after 60 ms (`SystemKey.pendingTap`,
  `tapDelayNs`). Linux's router fires the overview on that release today.
- **Protocol v5 (needed for the tests, optional for behavior):** `StatsRequest` (0x10, iPad → host:
  `HostStats` every N ms, 0 stops; the host clamps to 100–5000) and `HostStats` (0x11: encode p50/p95 and ack
  RTT p50/p95 in µs with `UInt32.max` for none; captured, encoded, sent, dropped before encode, encode
  failures, keyframes, refinements as u32; in flight and peak as u8; bits per second as u32), behind
  `ProtocolFeature.hostStats`. The Swift window is now [4, 5] (v3's golden bytes are gone; v5's recorded), so
  `lain-proto`'s golden tests fail until it has the two messages and the new window. A host that doesn't send
  stats is fine: the panel says its lain is older (at v4) or waits for numbers (at v5).

## 7. Video over a weak link (Mac host: done; Linux: worth porting)

Measured on the device over Wi-Fi (`log show --predicate 'subsystem == "lain" AND category == "diag"'`):
- **Adaptive bitrate** (`LainMedia/BitrateController.swift`, pure and trace-tested): from each `FrameAck` (size,
  round trip, receipt time) the best round trip, the median queueing over the last eight, and the delivery rate
  over the time the link was delivering (a gap over 3× the median ack gap is a stall). Down (at most 30% a
  step, to 90% of delivery) only on a busy, warm link: frames held back **for the link** (not for the encoder),
  at least 3 Mb/s delivered, past the first second; up 15% per clear half second, busy or not. Floor 6, ceiling
  60 Mb/s; 60 over USB, 20 over Wi-Fi to start. Refinements go out at the ceiling. VideoToolbox takes the rate
  live (average plus a 1.5× one-second cap below the ceiling). Each rule came from a device trace; see the tests.
- **Held-back frames split by cause** (`FrameGate.droppedForLink`/`droppedForEncoder`).
- **Diagnostics** once a second: input arrival (bursts, gaps, queueing from the header send times), video (sent,
  held back by cause, frame sizes, ack round trip, target, delivered, encode time, and per-direction one-way
  excess delay from the ack's receipt time).
- **4:2:0 vs 4:4:4** (Mac menu: Color): big scroll frames only ~8% smaller in 4:2:0 (measured), so the bitrate,
  not the chroma, is the lever.

## 8. Wi-Fi findings (2026-11-01, Mac host over AWDL and the LAN)

- Over AWDL: a ~270 ms blackout about once a second, both directions (the Mac's Wi-Fi was on 6 GHz, AWDL on 5).
- Over the LAN: a ~100 ms pause 2-4 times a second, both directions. **It is the iPad's radio**: pinging the
  router from the Mac at 10 Hz is clean (0/150 over 40 ms), pinging the iPad is not (18-45/150, a sawtooth every
  2-5 pings). Not affected by: service class (`.interactiveVideo` both sides), lain's peer-to-peer advertising
  (LainHost was the Mac's only AWDL client; removing it changed nothing), Universal Control, the Mac's AWDL off,
  the iPad's Bluetooth, AirDrop, Handoff, AirPlay Receiver. Open: whether the iPad's own browse or something
  system-wide keeps its radio away; a sysdiagnose of the iPad would say. A Linux host on Ethernet should show the
  same pauses with the same iPad on the same Wi-Fi.
- WiFiAware is unavailable on macOS 27 (every declaration `@available(macOS, unavailable)`).

## Open on the Linux side

- Scroll feel; a scroll-momentum bug found by `lain-input`'s property test (its failing case is kept in
  `tests/props.proptest-regressions`).
- The lock screen on lain's display, unlocked from the iPad.
- Moving windows between workspaces from the system key (Right Opt + Shift + Left/Right) is proposed, not built;
  GNOME's own Shift+Ctrl+Alt+Left/Right works from the iPad meanwhile.
