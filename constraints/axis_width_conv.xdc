# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Leonardo Capossio, bard0 design
# https://www.bard0.com  hello@bard0.com

# Project clock for axis_width_conv. Out of context, so no pin constraints.
#
# Not to be edited by the agent. A constraint change is something it proposes.

create_clock -period 10.000 -name clk [get_ports clk]

# Out of context, the clock port is not driven by anything, so Vivado has
# no clock tree to analyse and reports skew and insertion delay as zero.
# Naming the global buffer the clock would come from lets it estimate both,
# which makes the slack figure mean a little more than it otherwise would.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]
