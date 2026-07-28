#!/usr/bin/env python3
"""Pre-fit elaboration check: which modules actually survive elaboration of the
product top, given exactly the files Quartus is handed.

RULING 3 condition 4 asked for "the intended decode modules present in a pre-fit
elaboration check".  Nothing in the repository did that.  What we had was:

  * check_rtl_module_instantiations.py -- source/regex level.  w-audit measured
    it false-GREEN on an instantiation inside a disabled `if (0)` generate and
    false-RED on an escaped identifier.
  * check_qip_coverage.py -- filename level.  Proves a file is compiled, not
    that a module is instantiated.
  * make post-fit-hierarchy -- the real oracle, but only available AFTER a six
    hour fit, which is exactly the cost we are trying not to pay twice.

This gate sits in the gap.  It elaborates `emu` with Verilator using the file
list parsed out of files.qip and reports which modules exist in the elaborated
design.  Being an elaborator rather than a regex, it is immune to all three of
the known source-level blind spots at once:

  disabled generate      -> the instance elaborates away        -> ABSENT
  escaped identifier     -> the elaborator resolves it properly -> PRESENT
  file absent from .qip  -> never compiled                      -> ABSENT
  core orphaned from emu -> not reachable from the top          -> ABSENT

SCOPE -- READ BEFORE CITING THIS GATE FOR A PRODUCT CLAIM.

This gate detects failure modes 1 and 2 ONLY:

  1. not compiled      -- file missing from files.qip
  2. not instantiated  -- module orphaned from the product top

It CANNOT detect failure mode 3 -- compiled, instantiated, elaborated, and then
deleted by synthesis because the outputs drive nothing observable.  That is not
a theoretical gap.  w-fit-o5 measured it with Quartus Analysis & Synthesis:

  this gate on w-deblock-o5-converge   h264_decode_core PRESENT
  Quartus A&S on the same source       h264_decode_core ABSENT,
                                       ELABORATED_BUT_OPTIMIZED_AWAY

Verilator elaborates the instance faithfully and Quartus then removes it, so a
GREEN here is fully compatible with a bitstream containing no decoder -- which
is exactly how fb4bad84 shipped.  I originally offered this gate as satisfying
RULING 3 condition 4.  That claim was too strong and is withdrawn: it is a
cheap pre-filter, not an elaboration oracle.

For mode 3 use scripts/check_deadlogic_sink.py (fast, no Quartus, conservative)
and scripts/check_prefit_elaboration.sh (Quartus A&S, w-fit-o5, authoritative
pre-fit).  make post-fit-hierarchy remains the only final oracle.

Exit codes: 0 pass, 1 fail, 77 skip (never a pass), 2 usage error.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QIP = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
FPGA = ROOT / "fpga" / "Plex_MiSTer"
BLACKBOX = ROOT / "tests" / "rtl" / "prefit_blackbox" / "altera_blackbox.sv"
RUN_VERILATOR = ROOT / "scripts" / "run_verilator.sh"

# Vendor primitives that ship inside Quartus and are therefore not tracked here.
# Both are LEAVES: stubbing them cannot make an absent decode module present.
# Nothing else may be blackboxed -- if a non-vendor module goes missing that is
# a real file-list defect and this gate must fail, not paper over it.
ALLOWED_BLACKBOX = {"altera_pll", "altddio_out"}

# hps_io.sv is MiSTer framework code that Quartus accepts and Verilator does not
# like.  Waiving this one Verilator-specific strictness rule does not affect
# which modules elaborate.
WAIVERS = ["-Wno-fatal", "-Wno-PROCASSWIRE"]


def fail(msg: str) -> int:
    print(f"PREFIT_HIER_FAIL: {msg}", file=sys.stderr)
    return 1


def skip(msg: str) -> int:
    # A skip is not a pass.  77 is the project's skip code and callers are
    # expected to treat it as "not proven", never as green.
    print(f"SKIP-NOT-PASS check_prefit_hierarchy: {msg}", file=sys.stderr)
    return 77


def qip_sources() -> list[Path]:
    """Exactly the RTL Quartus is handed, in files.qip order."""
    out: list[Path] = []
    pattern = re.compile(
        r"^set_global_assignment\s+-name\s+(?:SYSTEMVERILOG_FILE|VERILOG_FILE)\s+(\S+)"
    )
    for line in QIP.read_text().splitlines():
        m = pattern.match(line.strip())
        if m:
            out.append(FPGA / m.group(1))
    return out


def blackbox_modules() -> set[str]:
    """Modules actually declared in the stub file.

    w-fit-o5's ALLOWED_ABSENT allowlist is a hand-maintained attack surface and
    said so up front.  The equivalent hole here would be someone adding a decode
    module to the blackbox file so it always elaborates.  Checking the file's
    contents against the allowlist closes it.
    """
    if not BLACKBOX.is_file():
        return set()
    return set(re.findall(r"^\s*module\s+(\w+)", BLACKBOX.read_text(), re.M))


def demangle(name: str) -> str:
    """Vemu_<module>.h carries Verilator's parameter mangling.

    h264_dpb_one_ref__F140_FBf0 -> h264_dpb_one_ref
    h264_deblock_writeback_ctrl__pi2 -> h264_deblock_writeback_ctrl
    Verified: no module declared under fpga/Plex_MiSTer/rtl contains '__'.
    """
    return name.split("__", 1)[0]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--top", default="emu", help="Product top module (default: emu).")
    ap.add_argument(
        "--require",
        action="append",
        default=[],
        help="Module that must be present in the elaborated hierarchy.",
    )
    ap.add_argument(
        "--forbid",
        action="append",
        default=[],
        help="Module that must NOT be present (e.g. a retired painter).",
    )
    ap.add_argument("--label", default="prefit", help="Label for the scope line.")
    ap.add_argument(
        "--mdir",
        default="build/prefit_hier",
        help="Verilator output directory (relative to repo root).",
    )
    args = ap.parse_args(argv)

    if not QIP.is_file():
        return fail(f"missing {QIP.relative_to(ROOT)}")
    if not RUN_VERILATOR.is_file():
        return skip(f"missing {RUN_VERILATOR.relative_to(ROOT)}")

    declared = blackbox_modules()
    rogue = sorted(declared - ALLOWED_BLACKBOX)
    if rogue:
        return fail(
            "blackbox stub file declares modules outside the vendor allowlist: "
            + ", ".join(rogue)
            + " -- a stub can make an absent module look present, so only leaf "
            "vendor primitives may live there"
        )

    sources = qip_sources()
    missing = [p for p in sources if not p.is_file()]
    if missing:
        return fail(
            "files.qip lists files that do not exist: "
            + ", ".join(str(p.relative_to(ROOT)) for p in missing)
        )

    mdir = ROOT / args.mdir
    prefix_h = f"V{args.top}_"
    # Purge previously generated headers before verilating.
    #
    # Without this the gate is a no-op detector: Verilator only writes the
    # modules that survive elaboration, it does not delete the ones that no
    # longer do, so a stale header from an earlier green run makes a mutated
    # tree look green.  The disabled-generate red proof caught exactly that on
    # this gate's first run -- w-audit's "exits 0 without doing any work" class,
    # in a gate written to defend against that class.
    stale = 0
    if mdir.is_dir():
        for f in list(mdir.iterdir()):
            if f.is_file() and f.name.startswith(prefix_h) and f.suffix == ".h":
                f.unlink()
                stale += 1

    inc = ROOT / "build" / "prefit_inc"
    inc.mkdir(parents=True, exist_ok=True)
    # Quartus generates build_id.v via a PRE_FLOW_SCRIPT (sys/build_id.tcl).
    # It carries a date string only; the value cannot affect elaboration.
    (inc / "build_id.v").write_text('`define BUILD_DATE "000000"\n')

    cmd = [
        str(RUN_VERILATOR),
        "--cc",
        "-fno-inline",
        "--top-module",
        args.top,
        "--Mdir",
        str(mdir),
        *WAIVERS,
        f"-I{inc}",
        "-y", str(FPGA / "rtl"),
        "-y", str(FPGA),
        "-y", str(FPGA / "sys"),
        "-y", str(FPGA / "rtl" / "pll"),
        "+libext+.sv+.v",
    ]
    if BLACKBOX.is_file():
        cmd.append(str(BLACKBOX))
    cmd += [str(p) for p in sources]

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    except FileNotFoundError:
        return skip("verilator wrapper not executable")
    if "Invalid option" in proc.stderr or "not found" in proc.stderr.lower():
        if proc.returncode != 0 and "%Error" not in proc.stderr:
            return skip(f"verilator unavailable: {proc.stderr.strip()[:200]}")

    log = ROOT / "build" / f"prefit-hier-{args.label}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(proc.stdout + proc.stderr)

    if proc.returncode != 0:
        modmissing = sorted(set(re.findall(r"Cannot find file containing module: '(\w+)'", proc.stderr)))
        detail = ""
        if modmissing:
            detail = (
                " -- modules with no source: "
                + ", ".join(modmissing)
                + ". These are NOT auto-stubbed: either the file is missing from "
                "files.qip or it is a new vendor leaf that needs an explicit "
                "allowlist entry."
            )
        return fail(
            f"elaboration of top '{args.top}' failed (rc={proc.returncode}); "
            f"see {log.relative_to(ROOT)}{detail}"
        )

    if not mdir.is_dir():
        return fail(f"verilator produced no output directory {args.mdir}")

    present: set[str] = set()
    for f in mdir.iterdir():
        if f.suffix == ".h" and f.name.startswith(prefix_h):
            stem = f.name[len(prefix_h) : -len(".h")]
            if stem.startswith("_"):  # __024root, _pch
                continue
            present.add(demangle(stem))
    present.add(args.top)

    # Non-vacuity: if the purge removed headers and verilation regenerated
    # nothing, every --require would report ABSENT for the wrong reason, and an
    # empty --require list would report a meaningless green.
    if len(present) <= 1:
        return fail(
            f"elaboration produced {len(present)} module header(s) in {args.mdir}; "
            f"the gate has nothing to inspect and cannot prove anything "
            f"(purged {stale} stale header(s) before running)"
        )

    absent = [m for m in args.require if m not in present]
    forbidden = [m for m in args.forbid if m in present]

    print(
        f"Scope: prefit_elaborated_modules={len(present)} top={args.top} "
        f"qip_sources={len(sources)} required={len(args.require)} "
        f"absent={len(absent)} forbidden_present={len(forbidden)} "
        f"purged_stale_headers={stale}"
    )

    if absent:
        for m in absent:
            print(
                f"PREFIT_HIER_ABSENT {m} -- not in the elaborated hierarchy under "
                f"{args.top}. Source-level reachability can report this module "
                f"green; elaboration says it is not in the design.",
                file=sys.stderr,
            )
        return fail(
            f"{len(absent)}/{len(args.require)} required modules absent from the "
            f"elaborated design"
        )
    if forbidden:
        for m in forbidden:
            print(f"PREFIT_HIER_FORBIDDEN_PRESENT {m}", file=sys.stderr)
        return fail(f"{len(forbidden)} forbidden modules are still elaborated")

    req = ",".join(args.require) if args.require else "<none>"
    print(
        f"PREFIT_HIER_OK label={args.label} top={args.top} present={req} "
        f"modules={len(present)} "
        f"detects=modes_1_2_only mode3_optimized_away=UNCHECKED "
        f"(elaboration-level. A module can be PRESENT here and still be deleted "
        f"by synthesis for driving nothing observable -- measured on this very "
        f"branch for h264_decode_core. Pair with check_deadlogic_sink.py and "
        f"check_prefit_elaboration.sh; make post-fit-hierarchy remains the only "
        f"final oracle)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
