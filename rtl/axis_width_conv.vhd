-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Leonardo Capossio, bard0 design
-- https://www.bard0.com  hello@bard0.com

-- axis_width_conv: AXI-Stream data width converter, 32 bit in to 128 bit out.
--
-- Specification: docs/axis_width_conv.md
--
-- The entity is fixed. The architecture is yours (or your agent's) to write.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axis_width_conv is
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;

        s_tdata  : in  std_logic_vector(31 downto 0);
        s_tvalid : in  std_logic;
        s_tready : out std_logic;
        s_tlast  : in  std_logic;

        m_tdata  : out std_logic_vector(127 downto 0);
        m_tkeep  : out std_logic_vector(15 downto 0);
        m_tvalid : out std_logic;
        m_tready : in  std_logic;
        m_tlast  : out std_logic
    );
end entity;

architecture rtl of axis_width_conv is
begin

    -- TODO: implement. Until then the block accepts nothing and emits nothing.
    s_tready <= '0';
    m_tdata  <= (others => '0');
    m_tkeep  <= (others => '0');
    m_tvalid <= '0';
    m_tlast  <= '0';

end architecture;
