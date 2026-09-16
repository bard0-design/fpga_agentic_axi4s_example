-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Leonardo Capossio, bard0 design
-- https://www.bard0.com  hello@bard0.com

-- stimulus: drives packets into the converter and back pressure into its
-- output. This is the file the agent may extend with more stimulus.
--
-- Generics are set from tb_top, which takes them on the command line:
--   ghdl -r tb_top -gPACKETS=50 -gSEED=3
--
--   PACKETS    random packets after the directed ones   (default 200)
--   SEED       random seed                              (default 1)
--   VALID_PCT  chance per cycle that s_tvalid is high   (default 70)
--   READY_PCT  chance per cycle that m_tready is high   (default 100)
--   MAXLEN     longest random packet, in beats          (default 20)
--
-- Out of the box there is no back pressure: m_tready stays high. The coverage
-- points that need a stall are not reachable until back pressure is added
-- here or READY_PCT is lowered.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

entity stimulus is
    generic (
        PACKETS   : natural := 200;
        SEED      : natural := 1;
        VALID_PCT : natural := 70;
        READY_PCT : natural := 100;
        MAXLEN    : natural := 20
    );
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;

        s_tdata  : out std_logic_vector(31 downto 0);
        s_tvalid : out std_logic;
        s_tready : in  std_logic;
        s_tlast  : out std_logic;

        m_tready : out std_logic;
        m_tvalid : in  std_logic;

        done     : out std_logic
    );
end entity;

architecture drive of stimulus is

    -- Directed packet lengths, sent first: every remainder mod 4, a single
    -- beat, and a few longer ones.
    -- One directed packet is long enough for the beat index to run through
    -- all 256 values of its byte. Without it the top three bits of the beat
    -- byte would be zero all run, and a converter that tied them low would
    -- compare equal on every word.
    constant NDIR : natural := 11;
    type len_array is array (0 to NDIR - 1) of natural;
    constant DIR_LEN : len_array := (1, 2, 3, 4, 5, 8, 9, 7, 1, 300, 4);

    -- Beat payload: packet index in byte 2, beat index in byte 0, so a
    -- mismatch report reads directly. Bytes 3 and 1 are a mix of the two
    -- indices and the seed. Every one of the 32 bits changes across a run, so
    -- a data path that drops or ties a bit cannot hide in a constant, and the
    -- mixed bytes are not recoverable from the readable ones without redoing
    -- the arithmetic, so a converter that carries half the word and
    -- regenerates the rest does not compare equal either.
    function payload(p, b : natural) return std_logic_vector is
        variable m3 : natural;
        variable m1 : natural;
    begin
        m3 := (p * 197 + b * 89  + SEED * 61 + 23) mod 256;
        m1 := (p * 151 + b * 211 + SEED * 29 + 97) mod 256;
        return std_logic_vector(to_unsigned(m3, 8)) &
               std_logic_vector(to_unsigned(p mod 256, 8)) &
               std_logic_vector(to_unsigned(m1, 8)) &
               std_logic_vector(to_unsigned(b mod 256, 8));
    end function;

    signal all_sent : std_logic := '0';

begin

    process
        variable l : line;
    begin
        write(l, string'("stimulus: ") & integer'image(NDIR) & " directed + " &
                 integer'image(PACKETS) & " random packets, seed " & integer'image(SEED) &
                 ", valid " & integer'image(VALID_PCT) & "%, ready " & integer'image(READY_PCT) & "%");
        writeline(output, l);
        wait;
    end process;

    ------------------------------------------------------------------
    -- Packet source
    ------------------------------------------------------------------
    process (clk)
        variable seed1   : positive := SEED + 1;
        variable seed2   : positive := 7 * SEED + 3;
        variable r       : real;
        variable pkt     : natural := 0;
        variable beat    : natural := 0;
        variable len     : natural := 0;
        variable sending : boolean := false;
        variable valid_v : std_logic := '0';

        impure function chance(pct : natural) return boolean is
        begin
            uniform(seed1, seed2, r);
            return integer(floor(r * 100.0)) < pct;
        end function;

        impure function next_len(p : natural) return natural is
        begin
            if p < NDIR then
                return DIR_LEN(p);
            end if;
            uniform(seed1, seed2, r);
            return 1 + (integer(floor(r * real(MAXLEN))) mod MAXLEN);
        end function;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                valid_v  := '0';
                s_tvalid <= '0';
                s_tdata  <= (others => '0');
                s_tlast  <= '0';
                sending  := false;
                all_sent <= '0';
                pkt      := 0;
                beat     := 0;
                len      := 0;
            elsif all_sent = '0' then
                if not sending then
                    len      := next_len(pkt);
                    beat     := 0;
                    sending  := true;
                    valid_v  := '0';
                    s_tvalid <= '0';
                elsif valid_v = '1' and s_tready = '1' then
                    -- beat accepted
                    if beat + 1 = len then
                        valid_v  := '0';
                        s_tvalid <= '0';
                        sending  := false;
                        pkt      := pkt + 1;
                        if pkt = NDIR + PACKETS then
                            all_sent <= '1';
                        end if;
                    else
                        beat := beat + 1;
                        if chance(VALID_PCT) then
                            s_tdata <= payload(pkt, beat);
                            s_tlast <= '1' when (beat + 1 = len) else '0';
                        else
                            valid_v  := '0';
                            s_tvalid <= '0';
                        end if;
                    end if;
                elsif valid_v = '0' then
                    -- idle inside a packet: present the next beat when the coin says so
                    if chance(VALID_PCT) then
                        valid_v  := '1';
                        s_tvalid <= '1';
                        s_tdata  <= payload(pkt, beat);
                        s_tlast  <= '1' when (beat + 1 = len) else '0';
                    end if;
                end if;
                -- else: beat presented and not yet accepted, hold it
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Back pressure on the output: m_tready is high with probability
    -- READY_PCT each cycle, so the default of 100 never stalls after the
    -- opening.
    --
    -- The opening is directed and runs whatever READY_PCT is: m_tready is
    -- held low until the converter raises m_tvalid. The specification says
    -- m_tvalid must not wait for m_tready, so a converter that waits for
    -- permission before announcing a word never gets it, and the run ends on
    -- the timeout with words still owed instead of passing quietly.
    ------------------------------------------------------------------
    process (clk)
        variable seed1      : positive := 3 * SEED + 11;
        variable seed2      : positive := SEED + 29;
        variable r          : real;
        variable seen_valid : boolean := false;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                m_tready   <= '0';
                seen_valid := false;
            elsif not seen_valid then
                m_tready <= '0';
                if m_tvalid = '1' then
                    seen_valid := true;
                end if;
            else
                uniform(seed1, seed2, r);
                if integer(floor(r * 100.0)) < READY_PCT then
                    m_tready <= '1';
                else
                    m_tready <= '0';
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Done: everything sent and the output has been quiet for a while
    ------------------------------------------------------------------
    process (clk)
        variable quiet : natural := 0;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                quiet := 0;
                done  <= '0';
            elsif all_sent = '1' then
                if m_tvalid = '1' then
                    quiet := 0;
                else
                    quiet := quiet + 1;
                end if;
                if quiet > 100 then
                    done <= '1';
                end if;
            end if;
        end if;
    end process;

end architecture;
