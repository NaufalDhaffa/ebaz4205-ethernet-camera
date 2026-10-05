# Resume an interrupted stereo_cam build.
#
# build_bd.tcl starts with `create_project -force`, so re-running it throws
# away whatever synthesis or implementation had already finished. This script
# opens the project that build_bd.tcl left behind and carries on from the
# first step that is not already at 100%, which matters because a full build
# is long enough to outlive a shell session.
#
#   vivado -mode batch -source hw/scripts/finish_build.tcl
#
# Safe to run repeatedly: every step is guarded by its own PROGRESS check, so
# a completed step is skipped rather than redone.

set proj_dir [file normalize [file join [file dirname [info script]] .. build]]
set xpr      [file join $proj_dir stereo_cam_hw.xpr]

if {![file exists $xpr]} {
  error "no project at $xpr -- run hw/scripts/build_bd.tcl first"
}
open_project $xpr

set jobs [expr {[exec nproc] < 4 ? [exec nproc] : 4}]

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  puts "RESUME: synthesis not complete, restarting it"
  reset_run synth_1
  launch_runs synth_1 -jobs $jobs
  wait_on_run synth_1
  if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "synth_1 did not complete successfully"
  }
} else {
  puts "RESUME: synthesis already done, skipping"
}

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  puts "RESUME: implementation not complete, (re)starting it"
  reset_run impl_1
  launch_runs impl_1 -to_step write_bitstream -jobs $jobs
  wait_on_run impl_1
  if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "impl_1 did not complete successfully"
  }
} else {
  puts "RESUME: implementation already done, skipping"
}

open_run impl_1

# Timing and pin sanity, printed so an interrupted build still leaves a record.
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "TIMING: WNS = $wns ns, WHS = $whs ns"
foreach p {cam_pclk cam_xclk cam2_pclk} {
  if {[llength [get_ports -quiet $p]]} {
    puts "PIN: $p -> [get_property PACKAGE_PIN [get_ports $p]]"
  }
}

write_hw_platform -fixed -include_bit -force [file join $proj_dir stereo_cam.xsa]
puts "BUILD_OK: bitstream + xsa written to $proj_dir"
