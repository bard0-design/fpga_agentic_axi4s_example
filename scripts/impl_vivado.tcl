# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Leonardo Capossio, bard0 design
# https://www.bard0.com  hello@bard0.com

# Vivado batch flow for axis_width_conv: synthesis, implementation, timing.
#
#   vivado -mode batch -source scripts/impl.tcl -tclargs sv     (or vhdl)
#
# Runs out of context so no pins are needed. Prints LATCHES, WNS, WHS and
# TIMING MET or TIMING FAILED, and exits non zero on failure. A latch is a
# failure, not a note: the design is meant to be fully synchronous, so the run
# stops before implementation rather than reporting timing on a netlist that
# should not exist. Reports land in build/.

set hdl  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "sv"}]
set part "xc7a35tcpg236-1"
set top  "axis_width_conv"

file mkdir build

if {$hdl eq "vhdl"} {
    read_vhdl -vhdl2008 rtl/axis_width_conv.vhd
} else {
    read_verilog -sv rtl/axis_width_conv.sv
}
read_xdc constraints/axis_width_conv.xdc

synth_design -top $top -part $part -mode out_of_context
report_utilization -file build/utilization.rpt

set latches [llength [get_cells -hier -quiet -filter {PRIMITIVE_SUBGROUP == LATCH || PRIMITIVE_SUBGROUP == latch}]]
puts "LATCHES: $latches"

if {$latches > 0} {
    puts "LATCHES FOUND"
    exit 1
}

opt_design
place_design
route_design

report_timing_summary -file build/timing_summary.rpt
report_timing -max_paths 5 -file build/timing_worst.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts [format "WNS: %.3f ns" $wns]
puts [format "WHS: %.3f ns" $whs]

if {$wns >= 0 && $whs >= 0} {
    puts "TIMING MET"
} else {
    puts "TIMING FAILED"
    exit 1
}
