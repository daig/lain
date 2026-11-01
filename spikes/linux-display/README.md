# Spike B: Mutter's virtual monitor as the iPad's display, and the pointer

Open spikes 2 and 3 of `docs/LINUX-HOST.md`: how `org.gnome.Mutter.ScreenCast.RecordVirtual`, linked to an
`org.gnome.Mutter.RemoteDesktop` session, behaves as lain's iPad display (2752×2064, scale 2, 120 Hz), and how
input reaches it and the physical monitors. Run on 2026-10-31 on the reference machine: Ubuntu 26.04.1, GNOME
Shell 50.1 on Wayland, PipeWire 1.6.2, one 3840×2160@60 monitor (HDMI-1, scale 1, primary) on the Radeon iGPU.
ScreenCast interface version 4, RemoteDesktop version 1 (`SupportedDeviceTypes` = 7: keyboard, pointer, touch).

**In short:** it works. Creating the display and injecting input show no consent prompt, but a persistent
(method 2) `ApplyMonitorsConfig` does: GNOME Shell asks "Keep these display settings?", so lain applies its
layouts with method 1 only.
- The virtual monitor takes exactly the size and maximum frame rate the PipeWire consumer asks for.
- It runs at a steady 120 Hz, over both DMA-BUF and shared memory.
- It can be scaled to 2 and placed anywhere adjacent with method 1, which Mutter doesn't keep across sessions
  and drops while the set of monitors differs. lain stores the arrangement itself and re-applies it.
- `NotifyPointerMotionAbsolute` takes stream-local logical pixels. libei's absolute pointer takes global
  logical pixels.
- Cursor position and image come in the stream's metadata, in device pixels, as premultiplied RGBA.
- All injected input counts as user activity.
- Two traps to design around: GNOME Shell's top-panel pointer barrier (it stops moves into lain's display, and
  some within it, near the top of the shared edge; the exact rule is open), and the fact that the monitor only exists once a consumer has
  negotiated the stream's format.

The lock screen was **not** tested. It needs a supervised test (see "Not tested").

The lead's design decisions that follow from this spike are recorded in "Design decisions taken by the lead
(2026-10-31)", at the end; where the recommended design below differs, those decisions win.

## What changed on the desktop, and how it was restored

- **Virtual monitors (`Meta-0`, and `Meta-1` in exp9):** every experiment created them and stopped its session at the end. Each
  experiment compared the layout at its end with the layout at its start, and every one matched the
  pre-wave snapshot (`HDMI-1` alone, 3840×2160@60, scale 1, primary, at 0,0, layout mode 1).
- **Temporary layouts:** experiments 2–7 and 9 applied layouts with `ApplyMonitorsConfig`, temporary
  (method 1) except in exp2's former `persist` runs (method 2, see the next point). They put the virtual
  monitor at scale 2, right of or below `HDMI-1`. In exp2, verify-only (method 0) calls also tried a left
  placement that moved `HDMI-1`'s logical origin. `HDMI-1`'s mode, scale and primary flag were never changed.
