# Perangkat keras

## Papan

EBAZ4205, papan kendali bekas penambang: Zynq **XC7Z010-1CLG400** (dua
Cortex-A9 + ~28 ribu sel logika), DDR3 256 MB, PHY Ethernet IP101GA 100 Mbps.

| Periferal PS | Sambungan | Catatan |
|---|---|---|
| UART1 | MIO 24 (TX) / 25 (RX) | konsol firmware |
| ENET0 | EMIO, MII, MDIO juga EMIO | 100 Mbps |
| DDR3 | pin khusus PS | `MT41K128M16 JT-125`, 16 bit |
| FCLK0 | 40 MHz | clock seluruh logika PL |

Ethernet lewat EMIO, jadi pin PHY-nya adalah pin PL dan harus ada di
`hw/constraints/ethernet.xdc`:

| Sinyal | Pin | Sinyal | Pin |
|---|---|---|---|
| `eth_rx_clk` | U14 | `eth_tx_clk` | U15 |
| `eth_rxd[0..3]` | Y16 V16 V17 Y17 | `eth_txd[0..3]` | W18 Y18 V18 Y19 |
| `eth_rx_dv` | W16 | `eth_tx_en` | W19 |
| `eth_mdio_mdc` | W15 | `eth_mdio_mdio_io` | Y14 |
| `led[0]`, `led[1]` | W13, W14 | | |

## Kamera

Dua modul OV7670 (tanpa FIFO), catu 3,3 V, tersambung ke header DATA1/DATA2
(kamera 1) dan DATA3/DATA2 (kamera 2). Semua pin LVCMOS33.

| Sinyal | Kamera 1 | Kamera 2 |
|---|---|---|
| XCLK (FPGA -> sensor) | **J19, satu pin untuk keduanya** | |
| PCLK | **K18** | **L16** |
| VSYNC | B20 | M17 |
| HREF | C20 | N17 |
| D7 | D20 | R18 |
| D6 | D18 | R19 |
| D5 | H18 | P19 |
| D4 | D19 | T20 |
| D3 | F20 | U20 |
| D2 | E19 | T19 |
| D1 | F19 | V20 |
| D0 | K17 | U19 |
| SIOC | A20 | M19 |
| SIOD | B19 | P18 |
| RESET# | G20 | G19 |
| PWDN | J18 | H20 |

Yang perlu diperhatikan saat mengawati:

- **PCLK harus di pin berkemampuan clock.** K18 adalah MRCC dan L16 SRCC.
  Keduanya tetap butuh `CLOCK_DEDICATED_ROUTE FALSE` di `camera.xdc`.
- **XCLK dan PCLK jangan bersebelahan.** Susunan awal menaruh keduanya di
  satu pasangan diferensial (H16/H17), kopling terkuat yang mungkin antara
  keluaran yang berayun keras dan masukan clock. Sekarang ketiganya di tiga
  pasangan berbeda.
- **Kabel clock sependek mungkin.** Pada rangkaian ini kabel XCLK dan PCLK di
  bawah 5 cm.
- **SCCB butuh pull-up.** SIOC dan SIOD kedua kamera ditarik ke 3,3 V dengan
  10 kOhm eksternal; SIOD juga punya pull-up internal di `camera.xdc`.
- **Hanya 4 bit teratas data (D7..D4) yang dipakai** oleh penangkap; D3..D0
  tetap tersambung tetapi dibuang saat sintesis.

## Yang dibutuhkan di meja

- Probe JTAG (di sini kabel Digilent berbasis FT232H) ke pad JTAG papan.
- Kabel Ethernet langsung ke PC, tanpa switch atau DHCP.
- Catu daya papan.

Urutan orientasi kamera memengaruhi tampilan saja: penampil memutar gambar
90 derajat secara bawaan agar tegak pada susunan modul yang sekarang.
