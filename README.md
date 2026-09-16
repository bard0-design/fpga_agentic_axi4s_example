# bard0 agent article: the width converter loop

Companion repository for the bard0 Embedded Insights article
[Agentic AI for FPGA Design: How the Loop Works](https://bard0.com/insights/agentic-fpga-loop.html).
Three pages go with it:
[the block itself](https://bard0.com/insights/axis-width-converter-appendix.html),
which covers the handshake, the packing rules and one architecture with
waveforms; [setting up the agent](https://bard0.com/insights/agent-setup-appendix.html),
which covers installing and signing in to a coding agent; and the
[FPGA agentic AI resources page](https://bard0.com/insights/agentic-ai-resources.html),
which collects the skills, tools and standards that build on this loop.

The article walks through an agent implementing an AXI-Stream data width
converter, 32 bit in to 128 bit out, by running lint, simulation, coverage,
synthesis and implementation in a loop and reading the results. This repository holds
everything that walkthrough assumes exists: the specification, the testbench
with an independent checker and reference model, the constraints, and a
Python script whose commands print results the agent can read.

What is missing is the converter itself. `rtl/axis_width_conv.sv` (or `.vhd`)
is a stub with the fixed port list and nothing behind it. Point your agent at
it with the prompt from the article, or write it yourself and run the same
loop by hand.

You do not need to read the articles to run the exercise. The prompt is
reproduced under "The prompt" below, the specification is in `docs/`, and
everything the loop touches is in this repository. The links above are
background, and an agent is better off spending its context here than fetching
four web pages.

## Layout

```
docs/axis_width_conv.md         the specification, the goal of the loop
rtl/axis_width_conv.sv          stub, SystemVerilog track
rtl/axis_width_conv.vhd         stub, VHDL track
tb/tb_top.*                     clock, reset, wiring, RESULT: PASS or FAIL
tb/stimulus.*                   packets and back pressure   (the agent may extend this)
tb/ref_model.*                  expected output, written from the spec
tb/checker.*                    data check, handshake rules, functional coverage
tb/fault.*                      optional interface faults, used by the acceptance suite
constraints/axis_width_conv.xdc the project clock
scripts/impl.tcl                Vivado batch flow: synthesis, implementation, timing
scripts/acceptance.py           checks that the testbench still catches what it claims
run.py                          lint, sim, cov, synth, impl, clean
```

Both tracks share the spec, the constraints and the Vivado script. The
testbench in each language is a port of the other, with the same checks, the
same coverage points and the same report lines.

They are equivalent in what they check, not in what they run. The payload of a
given packet and beat is the same in both for the same seed, so a mismatch line
reads the same either way, but the two use different random number generators
for gaps and packet lengths, so the traffic and the word counts differ. The
counts in this file come from the SystemVerilog track. Compare a run against
the checks it reports, not against a count from the other language.

## Tools

| Command | SystemVerilog (`--hdl sv`, default) | VHDL (`--hdl vhdl`) |
|--------|-----------------------------------|-------------------|
| preflight | version check on iverilog, vvp, yosys | on ghdl and yosys |
| lint   | Icarus Verilog `iverilog -Wall -t null` | GHDL `ghdl -a -Wall` and `ghdl -e` |
| sim    | `iverilog` + `vvp`                | `ghdl -a`, `-e`, `-r` |
| cov    | sim, then the coverage line is checked | same |
| synth  | Yosys generic synthesis           | `ghdl --synth` to Verilog, then Yosys |
| impl   | Vivado in batch mode              | same |
| guard  | git comparison of the trusted files | same |

- Icarus Verilog 12 or newer: <https://steveicarus.github.io/iverilog/>
- GHDL 4 or newer, any backend: <https://github.com/ghdl/ghdl/releases>
- Yosys 0.40 or newer: <https://github.com/YosysHQ/yosys>. The quickest route
  on any platform is `pip install yowasp-yosys`, which the script finds on its
  own.
- Vivado 2023.1 or newer (the free ML Standard edition covers the target part)
- Python 3.8 or newer, standard library only. The script itself runs on
  Windows, Linux and macOS; `impl` needs Vivado, which AMD supports on
  Windows and Linux.

Tools are looked up on PATH. If one is installed somewhere else, set
`IVERILOG`, `VVP`, `GHDL`, `YOSYS` or `VIVADO` in the environment to its full path
before running the script.

`python run.py preflight` prints the version of each tool the chosen track
needs and names any that are missing. Run it once after cloning, before you
start an agent: an agent told to run a simulator that is not installed will
spend its attempts working around that rather than reporting it. A missing
Vivado is reported but is not a failure, because everything except `impl`
runs without it.

Every tool invocation has a wall clock limit, 900 seconds by default. Set
`RUN_TIMEOUT` in the environment to change it. The limit is what returns
control to the loop when a design makes the simulator spin rather than
advance, which the testbench's own timeout cannot catch because it counts
simulated clock edges.

## The loop

```
python run.py preflight  which tools are installed            -> PREFLIGHT OK | FAILED
python run.py lint   compile the RTL, no warnings allowed      -> LINT OK
python run.py sim    run the testbench                        -> RESULT: PASS | FAIL
python run.py cov    run the testbench, require full coverage -> COVERAGE FULL | INCOMPLETE
python run.py synth  generic synthesis, cells and latches     -> SYNTH OK | FAILED
python run.py impl   synthesis, place, route, timing          -> TIMING MET | FAILED
python run.py guard  no trusted file was changed              -> GUARD OK | FAILED
```

`cov` fails on the stimulus as shipped, on a correct design as much as a wrong
one, because the default traffic never applies back pressure. That is
deliberate and it is part of the exercise. See "Coverage" below before
concluding that your converter is at fault.

Every command exits non zero on failure and writes its log to `build/`
(`lint.log`, `sim.log`, `synth.log`, `impl.log`, plus the Vivado reports).
That is what the agent reads.

`synth` is the vendor neutral check: Yosys proves the RTL is synthesisable
and prints the cell and flop count. It fails on an inferred latch, and on a
netlist with no cells or no flops, which is what an empty module produces. `impl`
is the vendor flow for the target part, where the timing figure comes from. It
also stops on a latch, before implementation, rather than reporting timing on a
netlist that should not exist.

One Yosys limitation is worth knowing before it costs you an attempt. Its
Verilog front end does not accept `return` inside a function:

```
function automatic logic [15:0] keep_for(input logic [1:0] fill);
    return 16'hFFFF >> (4 * (2'd3 - fill));   // ERROR: syntax error, unexpected TOK_CONSTVAL
endfunction
```

Assign to the function name instead, which every tool here accepts:

```
function automatic logic [15:0] keep_for(input logic [1:0] fill);
    keep_for = 16'hFFFF >> (4 * (2'd3 - fill));
endfunction
```

Icarus and Vivado both take the first form, so this shows up at `synth` on
code that has already passed `lint` and `sim`. It is a front end limitation,
not a comment on your RTL.

The simulation report ends with:

```
RUN: 933642890        token for this run, see below
WORDS: 708            output words transferred
PENDING WORDS: 0      words the model still owed when the run ended
OUTPUT STALL CYCLES: 4      cycles the output was held by m_tready low
INPUT STALL CYCLES: 0       cycles an input beat waited on s_tready
MISMATCHES: 0         words that differ from the reference model
PROTOCOL ERRORS: 0    AXI-Stream handshake violations
COVERAGE: 8/13        functional coverage points hit
THROUGHPUT: back to back output transfers seen (not required)
RESULT: PASS
```

`PENDING WORDS` has to be zero as well. A converter that accepts every input
beat, emits a correct prefix and then goes quiet produces no mismatch at all,
because a word that is never transferred is never compared. The model counts
what it is still owed, and the run fails with `INCOMPLETE` if anything is left.
`RESULT: FAIL` also makes the simulator exit non zero, so the verdict does not
rest on a string in the log.

`RUN` is a number `run.py` picks fresh for each simulation and passes in. A
report that does not carry it back is not accepted, so a canned report printed
from somewhere else in the simulation does not read as a pass. This is a guard
against an accident or a shortcut, not a proof: anything running inside the
simulation can in principle print anything. That is why the checker, the model
and the top are outside the agent's edit scope, and why the file rules belong
in the tool's permission configuration and not only in the prompt.

Coverage is thirteen functional points. Back to back output transfers are
counted and reported on the `THROUGHPUT` line but are not required, because
the specification does not constrain throughput: a correct converter that
inserts a bubble between output words still reaches full coverage. Nothing
bounds latency either. A converter that takes several cycles to present a word
is slow, not wrong, and the bench does not fail it.

Two of the thirteen points depend on the converter as well as the stimulus.
`input beat held while s_tready low` needs the design's own buffering to fill,
which a deep output queue can prevent however much back pressure you apply. If
a point will not close, check whether your design can reach that state at all
before assuming the stimulus is at fault.

Out of the box the stimulus applies almost no back pressure. `m_tready` is
held low only until the converter first raises `m_tvalid`, and is high after
that, so the five points that need back pressure after the opening are not
reached and
`python run.py cov` fails even on a correct design. Adding back pressure in
`tb/stimulus.sv` (or lowering `READY_PCT`) is part of the exercise, and it is
the gap the agent finds in step 5 of the article. A converter that passes
without it has not been tested on the hard part.

Two things in the default run are directed rather than random, and both are
there to close a hole a random stimulus leaves open:

- **The opening holds `m_tready` low until `m_tvalid` goes high.** The
  specification says `m_tvalid` must not wait for `m_tready`. A converter that
  waits for permission before announcing a word never gets it, so it hangs and
  the run ends with words still owed instead of passing quietly. The checker
  also names the violation when it sees it.
- **One directed packet is 300 beats long.** The beat index is a byte of every
  input beat's payload, and short packets leave its top three bits at zero all
  run, so a converter that tied them low would compare equal on every word.

There is also a reset in the middle of the run, timed to land while the model
is holding a partially packed word, because the specification says beats
received before reset are discarded. A converter that carries that word across
the reset emits it afterwards and mismatches. The stimulus restarts its packet
sequence after the reset. `python run.py sim +NORESET`, or
`python run.py sim --hdl vhdl -gRESET_MID_RUN=false`, skips it while you are
debugging something else.

A mismatch prints the word index, what the converter produced and what the
model expected. Each input beat carries the packet index in byte 2 and the
beat index in byte 0, so a wrong word reads directly as "packet 37, beat 2".
Bytes 3 and 1 hold a mix of the packet index, the beat index and the seed.
Every one of the 32 input bits changes during a run, so a data path that ties a
bit low cannot hide behind a payload that never set it. The mixed bytes are
also not a simple function of the byte beside them, which is what the payload
used to be, so the obvious version of carrying half of each beat and
regenerating the rest no longer compares equal. That is the whole of the claim.
The mix is still arithmetic on the packet index, the beat index and the seed,
and a converter that reproduced that arithmetic would compare equal, so passing
this payload is not a proof that every input byte was carried.

Stimulus options (random packets after the directed set, seed, valid and
ready probabilities, longest packet):

```
python run.py sim +PACKETS=50 +SEED=3 +READY_PCT=60                # iverilog
python run.py sim --hdl vhdl -gPACKETS=50 -gSEED=3 -gREADY_PCT=60  # ghdl
```

Waves: `python run.py sim +DUMP` writes `build/tb_top.vcd` with iverilog;
with GHDL add `--vcd=build/tb_top.vcd` after the command.

## From a mismatch to a waveform

A mismatch names the word, the time and both sides of the comparison:

```
MISMATCH word 40 at 2405 ns:
  got  data=6c09a6031309d302ba09000161092d00 keep=ffff last=0
  want data=6c09a6231309d322ba09002161092d20 keep=ffff last=0
```

Read it in this order.

1. **The payload says where you are in the stream.** Byte 2 of a lane is the
   packet index and byte 0 is the beat index. The hex dump runs lane 3 on the
   left to lane 0 on the right, so the rightmost lane is the oldest beat in the
   word: `61092d00` is packet 9, beat 0, and this word holds beats 0 to 3 of
   packet 9.
2. **Compare `got` against `want` lane by lane, not as one number.** A single
   wrong lane and four wrong lanes are different bugs. One lane wrong in the
   same position in every failing word is a data path problem. Lanes correct
   but in the wrong order is a packing order problem. Lanes right and `tkeep`
   or `tlast` wrong is a partial word problem, and the first failing word is
   then almost always the one at the end of a packet. In the run above every
   lane differs by 0x20, the same bit in each, which is a data path problem and
   not a packing one: the bytes are in the right places and one bit of them is
   wrong.
3. **Look at the first failing word, not the count.** A converter that slips by
   one beat mismatches on everything after the slip, so forty mismatches
   usually describe one event.
4. **Then open the waveform, at the time on the line.** `python run.py sim
   +DUMP +SEED=3` writes `build/tb_top.vcd`, which GTKWave and Surfer both
   read. Go to 2405 ns and put `s_tvalid`, `s_tready`, `s_tdata`, `s_tlast`,
   `m_tvalid`, `m_tready`, `m_tdata`, `m_tkeep` and `m_tlast` on the screen,
   with your internal accumulator and beat counter under them. Walk back from
   the failing transfer to the four input beats that fed it. The edge where the
   accumulator took a beat it should not have, or missed one it should have, is
   the bug.

Two habits make this quicker. Shrink the run first: `+PACKETS=2 +SEED=3` gives
a waveform you can read end to end, and a bug that survives the directed
packets at the start of the run is reproducible in a few microseconds of
simulated time. And rerun with the same seed after the fix rather than a new
one, so you know you addressed the failure you were looking at before you go
looking for the next.

## Checking the exercise itself

`python scripts/acceptance.py` tests the testbench rather than your converter.
Use it after changing anything under `tb/` or `run.py`, when moving the
exercise to another simulator, or when a result here surprises you and you want
to know whether the problem is your design or the bench.

With the stub still in place it runs the cases that need no converter: the stub
lints, fails simulation and fails synthesis, the report parser rejects a stale
run token and a report that is incomplete, out of order or duplicated, and a
tool that closes its output and hangs is killed by the deadline.

Once `rtl/` holds a working converter it also runs the fault suite. `tb/fault.*`
sits between the converter and the rest of the testbench and, told to, injures
its interface in one named way. The injury is applied to whatever is in `rtl/`,
so the suite needs no reference solution and none is shipped:

| Fault | Must |
|------|------|
| stops transferring after 100 words | fail |
| ties input data bit 5 low | fail |
| raises `m_tvalid` only when `m_tready` is high | fail |
| drives `s_tready` during reset | fail |
| `m_tkeep` always `FFFF` | fail |
| drops `m_tvalid` while stalled | fail |
| changes `m_tdata` while stalled | fail |
| carries half of each beat and regenerates the rest | fail |
| one idle cycle between output transfers | **pass** |
| announces each word eight cycles late | **pass** |

The last two are the point of the exercise as much as the first eight. They are
behaviours the specification allows, so a bench that rejected them would be
failing correct designs, and the suite catches that too.

With a converter in place this is 37 cases across both languages and takes a
few minutes. `--hdl sv` or `--hdl vhdl` runs one track, `--list` prints the
cases without running them.

## Checking the do not edit list held

The prompt asks the agent not to edit the checker, the reference model, the
testbench top, the fault layer, the spec, the constraints or the scripts. That
is a request, and a request is not a control. `python run.py guard` is the
control: it compares those thirteen files against what git has recorded and
fails if any of them differs.

```
python run.py guard
GUARD OK: 13 trusted files unchanged
```

Run it before you read a passing result, and after any session you did not
watch. It is a working tree comparison, so it catches a change however it was
made and whichever tool made it, and it compares against `HEAD`: if you meant
to change one of these files, commit that change first and guard will accept
it from then on.

Your agent tool may also be able to refuse the edit in the first place, through
its own permission or sandbox settings. Use that when you have it. Guard is the
check that does not depend on having it, or on it working the way its
documentation says.

## The limits

The article's prompt tells the agent which files it may touch. That is not
decoration. The checker and the reference model are written from the
specification and never from the implementation, so a design that passes did
not get to define what passing means. In the same spirit:

- `rtl/axis_width_conv.*`: the agent's to write.
- `tb/stimulus.*`: the agent may add stimulus.
- `tb/checker.*`, `tb/ref_model.*`, `tb/tb_top.*`, `tb/fault.*`, `docs/`,
  `constraints/`, `run.py`, `scripts/`: not the agent's to edit. These decide what passing
  means and how it is measured, so an agent that may edit them can pass by
  lowering the bar. A constraint change is something it proposes.

If you use a tool that supports it, put those rules in the tool's permission
configuration rather than only in the prompt.

## The prompt

The article's prompt is reproduced here so the repository stands on its own.
Start the agent with the working directory set to this repository and paste it:

```text
Implement axis_width_conv in rtl/axis_width_conv.sv: AXI-Stream, 32 bit in,
128 bit out, four beats per output word, tlast and tkeep correct on a
partial final word. Spec is in docs/axis_width_conv.md.

Run python run.py preflight first and note which tools it finds. Then run
lint, sim, cov, synth and impl, and read the logs after each. Skip impl if
preflight reported no implementation tool. Fix what fails and run again.
Done means: lint clean, sim reports RESULT: PASS with zero mismatches, zero
protocol errors and zero pending words, cov reports full coverage, synth
reports no latches, and impl, if it ran, passes timing.

You may edit rtl/axis_width_conv.sv and add stimulus in tb/stimulus.sv.
Do not edit tb/checker.sv, tb/ref_model.sv, tb/tb_top.sv, tb/fault.sv, run.py,
scripts/, the spec, or any .xdc file. python run.py guard must report GUARD OK
when you are done.
If the same check still fails after two attempts, stop and report what you
tried and what you think the problem is, so I can break it down with you.
```

For the VHDL track, replace each `.sv` with `.vhd` and add `--hdl vhdl` to
every command: `python run.py lint --hdl vhdl`, and the same for `sim`, `cov`
and `synth`.

Two attempts means two edit-and-rerun cycles against the same failing check.
The rule is there because an agent that has not understood a failure will
otherwise keep producing variations of the same wrong answer.

If you have no Vivado installed, drop `impl` from the prompt. The other four
commands still close the loop on functionality.

## Target

Out of context implementation on an Artix-7 `xc7a35tcpg236-1` at 100 MHz.

The clock port names the global buffer it would be driven from
(`HD.CLK_SRC` in the `.xdc`). Out of context there is nothing driving `clk`, so
without that Vivado has no clock tree to analyse and reports skew and insertion
delay as zero. With it the estimate is a little closer to what a real design
would see. It is still an estimate.

Out of context is meant literally. The only constraint is the clock, so `impl`
checks that the block is synthesisable and closes timing on its own paths. It
carries no input or output delay budget, so it says nothing about the
combinational `m_tready` to `s_tready` path once the block sits between two
others. Constraining the interface is a separate exercise and this repository
does not attempt it.
Change the part in `scripts/impl.tcl` and the period in
`constraints/axis_width_conv.xdc` if you want a different target; nothing else
depends on them.

## Author

Leonardo Capossio, [bard0 design](https://www.bard0.com).

FPGA and embedded hardware engineering consultancy. If you run this loop and
something here is wrong, unclear, or could teach it better, mail
<hello@bard0.com>; the same address reaches us for consulting and for the
FPGA and AI training the article mentions.

- Website: <https://www.bard0.com>
- Articles: <https://www.bard0.com/insights/>
- Email: <hello@bard0.com>

## Licence

MIT. See `LICENSE`.
