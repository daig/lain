#!/usr/bin/env python3
"""A GTK 4 window, fullscreen on one monitor, that reports the input it receives and animates every frame.

Usage: gtkprobe.py <connector> <seconds> [full]
With "full" (added by the conversion spike, spikes/linux-convert) the whole window changes every frame: a
background alternating between two shades, under 64 bars that move, drawn as GSK colour nodes (no cairo
upload), so Mutter composites and streams full-frame damage at the monitor's rate.
Prints JSON lines on stdout: ready (window size and the monitor's geometry and refresh as GTK sees them),
motion, scroll (with unit and source device), scroll-begin/end, decelerate (kinetic flings), key, and once a
second the frame clock's rate. Exits after <seconds>. Used by exp4 to observe what Mutter's injected events
look like to a client, and to give the virtual monitor changing content.
"""

import json
import sys
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Graphene", "1.0")
from gi.repository import Gdk, GLib, Graphene, Gtk  # noqa: E402

CONNECTOR, SECONDS = sys.argv[1], float(sys.argv[2])
FULL = len(sys.argv) > 3 and sys.argv[3] == "full"


class FullDamage(Gtk.Widget):
    """Changes every pixel's frame each tick: alternating background plus 64 moving bars."""

    def __init__(self):
        super().__init__(hexpand=True, vexpand=True)
        self.n = 0
        self.bg = [Gdk.RGBA(red=0.10, green=0.06, blue=0.16, alpha=1), Gdk.RGBA(red=0.11, green=0.06, blue=0.17, alpha=1)]
        self.fg = [Gdk.RGBA(red=r, green=g, blue=b, alpha=1) for r, g, b in
                   ((0.9, 0.9, 0.9), (0.47, 0.86, 0.47), (0.98, 0.78, 0.31), (0.43, 0.67, 0.98), (0.94, 0.43, 0.55))]

    def do_snapshot(self, snap):
        w, h = self.get_width(), self.get_height()
        self.n += 1
        snap.append_color(self.bg[self.n & 1], Graphene.Rect().init(0, 0, w, h))
        for i, y in enumerate(range(0, h, 32)):
            x = (self.n * 13 + i * 157) % max(w, 1)
            snap.append_color(self.fg[i % 5], Graphene.Rect().init(x, y + 9, 420, 14))


def out(ev, **kw):
    print(json.dumps({"ev": ev, "t": time.monotonic(), **kw}), flush=True)


def source_of(controller):
    ev = controller.get_current_event()
    if ev is None:
        return None
    dev = ev.get_device()
    return dev.get_source().value_nick if dev else None


class Probe(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=None)
        self.frames = 0
        self.connect("activate", self.on_activate)

    def on_activate(self, app):
        display = Gdk.Display.get_default()
        monitors = display.get_monitors()
        monitor = None
        for i in range(monitors.get_n_items()):
            m = monitors.get_item(i)
            if m.get_connector() == CONNECTOR:
                monitor = m
        if monitor is None:
            out("error", what=f"no monitor {CONNECTOR}")
            self.quit()
            return
        self.monitor = monitor
        win = Gtk.ApplicationWindow(application=app, title="lain spike B probe")
        # a small animated square in the middle: cheap to redraw, so the client keeps up with any refresh rate
        if FULL:
            area = FullDamage()
        else:
            area = Gtk.DrawingArea(width_request=240, height_request=240, halign=Gtk.Align.CENTER,
                                   valign=Gtk.Align.CENTER)
            area.set_draw_func(self.draw)
        win.set_child(area)
        self.area = area

        motion = Gtk.EventControllerMotion()
        motion.connect("motion", lambda c, x, y: out("motion", x=x, y=y))
        win.add_controller(motion)

        scroll = Gtk.EventControllerScroll(flags=Gtk.EventControllerScrollFlags.BOTH_AXES
                                           | Gtk.EventControllerScrollFlags.KINETIC)
        scroll.connect("scroll", lambda c, dx, dy: out("scroll", dx=dx, dy=dy, unit=c.get_unit().value_nick,
                                                       source=source_of(c)) or True)
        scroll.connect("scroll-begin", lambda c: out("scroll-begin", source=source_of(c)))
        scroll.connect("scroll-end", lambda c: out("scroll-end", source=source_of(c)))
        scroll.connect("decelerate", lambda c, vx, vy: out("decelerate", vx=vx, vy=vy))
        win.add_controller(scroll)

        key = Gtk.EventControllerKey()
        key.connect("key-pressed", lambda c, kv, code, st: out("key", down=True, keyval=Gdk.keyval_name(kv),
                                                                keycode=code) or False)
        key.connect("key-released", lambda c, kv, code, st: out("key", down=False, keyval=Gdk.keyval_name(kv),
                                                                 keycode=code))
        win.add_controller(key)

        win.fullscreen_on_monitor(monitor)
        win.present()
        self.win = win
        area.add_tick_callback(self.tick)
        GLib.timeout_add(1000, self.report)
        GLib.timeout_add(int(SECONDS * 1000), self.quit)
        GLib.timeout_add(700, self.ready)

    def ready(self):
        g = self.monitor.get_geometry()
        out("ready", width=self.win.get_width(), height=self.win.get_height(),
            monitor={"x": g.x, "y": g.y, "width": g.width, "height": g.height,
                     "scale": self.monitor.get_scale(), "scale_factor": self.monitor.get_scale_factor(),
                     "refresh_mhz": self.monitor.get_refresh_rate()},
            surface_scale=self.win.get_surface().get_scale() if self.win.get_surface() else None)
        return False

    def tick(self, widget, clock):
        self.frames += 1
        widget.queue_draw()
        return True

    def report(self):
        out("frames", per_second=self.frames)
        self.frames = 0
        return True

    def draw(self, area, cr, w, h):
        # a band that moves every frame, so every frame has damage
        x = (self.frames * 7) % max(w, 1)
        cr.set_source_rgb(0.1, 0.1, 0.12)
        cr.paint()
        cr.set_source_rgb(0.9, 0.5, 0.2)
        cr.rectangle(x, 0, 40, h)
        cr.fill()


if __name__ == "__main__":
    Probe().run([])
