#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Leonardo Capossio, bard0 design
# https://www.bard0.com  hello@bard0.com

"""axis_width_conv flow. Commands: preflight, lint, sim, cov, synth, impl, guard, clean.

    python run.py preflight        which tools are installed            -> PREFLIGHT OK | FAILED
    python run.py lint             compile the RTL, no warnings allowed -> LINT OK
    python run.py sim              run the testbench                    -> RESULT: PASS | FAIL
    python run.py cov              run the testbench, require coverage  -> COVERAGE FULL | INCOMPLETE
    python run.py synth            Yosys generic synthesis, no latches  -> SYNTH OK | FAILED
    python run.py impl             Vivado synthesis, implementation, timing -> TIMING MET | FAILED
    python run.py guard            check no trusted file changed        -> GUARD OK | FAILED
    python run.py clean            remove build/ and tool droppings

--hdl sv (default) or --hdl vhdl selects the language. Anything after the
command that the script does not recognise is passed to the simulator:

    python run.py sim +PACKETS=50 +SEED=3                  (iverilog plusargs)
    python run.py sim --hdl vhdl -gPACKETS=50 -gSEED=3     (ghdl generics)

Tool paths come from the environment when they are not on PATH: IVERILOG,
VVP, GHDL, YOSYS, VIVADO. Yosys is also found when installed with
"pip install yowasp-yosys". Every command exits non zero on failure and
writes its log to build/ so an agent can read it back. Needs Python 3.8 or
newer and nothing outside the standard library.
"""

import argparse
import glob
import os
import re
import shutil
import random
import subprocess
import sys
import threading

BUILD = "build"

# Wall clock limit per tool invocation. The testbench timeout counts simulated
# clock edges, which cannot rescue a simulation stuck in delta cycles, and a
# synthesis run can wedge too. Without a deadline the loop simply stops.
TIMEOUT = int(os.environ.get("RUN_TIMEOUT", "900"))

SV_RTL = ["rtl/axis_width_conv.sv"]
SV_TB = ["tb/tb_top.sv", "tb/stimulus.sv", "tb/ref_model.sv", "tb/checker.sv", "tb/fault.sv"]
VHDL_RTL = ["rtl/axis_width_conv.vhd"]
VHDL_TB = ["tb/ref_model.vhd", "tb/checker.vhd", "tb/stimulus.vhd", "tb/fault.vhd", "tb/tb_top.vhd"]
GHDL_FLAGS = ["--std=08", "--workdir=" + BUILD, "-frelaxed"]


def tool(name):
    """Resolve a tool: the environment variable named after it, else PATH.
    shutil.which also finds vivado.bat on Windows, which a bare name would not."""
    wanted = os.environ.get(name.upper(), name)
    return shutil.which(wanted) or wanted


def run(cmd, log=None, append=False):
    """Run a command, echo its output, optionally tee it to a log file.
    Returns the exit code."""
    print("$ " + " ".join(cmd), flush=True)
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except FileNotFoundError:
        print(f"error: {cmd[0]} not found. Install it or set {os.path.basename(cmd[0]).upper()} in the environment.")
        return 127
    handle = open(log, "a" if append else "w", encoding="utf-8") if log else None
    expired = []
    timer = threading.Timer(TIMEOUT, lambda: (expired.append(True), proc.kill()))
    timer.start()
    try:
        for line in proc.stdout:
            sys.stdout.write(line)
            if handle:
                handle.write(line)
        # The deadline stays armed until the process has actually exited. A
        # child that closes its output and keeps running would otherwise be
        # waited on forever.
        rc = proc.wait()
    finally:
        timer.cancel()
    sys.stdout.flush()
    if expired:
        note = f"error: killed after {TIMEOUT}s. Set RUN_TIMEOUT to allow longer."
        print(note)
        if handle:
            handle.write(note + "\n")
        rc = 124
    if handle:
        handle.close()
    return rc


def ensure_build():
    os.makedirs(BUILD, exist_ok=True)


