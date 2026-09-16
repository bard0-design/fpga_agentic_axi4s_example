-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Leonardo Capossio, bard0 design
-- https://www.bard0.com  hello@bard0.com

-- tb_top: clock, reset, and the wiring between stimulus, DUT, reference
-- model and checker. Prints RESULT: PASS or RESULT: FAIL at the end.
--
-- Generics can be set on the command line, for example:
--   ghdl -r --std=08 tb_top -gPACKETS=50 -gSEED=3
-- Waves: add --vcd=build/tb_top.vcd to the ghdl -r line.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_top is
    generic (
        PACKETS   : natural := 200;
        SEED      : natural := 1;
        VALID_PCT : natural := 70;
        READY_PCT : natural := 100;
        MAXLEN    : natural := 20;
        RESET_MID_RUN : boolean := true;
        -- Token for this run. run.py picks a fresh number every time and
        -- refuses a report that does not carry it back, so a canned report
        -- printed from somewhere else in the simulation is not a pass.
        NONCE     : natural := 0;
        -- Fault injection for scripts/acceptance.py. 0 is a straight wire.
        FAULT     : natural := 0
    );
end entity;

architecture sim of tb_top is

    -- Cycles to wait for the model to hold a partial word before giving up
    -- on the mid run reset.
    constant RESET_WAIT     : natural := 5_000;
    constant TIMEOUT_CYCLES : natural := 200_000;
    constant PERIOD         : time    := 10 ns;

    signal clk   : std_logic := '0';
    signal rst_n : std_logic := '0';

    signal s_tdata  : std_logic_vector(31 downto 0);
    signal s_tvalid, s_tready, s_tlast : std_logic;
    signal m_tdata  : std_logic_vector(127 downto 0);
    signal m_tkeep  : std_logic_vector(15 downto 0);
    signal m_tvalid, m_tready, m_tlast : std_logic;
    signal done     : std_logic;

    signal exp_avail, exp_last, pop : std_logic;
    signal exp_data : std_logic_vector(127 downto 0);
    signal exp_keep : std_logic_vector(15 downto 0);
    signal exp_pending : natural;
    signal exp_partial, exp_overflow : std_logic;

    -- The converter's own interface, before the fault layer.
    signal d_s_tready, d_m_tvalid, d_m_tlast, d_m_tready : std_logic;
    signal d_m_tdata : std_logic_vector(127 downto 0);
    signal d_m_tkeep : std_logic_vector(15 downto 0);

    signal report_req : boolean := false;
    signal passed     : boolean;
    signal finished   : boolean := false;

begin

    clk <= not clk after PERIOD / 2 when not finished;

    u_stim : entity work.stimulus
        generic map (
            PACKETS => PACKETS, SEED => SEED, VALID_PCT => VALID_PCT,
            READY_PCT => READY_PCT, MAXLEN => MAXLEN)
        port map (
            clk => clk, rst_n => rst_n,
            s_tdata => s_tdata, s_tvalid => s_tvalid, s_tready => s_tready, s_tlast => s_tlast,
            m_tready => m_tready, m_tvalid => m_tvalid,
            done => done);

    dut : entity work.axis_width_conv
        port map (
            clk => clk, rst_n => rst_n,
            s_tdata => s_tdata, s_tvalid => s_tvalid, s_tready => d_s_tready, s_tlast => s_tlast,
            m_tdata => d_m_tdata, m_tkeep => d_m_tkeep, m_tvalid => d_m_tvalid,
            m_tready => d_m_tready, m_tlast => d_m_tlast);

    -- With FAULT = 0 this layer is a wire. scripts/acceptance.py uses the
    -- other values to injure the converter's interface on purpose.
    u_fault : entity work.fault
        generic map (FAULT_SEL => FAULT)
        port map (
            clk => clk, rst_n => rst_n,
            d_s_tready => d_s_tready, d_m_tdata => d_m_tdata, d_m_tkeep => d_m_tkeep,
            d_m_tvalid => d_m_tvalid, d_m_tlast => d_m_tlast, d_m_tready => d_m_tready,
            s_tready => s_tready, m_tdata => m_tdata, m_tkeep => m_tkeep,
            m_tvalid => m_tvalid, m_tlast => m_tlast, m_tready => m_tready);

    u_model : entity work.ref_model
        port map (
            clk => clk, rst_n => rst_n,
            s_tdata => s_tdata, s_tvalid => s_tvalid, s_tready => s_tready, s_tlast => s_tlast,
            pop => pop, exp_avail => exp_avail, exp_data => exp_data,
            exp_keep => exp_keep, exp_last => exp_last,
            exp_pending => exp_pending, exp_partial => exp_partial,
            exp_overflow => exp_overflow);

    u_chk : entity work.axis_checker
        port map (
            clk => clk, rst_n => rst_n,
            s_tvalid => s_tvalid, s_tready => s_tready, s_tlast => s_tlast,
            m_tdata => m_tdata, m_tkeep => m_tkeep, m_tvalid => m_tvalid,
            m_tready => m_tready, m_tlast => m_tlast,
            exp_avail => exp_avail, exp_data => exp_data, exp_keep => exp_keep,
            exp_last => exp_last,
            exp_pending => exp_pending, exp_partial => exp_partial,
            exp_overflow => exp_overflow, pop => pop,
            report_req => report_req, passed => passed);

    process
        variable l      : line;
        variable cycles : natural := 0;
        variable waited : natural := 0;
    begin
        for i in 1 to 5 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';

        -- Mid run reset. The specification says beats received before reset
        -- are discarded, so the reset is timed to land while the reference
        -- model is holding a partially packed word: a converter that keeps
        -- that word across reset emits it afterwards and mismatches. The
        -- stimulus restarts its packet sequence, and both the model and the
        -- converter start again from empty.
        if RESET_MID_RUN then
            for i in 1 to 100 loop
                wait until rising_edge(clk);
            end loop;
            -- Bounded: a converter that never accepts a beat never gives the
            -- model a partial word to hold, and the run has to reach its own
            -- timeout rather than wait here forever.
            waited := 0;
            loop
                wait until rising_edge(clk);
                waited := waited + 1;
                exit when exp_partial = '1' or waited = RESET_WAIT;
            end loop;
            if exp_partial = '1' then
                write(l, string'("MID RUN RESET: asserted while the model held a partial word"));
                writeline(output, l);
                rst_n <= '0';
                for i in 1 to 3 loop
                    wait until rising_edge(clk);
                end loop;
                rst_n <= '1';
            else
                write(l, string'("MID RUN RESET: skipped, the model never held a partial word"));
                writeline(output, l);
            end if;
        end if;

        loop
            wait until rising_edge(clk);
            cycles := cycles + 1;
            exit when done = '1' or cycles = TIMEOUT_CYCLES;
        end loop;

        if cycles = TIMEOUT_CYCLES then
            write(l, string'("TIMEOUT after ") & integer'image(cycles) & " cycles");
            writeline(output, l);
        end if;

        write(l, string'("RUN: ") & integer'image(NONCE));
        writeline(output, l);
        report_req <= true;
        wait for 1 ns;

        if done = '1' and passed then
            write(l, string'("RESULT: PASS"));
            writeline(output, l);
            finished <= true;
            wait for 1 ns;
            finish;
        else
            write(l, string'("RESULT: FAIL"));
            writeline(output, l);
            finished <= true;
            wait for 1 ns;
            -- stop(1), not finish: the simulator exits non zero, so a failing
            -- run cannot be hidden behind a printed string.
            stop(1);
        end if;
    end process;

end architecture;
