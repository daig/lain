"""A minimal ctypes binding of libei (the sender side), enough for spike B.

Only the runtime library (libei.so.1) is installed here, not its headers, so the enum values below are copied
from libei 1.x's ei.h; event types are printed through ei_event_type_to_string, so they don't depend on it.
"""

import ctypes
import select

lib = ctypes.CDLL("libei.so.1")

P = ctypes.c_void_p
for name, res, args in [
    ("ei_new_sender", P, [P]),
    ("ei_configure_name", None, [P, ctypes.c_char_p]),
    ("ei_setup_backend_fd", ctypes.c_int, [P, ctypes.c_int]),
    ("ei_get_fd", ctypes.c_int, [P]),
    ("ei_dispatch", None, [P]),
    ("ei_get_event", P, [P]),
    ("ei_unref", P, [P]),
    ("ei_now", ctypes.c_uint64, [P]),
    ("ei_event_get_type", ctypes.c_int, [P]),
    ("ei_event_type_to_string", ctypes.c_char_p, [ctypes.c_int]),
    ("ei_event_get_seat", P, [P]),
    ("ei_event_get_device", P, [P]),
    ("ei_event_unref", P, [P]),
    ("ei_seat_get_name", ctypes.c_char_p, [P]),
    ("ei_seat_has_capability", ctypes.c_bool, [P, ctypes.c_int]),
    ("ei_seat_ref", P, [P]),
    ("ei_device_ref", P, [P]),
    ("ei_device_get_name", ctypes.c_char_p, [P]),
    ("ei_device_get_type", ctypes.c_int, [P]),
    ("ei_device_has_capability", ctypes.c_bool, [P, ctypes.c_int]),
    ("ei_device_get_region", P, [P, ctypes.c_size_t]),
    ("ei_device_get_width", ctypes.c_uint32, [P]),
    ("ei_device_get_height", ctypes.c_uint32, [P]),
    ("ei_device_start_emulating", None, [P, ctypes.c_uint32]),
    ("ei_device_stop_emulating", None, [P]),
    ("ei_device_frame", None, [P, ctypes.c_uint64]),
    ("ei_device_pointer_motion", None, [P, ctypes.c_double, ctypes.c_double]),
    ("ei_device_pointer_motion_absolute", None, [P, ctypes.c_double, ctypes.c_double]),
    ("ei_device_scroll_delta", None, [P, ctypes.c_double, ctypes.c_double]),
    ("ei_device_scroll_stop", None, [P, ctypes.c_bool, ctypes.c_bool]),
    ("ei_device_keyboard_get_keymap", P, [P]),
    ("ei_region_get_x", ctypes.c_uint32, [P]),
    ("ei_region_get_y", ctypes.c_uint32, [P]),
    ("ei_region_get_width", ctypes.c_uint32, [P]),
    ("ei_region_get_height", ctypes.c_uint32, [P]),
    ("ei_region_get_mapping_id", ctypes.c_char_p, [P]),
    ("ei_region_get_physical_scale", ctypes.c_double, [P]),
    ("ei_keymap_get_type", ctypes.c_int, [P]),
]:
    f = getattr(lib, name)
    f.restype = res
    f.argtypes = args

# ei_seat_bind_capabilities is variadic (terminated by NULL)
lib.ei_seat_bind_capabilities.restype = None

CAP_POINTER, CAP_POINTER_ABSOLUTE, CAP_KEYBOARD, CAP_TOUCH, CAP_SCROLL, CAP_BUTTON = 1, 2, 4, 8, 16, 32
CAPS = {"pointer": CAP_POINTER, "pointer_absolute": CAP_POINTER_ABSOLUTE, "keyboard": CAP_KEYBOARD,
        "touch": CAP_TOUCH, "scroll": CAP_SCROLL, "button": CAP_BUTTON}


def s(b):
    return b.decode() if b else None


