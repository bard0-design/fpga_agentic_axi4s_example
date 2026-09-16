// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Leonardo Capossio, bard0 design
// https://www.bard0.com  hello@bard0.com

// tb_top: clock, reset, and the wiring between stimulus, DUT, reference
// model and checker. Prints RESULT: PASS or RESULT: FAIL at the end.
//
// Plusargs: +DUMP dumps waves to build/tb_top.vcd. See stimulus.sv for the
// stimulus options.

`timescale 1ns/1ps

module tb_top;

    // Cycles to wait for the model to hold a partial word before giving up
    // on the mid run reset.
    localparam int RESET_WAIT = 5000;

    localparam int TIMEOUT_CYCLES = 200_000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #5 clk = ~clk;

    logic [31:0]  s_tdata;
    logic         s_tvalid, s_tready, s_tlast;
    logic [127:0] m_tdata;
    logic [15:0]  m_tkeep;
    logic         m_tvalid, m_tready, m_tlast;
    logic         done;

    logic         exp_avail, exp_last, pop;
    logic [127:0] exp_data;
    logic [15:0]  exp_keep;
    int unsigned  exp_pending;
    logic         exp_partial, exp_overflow;

    stimulus u_stim (
        .clk, .rst_n,
        .s_tdata, .s_tvalid, .s_tready, .s_tlast,
        .m_tready, .m_tvalid,
        .done
    );

    // The converter's own interface, before the fault layer. With no +FAULT
    // plusarg the layer is a wire and these are the public signals.
    logic         d_s_tready, d_m_tvalid, d_m_tlast, d_m_tready;
    logic [127:0] d_m_tdata;
    logic [15:0]  d_m_tkeep;

    int unsigned waited = 0;   // cycles spent waiting for the mid run reset

    int unsigned fault_sel = 0;
    int          fault_seen;
    initial fault_seen = $value$plusargs("FAULT=%d", fault_sel);

    axis_width_conv dut (
        .clk, .rst_n,
        .s_tdata, .s_tvalid, .s_tlast,
        .s_tready (d_s_tready),
        .m_tdata  (d_m_tdata),
        .m_tkeep  (d_m_tkeep),
        .m_tvalid (d_m_tvalid),
        .m_tready (d_m_tready),
        .m_tlast  (d_m_tlast)
    );

    fault u_fault (
        .fault_sel, .clk, .rst_n,
        .d_s_tready, .d_m_tdata, .d_m_tkeep, .d_m_tvalid, .d_m_tlast, .d_m_tready,
        .s_tready, .m_tdata, .m_tkeep, .m_tvalid, .m_tlast, .m_tready
    );

    ref_model u_model (
        .clk, .rst_n,
        .s_tdata, .s_tvalid, .s_tready, .s_tlast,
        .pop, .exp_avail, .exp_data, .exp_keep, .exp_last,
        .exp_pending, .exp_partial, .exp_overflow
    );

    axis_checker u_chk (
        .clk, .rst_n,
        .s_tvalid, .s_tready, .s_tlast,
        .m_tdata, .m_tkeep, .m_tvalid, .m_tready, .m_tlast,
        .exp_avail, .exp_data, .exp_keep, .exp_last,
        .exp_pending, .exp_partial, .exp_overflow, .pop
    );

    initial begin
        if ($test$plusargs("DUMP")) begin
            $dumpfile("build/tb_top.vcd");
            $dumpvars(0, tb_top);
        end
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;

        // Mid run reset. The specification says beats received before reset
        // are discarded, so the reset is timed to land while the reference
        // model is holding a partially packed word: a converter that keeps
        // that word across reset emits it afterwards and mismatches. The
        // stimulus restarts its packet sequence, and both the model and the
        // converter start again from empty.
        if (!$test$plusargs("NORESET")) begin
            repeat (100) @(posedge clk);
            // Bounded: a converter that never accepts a beat never gives the
            // model a partial word to hold, and the run has to reach its own
            // timeout rather than wait here forever.
            while (!exp_partial && waited < RESET_WAIT) begin
                waited++;
                @(posedge clk);
            end
            if (exp_partial) begin
                $display("MID RUN RESET: asserted while the model held a partial word");
                rst_n <= 1'b0;
                repeat (3) @(posedge clk);
                rst_n <= 1'b1;
            end else begin
                $display("MID RUN RESET: skipped, the model never held a partial word");
            end
        end
    end

    // Token for this run. run.py picks a fresh number every time and refuses
    // a report that does not carry it back, so a canned report printed from
    // somewhere else in the simulation is not a pass.
    int unsigned nonce = 0;
    int          nonce_seen;
    initial nonce_seen = $value$plusargs("NONCE=%d", nonce);

    int unsigned cycles = 0;

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (done || cycles == TIMEOUT_CYCLES) begin
            if (cycles == TIMEOUT_CYCLES)
                $display("TIMEOUT after %0d cycles", cycles);
            $display("RUN: %0d", nonce);
            u_chk.report();
            if (done && u_chk.passed()) begin
                $display("RESULT: PASS");
                $finish;
            end else begin
                // $fatal, not $finish: the simulator exits non-zero, so a
                // failing run cannot be hidden behind a printed string.
                $display("RESULT: FAIL");
                $fatal(1, "axis_width_conv: checks failed");
            end
        end
    end

endmodule
