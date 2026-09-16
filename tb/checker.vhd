-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Leonardo Capossio, bard0 design
-- https://www.bard0.com  hello@bard0.com

-- axis_checker: compares the converter output against the reference model,
-- checks the AXI-Stream handshake rules, and collects functional coverage.
--
-- Prints, when report_req rises:
--   WORDS: n            output words transferred
--   PENDING WORDS: n    words the model still owed when the run ended
--   MISMATCHES: n       words that differ from the reference model
--   PROTOCOL ERRORS: n  handshake rule violations
--   COVERAGE: hit/total functional coverage points
--   THROUGHPUT: whether back to back output transfers were seen
--
-- Nothing here bounds how many cycles the converter may take to present a
-- word. The specification does not constrain latency or throughput, so a slow
-- but correct design passes.
--
-- PASS needs the model drained: transferring a correct prefix and then going
-- quiet is a failure, not a pass.
--
-- Coverage is functional only. Back to back output transfers are reported
-- separately, because the specification does not constrain throughput and a
-- correct converter is allowed to insert a bubble.
--
-- Not to be edited by the agent.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity axis_checker is
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;

        -- input side, observed for coverage only
        s_tvalid   : in  std_logic;
        s_tready   : in  std_logic;
        s_tlast    : in  std_logic;

        -- output side, checked
        m_tdata    : in  std_logic_vector(127 downto 0);
        m_tkeep    : in  std_logic_vector(15 downto 0);
        m_tvalid   : in  std_logic;
        m_tready   : in  std_logic;
        m_tlast    : in  std_logic;

        -- reference model
        exp_avail  : in  std_logic;
        exp_data   : in  std_logic_vector(127 downto 0);
        exp_keep   : in  std_logic_vector(15 downto 0);
        exp_last   : in  std_logic;
        exp_pending  : in  natural;
        exp_partial  : in  std_logic;
        exp_overflow : in  std_logic;
        pop        : out std_logic;

        -- end of run
        report_req : in  boolean;
        passed     : out boolean
    );
end entity;

architecture check of axis_checker is

    signal words      : natural := 0;
    signal mismatches : natural := 0;
    signal proto_errs : natural := 0;
    signal out_stalls : natural := 0;   -- cycles with m_tvalid high and m_tready low
    signal in_stalls  : natural := 0;   -- cycles with s_tvalid high and s_tready low

    constant NPTS : natural := 14;
    -- Point 11 measures throughput, which docs/axis_width_conv.md leaves
    -- unconstrained, so it is reported but not required. The other thirteen
    -- are functional and cov has to hit all of them.
    constant PERF  : natural := 11;
    constant NFUNC : natural := NPTS - 1;
    signal cov : std_logic_vector(0 to NPTS - 1) := (others => '0');

    -- A converter that announces a word only once the sink is already ready
    -- never drives m_tvalid high while m_tready is low. Nothing here bounds
    -- how long it may take to announce one, because the specification does
    -- not: this records what happened and the report reads it, so a run that
    -- ends with words owed can say why.
    signal valid_without_ready : std_logic := '0';

    function beats_of(keep : std_logic_vector(15 downto 0)) return natural is
    begin
        case keep is
            when x"000F" => return 1;
            when x"00FF" => return 2;
            when x"0FFF" => return 3;
            when x"FFFF" => return 4;
            when others  => return 0;
        end case;
    end function;

    function cov_name(i : natural) return string is
    begin
        case i is
            when 0  => return "output word with 1 beat";
            when 1  => return "output word with 2 beats";
            when 2  => return "output word with 3 beats";
            when 3  => return "output word with 4 beats";
            when 4  => return "stalled while holding a 1 beat word";
            when 5  => return "stalled while holding a 2 beat word";
            when 6  => return "stalled while holding a 3 beat word";
            when 7  => return "stalled while holding a 4 beat word";
            when 8  => return "tlast on a full word";
            when 9  => return "packet ending on one valid lane";
            when 10 => return "stalled 3 or more cycles in a row";
            when 11 => return "output transfers on consecutive cycles  (throughput, not required)";
            when 12 => return "input gap inside a packet";
            when 13 => return "input beat held while s_tready low";
            when others => return "?";
        end case;
    end function;

    function cov_hits(c : std_logic_vector) return natural is
        variable h : natural := 0;
    begin
        for i in c'range loop
            if i /= PERF and c(i) = '1' then
                h := h + 1;
            end if;
        end loop;
        return h;
    end function;

    procedure say(s : string) is
        variable l : line;
    begin
        write(l, s);
        writeline(output, l);
    end procedure;

