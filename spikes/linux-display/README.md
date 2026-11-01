# Spike B: Mutter's virtual monitor as the iPad's display, and the pointer

Open spikes 2 and 3 of `docs/LINUX-HOST.md`: how `org.gnome.Mutter.ScreenCast.RecordVirtual`, linked to an
`org.gnome.Mutter.RemoteDesktop` session, behaves as lain's iPad display (2752×2064, scale 2, 120 Hz), and how
input reaches it and the physical monitors. Run on 2026-10-31 on the reference machine: Ubuntu 26.04.1, GNOME
Shell 50.1 on Wayland, PipeWire 1.6.2, one 3840×2160@60 monitor (HDMI-1, scale 1, primary) on the Radeon iGPU.
ScreenCast interface version 4, RemoteDesktop version 1 (`SupportedDeviceTypes` = 7: keyboard, pointer, touch).

**In short:** it works, and nothing needs consent.
- The virtual monitor takes exactly the size and maximum frame rate the PipeWire consumer asks for.
- It runs at a steady 120 Hz, over both DMA-BUF and shared memory.
- It can be scaled to 2 and placed anywhere adjacent, but Mutter never remembers where. lain stores the
  arrangement itself.
- `NotifyPointerMotionAbsolute` takes stream-local logical pixels. libei's absolute pointer takes global
  logical pixels.
- Cursor position and image come in the stream's metadata, in device pixels, as premultiplied RGBA.
- All injected input counts as user activity.
- Two traps to design around: GNOME Shell's top-panel pointer barrier, and the fact that the monitor only
  exists once a consumer has negotiated the stream's format.

The lock screen was **not** tested. It needs a supervised test (see "Not tested").

## What changed on the desktop, and how it was restored

- **Virtual monitors (`Meta-0`):** every experiment created them and stopped its session at the end. Each
  experiment compared the layout at its end with the layout at its start, and every one matched the
  pre-wave snapshot (`HDMI-1` alone, 3840×2160@60, scale 1, primary, at 0,0, layout mode 1).
- **Temporary layouts:** experiments 2–7 applied layouts with `ApplyMonitorsConfig`, temporary (method 1)
  except in exp2's `persist` run. They put the virtual monitor at scale 2, right of or below `HDMI-1`. In
  exp2, verify-only (method 0) calls also tried a left placement that moved `HDMI-1`'s logical origin.
  `HDMI-1`'s mode, scale and primary flag were never changed.
- **`~/.config/monitors.xml`:** exp2's `persist` run (method 2) made Mutter write this file a few seconds
  later. It didn't exist before. It held only `HDMI-1`'s configuration, identical to the default, and it was
  deleted both times. The script now waits for the file and deletes it itself.
- **The pointer:**
  - It moved over the empty virtual monitor in exp3, exp4 and exp6. Every run first read its position from
    the physical stream's cursor metadata and put it back exactly at the end (checked the same way).
  - Scrolling happened only over the virtual monitor: over the wallpaper, or over this spike's own probe
    window.
  - No button events.
- **Keys:** one Shift press and release in each of exp3 and exp4.
- **Focus:** the GTK probe window (`gtkprobe.py`, fullscreen on the virtual monitor) took keyboard focus for
  5–14 s at a time in exp4 and exp5.

## Files

