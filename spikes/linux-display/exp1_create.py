#!/usr/bin/env python3
"""Experiment 1: create a virtual monitor with RecordVirtual and negotiate its mode over PipeWire.

Steps: RemoteDesktop session + linked ScreenCast session, RecordVirtual(cursor-mode=metadata), Start. Read the
node's EnumFormat before any consumer connects, then connect pwprobe asking for WxH at FPS and watch the
monitor appear in DisplayConfig. Then stop the session and time the monitor's removal.

Usage: exp1_create.py [W H FPS [is-platform]]   (default 2752 2064 120; is-platform: true or false, unset by
default)
Prints JSON result lines; nothing is left behind (the session's connection closes at the end).
"""

import sys
import time

import dbus

from mutter import (DisplayConfig, Probe, Session, emit, log, pump, pump_until, pw_node_info, py, SC, RD)

W, H, FPS = (int(a) for a in sys.argv[1:4]) if len(sys.argv) >= 4 else (2752, 2064, 120)
IS_PLATFORM = {"true": True, "false": False}.get(sys.argv[4]) if len(sys.argv) >= 5 else None


def virtual_monitors(dc):
    s = dc.state()
    known = {"HDMI-1"}
    return s, [m for m in s["monitors"] if m["connector"] not in known]


def main():
    s = Session()
    dc = DisplayConfig(s.bus)
    before = dc.summary()
    emit("before", layout=before)
    try:
        t0 = time.monotonic()
        path = s.record_virtual(is_platform=IS_PLATFORM)
        emit("introspect_rd_session", xml=str(s.rd_obj.Introspect(dbus_interface="org.freedesktop.DBus.Introspectable")))
        emit("introspect_sc_stream", xml=str(s.streams[path]["obj"].Introspect(
            dbus_interface="org.freedesktop.DBus.Introspectable")))
        s.start()
        if not s.wait_nodes(5):
            emit("error", what="no PipeWireStreamAdded")
            return
        node = s.node(path)
        t_node = time.monotonic()
        emit("node", node=node, ms_from_record=round((t_node - t0) * 1000, 1), params=s.stream_params(path))
        _, vm = virtual_monitors(dc)
        emit("monitors_before_consumer", virtual=vm)
        emit("pw_node_before_consumer", info=pw_node_info(node))

        probe = Probe(node, W, H, FPS, 8)
        ok = pump_until(lambda: probe.first("format") is not None, 5)
        emit("negotiated", ok=ok, format=probe.first("format"), states=probe.of("state"))
        t_fmt = time.monotonic()
        appeared = pump_until(lambda: len(virtual_monitors(dc)[1]) > 0, 5)
        t_mon = time.monotonic()
        state, vm = virtual_monitors(dc)
        emit("monitor_appeared", ok=appeared, ms_after_format=round((t_mon - t_fmt) * 1000, 1), virtual=vm,
             logical=state["logical_monitors"], props=state["props"])
        emit("stream_params_after", params=s.stream_params(path))
        emit("pw_node_after_consumer", info=pw_node_info(node))
        pump(2)
        emit("probe_events", stats=probe.of("stats")[-2:], cursor=probe.of("cursor")[:3],
             frames=len(probe.of("frame")))
        probe.stop()
        pump(0.5)
        state, vm = virtual_monitors(dc)
        emit("after_consumer_left", virtual=vm, session_closed=s.closed)
    finally:
        t_stop = time.monotonic()
        s.stop()
        gone = pump_until(lambda: len(virtual_monitors(DisplayConfig(s.bus))[1]) == 0, 5)
        emit("removed", ok=gone, ms=round((time.monotonic() - t_stop) * 1000, 1))
        after = DisplayConfig(s.bus).summary()
        emit("after", layout=after, same_as_before=after == before)
        s.close()


if __name__ == "__main__":
    main()
