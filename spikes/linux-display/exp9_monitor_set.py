#!/usr/bin/env python3
"""Experiment 9: what a change in the set of monitors does to lain's display, simulated with a second virtual
monitor as the "hotplugged" one (no physical monitor is touched, no input is injected).

  exp9_monitor_set.py hotplug  lain's session ("L": RecordVirtual 2752x2064@120) gets scale 2, below the
                               physical monitor, with method 1. Then another session ("X") adds a 1280x720
                               virtual monitor, and later removes it. Does L's arrangement survive each change?
  exp9_monitor_set.py close    X's monitor exists first. L records its own virtual monitor *and* a RecordMonitor
                               stream of X's monitor (as a per-monitor input stream would be). Then X stops, so
                               X's monitor goes away: does L's session close, taking L's virtual monitor with it?
  exp9_monitor_set.py sizes    RecordMonitor(HDMI-1), consumer-less, then consumers asking for smaller sizes:
                               does a monitor stream negotiate anything but the monitor's own size? Only the
                               format is printed; no picture is kept.
"""

import sys

from mutter import DisplayConfig, Probe, Session, emit, pump, pump_until, pw_node_info

W, H, FPS = 2752, 2064, 120
PHYS = "HDMI-1"


def virtuals(dc):
    return [m["connector"] for m in dc.state()["monitors"] if m["connector"] != PHYS]


def layout(dc):
    st = dc.state()
    return [{k: lm[k] for k in ("x", "y", "scale", "connectors")} for lm in st["logical_monitors"]]


def mode_of(st, connector):
    return next(m["current_mode"]["id"] for m in st["monitors"] if m["connector"] == connector)


def new_virtual(dc, w, h, fps, extra_monitor_of=None):
    """A session with one RecordVirtual (and optionally a RecordMonitor of another connector); returns once its
    monitor is listed."""
    known = set(virtuals(dc))
    s = Session()
    vpath = s.record_virtual()
    mpath = s.record_monitor(extra_monitor_of) if extra_monitor_of else None
    s.start()
    assert s.wait_nodes(5), "no node"
    probe = Probe(s.node(vpath), w, h, fps, 120)
    assert pump_until(lambda: probe.first("format") is not None, 5), "no format"
    assert pump_until(lambda: set(virtuals(dc)) - known, 5), "no monitor"
    connector = (set(virtuals(dc)) - known).pop()
    return s, probe, connector, mpath


def place_below(dc, lain, others):
    """Method 1: physical at (0,0), lain's monitor below it at scale 2, any other virtual right of the physical."""
    st = dc.state()
    lms = [(0, 0, 1.0, 0, True, [(PHYS, mode_of(st, PHYS))]),
           (1232, 2160, 2.0, 0, False, [(lain, mode_of(st, lain))])]
    for c in others:
        lms.append((3840, 0, 1.0, 0, False, [(c, mode_of(st, c))]))
    dc.apply(1, lms)
    pump(0.7)


def hotplug(dc, cleanup):
    L, lp, lain, _ = new_virtual(dc, W, H, FPS)
    cleanup += [(L, lp)]
    place_below(dc, lain, [])
    emit("lain_arranged", lain=lain, layout=layout(dc))
    X, xp, other, _ = new_virtual(dc, 1280, 720, 60)
    cleanup += [(X, xp)]
    pump(1.0)
    emit("after_add", added=other, layout=layout(dc), lain_session_closed=L.closed)
    xp.stop()
    X.stop()
    pump_until(lambda: other not in virtuals(dc), 5)
    pump(1.0)
    emit("after_remove", removed=other, layout=layout(dc), lain_session_closed=L.closed)


def close(dc, cleanup):
    X, xp, other, _ = new_virtual(dc, 1280, 720, 60)
    cleanup += [(X, xp)]
    L, lp, lain, mpath = new_virtual(dc, W, H, FPS, extra_monitor_of=other)
    cleanup += [(L, lp)]
    emit("both_up", lain=lain, other=other, monitor_stream_params=L.stream_params(mpath), layout=layout(dc))
    xp.stop()
    X.stop()
    gone = pump_until(lambda: other not in virtuals(dc), 5)
    pump_until(lambda: L.closed, 3)
    pump(0.5)
    emit("after_other_removed", other_gone=gone, lain_session_closed=L.closed,
         monitor_stream_params=L.stream_params(mpath),
         lain_monitor_still_listed=lain in virtuals(dc), layout=layout(dc))


def sizes(dc, cleanup):
    s = Session()
    path = s.record_monitor(PHYS)
    s.start()
    assert s.wait_nodes(5)
    cleanup += [(s, None)]
    node = s.node(path)
    info = pw_node_info(node) or {}
    emit("monitor_node_offers", EnumFormat=info.get("EnumFormat"))
    for (w, h, fps) in [(64, 36, 60), (1920, 1080, 60), (3840, 2160, 1), (3840, 2160, 60)]:
        p = Probe(node, w, h, fps, 10)
        ok = pump_until(lambda: p.first("format") is not None, 4)
        states = [e.get("state") for e in p.of("state")]
        emit("monitor_stream_size", asked=[w, h, fps], negotiated=ok, format=p.first("format"),
             states=states, errors=[e for e in p.events if e["ev"] == "error"][:2])
        p.stop()
        pump(0.3)


def main():
    phase = sys.argv[1] if len(sys.argv) > 1 else "hotplug"
    watcher = Session(remote_desktop=False)  # DisplayConfig only; records nothing
    dc = DisplayConfig(watcher.bus)
    before = dc.summary()
    emit("before", layout=before)
    cleanup = []
    try:
        {"hotplug": hotplug, "close": close, "sizes": sizes}[phase](dc, cleanup)
    finally:
        for (s, p) in reversed(cleanup):
            if p:
                p.stop()
            s.close()
        pump_until(lambda: not virtuals(dc), 5)
        pump(0.5)
        after = dc.summary()
        emit("after", layout=after, same_as_before=after == before)
        watcher.close()


if __name__ == "__main__":
    main()
