#!/usr/bin/env python3
"""Experiment 4: NotifyPointerAxis flags as a client sees them, motion in client coordinates, and frame delivery
at 120 Hz with changing content.

Creates the virtual monitor (2752x2064@120, scale 2, right of the physical monitor, temporarily), opens
gtkprobe.py fullscreen on it (it animates every frame and logs the input it gets), moves the pointer over it
and scrolls with each combination of flags. One Shift press and release goes to the probe window: the only key
event any committed script sends. The pointer goes back where it was at the end, checked against the physical
stream's metadata, with one retry and a `restore_failed` line if it still isn't there. Before the first scroll, before every scroll case and before the Shift, the
virtual stream's cursor metadata must put the pointer inside the virtual monitor (require_pointer_on);
otherwise the run stops there.

The probe window takes keyboard focus for the few seconds it is open.
"""

import json
import os
import subprocess
import time

from mutter import (AXIS_CONTINUOUS, AXIS_FINGER, AXIS_FINISH, AXIS_WHEEL, HERE, KEY_LEFTSHIFT, DisplayConfig,
                    Probe, Session, emit, pump, pump_until, require_pointer_on, restore_pointer)

W, H, FPS = 2752, 2064, 120
PHYS = "HDMI-1"


class Gtk:
    def __init__(self, connector, seconds):
        self.proc = subprocess.Popen(["python3", os.path.join(HERE, "gtkprobe.py"), connector, str(seconds)],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.events, self._buf = [], ""

    def poll(self):
        try:
            chunk = self.proc.stdout.read()
        except BlockingIOError:
            chunk = None
        if chunk:
            self._buf += chunk
            *lines, self._buf = self._buf.split("\n")
            self.events += [json.loads(x) for x in lines if x.strip()]
        return self.events

    def since(self, n):
        return self.poll()[n:]


def main():
    s = Session()
    dc = DisplayConfig(s.bus)
    before = dc.summary()
    emit("before", layout=before)
    vprobe = pprobe = gtk = None
    home = None
    try:
        vpath = s.record_virtual()
        ppath = s.record_monitor(PHYS)
        s.start()
        assert s.wait_nodes(5)
        probe_s = 60 + int(float(os.environ.get("HOME_WAIT", "15")))
        vprobe = Probe(s.node(vpath), W, H, FPS, probe_s)
        pprobe = Probe(s.node(ppath), 3840, 2160, 60, probe_s)
        assert pump_until(lambda: vprobe.first("format") and pprobe.first("format"), 5)
        assert pump_until(lambda: any(m["connector"] != PHYS for m in dc.state()["monitors"]), 5)
        st = dc.state()
        v = next(m for m in st["monitors"] if m["connector"] != PHYS)
        pmode = next(m for m in st["monitors"] if m["connector"] == PHYS)["current_mode"]["id"]
        dc.apply(1, [(0, 0, 1.0, 0, True, [(PHYS, pmode)]),
                     (3840, 0, 2.0, 0, False, [(v["connector"], v["current_mode"]["id"])])])
        pump(0.7)
        # The physical stream's metadata says "hidden" while GNOME hides the pointer (when someone types); wait
        # up to HOME_WAIT seconds for a visible position.
        pump_until(lambda: pprobe.of("cursor") and pprobe.of("cursor")[-1].get("valid"),
                   float(os.environ.get("HOME_WAIT", "15")))
        home = pprobe.of("cursor")[-1] if pprobe.of("cursor") else None
        if not home or not home.get("valid"):
            emit("error", what="pointer position unknown; not injecting")
            return
        emit("home", physical=home)

        # pointer onto the virtual monitor first (crossing the shared edge away from its top), then the window
        s.move_abs(vpath, 688, 516)
        pump(0.2)
        emit("on_virtual", virtual_meta=require_pointer_on(vprobe, W, H, "anything"))
        gtk = Gtk(v["connector"], 14)
        assert pump_until(lambda: any(e["ev"] == "ready" for e in gtk.poll()), 6), "probe window not ready"
        emit("gtk_ready", ready=next(e for e in gtk.events if e["ev"] == "ready"))

        # motion in client coordinates
        n = len(gtk.poll())
        for (x, y) in [(100, 100), (688, 516), (1375, 1031), (100.5, 200.25)]:
            s.move_abs(vpath, x, y)
            pump(0.1)
        emit("gtk_motion", sent=[[100, 100], [688, 516], [1375, 1031], [100.5, 200.25]],
             got=[[e["x"], e["y"]] for e in gtk.since(n) if e["ev"] == "motion"])
        s.move_abs(vpath, 688, 516)
        pump(0.2)

        cases = [
            ("finger", [(0, 10, AXIS_FINGER)] * 5 + [(0, 0, AXIS_FINGER | AXIS_FINISH)]),
            ("finger_dx", [(10, 0, AXIS_FINGER)] * 3 + [(0, 0, AXIS_FINGER | AXIS_FINISH)]),
            ("finger_negative", [(0, -10, AXIS_FINGER)] * 3 + [(0, 0, AXIS_FINGER | AXIS_FINISH)]),
            ("continuous", [(0, 10, AXIS_CONTINUOUS)] * 3 + [(0, 0, AXIS_CONTINUOUS | AXIS_FINISH)]),
            ("wheel", [(0, 10, AXIS_WHEEL)] * 3),
            ("wheel_finish", [(0, 10, AXIS_WHEEL), (0, 0, AXIS_WHEEL | AXIS_FINISH)]),
            ("no_source", [(0, 10, 0)] * 3 + [(0, 0, AXIS_FINISH)]),
            ("finish_with_delta", [(0, 10, AXIS_FINGER), (0, 10, AXIS_FINGER | AXIS_FINISH)]),
            ("discrete_v+1", "d0+1"),
            ("discrete_h+1", "d1+1"),
        ]
        for label, steps in cases:
            pump(0.4)
            require_pointer_on(vprobe, W, H, f"axis case {label}")
            n = len(gtk.poll())
            if isinstance(steps, str):
                s.axis_discrete(int(steps[1]), int(steps[2:]))
            else:
                for (dx, dy, flags) in steps:
                    s.axis(float(dx), float(dy), flags)
                    pump(0.016)
            pump(0.5)
            emit("axis", case=label, got=[{k: v for k, v in e.items() if k != "t"} for e in gtk.since(n)
                                         if e["ev"] in ("scroll", "scroll-begin", "scroll-end", "decelerate")])

        n = len(gtk.poll())
        require_pointer_on(vprobe, W, H, "Shift")
        s.key(KEY_LEFTSHIFT, True)
        s.key(KEY_LEFTSHIFT, False)
        pump(0.3)
        emit("key", got=[e for e in gtk.since(n) if e["ev"] == "key"])

        # frame delivery with the animated window: the probe's last few one-second windows
        pump(3)
        emit("frame_rate", gtk_frames=[e["per_second"] for e in gtk.poll() if e["ev"] == "frames"],
             pipewire=[{k: e[k] for k in ("window_buffers", "window_pictures", "max_gap_ms")}
                       for e in vprobe.of("stats")[-6:]])
        frames = vprobe.of("frame")
        if len(frames) > 20:
            gaps = sorted((b["t"] - a["t"]) * 1000 for a, b in zip(frames[-200:], frames[-199:]))
            emit("frame_gaps_ms", n=len(gaps), p50=round(gaps[len(gaps) // 2], 2),
                 p95=round(gaps[int(len(gaps) * 0.95)], 2), max=round(gaps[-1], 2),
                 damage_sample=[f.get("damage") for f in frames[-3:]])
    finally:
        if gtk:
            gtk.proc.terminate()
            gtk.proc.wait(5)
        if home and home.get("valid"):
            restore_pointer(s, ppath, pprobe, home)
        for p in (vprobe, pprobe):
            if p:
                p.stop()
        s.stop()
        pump_until(lambda: len(dc.state()["monitors"]) == 1, 5)
        after = dc.summary()
        emit("after", layout=after, same_as_before=after == before)
        s.close()


if __name__ == "__main__":
    main()
