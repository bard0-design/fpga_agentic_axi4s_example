// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Leonardo Capossio, bard0 design
// https://www.bard0.com  hello@bard0.com

// axis_checker: compares the converter output against the reference model,
// checks the AXI-Stream handshake rules, and collects functional coverage.
//
// Reports at the end of the run (see report()):
//   WORDS: n            output words transferred
//   PENDING WORDS: n    words the model still owed when the run ended
//   MISMATCHES: n       words that differ from the reference model
//   PROTOCOL ERRORS: n  handshake rule violations
//   COVERAGE: hit/total functional coverage points
//   THROUGHPUT: whether back to back output transfers were seen
//
// Nothing here bounds how many cycles the converter may take to present a
// word. The specification does not constrain latency or throughput, so a
// slow but correct design passes.
//
// PASS needs the model drained: transferring a correct prefix and then
// going quiet is a failure, not a pass.
//
// Coverage is functional only. Back to back output transfers are reported
// separately, because the specification does not constrain throughput and a
// correct converter is allowed to insert a bubble.
//
// Not to be edited by the agent.

`timescale 1ns/1ps

module axis_checker (
    input  logic         clk,
    input  logic         rst_n,

    // input side, observed for coverage only
    input  logic         s_tvalid,
    input  logic         s_tready,
    input  logic         s_tlast,

    // output side, checked
    input  logic [127:0] m_tdata,
    input  logic [15:0]  m_tkeep,
    input  logic         m_tvalid,
    input  logic         m_tready,
    input  logic         m_tlast,

    // reference model
    input  logic         exp_avail,
    input  logic [127:0] exp_data,
    input  logic [15:0]  exp_keep,
    input  logic         exp_last,
    input  int unsigned  exp_pending,
    input  logic         exp_partial,
    input  logic         exp_overflow,
    output logic         pop
);

    int unsigned words      = 0;
    int unsigned mismatches = 0;
    int unsigned proto_errs = 0;

    assign pop = rst_n && m_tvalid && m_tready;

    // ------------------------------------------------------------------
    // Data check
    // ------------------------------------------------------------------
    function automatic int unsigned beats_of(input logic [15:0] keep);
        case (keep)
            16'h000F: return 1;
            16'h00FF: return 2;
            16'h0FFF: return 3;
            16'hFFFF: return 4;
            default:  return 0;
        endcase
    endfunction

    logic [127:0] mask;
    always_comb begin
        for (int b = 0; b < 16; b++)
            mask[8*b +: 8] = {8{exp_keep[b]}};
    end

    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            words <= words + 1;
            if (!exp_avail) begin
                mismatches <= mismatches + 1;
                $display("MISMATCH word %0d at %0d ns: output word transferred but the model expects nothing (keep=%h last=%b)",
                         words, $time, m_tkeep, m_tlast);
            end else if (m_tkeep !== exp_keep || m_tlast !== exp_last ||
                         ((m_tdata ^ exp_data) & mask) !== '0) begin
                mismatches <= mismatches + 1;
                $display("MISMATCH word %0d at %0d ns:", words, $time);
                $display("  got  data=%h keep=%h last=%b", m_tdata, m_tkeep, m_tlast);
                $display("  want data=%h keep=%h last=%b", exp_data, exp_keep, exp_last);
            end
        end
    end

    // ------------------------------------------------------------------
    // Handshake rules (docs/axis_width_conv.md, "Handshake")
    // ------------------------------------------------------------------
    logic         p_valid, p_ready, p_last;
    logic [127:0] p_data;
    logic [15:0]  p_keep;

    // A converter that announces a word only once the sink is already ready
    // never drives m_tvalid high while m_tready is low. Nothing here bounds
    // how long it may take to announce one, because the specification does
    // not: this records what happened and the report reads it, so a run that
    // ends with words owed can say why.
    logic valid_without_ready = 1'b0;

    // Clock edges spent in reset. Reset is synchronous, so on the first edge
    // with rst_n low the converter's outputs still hold their previous values
    // and are cleared by that same edge. Checking them there would fail a
    // correct design, so the check starts on the second edge.
    int unsigned rst_cycles = 0;
    logic        reset_flagged = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            p_valid <= 1'b0;
            rst_cycles <= rst_cycles + 1;
            // Spec, "Reset": during reset m_tvalid and s_tready are 0.
            if (rst_cycles > 0 && (m_tvalid || s_tready) && !reset_flagged) begin
                reset_flagged <= 1'b1;
                proto_errs <= proto_errs + 1;
                $display("PROTOCOL: m_tvalid or s_tready high during reset (m_tvalid=%b s_tready=%b)",
                         m_tvalid, s_tready);
            end
        end else begin
            rst_cycles <= 0;
            if (m_tvalid && !m_tready)
                valid_without_ready <= 1'b1;
            if (p_valid && !p_ready) begin
                if (!m_tvalid) begin
                    proto_errs <= proto_errs + 1;
                    $display("PROTOCOL: m_tvalid dropped while stalled (before word %0d)", words);
                end else if (m_tdata !== p_data || m_tkeep !== p_keep || m_tlast !== p_last) begin
                    proto_errs <= proto_errs + 1;
                    $display("PROTOCOL: m_tdata/m_tkeep/m_tlast changed while stalled (before word %0d)", words);
                end
            end
            if (m_tvalid && beats_of(m_tkeep) == 0) begin
                proto_errs <= proto_errs + 1;
                $display("PROTOCOL: illegal m_tkeep %h", m_tkeep);
            end
            p_valid <= m_tvalid;
            p_ready <= m_tready;
            p_data  <= m_tdata;
            p_keep  <= m_tkeep;
            p_last  <= m_tlast;
        end
    end

    // ------------------------------------------------------------------
    // Functional coverage
    // ------------------------------------------------------------------
    localparam int NPTS = 14;
    // Point 11 measures throughput, which docs/axis_width_conv.md leaves
    // unconstrained, so it is reported but not required. The other thirteen
    // are functional and cov has to hit all of them.
    localparam int PERF  = 11;
    localparam int NFUNC = NPTS - 1;
    logic [NPTS-1:0] cov = '0;

    function automatic string cov_name(input int i);
        case (i)
            0:  return "output word with 1 beat";
            1:  return "output word with 2 beats";
            2:  return "output word with 3 beats";
            3:  return "output word with 4 beats";
            4:  return "stalled while holding a 1 beat word";
            5:  return "stalled while holding a 2 beat word";
            6:  return "stalled while holding a 3 beat word";
            7:  return "stalled while holding a 4 beat word";
            8:  return "tlast on a full word";
            9:  return "packet ending on one valid lane";
            10: return "stalled 3 or more cycles in a row";
            11: return "output transfers on consecutive cycles  (throughput, not required)";
            12: return "input gap inside a packet";
            13: return "input beat held while s_tready low";
            default: return "?";
        endcase
    endfunction

    int unsigned stall_run = 0;
    logic        p_xfer    = 1'b0;
    logic        in_packet = 1'b0;
    int unsigned n;
    int unsigned out_stalls = 0;   // cycles with m_tvalid high and m_tready low
    int unsigned in_stalls  = 0;   // cycles with s_tvalid high and s_tready low

    always @(posedge clk) begin
        if (rst_n) begin
            n = beats_of(m_tkeep);
            if (m_tvalid && !m_tready) out_stalls <= out_stalls + 1;
            if (s_tvalid && !s_tready) in_stalls  <= in_stalls + 1;
            if (m_tvalid && m_tready) begin
                if (n >= 1 && n <= 4) cov[n-1] <= 1'b1;
                if (m_tlast && n == 4) cov[8] <= 1'b1;
                if (m_tlast && n == 1) cov[9] <= 1'b1;
                if (p_xfer) cov[11] <= 1'b1;
            end
            if (m_tvalid && !m_tready) begin
                if (n >= 1 && n <= 4) cov[4+n-1] <= 1'b1;
                stall_run <= stall_run + 1;
                if (stall_run >= 2) cov[10] <= 1'b1;
            end else begin
                stall_run <= 0;
            end
            p_xfer <= m_tvalid && m_tready;

            if (s_tvalid && s_tready)
                in_packet <= !s_tlast;
            else if (in_packet && !s_tvalid)
                cov[12] <= 1'b1;
            if (s_tvalid && !s_tready)
                cov[13] <= 1'b1;
        end
    end

    function automatic int unsigned cov_hits();
        int unsigned h = 0;
        for (int i = 0; i < NPTS; i++) if (i != PERF && cov[i]) h++;
        return h;
    endfunction

    // ------------------------------------------------------------------
    // Report, called by tb_top at the end of the run
    // ------------------------------------------------------------------
    task report();
        $display("----------------------------------------------------------");
        for (int i = 0; i < NPTS; i++)
            $display("  [%s] %s", cov[i] ? "x" : " ", cov_name(i));
        $display("WORDS: %0d", words);
        $display("PENDING WORDS: %0d", exp_pending);
        if (exp_pending != 0)
            $display("INCOMPLETE: the model still owes %0d word(s); the converter stopped early or dropped them", exp_pending);
        if (exp_pending != 0 && !valid_without_ready)
            $display("INCOMPLETE: m_tvalid never went high while m_tready was low, so the converter appears to wait for m_tready before announcing a word; the specification says it must not");
        if (exp_partial)
            $display("INCOMPLETE: input beats were accepted that never became an output word");
        if (exp_overflow)
            $display("INVALID: the reference queue overflowed, this run proves nothing");
        $display("OUTPUT STALL CYCLES: %0d", out_stalls);
        $display("INPUT STALL CYCLES: %0d", in_stalls);
        $display("MISMATCHES: %0d", mismatches);
        $display("PROTOCOL ERRORS: %0d", proto_errs);
        $display("COVERAGE: %0d/%0d", cov_hits(), NFUNC);
        if (cov[PERF])
            $display("THROUGHPUT: back to back output transfers seen (not required)");
        else
            $display("THROUGHPUT: back to back output transfers not seen (not required)");
    endtask

    function automatic bit passed();
        return words > 0 && mismatches == 0 && proto_errs == 0
               && exp_pending == 0 && !exp_partial && !exp_overflow;
    endfunction

    function automatic bit covered();
        return cov_hits() == NFUNC;
    endfunction

endmodule
