#!/usr/bin/env python3
"""Policy gate: every fit-report reader must bind its report to a bitstream.

There are 92 `*.fit.rpt` and 99 `Plex.rbf` files on this host, and 4 of those
reports describe the build the user is actually running. A gate pointed at any
of the other 88 parses cleanly and returns a confident verdict about a build
nobody is running. That is not a parsing bug -- every number it prints is true --
so nothing downstream can detect it.

Binding is therefore not left to each author's memory. This gate finds the
report readers mechanically and fails when one of them cannot say which
bitstream it is talking about.

A reader is bound only when it does all three:
  1. imports `fit_report_binding`
  2. calls `add_binding_args(...)`   -- so `--expect-rbf-md5` exists
  3. calls `require_binding(...)`    -- so the answer is actually honoured
Importing the helper and never calling it is the vacuous case this gate exists
to catch, so all three are required.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"

# Arguments that mean "I am reading a Quartus fit/STA/synthesis report".
READER_ARGS = ("--fit-rpt", "--sta-rpt", "--map-rpt")
HELPER = "fit_report_binding"
# The helper itself and gates that only orchestrate other gates.
EXEMPT = {
    "fit_report_binding.py",
    "check_fit_report_binding_policy.py",
    # Consumes other gates' verdicts rather than parsing a report itself.
    "check_fit_request_readiness.py",
}


def reader_args(text: str) -> list[str]:
    return [arg for arg in READER_ARGS if f'"{arg}"' in text or f"'{arg}'" in text]


def binding_calls(text: str) -> tuple[bool, bool, bool]:
    imported = re.search(rf"^\s*(?:import|from)\s+{HELPER}\b", text, re.M) is not None
    adds = "add_binding_args(" in text
    requires = "require_binding(" in text
    return imported, adds, requires


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scripts-dir", type=Path, default=SCRIPTS)
    args = ap.parse_args(argv)

    candidates = sorted(p for p in args.scripts_dir.glob("*.py") if p.name not in EXEMPT)
    readers: list[tuple[Path, list[str]]] = []
    for path in candidates:
        found = reader_args(path.read_text(encoding="utf-8", errors="ignore"))
        if found:
            readers.append((path, found))

    print(
        f"Scope: scripts_scanned={len(candidates)} fit_report_readers={len(readers)} "
        f"exempt={len(EXEMPT)} reader_args={','.join(READER_ARGS)}"
    )

    if not readers:
        print(
            "FIT_BINDING_POLICY_REFUSED: found no fit-report readers at all. Either "
            "the report arguments were renamed or the detector is broken; an empty "
            "scan cannot certify a policy.",
            file=sys.stderr,
        )
        return 2

    unbound: list[str] = []
    for path, found in readers:
        text = path.read_text(encoding="utf-8", errors="ignore")
        imported, adds, requires = binding_calls(text)
        ok = imported and adds and requires
        missing = ",".join(
            name
            for name, present in (
                ("import", imported), ("add_binding_args", adds), ("require_binding", requires),
            )
            if not present
        )
        print(
            f"{'BOUND_READER' if ok else 'UNBOUND_READER'} {path.name} "
            f"args={','.join(found)} missing={missing or '<none>'}"
        )
        if not ok:
            unbound.append(f"{path.name}(missing {missing})")

    if unbound:
        print(
            "FIT_BINDING_POLICY_FAIL: these gates read a Quartus report without "
            "binding it to a bitstream, so they can be confidently correct about a "
            "build nobody is running: " + "; ".join(unbound),
            file=sys.stderr,
        )
        return 1

    print(f"FIT_REPORT_BINDING_POLICY_OK readers={len(readers)} unbound=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