begin

    pop <= rst_n and m_tvalid and m_tready;

    ------------------------------------------------------------------
    -- Data check
    ------------------------------------------------------------------
    process (clk)
        variable diff : std_logic_vector(127 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '1' and m_tvalid = '1' and m_tready = '1' then
                words <= words + 1;
                if exp_avail = '0' then
                    mismatches <= mismatches + 1;
                    say("MISMATCH word " & integer'image(words) & " at " & integer'image(now / 1 ns) & " ns" &
                        ": output word transferred but the model expects nothing (keep=" &
                        to_hstring(m_tkeep) & " last=" & std_logic'image(m_tlast) & ")");
                else
                    diff := m_tdata xor exp_data;
                    for b in 0 to 15 loop
                        if exp_keep(b) = '0' then
                            diff(8 * b + 7 downto 8 * b) := (others => '0');
                        end if;
                    end loop;
                    if m_tkeep /= exp_keep or m_tlast /= exp_last or unsigned(diff) /= 0 then
                        mismatches <= mismatches + 1;
                        say("MISMATCH word " & integer'image(words) & " at " & integer'image(now / 1 ns) & " ns:");
                        say("  got  data=" & to_hstring(m_tdata) & " keep=" & to_hstring(m_tkeep) &
                            " last=" & std_logic'image(m_tlast));
                        say("  want data=" & to_hstring(exp_data) & " keep=" & to_hstring(exp_keep) &
                            " last=" & std_logic'image(exp_last));
                    end if;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Handshake rules (docs/axis_width_conv.md, "Handshake")
    ------------------------------------------------------------------
    process (clk)
        variable p_valid, p_ready, p_last : std_logic := '0';
        variable p_data : std_logic_vector(127 downto 0);
        variable p_keep : std_logic_vector(15 downto 0);
        -- Clock edges spent in reset. Reset is synchronous, so on the first
        -- edge with rst_n low the converter's outputs still hold their
        -- previous values and are cleared by that same edge. Checking them
        -- there would fail a correct design, so the check starts on the
        -- second edge.
        variable rst_cycles    : natural := 0;
        variable reset_flagged : boolean := false;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                p_valid    := '0';
                rst_cycles := rst_cycles + 1;
                -- Spec, "Reset": during reset m_tvalid and s_tready are 0.
                if rst_cycles > 1 and (m_tvalid = '1' or s_tready = '1') and not reset_flagged then
                    reset_flagged := true;
                    proto_errs <= proto_errs + 1;
                    say("PROTOCOL: m_tvalid or s_tready high during reset (m_tvalid=" &
                        std_logic'image(m_tvalid) & " s_tready=" & std_logic'image(s_tready) & ")");
                end if;
            else
                rst_cycles := 0;
                if m_tvalid = '1' and m_tready = '0' then
                    valid_without_ready <= '1';
                end if;
                if p_valid = '1' and p_ready = '0' then
                    if m_tvalid = '0' then
                        proto_errs <= proto_errs + 1;
                        say("PROTOCOL: m_tvalid dropped while stalled (before word " &
                            integer'image(words) & ")");
                    elsif m_tdata /= p_data or m_tkeep /= p_keep or m_tlast /= p_last then
                        proto_errs <= proto_errs + 1;
                        say("PROTOCOL: m_tdata/m_tkeep/m_tlast changed while stalled (before word " &
                            integer'image(words) & ")");
                    end if;
                end if;
                if m_tvalid = '1' and beats_of(m_tkeep) = 0 then
                    proto_errs <= proto_errs + 1;
                    say("PROTOCOL: illegal m_tkeep " & to_hstring(m_tkeep));
                end if;
                p_valid := m_tvalid;
                p_ready := m_tready;
                p_data  := m_tdata;
                p_keep  := m_tkeep;
                p_last  := m_tlast;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Functional coverage
    ------------------------------------------------------------------
    process (clk)
        variable n         : natural;
        variable stall_run : natural := 0;
        variable p_xfer    : boolean := false;
        variable in_packet : boolean := false;
    begin
        if rising_edge(clk) and rst_n = '1' then
            n := beats_of(m_tkeep);
            if m_tvalid = '1' and m_tready = '0' then
                out_stalls <= out_stalls + 1;
            end if;
            if s_tvalid = '1' and s_tready = '0' then
                in_stalls <= in_stalls + 1;
            end if;
            if m_tvalid = '1' and m_tready = '1' then
                if n >= 1 and n <= 4 then
                    cov(n - 1) <= '1';
                end if;
                if m_tlast = '1' and n = 4 then
                    cov(8) <= '1';
                end if;
                if m_tlast = '1' and n = 1 then
                    cov(9) <= '1';
                end if;
                if p_xfer then
                    cov(11) <= '1';
                end if;
            end if;
            if m_tvalid = '1' and m_tready = '0' then
                if n >= 1 and n <= 4 then
                    cov(4 + n - 1) <= '1';
                end if;
                stall_run := stall_run + 1;
                if stall_run >= 3 then
                    cov(10) <= '1';
                end if;
            else
                stall_run := 0;
            end if;
            p_xfer := (m_tvalid = '1' and m_tready = '1');

            if s_tvalid = '1' and s_tready = '1' then
                in_packet := (s_tlast = '0');
            elsif in_packet and s_tvalid = '0' then
                cov(12) <= '1';
            end if;
            if s_tvalid = '1' and s_tready = '0' then
                cov(13) <= '1';
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Report
    ------------------------------------------------------------------
    passed <= (words > 0) and (mismatches = 0) and (proto_errs = 0)
              and (exp_pending = 0) and (exp_partial = '0') and (exp_overflow = '0');

    process
    begin
        wait until report_req;
        say("----------------------------------------------------------");
        for i in 0 to NPTS - 1 loop
            if cov(i) = '1' then
                say("  [x] " & cov_name(i));
            else
                say("  [ ] " & cov_name(i));
            end if;
        end loop;
        say("WORDS: " & integer'image(words));
        say("PENDING WORDS: " & integer'image(exp_pending));
        if exp_pending /= 0 then
            say("INCOMPLETE: the model still owes " & integer'image(exp_pending) &
                " word(s); the converter stopped early or dropped them");
            if valid_without_ready = '0' then
                say("INCOMPLETE: m_tvalid never went high while m_tready was low, so the converter appears to wait for m_tready before announcing a word; the specification says it must not");
            end if;
        end if;
        if exp_partial = '1' then
            say("INCOMPLETE: input beats were accepted that never became an output word");
        end if;
        if exp_overflow = '1' then
            say("INVALID: the reference queue overflowed, this run proves nothing");
        end if;
        say("OUTPUT STALL CYCLES: " & integer'image(out_stalls));
        say("INPUT STALL CYCLES: " & integer'image(in_stalls));
        say("MISMATCHES: " & integer'image(mismatches));
        say("PROTOCOL ERRORS: " & integer'image(proto_errs));
        say("COVERAGE: " & integer'image(cov_hits(cov)) & "/" & integer'image(NFUNC));
        if cov(PERF) = '1' then
            say("THROUGHPUT: back to back output transfers seen (not required)");
        else
            say("THROUGHPUT: back to back output transfers not seen (not required)");
        end if;
        wait;
    end process;

end architecture;
