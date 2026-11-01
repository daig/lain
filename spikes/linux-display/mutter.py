"""Shared helpers for spike B: Mutter's ScreenCast, RemoteDesktop, DisplayConfig and IdleMonitor over D-Bus.

Each experiment owns one D-Bus connection (a private one, not the shared session bus object), because Mutter
ends a remote-desktop or screen-cast session when the connection that created it closes. Closing that
connection is the safety net: whatever an experiment leaves behind goes with it.
"""

import json
import os
import subprocess
import sys
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

DBusGMainLoop(set_as_default=True)

SC = "org.gnome.Mutter.ScreenCast"
RD = "org.gnome.Mutter.RemoteDesktop"
DC = "org.gnome.Mutter.DisplayConfig"
IM = "org.gnome.Mutter.IdleMonitor"

HERE = os.path.dirname(os.path.abspath(__file__))
PWPROBE = os.environ.get("PWPROBE", os.path.join(HERE, "build", "pwprobe"))

# ScreenCast cursor modes (org.gnome.Mutter.ScreenCast.xml)
CURSOR_HIDDEN, CURSOR_EMBEDDED, CURSOR_METADATA = 0, 1, 2

# NotifyPointerAxis flags (org.gnome.Mutter.RemoteDesktop.xml)
AXIS_FINISH, AXIS_WHEEL, AXIS_FINGER, AXIS_CONTINUOUS = 1, 2, 4, 8

BTN_LEFT = 0x110
KEY_LEFTSHIFT = 42


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def emit(kind, **fields):
    """One result line on stdout, as JSON."""
    print(json.dumps({"result": kind, **fields}, default=str), flush=True)


def private_bus():
    bus = dbus.SessionBus(private=True)
    # libdbus exits the process when a private connection is disconnected, closing it included
    bus.set_exit_on_disconnect(False)
    return bus


def pump(seconds):
    """Runs the GLib main loop for `seconds` (signals arrive only while it runs)."""
    loop = GLib.MainLoop()
    GLib.timeout_add(int(seconds * 1000), loop.quit)
    loop.run()


def pump_until(cond, timeout, step=0.02):
    deadline = time.monotonic() + timeout
    ctx = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while ctx.pending():
            ctx.iteration(False)
        if cond():
            return True
        time.sleep(step)
    while ctx.pending():
        ctx.iteration(False)
    return cond()


def py(v):
    """dbus types → plain Python."""
    if isinstance(v, (dbus.Array, list)):
        return [py(x) for x in v]
    if isinstance(v, (dbus.Struct, tuple)):
        return [py(x) for x in v]
    if isinstance(v, (dbus.Dictionary, dict)):
        return {str(k): py(x) for k, x in v.items()}
    if isinstance(v, dbus.Boolean):
        return bool(v)
    if isinstance(v, (dbus.Double, float)):
        return float(v)
    if isinstance(v, (dbus.String, dbus.ObjectPath, str)):
        return str(v)
    if isinstance(v, (int,)):
        return int(v)
    return v


# ---------------------------------------------------------------- DisplayConfig


