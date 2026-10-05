# Arsitektur

## Jalur sinyal

1. **Sensor.** Tiap OV7670 menerima XCLK 20 MHz dari FPGA dan berjalan bebas,
   mengeluarkan VGA 640x480 YUV422 pada bus 8 bit bersama PCLK, HREF, dan
   VSYNC miliknya sendiri.
2. **`ov7670_capture`** (satu per kamera, di ranah PCLK kamera itu). Mengambil
   1 dari tiap 4 piksel dan 1 dari tiap 4 baris, sehingga 640x480 menjadi
   160x120, dan hanya menyimpan 4 bit teratas luma.
3. **`preview_buffer`** (satu per kamera). Salinan frame yang bisa dibaca PS.
   Piksel dikemas 8 per kata 32 bit dan dibaca lewat AXI BRAM controller.
4. **Firmware** (Cortex-A9, bare metal, lwIP raw API). Membekukan kedua
   buffer, menyalin isinya ke datagram UDP, lalu melepas pembekuan.
5. **PC.** Penampil merakit ulang datagram menjadi frame dan menayangkannya.

## Ranah clock

| Clock | Frekuensi | Dipakai oleh |
|---|---|---|
| `clk_fpga_0` (FCLK0) | 40 MHz | AXI, pengendali SCCB, pembagi XCLK |
| `cam_xclk` | 20 MHz (FCLK0/2) | masukan clock kedua sensor, satu pin bersama |
| `cam_pclk` | ~20 MHz | penangkap kamera 1 |
| `cam2_pclk` | ~20 MHz | penangkap kamera 2 |

Kedua PCLK berasal dari sensor masing-masing dan dideklarasikan asinkron
terhadap satu sama lain dan terhadap FCLK0 (`camera_timing.xdc`).

## Mengapa 160x120 dan 4 bit

Pengurangannya sama di kedua sumbu, jadi piksel tetap persegi dan rasio 4:3
terjaga. Empat bit dipilih karena proyek induknya mencocokkan citra stereo
pada luma 4 bit dan memori FPGA-nya terbatas. Untuk kamera Ethernet saja,
batas ini bukan keharusan: 8 bit per piksel tinggal soal lebar buffer.

## Pembekuan frame (snapshot)

Buffer preview terus ditulisi kamera. Kalau PS membacanya sambil berjalan,
satu frame akan tersusun dari beberapa waktu tangkap. Karena itu ada jabat
tangan:

1. PS menaikkan bit `snap_arm`.
2. Tiap `preview_buffer` menunggu awal frame berikutnya, menangkap satu frame
   utuh, lalu berhenti dan menaikkan bit `ready`-nya.
3. PS menunggu **kedua** kamera siap, mengirim keduanya dengan `frame_id`
   yang sama, lalu menurunkan `snap_arm`.

Itulah yang membuat pasangan cam1/cam2 ber-`frame_id` sama benar-benar
berasal dari saat yang sama (dalam satu periode frame), dan itulah yang
dijadikan syarat oleh penampil dua-kamera.

## Konfigurasi sensor

`ov7670_controller` mengirim tabel register (`ov7670_registers.vhd`) ke kedua
sensor lewat SCCB setelah reset, dan mengulanginya bila bit `resend` ditulis.
Selain itu PS bisa mengambil alih bus SCCB (bit `sccb_en`) untuk membaca dan
menulis register satu per satu; inilah yang dipakai slider eksposur dan gain
di penampil. Pin SIOD memakai primitif `IOBUF` eksplisit, lihat
[06-catatan-rtl.md](06-catatan-rtl.md).

## Register PS

AXI GPIO dua kanal di `0x41200000`.

Kanal 1 (PS menulis), 25 bit:

| Bit | Nama | Fungsi |
|---|---|---|
| 0 | `resend` | kirim ulang tabel register ke kedua sensor |
| 4:1 | `row_offset` | rektifikasi mesin depth (tidak dipakai jalur kamera) |
| 12:5 | `col_offset` | rektifikasi mesin depth (tidak dipakai jalur kamera) |
| 13 | `sccb_en` | PS mengambil alih bus SCCB |
| 15:14 | `sioc` | SIOC kamera 1 / 2 saat `sccb_en` |
| 17:16 | `siod_o` | nilai SIOD |
| 19:18 | `siod_oe` | SIOD menarik rendah |
| 20 | `snap_arm` | minta pembekuan frame |
| 21 | `cam_reset_assert` | reset kedua sensor |
| 22 | `cam_pwdn_assert` | power-down kedua sensor |
| 23 | `luma_phase` | byte YUV422 mana yang disimpan |
| 24 | `cam_swap` | urutan kamera bagi mesin depth |

Kanal 2 (PS membaca):

| Bit | Nama |
|---|---|
| 0, 1 | konfigurasi kamera 1 / 2 selesai |
| 2 | bergantian tiap frame depth selesai |
| 4:3 | level SIOD kamera 1 / 2 |
| 7:5 | snapshot siap: kamera 1, kamera 2, depth |

Buffer preview kamera 1 dan 2 berada di `0x40100000` dan `0x40110000`. Alamat
diambil firmware dari `xparameters.h`; angka di atas adalah nilai yang
sekarang diberikan `build_bd.tcl`.