def read_log(name):
    path = os.path.join(BUILD, name)
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def cmd_lint(hdl, extra):
    ensure_build()
    log = os.path.join(BUILD, "lint.log")
    if hdl == "vhdl":
        rc = run([tool("ghdl"), "-a"] + GHDL_FLAGS + ["-Wall"] + VHDL_RTL, log)
        if rc == 0:
            rc = run([tool("ghdl"), "-e"] + GHDL_FLAGS + ["axis_width_conv"], log, append=True)
    else:
        rc = run([tool("iverilog"), "-g2012", "-Wall", "-t", "null"] + SV_RTL, log)
    text = read_log("lint.log")
    warnings = len(re.findall(r"\bwarning:", text, re.I))
    print(f"LINT WARNINGS: {warnings}")
    if rc != 0:
        print("LINT FAILED")
        return rc
    if warnings:
        # "Lint clean" means no warnings, not merely that it compiled.
        print("LINT FAILED (warnings)")
        return 1
    print("LINT OK")
    return 0


def cmd_sim(hdl, extra):
    ensure_build()
    log = os.path.join(BUILD, "sim.log")
    nonce = random.randrange(1, 2 ** 30)
    extra = list(extra) + ([f"-gNONCE={nonce}"] if hdl == "vhdl" else [f"+NONCE={nonce}"])
    if hdl == "vhdl":
        rc = run([tool("ghdl"), "-a"] + GHDL_FLAGS + VHDL_RTL + VHDL_TB, log)
        if rc == 0:
            rc = run([tool("ghdl"), "-e"] + GHDL_FLAGS + ["tb_top"], log, append=True)
        if rc == 0:
            rc = run([tool("ghdl"), "-r"] + GHDL_FLAGS + ["tb_top"] + extra, log, append=True)
    else:
        vvp_file = os.path.join(BUILD, "sim.vvp")
        rc = run([tool("iverilog"), "-g2012", "-Wall", "-o", vvp_file] + SV_TB + SV_RTL, log)
        if rc == 0:
            rc = run([tool("vvp"), vvp_file] + extra, log, append=True)
    return sim_verdict(rc, nonce)


# Every line the checker's report prints, in the order it prints them. A pass
# has to show the whole report, once, with RESULT at the end of it.
REPORT_LINES = [
    "RUN:", "WORDS:", "PENDING WORDS:", "OUTPUT STALL CYCLES:",
    "INPUT STALL CYCLES:", "MISMATCHES:", "PROTOCOL ERRORS:", "COVERAGE:",
    "THROUGHPUT:", "RESULT:",
]


def sim_verdict(rc, nonce):
    """The verdict comes from the checker, not from a string in the log.
    The simulator exits non-zero when the checker fails, and a pass has to be
    backed by the checker's whole report, each line once and RESULT last. That
    is not proof against a testbench someone rewrote to lie, which is why the
    checker, the model and the top are outside the agent's edit scope; it does
    stop a stray print or an early $finish from reading as a pass."""
    text = read_log("sim.log")
    if rc != 0:
        print("SIM FAILED")
        return rc
    if len(re.findall(r"^RUN:\s*%d\s*$" % nonce, text, re.M)) != 1:
        print("SIM INCONCLUSIVE (the report does not carry this run's token; see build/sim.log)")
        return 1
    seen = {}
    for marker in REPORT_LINES:
        hits = [m.start() for m in re.finditer("^" + re.escape(marker), text, re.M)]
        if len(hits) != 1:
            print(f"SIM INCONCLUSIVE ({len(hits)} {marker} lines in build/sim.log, expected 1)")
            return 1
        seen[marker] = hits[0]
    order = [seen[marker] for marker in REPORT_LINES]
    if order != sorted(order):
        print("SIM INCONCLUSIVE (the checker report lines are out of order in build/sim.log)")
        return 1
    if not re.search(r"^RESULT:\s*PASS\s*$", text, re.M):
        print("SIM FAILED")
        return 1
    return 0


