// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Leonardo Capossio, bard0 design
// https://www.bard0.com  hello@bard0.com

// axis_width_conv: AXI-Stream data width converter, 32 bit in to 128 bit out.
//
// Specification: docs/axis_width_conv.md
//
// The port list is fixed. The body is yours (or your agent's) to write.

`timescale 1ns/1ps

module axis_width_conv (
    input  logic         clk,
    input  logic         rst_n,

    input  logic [31:0]  s_tdata,
    input  logic         s_tvalid,
    output logic         s_tready,
    input  logic         s_tlast,

    output logic [127:0] m_tdata,
    output logic [15:0]  m_tkeep,
    output logic         m_tvalid,
    input  logic         m_tready,
    output logic         m_tlast
);

    // TODO: implement. Until then the block accepts nothing and emits nothing.
    assign s_tready = 1'b0;
    assign m_tdata  = '0;
    assign m_tkeep  = '0;
    assign m_tvalid = 1'b0;
    assign m_tlast  = 1'b0;

endmodule
