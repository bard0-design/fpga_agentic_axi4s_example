-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Leonardo Capossio, bard0 design
-- https://www.bard0.com  hello@bard0.com

-- fault: an optional layer between the converter and the rest of the
-- testbench, used only by scripts/acceptance.py.
--
-- With FAULT_SEL = 0 it is a wire. With any other value it injures the
-- converter's interface in one specific, named way. That lets the acceptance
-- suite prove the testbench catches a class of bug without shipping a
-- reference solution and without knowing anything about how the converter is
-- written: the injury is applied to whatever implementation is in rtl/.
--
-- Faults 1 to 8 must make the run fail. Faults 9 and 10 are legal behaviours a
-- correct converter is allowed to have, and must still pass; they are here so
-- that a bench which over-constrains the design is caught too.
--
--   0  none, a straight wire
--   1  stop transferring after STOP_AT output words
--   2  tie input data bit 5 low on every lane of the output word
--   3  raise m_tvalid only when m_tready is already high
--   4  drive s_tready high during reset
--   5  m_tkeep always FFFF
--   6  drop m_tvalid for one cycle while a word is stalled
--   7  change m_tdata while a word is stalled
--   8  carry only bytes 2 and 0 of each lane, regenerate 3 and 1
--   9  legal: one idle cycle between output transfers
--  10  legal: announce each word LATENCY cycles after it is ready
--
-- Not to be edited by the agent.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fault is
    generic (
        FAULT_SEL : natural := 0;
        STOP_AT   : natural := 100;
        LATENCY   : natural := 8
    );
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;

        -- from the converter
        d_s_tready : in  std_logic;
        d_m_tdata  : in  std_logic_vector(127 downto 0);
        d_m_tkeep  : in  std_logic_vector(15 downto 0);
        d_m_tvalid : in  std_logic;
        d_m_tlast  : in  std_logic;
        d_m_tready : out std_logic;

        -- to the rest of the testbench
        s_tready   : out std_logic;
        m_tdata    : out std_logic_vector(127 downto 0);
        m_tkeep    : out std_logic_vector(15 downto 0);
        m_tvalid   : out std_logic;
        m_tlast    : out std_logic;
        m_tready   : in  std_logic
    );
end entity;

architecture inject of fault is

    signal xfers        : natural   := 0;
    signal gate         : std_logic := '0';   -- fault 9
    signal wait_n       : natural   := 0;     -- fault 10
    signal stall_toggle : std_logic := '0';

    signal v_int, r_int : std_logic;
    signal d_int        : std_logic_vector(127 downto 0);

    -- Lane rebuild used by fault 8: keep bytes 2 and 0, regenerate 3 and 1 as
    -- the complement of their neighbour, which is what the payload used to
    -- make recoverable.
    function halved(w : std_logic_vector(31 downto 0)) return std_logic_vector is
    begin
        return (not w(23 downto 16)) & w(23 downto 16) &
               (not w(7 downto 0))   & w(7 downto 0);
    end function;

begin

    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                xfers        <= 0;
                gate         <= '0';
                wait_n       <= 0;
                stall_toggle <= '0';
            else
                if v_int = '1' and m_tready = '1' then
                    xfers <= xfers + 1;
                    gate  <= '1';
                else
                    gate <= '0';
                end if;
                if d_m_tvalid = '1' and m_tready = '0' then
                    stall_toggle <= '1';
                else
                    stall_toggle <= '0';
                end if;
                -- Reset on a transfer as well as on an idle cycle, so every
                -- word waits LATENCY cycles, not just the first of a burst.
                if d_m_tvalid = '0' or (v_int = '1' and m_tready = '1') then
                    wait_n <= 0;
                elsif wait_n < LATENCY then
                    wait_n <= wait_n + 1;
                end if;
            end if;
        end if;
    end process;

    process (all)
        variable dv : std_logic_vector(127 downto 0);
    begin
        -- Default: a straight wire.
        s_tready <= d_s_tready;
        dv       := d_m_tdata;
        m_tkeep  <= d_m_tkeep;
        v_int    <= d_m_tvalid;
        r_int    <= m_tready;
        m_tlast  <= d_m_tlast;

        case FAULT_SEL is
            when 1 =>
                if xfers >= STOP_AT then
                    v_int <= '0';
                    r_int <= '0';
                end if;
            when 2 =>
                for lane in 0 to 3 loop
                    dv(32 * lane + 5) := '0';
                end loop;
            when 3 =>
                v_int <= d_m_tvalid and m_tready;
                r_int <= m_tready and d_m_tvalid;
            when 4 =>
                s_tready <= d_s_tready or (not rst_n);
            when 5 =>
                if d_m_tvalid = '1' then
                    m_tkeep <= x"FFFF";
                end if;
            when 6 =>
                if d_m_tvalid = '1' and m_tready = '0' and stall_toggle = '1' then
                    v_int <= '0';
                    r_int <= '0';
                end if;
            when 7 =>
                if d_m_tvalid = '1' and m_tready = '0' and stall_toggle = '1' then
                    dv(0) := not d_m_tdata(0);
                end if;
            when 8 =>
                for lane in 0 to 3 loop
                    dv(32 * lane + 31 downto 32 * lane) :=
                        halved(d_m_tdata(32 * lane + 31 downto 32 * lane));
                end loop;
            when 9 =>
                if gate = '1' then
                    v_int <= '0';
                    r_int <= '0';
                end if;
            when 10 =>
                if wait_n < LATENCY then
                    v_int <= '0';
                    r_int <= '0';
                end if;
            when others =>
                null;
        end case;

        d_int <= dv;
    end process;

    m_tdata    <= d_int;
    m_tvalid   <= v_int;
    d_m_tready <= r_int;

end architecture;
