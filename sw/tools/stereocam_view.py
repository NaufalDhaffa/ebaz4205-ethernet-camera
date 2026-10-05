#!/usr/bin/env python3
"""Live viewer for both cameras streaming at once.

    stereocam-view                     # from anywhere, if the symlink is installed
    sw/tools/stereocam_view.py         # from anywhere, by path
    python3 sw/tools/stereocam_view.py # any interpreter; re-execs into the venv

The board sends camera 1 and camera 2 as separate planes that share one
frame_id, because both buffers are frozen by the same snapshot before
either is read out. This viewer only puts a pair on screen once BOTH
planes of the same frame_id have arrived, so what you see side by side was
genuinely captured at the same instant. Showing each plane the moment it
lands would be simpler and would quietly pair up images milliseconds
apart -- which defeats the point of having two cameras.

Separate from ethcam_view.py (single camera) and depth_tuner.py (the old
three-plane stereo-depth tool, which is built around disparity and does
not apply to this build).

Camera controls can target camera 1, camera 2 or both at once. "Keduanya"
is the default because the two sensors should normally stay matched --
different exposure on each is exactly what makes a pair unusable.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import queue
import socket
import struct
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk

HERE = pathlib.Path(__file__).resolve()
VENV_PY = HERE.parents[2] / ".venv" / "bin" / "python"


def _reexec_in_venv():
    """Restart under the project venv, which owns numpy and PIL.

    Everything is resolved from __file__, never from the working directory,
    so the viewer starts the same way from anywhere -- including through a
    symlink on PATH, which is why __file__ is resolved before use.
    """
    if os.environ.get("STEREOCAM_BOOTSTRAPPED"):
        return      # already re-execed and still broken: let the real
                    # ImportError through instead of looping forever
    if not VENV_PY.exists():
        sys.exit(f"butuh numpy + Pillow, dan venv tidak ada di {VENV_PY}")
    os.environ["STEREOCAM_BOOTSTRAPPED"] = "1"
    os.execv(str(VENV_PY), [str(VENV_PY), str(HERE), *sys.argv[1:]])


try:
    import numpy as np
    from PIL import Image, ImageTk
except ImportError:
    _reexec_in_venv()
    raise

BOARD_IP = "192.168.2.10"
FRAME_PORT = 5001
CTRL_PORT = 5002
W, H = 160, 120
PIXELS = W * H
PLANES = {1: "cam1", 2: "cam2"}

HDR = struct.Struct("<HHBBH")
REQ = struct.Struct("<BBBBBBH")
RSP = struct.Struct("<BBBBBBH")

CMD_PING, CMD_SCCB_WRITE, CMD_SCCB_READ = 0x00, 0x01, 0x02
CMD_RESEND, CMD_GET_STATUS = 0x04, 0x05

REG_GAIN, REG_AECH = 0x00, 0x10
REG_COM7, REG_COM8 = 0x12, 0x13
REG_MVFP, REG_BRIGHT, REG_CONTRAS = 0x1E, 0x55, 0x56

COM8_AEC, COM8_AGC = 0x01, 0x04
COM7_COLORBAR = 0x02
MVFP_MIRROR, MVFP_VFLIP = 0x20, 0x10

STATUS_NAMES = {0: "ok", 1: "magic salah", 2: "cmd salah", 3: "NO ACK"}


class Control:
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

    def read_reg(self, cam, reg):
        return self.call(CMD_SCCB_READ, cam, reg)[1]

    def write_reg(self, cam, reg, val):
        return self.call(CMD_SCCB_WRITE, cam, reg, val & 0xFF)[0]


def receiver(stop, out_q, log_q, bind_ip):
    """Reassemble both planes and emit only complete, matched pairs."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        # Interface address, not 0.0.0.0: a wildcard bind receives nothing
        # on this point-to-point link.
        s.bind((bind_ip, FRAME_PORT))
    except OSError as e:
        log_q.put(f"tidak bisa bind UDP {bind_ip}:{FRAME_PORT}: {e}")
        return
    s.settimeout(0.5)

    pend = {}
    while not stop.is_set():
        try:
            pkt, _ = s.recvfrom(2048)
        except socket.timeout:
            continue
        if len(pkt) < HDR.size:
            continue
        fid, idx, plane, _a, _b = HDR.unpack_from(pkt, 0)
        if plane not in PLANES:
            continue
        payload = pkt[HDR.size:]
        if idx + len(payload) > PIXELS:
            continue

        st = pend.setdefault(fid, {})
        p = st.setdefault(plane, {"buf": bytearray(PIXELS), "have": 0})
        p["buf"][idx:idx + len(payload)] = payload
        p["have"] += len(payload)

        if len(st) == 2 and all(v["have"] >= PIXELS for v in st.values()):
            pair = {n: bytes(st[k]["buf"]) for k, n in PLANES.items()}
            del pend[fid]
            try:
                out_q.put_nowait((fid, pair))
            except queue.Full:
                pass
        # A dropped datagram leaves a pair permanently incomplete; age them
        # out so memory does not grow.
        for old in [k for k in pend if k < fid - 4]:
            del pend[old]
    s.close()