class DisplayConfig:
    def __init__(self, bus):
        self.obj = bus.get_object(DC, "/org/gnome/Mutter/DisplayConfig")
        self.iface = dbus.Interface(self.obj, DC)

    def raw_state(self):
        return self.iface.GetCurrentState()

    def state(self):
        """GetCurrentState, summarised like the wave brief's snapshot, with a bit more detail."""
        serial, monitors, logical, props = self.raw_state()
        mons = []
        for (spec, modes, mprops) in monitors:
            connector, vendor, product, serialno = [str(x) for x in spec]
            cur = None
            for m in modes:
                mp = m[6]
                if mp.get("is-current", False):
                    cur = {
                        "id": str(m[0]),
                        "size": [int(m[1]), int(m[2])],
                        "refresh": float(m[3]),
                        "preferred_scale": float(m[4]),
                        "supported_scales": [float(s) for s in m[5]],
                    }
            mons.append({
                "connector": connector,
                "vendor": vendor,
                "product": product,
                "serial": serialno,
                "current_mode": cur,
                "mode_count": len(modes),
                "props": {k: py(v) for k, v in mprops.items() if k in (
                    "is-builtin", "display-name", "is-for-lease", "is-underscanning", "min-refresh-rate",
                    "is-virtual", "color-mode", "supported-color-modes")},
            })
        lms = []
        for (x, y, scale, transform, primary, conns, lprops) in logical:
            lms.append({
                "x": int(x), "y": int(y), "scale": float(scale), "transform": int(transform),
                "primary": bool(primary), "connectors": [str(c[0]) for c in conns],
            })
        return {
            "serial": int(serial),
            "monitors": mons,
            "logical_monitors": lms,
            "props": {k: py(v) for k, v in props.items()},
        }

    def summary(self):
        """The same shape as the wave brief's snapshot, for the before/after comparison."""
        s = self.state()
        return {
            "monitors": [{
                "connector": m["connector"], "vendor": m["vendor"], "product": m["product"],
                "current_mode": m["current_mode"]["id"] if m["current_mode"] else None,
            } for m in s["monitors"]],
            "logical_monitors": [{k: lm[k] for k in ("x", "y", "scale", "transform", "primary", "connectors")}
                                 for lm in s["logical_monitors"]],
            "layout_mode": s["props"].get("layout-mode"),
        }

    def apply(self, method, logical_monitors, props=None):
        """ApplyMonitorsConfig. logical_monitors: [(x, y, scale, transform, primary, [(connector, mode_id)])]."""
        serial = self.raw_state()[0]
        lm = dbus.Array([
            dbus.Struct((dbus.Int32(x), dbus.Int32(y), dbus.Double(scale), dbus.UInt32(transform),
                         dbus.Boolean(primary),
                         dbus.Array([dbus.Struct((dbus.String(c), dbus.String(mode), dbus.Dictionary({}, "sv")))
                                     for c, mode in conns], signature="(ssa{sv})")))
            for (x, y, scale, transform, primary, conns) in logical_monitors
        ], signature="(iiduba(ssa{sv}))")
        self.iface.ApplyMonitorsConfig(dbus.UInt32(serial), dbus.UInt32(method), lm,
                                       dbus.Dictionary(props or {}, signature="sv"))


# ---------------------------------------------------------------- IdleMonitor


class Idle:
    def __init__(self, bus):
        self.iface = dbus.Interface(bus.get_object(IM, "/org/gnome/Mutter/IdleMonitor/Core"), IM)

    def ms(self):
        return int(self.iface.GetIdletime())


# ---------------------------------------------------------------- sessions


class Session:
    """A RemoteDesktop session with a linked ScreenCast session, on its own connection."""

    def __init__(self, bus=None, remote_desktop=True):
        self.bus = bus or private_bus()
        self.closed = False
        self.streams = {}  # stream path → {"node": id or None, "params": {...}}
        if remote_desktop:
            rd = dbus.Interface(self.bus.get_object(RD, "/org/gnome/Mutter/RemoteDesktop"), RD)
            self.rd_path = rd.CreateSession()
            self.rd_obj = self.bus.get_object(RD, self.rd_path)
            self.rd = dbus.Interface(self.rd_obj, RD + ".Session")
            self.rd.connect_to_signal("Closed", self._on_closed)
            self.session_id = str(self.rd_obj.Get(RD + ".Session", "SessionId",
                                                  dbus_interface="org.freedesktop.DBus.Properties"))
            sc_props = {"remote-desktop-session-id": self.session_id}
        else:
            self.rd = None
            sc_props = {}
        sc = dbus.Interface(self.bus.get_object(SC, "/org/gnome/Mutter/ScreenCast"), SC)
        self.sc_path = sc.CreateSession(dbus.Dictionary(sc_props, signature="sv"))
        self.sc = dbus.Interface(self.bus.get_object(SC, self.sc_path), SC + ".Session")
        if not remote_desktop:
            self.sc.connect_to_signal("Closed", self._on_closed)

    def _on_closed(self, *args):
        log("session closed by Mutter")
        self.closed = True

    def _watch(self, path):
        self.streams[str(path)] = {"node": None}
        obj = self.bus.get_object(SC, path)
        iface = dbus.Interface(obj, SC + ".Stream")

        def added(node, path=str(path)):
            self.streams[path]["node"] = int(node)

        iface.connect_to_signal("PipeWireStreamAdded", added)
        self.streams[str(path)]["obj"] = obj
        return str(path)

    def record_virtual(self, cursor_mode=CURSOR_METADATA, is_platform=None, extra=None):
        props = {"cursor-mode": dbus.UInt32(cursor_mode)}
        if is_platform is not None:
            props["is-platform"] = dbus.Boolean(is_platform)
        props.update(extra or {})
        return self._watch(self.sc.RecordVirtual(dbus.Dictionary(props, signature="sv")))

    def record_monitor(self, connector, cursor_mode=CURSOR_METADATA):
        props = {"cursor-mode": dbus.UInt32(cursor_mode)}
        return self._watch(self.sc.RecordMonitor(connector, dbus.Dictionary(props, signature="sv")))

    def stream_params(self, path):
        obj = self.streams[path]["obj"]
        try:
            return py(obj.Get(SC + ".Stream", "Parameters", dbus_interface="org.freedesktop.DBus.Properties"))
        except dbus.DBusException as e:
            return {"error": str(e)}

    def start(self):
        if self.rd is not None:
            self.rd.Start()
        else:
            self.sc.Start()

    def wait_nodes(self, timeout=5):
        return pump_until(lambda: all(s["node"] is not None for s in self.streams.values()), timeout)

    def node(self, path):
        return self.streams[path]["node"]

    def stop(self):
        if self.closed:
            return
        try:
            if self.rd is not None:
                self.rd.Stop()
            else:
                self.sc.Stop()
        except dbus.DBusException as e:
            log("stop:", e)
        self.closed = True

    def close(self):
        self.stop()
        try:
            self.bus.close()
        except Exception:
            pass

    # -- input (stream-local absolute motion; everything else is global)

    def move_abs(self, stream_path, x, y):
        self.rd.NotifyPointerMotionAbsolute(stream_path, dbus.Double(x), dbus.Double(y))

    def axis(self, dx, dy, flags):
        self.rd.NotifyPointerAxis(dbus.Double(dx), dbus.Double(dy), dbus.UInt32(flags))

    def axis_discrete(self, axis, steps):
        self.rd.NotifyPointerAxisDiscrete(dbus.UInt32(axis), dbus.Int32(steps))

    def key(self, evdev_code, down):
        self.rd.NotifyKeyboardKeycode(dbus.UInt32(evdev_code), dbus.Boolean(down))


