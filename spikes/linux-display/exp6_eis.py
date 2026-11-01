#!/usr/bin/env python3
"""Experiment 6: libei through RemoteDesktop.ConnectToEIS, and absolute motion on a stream nobody consumes.

Session A records the virtual monitor (scale 2, right of the physical one, temporarily) and the physical
monitor, both consumed by pwprobe for cursor metadata. It connects to EIS and reports the seat, the devices,
their capabilities and regions (with mapping ids, to match against each stream's Parameters). Then, with the
pointer over the virtual monitor, absolute EIS motion to a few region-relative points and one EIS scroll, and
the IdleMonitor before and after an EIS motion. Cursor bitmaps are checked for premultiplied alpha.

Restoring the pointer is the second test: session B (another connection) has a RecordMonitor stream for the
physical monitor with no PipeWire consumer, and its NotifyPointerMotionAbsolute puts the pointer back; session
A's physical-stream metadata checks it against home. If that fails, session A's own stream does it, checked the
same way with one retry, and a `restore_failed` line if the pointer still isn't home.

Input safety: motion only over the virtual monitor. The EIS scroll goes through the relative virtual pointer,
so it lands wherever the pointer is: it runs only if the absolute moves onto the virtual monitor ran, and only
if the virtual stream's cursor metadata puts the pointer inside the virtual monitor right before it
(require_pointer_on); otherwise it is skipped. No keys and no buttons.
"""

import os
import time

from ei import Ei
from mutter import (DisplayConfig, Idle, NotOnVirtualMonitor, Probe, Session, at_home, emit, pointer_on, pump,
                    pump_until, require_pointer_on, restore_pointer)

W, H, FPS = 2752, 2064, 120
PHYS = "HDMI-1"


