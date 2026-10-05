# Full camera pin constraints for the stereo_cam build (hw/scripts/build_bd.tcl).
# Pin table derived by the board owner (physical measurement), same as
# hw/constraints/i2c_probe.xdc's subset but with the full 16 signals/camera
# needed for actual image capture (PCLK/VSYNC/HREF/D[7:0] added on top of
# the SCCB-only pins used by the standalone probe). See docs/BOARD_CONFIG.md
# for the full table (cam1 = DATA1/DATA2, Bank 35; cam2 = DATA3/DATA2, Bank 34).
#
# Clock pins moved off DATA1 onto DATA2 (both still Bank 35):
#   cam_pclk  H16 -> K18  (DATA2 pin 11, IO_L12N_T1_MRCC_35 -- clock-capable)
#   cam2_pclk N20 -> L16  (DATA2 pin 15, IO_L11P_T1_SRCC_35 -- clock-capable)
#   cam_xclk  H17 -> J19  (DATA2 pin 9,  IO_L10N_T1_AD11N_35 -- plain I/O)
# Both PCLKs now live in bank 35 on the DATA2 header alongside the shared
# XCLK; N20 (bank 34) is free.
# J19 is not clock-capable, which is fine: xclk is a toggling register output
# (ov7670_controller.vhd), not a forwarded clock net. H16/H17 were the two
# halves of one differential pair (L13P/L13N) -- the tightest possible
# coupling between a hard-switching output and a sensitive clock input;
# K18, L16 and J19 sit in three separate pairs. cam_pclk keeps an MRCC pin
# (K18); cam2_pclk is on an SRCC, which reaches one clock region instead of
# two. The CLOCK_DEDICATED_ROUTE FALSE lines below were already needed when
# both were MRCC/SRCC on the old pins and are still needed here.

## Camera 1 (DATA1 header, + DATA2 for reset/pwdn)
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33} [get_ports {cam_sioc}]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports {cam_pclk}]
set_property -dict {PACKAGE_PIN B19 IOSTANDARD LVCMOS33} [get_ports {cam_siod}]
set_property PULLUP TRUE [get_ports {cam_siod}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33} [get_ports {cam_vsync}]
set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS33} [get_ports {cam_href}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33} [get_ports {cam_xclk}]
set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} [get_ports {cam_pdata[7]}]
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {cam_pdata[6]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} [get_ports {cam_pdata[5]}]
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports {cam_pdata[4]}]
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} [get_ports {cam_pdata[3]}]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports {cam_pdata[2]}]
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports {cam_pdata[1]}]
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports {cam_pdata[0]}]
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} [get_ports {cam_reset_n}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {cam_pwdn}]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports cam_pclk]]

## Camera 2 (DATA3 header, + DATA2 for reset/pwdn)
set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} [get_ports {cam2_sioc}]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33} [get_ports {cam2_pclk}]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports {cam2_siod}]
set_property PULLUP TRUE [get_ports {cam2_siod}]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports {cam2_vsync}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {cam2_href}]
# cam2_xclk removed: both cameras now share cam_xclk (J19). One divider feeds
# both, so the two sensors run off the same reference; their PCLKs still
# free-run independently, so camera_timing.xdc's asynchronous clock groups
# below stay as they are. P20 is now free.
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {cam2_pdata[7]}]
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports {cam2_pdata[6]}]
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports {cam2_pdata[5]}]
set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} [get_ports {cam2_pdata[4]}]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} [get_ports {cam2_pdata[3]}]
set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} [get_ports {cam2_pdata[2]}]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports {cam2_pdata[1]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {cam2_pdata[0]}]
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} [get_ports {cam2_reset_n}]
set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} [get_ports {cam2_pwdn}]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports cam2_pclk]]

# PCLK is supplied BY the camera, so it's a genuine primary clock that the
# tool otherwise knows nothing about -- without these, the whole capture
# path (ov7670_capture, the frame buffers' write ports, cam_activity) sits
# in an unconstrained domain and is never timing-checked at all.
# Period: the register table leaves CLKRC at no prescale, so PCLK tracks
# XCLK, which stereo_depth_top derives as clk50/2 = 20MHz. Declared a
# little fast (40ns = 25MHz) to keep some margin over that.
create_clock -name cam_pclk  -period 40.0 [get_ports cam_pclk]
create_clock -name cam2_pclk -period 40.0 [get_ports cam2_pclk]

# The asynchronous clock-group declaration lives in camera_timing.xdc, which
# is marked implementation-only. It cannot live here: it has to name
# clk_fpga_0, which the PS7 IP creates in its own generated .xdc and which is
# therefore not in scope while this file is read during synthesis. Naming it
# here produced "No valid object(s) found" and silently dropped the whole
# constraint, and guarding that with a Tcl `if` is not allowed either
# ("Command 'if' is not supported in the xdc constraint file").
