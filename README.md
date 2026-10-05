# Kamera Ethernet dua-sensor di EBAZ4205

Dua kamera OV7670 ditangkap oleh FPGA Zynq-7010 pada papan **EBAZ4205**, lalu
dialirkan ke PC lewat Ethernet 100 Mbps sebagai datagram UDP. Di sisi PC,
penampil Python menayangkan kedua kamera secara langsung dan mengatur
register sensor dari jarak jauh.

```
OV7670 #1 ─┐ 8-bit DVP                       ┌──────────────────────┐
           ├─ ov7670_capture ─ preview_buffer ┤ AXI BRAM controller  │
OV7670 #2 ─┘ (160x120, luma 4 bit)           └──────────┬───────────┘
     ▲                                                  │
     │ SCCB (konfigurasi)                    ┌──────────┴───────────┐
     └──────── AXI GPIO ─────────────────────┤ Cortex-A9, bare metal│
                                             │ lwIP raw API         │
                                             └──────────┬───────────┘
                                              UDP 5001 (frame) / 5002 (kendali)
                                             ┌──────────┴───────────┐
                                             │ PC: stereocam_view.py│
                                             └──────────────────────┘
```

## Angka terukur

| | nilai |
|---|---|
| Resolusi per kamera | 160 x 120, luma 4 bit (16 aras), 1 byte per piksel di kabel |
| Laju | 25 pasang frame/detik (dua kamera); 21 dengan bidang depth ikut dikirim |
| Sinkron antar kamera | kedua bidang satu `frame_id` dibekukan oleh satu snapshot |
| Piksel salah tangkap | ~0,1% per frame, setara di kedua kamera |
| Pemakaian FPGA | 7 626 LUT (43%), 54,5 dari 60 BRAM, slack +10,8 ns pada 40 MHz |
| Jaringan | papan `192.168.2.10`, PC `192.168.2.1/24`, tautan langsung |

Angka pemakaian FPGA mencakup seluruh bitstream, termasuk mesin depth dan
tiga inti ILA (lihat "Cakupan" di bawah).

## Mulai cepat

Papan sudah diprogram dan tersambung ke PC lewat kabel Ethernet:

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python sw/tools/stereocam_view.py
```

Antarmuka Ethernet PC harus beralamat `192.168.2.1/24`. Untuk membangun
bitstream dan firmware dari nol, lihat [docs/04-build-dan-deploy.md](docs/04-build-dan-deploy.md).

## Isi repo

| Jalur | Isi |
|---|---|
| `hw/ip/stereo_depth/` | RTL VHDL: penangkap OV7670, pengendali SCCB, buffer preview, top-level |
| `hw/constraints/` | pin kamera dan Ethernet, batasan clock |
| `hw/scripts/` | `build_bd.tcl` (block design + bitstream), `deploy.sh` (unggah lewat JTAG) |
| `sw/apps/depth_stream/src/` | firmware bare-metal: lwIP, pengirim frame, port kendali |
| `sw/tools/` | alat Python di PC |
| `docs/` | dokumentasi |

## Dokumentasi

1. [Arsitektur](docs/01-arsitektur.md) — jalur sinyal dari sensor sampai layar
2. [Perangkat keras](docs/02-perangkat-keras.md) — papan, pin, pengawatan kamera
3. [Protokol UDP](docs/03-protokol-udp.md) — format frame dan perintah kendali
4. [Build dan deploy](docs/04-build-dan-deploy.md) — Vivado, Vitis, JTAG
5. [Alat Python](docs/05-alat-python.md) — penampil, penangkap, pustaka jaringan
6. [Catatan RTL](docs/06-catatan-rtl.md) — cacat yang ditemukan dan cara memperbaikinya

## Cakupan

Repo ini mendokumentasikan **jalur kamera-ke-Ethernet**. Sumber RTL dan
firmware disalin apa adanya dari proyek induknya,
[depthcam-ebaz4205](https://github.com/NaufalDhaffa/depthcam-ebaz4205), supaya
yang ada di sini adalah persis yang sudah diuji di papan. Akibatnya bitstream
yang dihasilkan juga memuat mesin depth stereo (`depth_engine_sad.vhd`) dan
firmware ikut mengirim bidang ketiga berisi peta disparitas. Penampil kamera
di repo ini mengabaikan bidang itu. Mesin depth, kalibrasinya, dan alatnya
didokumentasikan di proyek induk.

## Asal-usul dan lisensi

RTL pengendali dan penangkap OV7670 berasal dari
[Archfx/FPGA-DepthMap-Basys3](https://github.com/Archfx/FPGA-DepthMap-Basys3)
(Aruna Jayasena), yang pengendali kameranya ditulis Mike Field, lalu dirombak
untuk papan ini; rinciannya ada di kepala tiap berkas dan di
[docs/06-catatan-rtl.md](docs/06-catatan-rtl.md). Berkas `LICENSE` (MIT)
disalin dari proyek induk.