def main():
    a = Session()
    dc = DisplayConfig(a.bus)
    idle = Idle(a.bus)
    before = dc.summary()
    emit("before", layout=before)
    vprobe = pprobe = ei = b = None
    home = None
    abs_moves_ran = False
    try:
        vpath = a.record_virtual()
        ppath = a.record_monitor(PHYS)
        a.start()
        assert a.wait_nodes(5)
        vprobe = Probe(a.node(vpath), W, H, FPS, 400, bitmaps=True)
        pprobe = Probe(a.node(ppath), 3840, 2160, 60, 400, bitmaps=True)
        assert pump_until(lambda: vprobe.first("format") and pprobe.first("format"), 5)
        assert pump_until(lambda: any(m["connector"] != PHYS for m in dc.state()["monitors"]), 5)
        st = dc.state()
        v = next(m for m in st["monitors"] if m["connector"] != PHYS)
        pmode = next(m for m in st["monitors"] if m["connector"] == PHYS)["current_mode"]["id"]
        dc.apply(1, [(0, 0, 1.0, 0, True, [(PHYS, pmode)]),
                     (3840, 0, 2.0, 0, False, [(v["connector"], v["current_mode"]["id"])])])
        pump(0.7)
        emit("stream_params", virtual=a.stream_params(vpath), physical=a.stream_params(ppath),
             logical=dc.state()["logical_monitors"])
        # The physical stream's first metadata may say "hidden" (GNOME hides the pointer while typing); wait
        # for a visible position.
        pump_until(lambda: pprobe.of("cursor") and pprobe.of("cursor")[-1].get("valid"), float(os.environ.get("HOME_WAIT", "15")))
        home = pprobe.of("cursor")[-1] if pprobe.of("cursor") else None
        emit("physical_cursor_meta_so_far", events=pprobe.of("cursor")[:3])
        emit("home", physical=home)

        fd = a.rd.ConnectToEIS({}).take()
        ei = Ei(fd)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not ei.device_with("pointer_absolute"):
            ei.dispatch(0.1, bind=["pointer", "pointer_absolute", "scroll", "keyboard", "button"])
        ei.dispatch(0.3)
        emit("eis_events", events=ei.log)
        emit("eis_devices", devices=list(ei.devices.values()))
        if not home or not home.get("valid"):
            emit("error", what="pointer position unknown (hidden); not injecting")
            home = None
            return

        absdev = ei.device_with("pointer_absolute")
        if absdev:
            regions = ei.devices[absdev]["regions"]
            vmap = a.stream_params(vpath).get("mapping-id")
            vr = next((r for r in regions if r["mapping_id"] == vmap), None)
            emit("virtual_region", region=vr, mapping_id=vmap)
            if vr:
                ei.start(absdev)
                for (x, y) in [(688, 516), (10, 10), (1375, 1031), (100.5, 200.25), (688, 516)]:
                    n = len(vprobe.of("cursor"))
                    lib_x, lib_y = vr["x"] + x, vr["y"] + y
                    from ei import lib
                    lib.ei_device_pointer_motion_absolute(absdev, lib_x, lib_y)
                    ei.frame(absdev)
                    pump_until(lambda: len(vprobe.of("cursor")) > n, 0.5)
                    pump(0.08)
                    emit("eis_abs", region_local=[x, y], sent=[lib_x, lib_y], virtual_meta=vprobe.of("cursor")[-1])
                # out-of-region point: what happens to absolute motion outside every region?
                n = len(vprobe.of("cursor"))
                lib.ei_device_pointer_motion_absolute(absdev, vr["x"] + 2000.0, vr["y"] + 500.0)
                ei.frame(absdev)
                pump(0.3)
                emit("eis_abs_outside", sent=[vr["x"] + 2000, vr["y"] + 500],
                     virtual_meta=vprobe.of("cursor")[-1], changes=len(vprobe.of("cursor")) - n)
                lib.ei_device_pointer_motion_absolute(absdev, vr["x"] + 688.0, vr["y"] + 516.0)
                ei.frame(absdev)
                pump(0.2)
                abs_moves_ran = True

                # user activity through EIS
                t0 = time.monotonic()
                while idle.ms() < 1500 and time.monotonic() - t0 < 20:
                    pump(0.2)
                before_ms = idle.ms()
                lib.ei_device_pointer_motion_absolute(absdev, vr["x"] + 690.0, vr["y"] + 518.0)
                ei.frame(absdev)
                pump(0.1)
                emit("eis_activity", idle_before_ms=before_ms, idle_after_ms=idle.ms())
                ei.dispatch(0)
                lib.ei_device_stop_emulating(absdev)
                ei.dispatch(0)

        scrolldev = ei.device_with("scroll")
        if scrolldev and not abs_moves_ran:
            emit("eis_scroll", skipped="the absolute moves onto the virtual monitor didn't run")
            scrolldev = None
        if scrolldev:
            pump_until(lambda: pointer_on(vprobe, W, H) is not None, 1)
            try:
                require_pointer_on(vprobe, W, H, "EIS scroll")
            except NotOnVirtualMonitor as e:
                emit("eis_scroll", skipped=str(e))
                scrolldev = None
        if scrolldev:
            from ei import lib
            ei.start(scrolldev)
            lib.ei_device_scroll_delta(scrolldev, 0.0, 10.0)
            ei.frame(scrolldev)
            lib.ei_device_scroll_stop(scrolldev, True, True)
            ei.frame(scrolldev)
            lib.ei_device_stop_emulating(scrolldev)
            ei.dispatch(0.1)
            emit("eis_scroll", device=ei.devices[scrolldev]["name"], sent="delta(0,10) then stop", ok=True)

        emit("cursor_bitmaps", virtual=[c for c in vprobe.of("cursor") if "bitmap" in c][:3],
             physical=[c for c in pprobe.of("cursor") if "bitmap" in c][:2])
    finally:
        restored = None
        if home and home.get("valid"):
            # session B: a RecordMonitor stream with no consumer
            try:
                b = Session()
                bpath = b.record_monitor(PHYS)
                b.start()
                b.wait_nodes(3)
                pump(0.2)
                n = len(pprobe.of("cursor"))
                b.move_abs(bpath, float(home["x"]), float(home["y"]))
                pump(0.4)
                last, restored = at_home(pprobe, home)
                emit("restore_via_unconsumed_stream", ok=restored, meta=last, changes=len(pprobe.of("cursor")) - n)
            except Exception as e:
                emit("restore_via_unconsumed_stream", ok=False, error=str(e))
            if not restored:
                # Session A may already be closed by Mutter (exp6.jsonl lines 18-19): never let a failed restore
                # skip the cleanup below.
                try:
                    restore_pointer(a, ppath, pprobe, home)
                except Exception as e:
                    emit("restore_failed", via="session A", error=str(e))
        if ei:
            ei.close()
        if b:
            b.close()
        for p in (vprobe, pprobe):
            if p:
                p.stop()
        a.stop()
        pump_until(lambda: len(dc.state()["monitors"]) == 1, 5)
        after = dc.summary()
        emit("after", layout=after, same_as_before=after == before)
        a.close()


if __name__ == "__main__":
    main()
