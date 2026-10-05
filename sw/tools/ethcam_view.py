#!/usr/bin/env python3
"""Live viewer for the board running as a single-camera Ethernet camera.

    .venv/bin/python sw/tools/ethcam_view.py

Shows camera 1's stream and exposes the camera registers that actually
matter once the pipeline itself is working: auto-exposure, manual exposure,
gain, brightness, contrast, mirror/flip and the colour-bar test pattern.

Separate from depth_tuner.py on purpose. That tool drives the three-plane
stereo set and is built around disparity -- rectification offsets, valid-%
of the depth map, distance readout. None of that applies here: this build
streams one camera and nothing else.

Two details are easy to get wrong and are handled here:

  * The frame socket binds the interface address, not 0.0.0.0. On this
    point-to-point link a wildcard bind silently receives nothing while the
    same socket bound to 192.168.2.1 gets every datagram.

  * The sensor is mounted on its side, so the view is rotated -90 by
    default. Rotation is display-side only; the stats row and any saved
    .raw stay in sensor orientation so they still line up with the ILA.

  * Pixels are 4-bit luma scaled to 0..255, so there are only 16 distinct
    levels. The "regangkan kontras" switch stretches that for DISPLAY only
    and does not touch the sensor -- the numbers in the stats row always
    describe the raw frame, so a dark image still reads as dark.
"""

from __future__ import annotations

import argparse
import queue
import socket
import struct
import threading
import time
import tkinter as tk
from tkinter import ttk

import numpy as np
from PIL import Image, ImageTk

BOARD_IP = "192.168.2.10"
FRAME_PORT = 5001
CTRL_PORT = 5002
W, H = 160, 120
PIXELS = W * H
PLANE_CAM1 = 1

HDR = struct.Struct("<HHBBH")      # frame_id, chunk_index, plane, pad, pad
REQ = struct.Struct("<BBBBBBH")    # magic0 magic1 cmd cam arg0 arg1 seq
RSP = struct.Struct("<BBBBBBH")

CMD_PING, CMD_SCCB_WRITE, CMD_SCCB_READ = 0x00, 0x01, 0x02
CMD_RESEND, CMD_GET_STATUS = 0x04, 0x05

# OV7670 registers this UI touches.
REG_GAIN, REG_COM1, REG_AECH = 0x00, 0x04, 0x10
REG_COM7, REG_COM8 = 0x12, 0x13
REG_MVFP, REG_BRIGHT, REG_CONTRAS = 0x1E, 0x55, 0x56

COM8_AEC = 0x01      # auto exposure
COM8_AWB = 0x02
COM8_AGC = 0x04      # auto gain
COM7_COLORBAR = 0x02
MVFP_MIRROR, MVFP_VFLIP = 0x20, 0x10

STATUS_NAMES = {0: "ok", 1: "magic salah", 2: "cmd salah", 3: "NO ACK"}


class Control:
    """UDP control channel to the board. One retry: a lost datagram on a
    point-to-point link is rare, but a tuning command that silently does
    nothing is worse than a slightly slower UI."""

    def __init__(self, ip=BOARD_IP, timeout=1.0):
        self.addr = (ip, CTRL_PORT)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)
        self.lock = threading.Lock()
        self.seq = 0

    def call(self, cmd, cam=0, arg0=0, arg1=0):
        with self.lock:
            self.seq = (self.seq + 1) & 0xFFFF
            seq = self.seq
            pkt = REQ.pack(ord("D"), ord("C"), cmd, cam, arg0, arg1, seq)
            for _ in range(2):
                self.sock.sendto(pkt, self.addr)
                try:
                    data, _ = self.sock.recvfrom(64)
                except socket.timeout:
                    continue
                if len(data) < RSP.size:
                    continue
                m0, m1, _rc, status, value, _pad, rseq = RSP.unpack_from(data)
                if (m0, m1) == (ord("D"), ord("C")) and rseq == seq:
                    return status, value
            raise TimeoutError("board tidak merespons")

    def read_reg(self, reg):
        return self.call(CMD_SCCB_READ, 0, reg)[1]

    def write_reg(self, reg, val):
        return self.call(CMD_SCCB_WRITE, 0, reg, val & 0xFF)[0]