def cmd_cov(hdl, extra):
    # Coverage is the functional coverage the checker collects. Full means every
    # point was hit at least once; the line reads "COVERAGE: hit/total".
    rc = cmd_sim(hdl, extra)
    lines = re.findall(r"^COVERAGE:\s*(\d+)/(\d+)", read_log("sim.log"), re.M)
    if len(lines) != 1:
        print(f"COVERAGE INCOMPLETE ({len(lines)} COVERAGE lines in build/sim.log, expected 1)")
        return rc or 1
    hit, total = int(lines[0][0]), int(lines[0][1])
    if rc == 0 and hit == total:
        print(f"COVERAGE FULL ({hit}/{total})")
        return 0
    print(f"COVERAGE INCOMPLETE ({hit}/{total})")
    return rc or 1


def yosys_command():
    """Yosys as a command list: YOSYS from the environment, yosys or
    yowasp-yosys on PATH, else the yowasp_yosys Python package if installed."""
    for name in ([os.environ["YOSYS"]] if os.environ.get("YOSYS") else []) + ["yosys", "yowasp-yosys"]:
        found = shutil.which(name)
        if found:
            return [found]
    try:
        import yowasp_yosys  # noqa: F401
    except ImportError:
        return None
    return [sys.executable, "-c", "import sys, yowasp_yosys; sys.exit(yowasp_yosys.run_yosys(sys.argv[1:]))"]


def cmd_synth(hdl, extra):
    """Vendor neutral synthesis with Yosys: proves the RTL is synthesisable and
    reports the cell count and any inferred latches. VHDL goes through
    ghdl --synth to a Verilog netlist first, so no Yosys plugin is needed."""
    ensure_build()
    log = os.path.join(BUILD, "synth.log")
    yosys = yosys_command()
    if yosys is None:
        print("error: yosys not found. Install it, set YOSYS in the environment, or pip install yowasp-yosys.")
        return 127
    if hdl == "vhdl":
        netlist = os.path.join(BUILD, "synth_vhdl.v")
        ghdl_log = os.path.join(BUILD, "synth_ghdl.log")
        cmd = [tool("ghdl"), "--synth"] + GHDL_FLAGS + ["--out=verilog"] + VHDL_RTL + ["-e", "axis_width_conv"]
        print("$ " + " ".join(cmd) + " > " + netlist, flush=True)
        try:
            with open(netlist, "w", encoding="utf-8") as out, open(ghdl_log, "w", encoding="utf-8") as err:
                rc = subprocess.call(cmd, stdout=out, stderr=err, timeout=TIMEOUT)
        except FileNotFoundError:
            print("error: ghdl not found. Install it or set GHDL in the environment.")
            return 127
        except subprocess.TimeoutExpired:
            print(f"error: ghdl --synth killed after {TIMEOUT}s. Set RUN_TIMEOUT to allow longer.")
            return 124
        sys.stdout.write(read_log("synth_ghdl.log"))
        if rc != 0:
            print("SYNTH FAILED (ghdl --synth, see build/synth_ghdl.log)")
            return rc
        read_cmd = "read_verilog " + netlist.replace(os.sep, "/")
    else:
        read_cmd = "read_verilog -sv " + SV_RTL[0]
    # The latch verdict comes from Yosys itself, not from parsing its
    # statistics: select -list writes one line per matching cell, and an
    # unreadable file counts as a failure rather than as zero latches.
    latch_file = os.path.join(BUILD, "latches.txt")
    # Remove the previous report first: a run that dies before the tee must
    # not be judged against the last run's latch list.
    if os.path.exists(latch_file):
        os.remove(latch_file)
    latch_file = latch_file.replace(os.sep, "/")
    script = (read_cmd + "; synth -top axis_width_conv; stat"
              + "; tee -q -o " + latch_file
              + " select -list t:$_DLATCH_* t:$_DLATCHSR_* t:$_SR_*")
    # Yosys writes its own log: its stdout is lost through a pipe when it runs
    # from the wasm package, so the file is the record and the summary below
    # is what the terminal shows.
    rc = run(yosys + ["-q", "-l", log, "-p", script])
    text = read_log("synth.log")
    if "Printing statistics" in text:
        sys.stdout.write(text[text.rfind("Printing statistics"):].split("Time spent")[0])
    for line in re.findall(r"^(?:Warning|ERROR):.*$", text, re.M):
        print(line)
    stats = text[text.rfind("Printing statistics"):] if "Printing statistics" in text else ""
    cells = count_stat(stats, r"cells")
    flops = sum_stat(stats, r"\$_[SA]?DFF\w*_")
    warnings = len(re.findall(r"^Warning:", text, re.M))
    latches = latch_count()
    # A module with no logic prints no cells line at all: that is 0 cells.
    print(f"CELLS: {cells if cells is not None else 0}")
    print(f"FLOPS: {flops}")
    print(f"LATCHES: {latches if latches is not None else 'unknown'}")
    print(f"WARNINGS: {warnings}")
    if rc != 0 or not stats:
        print("SYNTH FAILED")
        return rc or 1
    if latches is None:
        print("SYNTH FAILED (no latch report from Yosys, see build/synth.log)")
        return 1
    if latches:
        print("SYNTH FAILED (latches inferred)")
        return 1
    if not cells or not flops:
        # A width converter holds state and does arithmetic on it. A netlist
        # with no cells or no flops is an empty module, however well the
        # simulation appeared to go.
        print("SYNTH FAILED (empty netlist: no cells or no flops)")
        return 1
    print("SYNTH OK")
    return 0


