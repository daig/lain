#!/usr/bin/env python3
"""Runs a command while Mutter composites a 120 Hz virtual monitor with animated content (conversion spike).

Creates lain's display as spike B does (RemoteDesktop + ScreenCast session, RecordVirtual with cursor-mode
metadata), lets a PipeWire consumer fix its format at 2752x2064 / max 120 fps, opens spike B's gtkprobe.py
fullscreen on it (under the NVIDIA guard, GSK_RENDERER=gl, Mesa EGL pinned), and then:
  load <gtk-mode> -- <command...>   the consumer is spike B's pwprobe (DMA-BUF, never mapped); <command> runs
                                    once the probe animates (for example run-one.sh with a converter).
  e2e <gtk-mode> -- <e2e args...>   the consumer is e2e itself, launched through run-one.sh with the node id
                                    as its first argument.
<gtk-mode> is "square" (spike B's 240x240 animated square) or "full" (whole-window damage every frame).
No ApplyMonitorsConfig, no input. At the end the probe is closed, the session stopped, and the layout compared
with the one before (and with the snapshot the brief gave).
"""

import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SPIKE_B = os.path.join(HERE, "..", "linux-display")
sys.path.insert(0, SPIKE_B)
from mutter import DisplayConfig, Probe, Session, emit, pump_until  # noqa: E402

W, H, FPS = 2752, 2064, 120
PHYS = "HDMI-1"
MOD = 0x0200000000401B03
GUARD = os.path.join(HERE, "..", "linux-encoder", "nvidia-guard.sh")
EXPECTED = {"monitors": [{"connector": "HDMI-1", "vendor": "SAM", "product": "Odyssey G95NC",
                          "current_mode": "3840x2160@60.000"}],
            "logical_monitors": [{"x": 0, "y": 0, "scale": 1, "transform": 0, "primary": True,
                                  "connectors": ["HDMI-1"]}], "layout_mode": 1}


def gtk_env():
    env = dict(os.environ)
    env.update(GSK_RENDERER="gl", __EGL_VENDOR_LIBRARY_FILENAMES="/usr/share/glvnd/egl_vendor.d/50_mesa.json",
               VK_DRIVER_FILES="/usr/share/vulkan/icd.d/radeon_icd.json", VK_LOADER_LAYERS_DISABLE="~implicit~")
    return env


def main():
    mode, gtk_mode = sys.argv[1], sys.argv[2]
    assert mode in ("load", "e2e") and gtk_mode in ("square", "full") and sys.argv[3] == "--"
    cmd = sys.argv[4:]
    os.environ.setdefault("PWPROBE", os.path.join(SPIKE_B, "build", "pwprobe"))
    w = Session(remote_desktop=False)
    dc = DisplayConfig(w.bus)
    before = dc.summary()
    emit("before", same_as_brief=before == EXPECTED, layout=before)
    s = Session()
    gtk = probe = consumer = None
    rc = 1
    try:
        vpath = s.record_virtual()
        s.start()
        assert s.wait_nodes(5), "no PipeWire node"
        node = s.node(vpath)
        if mode == "load":
            os.environ["PROBE_OPTS"] = f"dmabuf={MOD}"
            probe = Probe(node, W, H, FPS, 60)
            assert pump_until(lambda: probe.first("format") is not None, 5), "pwprobe negotiated no format"
        else:
            consumer = subprocess.Popen([os.path.join(HERE, "run-one.sh"), "e2e", os.path.join(HERE, "e2e", "e2e"),
                                         str(node)] + cmd)
        assert pump_until(lambda: any(m["connector"] != PHYS for m in dc.state()["monitors"]), 8), "no monitor"
        v = next(m for m in dc.state()["monitors"] if m["connector"] != PHYS)
        emit("virtual", connector=v["connector"], mode=v["current_mode"]["id"])
        seconds = 40 if mode == "load" else 14
        gtk = subprocess.Popen([GUARD, "python3", os.path.join(SPIKE_B, "gtkprobe.py"), v["connector"], str(seconds)]
                               + (["full"] if gtk_mode == "full" else []),
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=gtk_env(),
                               start_new_session=True)  # its own group: the guard's strace and python go together
        if mode == "load":
            time.sleep(3)  # the probe window is up and animating
            rc = subprocess.call(cmd)
        else:
            rc = consumer.wait(40)
    finally:
        out = ""
        if gtk:
            if gtk.poll() is None:
                os.killpg(gtk.pid, signal.SIGTERM)
            try:
                out = gtk.communicate(timeout=10)[0]
            except subprocess.TimeoutExpired:
                os.killpg(gtk.pid, signal.SIGKILL)
                out = gtk.communicate()[0]
        ticks = [json.loads(x)["per_second"] for x in out.splitlines() if x.strip().startswith("{")
                 and json.loads(x)["ev"] == "frames"]
        emit("gtkprobe", ticks_per_s=ticks, guard_rc=gtk.returncode if gtk else None)
        if probe:
            stats = probe.stop()
            emit("pwprobe", pictures_per_s=[e["window_pictures"] for e in stats if e["ev"] == "stats"],
                 modifier=hex(probe.first("format")["modifier"]) if probe.first("format") else None)
        if consumer and consumer.poll() is None:
            consumer.terminate()
            consumer.wait(10)
        s.stop()
        pump_until(lambda: len(dc.state()["monitors"]) == 1, 5)
        s.close()
        after = dc.summary()
        emit("after", same_as_before=after == before, same_as_brief=after == EXPECTED, layout=after)
        w.close()
    sys.exit(rc)


if __name__ == "__main__":
    main()