- **`~/.config/monitors.xml` and the dialog:** exp2's `persist` mode applied with method 2, twice. Each time
  GNOME Shell showed "Keep these display settings?" to the developer (reported during the spike; the script
  didn't know). Only *Keep* writes `monitors.xml`, which didn't exist before; it appeared after the run and
  held only `HDMI-1`'s configuration, identical to the default, and it was deleted both times. The `persist`
  mode has since been removed from `exp2_arrange.py`. `~/.config/monitors.xml` doesn't exist now.
- **The pointer:**
  - It moved over the empty virtual monitor in exp3, exp4 and exp6. Every run first read its position from
    the physical stream's cursor metadata and moved it back to that position at the end.
  - **Not every run ended with the pointer at home.** The committed exp3 and exp6 results end at home
    (`results/exp3.jsonl` line 36: (821, 101); `results/exp6.jsonl` line 17: (1225, 631)). The review
    round's exp4 didn't: its restore read (0, 1886) on `HDMI-1` instead of the home (653, 1504)
    (`results/exp4.jsonl` line 19). The probe window had received motion the script hadn't sent (line 5), so
    the developer was most likely moving the mouse; the pointer was hidden (typing) when checked afterwards,
    so it wasn't moved again. The scripts that ran then only logged where the pointer ended up. exp3, exp4
    and exp6 now compare it with home, retry once, and emit `restore_failed` if it still isn't there
    (`restore_pointer` in `mutter.py`).
  - **Scrolling:** the D-Bus scrolls (exp3, exp4) happened only over the virtual monitor: over the
    wallpaper, or over this spike's own probe window. In the first round this rested on the moves having
    worked (each "home" was below the panel's band, and where the barrier stopped a move the pointer was
    still on the virtual monitor's first column); exp3 and exp4 now check it before every scroll and key.
    **exp6's libei scroll was not guarded:** it goes through the relative virtual pointer, so it lands
    wherever the pointer is, and it would have scrolled the developer's window had the absolute moves not
    put the pointer on the virtual monitor. In the committed run they had (`results/exp6.jsonl` lines 8–12
    put the pointer at the virtual centre right before the scroll on line 15). exp6 now runs it only after
    the absolute moves and behind `require_pointer_on`, and skips it otherwise.
  - No button events.
- **Keys: the brief allowed one Shift press and release; three were sent.** exp3 and exp4 each ran twice in
  the first round and exp4 once more in the review round. The first run of each crashed before any key or
  scroll (exp3 on a keyword clash in its first activity line, after one motion; exp4 on a non-blocking read
  while waiting for its window). The three pairs:
  1. exp3's second run, in its user-activity loop (`results/exp3.jsonl` line 33), over the virtual monitor;
  2. exp4's second run (first round; that output was replaced by the review round's), to the probe window;
  3. exp4's review-round run (`results/exp4.jsonl` line 16), to the probe window.

  Each pair went to the virtual monitor or the spike's own window, and no other key events were sent. The
  committed scripts now send one pair only, in exp4, where GTK confirms the keycode; exp3's activity loop no
  longer sends a key.
- **Focus:** the GTK probe window (`gtkprobe.py`, fullscreen on the virtual monitor) took keyboard focus for
  5–14 s at a time in exp4 and exp5.
- **Review round** (the same day): exp2 `temp`, exp4 and exp5 (DMA-BUF) were rerun with the committed scripts,
  and exp9 is new. exp9 added a second virtual monitor next to lain's, never touching `HDMI-1`'s settings, and
  injects no input. Every run ended with the layout as it found it.

## Files

| File | What it is |
|---|---|
| `pwprobe.c`, `build.sh` | A PipeWire consumer for one Mutter node: negotiates a given size and max frame rate, shm or DMA-BUF (`dmabuf=<modifier>`); prints the format, frames (with damage), cursor metadata (with bitmap checks) and per-second stats as JSON lines. `./build.sh [outdir]` (needs `libpipewire-0.3-dev`). |
| `mutter.py` | Helpers: one private D-Bus connection per experiment, RemoteDesktop+ScreenCast sessions, DisplayConfig, IdleMonitor, running `pwprobe`. |
| `ei.py` | A ctypes binding of the libei sender API (only the runtime `libei.so.1` is installed, not the headers). |
| `gtkprobe.py` | A GTK 4 window, fullscreen on a given connector: logs the motion, scroll and key events it receives, and redraws a small square on every frame-clock tick. |
| `exp1_create.py` … `exp9_monitor_set.py` | The experiments below. Each prints JSON result lines. Before any scroll or key, exp3, exp4 and exp6 require the virtual stream's cursor metadata to put the pointer inside the virtual monitor (`require_pointer_on` in `mutter.py`): exp3 and exp4 stop otherwise, exp6 skips its scroll. At the end, exp3, exp4 and exp6 check the pointer is back home, retry once, and emit `restore_failed` if not (`restore_pointer`). Only exp4 sends a key (one Shift press and release). |
| `results/` | Their output (the monitor's serial number redacted). `exp2_persist.jsonl` comes from the since-removed method-2 mode (commit 1198caa). `exp3_first_run.txt` is exp3's first, crashed run, recovered from the session log (lines cut at 1200 characters); it is the only record of the barrier stopping a move from `HDMI-1`. `exp2_temp.jsonl`, `exp4.jsonl`, `exp5_dmabuf.jsonl` and `exp9_*.jsonl` come from the committed scripts (review round); the other files are from the first round. Its exp3 had no scroll guard, sent a Shift in its activity loop (`exp3.jsonl` line 33) and only logged the restore; its exp6 had no scroll guard and a single unchecked fallback restore. Otherwise the scripts are the committed ones. Figures in this README come from these files unless marked "first round, no committed file". |

Run them as `PWPROBE=<outdir>/pwprobe python3 expN_….py`, one at a time. `exp5_rate.py` takes
`PROBE_OPTS=dmabuf=144115188080057091` for DMA-BUF. `exp9_monitor_set.py` takes a phase: `hotplug`, `close`
or `sizes`. `exp4_scroll.py` waits up to `HOME_WAIT` seconds (default 15) for a visible pointer before it
injects anything.

## Findings

### 1. Creating the display, and how size and refresh are negotiated (exp1, exp5, exp8)

- **The calls:**
  - `RemoteDesktop.CreateSession()` → read the session's `SessionId`.
  - `ScreenCast.CreateSession({"remote-desktop-session-id": id})`.
  - `Session.RecordVirtual({"cursor-mode": 2})` → a stream object.
  - Subscribe to its `PipeWireStreamAdded(u node_id)`, then `RemoteDesktop.Session.Start()`. The node id
    arrives about 24 ms after `RecordVirtual`.
- **What the node offers before anyone connects** (`pw-dump`):
  - Formats: `BGRx` and `BGRA`.
  - Size: any from 1×1 to 16384×16386 (default 1280×720).
  - `framerate` 0/1 (variable); `maxFramerate` 0–1000 (default 60).
  - Colour: bt709, gamma 2.2.
  - DRM modifiers: AMD's `0x200000000401b03` (preferred), `0x200000000401603`, `0x200000000000901`, LINEAR
    and `DRM_FORMAT_MOD_INVALID`.
- **No monitor exists until a consumer fixes the format.** Once the consumer offers size 2752×2064 and
  `maxFramerate` 120/1, `DisplayConfig` lists a new monitor 57 ms later (`results/exp1.jsonl` line 8; the
  first round's other runs saw 30–60 ms, no committed file):
  - connector `Meta-0`, vendor `MetaVendor`, product `Virtual remote monitor`;
  - a single mode, `2752x2064@120.000`;
  - supported scales 1, 1.33, 2, 2.67; it comes up at **scale 1**;
  - placed to the right of the existing layout, at (3840, 0).

  The mode's refresh is the consumer's `maxFramerate`: asking for 60, 144 or 240 gave modes at 60, 144 and
  240 Hz (`results/exp5_dmabuf.jsonl`). GTK sees the monitor at scale 2 (once applied) and 120 000 mHz.
- **The serial changes every time** (`0x000001` in exp1, `0x000027` and `0x000028` in exp2 `persist`,
  `0x000029` in exp8, `0x000030` and `0x000031` in exp2 `temp`). So does each stream's `mapping-id`. Nothing identifies "lain's monitor" across sessions.
- **Telling which monitor is lain's:**
  - A virtual stream's `Parameters` hold only `mapping-id`. A `RecordMonitor` stream also has `position`,
    `size` and `output-name`.
  - So lain finds its monitor as the one that appeared in `DisplayConfig` after negotiation, or as the EIS
    region with the stream's `mapping-id` (§4), which also gives its global rectangle.
  - `is-platform: true` made no visible difference (first round, no committed file).
- **The monitor outlives its consumer** (exp8):
  - When the consumer disconnects, the monitor stays, same connector, serial and mode, until the session
    stops.
  - A second consumer then connects to the same node and streams with no new monitor.
  - A consumer asking for another size (2064×2752) re-modes the same monitor in place.
  - Two consumers at once both reach `streaming`.
- **Removal:** `Session.Stop()` (or closing the D-Bus connection) removes the monitor within about 12 ms.
  The layout returns to what it was.
- **Changing the scale** makes the stream renegotiate: a new `param_changed` with the same size. The
  consumer must expect format events mid-stream.

### 2. Frame delivery (exp5)

Frames are damage-driven: a static virtual monitor sends no new pictures. To test the rate, `gtkprobe.py`
animated a 240×240 square on the monitor at scale 2 and 120 Hz:

| Buffers | Pictures/s | Interval p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| DMA-BUF at `maxFramerate` 120 | 120 | 8.33 ms | 8.39 | 8.42 | 26.5 |
| DMA-BUF at 60 | 60 | 16.66 ms | 16.8 | 17.52 | 17.82 |
| DMA-BUF at 144 | 144 | 6.94 ms | 7.00 | 7.04 | 7.17 |
| DMA-BUF at 240 | 240 | 4.17 ms | 4.21 | 4.27 | 4.51 |
| shared memory (MemFd) at 120 | 120 | 8.25 ms | 8.75 | 9.42 | 16.6 |

DMA-BUF rows: `results/exp5_dmabuf.jsonl` (review round); shared memory: `results/exp5_shm.jsonl` (first round).
The first round's DMA-BUF run at 120 had a max of 8.43 ms (first round, no committed file).

- **DMA-BUF:** one plane, and the negotiated modifier (logged from the format event) is `0x200000000401b03`,
  the one pwprobe asked for. pwprobe offers that single modifier as mandatory, so this shows Mutter accepts
  it, not what Mutter would pick from a list.

- **Pacing:** it is timer-driven and very regular, and the GTK frame clock on that monitor ticks at the
  same rate.
- **When the client can't keep up, the rate drops with it.** An earlier `gtkprobe.py`, which repainted the
  whole 2752×2064 surface in software every tick, fell to 60–87 Hz in the first round's exp4 and exp5 runs,
  with full-frame damage (first round, no committed file). That was the client's cost, not Mutter's. With the
  committed probe (a small square), the review round's exp4 got 117–118 pictures/s while it scrolled
  (`results/exp4.jsonl` line 17).
- **Shared memory is a GPU readback**, so lain-linux-video should use DMA-BUF (L3). Whether VA-API takes
  these modifiers is spike A's question.
- **Damage:** the `VideoDamage` metadata carries full-frame and partial rectangles in device pixels.

### 3. Arrangement, scale and persistence (exp2, exp9)

- **What `ApplyMonitorsConfig` accepts** with the virtual monitor in it (method 0 checks without applying;
  1 is temporary, 2 persistent):
  - placements left, right (with a y offset) and below-centred;
  - scale 2 (and the other listed scales).
- **What it rejects:**
  - a gap or an overlap: "Logical monitors not adjacent";
  - a negative position: "Invalid logical monitor position (-1376, 0)". So putting the iPad to the left
    means moving the physical monitor to x = 1376: the global origin stays at the layout's top-left corner;
  - scale 1.5: "not valid for resolution 2752x2064".
- **It takes effect at once** (the call takes 16–26 ms), and the next `GetCurrentState` shows it.
- **Method 1 (temporary) doesn't outlive the session:** after destroy and re-create, the monitor is back at
  (3840, 0), scale 1.
- **Method 1 doesn't survive a change in the set of monitors either** (exp9 `hotplug`, with a second virtual
  monitor standing in for a hotplugged one):
  - lain's monitor at (1232, 2160), scale 2; a 1280×720 monitor appears → lain's monitor moves to (3840, 0),
    still at scale 2, and the new one goes to its right;
  - the extra monitor goes away → lain's monitor is back at (1232, 2160), scale 2. Mutter remembered the
    temporary layout for that set of monitors.
  - Whether the scale survives every such change, and what a real unplug does, wasn't tested. lain must not
    rely on either.
- **Method 2 (persistent) is unresolved, and lain never uses it.** Every method-2 apply makes GNOME Shell show
  "Keep these display settings?"; Mutter reverts after about 20 s unless someone clicks *Keep*, and only *Keep*
  writes `~/.config/monitors.xml` (reported by the developer). The first round's `persist` runs didn't
  account for the dialog, so their evidence (`results/exp2_persist.jsonl`) is confounded: the virtual monitor
  was destroyed about 1 s after the apply, and `monitors.xml` appeared later, holding only `HDMI-1`. That fits
  a click on *Keep* after the virtual monitor had gone. It shows what the layout was at the click, not what
  Mutter persists for a virtual monitor. The mode has been removed from the script.
- **So lain stores the owner's arrangement itself and applies it with method 1** after every `create` and
  after every change in the set of monitors: scale 2, the side and offset relative to a physical monitor
  (identified by connector, vendor, product and serial). Method 1 because nobody at the iPad can answer the
  dialog, and the iPad may be the only screen anyone is looking at.

### 4. Coordinates and reaching every monitor (exp3, exp4, exp6, exp7)

**`NotifyPointerMotionAbsolute(stream, x, y)`** takes **stream-local logical pixels**:
- On the virtual monitor at scale 2, (688, 516) is its centre (cursor metadata at 1376, 1032) and (1375.5,
  1031.5) is its last device pixel.
- Fractions pass through: the GTK client received exactly (100.5, 200.25).
- Values outside the stream are clamped to its edge. (2000, 1500) landed at (1375, 1031).
- **The mapping:** `local = global − monitor.origin` in logical pixels, with no scale factor.
- **A stream needs no consumer for this.** A second session's `RecordMonitor(HDMI-1)` stream, never
  connected to PipeWire, put the pointer back exactly (exp6). Each physical monitor needs a stream, but not
  a capture.
- **A monitor stream whose monitor goes away is removed, and its session stays** (exp9 `close`): lain's
  session recorded its virtual monitor plus a `RecordMonitor` stream of a second virtual monitor; when that
  monitor went away, the stream's D-Bus object disappeared, but the session didn't close and lain's monitor
  stayed listed. The stream has to be recreated if the monitor comes back. Tested with a virtual monitor
  standing in for a physical one; a real unplug or DPMS-off is in "Not tested".

**`NotifyPointerMotionRelative(dx, dy)`** moves by logical pixels with no acceleration: +10 moved the pointer
exactly 20 device pixels at scale 2.

**libei (`ConnectToEIS({})` → fd):**
- The seat ("mutter default seat") offers pointer, absolute pointer, keyboard, touch, scroll and button.
- Binding them gives three devices:
  - a **virtual pointer** (relative, scroll, button);
  - a **virtual keyboard** (with an xkb keymap);
  - a **"shared virtual absolute pointer"** (absolute, scroll, button).
- **The absolute pointer has one region per screen-cast stream in the session, not per monitor.** Its
  `mapping_id` is the stream's `mapping-id`, its rectangle is in global logical pixels, and it carries a
  `physical_scale`. Examples: virtual {3840, 0, 1376×1032, scale 2}, physical {0, 0, 3840×2160, scale 1}.
  - A session with only the virtual stream has only its region.
  - Adding a `RecordMonitor` stream after `Start` adds its region, even though that stream has no consumer.
- **Coordinates are global logical pixels:** (3840+688, 516) is the virtual monitor's centre.
- **Motion outside every region is dropped** (D-Bus clamps instead).
- **Each layout change removes and re-adds the absolute device**, twice for one `ApplyMonitorsConfig`, with
  the new regions. A sender has to re-resolve its device and call `start_emulating` again each time.

**GNOME Shell's top-panel barrier blocks absolute motion.**
- **What was seen** (virtual monitor right of `HDMI-1`, so the shared edge is x = 3840):
  - **From the physical monitor:** the move from (391, 1564) to the virtual (10, 10), whose line crosses
    x = 3840 at y ≈ 14, stopped at x = 3840 (virtual (0, 10)) while y moved (`results/exp3_first_run.txt`).
    From (821, 101), the line to the virtual centre crosses at y ≈ 440 and went through.
  - **Within lain's display, sometimes:** some moves that *start* on the virtual monitor's left edge inside
    the panel's band stick too, and some don't.
    - Stuck: from virtual (0, 10), reached by the stuck move above, the move to (500, 400) stayed at x = 0
      (`results/exp3_first_run.txt`). From virtual (0, 0), reached by (−50, −50) being clamped there, the
      move to the centre (688, 516) ended at (0, 516): y moved, x didn't (`results/exp3.jsonl` lines 19–20).
    - **Not stuck:** from virtual (0, 0), reached by a move from the centre to exactly (0, 0), the move to
      (5, 5) went through to (5, 5) (`results/exp3.jsonl` lines 16–17). Same start point as lines 19–20, in
      the band, +x, yet no stop.
    - Below the band: from (0, 516), the move to (3, 516) worked (`results/exp3.jsonl` lines 21–22).
  - Where it stopped, the pointer was on the virtual monitor's first column (x = 3840 belongs to it), not on
    `HDMI-1`.
- **The mechanism is a hypothesis.** `layout.js` `_updatePanelBarrier()` puts a `Meta.Barrier` at the
  primary monitor's right edge, from y = 0 to the panel's height, that lets the pointer through only in the
  −x direction, and Mutter applies barriers to absolute motion along the line from the current position.
  That explains the moves from `HDMI-1`. It doesn't settle the moves that start on the barrier's line: lines
  16–17 and 19–20 start at the same reported point and differ only in how the pointer got there (a move
  ending exactly at (0, 0) versus one clamped there from outside the stream), and only the second stuck. One
  guess is that the pointer's sub-pixel position, or the side of the barrier Mutter assigns it to, differs
  between the two; nothing here tests that. **The exact rule for a move that starts on the line is open.**
- **What it means for lain:** an absolute move in the +x direction whose path crosses x = shared edge within
  the panel's band (the panel's height; about 32 logical pixels at scale 1 is an estimate, not measured here)
  sticks at the edge. A move that starts on the edge within the band may or may not stick, by a rule not yet
  known; that includes an iPad user going to lain's top-left corner and then moving right. Moves out of
  lain's display (−x) are let through.
- **A possible fix in `lain-gnome`, untested** (the detour below was never run): for a move whose straight
  line may touch the barrier (starts on or crosses the shared edge, +x, within the band), go first to
  (x, y_safe) on the current side, where y_safe is just below the band, then to the target. Then check where the pointer went with
  `cursor_location`. Costs: at 120 Hz each such step becomes two motions, the pointer visibly dips below the
  band and back, and, with a button held, a drag passes through the detour point. So:
  - prototype it behind a test and apply it only to the moves whose line touches the barrier;
  - skip it while a button is held;
  - or decide the native behaviour is acceptable (the pointer sticks at the edge, and the cursor-warp path
    corrects the client). That is lain-gnome's call, with a measurement.
- **Not checked:** whether libei absolute motion is also subject to the barrier. Testing it would need the
  pointer near the top of the user's monitor.

### 5. NotifyPointerAxis and NotifyPointerAxisDiscrete flags (exp4, as a GTK 4 client sees them)

Flags: 1 = finish, 2 = wheel, 4 = finger, 8 = continuous. Positive `dy` scrolls down and positive `dx`
right, which is Wayland's convention and `InputAction::Scroll`'s.

| Sent | GTK 4 received |
|---|---|
| finger: `(0, 10, FINGER)` ×5, then `(0, 0, FINGER\|FINISH)` | `scroll-begin`; 5 × `scroll` dy = 10.0, unit `surface`, source `touchpad`; `scroll-end`; `decelerate` vy ≈ 602 px/s (GTK's own kinetic fling) |
| finger, dx and negative | the same, on the other axis and with the other sign |
| continuous: `(0, 10, CONTINUOUS)` ×3 + finish | the same as finger, with source `trackpoint`, **and GTK still decelerates kinetically** |
| no source flag + finish | the same as finger (source `touchpad`) |
| finish with a delta: `(0, 10, FINGER)`, then `(0, 10, FINGER\|FINISH)` | `scroll-begin`, **one** `scroll` dy = 10.0, `scroll-end`, `decelerate`: the delta sent with the finish is dropped |
| wheel: `(0, 10, WHEEL)` ×3 | 3 × `scroll` dy = 1.0, unit `wheel`, source `mouse`, with no begin or end: 10 is one detent |
| wheel + finish | finish ignored |
| `NotifyPointerAxisDiscrete(0, +1)` / `(1, +1)` | one wheel step down / right |

Source: `results/exp4.jsonl` lines 6–15; the `decelerate` velocities there range from 526 to 625 px/s.
Deltas arrive 1:1 in logical pixels. **A delta sent together with `FINISH` is discarded**, so the last delta
must go in its own call, and the finish in a separate `(0, 0, source | FINISH)`. That is why the mapping
below sends `ScrollStop` as a zero-delta finish.

**Contract mismatch:** `ScrollSource::Continuous` promises no kinetic continuation by the desktop, but GTK 4
flings after a finish for the continuous source too. Whether sending the stop late, or not at all, avoids it
belongs to open spike 4 (scroll feel).

### 6. Cursor image and position in the stream's metadata (exp3, exp6)

`cursor-mode: 2` (metadata) puts a `SPA_META_Cursor` on the buffers:
- **`position` is the pointer (the hotspot), in the stream's device pixels:** logical × scale, rounded. The
  hotspot is in bitmap pixels.
- **The bitmap:**
  - It is rendered at the monitor's scale: 48×48 with hotspot (8, 8) at scale 2, 24×24 with hotspot (4, 4)
    at scale 1.
  - Its format is **`RGBA`**, not BGRA.
  - It is **premultiplied**: no colour channel ever exceeded alpha (0 of 743 partial pixels, 101 of them
    coloured; `results/exp6.jsonl` line 16).
  - It comes **only when the sprite changes** (`bitmap_offset` ≠ 0). Every other update carries the
    position alone, so the reader caches the last bitmap.
- **Cursor-only updates are buffers with an empty chunk** (size 0). In exp3, 452 of 471 buffers were
  cursor-only (`results/exp3.jsonl` line 35). A video consumer must not treat them as frames.
- **Validity:**
  - The metadata turns invalid (id 0) when the pointer leaves a stream's monitor.
  - A stream can also report a position just outside itself while the sprite still overlaps it: the
    physical stream showed x = 3843 when the pointer was 3 logical pixels into the virtual monitor.
  - It stayed invalid for minutes on the physical stream while the user was at the keyboard. Most likely
    GNOME hides the pointer while you type (the cause is a guess). Either way, the position is unknown while
    the cursor is hidden.
- **A monitor stream negotiates only its monitor's size** (exp9 `sizes`): `RecordMonitor(HDMI-1)` offers
  exactly 3840×2160 (min = max), and consumers asking for 64×36 or 1920×1080 fail to negotiate. Its
  `maxFramerate` can go down to 1/1, which did negotiate. What a metadata-only consumer at 3840×2160 and a low
  `maxFramerate` costs, and whether its cursor updates are then rate-limited too, wasn't measured.

### 7. User activity (exp3, exp6)

Injected input resets Mutter's idle time:

| Input injected | Idle time before | Idle time after |
|---|---|---|
| absolute motion | 1502 ms | 100 ms (when it was read) |
| finger axis | 1502 ms | 100 ms |
| wheel axis | 1503 ms | 100 ms |
| Shift press and release | 1503 ms | 100 ms |
| libei absolute motion | 1608 ms | 103 ms |

Sources: `results/exp3.jsonl` lines 30–33 and `results/exp6.jsonl` line 14. The Shift row comes from the
first round's exp3, which sent a key in its activity loop; the committed exp3 doesn't (see "Keys" above), so
rerunning it reproduces the other rows only. The one Shift the committed scripts send (exp4) doesn't measure
idle time.

So iPad input keeps the session from going idle (screen blanking and the lock both follow
`IdleMonitor`), and `PowerBackend::user_activity` needs no extra call on GNOME.

### 8. Keys

- **`NotifyKeyboardKeycode` takes evdev codes:** 42 arrived in GTK as `Shift_L` (hardware keycode 50, which
  is evdev + 8). That matches `InputAction::Key`.
- **Keysyms:** `NotifyKeyboardKeysym` exists too.
- **Keymaps:** the session exposes `SetKeymap`, `SetKeymapLayoutIndex`, `CurrentKeymap` and
  `KeymapCapabilities`. They weren't explored.

### Not tested

- **The lock screen:** left for a supervised test.
  - **Questions:** does the virtual monitor survive locking? Does the stream keep producing frames (the
    shield, then the unlock dialog)? Do injected keys reach the unlock prompt? Does the session survive
    unlock?
  - **How:** with the developer present, run exp4 with `loginctl lock-session` added.
- **Barriers and libei:** whether libei absolute motion is subject to the panel barrier.
- **No physical monitor** (headless).
- **A real hotplug:** unplugging `HDMI-1`, or the monitor dropping off when it powers down (DPMS), while
  lain's display exists. exp9 simulates it with a second virtual monitor only. Needs the developer present.
- **The barrier detour** (§4): proposed, never run.
- **Picture quality at scale 2:** the repeat of SL1.
- **Clipboard** (`EnableClipboard`/`Selection*`).

## Recommended design for `lain-gnome`

### `GnomeDisplay: DisplayBackend`

**The connection.** One zbus connection per display session; it holds the display's RemoteDesktop session
and the linked ScreenCast session, so dropping it ends both. Input has its own session (see the lead's
decisions). `type Source = GnomeSource { node_id: u32, stream_path,
mapping_id, cursor: Arc<CursorState>, spec }`.

**`create(spec)`:**
1. Check that no display already exists (contract: one at a time).
2. Set up the session: `RemoteDesktop.CreateSession`, then `ScreenCast.CreateSession({remote-desktop-session-id})`,
   then `RecordVirtual({cursor-mode: 2})`. Subscribe to `PipeWireStreamAdded`, then `Start`.
3. **Negotiate once, in `create`**, with a short-lived PipeWire consumer: size `pixel_width × pixel_height`,
   `maxFramerate = refresh_hz/1`, `framerate` 0/1. Wait until a new `Meta-*` monitor with mode
   `{w}x{h}@{hz}` is in `GetCurrentState`, then disconnect the consumer. The monitor stays (exp8), and
   lain-linux-video later connects to the same node with the same format. This is what makes the contract's
   "returns once active and listed" achievable.
   - It means lain-gnome links PipeWire, which L6 doesn't show.
   - The alternative is a contract change (see "Contract notes").
4. **Apply the stored arrangement** with `ApplyMonitorsConfig` method 1:
   - the virtual monitor at scale `spec.scale` (2), at the owner's preferred side and offset;
   - every other logical monitor exactly as `GetCurrentState` reported it (same mode, scale, transform,
     primary);
   - positions normalised so the layout's top-left is (0, 0) and monitors stay adjacent.

   With no stored preference, keep Mutter's placement (to the right) and set only the scale. Then wait for
   `MonitorsChanged` to show it.
5. Return `StreamedDisplay { id, pixel_width, pixel_height, refresh_hz }`, plus the source.

**Re-applying after a change in the set of monitors.** Method 1 doesn't hold across one (§3: a new monitor
moved lain's display from below to the right). On every `MonitorsChanged` whose set of monitors (by spec)
differs from the one lain last applied for, lain-gnome applies the stored arrangement again, as in step 4,
and records the new set. Until that lands, `monitors()` reports what Mutter reports.

**When Mutter ends the session.** The session can end without lain asking: the owner stops it from GNOME
Shell's sharing indicator, gnome-shell restarts, or (not seen in exp9, but not ruled out for a real unplug) a
stream closing takes it down. lain-gnome subscribes to the RemoteDesktop session's `Closed` signal and to its
connection's loss, and then:
- marks the display gone and takes lain's entry out of `monitors()` (the core already treats the display
  leaving the list as its end);
- drops lain's display from `GnomeInput`'s stream map, so moves onto it are clamped to the remaining
  monitors instead of going to a dead stream path (`call_noreply` would fail silently). Input to the other
  monitors carries on in its own session (see the lead's decisions);
- leaves `destroy()` idempotent: after a `Closed`, it returns at once.

**`destroy()`:**
- `Session.Stop()`, then wait until the connector leaves `GetCurrentState` (about 12 ms).
- Idempotent. Run the removal on a spawned task, so it completes even if the future is dropped; closing
  the connection does it in any case.

**`monitors()`:** a `watch` fed by `GetCurrentState` on start and on every `MonitorsChanged`. One `Monitor`
per logical monitor:
- `bounds` = (x, y) and the mode size ÷ scale (transform-aware), in logical pixels. Layout mode 1, the
  logical mode, is required: refuse layout mode 2 or convert it.
- `primary` from the logical monitor.
- `lain` = the connector `create` recorded.
- `id`: a host-run-stable number kept in a map, keyed by the monitor spec (connector, vendor, product,
  serial). The virtual monitor's serial is new every session, so a new session's display gets a new id.

**Recording the owner's arrangement:** on a `MonitorsChanged` while lain's display exists, store its
position in `$XDG_CONFIG_HOME/lain/` only if all of these hold:
- the set of monitors is the one lain last applied for (otherwise it is Mutter's re-derived layout, and lain
  re-applies instead);
- lain's monitor is at scale `spec.scale` (a reset to scale 1 is Mutter's default, not a choice; lain
  re-applies the scale instead, see the lead's decisions);
- its position differs from the last *stored* arrangement;
- it has stayed that way for longer than GNOME's revert timeout (so a method-2 change the owner then reverts,
  or lets time out, is never stored).

Store it relative to the monitor it touches (that monitor's spec, edge, offset), never as absolute
coordinates. The owner changes it in GNOME Settings, which applies with method 2 and so shows the dialog to
the person at the Mac, where someone can answer it.

**`cursor_location()`:** read from `CursorState`, never from D-Bus (it's polled at 60 Hz).
- **Fed by:** lain-linux-video's reader of the virtual stream's metadata, which covers lain's display.
- **Off lain's display it is `None`** (the lead's decision). Swift samples the real cursor anywhere on the
  desktop for warp detection (`HostSession.swift`, the cursor-warp check); on GNOME the client doesn't see
  warps off lain's display. The options weighed:
  - a metadata-only consumer of each physical monitor's `RecordMonitor` stream. It can't be negotiated small
    (§6: only the monitor's own size), so it is a 3840×2160 capture on the iGPU that also encodes, though at
    a `maxFramerate` as low as 1. Its cost, and whether cursor updates still arrive at 60 Hz, weren't
    measured;
  - libei can't help: the EIS absolute device's regions say where monitors are, not where the pointer is;
  - `None` whenever the pointer is off lain's display: chosen.
- **The conversion:** global = monitor.origin + position ÷ scale.
- **Which stream wins:** take the stream whose rectangle contains the converted point. Positions just
  outside a stream (sprite overlap) are ignored.
- **`None`** when no stream has valid metadata (pointer hidden while typing, or the cursor-mode
  unavailable).

### Input: `GnomeInput: InputBackend`

**Recommendation: `Notify*` over D-Bus for v1, with libei kept behind the same type for later.**
- **Why `Notify*`:**
  - It needs no C library: libei has no Rust binding on this system, and only the runtime is installed.
  - Its absolute motion clamps rather than drops.
  - It works for every monitor through a consumer-less `RecordMonitor` stream.
  - Everything lain needs is there: evdev keys, buttons, smooth axis with source and finish flags.
- **What libei would add:** lower overhead (a socket, not one D-Bus round trip per event) and frames, which
  group motion with scroll.
- **Measure before deciding:** the D-Bus latency per event at 120 Hz. If it hurts, switch to EIS:
  - absolute motion in global logical pixels;
  - regions from the device, matched by `mapping_id`;
  - re-resolve the device after every layout change.

**`apply()` must not block:** push actions onto an unbounded channel. One task owns the session's
connection and sends the calls in order with `call_noreply` (the D-Bus no-reply flag), so nothing waits on
Mutter.

**Mapping each action:**
- **`MoveTo(global)`:**
  - Find the monitor containing the point, half-open; if none, clamp to the nearest.
  - Send `NotifyPointerMotionAbsolute(stream_of(monitor), global − origin)` in logical pixels.
  - Streams: input's own RemoteDesktop session (the lead's decision) holds a consumer-less `RecordMonitor`
    stream for every monitor, lain's `Meta-*` connector included, so a move onto lain's display doesn't go
    through the display session's `RecordVirtual` stream. Mutter removes a monitor stream when its monitor
    goes away and the session survives that (exp9 `close`), so lain-gnome recreates the streams whenever the
    set of monitors in `monitors()` changes. A `RecordMonitor` added after `Start` works for EIS; whether it
    does for D-Bus motion wasn't checked, so either check it or rebuild the input session on each change (a
    second session's consumer-less stream does take motion, exp6). Not tested either: a `RecordMonitor`
    stream of lain's virtual monitor taking motion (exp9 `close` recorded a second virtual monitor this way,
    but sent no motion to it). Test a real unplug and DPMS-off with the developer present before lain-gnome
    depends on this.
  - The panel barrier (§4) stops a move that crosses the shared edge within the panel's band, and can stop
    one that starts on it, including on lain's display (the rule for those is open). Whether to route around
    it, and how, is open (§4).
    Where a move sticks, the pointer is left short of the target, on lain's display.
- **`Key { code, down }`:** `NotifyKeyboardKeycode(code, down)`, evdev as is.
- **`Button { code, down }`:** `NotifyPointerButton(code as i32, down)`, an evdev button code (not tested
  here: no button events).
- **`Scroll { dx, dy, source }`:**
  - `Finger`: `NotifyPointerAxis(dx, dy, FINGER)`.
  - `Continuous`: `NotifyPointerAxis(dx, dy, CONTINUOUS)`.
  - `Wheel`: `NotifyPointerAxis(dx, dy, WHEEL)`, where 10 units is one detent (GTK saw dy = 1.0 per 10).
    Or `NotifyPointerAxisDiscrete` for whole detents. Which one depends on the unit the contract gives
    `Scroll` for `Wheel` (see "Contract notes").
- **`ScrollStop { source }`:** `NotifyPointerAxis(0, 0, source | FINISH)`, always with a zero delta: Mutter
  drops a delta that comes with `FINISH` (§5), so the last `Scroll` must have gone out on its own. Nothing
  for `Wheel`: Mutter ignores it.

### `CursorState` and `CursorSource`

`CursorState` is shared between lain-gnome and lain-linux-video, which writes it from the virtual stream's
metadata. It holds:
- the position in device pixels;
- whether the metadata is valid;
- the stream's scale and the monitor's origin (lain-gnome writes these on each layout change);
- the current image as an `Arc<CursorImage>`.

The writer turns each new bitmap into `CursorImage { pixel_width, pixel_height, scale: monitor scale,
hotspot: hot ÷ scale, pixels }`:
- swizzle RGBA to BGRA;
- keep it premultiplied, as it already is;
- copy row by row using `stride`.

It replaces the `Arc` only when a new bitmap arrives, which is when Mutter sets `bitmap_offset`.
`CursorSource::current()` returns the `Arc`, or `None` while the metadata is invalid.

### Power

**Injected input already counts as activity** (§7), so `PowerBackend::user_activity` can be a no-op.
`IdleMonitor.ResetIdletime` is available if wanted.

### Contract notes for the lead

- **`DisplayBackend::create`:** "active and listed" is reachable on GNOME only if `create` negotiates the
  PipeWire format itself. The monitor doesn't exist until a consumer has fixed the size.
  - **Either:** lain-gnome links `pipewire` for a short-lived negotiating consumer. Recommended: exp8 shows
    the handover works.
  - **Or:** the contract lets the display appear after `VideoBackend::start`, and the core waits for it in
    `monitors()`.
- **`ScrollSource::Continuous`:** its doc ("no kinetic continuation by the desktop") isn't what GTK 4 does
  (§5). Leave it to open spike 4.
- **Cursor format:** `CursorImage` (premultiplied BGRA) is fine; the conversion is a swizzle.
- **`InputAction` units** (global logical pixels, evdev codes, Wayland scroll signs) all match Mutter's.
- **`InputAction::Scroll` with `ScrollSource::Wheel`:** the doc says logical pixels but not how many make a
  detent, and Mutter's wheel axis counts 10 units per detent. The lead should fix the convention in
  `input.rs`'s doc, so lain-input and lain-gnome can't end up 10× apart. Either:
  - `Wheel` deltas are logical pixels at 10 per detent, passed through as `NotifyPointerAxis(…, WHEEL)`
    (Swift's injector also sends wheel notches as pixel deltas); or
  - `Wheel` deltas are whole detents, sent with `NotifyPointerAxisDiscrete`.
- **The session ending on Mutter's side:** `DisplayBackend` has no error channel for it. The design above
  signals it by taking lain's entry out of `monitors()`, which the core already handles; say so in the
  contract's doc.
- **`cursor_location` off lain's display** is `None` on GNOME (the lead's decision, below): a documented
  difference from the Mac host's warp detection.
- **No changes needed** to the rest: `monitors`, `InputBackend` and `CursorSource` fit.

## Design decisions taken by the lead (2026-10-31)

Taken from the results above, without new experiments. They override the recommended design where the two
differ.

1. **Input gets its own RemoteDesktop session, independent of the display's `create` and `destroy`.** It
   holds a consumer-less `RecordMonitor` stream for every monitor, lain's `Meta-*` connector included, and
   `NotifyPointerMotionAbsolute` goes to those streams (§4: a stream needs no consumer, and a second
   session's stream takes motion, exp6). So input keeps working in an input-only session, when video fails,
   or when the owner stops the display's capture from GNOME Shell's sharing indicator. The input session's
   streams follow the set of monitors as described under `MoveTo`.
2. **lain uses `ApplyMonitorsConfig` method 1 only.** Never method 2: it shows GNOME Shell's "Keep these
   display settings?" dialog, which nobody at the iPad can answer (§3).
3. **lain stores the owner's arrangement only after it has been stable for longer than GNOME's revert
   timeout, comparing with the last stored arrangement.** A change the owner makes in GNOME Settings (method
   2) that is reverted, or left to time out, is never stored; a layout equal to the stored one isn't
   rewritten.
4. **lain re-applies the spec's scale whenever lain's display is at another scale** (with method 1, keeping
   its position), whether Mutter reset it on `create`, after a change in the set of monitors, or for any
   other reason. A scale other than `spec.scale` is never stored as the owner's choice.
5. **`cursor_location` is `None` while the pointer is off lain's display.** It is a documented difference
   from the Mac host, whose warp detection samples the cursor anywhere on the desktop: on GNOME, the client
   doesn't see warps that happen off lain's display.