def receiver(stop, out_q, log_q, bind_ip):
    """Reassemble camera-1 frames and hand over the newest one."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((bind_ip, FRAME_PORT))
    except OSError as e:
        log_q.put(f"tidak bisa bind UDP {bind_ip}:{FRAME_PORT}: {e}")
        return
    s.settimeout(0.5)

    partial = {}
    while not stop.is_set():
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
            try:
                out_q.put_nowait(bytes(st["buf"]))
            except queue.Full:
                pass          # display is behind; newest frame wins
        for old in [k for k in partial if k < fid - 4]:
            del partial[old]
    s.close()


class Viewer:
    def __init__(self, root, bind_ip, ip):
        self.root = root
        root.title("EBAZ4205 — Ethernet camera (kamera 1)")

        self.ctrl = Control(ip)
        self.frames = queue.Queue(maxsize=2)
        self.logs = queue.Queue()
        self.stop = threading.Event()
        self.rx = threading.Thread(target=receiver,
                                   args=(self.stop, self.frames, self.logs, bind_ip),
                                   daemon=True)
        self.rx.start()

        self.n_frames = 0
        self.t0 = time.time()
        self.fps = 0.0
        self.last_img = None

        self._build()
        self.root.after(30, self._pump)
        self.root.protocol("WM_DELETE_WINDOW", self._quit)

    # ---------------- layout ----------------
    def _build(self):
        main = ttk.Frame(self.root, padding=8)
        main.grid(row=0, column=0, sticky="nsew")

        self.scale = 4
        self.canvas = tk.Canvas(main, width=W * self.scale, height=H * self.scale,
                                bg="#111", highlightthickness=1,
                                highlightbackground="#555")
        self.canvas.grid(row=0, column=0, rowspan=2, sticky="nw")
        self.img_id = self.canvas.create_image(0, 0, anchor="nw")

        self.stats = ttk.Label(main, text="menunggu frame...",
                               font=("TkFixedFont", 9))
        self.stats.grid(row=2, column=0, sticky="w", pady=(6, 0))

        side = ttk.Frame(main, padding=(12, 0, 0, 0))
        side.grid(row=0, column=1, sticky="n")
        r = 0

        self.status_lbl = ttk.Label(side, text="status: -", font=("TkFixedFont", 9))
        self.status_lbl.grid(row=r, column=0, columnspan=2, sticky="w"); r += 1
        ttk.Button(side, text="Periksa kamera (PID)", command=self.probe
                   ).grid(row=r, column=0, columnspan=2, sticky="ew", pady=(4, 8)); r += 1

        # --- exposure ---
        ttk.Label(side, text="Eksposur", font=("TkDefaultFont", 10, "bold")
                  ).grid(row=r, column=0, columnspan=2, sticky="w"); r += 1
        self.auto_exp = tk.BooleanVar(value=True)
        ttk.Checkbutton(side, text="Otomatis (AEC + AGC)", variable=self.auto_exp,
                        command=self.apply_auto
                        ).grid(row=r, column=0, columnspan=2, sticky="w"); r += 1

        self.v_exp = tk.IntVar(value=120)
        r = self._slider(side, r, "Eksposur (AECH)", self.v_exp, 0, 255,
                         lambda _v: self.write(REG_AECH, self.v_exp.get()))
        self.v_gain = tk.IntVar(value=32)
        r = self._slider(side, r, "Gain", self.v_gain, 0, 255,
                         lambda _v: self.write(REG_GAIN, self.v_gain.get()))
        self.v_bright = tk.IntVar(value=0)
        r = self._slider(side, r, "Kecerahan", self.v_bright, 0, 255,
                         lambda _v: self.write(REG_BRIGHT, self.v_bright.get()))
        self.v_contrast = tk.IntVar(value=64)
        r = self._slider(side, r, "Kontras", self.v_contrast, 0, 255,
                         lambda _v: self.write(REG_CONTRAS, self.v_contrast.get()))

        # --- orientation / test ---
        ttk.Separator(side, orient="horizontal").grid(
            row=r, column=0, columnspan=2, sticky="ew", pady=6); r += 1
        self.mirror = tk.BooleanVar(value=False)
        self.vflip = tk.BooleanVar(value=False)
        ttk.Checkbutton(side, text="Cermin", variable=self.mirror,
                        command=self.apply_mvfp).grid(row=r, column=0, sticky="w")
        ttk.Checkbutton(side, text="Balik vertikal", variable=self.vflip,
                        command=self.apply_mvfp).grid(row=r, column=1, sticky="w"); r += 1
        self.testbar = tk.BooleanVar(value=False)
        ttk.Checkbutton(side, text="Pola uji colour bar", variable=self.testbar,
                        command=self.apply_testbar
                        ).grid(row=r, column=0, columnspan=2, sticky="w"); r += 1

        # --- display-only ---
        ttk.Separator(side, orient="horizontal").grid(
            row=r, column=0, columnspan=2, sticky="ew", pady=6); r += 1
        self.stretch = tk.BooleanVar(value=False)
        ttk.Checkbutton(side, text="Regangkan kontras (tampilan saja)",
                        variable=self.stretch
                        ).grid(row=r, column=0, columnspan=2, sticky="w"); r += 1
        ttk.Label(side, text="Putar").grid(row=r, column=0, sticky="w")
        self.rotation = tk.StringVar(value="90")
        ttk.Combobox(side, textvariable=self.rotation, width=6, state="readonly",
                     values=("0", "-90", "90", "180")
                     ).grid(row=r, column=1, sticky="e"); r += 1

        ttk.Button(side, text="Kirim ulang tabel register",
                   command=self.resend).grid(row=r, column=0, columnspan=2,
                                             sticky="ew", pady=(8, 2)); r += 1
        ttk.Button(side, text="Simpan PNG", command=self.save
                   ).grid(row=r, column=0, columnspan=2, sticky="ew"); r += 1

        self.log = tk.Text(main, height=7, width=78, font=("TkFixedFont", 8),
                           bg="#f7f7f7", relief="flat")
        self.log.grid(row=3, column=0, columnspan=2, sticky="ew", pady=(8, 0))

    def _slider(self, parent, row, label, var, lo, hi, cb):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w")
        val = ttk.Label(parent, textvariable=var, width=4)
        val.grid(row=row, column=1, sticky="e")
        s = ttk.Scale(parent, from_=lo, to=hi, variable=var, orient="horizontal",
                      length=190,
                      command=lambda v: var.set(int(float(v))))
        s.grid(row=row + 1, column=0, columnspan=2, sticky="ew")
        s.bind("<ButtonRelease-1>", lambda _e: cb(var.get()))
        return row + 2

    # ---------------- helpers ----------------
    def say(self, msg):
        self.log.insert("end", msg.rstrip() + "\n")
        self.log.see("end")

    def guard(self, fn, what):
        try:
            return fn()
        except TimeoutError:
            self.say(f"{what}: board tidak merespons")
        except Exception as e:                      # noqa: BLE001
            self.say(f"{what}: {e}")
        return None

    def write(self, reg, val):
        def go():
            st = self.ctrl.write_reg(reg, val)
            self.say(f"tulis 0x{reg:02X} = 0x{val:02X} -> {STATUS_NAMES.get(st, st)}")
        self.guard(go, f"tulis 0x{reg:02X}")

    # ---------------- actions ----------------
    def probe(self):
        def go():
            pid = self.ctrl.read_reg(0x0A)
            ver = self.ctrl.read_reg(0x0B)
            ok = "COCOK" if pid == 0x76 else "SALAH (harusnya 0x76)"
            self.say(f"PID=0x{pid:02X} VER=0x{ver:02X}  {ok}")
        self.guard(go, "probe")

    def apply_auto(self):
        def go():
            com8 = self.ctrl.read_reg(REG_COM8)
            bits = COM8_AEC | COM8_AGC
            com8 = (com8 | bits) if self.auto_exp.get() else (com8 & ~bits)
            self.ctrl.write_reg(REG_COM8, com8)
            mode = "otomatis" if self.auto_exp.get() else "manual"
            self.say(f"eksposur {mode} (COM8=0x{com8 & 0xFF:02X})")
        self.guard(go, "auto exposure")

    def apply_mvfp(self):
        v = (MVFP_MIRROR if self.mirror.get() else 0) | \
            (MVFP_VFLIP if self.vflip.get() else 0)
        self.write(REG_MVFP, v)

    def apply_testbar(self):
        def go():
            com7 = self.ctrl.read_reg(REG_COM7)
            com7 = (com7 | COM7_COLORBAR) if self.testbar.get() \
                else (com7 & ~COM7_COLORBAR)
            self.ctrl.write_reg(REG_COM7, com7)
            self.say(f"pola uji {'ON' if self.testbar.get() else 'OFF'}")
        self.guard(go, "test pattern")

    def resend(self):
        def go():
            self.ctrl.call(CMD_RESEND)
            self.say("tabel register dikirim ulang")
        self.guard(go, "resend")

    def save(self):
        if self.last_img is None:
            self.say("belum ada frame untuk disimpan")
            return
        name = time.strftime("ethcam_%Y%m%d_%H%M%S.png")
        a = self.last_img
        rot = int(self.rotation.get())
        if rot:
            a = np.rot90(a, k=(-rot // 90) % 4)
        ih, iw = a.shape
        Image.fromarray(a).resize(
            (iw * self.scale, ih * self.scale), Image.NEAREST).save(name)
        self.say(f"disimpan: {name}")

    # ---------------- render loop ----------------
    def _pump(self):
        try:
            while True:
                self.say(self.logs.get_nowait())
        except queue.Empty:
            pass

        newest = None
        try:
            while True:
                newest = self.frames.get_nowait()
        except queue.Empty:
            pass

        if newest is not None:
            a = np.frombuffer(newest, dtype=np.uint8).reshape(H, W)
            self.last_img = a
            self.n_frames += 1
            dt = time.time() - self.t0
            if dt >= 1.0:
                self.fps = self.n_frames / dt
                self.n_frames, self.t0 = 0, time.time()

            shown = a
            rot = int(self.rotation.get())
            if rot:
                shown = np.rot90(shown, k=(-rot // 90) % 4)
            if self.stretch.get():
                lo, hi = int(a.min()), int(a.max())
                if hi > lo:
                    shown = ((a.astype(np.int32) - lo) * 255 // (hi - lo)).astype(np.uint8)

            ih, iw = shown.shape
            cw, ch = iw * self.scale, ih * self.scale
            if (int(self.canvas["width"]), int(self.canvas["height"])) != (cw, ch):
                self.canvas.config(width=cw, height=ch)
            img = Image.fromarray(shown).resize((cw, ch), Image.NEAREST)
            self.photo = ImageTk.PhotoImage(img)
            self.canvas.itemconfig(self.img_id, image=self.photo)

            # Always describe the RAW frame, never the stretched view.
            hdiff = float(np.abs(np.diff(a.astype(np.int16), axis=1)).mean())
            clip = 100.0 * float(((a == 0) | (a == 255)).mean())
            rows = int((a.max(axis=1) > 0).sum())
            self.stats.config(
                text=f"{self.fps:5.1f} fps   baris {rows:3d}/{H}   "
                     f"mean {a.mean():5.1f}   jenuh {clip:4.1f}%   "
                     f"beda-tetangga {hdiff:4.1f}   aras {len(np.unique(a)):2d}/16")

        self.root.after(30, self._pump)

    def _quit(self):
        self.stop.set()
        self.root.after(100, self.root.destroy)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="192.168.2.1",
                    help="alamat antarmuka lokal untuk socket frame")
    ap.add_argument("--ip", default=BOARD_IP, help="alamat board")
    a = ap.parse_args()

    root = tk.Tk()
    Viewer(root, a.bind, a.ip)
    root.mainloop()


if __name__ == "__main__":
    main()
