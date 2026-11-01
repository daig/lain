#!/usr/bin/env python3
"""Experiment 5: how often the virtual monitor actually repaints, against the max framerate asked for.

For each requested max framerate, creates the virtual monitor (2752x2064, optionally at scale 2), opens
gtkprobe.py fullscreen on it (it redraws on every frame-clock tick), and counts GTK's frame-clock ticks and the
picture buffers pwprobe receives per second. No input is injected; the probe window takes keyboard focus
for a few seconds each time.

Usage: exp5_rate.py [scale] [fps ...]   (default: scale 2; 120 60 144 240)
"""

import json
import os
import subprocess
import sys

from mutter import HERE, DisplayConfig, Probe, Session, emit, pump, pump_until

W, H = 2752, 2064
PHYS = "HDMI-1"


def run(fps, scale, dc_before):
    s = Session()
    dc = DisplayConfig(s.bus)
    gtk = probe = None
    try:
        vpath = s.record_virtual()
        s.start()
        assert s.wait_nodes(5)
        probe = Probe(s.node(vpath), W, H, fps, 30)
        assert pump_until(lambda: probe.first("format") is not None, 5)
        assert pump_until(lambda: any(m["connector"] != PHYS for m in dc.state()["monitors"]), 5)
        st = dc.state()
        v = next(m for m in st["monitors"] if m["connector"] != PHYS)
        if scale != 1:
            pmode = next(m for m in st["monitors"] if m["connector"] == PHYS)["current_mode"]["id"]
            dc.apply(1, [(0, 0, 1.0, 0, True, [(PHYS, pmode)]),
                         (3840, 0, float(scale), 0, False, [(v["connector"], v["current_mode"]["id"])])])
            pump(0.5)
        gtk = subprocess.Popen(["python3", os.path.join(HERE, "gtkprobe.py"), v["connector"], "5"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        out, _ = gtk.communicate(timeout=15)
        evs = [json.loads(x) for x in out.splitlines() if x.strip()]
        ready = next((e for e in evs if e["ev"] == "ready"), None)
        stats = probe.of("stats")
        frames = probe.of("frame")
        gaps = sorted((b["t"] - a["t"]) * 1000 for a, b in zip(frames, frames[1:])
                      if ready and a["t"] > ready["t"] and b["t"] < ready["t"] + 3.5)
        emit("rate", requested_fps=fps, scale=scale, mode=v["current_mode"]["id"],
             negotiated=probe.first("format")["max_framerate"],
             # the modifier of the last format event (a scale change renegotiates); 0 is LINEAR, or shm
             modifier=hex(probe.of("format")[-1]["modifier"]),
             gtk_refresh_mhz=ready and ready["monitor"]["refresh_mhz"],
             gtk_ticks_per_s=[e["per_second"] for e in evs if e["ev"] == "frames"][1:],
             pictures_per_s=[e["window_pictures"] for e in stats[-4:]],
             buffers_per_s=[e["window_buffers"] for e in stats[-4:]],
             buffer_type=probe.first("buffer_type"),
             gap_ms=gaps and {"n": len(gaps), "p50": round(gaps[len(gaps) // 2], 2),
                              "p95": round(gaps[int(len(gaps) * 0.95)], 2),
                              "p99": round(gaps[int(len(gaps) * 0.99)], 2), "max": round(gaps[-1], 2)})
    finally:
        if gtk and gtk.poll() is None:
            gtk.terminate()
        if probe:
            probe.stop()
        s.stop()
        pump_until(lambda: len(dc.state()["monitors"]) == 1, 5)
        s.close()


def main():
    scale = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    rates = [int(a) for a in sys.argv[2:]] or [120, 60, 144, 240]
    w = Session(remote_desktop=False)
    dc = DisplayConfig(w.bus)
    before = dc.summary()
    for fps in rates:
        run(fps, scale, before)
    after = dc.summary()
    emit("after", same_as_before=after == before, layout=after)
    w.close()


if __name__ == "__main__":
    main()
