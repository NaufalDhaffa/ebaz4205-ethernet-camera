# Alat Python

Butuh Python 3 dengan `numpy` dan `Pillow` (`requirements.txt`), serta Tk
untuk penampil (`python3-tk` di Debian/Ubuntu).

Semua alat menerima `--bind` (default `192.168.2.1`); kedua penampil juga
menerima `--ip` (default `192.168.2.10`).

## `stereocam_view.py` — penampil dua kamera

```bash
.venv/bin/python sw/tools/stereocam_view.py [-o direktori_simpan]
```

- Dua panel berdampingan. Sepasang gambar hanya ditampilkan setelah kedua
  bidang dengan `frame_id` sama lengkap.
- Baris statistik per kamera: jumlah baris terisi, rata-rata, persen piksel
  jenuh, beda antar tetangga, dan jumlah aras. Statistik selalu dihitung dari
  frame mentah, bukan dari tampilan yang sudah diputar atau diregangkan.
- Kendali sensor lewat SCCB, berlaku untuk kamera 1, kamera 2, atau keduanya:
  eksposur otomatis (AEC + AGC), eksposur manual, gain, kecerahan, kontras,
  cermin, balik vertikal, pola uji colour bar.
- "Periksa kedua kamera" membaca ID produk (harus 0x76).
- "Kirim ulang tabel register" mengembalikan kedua sensor ke setelan awal.
- Rotasi tampilan (default 90 derajat), regang kontras untuk tampilan, dan
  simpan pasangan sebagai PNG.

Skrip bisa dijalankan dari direktori mana pun. Bila interpreter yang
memanggilnya tidak punya `numpy`/`Pillow`, ia memulai ulang dirinya dengan
`.venv/bin/python` di akar repo.

## `ethcam_view.py` — penampil satu kamera

```bash
.venv/bin/python sw/tools/ethcam_view.py
```

Menampilkan kamera 1 saja, dengan kendali sensor yang sama. Berguna saat
hanya satu modul terpasang atau untuk menyetel eksposur satu kamera.

## `ethcam_capture.py` — penangkap baris perintah

```bash
.venv/bin/python sw/tools/ethcam_capture.py -n 4 -o shots/
```

Menyimpan `-n` frame kamera 1 sebagai `.raw` (160x120 byte, orientasi
sensor) dan PNG (diputar sesuai `--rotate`, default 90). Mencetak statistik
tiap frame, sehingga bisa dipakai untuk memeriksa kualitas tangkapan tanpa
layar.

## `stereo_net.py` — pustaka

Dipakai untuk menulis alat sendiri:

```python
import numpy as np
from stereo_net import Control, recv_pair, W, H

ctl = Control()                       # port kendali 5002
print(hex(ctl.read_reg(0, 0x0A)))     # ID produk kamera 1 -> 0x76
ctl.write_reg(1, 0x55, 0x10)          # kecerahan kamera 2

fid, planes = recv_pair()             # blokir sampai satu pasangan lengkap
cam1 = np.frombuffer(planes["cam1"], np.uint8).reshape(H, W)
```

- `recv_pair()` mengembalikan `(frame_id, {"cam1": bytes, "cam2": bytes})`,
  ditambah kunci `"depth_hw"` bila bidang depth ikut diterima.
- `PairReceiver` adalah versi thread yang hanya menyimpan pasangan terbaru,
  untuk penampil langsung: bila pemakainya tertinggal, yang diambil frame
  terbaru, bukan antrean frame lama.

Catatan: `stereocam_view.py` dan `ethcam_view.py` masih memuat salinan
penerimanya sendiri dan tidak memakai `stereo_net.py`.

## Register OV7670 yang dipakai penampil

| Register | Alamat | Dipakai untuk |
|---|---|---|
| GAIN | 0x00 | gain manual |
| PID / VER | 0x0A / 0x0B | pengenal sensor: 0x76 / 0x73 |
| AECH | 0x10 | eksposur manual |
| COM7 | 0x12 | bit 1 = colour bar |
| COM8 | 0x13 | bit 0 = AEC, bit 2 = AGC |
| MVFP | 0x1E | bit 5 = cermin, bit 4 = balik vertikal |
| BRIGHT | 0x55 | kecerahan |
| CONTRAS | 0x56 | kontras |

Penulisan dilakukan saat slider dilepas, bukan selama digeser: SCCB berjalan
di sekitar 100 kHz dan akan kewalahan.
