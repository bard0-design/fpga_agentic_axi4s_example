-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Leonardo Capossio, bard0 design
-- https://www.bard0.com  hello@bard0.com

-- ref_model: behavioural model of axis_width_conv, written from the spec.
--
-- It watches the input side handshake, packs beats exactly as
-- docs/axis_width_conv.md describes, and queues the expected output words.
-- The checker pops one expected word per output transfer.
--
-- exp_* are valid in the cycle before the clock edge on which the checker
-- compares them. A word that completes on the same edge as it is transferred
-- (a zero latency converter) is presented combinationally, so that case also
-- checks correctly.
--
-- Not to be edited by the agent.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ref_model is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        s_tdata   : in  std_logic_vector(31 downto 0);
        s_tvalid  : in  std_logic;
        s_tready  : in  std_logic;
        s_tlast   : in  std_logic;

        pop       : in  std_logic;
        exp_avail : out std_logic;
        exp_data  : out std_logic_vector(127 downto 0);
        exp_keep  : out std_logic_vector(15 downto 0);
        exp_last  : out std_logic;

        -- End of run completeness, read by the checker. A design that accepts
        -- every input beat but stops emitting leaves words queued here.
        exp_pending  : out natural;
        exp_partial  : out std_logic;
        exp_overflow : out std_logic
    );
end entity;

architecture model of ref_model is

    constant DEPTH : natural := 4096;

    type data_array is array (0 to DEPTH - 1) of std_logic_vector(127 downto 0);
    type keep_array is array (0 to DEPTH - 1) of std_logic_vector(15 downto 0);

    signal q_data : data_array;
    signal q_keep : keep_array;
    signal q_last : std_logic_vector(0 to DEPTH - 1);
    signal wr, rd : natural range 0 to DEPTH - 1 := 0;

    -- partially packed word
    signal acc  : std_logic_vector(127 downto 0) := (others => '0');
    signal fill : natural range 0 to 3 := 0;

    -- word that would complete on this edge, if any
    signal accept, complete : std_logic;
    signal ovf : std_logic := '0';
    signal cand_data : std_logic_vector(127 downto 0);
    signal cand_keep : std_logic_vector(15 downto 0);

    function keep_for(beats : natural) return std_logic_vector is
        variable k : std_logic_vector(15 downto 0) := (others => '0');
    begin
        for b in 0 to 15 loop
            if b < 4 * beats then
                k(b) := '1';
            end if;
        end loop;
        return k;
    end function;

begin

    -- Words the specification says are due but the converter has not
    -- transferred yet, the partially packed word it still owes, and the
    -- queue overflow that would make the oracle lie.
    exp_pending  <= (wr + DEPTH - rd) mod DEPTH;
    exp_partial  <= '1' when fill /= 0 else '0';
    exp_overflow <= ovf;

    accept   <= s_tvalid and s_tready;
    complete <= accept when (fill = 3 or s_tlast = '1') else '0';

    process (all)
    begin
        cand_data <= acc;
        cand_data(32 * fill + 31 downto 32 * fill) <= s_tdata;
        cand_keep <= keep_for(fill + 1);
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                wr   <= 0;
                rd   <= 0;
                acc  <= (others => '0');
                fill <= 0;
                ovf  <= '0';
            else
                if accept = '1' and complete = '1'
                   and ((wr + DEPTH - rd) mod DEPTH) >= DEPTH - 1 then
                    ovf <= '1';
                    report "MODEL: reference queue overflow at " & integer'image(DEPTH) &
                           " words, raise DEPTH in tb/ref_model.vhd" severity note;
                end if;
                if pop = '1' then
                    rd <= (rd + 1) mod DEPTH;
                end if;
                if accept = '1' then
                    if complete = '1' then
                        q_data(wr) <= cand_data;
                        q_keep(wr) <= cand_keep;
                        q_last(wr) <= s_tlast;
                        wr   <= (wr + 1) mod DEPTH;
                        acc  <= (others => '0');
                        fill <= 0;
                    else
                        acc  <= cand_data;
                        fill <= fill + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process (all)
    begin
        if wr /= rd then
            exp_avail <= '1';
            exp_data  <= q_data(rd);
            exp_keep  <= q_keep(rd);
            exp_last  <= q_last(rd);
        else
            exp_avail <= complete;
            exp_data  <= cand_data;
            exp_keep  <= cand_keep;
            exp_last  <= s_tlast;
        end if;
    end process;

end architecture;
