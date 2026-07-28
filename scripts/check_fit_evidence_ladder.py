#!/usr/bin/env python3
"""Diagnose *why* a module is absent from a fit, not merely that it is.

The parent's ruling makes post-fit hierarchy the strongest oracle. It is -- but
"ABSENT from the fit report" is four different facts wearing one label, and they
have completely different owners and fixes. Measured on the deployed bitstream
`fb4bad849ad2db782a5004ce5a3471ce` (fit `wfit-hour27-bdiag-b`, source `5b68cc2`):

```
h264_decode_top    fit=0  map=0                          -> never compiled
h264_decode_core   fit=0  map has "Found entity" only    -> compiled, never instantiated
h264_ref_clamp     fit=0  map has "Elaborating entity ... |decode_stub:stub|
                                  h264_luma_ref_tap_addr|h264_ref_clamp"
                                                          -> instantiated, then optimised away
h264_dpb_one_ref   fit=77 hits                            -> actually in silicon
```

All four report the same "ABSENT" to a fit-report-only check. Yet the first is a
`files.qip` bug, the second an instantiation bug, the third a dead-logic /
sink bug (fix the outputs, not the instantiation), and only the fourth is a
non-problem. Telling a worker "your module is absent" without saying which rung
they are on sends them to fix the wrong thing.

The rungs, weakest to strongest:

    NOT_COMPILED    -- absent from the analysis-and-synthesis report entirely
    COMPILED_ONLY   -- "Found entity" but no "Elaborating entity"; nothing
                       instantiates it
    ELABORATED_ONLY -- elaborated into a real hierarchy path, then absent from
                       the fit report; synthesis pruned it as dead logic
    FITTED          -- present in the fit report; it is in the bitstream

This is deliberately **grep-level**, not a table parse. `w-audit` has already
broken two entity-table parsers in this repo (unbounded trailing tables, direct
children only), and a table parse can only *lose* rows relative to a raw scan.
So this instrument is independent of those defects by construction, and is meant
to be run *alongside* `make post-fit-hierarchy` as a cross-check rather than
instead of it. Where the two disagree, that disagreement is the finding.

It never runs Quartus. It reads reports someone else produced.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fit_report_binding as binding  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]

NOT_COMPILED = "NOT_COMPILED"
COMPILED_ONLY = "COMPILED_ONLY"
ELABORATED_ONLY = "ELABORATED_ONLY"
FITTED = "FITTED"
RUNGS = (NOT_COMPILED, COMPILED_ONLY, ELABORATED_ONLY, FITTED)

SKIP = 77


def fail(msg: str) -> None:
    print(f"FIT_EVIDENCE_LADDER_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def skip(msg: str) -> None:
    """Genuinely unmeasurable, e.g. no fit exists yet. Never 0, never 1."""
    print(f"SKIP-NOT-PASS fit-evidence-ladder: {msg}", file=sys.stderr)
    raise SystemExit(SKIP)


def elaborated_hierarchy(map_text: str, module: str) -> str | None:
    """The hierarchy path Quartus reported when it elaborated `module`.

    Anchored on the quoted entity name so that `h264_mv_pred_16x16` is never
    matched by a line about `h264_mv_pred_16x16_wrapper`, and so that a mention
    of the module *inside another entity's* hierarchy string does not count as
    that module being elaborated.
    """
    pattern = re.compile(
        r'Elaborating entity "' + re.escape(module) + r'" for hierarchy "([^"]*)"'
    )
    match = pattern.search(map_text)
    return match.group(1) if match else None


def was_compiled(map_text: str, module: str) -> bool:
    return re.search(r"Found entity \d+: " + re.escape(module) + r"\b", map_text) is not None


def fit_mentions(fit_text: str, module: str) -> int:
    return len(re.findall(r"\b" + re.escape(module) + r"\b", fit_text))


def classify(map_text: str, fit_text: str, module: str) -> tuple[str, str]:
    hits = fit_mentions(fit_text, module)
    if hits:
        return FITTED, f"fit_mentions={hits}"
    hierarchy = elaborated_hierarchy(map_text, module)
    if hierarchy:
        return ELABORATED_ONLY, hierarchy
    if was_compiled(map_text, module):
        return COMPILED_ONLY, "compiled but never elaborated: nothing instantiates it"
    return NOT_COMPILED, "absent from analysis-and-synthesis: check files.qip"


def rtl_module_names() -> list[str]:
    rtl_dir = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
    names: set[str] = set()
    for path in sorted(rtl_dir.rglob("*.sv")) + sorted(rtl_dir.rglob("*.v")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        names.update(re.findall(r"^\s*module\s+([A-Za-z_]\w*)", text, re.M))
    return sorted(names)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--map-rpt", required=True, help="Quartus analysis-and-synthesis report")
    ap.add_argument("--fit-rpt", required=True, help="Quartus fitter report")
    ap.add_argument("--module", action="append", default=[], help="Module to classify (repeatable)")
    ap.add_argument(
        "--require-fitted",
        action="append",
        default=[],
        help="Hard-fail unless this module reached the FITTED rung",
    )
    binding.add_binding_args(ap)
    args = ap.parse_args(argv)

    map_path, fit_path = Path(args.map_rpt), Path(args.fit_rpt)
    modules = sorted(set(args.module) | set(args.require_fitted)) or rtl_module_names()

    print(
        "Scope: fit_ladder_modules=%d map_rpt=%s fit_rpt=%s"
        % (len(modules), map_path.name, fit_path.name),
        flush=True,
    )
    if not modules:
        fail("Scope: 0 modules; the gate cannot claim a PASS over an empty set")
    if fit_path.is_file():
        bound = binding.require_binding(args, fit_path)
        if bound.rc:
            return bound.rc
    missing = [str(p) for p in (map_path, fit_path) if not p.is_file()]
    if missing:
        # No fit exists to read. That is unmeasurable, not a pass and not a
        # failure -- exactly what 77 is for.
        skip("no fit reports to read: " + ", ".join(missing))

    map_text = map_path.read_text(encoding="utf-8", errors="ignore")
    fit_text = fit_path.read_text(encoding="utf-8", errors="ignore")

    tally = dict.fromkeys(RUNGS, 0)
    verdicts: dict[str, str] = {}
    for module in modules:
        rung, detail = classify(map_text, fit_text, module)
        verdicts[module] = rung
        tally[rung] += 1
        print(f"FIT_LADDER {module} rung={rung} {detail}")

    print(
        "FIT_LADDER_SUMMARY "
        + " ".join(f"{rung.lower()}={tally[rung]}" for rung in RUNGS)
        + f" modules={len(modules)}"
    )

    shortfall = [(m, verdicts[m]) for m in args.require_fitted if verdicts[m] != FITTED]
    for module, rung in shortfall:
        print(f"REQUIRED_MODULE_NOT_FITTED {module} rung={rung}", file=sys.stderr)
    if shortfall:
        fail(
            "required modules did not reach the FITTED rung, i.e. they are not in this "
            "bitstream: "
            + ", ".join(f"{m}({r})" for m, r in shortfall)
        )

    print(f"FIT_EVIDENCE_LADDER_OK modules={len(modules)} fitted={tally[FITTED]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
