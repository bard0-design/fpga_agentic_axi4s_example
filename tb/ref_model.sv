// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Leonardo Capossio, bard0 design
// https://www.bard0.com  hello@bard0.com

// ref_model: behavioural model of axis_width_conv, written from the spec.
//
// It watches the input side handshake, packs beats exactly as
// docs/axis_width_conv.md describes, and queues the expected output words.
// The checker pops one expected word per output transfer.
//
// exp_* are valid in the cycle before the clock edge on which the checker
// compares them. A word that completes on the same edge as it is transferred
// (a zero latency converter) is presented combinationally, so that case also
// checks correctly.
//
// Not to be edited by the agent.

`timescale 1ns/1ps

module ref_model (
    input  logic         clk,
    input  logic         rst_n,

    input  logic [31:0]  s_tdata,
    input  logic         s_tvalid,
    input  logic         s_tready,
    input  logic         s_tlast,

    input  logic         pop,
    output logic         exp_avail,
    output logic [127:0] exp_data,
    output logic [15:0]  exp_keep,
    output logic         exp_last,

    // End of run completeness, read by the checker. A design that accepts
    // every input beat but stops emitting leaves words queued here.
    output int unsigned  exp_pending,
    output logic         exp_partial,
    output logic         exp_overflow
);

    localparam int DEPTH = 4096;

    logic [127:0] q_data [DEPTH];
    logic [15:0]  q_keep [DEPTH];
    logic         q_last [DEPTH];
    int unsigned  wr, rd;

    // partially packed word
    logic [127:0] acc;
    int unsigned  fill;

    // word that would complete on this edge, if any
    logic         accept, complete;
    logic [127:0] cand_data;
    logic [15:0]  cand_keep;

    assign accept   = s_tvalid && s_tready;
    assign complete = accept && (fill == 3 || s_tlast);

    always_comb begin
        cand_data = acc;
        cand_data[32*fill +: 32] = s_tdata;
        cand_keep = 16'hFFFF >> (16 - 4 * (fill + 1));
    end

    // Words the specification says are due but the converter has not
    // transferred yet, the partially packed word it still owes, and the
    // queue overflow that would make the oracle lie.
    assign exp_pending  = wr - rd;
    assign exp_partial  = (fill != 0);

    // Reported outside the always_ff so the model still reads as synthesisable
    // code to a linter, which keeps the tool output about the design.
    logic ovf_q = 1'b0;
    always @(posedge clk) begin
        ovf_q <= exp_overflow;
        if (exp_overflow && !ovf_q)
            $display("MODEL: reference queue overflow at %0d words, raise DEPTH in tb/ref_model.sv", DEPTH);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr   <= 0;
            rd   <= 0;
            acc  <= '0;
            fill <= 0;
            exp_overflow <= 1'b0;
        end else begin
            if (accept && complete && (wr - rd) >= DEPTH)
                exp_overflow <= 1'b1;
            if (pop)
                rd <= rd + 1;
            if (accept) begin
                if (complete) begin
                    q_data[wr % DEPTH] <= cand_data;
                    q_keep[wr % DEPTH] <= cand_keep;
                    q_last[wr % DEPTH] <= s_tlast;
                    wr   <= wr + 1;
                    acc  <= '0;
                    fill <= 0;
                end else begin
                    acc  <= cand_data;
                    fill <= fill + 1;
                end
            end
        end
    end

    always_comb begin
        if (wr != rd) begin
            exp_avail = 1'b1;
            exp_data  = q_data[rd % DEPTH];
            exp_keep  = q_keep[rd % DEPTH];
            exp_last  = q_last[rd % DEPTH];
        end else begin
            exp_avail = complete;
            exp_data  = cand_data;
            exp_keep  = cand_keep;
            exp_last  = s_tlast;
        end
    end

endmodule
