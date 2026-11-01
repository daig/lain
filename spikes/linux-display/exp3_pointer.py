#!/usr/bin/env python3
"""Experiment 3: the coordinate space of NotifyPointerMotionAbsolute, the cursor metadata, and user activity.

One session records the virtual monitor (2752x2064@120, set to scale 2 to the right of the physical monitor,
temporarily) and the physical monitor (RecordMonitor HDMI-1), both with cursor-mode=metadata, so pwprobe sees
the cursor's position on each stream. Then:

  1. Read where the pointer is now (the physical stream's cursor metadata), to put it back at the end.
  2. Absolute motion to points on the virtual stream, chosen so that "logical" (0..1376) and "physical"
     (0..2752) interpretations differ; record the metadata position after each.
  3. Relative motion from the virtual monitor's centre.
  4. User activity: with the desktop idle for at least 1.5 s, inject one kind of event and read
     IdleMonitor.GetIdletime: motion, scroll (NotifyPointerAxis over the virtual monitor) and Shift.
  5. Put the pointer back where it was (absolute motion on the physical stream).

Input safety: motion and scrolling only while the pointer is over the virtual monitor (which shows only the
wallpaper); one Shift press and release; no buttons.
"""

import time

from mutter import (AXIS_FINISH, AXIS_FINGER, AXIS_WHEEL, KEY_LEFTSHIFT, DisplayConfig, Idle, Probe, Session,
                    emit, log, pump, pump_until)

W, H, FPS = 2752, 2064, 120
PHYS = "HDMI-1"


def last_cursor(probe):
    cs = probe.of("cursor")
    return cs[-1] if cs else None


def settle(probe, n_before, timeout=0.5):
    pump_until(lambda: len(probe.of("cursor")) > n_before, timeout)
    pump(0.08)
    return last_cursor(probe)


def wait_idle(idle, min_ms, timeout):
    """Waits until the desktop has been idle at least min_ms; returns the idle time then, or None."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ms = idle.ms()
        if ms >= min_ms:
            return ms
        pump(max(0.05, (min_ms - ms) / 1000))
    return None


def main():
    s = Session()
    dc = DisplayConfig(s.bus)
    idle = Idle(s.bus)
    before = dc.summary()
    emit("before", layout=before)
    vprobe = pprobe = None
    home = None
    try:
        vpath = s.record_virtual()
        ppath = s.record_monitor(PHYS)
        s.start()
        assert s.wait_nodes(5), "no nodes"
        vprobe = Probe(s.node(vpath), W, H, FPS, 120, bitmaps=True)
        pprobe = Probe(s.node(ppath), 3840, 2160, 60, 120, bitmaps=True)
        assert pump_until(lambda: vprobe.first("format") and pprobe.first("format"), 5), "no formats"
        assert pump_until(lambda: any(m["connector"] != PHYS for m in dc.state()["monitors"]), 5)
        emit("formats", virtual=vprobe.first("format"), physical=pprobe.first("format"))

        st = dc.state()
        v = next(m for m in st["monitors"] if m["connector"] != PHYS)
        mode = v["current_mode"]["id"]
        pmode = next(m for m in st["monitors"] if m["connector"] == PHYS)["current_mode"]["id"]
        dc.apply(1, [(0, 0, 1.0, 0, True, [(PHYS, pmode)]), (3840, 0, 2.0, 0, False, [(v["connector"], mode)])])
        pump(0.7)
        emit("layout", logical=dc.state()["logical_monitors"])

        pump_until(lambda: last_cursor(pprobe) is not None or last_cursor(vprobe) is not None, 2)
        home = last_cursor(pprobe)
        emit("home", physical=home, virtual=last_cursor(vprobe))
        if not home or not home.get("valid"):
            emit("error", what="pointer position on the physical monitor unknown; not injecting")
            return

        # 2. absolute motion, stream-local
        # Each move is (x, y) in the stream's coordinates; "C" marks a return to the centre between probes,
        # so that a move starting at the monitor's left edge can be told apart from one starting inside.
        points = [(688, 516), (10, 10), "C", (10, 10), "C", (500, 400), (1000, 800), (1370, 1025),
                  (1375.5, 1031.5), (2000, 1500), "C", (0, 0), (5, 5), "C", (-50, -50), "C", (0, 516), (3, 516),
                  "C", (688.25, 516.75), (688.5, 516.5)]
        for pt in points:
            x, y = (688, 516) if pt == "C" else pt
            n_v, n_p = len(vprobe.of("cursor")), len(pprobe.of("cursor"))
            s.move_abs(vpath, x, y)
            cv = settle(vprobe, n_v)
            pump(0.05)
            cp = pprobe.of("cursor")[n_p:]
            emit("abs", sent=[x, y], centre=pt == "C", virtual_meta=cv, physical_meta_changes=cp[-1:] if cp else [])

        # 3. relative motion from the centre
        s.move_abs(vpath, 688, 516)
        settle(vprobe, len(vprobe.of("cursor")))
        for (dx, dy) in [(10, 0), (0, 10), (-20, -20), (0.5, 0.5)]:
            n_v = len(vprobe.of("cursor"))
            s.rd.NotifyPointerMotionRelative(float(dx), float(dy))
            emit("rel", sent=[dx, dy], virtual_meta=settle(vprobe, n_v))

        # 4. user activity
        s.move_abs(vpath, 688, 516)
        for kind in ["motion", "axis_finger", "axis_wheel", "shift"]:
            before_ms = wait_idle(idle, 1500, 20)
            if before_ms is None:
                emit("activity", event=kind, skipped="desktop never idle for 1.5 s")
                continue
            if kind == "motion":
                s.move_abs(vpath, 700, 520)
            elif kind == "axis_finger":
                s.axis(0.0, 1.0, AXIS_FINGER)
                s.axis(0.0, 0.0, AXIS_FINGER | AXIS_FINISH)
            elif kind == "axis_wheel":
                s.axis(0.0, 10.0, AXIS_WHEEL)
            elif kind == "shift":
                s.key(KEY_LEFTSHIFT, True)
                s.key(KEY_LEFTSHIFT, False)
            pump(0.1)
            emit("activity", event=kind, idle_before_ms=before_ms, idle_after_ms=idle.ms())

        emit("cursor_bitmaps", virtual=[c for c in vprobe.of("cursor") if "bitmap" in c][:4],
             physical=[c for c in pprobe.of("cursor") if "bitmap" in c][:2])
        emit("virtual_stats", stats=vprobe.of("stats")[-3:])
    finally:
        if home and home.get("valid"):
            s.move_abs(ppath, float(home["x"]), float(home["y"]))
            pump(0.2)
            emit("restored", physical_meta=last_cursor(pprobe) if pprobe else None, target=[home["x"], home["y"]])
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
