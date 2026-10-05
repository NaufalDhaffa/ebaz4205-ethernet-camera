#!/usr/bin/env python3
"""Grab camera-1 frames from the board.

The board streams several planes per frame (see docs/03-protokol-udp.md);
this tool keeps only plane 1, camera 1, and ignores the rest.

    .venv/bin/python sw/tools/ethcam_capture.py -n 4 -o shots/

Pixels arrive as 4-bit luma scaled to 0..255, i.e. only 16 distinct levels.
The quality numbers printed alongside are the two that actually diagnose a
bad image: horizontal neighbour difference (real luma is smooth, chroma
sampled by mistake is not) and the fraction of pixels pinned at 0 or 255
(clipping, i.e. auto-exposure not doing its job).
"""

from __future__ import annotations

import argparse
import pathlib
import socket
import struct
import time

import numpy as np

FRAME_PORT = 5001
W, H = 160, 120
PIXELS = W * H
HDR = struct.Struct("<HHBBH")
PLANE_CAM1 = 1


def frames(bind_ip, want, timeout):
    """Yield complete camera-1 frames as HxW uint8 arrays."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Bind the interface address: a wildcard bind receives nothing on this
    # point-to-point link while the same socket bound to the interface gets
    # every datagram.
    s.bind((bind_ip, FRAME_PORT))
    s.settimeout(1.0)

    partial = {}
    got = 0
    deadline = time.time() + timeout
    try:
        while got < want and time.time() < deadline:
            try:
                pkt, _ = s.recvfrom(2048)
            except socket.timeout:
                continue
            if len(pkt) < HDR.size:
                continue
            fid, idx, plane, _a, _b = HDR.unpack_from(pkt, 0)
            if plane != PLANE_CAM1:
                continue
            payload = pkt[HDR.size:]
            if idx + len(payload) > PIXELS:
                continue
            st = partial.setdefault(fid, {"buf": bytearray(PIXELS), "have": 0})
            st["buf"][idx:idx + len(payload)] = payload
            st["have"] += len(payload)
            if st["have"] >= PIXELS:
                del partial[fid]
                got += 1
                yield fid, np.frombuffer(bytes(st["buf"]), dtype=np.uint8).reshape(H, W)
            for old in [k for k in partial if k < fid - 4]:
                del partial[old]
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--count", type=int, default=1)
    ap.add_argument("-o", "--out", default="shots")
    ap.add_argument("--bind", default="192.168.2.1")
    ap.add_argument("--scale", type=int, default=4)
    ap.add_argument("--timeout", type=float, default=20.0)
    # The sensor is mounted on its side, so the stream arrives rotated. The
    # correction lives here rather than in RTL: it costs nothing on the host
    # and stays adjustable if the camera is remounted.
    ap.add_argument("--rotate", type=int, default=90, choices=[-90, 0, 90, 180],
                    help="putar citra sebelum disimpan (default 90)")
    a = ap.parse_args()

    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    from PIL import Image

    n = 0
    for fid, img in frames(a.bind, a.count, a.timeout):
        n += 1
        # .raw stays in sensor orientation: it is the wire format, and a
        # rotated copy would silently disagree with the ILA and the RTL.
        (out / f"cam1_{n:03d}.raw").write_bytes(img.tobytes())
        shown = np.rot90(img, k=(-a.rotate // 90) % 4) if a.rotate else img
        ih, iw = shown.shape
        Image.fromarray(shown).resize((iw * a.scale, ih * a.scale),
                                      Image.NEAREST).save(out / f"cam1_{n:03d}.png")
        hdiff = float(np.abs(np.diff(img.astype(int), axis=1)).mean())
        clip = 100.0 * float(((img == 0) | (img == 255)).mean())
        rows = int((img.max(axis=1) > 0).sum())
        print(f"  frame {n} (id {fid}): baris terisi {rows:3d}/120  "
              f"mean {img.mean():6.1f}  beda-tetangga {hdiff:6.1f}  "
              f"jenuh {clip:5.1f}%  unik {len(np.unique(img)):3d}")
    if n == 0:
        raise SystemExit("tidak ada frame kamera 1 diterima")
    print(f"ditulis ke {out}/")


if __name__ == "__main__":
    main()
