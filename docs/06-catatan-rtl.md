# Catatan RTL: cacat yang ditemukan dan perbaikannya

Semua yang di bawah ini ditemukan di papan, sebagian besar dengan ILA, lalu
diperbaiki dan diukur ulang. Urutannya dari yang paling menentukan.

## 1. SCCB selalu membaca 0x00: SIOD tidak pernah menjadi masukan

**Gejala.** Menulis register tampak berhasil, membaca selalu 0x00.

**Sebab.** `cam_siod` disintesis sebagai `OBUF` biasa, tanpa penyangga
masukan dan tanpa tiga-keadaan. Penugasan `'Z'` yang ditulis secara baku pun
tetap diratakan menjadi `OBUF` begitu melewati batas sel block design.

**Perbaikan.** Primitif `IOBUF` diinstansiasi eksplisit di
`stereo_depth_top.vhd`; pin hanya pernah menarik rendah atau melepas
(open-drain), dan levelnya dibaca balik lewat keluaran `O`.

## 2. Data dicuplik di tepi yang salah

**Gejala.** Bintik terang di daerah gelap, bergeser dalam pita, muncul
"tiba-tiba" setelah build ulang; satu kamera ~1 300 piksel salah per frame
(7%) sementara kamera lain bersih.

**Sebab.** `ov7670_capture` mencuplik D[7:0] dan HREF pada tepi turun PCLK.
OV7670 mengganti datanya di tepi turun dan menahannya melewati tepi naik,
jadi hasil cuplikan bergantung pada selisih beberapa nanodetik antara tunda
clock dan tunda routing tiap bit. Keduanya tidak dikunci dan berubah di
setiap place-and-route. Piksel yang salah berisi bit dari byte kroma di
sebelahnya.

**Perbaikan.** Cuplik di tepi naik, dan register masukannya dikunci di sel
I/O (`attribute IOB`), supaya tunda pad-ke-register sama di setiap build.
Setelahnya kedua kamera setara di ~25 piksel terisolasi per frame (~0,1%).

## 3. Hanya 7 dari 120 baris terisi: VSYNC mentah

**Gejala.** Buffer preview hanya berisi beberapa baris, dan sinyal "siap"
menyala terlalu cepat.

**Sebab.** `ov7670_capture` men-debounce VSYNC di dalamnya, tetapi
`preview_buffer` memakai pin VSYNC mentah. ILA menunjukkan denyut VSYNC
selebar 0,6 mikrodetik (glitch di kabel pita); tiap glitch mengulang penunjuk
tulis.

**Perbaikan.** VSYNC yang sudah bersih diekspor (`vsync_clean_out`) dan
dipakai semua pemakai sinkron frame.

## 4. Gambar seperti derau: bit RGB565 diambil dari aliran YUV422

**Gejala.** Citra hampir biner dan berderau, hanya samar-samar mengikuti
kecerahan.

**Sebab.** Rancangan asal mengatur sensor ke RGB565 dan mengambil medan
R/G/B dari pasangan byte. Di sini sensor berjalan YUV422, sehingga posisi bit
yang sama melintasi batas byte: tiga bit bawah satu byte ditempel ke bit atas
byte berikutnya.

**Perbaikan.** Ambil 4 bit teratas dari satu byte utuh. Byte mana yang luma
dipilih oleh bit `luma_phase`; nilainya ditentukan dengan pengukuran, bukan
dari lembar data: pada byte luma, beda rata-rata antar piksel bertetangga
jauh lebih kecil daripada pada byte kroma. Penalaran "YUV422 itu U Y V Y,
jadi luma di indeks ganjil" memberi jawaban terbalik untuk sensor ini.

## 5. Kolom terakhir tiap baris berisi kroma

**Gejala.** Piksel ke-160 tiap baris terang seragam (rata-rata 128).

**Sebab.** Pencacah desimasi berjalan ~3 PCLK melewati akhir baris, sehingga
penulisan ke-160 terjadi setelah HREF turun, saat register geser data sudah
berhenti di byte terakhir baris, yaitu fase kroma.

**Perbaikan.** Untuk penulisan itu saja, ambil byte satu langkah sebelumnya.
Menggeser fase pencacah juga dicoba dan dibatalkan: itu memindahkan seluruh
cuplikan ke kroma. Menghapus penulisannya juga bukan pilihan, karena
`preview_buffer` mengemas berdasarkan jumlah penulisan dan tiap baris harus
menghasilkan tepat 160.

## 6. Dua cacat lain di penangkap asal

Tercatat di kepala `ov7670_capture.vhd`: alamat tulis yang berjalan bebas
sepanjang frame tanpa jangkar per baris (satu baris pendek menggeser semua
baris sesudahnya), dan alamat tanpa batas atas (sensor mengeluarkan lebih
banyak baris aktif daripada yang disimpan).

## Di sisi firmware dan host

- **Kepala datagram harus kelipatan 4 byte.** Lihat
  [03-protokol-udp.md](03-protokol-udp.md); kepala 6 byte menjatuhkan
  firmware dengan data abort.
- **Satu bidang per putaran loop utama.** Mengirim beberapa bidang beruntun
  melipatgandakan ledakan datagram, dan antrean TX EmacPs tidak gagal dengan
  rapi saat kelebihan.
- **Syarat tunggu adalah "kedua kamera siap", bukan "semua buffer siap".**
  Menunggu ketiganya pernah membuat papan yang sehat tampak tidak mengirim
  apa pun.
- **Bind ke alamat antarmuka, bukan `0.0.0.0`.**

## Yang belum diselesaikan

- Pembacaan SCCB pertama setelah jeda kadang mengembalikan 0x00.
- Sekali terlihat satu baris piksel hilang (garis gelap mendatar) di frame
  kamera 1; belum ditelusuri dan belum terlihat lagi sejak perbaikan nomor 2.
- Tidak ada batasan `set_input_delay` untuk pin kamera; ketahanannya
  sekarang bertumpu pada register IOB dan tepi cuplik, bukan pada analisis
  timing masukan.
