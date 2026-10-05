# Build dan deploy

Diuji dengan **Vivado/Vitis 2025.2** di Linux, probe JTAG Digilent.

## 1. Bitstream (~6 menit)

```bash
vivado -mode batch -source hw/scripts/build_bd.tcl
```

Skrip ini membuat proyek di `hw/build/`, menyusun block design (PS7, AXI GPIO,
AXI BRAM controller, modul kamera, tiga inti ILA), menjalankan sintesis dan
implementasi, lalu menulis `hw/build/stereo_cam.xsa`.

`build_bd.tcl` memakai `create_project -force`, jadi menjalankannya ulang
membuang hasil sebelumnya. Kalau build terputus di tengah, lanjutkan dengan:

```bash
vivado -mode batch -source hw/scripts/finish_build.tcl
```

## 2. BSP dan firmware

```bash
source ~/Xilinx/2025.2/Vitis/settings64.sh
sdtgen -xsa hw/build/stereo_cam.xsa -dir sw/dts
empyro create_bsp -w sw/workspace -s sw/dts/system-top.dts -p ps7_cortexa9_0
empyro config_bsp -d sw/workspace -al lwip220
empyro config_bsp -d sw/workspace -st lwip220 "lwip220_temac_phy_link_speed:CONFIG_LINKSPEED100"
empyro config_bsp -d sw/workspace -st lwip220 "lwip220_dhcp:false"
empyro config_bsp -d sw/workspace -st lwip220 "lwip220_lwip_dhcp_does_acd_check:false"
empyro create_app -w sw/workspace -n depth_stream_app -d sw/workspace -t lwip_echo_server
cp sw/apps/depth_stream/src/*.c sw/apps/depth_stream/src/*.h sw/workspace/src/
empyro build_app -w sw/workspace
```

Tiga setelan lwIP itu wajib untuk papan ini:

- **Kecepatan tautan dipaksa 100 Mbps.** Dengan deteksi otomatis, PHY papan
  ini turun ke 10 Mbps.
- **DHCP dan pemeriksaan ACD dimatikan bersama.** Tautannya langsung tanpa
  server DHCP, dan jalur "jatuh ke IP statis" pada templat tidak pernah
  terpicu. lwIP menolak dikompilasi bila ACD menyala sementara DHCP mati.

Alamat IP papan ditetapkan di `main.c` (`IP4_ADDR`), bukan di BSP.

Setelah mengubah sumber firmware, cukup salin ulang ke `sw/workspace/src/`
dan jalankan `empyro build_app` lagi.

Kalau `empyro create_bsp` gagal dengan jalur ke versi Vitis lain, berkas
`.repo.yaml` di direktori kerja menunjuk ke instalasi lama. Perbaiki dengan:

```bash
empyro repo -st ~/Xilinx/2025.2/Vitis/data/embeddedsw
```

## 3. Unggah lewat JTAG

`hw_server` harus sudah berjalan **di terminalnya sendiri**; bila dijalankan
di latar belakang dari skrip, pada rangkaian ini ia berulang kali mati
beberapa detik setelah mulai.

```bash
source ~/Xilinx/2025.2/Vivado/settings64.sh && hw_server
```

Lalu di terminal lain:

```bash
bash hw/scripts/deploy.sh
```

Skrip itu menghentikan inti, memprogram PL, lalu pada sesi `xsdb` terpisah
menjalankan `ps7_init` dan memuat firmware. Dua hal di dalamnya disengaja:

- **Inti dihentikan sebelum PL diprogram.** Firmware yang masih berjalan dan
  mengakses periferal AXI saat PL dicabut meninggalkan interkoneksi
  tergantung; gejalanya "DAP (APB AP transaction error)" dan hanya pulih
  dengan mematikan daya papan.
- **Pemrograman PL dan `ps7_init` di sesi terpisah.** Menggabungkannya pernah
  membuat Ethernet tidak hidup.

Hindari juga membaca memori AXI lewat `mrd` saat firmware berjalan; itu
pernah menggantung DAP dengan cara yang sama.

## 4. Jaringan PC

Antarmuka kabel PC diberi alamat statis `192.168.2.1/24`. Periksa:

```bash
ping -c 3 192.168.2.10
```

Lalu jalankan penampil, lihat [05-alat-python.md](05-alat-python.md).

## Debug dengan ILA

Bitstream memuat tiga inti `system_ila`: `ila_pix` dan `ila_pix2` di ranah
PCLK tiap kamera (VSYNC, HREF, data, sinyal tulis), dan `ila_ctl` di ranah
40 MHz (XCLK, SCCB, status konfigurasi kedua kamera). Berkas probe `.ltx`
ada di direktori `impl_1` setelah build dan dibuka dari Hardware Manager
Vivado. Ketiganya memakan sekitar 3 500 LUT dan 6 BRAM; hapus dari
`build_bd.tcl` bila tidak diperlukan.
