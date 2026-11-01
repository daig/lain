#!/usr/bin/env python3
"""Software-decodes an e2e HEVC dump with libde265 (ctypes; no GStreamer, no GPU) and checks it.

Reports the pictures decoded, every libde265 error and warning, the parameter sets seen, and, given the
reference NV12 of the last encoded frame (e2e --refdump), the PSNR of the last decoded picture against it.
Run it under spikes/linux-encoder/fence.sh.

Usage: decode-check.py <stream.h265> [<frame.nv12> <width> <height> <frame-index>]
(<frame-index> is e2e's refdump frame_index: the picture, counted from 0, the NV12 belongs to.)
"""

import ctypes
import math
import sys

lib = ctypes.CDLL("libde265.so.0")
lib.de265_new_decoder.restype = ctypes.c_void_p
lib.de265_push_data.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int64, ctypes.c_void_p]
lib.de265_flush_data.argtypes = [ctypes.c_void_p]
lib.de265_decode.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
lib.de265_get_next_picture.argtypes = [ctypes.c_void_p]
lib.de265_get_next_picture.restype = ctypes.c_void_p
lib.de265_get_warning.argtypes = [ctypes.c_void_p]
lib.de265_get_error_text.restype = ctypes.c_char_p
lib.de265_get_image_plane.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
lib.de265_get_image_plane.restype = ctypes.POINTER(ctypes.c_uint8)
lib.de265_get_image_width.argtypes = [ctypes.c_void_p, ctypes.c_int]
lib.de265_get_image_height.argtypes = [ctypes.c_void_p, ctypes.c_int]
lib.de265_free_decoder.argtypes = [ctypes.c_void_p]
WAITING_FOR_INPUT = 13

data = open(sys.argv[1], "rb").read()
nal_types = {}
i = 0
while True:
    i = data.find(b"\x00\x00\x01", i)
    if i < 0 or i + 3 >= len(data):
        break
    t = (data[i + 3] >> 1) & 0x3F
    nal_types[t] = nal_types.get(t, 0) + 1
    i += 3

dec = lib.de265_new_decoder()
lib.de265_push_data(dec, data, len(data), 0, None)
lib.de265_flush_data(dec)
errors, warnings, pictures, last = {}, {}, 0, None
more = ctypes.c_int(1)
while more.value:
    err = lib.de265_decode(dec, ctypes.byref(more))
    if err not in (0, WAITING_FOR_INPUT):
        text = lib.de265_get_error_text(err).decode()
        (warnings if err >= 1000 else errors)[text] = (warnings if err >= 1000 else errors).get(text, 0) + 1
    while True:
        w = lib.de265_get_warning(dec)
        if w == 0:
            break
        text = lib.de265_get_error_text(w).decode()
        warnings[text] = warnings.get(text, 0) + 1
    while True:
        img = lib.de265_get_next_picture(dec)
        if not img:
            break
        pictures += 1
        if len(sys.argv) > 5 and pictures - 1 == int(sys.argv[5]):  # copy the reference frame's planes
            planes = []
            for c in range(3):
                stride = ctypes.c_int()
                p = lib.de265_get_image_plane(img, c, ctypes.byref(stride))
                w_, h_ = lib.de265_get_image_width(img, c), lib.de265_get_image_height(img, c)
                buf = ctypes.string_at(p, stride.value * h_)
                planes.append(b"".join(buf[y * stride.value:y * stride.value + w_] for y in range(h_)))
            last = planes
    if err == WAITING_FOR_INPUT:
        break

print(f"nal types: {dict(sorted(nal_types.items()))} (32 VPS, 33 SPS, 34 PPS, 19 IDR_W_RADL, 1 TRAIL_R)")
print(f"decoded pictures: {pictures}; slices in stream: {nal_types.get(19, 0) + nal_types.get(1, 0)}")
print(f"errors: {errors or 'none'}")
print(f"warnings: {warnings or 'none'}")


def psnr(a, b):
    se = sum((x - y) * (x - y) for x, y in zip(a, b))
    return float("inf") if se == 0 else 10 * math.log10(255 * 255 * len(a) / se)


if len(sys.argv) > 5:
    if not last:
        print(f"picture {sys.argv[5]} was not decoded")
        sys.exit(1)
    W, H = int(sys.argv[3]), int(sys.argv[4])
    ref = open(sys.argv[2], "rb").read()
    y_ref, uv = ref[:W * H], ref[W * H:W * H * 3 // 2]
    cb_ref, cr_ref = uv[0::2], uv[1::2]
    # Subsample for speed: every 7th sample of each plane (Python-side arithmetic over 8.5 MB is slow).
    s = slice(0, None, 7)
    print(f"picture {sys.argv[5]} vs reference NV12 (every 7th sample): Y PSNR {psnr(last[0][s], y_ref[s]):.2f} dB, "
          f"Cb {psnr(last[1][s], cb_ref[s]):.2f} dB, Cr {psnr(last[2][s], cr_ref[s]):.2f} dB")
lib.de265_free_decoder(dec)
sys.exit(1 if errors or pictures == 0 else 0)
