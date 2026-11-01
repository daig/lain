#!/usr/bin/env python3
"""Experiment 8: can a short-lived consumer bring the virtual monitor up and hand the node to a later one?

The monitor exists only once a consumer has fixed the stream's format. lain-gnome's create() must return
with the display listed, before lain-linux-video starts capturing. So:
  1. consumer A negotiates 2752x2064@120 and disconnects; is the monitor still there, with the same serial?
  2. consumer B connects to the same node with the same size: does it stream, does the monitor stay?
  3. B disconnects, and consumer C asks for 2064x2752@120 (a different size): what happens to the monitor?
  4. two consumers at once (B and D): does the second get frames?
No input is injected.
"""

from mutter import DisplayConfig, Probe, Session, emit, pump, pump_until

PHYS = "HDMI-1"


def virtual(dc):
    return [{"connector": m["connector"], "serial": m["serial"], "mode": m["current_mode"]["id"]}
            for m in dc.state()["monitors"] if m["connector"] != PHYS]


def consume(node, w, h, fps, seconds, label):
    p = Probe(node, w, h, fps, seconds)
    ok = pump_until(lambda: p.first("format") is not None, 4)
    return p, ok


def main():
    s = Session()
    dc = DisplayConfig(s.bus)
    before = dc.summary()
    try:
        path = s.record_virtual()
        s.start()
        assert s.wait_nodes(5)
        node = s.node(path)

        a, ok = consume(node, 2752, 2064, 120, 30, "A")
        pump_until(lambda: virtual(dc), 3)
        emit("A_negotiated", ok=ok, format=a.first("format"), monitor=virtual(dc))
        a.stop()
        pump(1.0)
        emit("A_gone", monitor=virtual(dc), session_closed=s.closed)

        b, ok = consume(node, 2752, 2064, 120, 30, "B")
        pump(1.5)
        emit("B_connected", ok=ok, format=b.first("format"), states=[e["state"] for e in b.of("state")],
             pictures=len(b.of("frame")), monitor=virtual(dc))

        d, ok = consume(node, 2752, 2064, 120, 30, "D")
        pump(1.5)
        emit("D_second_consumer", ok=ok, format=d.first("format"), states=[e["state"] for e in d.of("state")],
             pictures=len(d.of("frame")), monitor=virtual(dc))
        d.stop()
        b.stop()
        pump(1.0)

        c, ok = consume(node, 2064, 2752, 120, 30, "C")
        pump(1.5)
        emit("C_other_size", ok=ok, format=c.first("format"), states=[e["state"] for e in c.of("state")],
             monitor=virtual(dc))
        c.stop()
        pump(0.5)
    finally:
        s.stop()
        pump_until(lambda: not virtual(dc), 5)
        after = dc.summary()
        emit("after", layout=after, same_as_before=after == before)
        s.close()


if __name__ == "__main__":
    main()
