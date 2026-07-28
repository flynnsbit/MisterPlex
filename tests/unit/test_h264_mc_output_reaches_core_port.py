#!/usr/bin/env python3
"""Motion compensation must survive synthesis inside the product decode core.

Three product-absence failure modes are known: a file never compiled, a module
never instantiated, and a module instantiated and elaborated and then deleted
because nothing observable depends on it. The third one has now been measured on
real silicon, and no reachability graph can see it.

The MC lineage is already proven reachable under h264_decode_core and proven
correct over a full 1170-macroblock frame. Neither of those proofs says anything
about survival: a predictor whose samples are computed and then dropped passes
both and occupies no logic. This gate asks the survival question directly - do
the outputs of h264_inter_mc_part influence any output port of the decode core -
and red-proves it by cutting the two links that carry the answer.

Scope, declared up front: this is a source-level *predictor*, not the oracle.
Quartus Analysis and Synthesis remains the arbiter. The predictor is built so it
cannot report a false "alive", which means it can report a false alarm; a false
alarm costs one A&S run, a false "alive" costs a six-hour fit and a decoder-less
bitstream. Green here is necessary and not sufficient.

Exit 0 pass, 1 fail. There is no skip path: every input is a tracked source file.
"""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
RTL = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
CHECKER = ROOT / "scripts" / "check_output_sink_liveness.py"
WORK = ROOT / "build" / "mc_sink_gate"

CORE = "h264_decode_core"
MC = "h264_inter_mc_part"
# The port that carries a reconstructed sample out of the core to the reference
# store. If MC influences nothing else, it must influence this.
RECON_PORT = "dpb_wr_data"


def owning_file(module, directory):
    """The file declaring `module`. Resolved, never spelled out: a literal RTL
    filename in a test that also names the Verilator wrapper is read by
    test_bench_rtl_filelists as a file list and must then satisfy full module
    closure."""
    pattern = re.compile(r"^\s*module\s+%s\b" % re.escape(module), re.M)
    for path in sorted(directory.glob("*.sv")):
        if pattern.search(path.read_text(errors="replace")):
            return path
    raise SystemExit("MC_SINK_ERROR: no file in %s declares %s" % (directory, module))


def run(rtl_dir=None):
    argv = [sys.executable, str(CHECKER), "--parent", CORE, "--product", MC,
            "--gate", "path-to-port"]
    if rtl_dir is not None:
        argv += ["--rtl-dir", str(rtl_dir)]
    proc = subprocess.run(argv, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def stage():
    """A private copy of the RTL to mutate. Sources are never edited in place."""
    WORK.mkdir(parents=True, exist_ok=True)
    for path in RTL.glob("*.sv"):
        shutil.copy2(path, WORK / path.name)
    return WORK


def fail(message, output):
    print("MC_SINK_FAIL: %s" % message, file=sys.stderr)
    print(output.rstrip(), file=sys.stderr)
    return 1


def main():
    rc, out = run()
    if rc != 0:
        return fail("MC outputs do not reach a port of %s on the real source" % CORE, out)
    if RECON_PORT not in out:
        return fail("MC reaches a port but not %s, so the reconstructed sample is "
                    "no longer what leaves the core" % RECON_PORT, out)
    print("OK green: %s outputs influence %s of %s" % (MC, RECON_PORT, CORE))

    rc, out = run(stage())
    if rc != 0:
        return fail("the unmutated copy is not green, so a later red proves "
                    "nothing about the mutation", out)
    print("OK control: an unmutated copy is green, so the copy is not the variable")

    core_copy = owning_file(CORE, stage())
    text = core_copy.read_text()
    cuts = 0
    for name in ("pred_y", "pred_u", "pred_v",
                 "pred_y_valid", "pred_u_valid", "pred_v_valid"):
        before = text
        text = text.replace(".%s(p16_%s)" % (name, name),
                            ".%s(p16_%s_mutcut)" % (name, name))
        cuts += before != text
    if cuts != 6:
        return fail("red proof A could not find the 6 MC output connections to "
                    "cut (found %d); the mutation is stale, not the design" % cuts, "")
    core_copy.write_text(text)
    rc, out = run(WORK)
    if rc == 0:
        return fail("red proof A: MC outputs were rewired to nets nobody reads "
                    "and the gate still passed", out)
    if "NO_PATH_TO_PORT" not in out:
        return fail("red proof A failed for the wrong reason", out)
    print("OK red A: rewiring MC outputs to unread nets is caught")

    core_copy = owning_file(CORE, stage())
    text = core_copy.read_text()
    assign = re.compile(r"assign\s+%s\s*=\s*[^;]*;" % re.escape(RECON_PORT))
    if not assign.search(text):
        return fail("red proof B could not find the driver of %s" % RECON_PORT, "")
    core_copy.write_text(assign.sub("assign %s = 8'd0;" % RECON_PORT, text))
    rc, out = run(WORK)
    if rc == 0:
        return fail("red proof B: the reconstructed sample was replaced by a "
                    "constant on the way out and the gate still passed", out)
    print("OK red B: constant-driving %s is caught" % RECON_PORT)

    proc = subprocess.run([sys.executable, str(CHECKER), "--self-test"],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        return fail("the checker's own self-test does not pass",
                    proc.stdout + proc.stderr)
    print("OK checker self-test rc=0")

    proc = subprocess.run([sys.executable, str(CHECKER), "--not-a-flag"],
                          capture_output=True, text=True)
    if proc.returncode != 2:
        return fail("the checker accepted an unrecognised argument (rc=%d); a "
                    "checker that ignores unknown flags hands out confident "
                    "greens to a wrong command line" % proc.returncode,
                    proc.stdout + proc.stderr)
    print("OK strict args: an unrecognised flag is rc=2, not a silent green")

    print("MC_SINK_OK %s -> %s -> %s survives as observable logic; predictor only, "
          "Quartus A&S remains the oracle" % (MC, CORE, RECON_PORT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