def latch_count():
    """Latches Yosys itself selected, one per line in build/latches.txt.
    None means the report is missing: that is a failure, not zero."""
    path = os.path.join(BUILD, "latches.txt")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return len([line for line in f if line.strip()])


# Yosys has printed its statistics as "count name" and as "name count" over
# the versions the README supports, so both are read and neither is assumed.
def count_stat(stats, name):
    m = re.search(r"^\s*(\d+)\s+" + name + r"\s*$", stats, re.M)
    if m:
        return int(m.group(1))
    m = re.search(r"^\s*Number of " + name + r":\s*(\d+)\s*$", stats, re.M)
    return int(m.group(1)) if m else None


def sum_stat(stats, cell):
    total = sum(int(n) for n in re.findall(r"^\s*(\d+)\s+" + cell + r"\s*$", stats, re.M))
    total += sum(int(n) for n in re.findall(r"^\s*" + cell + r"\s+(\d+)\s*$", stats, re.M))
    return total


def cmd_impl(hdl, extra):
    ensure_build()
    log = os.path.join(BUILD, "impl.log")
    rc = run([tool("vivado"), "-mode", "batch", "-log", log, "-journal", os.path.join(BUILD, "impl.jou"),
              "-source", "scripts/impl.tcl", "-tclargs", hdl] + extra)
    log_text = read_log("impl.log")
    latches = re.search(r"^LATCHES: (\d+)$", log_text, re.M)
    if latches is None:
        print("IMPL FAILED: no latch count in the log")
        return rc or 1
    if int(latches.group(1)) != 0:
        print(f"IMPL FAILED: {latches.group(1)} latch(es) inferred; the design must be fully synchronous")
        return rc or 1
    if "TIMING MET" not in log_text:
        return rc or 1
    return rc


# The tools each track needs, and the flag that makes each one print a version.
# vivado is listed separately because only impl needs it.
PREFLIGHT = {
    "sv":   [("iverilog", ["-V"]), ("vvp", ["-V"])],
    "vhdl": [("ghdl", ["--version"])],
}


