# Handoff: Mac host smoothness and Terminal scrolling (from the Linux session, 2026-11-13)

Continue on the Mac, where the Mac host can be built, run and measured. Delete this file once both issues
are settled and recorded (ARCHITECTURE.md §11/§13, STATUS.md).

## Where things stand

- `main` has the Linux host at parity with v1. On the iPhone Duo over USB and the LAN it is verified for:
  - protocol v7 at 3× (a 2850×2004 display), video and pointer;
  - sound (v6 `AudioConfig`/`AudioPacket`);
  - dictation and the on-screen keyboard (v6 `TextInput`, typed as keys of the desktop's layout).

  Details: `rust/HOST-PARITY.md` (§3 "since protocol v7") and the commit messages from `9c7a94f` to `28b7bab`.
- Side by side, the owner found the Linux host smoother than the Mac host:
  - **Scrolling in Terminal.app on the Mac is choppy, nearly unusable.**
  - Scrolling in a browser is better.
  - Everything is a little less smooth than on Linux.

These look like two separate issues.

## Issue 1: Terminal scrolls in big jumps (likely a bug in the Mac host's scroll events)

**Hypothesis.** `InputInjector.scroll` (`Packages/LainKit/Sources/LainHostCore/Input/InputInjector.swift`,
around line 163) writes the **pixel** delta into both fields:

```swift
ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(s.dy))    // pixels: right
ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(s.dy))  // should be lines
```

- `PointDelta` is pixels; AppKit's `scrollingDeltaY` reads it, and browsers use it.
- `FixedPtDelta` is the line delta, AppKit's `deltaY`. On real trackpad events it is much smaller than the
  pixel delta, roughly a tenth (not verified).
- An app that scrolls by lines, like Terminal (and anything reading `deltaY`), then moves about 10× too far
  per event, in steps. That matches "Terminal choppy, browser fine".
- The integer field `scrollWheelEventDeltaAxis1`, which `CGEvent(scrollWheelEvent2Source:units: .pixel, …)`
  derives from `wheel1`, should be checked too.
- These lines haven't changed since the first version (`9f11a84`), with no note saying it was deliberate.
- The Linux host can't have this bug: Wayland has no line delta (it sends logical pixels with
  `NotifyPointerAxis`).

**Measure first.** Compare a real trackpad scroll with one from lain, using this probe. Save it as
`scrollprobe.swift`, run `swift scrollprobe.swift`, and scroll over its window:
1. with the Mac's own trackpad;
2. with the iPad/Duo trackpad through lain (the window on lain's display).

```swift
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 300), styleMask: [.titled, .closable],
                 backing: .buffered, defer: false)
w.title = "scroll here"
w.makeKeyAndOrderFront(nil)
NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
    let cg = e.cgEvent!
    print(String(format: "precise=%d phase=%lu mom=%lu  scrollingΔY=%.2f deltaY=%.3f  point=%.2f fixed=%.3f int=%lld",
                 e.hasPreciseScrollingDeltas ? 1 : 0, e.phase.rawValue, e.momentumPhase.rawValue,
                 e.scrollingDeltaY, e.deltaY,
                 cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                 cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                 cg.getIntegerValueField(.scrollWheelEventDeltaAxis1)))
    return e
}
app.activate(ignoringOtherApps: true)
app.run()
```

What to look for:
- **The ratio** of `point` to `fixed` (and to `int`) on real trackpad events. If it's about 10:1, use it.
- **Whether lain's events differ:** if they show `fixed ≈ point` while the trackpad's don't, the hypothesis
  holds.
- **Phase and momentum sequences:** whether they look like the trackpad's (began/changed/ended, then
  momentum began/changed/ended).

**Fix candidate.** Set `FixedPtDelta` (and the integer `DeltaAxis`, if it's also off) from the pixel delta
divided by the measured ratio. Keep the fractional remainder for the integer field if the trackpad's events
do that. Add a unit test pinning the fields for a sample `Scroll`.

Then check:
- Terminal: scrollback, and `less`/`vim` in the alternate screen. The alternate screen scrolls by lines
  (arrow keys), so some steppiness there is inherent.
- A browser and Xcode, which should be unchanged.

## Issue 2: the Mac host is a little less smooth overall (probably the network, to be confirmed)

**What's known.**
- In the Linux test, the host was on **Ethernet** (`LAN (enp12s0)`) and the device was on Wi-Fi or USB.
- The Mac host's Wi-Fi findings (`rust/HOST-PARITY.md` §8, 2026-11-01):
  - over AWDL, a ~270 ms blackout about once a second;
  - over the LAN, ~100 ms pauses 2–4 times a second.
  - The LAN pauses were traced to the iPad's radio.
- If the Mac session ran over Wi-Fi, especially peer-to-peer, that alone could explain it.

**Isolate the network first.** Use the same device and the same path on both hosts.

| Path | Mac host | Linux host |
|---|---|---|
| USB | ? | smooth (Duo, 2026-11-12) |
| LAN | ? | smooth (Ethernet host, Duo on Wi-Fi) |
| Peer-to-peer (AWDL) | ? | n/a (Linux has no AWDL) |

**If USB on the Mac is as smooth as Linux:** it's the radio or the path. Pursue §8 (an iPad or Duo
sysdiagnose; the radio-priority setting; LAN vs AWDL).

**If USB on the Mac is still less smooth:** it's the host. Compare the system-key panel's stats on both
hosts: encode p50/p95, ack RTT, frames held back (for the link or for the encoder), frames sent per second
while scrolling. Also the Mac's `diag` log category, once a second. Candidates on the Mac side:
- **Capture scaling:**
  - The Mac renders the virtual display at 2× of its points.
  - ScreenCaptureKit then scales the capture to the panel. The Duo at 3× is 951×669 pt, so a 1902×1338
    backing store is scaled up to 2853×2007.
  - Linux renders and encodes at the panel's own pixels, with no scaling.
  - Check whether the scaling adds latency or drops frames; compare at the device's 2×, where the backing
    size equals the panel.
- **Capture cadence:**
  - `minimumFrameInterval` is 1/frameRate and `queueDepth` is 4 (`FrameSource.swift` ~122–128).
  - Check that the virtual display really runs at 120 Hz (`CGVirtualDisplay` mode), and that SCK delivers
    120 fps while scrolling.
  - Check frame pacing: steady intervals versus bursts.
- **Adaptive bitrate:** whether the Mac's target dips while scrolling (frames held back "for the link").
  The Linux host mostly sat at the 60 Mb/s ceiling on the LAN.
- **The encoder:** VideoToolbox real-time HEVC, with no reordering and `MaxFrameDelayCount` 0. This looks
  right (`LainMedia/VideoEncoder.swift` ~128–165). The one thing to check is
  `EnableLowLatencyRateControl: false`.

**Record** the measurements in ARCHITECTURE.md §13, and the outcome in STATUS.md and `rust/HOST-PARITY.md`.

## Linux-side follow-ups (not blocking)

- Typed text:
  - Caps Lock state isn't compensated (letters invert if it's on).
  - Emoji and characters the layout lacks are skipped; the options are the RemoteDesktop clipboard plus
    Ctrl+V, or a GNOME Shell extension that commits text.
- The Mac host also mutes its own speakers while sound plays on the device; Linux deliberately doesn't (the
  development machine has no speakers).
