#!/usr/bin/env python3
"""Experiment 2: arrangement and scale of the virtual monitor through ApplyMonitorsConfig, and whether they persist.

  exp2_arrange.py temp     create, apply scale 2 at a non-default place with method 1 (temporary), check the
                           stream's format, destroy, recreate: what comes back?
  exp2_arrange.py persist  the same with method 2 (persistent), then look at ~/.config/monitors.xml. Mutter
                           writes it a few seconds later, so the run waits up to 15 s for it, reports its
                           content and, if the file did not exist before the run, deletes it again.
  exp2_arrange.py restart  create only and report where Mutter puts the monitor (run after `persist` to see
                           whether the stored config is used for a fresh session).

The physical monitor keeps its mode, scale 1 and primary in every config applied here; only its logical
position may move (when the virtual monitor goes to its left or above it). Each run ends with the layout
compared to the one it found.
"""

import os
import sys
import time

from mutter import DisplayConfig, Probe, Session, emit, log, pump, pump_until

W, H, FPS = 2752, 2064, 120
PHYS = "HDMI-1"
MONITORS_XML = os.path.expanduser("~/.config/monitors.xml")


def find(state, connector):
    for lm in state["logical_monitors"]:
        if connector in lm["connectors"]:
            return lm
    return None


def virtual_connector(state):
    return next((m["connector"] for m in state["monitors"] if m["connector"] != PHYS), None)


def mode_of(state, connector):
    return next(m["current_mode"]["id"] for m in state["monitors"] if m["connector"] == connector)


def create(dc):
    s = Session()
    path = s.record_virtual()
    s.start()
    assert s.wait_nodes(5), "no node"
    probe = Probe(s.node(path), W, H, FPS, 60)
    assert pump_until(lambda: probe.first("format") is not None, 5), "no format"
    assert pump_until(lambda: virtual_connector(DisplayConfig(s.bus).state()) is not None, 5), "no monitor"
    return s, path, probe


def destroy(s, probe, dc):
    probe.stop()
    s.stop()
    pump_until(lambda: virtual_connector(dc.state()) is None, 5)
    s.close()


def apply_and_report(dc, method, placement, label):
    """placement: [(connector, x, y, scale, primary)]"""
    state = dc.state()
    lms = [(x, y, scale, 0, primary, [(c, mode_of(state, c))]) for (c, x, y, scale, primary) in placement]
    t = time.monotonic()
    try:
        dc.apply(method, lms)
        apply_ms = round((time.monotonic() - t) * 1000, 1)
    except Exception as e:
        emit("apply_failed", label=label, method=method, placement=placement, error=str(e))
        return None
    pump(0.5)
    after = dc.state()
    emit("applied", label=label, method=method, apply_call_ms=apply_ms,
         logical=after["logical_monitors"])
    return after


def main():
    phase = sys.argv[1] if len(sys.argv) > 1 else "temp"
    watcher = Session(remote_desktop=False)  # a connection for DisplayConfig only; it records nothing
    dc = DisplayConfig(watcher.bus)
    before = dc.summary()
    xml_before = os.path.exists(MONITORS_XML)
    emit("before", layout=before, monitors_xml_exists=xml_before)
    method = {"temp": 1, "persist": 2}.get(phase)
    try:
        s, path, probe = create(dc)
        st = dc.state()
        v = virtual_connector(st)
        emit("created", connector=v, logical=st["logical_monitors"],
             serial=[m["serial"] for m in st["monitors"] if m["connector"] != PHYS])
        if method is None:
            pump(1)
            destroy(s, probe, dc)
            return

        # Validation first (method 0): a few placements, to learn the rules.
        for label, placement in [
            ("left", [(v, 0, 0, 2.0, False), (PHYS, 1376, 0, 1.0, True)]),
            ("right_offset_y", [(PHYS, 0, 0, 1.0, True), (v, 3840, 500, 2.0, False)]),
            ("below_centered", [(PHYS, 0, 0, 1.0, True), (v, 1232, 2160, 2.0, False)]),
            ("gap", [(PHYS, 0, 0, 1.0, True), (v, 4000, 0, 2.0, False)]),
            ("overlap", [(PHYS, 0, 0, 1.0, True), (v, 3000, 0, 2.0, False)]),
            ("negative_origin", [(PHYS, 0, 0, 1.0, True), (v, -1376, 0, 2.0, False)]),
            ("fractional_1.5", [(PHYS, 0, 0, 1.0, True), (v, 3840, 0, 1.5, False)]),
        ]:
            st = dc.state()
            lms = [(x, y, sc, 0, pr, [(c, mode_of(st, c))]) for (c, x, y, sc, pr) in placement]
            try:
                dc.apply(0, lms)
                emit("verify", label=label, ok=True)
            except Exception as e:
                emit("verify", label=label, ok=False, error=str(e).split(":", 1)[-1].strip())

        target = [(PHYS, 0, 0, 1.0, True), (v, 1232, 2160, 2.0, False)]
        apply_and_report(dc, method, target, "below_centered")
        n_formats = len(probe.of("format"))
        pump(1)
        emit("stream_after_scale", formats=probe.of("format"), new_formats=len(probe.of("format")) - n_formats + 1)

        # Another session's view: does a fresh connection see the same layout? (it should; one compositor)
        # Now destroy and recreate in this Mutter run.
        destroy(s, probe, dc)
        emit("after_destroy", layout=dc.summary())
        if phase == "persist":
            emit("monitors_xml", exists=os.path.exists(MONITORS_XML),
                 content=open(MONITORS_XML).read() if os.path.exists(MONITORS_XML) else None)
        s, path, probe = create(dc)
        st = dc.state()
        emit("recreated", connector=virtual_connector(st), logical=st["logical_monitors"],
             serial=[m["serial"] for m in st["monitors"] if m["connector"] != PHYS],
             mode=mode_of(st, virtual_connector(st)))
        destroy(s, probe, dc)
    finally:
        pump(0.5)
        if phase == "persist":
            appeared = pump_until(lambda: os.path.exists(MONITORS_XML), 0 if xml_before else 15)
            if appeared and not xml_before:
                content = open(MONITORS_XML).read()
                os.remove(MONITORS_XML)
                emit("monitors_xml_written_later", content=content, removed=True)
        after = dc.summary()
        emit("after", layout=after, same_as_before=after == before,
             monitors_xml_exists=os.path.exists(MONITORS_XML))
        watcher.close()


if __name__ == "__main__":
    main()