def cmd_preflight(hdl, extra):
    """Report which tools are installed, before an agent spends attempts on it.

    An agent told to run a simulator that is not there will work around it
    rather than report it, so this is worth running by hand once after cloning.
    Missing vivado is a warning, not a failure: everything except impl runs
    without it.
    """
    def probe(name, flag):
        path = tool(name)
        try:
            out = subprocess.run([path] + flag, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            return None
        text = (out.stdout or "") + (out.stderr or "")
        return (path, text.strip().splitlines()[0] if text.strip() else "version unknown")

    missing = []
    for name, flag in PREFLIGHT[hdl]:
        found = probe(name, flag)
        if found is None:
            print(f"MISSING  {name}: not on PATH, and {name.upper()} in the environment "
                  f"does not point at a working one either")
            missing.append(name)
        else:
            print(f"found    {name}: {found[1]}")

    yosys = yosys_command()
    if yosys is None:
        print("MISSING  yosys: not on PATH, YOSYS is not set, and yowasp-yosys is not installed")
        missing.append("yosys")
    else:
        out = subprocess.run(yosys + ["-V"], capture_output=True, text=True)
        text = ((out.stdout or "") + (out.stderr or "")).strip()
        print(f"found    yosys: {text.splitlines()[0] if text else 'version unknown'}")

    vivado = probe("vivado", ["-version"])
    if vivado is None:
        print("absent   vivado: impl will not run; every other command will")
    else:
        print(f"found    vivado: {vivado[1]}")

    if missing:
        print(f"PREFLIGHT FAILED: install {', '.join(missing)}, or set "
              f"{', '.join(m.upper() for m in missing)} to the full path")
        return 1
    print("PREFLIGHT OK")
    return 0


# Files the exercise depends on being what it shipped. The prompt asks the
# agent not to edit them; guard checks whether that held, so the request does
# not have to be taken on trust.
TRUSTED = [
    "tb/checker.sv", "tb/checker.vhd",
    "tb/ref_model.sv", "tb/ref_model.vhd",
    "tb/tb_top.sv", "tb/tb_top.vhd",
    "tb/fault.sv", "tb/fault.vhd",
    "run.py", "scripts/impl.tcl", "scripts/acceptance.py",
    "docs/axis_width_conv.md",
    "constraints/axis_width_conv.xdc",
]


def cmd_guard(hdl, extra):
    """Fail if any trusted file differs from what git has recorded.

    This is the check behind the do not edit list. It is a working tree
    comparison, so it catches an edit whether it was made by an agent, by an
    editor or by hand, and it does not care which tool ran. Commit your own
    changes to these files first if you meant to make them: guard compares
    against HEAD, not against the upstream repository.
    """
    missing = [f for f in TRUSTED if not os.path.exists(f)]
    if missing:
        for f in missing:
            print(f"GUARD: {f} is missing")
        print("GUARD FAILED")
        return 1
    git = shutil.which("git")
    if git is None:
        print("GUARD: git is not on PATH, so the trusted files cannot be compared")
        print("GUARD FAILED")
        return 1
    proc = subprocess.run([git, "status", "--porcelain", "--"] + TRUSTED,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        print("GUARD: git could not read this directory; is it a clone of the repository?")
        print("GUARD FAILED")
        return 1
    changed = [line[3:].strip().strip('"') for line in proc.stdout.splitlines() if line.strip()]
    if changed:
        for f in changed:
            print(f"GUARD: {f} has been modified")
        print("GUARD FAILED: a file the exercise depends on was changed; "
              "run git diff on it, and git checkout -- it to put it back")
        return 1
    print(f"GUARD OK: {len(TRUSTED)} trusted files unchanged")
    return 0


def cmd_clean(hdl, extra):
    for path in [BUILD, ".Xil"]:
        shutil.rmtree(path, ignore_errors=True)
    for pattern in ["*.jou", "*.log", "*.str", "clockInfo.txt", "dfx_runtime.txt"]:
        for path in glob.glob(pattern):
            os.remove(path)
    return 0


COMMANDS = {"preflight": cmd_preflight, "lint": cmd_lint, "sim": cmd_sim, "cov": cmd_cov,
            "synth": cmd_synth, "impl": cmd_impl, "guard": cmd_guard, "clean": cmd_clean}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=sorted(COMMANDS))
    parser.add_argument("--hdl", choices=["sv", "vhdl"], default=os.environ.get("HDL", "sv"))
    args, extra = parser.parse_known_args()
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    sys.exit(COMMANDS[args.command](args.hdl, extra))


if __name__ == "__main__":
    main()
