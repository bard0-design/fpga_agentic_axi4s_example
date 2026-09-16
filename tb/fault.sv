// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Leonardo Capossio, bard0 design
// https://www.bard0.com  hello@bard0.com

// fault: an optional layer between the converter and the rest of the
// testbench, used only by scripts/acceptance.py.
//
// With FAULT = 0 it is a wire. With any other value it injures the converter's
// interface in one specific, named way. That lets the acceptance suite prove
// the testbench catches a class of bug without shipping a reference solution
// and without knowing anything about how the converter is written: the injury
// is applied to whatever implementation is in rtl/.
//
// Faults 1 to 8 must make the run fail. Faults 9 and 10 are legal behaviours a
// correct converter is allowed to have, and must still pass; they are here so
// that a bench which over-constrains the design is caught too.
//
//   0  none, a straight wire
//   1  stop transferring after 100 output words
//   2  tie input data bit 5 low on every lane of the output word
//   3  raise m_tvalid only when m_tready is already high
//   4  drive s_tready high during reset
//   5  m_tkeep always FFFF
//   6  drop m_tvalid for one cycle while a word is stalled
//   7  change m_tdata while a word is stalled
//   8  carry only bytes 2 and 0 of each lane, regenerate 3 and 1
//   9  legal: one idle cycle between output transfers
//  10  legal: announce each word LATENCY cycles after it is ready
//
// Not to be edited by the agent.

`timescale 1ns/1ps

module fault #(
    parameter int STOP_AT = 100,
    parameter int LATENCY = 8
) (
    // Which fault to inject. Driven from the +FAULT plusarg by tb_top, so the
    // suite selects a fault per run without recompiling.
    input  int unsigned  fault_sel,

    input  logic         clk,
    input  logic         rst_n,

    // from the converter
    input  logic         d_s_tready,
    input  logic [127:0] d_m_tdata,
    input  logic [15:0]  d_m_tkeep,
    input  logic         d_m_tvalid,
    input  logic         d_m_tlast,
    output logic         d_m_tready,

    // to the rest of the testbench
    output logic         s_tready,
    output logic [127:0] m_tdata,
    output logic [15:0]  m_tkeep,
    output logic         m_tvalid,
    output logic         m_tlast,
    input  logic         m_tready
);

    // ------------------------------------------------------------------
    // State the individual faults need
    // ------------------------------------------------------------------
    int unsigned xfers  = 0;    // output words transferred so far
    logic        gate   = 1'b0; // fault 9: this cycle is an inserted bubble
    int unsigned wait_n = 0;    // fault 10: cycles this word has waited
    logic        stall_toggle = 1'b0;

    wire transfer = m_tvalid && m_tready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            xfers        <= 0;
            gate         <= 1'b0;
            wait_n       <= 0;
            stall_toggle <= 1'b0;
        end else begin
            if (transfer) xfers <= xfers + 1;
            // One idle cycle after each transfer, and only one.
            gate <= transfer;
            stall_toggle <= d_m_tvalid && !m_tready;
            // Reset on a transfer as well as on an idle cycle, so every word
            // waits LATENCY cycles, not just the first of a burst.
            if (!d_m_tvalid || transfer)
                wait_n <= 0;
            else if (wait_n < LATENCY)
                wait_n <= wait_n + 1;
        end
    end

    // Lane rebuild used by fault 8: keep bytes 2 and 0, regenerate 3 and 1 as
    // the complement of their neighbour, which is what the payload used to
    // make recoverable.
    function automatic logic [31:0] halved(input logic [31:0] w);
        return {~w[23:16], w[23:16], ~w[7:0], w[7:0]};
    endfunction

    // An explicit sensitivity list rather than always_comb. Icarus cannot
    // narrow a part select when it infers one, so it warns once per process
    // and includes every bit anyway; naming the signals avoids the warning
    // without changing what the process does.
    always @(fault_sel or rst_n or d_s_tready or d_m_tdata or d_m_tkeep or
             d_m_tvalid or d_m_tlast or m_tready or xfers or gate or wait_n or
             stall_toggle) begin
        // Default: a straight wire.
        s_tready   = d_s_tready;
        m_tdata    = d_m_tdata;
        m_tkeep    = d_m_tkeep;
        m_tvalid   = d_m_tvalid;
        m_tlast    = d_m_tlast;
        d_m_tready = m_tready;

        case (fault_sel)
            1: begin
                if (xfers >= STOP_AT) begin
                    m_tvalid   = 1'b0;
                    d_m_tready = 1'b0;
                end
            end
            2: begin
                for (int lane = 0; lane < 4; lane++)
                    m_tdata[32 * lane + 5] = 1'b0;
            end
            3: begin
                m_tvalid   = d_m_tvalid && m_tready;
                d_m_tready = m_tready && d_m_tvalid;
            end
            4: begin
                s_tready = d_s_tready || !rst_n;
            end
            5: begin
                if (d_m_tvalid) m_tkeep = 16'hFFFF;
            end
            6: begin
                if (d_m_tvalid && !m_tready && stall_toggle) begin
                    m_tvalid   = 1'b0;
                    d_m_tready = 1'b0;
                end
            end
            7: begin
                if (d_m_tvalid && !m_tready && stall_toggle)
                    m_tdata[0] = ~d_m_tdata[0];
            end
            8: begin
                for (int lane = 0; lane < 4; lane++)
                    m_tdata[32 * lane +: 32] = halved(d_m_tdata[32 * lane +: 32]);
            end
            9: begin
                if (gate) begin
                    m_tvalid   = 1'b0;
                    d_m_tready = 1'b0;
                end
            end
            10: begin
                if (wait_n < LATENCY) begin
                    m_tvalid   = 1'b0;
                    d_m_tready = 1'b0;
                end
            end
            default: ;
        endcase
    end

endmodule