| File | What it is |
|---|---|
| `pwprobe.c`, `build.sh` | A PipeWire consumer for one Mutter node: negotiates a given size and max frame rate, shm or DMA-BUF (`dmabuf=<modifier>`); prints the format, frames (with damage), cursor metadata (with bitmap checks) and per-second stats as JSON lines. `./build.sh [outdir]` (needs `libpipewire-0.3-dev`). |
| `mutter.py` | Helpers: one private D-Bus connection per experiment, RemoteDesktop+ScreenCast sessions, DisplayConfig, IdleMonitor, running `pwprobe`. |
| `ei.py` | A ctypes binding of the libei sender API (only the runtime `libei.so.1` is installed, not the headers). |
| `gtkprobe.py` | A GTK 4 window, fullscreen on a given connector: logs the motion, scroll and key events it receives, and redraws a small square on every frame-clock tick. |
| `exp1_create.py` … `exp8_handover.py` | The experiments below. Each prints JSON result lines. |
| `results/` | Their output from this run (the monitor's serial number redacted). |

Run them as `PWPROBE=<outdir>/pwprobe python3 expN_….py`, one at a time. `exp5_rate.py` takes
`PROBE_OPTS=dmabuf=144115188080057091` for DMA-BUF.

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
  `maxFramerate` 120/1, `DisplayConfig` lists a new monitor 30–60 ms later:
  - connector `Meta-0`, vendor `MetaVendor`, product `Virtual remote monitor`;
  - a single mode, `2752x2064@120.000`;
  - supported scales 1, 1.33, 2, 2.67; it comes up at **scale 1**;
  - placed to the right of the existing layout, at (3840, 0).

  The mode's refresh is the consumer's `maxFramerate`: asking for 60, 144 or 240 gave modes at 60, 144 and
  240 Hz. GTK sees the monitor at scale 2 (once applied) and 120 000 mHz.
- **The serial changes every time** (`0x000001`, `0x00000a`, `0x00000b`, `0x000020`, `0x000029`, …). So does
  each stream's `mapping-id`. Nothing identifies "lain's monitor" across sessions.
- **Telling which monitor is lain's:**
  - A virtual stream's `Parameters` hold only `mapping-id`. A `RecordMonitor` stream also has `position`,
    `size` and `output-name`.
  - So lain finds its monitor as the one that appeared in `DisplayConfig` after negotiation, or as the EIS
    region with the stream's `mapping-id` (§4), which also gives its global rectangle.
  - `is-platform: true` made no visible difference.
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
| DMA-BUF, modifier `0x200000000401b03`, 1 plane | 120 | 8.33 ms | 8.39 | 8.41 | 8.43 |
| shared memory (MemFd) | 120 | 8.25 ms | 8.75 | 9.42 | 16.6 |
| DMA-BUF at `maxFramerate` 240 | 240 | 4.16 ms | 4.23 | 4.25 | 4.25 |

- **Pacing:** it is timer-driven and very regular, and the GTK frame clock on that monitor ticks at the
  same rate.
- **When the client can't keep up, the rate drops with it.** A client that repainted the whole 2752×2064
  surface in software every tick fell to 60–87 Hz. That was the client's cost, not Mutter's.
- **Shared memory is a GPU readback**, so lain-linux-video should use DMA-BUF (L3). Whether VA-API takes
  these modifiers is spike A's question.
- **Damage:** the `VideoDamage` metadata carries full-frame and partial rectangles in device pixels.

### 3. Arrangement, scale and persistence (exp2)

- **What `ApplyMonitorsConfig` accepts** with the virtual monitor in it (method 0 checks without applying;
  1 is temporary, 2 persistent):
  - placements left, right (with a y offset) and below-centred;
  - scale 2 (and the other listed scales).
- **What it rejects:**
  - a gap or an overlap: "Logical monitors not adjacent";
  - a negative position: "Invalid logical monitor position (-1376, 0)". So putting the iPad to the left
    means moving the physical monitor to x = 1376: the global origin stays at the layout's top-left corner;
  - scale 1.5: "not valid for resolution 2752x2064".
- **It takes effect at once** (the call takes 16 ms), and the next `GetCurrentState` shows it.
- **Nothing persists:**
  - **Temporary:** after destroy and re-create, the monitor is back at (3840, 0), scale 1.
  - **Persistent:** also back at the default. Mutter rewrote `monitors.xml` a few seconds later, but with
    only `HDMI-1`'s logical monitor: the virtual monitor's configuration is left out. With a new serial
    every time, Mutter couldn't match it anyway.
- **So lain stores the owner's arrangement itself and applies it after every `create`:** scale 2, the side
  and offset relative to a physical monitor (identified by connector, vendor, product and serial).
  - It records a new arrangement when `MonitorsChanged` shows the owner moving the monitor (in GNOME
    Settings, for example).
  - It applies with method 1: method 2 only rewrites `monitors.xml` and saves nothing for the virtual
    monitor.

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
- **What was seen:** some moves from the physical monitor into the virtual one stopped at the shared edge
  (x = 3840) while y moved. This happened when the straight line from the old position to the new one
  crossed x = 3840 near the top: at y ≈ 10 or 14, not at y ≈ 400.
- **The cause:** `layout.js` `_updatePanelBarrier()` puts a `Meta.Barrier` at the primary monitor's right
  edge, from y = 0 to the panel's height, that lets the pointer through only in the −x direction. Mutter
  applies barriers to absolute motion along the line from the current position.
- **What it means for lain:**
  - Moves within lain's display, and moves out of it, are unaffected.
  - A jump from the physical monitor onto the iPad display can stick at the edge if the iPad display is to
    the right of the primary monitor and the line crosses that edge within the panel's height (about 32
    logical pixels at scale 1).
  - **Fix in `lain-gnome`:** when the pointer isn't on the target monitor, route the move through a point
    below the panel's band. For example, first move vertically within the current monitor to y = max(y,
    64), then to the target's x at that y, then to the target. Then check where the pointer actually went
    with `cursor_location`.
- **Not checked:** whether libei absolute motion is also subject to the barrier. Testing it would need the
  pointer near the top of the user's monitor.

### 5. NotifyPointerAxis and NotifyPointerAxisDiscrete flags (exp4, as a GTK 4 client sees them)

Flags: 1 = finish, 2 = wheel, 4 = finger, 8 = continuous. Positive `dy` scrolls down and positive `dx`
right, which is Wayland's convention and `InputAction::Scroll`'s.