class StereoViewer:
    def __init__(self, root, bind_ip, ip, out_dir):
        self.root = root
        self.out_dir = pathlib.Path(out_dir).expanduser().resolve()
        root.title("EBAZ4205 — dua kamera (cam1 + cam2)")

        self.ctrl = Control(ip)
        self.pairs = queue.Queue(maxsize=2)
        self.logs = queue.Queue()
        self.stop = threading.Event()
        threading.Thread(target=receiver,
                         args=(self.stop, self.pairs, self.logs, bind_ip),
                         daemon=True).start()

        self.n, self.t0, self.fps = 0, time.time(), 0.0
        self.last = None
        self.photos = {}
        self.scale = 3

        self._build()
        self.root.after(30, self._pump)
        self.root.protocol("WM_DELETE_WINDOW", self._quit)

    def _build(self):
        main = ttk.Frame(self.root, padding=8)
        main.grid(row=0, column=0, sticky="nsew")

        self.canvas, self.img_id, self.stat = {}, {}, {}
        for col, name in enumerate(("cam1", "cam2")):
            box = ttk.LabelFrame(main, text=f"  {name}  ", padding=4)
            box.grid(row=0, column=col, padx=(0, 8), sticky="n")
            cv = tk.Canvas(box, width=W * self.scale, height=H * self.scale,
                           bg="#111", highlightthickness=1,
                           highlightbackground="#555")
            cv.grid(row=0, column=0)
            self.canvas[name] = cv
            self.img_id[name] = cv.create_image(0, 0, anchor="nw")
            lbl = ttk.Label(box, text="-", font=("TkFixedFont", 8))
            lbl.grid(row=1, column=0, sticky="w", pady=(4, 0))
            self.stat[name] = lbl

        self.pair_lbl = ttk.Label(main, text="menunggu pasangan frame...",
                                  font=("TkFixedFont", 9))
        self.pair_lbl.grid(row=1, column=0, columnspan=2, sticky="w", pady=(6, 0))

        side = ttk.Frame(main, padding=(12, 0, 0, 0))
        side.grid(row=0, column=2, rowspan=2, sticky="n")
        r = 0

        ttk.Label(side, text="Kendali berlaku untuk").grid(row=r, column=0, sticky="w")
        self.target = tk.StringVar(value="Keduanya")
        ttk.Combobox(side, textvariable=self.target, width=10, state="readonly",
                     values=("Keduanya", "cam1", "cam2")
                     ).grid(row=r, column=1, sticky="e"); r += 1
        ttk.Button(side, text="Periksa kedua kamera (PID)", command=self.probe
                   ).grid(row=r, column=0, columnspan=2, sticky="ew", pady=(6, 8)); r += 1

        ttk.Label(side, text="Eksposur", font=("TkDefaultFont", 10, "bold")
                  ).grid(row=r, column=0, columnspan=2, sticky="w"); r += 1
        self.auto_exp = tk.BooleanVar(value=True)
        ttk.Checkbutton(side, text="Otomatis (AEC + AGC)", variable=self.auto_exp,
                        command=self.apply_auto
                        ).grid(row=r, column=0, columnspan=2, sticky="w"); r += 1

        self.v_exp = tk.IntVar(value=120)
        r = self._slider(side, r, "Eksposur (AECH)", self.v_exp, 0, 255,
                         lambda: self.write(REG_AECH, self.v_exp.get()))
        self.v_gain = tk.IntVar(value=32)
        r = self._slider(side, r, "Gain", self.v_gain, 0, 255,
                         lambda: self.write(REG_GAIN, self.v_gain.get()))
        self.v_bright = tk.IntVar(value=0)
        r = self._slider(side, r, "Kecerahan", self.v_bright, 0, 255,
                         lambda: self.write(REG_BRIGHT, self.v_bright.get()))
        self.v_contrast = tk.IntVar(value=64)
        r = self._slider(side, r, "Kontras", self.v_contrast, 0, 255,
                         lambda: self.write(REG_CONTRAS, self.v_contrast.get()))

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

        ttk.Button(side, text="Kirim ulang tabel register", command=self.resend
                   ).grid(row=r, column=0, columnspan=2, sticky="ew", pady=(8, 2)); r += 1
        ttk.Button(side, text="Simpan pasangan PNG", command=self.save
                   ).grid(row=r, column=0, columnspan=2, sticky="ew"); r += 1

        self.log = tk.Text(main, height=7, width=96, font=("TkFixedFont", 8),
                           bg="#f7f7f7", relief="flat")
        self.log.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(8, 0))

    def _slider(self, parent, row, label, var, lo, hi, cb):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w")
        ttk.Label(parent, textvariable=var, width=4).grid(row=row, column=1, sticky="e")
        s = ttk.Scale(parent, from_=lo, to=hi, variable=var, orient="horizontal",
                      length=190, command=lambda v: var.set(int(float(v))))
        s.grid(row=row + 1, column=0, columnspan=2, sticky="ew")
        # Commit on release, not on every pixel of the drag: SCCB runs at
        # ~100 kHz and would be swamped.
        s.bind("<ButtonRelease-1>", lambda _e: cb())
        return row + 2

    # ---------------- helpers ----------------
    def say(self, msg):
        self.log.insert("end", msg.rstrip() + "\n")
        self.log.see("end")

    def cams(self):
        t = self.target.get()
        return (0, 1) if t == "Keduanya" else ((0,) if t == "cam1" else (1,))

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
            for c in self.cams():
                st = self.ctrl.write_reg(c, reg, val)
                self.say(f"cam{c+1} 0x{reg:02X}=0x{val:02X} -> "
                         f"{STATUS_NAMES.get(st, st)}")
        self.guard(go, f"tulis 0x{reg:02X}")

    # ---------------- actions ----------------
    def probe(self):
        def go():
            for c in (0, 1):
                pid = self.ctrl.read_reg(c, 0x0A)
                ver = self.ctrl.read_reg(c, 0x0B)
                ok = "COCOK" if pid == 0x76 else "SALAH (harap 0x76)"
                self.say(f"cam{c+1}: PID=0x{pid:02X} VER=0x{ver:02X}  {ok}")
        self.guard(go, "probe")

    def apply_auto(self):
        def go():
            bits = COM8_AEC | COM8_AGC
            for c in self.cams():
                com8 = self.ctrl.read_reg(c, REG_COM8)
                com8 = (com8 | bits) if self.auto_exp.get() else (com8 & ~bits)
                self.ctrl.write_reg(c, REG_COM8, com8)
                self.say(f"cam{c+1} eksposur "
                         f"{'otomatis' if self.auto_exp.get() else 'manual'} "
                         f"(COM8=0x{com8 & 0xFF:02X})")
        self.guard(go, "auto exposure")

    def apply_mvfp(self):
        v = (MVFP_MIRROR if self.mirror.get() else 0) | \
            (MVFP_VFLIP if self.vflip.get() else 0)
        self.write(REG_MVFP, v)

    def apply_testbar(self):
        def go():
            for c in self.cams():
                com7 = self.ctrl.read_reg(c, REG_COM7)
                com7 = (com7 | COM7_COLORBAR) if self.testbar.get() \
                    else (com7 & ~COM7_COLORBAR)
                self.ctrl.write_reg(c, REG_COM7, com7)
            self.say(f"pola uji {'ON' if self.testbar.get() else 'OFF'}")
        self.guard(go, "test pattern")

    def resend(self):
        def go():
            self.ctrl.call(CMD_RESEND)
            self.say("tabel register dikirim ulang (kedua kamera)")
        self.guard(go, "resend")

    def save(self):
        if self.last is None:
            self.say("belum ada pasangan untuk disimpan")
            return
        stamp = time.strftime("%Y%m%d_%H%M%S")
        try:
            self.out_dir.mkdir(parents=True, exist_ok=True)
            for name, a in self.last.items():
                img = self._oriented(a)
                ih, iw = img.shape
                Image.fromarray(img).resize((iw * self.scale, ih * self.scale),
                                            Image.NEAREST).save(
                    self.out_dir / f"stereo_{stamp}_{name}.png")
        except OSError as e:
            self.say(f"gagal menyimpan: {e}")
            return
        # Absolute path: started from an arbitrary directory, "disimpan ke
        # stereo_....png" would not say where.
        self.say(f"disimpan: {self.out_dir}/stereo_{stamp}_cam{{1,2}}.png")

    def _oriented(self, a):
        rot = int(self.rotation.get())
        return np.rot90(a, k=(-rot // 90) % 4) if rot else a

    # ---------------- render ----------------
    def _pump(self):
        try:
            while True:
                self.say(self.logs.get_nowait())
        except queue.Empty:
            pass

        newest = None
        try:
            while True:
                newest = self.pairs.get_nowait()
        except queue.Empty:
            pass

        if newest is not None:
            fid, pair = newest
            arrs = {n: np.frombuffer(b, dtype=np.uint8).reshape(H, W)
                    for n, b in pair.items()}
            self.last = arrs
            self.n += 1
            dt = time.time() - self.t0
            if dt >= 1.0:
                self.fps = self.n / dt
                self.n, self.t0 = 0, time.time()

            for name, a in arrs.items():
                shown = self._oriented(a)
                if self.stretch.get():
                    lo, hi = int(shown.min()), int(shown.max())
                    if hi > lo:
                        shown = ((shown.astype(np.int32) - lo) * 255
                                 // (hi - lo)).astype(np.uint8)
                ih, iw = shown.shape
                cw, ch = iw * self.scale, ih * self.scale
                cv = self.canvas[name]
                if (int(cv["width"]), int(cv["height"])) != (cw, ch):
                    cv.config(width=cw, height=ch)
                img = Image.fromarray(shown).resize((cw, ch), Image.NEAREST)
                self.photos[name] = ImageTk.PhotoImage(img)
                cv.itemconfig(self.img_id[name], image=self.photos[name])

                # Stats always describe the RAW frame, never the rotated or
                # stretched view -- otherwise a dark image looks solved.
                hdiff = float(np.abs(np.diff(a.astype(np.int16), axis=1)).mean())
                clip = 100.0 * float(((a == 0) | (a == 255)).mean())
                rows = int((a.max(axis=1) > 0).sum())
                self.stat[name].config(
                    text=f"baris {rows:3d}/{H}  mean {a.mean():5.1f}  "
                         f"jenuh {clip:4.1f}%  beda {hdiff:4.1f}  "
                         f"aras {len(np.unique(a)):2d}/16")

            self.pair_lbl.config(
                text=f"{self.fps:5.1f} pasang/detik   frame_id {fid}   "
                     f"kedua citra dari instan yang sama")

        self.root.after(30, self._pump)

    def _quit(self):
        self.stop.set()
        self.root.after(100, self.root.destroy)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="192.168.2.1")
    ap.add_argument("--ip", default=BOARD_IP)
    ap.add_argument("-o", "--out", default=".",
                    help="direktori untuk PNG yang disimpan (default: direktori kerja)")
    a = ap.parse_args()
    root = tk.Tk()
    StereoViewer(root, a.bind, a.ip, a.out)
    root.mainloop()


if __name__ == "__main__":
    main()
