#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Leonardo Capossio, bard0 design
# https://www.bard0.com  hello@bard0.com

"""Acceptance suite for the exercise itself, not for your converter.

It answers one question: does this testbench still catch the bugs it claims to
catch, and does it let through the things the specification allows? Run it when
you change anything under tb/ or run.py, when you port the exercise to another
simulator, or when a result here surprises you and you want to know whether the
problem is your design or the bench.

    python scripts/acceptance.py                 both languages
    python scripts/acceptance.py --hdl sv        one of them
    python scripts/acceptance.py --list          what it would run

With the stub in rtl/ it checks the parts that need no converter: the stub
lints, fails simulation, and fails synthesis, the report parser rejects a
report it should reject, and a wedged tool is killed. Write a converter, or
copy one in, and it also runs the fault suite: tb/fault.* injures the interface
of whatever is in rtl/ in ten named ways, eight of which must fail and two of
which are legal and must pass. Nothing here needs a reference solution, so none
is shipped.

Exit code 0 means every case behaved as expected. Needs Python 3.8 or newer.
"""

import argparse
import importlib.util
import io
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")

# The faults tb/fault.* can inject, and what each one must do to the run.
# 1 to 8 are bugs the checker has to catch. 9 and 10 are behaviours the
# specification allows, so the bench must not reject them.
FAULTS = [
    (1,  "stops transferring after 100 words",        "fail"),
    (2,  "ties input data bit 5 low",                 "fail"),
    (3,  "raises m_tvalid only when m_tready is high", "fail"),
    (4,  "drives s_tready during reset",              "fail"),
    (5,  "m_tkeep always FFFF",                       "fail"),
    (6,  "drops m_tvalid while stalled",              "fail"),
    (7,  "changes m_tdata while stalled",             "fail"),
    (8,  "carries half the payload, regenerates rest", "fail"),
    (9,  "legal: one idle cycle between transfers",   "pass"),
    (10, "legal: announces each word 8 cycles late",  "pass"),
]

# Reports the parser has to refuse. Each is a complete, plausible looking
# report with one thing wrong.
GOOD_REPORT = """RUN: {nonce}
WORDS: 700
PENDING WORDS: 0
OUTPUT STALL CYCLES: 0
INPUT STALL CYCLES: 0
MISMATCHES: 0
PROTOCOL ERRORS: 0
COVERAGE: 13/13
THROUGHPUT: back to back output transfers seen (not required)
RESULT: PASS
"""


def report_cases(nonce):
    good = GOOD_REPORT.format(nonce=nonce)
    return [
        ("a clean report",              good,                                        0),
        ("a stale run token",           GOOD_REPORT.format(nonce=nonce + 1),         1),
        ("no run token",                good.replace(f"RUN: {nonce}\n", ""),         1),
        ("a second RESULT line",        good + "RESULT: PASS\n",                     1),
        ("RESULT before the report",    "RESULT: PASS\n" + good.replace("RESULT: PASS\n", ""), 1),
        ("a missing stall line",        good.replace("OUTPUT STALL CYCLES: 0\n", ""), 1),
        ("the report out of order",     good.replace("WORDS: 700\nPENDING WORDS: 0\n",
                                                     "PENDING WORDS: 0\nWORDS: 700\n"), 1),
        ("a failing verdict",           good.replace("RESULT: PASS", "RESULT: FAIL"), 1),
    ]


