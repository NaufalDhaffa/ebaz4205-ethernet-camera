# Protokol UDP

Papan `192.168.2.10`, PC `192.168.2.1`. Semua bilangan little-endian.

## Frame: papan -> PC, port 5001

Tiap datagram = kepala 8 byte + sampai 1400 byte piksel.

| Offset | Tipe | Isi |
|---|---|---|
| 0 | u16 | `frame_id`, naik satu per set frame |
| 2 | u16 | `chunk_index`: offset piksel pertama datagram ini di dalam bidang |
| 4 | u8 | `plane`: 0 = depth, 1 = kamera 1, 2 = kamera 2 |
| 5 | u8 | cadangan |
| 6 | u16 | cadangan |

Di Python: `struct.Struct("<HHBBH")`.

- Satu bidang = 160 x 120 = 19 200 byte, urutan baris demi baris, jadi
  14 datagram per bidang.
- Piksel kamera = nibble luma x 17, sehingga 16 aras tersebar di 0..255.
- Bidang depth (0) berisi disparitas mentah 0..40 dan dikirim lebih dulu;
  penampil kamera mengabaikannya.
- Semua bidang dalam satu set memakai `frame_id` yang sama. **Pasangan
  cam1/cam2 hanya sah bila keduanya lengkap dengan `frame_id` sama.**
- Tidak ada pengiriman ulang. Datagram hilang berarti frame itu tidak
  lengkap dan dibuang penerima.

Kepala sengaja tepat 8 byte. Payload disalin langsung dari jendela AXI yang
dipetakan *strongly ordered*; kepala yang bukan kelipatan 4 membuat `memcpy`
melakukan akses tak-sejajar ke jendela itu dan firmware berhenti dengan data
abort. Itu pernah terjadi dengan kepala 6 byte.

Papan mengirim ke alamat tujuan tetap; penerima harus **bind ke
`192.168.2.1`**, bukan `0.0.0.0`. Pada tautan langsung ini bind wildcard tidak
menerima apa pun dan tidak memberi galat.

## Kendali: PC <-> papan, port 5002

Permintaan dan jawaban sama-sama 8 byte (`struct.Struct("<BBBBBBH")`).

Permintaan: `'D'`, `'C'`, `cmd`, `cam`, `arg0`, `arg1`, `seq` (u16).
Jawaban: `'D'`, `'C'`, `cmd`, `status`, `value`, cadangan, `seq` (u16).

`cam`: 0 = kamera 1, 1 = kamera 2. `seq` dikembalikan apa adanya supaya
jawaban bisa dipasangkan dengan permintaannya.

| `cmd` | Nama | Argumen | Jawaban |
|---|---|---|---|
| 0x00 | PING | – | status |
| 0x01 | SCCB_WRITE | `cam`, `arg0` = register, `arg1` = nilai | status |
| 0x02 | SCCB_READ | `cam`, `arg0` = register | `value` |
| 0x03 | SET_RECT | rektifikasi mesin depth | status |
| 0x04 | RESEND | – (kirim ulang tabel register) | status |
| 0x05 | GET_STATUS | – | `value` = bit status |
| 0x06 | SET_PLANES | `arg0` = topeng preview | `value` |
| 0x07 | SET_LUMA | `arg0` = fase luma 0/1 | `value` |

`status`: 0 = ok, 1 = magic salah, 2 = perintah tidak dikenal, 3 = sensor
tidak memberi ACK di SCCB.

Contoh, membaca ID produk kamera 1 (register 0x0A, harus 0x76):

```python
import socket, struct
REQ = RSP = struct.Struct("<BBBBBBH")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1)
s.sendto(REQ.pack(ord("D"), ord("C"), 0x02, 0, 0x0A, 0, 1), ("192.168.2.10", 5002))
print(hex(RSP.unpack(s.recvfrom(64)[0])[4]))
```

Satu keanehan yang belum ditelusuri: pembacaan SCCB pertama setelah jeda
(sesaat setelah RESEND, setelah firmware baru mulai, atau pada koneksi baru)
kadang mengembalikan 0x00, lalu 0x76 pada pembacaan berikutnya. Baca dua
kali sebelum menyimpulkan sensor tidak menjawab.
