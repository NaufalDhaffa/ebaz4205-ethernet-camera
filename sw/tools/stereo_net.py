"""Jalur jaringan bersama ke board: kendali SCCB dan penerima pasangan frame.

Dipisahkan ketika salinan ketiganya akan ditulis. Satu hal yang tidak boleh
berbeda antar alat adalah syarat pasangannya -- kedua bidang harus berasal
dari frame_id yang sama. Board membekukan kedua buffer dengan satu snapshot,
jadi pasangan ber-frame_id sama benar-benar satu instan; memasangkan bidang
dari frame berbeda menghasilkan disparitas yang mengukur gerakan, bukan jarak.

stereocam_view.py masih memakai salinannya sendiri: ia berjalan dan tidak ada
yang didapat dari mengusiknya sekarang.
"""

from __future__ import annotations

import socket
import struct
import threading
import time

BOARD_IP = "192.168.2.10"
FRAME_PORT, CTRL_PORT = 5001, 5002
W, H = 160, 120
PIXELS = W * H

HDR = struct.Struct("<HHBBH")
REQ = RSP = struct.Struct("<BBBBBBH")
PLANES = {1: "cam1", 2: "cam2"}
PLANE_DEPTH = 0          # keluaran depth_engine_sad: disparitas, 0 = kosong

CMD_PING, CMD_SCCB_WRITE, CMD_SCCB_READ = 0x00, 0x01, 0x02
CMD_RESEND, CMD_GET_STATUS = 0x04, 0x05
CMD_SET_RECT = 0x03
STATUS_NAMES = {0: "ok", 1: "magic salah", 2: "cmd salah", 3: "NO ACK"}


class Control:
    """Port kendali UDP 5002, request/response dengan nomor urut."""

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

    def set_rect(self, row_offset, col_offset, swap):
        """Tulis register rektifikasi mesin depth di FPGA.

        row_offset: geser sumbu silang, -8..7; col_offset: geser sumbu
        baseline, -128..127; swap: cam2 sebagai citra acuan. Mesin
        mencupliknya sekali per frame.
        """
        if not (-8 <= row_offset <= 7 and -128 <= col_offset <= 127):
            raise ValueError("geser di luar rentang register (-8..7, -128..127)")
        return self.call(CMD_SET_RECT, 1 if swap else 0,
                         row_offset & 0xF, col_offset & 0xFF)[0]

    def read_reg(self, cam, reg):
        return self.call(CMD_SCCB_READ, cam, reg)[1]

    def write_reg(self, cam, reg, val):
        return self.call(CMD_SCCB_WRITE, cam, reg, val & 0xFF)[0]


def _open_frame_socket(bind_ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Alamat antarmuka, bukan 0.0.0.0: bind wildcard tidak menerima apa pun
    # di tautan point-to-point ini, diam-diam dan tanpa error.
    s.bind((bind_ip, FRAME_PORT))
    s.settimeout(0.5)
    return s


def _feed(pend, pkt):
    """Masukkan satu datagram; kembalikan (fid, pasangan) kalau sudah lengkap."""
    if len(pkt) < HDR.size:
        return None
    fid, idx, plane, _a, _b = HDR.unpack_from(pkt, 0)
    if plane not in PLANES and plane != PLANE_DEPTH:
        return None
    payload = pkt[HDR.size:]
    if idx + len(payload) > PIXELS:
        return None
    st = pend.setdefault(fid, {})
    p = st.setdefault(plane, {"buf": bytearray(PIXELS), "have": 0})
    p["buf"][idx:idx + len(payload)] = payload
    p["have"] += len(payload)
    out = None
    if all(k in st and st[k]["have"] >= PIXELS for k in PLANES):
        out = (fid, {n: bytes(st[k]["buf"]) for k, n in PLANES.items()})
        # Bidang depth dari FPGA ikut bila ada dan lengkap. Board mengirimnya
        # SEBELUM kedua kamera, jadi saat pasangan kamera lengkap ia sudah
        # tiba atau memang tidak dikirim untuk frame ini; pasangan kamera
        # tidak pernah ditahan menunggunya.
        d = st.get(PLANE_DEPTH)
        if d and d["have"] >= PIXELS:
            out[1]["depth_hw"] = bytes(d["buf"])
        del pend[fid]
    # Datagram yang hilang membuat satu pasangan tidak pernah lengkap;
    # buang yang sudah tua supaya memori tidak tumbuh terus.
    for old in [k for k in pend if k < fid - 4]:
        del pend[old]
    return out


def recv_pair(bind_ip="192.168.2.1", timeout=15.0):
    """Blokir sampai satu pasangan lengkap datang. Untuk alat baris perintah."""
    s = _open_frame_socket(bind_ip)
    pend, deadline = {}, time.time() + timeout
    try:
        while time.time() < deadline:
            try:
                pkt, _ = s.recvfrom(2048)
            except socket.timeout:
                continue
            got = _feed(pend, pkt)
            if got:
                return got
        raise TimeoutError("tidak ada pasangan frame lengkap dalam batas waktu")
    finally:
        s.close()


class PairReceiver(threading.Thread):
    """Thread penerima yang hanya menyimpan pasangan TERBARU.

    Slot, bukan antrean, dan itu disengaja: kalau penghitung depth tertinggal,
    yang diinginkan adalah frame terbaru, bukan antrean frame basi yang
    membuat tampilan makin lama makin tertinggal dari kenyataan.
    """

    daemon = True

    def __init__(self, bind_ip="192.168.2.1", on_error=None):
        super().__init__()
        self.bind_ip = bind_ip
        self.on_error = on_error
        self.stop_flag = threading.Event()
        self.lock = threading.Lock()
        self.latest = None
        self.count = 0

    def run(self):
        try:
            s = _open_frame_socket(self.bind_ip)
        except OSError as e:
            if self.on_error:
                self.on_error(f"tidak bisa bind UDP "
                              f"{self.bind_ip}:{FRAME_PORT}: {e}")
            return
        pend = {}
        while not self.stop_flag.is_set():
            try:
                pkt, _ = s.recvfrom(2048)
            except socket.timeout:
                continue
            got = _feed(pend, pkt)
            if got:
                with self.lock:
                    self.latest = got
                    self.count += 1
        s.close()

    def take(self):
        """Ambil pasangan terbaru dan kosongkan slot; None kalau belum ada."""
        with self.lock:
            got, self.latest = self.latest, None
            return got

    def stop(self):
        self.stop_flag.set()
