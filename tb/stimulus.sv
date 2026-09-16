// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Leonardo Capossio, bard0 design
// https://www.bard0.com  hello@bard0.com

// stimulus: drives packets into the converter and back pressure into its
// output. This is the file the agent may extend with more stimulus.
//
// Plusargs (vvp sim.vvp +NAME=value):
//   +PACKETS=n     random packets after the directed ones   (default 200)
//   +SEED=n        random seed                              (default 1)
//   +VALID_PCT=n   chance per cycle that s_tvalid is high   (default 70)
//   +READY_PCT=n   chance per cycle that m_tready is high   (default 100)
//   +MAXLEN=n      longest random packet, in beats          (default 20)
//
// Out of the box there is no back pressure: m_tready stays high. The coverage
// points that need a stall are not reachable until back pressure is added
// here or READY_PCT is lowered.

`timescale 1ns/1ps

module stimulus (
    input  logic        clk,
    input  logic        rst_n,

    output logic [31:0] s_tdata,
    output logic        s_tvalid,
    input  logic        s_tready,
    output logic        s_tlast,

    output logic        m_tready,
    input  logic        m_tvalid,

    output logic        done
);

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------
    int unsigned packets   = 200;
    int unsigned seed      = 1;
    int unsigned valid_pct = 70;
    int unsigned ready_pct = 100;
    int unsigned maxlen    = 20;
    int          dummy;
    int unsigned seed_copy;
    int unsigned pay_seed;

    // Directed packet lengths, sent first: every remainder mod 4, a single
    // beat, a few longer ones, and one packet long enough for the beat index
    // to run through all 256 values of its byte. Without that packet the top
    // three bits of the beat byte would be zero all run, and a converter that
    // tied them low would compare equal on every word.
    localparam int NDIR = 11;

    function automatic int unsigned dir_len(input int unsigned p);
        case (p)
            0: return 1;
            1: return 2;
            2: return 3;
            3: return 4;
            4: return 5;
            5: return 8;
            6: return 9;
            7: return 7;
            8: return 1;
            9: return 300;
            default: return 4;
        endcase
    endfunction

    initial begin
        dummy = $value$plusargs("PACKETS=%d",   packets);
        dummy = $value$plusargs("SEED=%d",      seed);
        dummy = $value$plusargs("VALID_PCT=%d", valid_pct);
        dummy = $value$plusargs("READY_PCT=%d", ready_pct);
        dummy = $value$plusargs("MAXLEN=%d",    maxlen);
        // $urandom updates the seed it is given, so the payload keeps its own
        // copy: the mix below has to depend on the seed the user asked for,
        // and has to match what the VHDL track computes from the same number.
        pay_seed  = seed;
        seed_copy = seed;
        dummy = $urandom(seed_copy);
        $display("stimulus: %0d directed + %0d random packets, seed %0d, valid %0d%%, ready %0d%%",
                 NDIR, packets, seed, valid_pct, ready_pct);
    end

    function automatic bit chance(input int unsigned pct);
        return ($urandom % 100) < pct;
    endfunction

    // ------------------------------------------------------------------
    // Packet source
    // ------------------------------------------------------------------
    int unsigned pkt  = 0;      // packet index
    int unsigned beat = 0;      // beat index within the packet
    int unsigned len  = 0;      // length of the current packet
    logic        sending = 1'b0;
    logic        all_sent = 1'b0;

    function automatic int unsigned next_len(input int unsigned p);
        if (p < NDIR) return dir_len(p);
        return 1 + ($urandom % maxlen);
    endfunction

    // Beat payload: packet index in byte 2, beat index in byte 0, so a
    // mismatch report reads directly. Bytes 3 and 1 are a mix of the two
    // indices and the seed. Every one of the 32 bits changes across a run, so
    // a data path that drops or ties a bit cannot hide in a constant, and the
    // mixed bytes are not recoverable from the readable ones without redoing
    // the arithmetic, so a converter that carries half the word and
    // regenerates the rest does not compare equal either.
    function automatic logic [31:0] payload(input int unsigned p, input int unsigned b);
        int unsigned m3 = (p * 197 + b * 89  + pay_seed * 61 + 23) % 256;
        int unsigned m1 = (p * 151 + b * 211 + pay_seed * 29 + 97) % 256;
        return {m3[7:0], p[7:0], m1[7:0], b[7:0]};
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s_tvalid <= 1'b0;
            s_tdata  <= '0;
            s_tlast  <= 1'b0;
            sending  <= 1'b0;
            all_sent <= 1'b0;
            pkt      <= 0;
            beat     <= 0;
            len      <= 0;
        end else if (!all_sent) begin
            if (!sending) begin
                len     <= next_len(pkt);
                beat    <= 0;
                sending <= 1'b1;
                s_tvalid <= 1'b0;
            end else if (s_tvalid && s_tready) begin
                // beat accepted
                if (beat + 1 == len) begin
                    s_tvalid <= 1'b0;
                    sending  <= 1'b0;
                    pkt      <= pkt + 1;
                    if (pkt + 1 == NDIR + packets)
                        all_sent <= 1'b1;
                end else begin
                    beat <= beat + 1;
                    if (chance(valid_pct)) begin
                        s_tdata  <= payload(pkt, beat + 1);
                        s_tlast  <= (beat + 2 == len);
                    end else begin
                        s_tvalid <= 1'b0;
                    end
                end
            end else if (!s_tvalid) begin
                // idle inside a packet: present the next beat when the coin says so
                if (chance(valid_pct)) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= payload(pkt, beat);
                    s_tlast  <= (beat + 1 == len);
                end
            end
            // else: beat presented and not yet accepted, hold it
        end
    end

    // ------------------------------------------------------------------
    // Back pressure on the output: m_tready is high with probability
    // ready_pct each cycle, so the default of 100 never stalls after the
    // opening.
    //
    // The opening is directed and runs whatever ready_pct is: m_tready is
    // held low until the converter raises m_tvalid. The specification says
    // m_tvalid must not wait for m_tready, so a converter that waits for
    // permission before announcing a word never gets it, and the run ends on
    // the timeout with words still owed instead of passing quietly.
    // ------------------------------------------------------------------
    logic seen_valid = 1'b0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_tready   <= 1'b0;
            seen_valid <= 1'b0;
        end else if (!seen_valid) begin
            m_tready <= 1'b0;
            if (m_tvalid) seen_valid <= 1'b1;
        end else begin
            m_tready <= chance(ready_pct);
        end
    end

    // ------------------------------------------------------------------
    // Done: everything sent and the output has been quiet for a while
    // ------------------------------------------------------------------
    int unsigned quiet = 0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            quiet <= 0;
            done  <= 1'b0;
        end else if (all_sent) begin
            quiet <= m_tvalid ? 0 : quiet + 1;
            if (quiet > 100)
                done <= 1'b1;
        end
    end

endmodule
