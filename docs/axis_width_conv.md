# axis_width_conv specification

An AXI-Stream data width converter, 32 bit in to 128 bit out. Four input beats
are packed into one output word. A packet whose length is not a multiple of
four ends with a partially filled output word, marked by `tkeep`.

This document is the goal. The checker (`tb/checker.*`) and the reference model
(`tb/ref_model.*`) are written from it, not from any implementation.

## Interface

All signals are synchronous to the rising edge of `clk`. `rst_n` is an active
low synchronous reset.

| Signal      | Dir | Width | Description                                        |
|-------------|-----|-------|----------------------------------------------------|
| `clk`       | in  | 1     | Clock                                              |
| `rst_n`     | in  | 1     | Synchronous reset, active low                      |
| `s_tdata`   | in  | 32    | Input beat                                         |
| `s_tvalid`  | in  | 1     | Input beat valid                                   |
| `s_tready`  | out | 1     | Converter accepts the input beat                   |
| `s_tlast`   | in  | 1     | Input beat is the last of its packet               |
| `m_tdata`   | out | 128   | Output word                                        |
| `m_tkeep`   | out | 16    | Byte qualifiers for `m_tdata`, one bit per byte    |
| `m_tvalid`  | out | 1     | Output word valid                                  |
| `m_tready`  | in  | 1     | Downstream accepts the output word                 |
| `m_tlast`   | out | 1     | Output word is the last of its packet              |

Every input beat carries four valid bytes, so there is no `s_tkeep`.

## Packing

Input beats are numbered from 0 within each packet. Beat `i` of a packet lands
in output word `i / 4`, in lanes `[32*(i mod 4) + 31 : 32*(i mod 4)]`. The first
beat of a word occupies the least significant lanes.

An output word is complete when it holds four beats, or when the beat it
received was marked `s_tlast`.

## tkeep and tlast

`m_tkeep[b]` is 1 when byte `b` of `m_tdata` holds input data and 0 otherwise.
A full word has `m_tkeep = 16'hFFFF`. A word holding `n` beats (1 to 4) has the
low `4*n` bits set and the rest clear. The contents of `m_tdata` bytes whose
`m_tkeep` bit is 0 are unspecified.

`m_tlast` is 1 on the output word that holds the last beat of the packet, and
0 on every other word.

Packets are never merged: the word after a `m_tlast` word starts a new packet
with beat 0 in the least significant lanes.

## Handshake

The AXI-Stream rules apply on both interfaces:

- A beat transfers on a clock edge where `tvalid` and `tready` are both 1.
- Once `m_tvalid` is 1 it stays 1, and `m_tdata`, `m_tkeep` and `m_tlast` hold
  their values, until the transfer happens.
- `m_tvalid` must not wait for `m_tready`. `s_tready` may depend on `m_tready`.
- `s_tvalid` may drop to 0 between beats of a packet. The converter must not
  emit anything for beats it has not received.

## Reset

During and after reset `m_tvalid` and `s_tready` are 0 until the converter is
ready. Any beats received before reset are discarded.

## Throughput

Not constrained by this specification. A converter that accepts one input beat
per clock when the output is not stalled is the expected result, but the
checker does not measure it.

## Relationship to AMBA AXI4-Stream

This is a profile of AXI4-Stream, not the whole protocol. The handshake rules
above are AMBA's and are where a converter usually goes wrong. The rest is
narrower, deliberately, and the differences matter if you reuse the block or
the testbench outside this exercise.

- Signals. The stream carries `tdata`, `tvalid`, `tready`, `tlast`, and `tkeep`
  on the output only. There is no `tstrb`, `tid`, `tdest` or `tuser` on either
  interface, so this converter handles one anonymous stream. A general one must
  never coalesce beats with different `tid` or `tdest` into a single output
  word. This one never sees them.
- No `s_tkeep`. AMBA lets a master emit sparse or partial beats. Here the input
  contract is four valid bytes on every beat, which is what makes the packing
  arithmetic above well defined. A source that ends a packet with a short beat
  needs a different block, not a wider one.
- Synchronous reset. AMBA's `ARESETn` may be asserted asynchronously and must be
  deasserted synchronously. `rst_n` here is synchronous in both directions,
  which is the usual choice on an FPGA and is a restriction rather than an
  extension.
- `s_tready` during reset. AMBA requires `tvalid` low during reset and only
  recommends `tready` low. This specification requires both, and the checker
  enforces it as a protocol error. That is stricter than AMBA on purpose: a
  checked exercise needs rules with one reading.
- Combinational `s_tready`. Allowed above, and allowed by AMBA, which does not
  forbid a path between interfaces. It costs a `tready` path that crosses the
  block, which is what a skid buffer on the input would buy back. It cannot
  close a combinational loop on its own, because that would need a master whose
  `tvalid` waits for `tready`, and AMBA forbids that.

## Target

The block must meet timing on the project clock in `constraints/axis_width_conv.xdc`
on the part named in `scripts/impl.tcl`.

---

Leonardo Capossio, bard0 design, <https://www.bard0.com>, <hello@bard0.com>. MIT licensed.
