#!/usr/bin/env python3
"""Experiment 7: which regions the EIS absolute pointer gets, and what a layout change does to them.

  1. A session that records only the virtual monitor: connect to EIS, list devices and regions.
  2. Apply scale 2 and move the virtual monitor below the physical one (temporarily): which EIS events arrive,
     and what the regions become.
  3. Add a RecordMonitor stream for the physical monitor to the running session (after Start): does a region
     for it appear?
No input is injected.
"""

import time

from ei import Ei
from mutter import DisplayConfig, Probe, Session, emit, pump, pump_until

W, H, FPS = 2752, 2064, 120
PHYS = "HDMI-1"


def eis_pump(ei, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        ei.dispatch(0.05, bind=["pointer", "pointer_absolute", "scroll", "keyboard", "button"])
        pump(0.01)


def main():
    a = Session()
    dc = DisplayConfig(a.bus)
    before = dc.summary()
    emit("before", layout=before)
    probe = ei = None
    try:
        vpath = a.record_virtual()
        a.start()
        assert a.wait_nodes(5)
        probe = Probe(a.node(vpath), W, H, FPS, 60)
        assert pump_until(lambda: probe.first("format") is not None, 5)
        assert pump_until(lambda: any(m["connector"] != PHYS for m in dc.state()["monitors"]), 5)
        ei = Ei(a.rd.ConnectToEIS({}).take())
        eis_pump(ei, 1.5)
        emit("virtual_only", mapping_id=a.stream_params(vpath).get("mapping-id"),
             devices=[d for d in ei.devices.values() if "pointer_absolute" in d["caps"]])

        n = len(ei.log)
        st = dc.state()
        v = next(m for m in st["monitors"] if m["connector"] != PHYS)
        pmode = next(m for m in st["monitors"] if m["connector"] == PHYS)["current_mode"]["id"]
        dc.apply(1, [(0, 0, 1.0, 0, True, [(PHYS, pmode)]),
                     (1232, 2160, 2.0, 0, False, [(v["connector"], v["current_mode"]["id"])])])
        eis_pump(ei, 1.5)
        emit("after_layout_change", events=ei.log[n:],
             devices=[d for d in ei.devices.values() if "pointer_absolute" in d["caps"]],
             logical=dc.state()["logical_monitors"])

        n = len(ei.log)
        try:
            ppath = a.record_monitor(PHYS)
            pump(0.5)
            eis_pump(ei, 1.0)
            emit("after_adding_physical_stream", stream=ppath, node=a.node(ppath), events=ei.log[n:],
                 devices=[d for d in ei.devices.values() if "pointer_absolute" in d["caps"]])
        except Exception as e:
            emit("after_adding_physical_stream", error=str(e))
    finally:
        if ei:
            ei.close()
        if probe:
            probe.stop()
        a.stop()
        pump_until(lambda: len(dc.state()["monitors"]) == 1, 5)
        after = dc.summary()
        emit("after", layout=after, same_as_before=after == before)
        a.close()


if __name__ == "__main__":
    main()