class Ei:
    def __init__(self, fd, name=b"lain-spike-b"):
        self.ei = lib.ei_new_sender(None)
        lib.ei_configure_name(self.ei, name)
        rc = lib.ei_setup_backend_fd(self.ei, fd)
        if rc != 0:
            raise OSError(-rc, "ei_setup_backend_fd")
        self.seats = []
        self.devices = {}  # pointer → info dict
        self.log = []
        self.sequence = 1

    def dispatch(self, timeout=0.1, bind=None):
        fd = lib.ei_get_fd(self.ei)
        r, _, _ = select.select([fd], [], [], timeout)
        lib.ei_dispatch(self.ei)
        while True:
            ev = lib.ei_get_event(self.ei)
            if not ev:
                break
            t = lib.ei_event_get_type(ev)
            name = s(lib.ei_event_type_to_string(t))
            entry = {"event": name}
            if name == "EI_EVENT_SEAT_ADDED":
                seat = lib.ei_seat_ref(lib.ei_event_get_seat(ev))
                caps = [k for k, v in CAPS.items() if lib.ei_seat_has_capability(seat, v)]
                entry.update(seat=s(lib.ei_seat_get_name(seat)), caps=caps)
                self.seats.append(seat)
                if bind is not None:
                    args = [ctypes.c_int(CAPS[c]) for c in bind if c in caps] + [None]
                    lib.ei_seat_bind_capabilities(seat, *args)
                    entry["bound"] = [c for c in bind if c in caps]
            elif name in ("EI_EVENT_DEVICE_ADDED", "EI_EVENT_DEVICE_RESUMED", "EI_EVENT_DEVICE_PAUSED",
                          "EI_EVENT_DEVICE_REMOVED"):
                dev = lib.ei_event_get_device(ev)
                if name == "EI_EVENT_DEVICE_ADDED":
                    dev = lib.ei_device_ref(dev)
                    self.devices[dev] = self.describe(dev)
                    entry["device"] = self.devices[dev]
                else:
                    info = self.devices.get(dev, {})
                    entry["device"] = info.get("name")
                    if name == "EI_EVENT_DEVICE_RESUMED" and dev in self.devices:
                        self.devices[dev]["resumed"] = True
                    if name in ("EI_EVENT_DEVICE_PAUSED", "EI_EVENT_DEVICE_REMOVED") and dev in self.devices:
                        self.devices[dev]["resumed"] = False
            self.log.append(entry)
            lib.ei_event_unref(ev)

    def describe(self, dev):
        regions = []
        i = 0
        while True:
            r = lib.ei_device_get_region(dev, i)
            if not r:
                break
            regions.append({"x": lib.ei_region_get_x(r), "y": lib.ei_region_get_y(r),
                            "width": lib.ei_region_get_width(r), "height": lib.ei_region_get_height(r),
                            "mapping_id": s(lib.ei_region_get_mapping_id(r)),
                            "physical_scale": lib.ei_region_get_physical_scale(r)})
            i += 1
        caps = [k for k, v in CAPS.items() if lib.ei_device_has_capability(dev, v)]
        info = {"name": s(lib.ei_device_get_name(dev)), "type": {1: "virtual", 2: "physical"}.get(
            lib.ei_device_get_type(dev)), "caps": caps, "regions": regions}
        if "keyboard" in caps:
            km = lib.ei_device_keyboard_get_keymap(dev)
            info["keymap"] = {"present": bool(km), "type": lib.ei_keymap_get_type(km) if km else None}
        return info

    def device_with(self, cap):
        for d, info in self.devices.items():
            if cap in info["caps"] and info.get("resumed"):
                return d
        return None

    def start(self, dev):
        lib.ei_device_start_emulating(dev, self.sequence)
        self.sequence += 1

    def frame(self, dev):
        lib.ei_device_frame(dev, lib.ei_now(self.ei))
        self.dispatch(0)

    def close(self):
        for d in list(self.devices):
            pass
        lib.ei_unref(self.ei)
        self.ei = None