def load_run_py():
    spec = importlib.util.spec_from_file_location("flow", os.path.join(ROOT, "run.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def flow(args):
    """Run run.py and return its exit code and combined output."""
    proc = subprocess.run([sys.executable, "run.py"] + args,
                          cwd=ROOT, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def opt(hdl, name, value):
    """A stimulus or testbench option in the form this language takes."""
    return f"-g{name}={value}" if hdl == "vhdl" else f"+{name}={value}"


class Suite:
    def __init__(self, list_only=False):
        self.rows = []
        self.list_only = list_only

    def case(self, group, name, expect, run):
        if self.list_only:
            print(f"  {group:10s} {name}")
            return
        got = run()
        ok = got == expect
        self.rows.append((ok, group, name, expect, got))
        print(f"{'ok  ' if ok else 'FAIL'}  {group:10s} {name:52s} "
              f"expected {expect}, got {got}", flush=True)

    def failures(self):
        return [r for r in self.rows if not r[0]]


def run_suite(hdls, list_only):
    s = Suite(list_only)

    # ---------------------------------------------------------- the parser
    mod = load_run_py()
    nonce = 12345

    def parser_case(text, expect_rc):
        os.makedirs(BUILD, exist_ok=True)
        with io.open(os.path.join(BUILD, "sim.log"), "w", encoding="utf-8") as f:
            f.write(text)
        cwd = os.getcwd()
        os.chdir(ROOT)
        try:
            return "accept" if mod.sim_verdict(0, nonce) == 0 else "reject"
        finally:
            os.chdir(cwd)

    for name, text, rc in report_cases(nonce):
        s.case("parser", name, "accept" if rc == 0 else "reject",
               lambda t=text, r=rc: parser_case(t, r))

    # --------------------------------------------------------- the deadline
    def wedged():
        probe = os.path.join(BUILD, "wedged.py")
        os.makedirs(BUILD, exist_ok=True)
        with io.open(probe, "w", encoding="utf-8") as f:
            f.write("import os, sys, time\n"
                    "sys.stdout.close(); sys.stderr.close()\n"
                    "os.close(1); os.close(2)\n"
                    "time.sleep(30)\n")
        mod.TIMEOUT = 3
        cwd = os.getcwd()
        os.chdir(ROOT)
        try:
            return "killed" if mod.run([sys.executable, probe]) == 124 else "ran on"
        finally:
            os.chdir(cwd)

    s.case("deadline", "a tool that closes its output and hangs", "killed", wedged)

    # ------------------------------------------------------------ the flow
    for hdl in hdls:
        lang = ["--hdl", hdl]

        working = flow(["sim"] + lang)[0] == 0 if not list_only else False

        if not working:
            s.case(hdl, "the module in rtl/ lints", "ok",
                   lambda a=lang: "ok" if flow(["lint"] + a)[0] == 0 else "not ok")
            s.case(hdl, "an unimplemented converter fails simulation", "fail",
                   lambda a=lang: "fail" if flow(["sim"] + a)[0] != 0 else "pass")
            s.case(hdl, "an empty netlist fails synthesis", "fail",
                   lambda a=lang: "fail" if flow(["synth"] + a)[0] != 0 else "pass")
            if not list_only:
                print(f"      {hdl}: rtl/ holds no working converter, so the fault "
                      f"suite is skipped. Write one, or copy one in, and run again.")
            continue

        s.case(hdl, "a working converter passes simulation", "pass",
               lambda a=lang: "pass" if flow(["sim"] + a)[0] == 0 else "fail")
        s.case(hdl, "a working converter lints", "ok",
               lambda a=lang: "ok" if flow(["lint"] + a)[0] == 0 else "not ok")
        s.case(hdl, "a working converter synthesises without latches", "ok",
               lambda a=lang: "ok" if flow(["synth"] + a)[0] == 0 else "not ok")
        s.case(hdl, "back pressure closes coverage", "full",
               lambda a=lang, h=hdl: "full" if flow(
                   ["cov"] + a + [opt(h, "READY_PCT", 60)])[0] == 0 else "short")

        for num, what, expect in FAULTS:
            s.case(hdl, f"fault {num}: {what}", expect,
                   lambda a=lang, h=hdl, n=num, e=expect:
                   ("pass" if flow(["sim"] + a + [opt(h, "FAULT", n),
                                                  opt(h, "READY_PCT", 60)])[0] == 0
                    else "fail"))

    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hdl", choices=["sv", "vhdl", "both"], default="both")
    ap.add_argument("--list", action="store_true", help="print the cases and stop")
    args = ap.parse_args()

    hdls = ["sv", "vhdl"] if args.hdl == "both" else [args.hdl]
    s = run_suite(hdls, args.list)
    if args.list:
        return 0

    bad = s.failures()
    print()
    if bad:
        print(f"ACCEPTANCE FAILED: {len(bad)} of {len(s.rows)} cases did not behave as expected")
        for _, group, name, expect, got in bad:
            print(f"  {group}: {name} -> expected {expect}, got {got}")
        return 1
    print(f"ACCEPTANCE OK: {len(s.rows)} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
