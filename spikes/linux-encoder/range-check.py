#!/usr/bin/env python3
"""Checks the range vapostproc converts BGRx to NV12 with: white and black frames go through vapostproc
on the AMD iGPU with the given output colorimetry, are downloaded, and their luma printed (full range:
255/0; limited: 235/16). Usage: python3 -I range-check.py [colorimetry ...]"""
import sys

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402

Gst.init(None)
for colorimetry in sys.argv[1:] or ["", "1:3:7:1", "2:3:5:1"]:
    caps = "video/x-raw(memory:VAMemory),format=NV12" + (f",colorimetry={colorimetry}" if colorimetry else "")
    out = []
    for pattern in ("white", "black"):
        p = Gst.parse_launch(
            f"videotestsrc pattern={pattern} num-buffers=1 ! video/x-raw,format=BGRx,width=256,height=256 ! "
            f"vapostproc ! {caps} ! vapostproc ! video/x-raw,format=NV12 ! appsink name=s"
        )
        p.set_state(Gst.State.PLAYING)
        sample = p.get_by_name("s").emit("pull-sample")
        ok, info = sample.get_buffer().map(Gst.MapFlags.READ)
        out.append(f"{pattern} Y={info.data[256 * 128 + 128]}")
        p.set_state(Gst.State.NULL)
    neg = sample.get_caps().get_structure(0).get_value("colorimetry")
    print(f"colorimetry {colorimetry or '(default)'}: {', '.join(out)} (downloaded caps colorimetry {neg})")