| Sent | GTK 4 received |
|---|---|
| finger: `(0, 10, FINGER)` ×5, then `(0, 0, FINGER\|FINISH)` | `scroll-begin`; 5 × `scroll` dy = 10.0, unit `surface`, source `touchpad`; `scroll-end`; `decelerate` vy ≈ 610 px/s (GTK's own kinetic fling) |
| finger, dx and negative | the same, on the other axis and with the other sign |
| continuous: `(0, 10, CONTINUOUS)` ×3 + finish | the same as finger, with source `trackpoint`, **and GTK still decelerates kinetically** |
| no source flag + finish | the same as finger (source `touchpad`) |
| finish with a delta: `(0, 10, FINGER\|FINISH)` | the delta, then `scroll-end` and `decelerate` |
| wheel: `(0, 10, WHEEL)` ×3 | 3 × `scroll` dy = 1.0, unit `wheel`, source `mouse`, with no begin or end: 10 is one detent |
| wheel + finish | finish ignored |
| `NotifyPointerAxisDiscrete(0, +1)` / `(1, +1)` | one wheel step down / right |

Deltas arrive 1:1 in logical pixels.

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
    coloured).
  - It comes **only when the sprite changes** (`bitmap_offset` ≠ 0). Every other update carries the
    position alone, so the reader caches the last bitmap.
- **Cursor-only updates are buffers with an empty chunk** (size 0). In exp3, 452 of 471 buffers were
  cursor-only. A video consumer must not treat them as frames.
- **Validity:**
  - The metadata turns invalid (id 0) when the pointer leaves a stream's monitor.
  - A stream can also report a position just outside itself while the sprite still overlaps it: the
    physical stream showed x = 3843 when the pointer was 3 logical pixels into the virtual monitor.
  - It stayed invalid for minutes on the physical stream while the user was at the keyboard. Most likely
    GNOME hides the pointer while you type. Either way, the position is unknown while the cursor is hidden.

### 7. User activity (exp3, exp6)

Injected input resets Mutter's idle time:

| Input injected | Idle time before | Idle time after |
|---|---|---|
| absolute motion | ≥ 1.5 s | ~100 ms (when it was read) |
| finger axis | ≥ 1.5 s | ~100 ms |
| wheel axis | ≥ 1.5 s | ~100 ms |
| Shift press and release | ≥ 1.5 s | ~100 ms |
| libei absolute motion | ≥ 1.5 s | ~100 ms |

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
- **Picture quality at scale 2:** the repeat of SL1.
- **Clipboard** (`EnableClipboard`/`Selection*`).

## Recommended design for `lain-gnome`

### `GnomeDisplay: DisplayBackend`

**The connection.** One zbus connection per display session; it holds the RemoteDesktop session and the
linked ScreenCast session, so dropping it ends both. `type Source = GnomeSource { node_id: u32, stream_path,
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

**Recording the owner's arrangement:** on each `MonitorsChanged` while lain's display exists, if its position
differs from the one lain applied, store it in `$XDG_CONFIG_HOME/lain/`. Store it relative to the monitor it
touches (that monitor's spec, edge, offset), never as absolute coordinates.

**`cursor_location()`:** read from `CursorState`, never from D-Bus (it's polled at 60 Hz).
- **Fed by:** lain-linux-video's reader of the virtual stream's metadata. lain-gnome also runs its own
  metadata-only consumer of one `RecordMonitor` stream per physical monitor, which can be negotiated tiny,
  since only the metadata matters. That second part is a choice for lain-gnome's agent. The cheaper
  alternative is to report `None` whenever the pointer is off the virtual monitor.
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
  - Streams: lain's display uses its `RecordVirtual` stream. Each physical monitor gets one `RecordMonitor`
    stream, with no consumer needed, created in the same session at `create` time. Keep them in step with
    `monitors()`: a `RecordMonitor` added after `Start` works for EIS. Whether it does for D-Bus motion
    wasn't checked, so create them before `Start`, or check.
  - Apply the barrier detour from §4 when the pointer isn't already on the target monitor.
- **`Key { code, down }`:** `NotifyKeyboardKeycode(code, down)`, evdev as is.
- **`Button { code, down }`:** `NotifyPointerButton(code as i32, down)`, an evdev button code (not tested
  here: no button events).
- **`Scroll { dx, dy, source }`:**
  - `Finger`: `NotifyPointerAxis(dx, dy, FINGER)`.
  - `Continuous`: `NotifyPointerAxis(dx, dy, CONTINUOUS)`.
  - `Wheel`: `NotifyPointerAxis(dx, dy, WHEEL)`, where 10 units is one detent. Or `NotifyPointerAxisDiscrete`
    for whole detents. `lain-input`'s wheel convention decides which.
- **`ScrollStop { source }`:** `NotifyPointerAxis(0, 0, source | FINISH)`. Nothing for `Wheel`: Mutter
  ignores it.

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
- **No changes needed** to the rest: `monitors`, `cursor_location`, `InputBackend` and `CursorSource` fit.