# ---------------------------------------------------------------- the PipeWire probe


class Probe:
    """Runs pwprobe against a node in the background and collects its JSON lines."""

    def __init__(self, node, width, height, fps, seconds, bitmaps=False):
        args = [PWPROBE, str(node), str(width), str(height), str(fps), str(seconds)]
        if bitmaps:
            args.append("bitmaps")
        # e.g. PROBE_OPTS=dmabuf=144115188080057091 to receive DMA-BUFs with that modifier instead of shm
        args += os.environ.get("PROBE_OPTS", "").split()
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.events = []
        os.set_blocking(self.proc.stdout.fileno(), False)
        self._buf = ""

    def poll(self):
        try:
            chunk = self.proc.stdout.read()
        except (BlockingIOError, TypeError):
            chunk = None
        if chunk:
            self._buf += chunk
            *lines, self._buf = self._buf.split("\n")
            for line in lines:
                if line.strip():
                    try:
                        self.events.append(json.loads(line))
                    except json.JSONDecodeError:
                        log("probe:", line)
        return self.events

    def first(self, ev):
        self.poll()
        return next((e for e in self.events if e["ev"] == ev), None)

    def of(self, ev):
        self.poll()
        return [e for e in self.events if e["ev"] == ev]

    def wait(self, timeout=None):
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            self.proc.wait()
        self.poll()
        if self._buf.strip():
            try:
                self.events.append(json.loads(self._buf))
            except json.JSONDecodeError:
                pass
        return self.events

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
        return self.wait(5)


class NotOnVirtualMonitor(RuntimeError):
    pass


def pointer_on(probe, width, height):
    """The probe's latest cursor metadata if it is valid and inside the stream (device pixels), else None."""
    cur = probe.of("cursor") if probe else []
    c = cur[-1] if cur else None
    if c and c.get("valid") and 0 <= c["x"] < width and 0 <= c["y"] < height:
        return c
    return None


def require_pointer_on(probe, width, height, what):
    """The input-safety guard: call it right before injecting scrolling or a key, so neither can reach a window
    on the user's monitor. Raises (the experiment's `finally` then restores the pointer and the layout) unless
    the virtual stream's cursor metadata puts the pointer inside the virtual monitor."""
    c = pointer_on(probe, width, height)
    if c is None:
        cur = probe.of("cursor") if probe else []
        raise NotOnVirtualMonitor(f"not sending {what}: pointer not on the virtual monitor "
                                  f"(last cursor metadata: {cur[-1] if cur else None})")
    return c


def pw_node_info(node):
    """The node's properties and its EnumFormat params as pw-dump reports them."""
    out = subprocess.run(["pw-dump", str(node)], capture_output=True, text=True, timeout=10).stdout
    try:
        objs = json.loads(out)
    except json.JSONDecodeError:
        return None
    for o in objs:
        if o.get("id") == node:
            info = o.get("info", {})
            return {"props": info.get("props", {}), "EnumFormat": info.get("params", {}).get("EnumFormat"),
                    "Format": info.get("params", {}).get("Format")}
    return None
