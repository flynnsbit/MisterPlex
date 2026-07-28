#!/usr/bin/env python3
"""Every gate must reject an argument it does not understand.

Failure mode, measured on `w-cast-play-state` `667a237` and baseline
`ddb7c97`: `check_rtl_module_instantiations.py` there contains **zero**
`add_argument` calls and never references `sys.argv`. It therefore accepted

    --root h264_decode_core --require totally_bogus_module_xyz

discarded both, checked `root=emu` instead, and printed
`RTL_MODULE_INSTANTIATION_OK` with rc=0. **A module that exists nowhere in the
repository passed.**

This is a distinct class from print/exit divergence (`check_gate_exit_contract`).
There, a gate admits in text that it cannot evaluate. Here the gate emits an
ordinary, plausible pass line, having answered a question nobody asked. The only
way to tell it from a real green is to re-run with a deliberately bogus argument
-- which is exactly why it must be mechanical rather than remembered.

The contract, one of:
  * uses `argparse` and calls `parse_args()`   -- argparse rejects unknown flags
  * calls `strict_argv.refuse_unrecognised_argv()` -- for scripts taking no args

`parse_known_args()` is a violation: it is argparse's opt-out from the very
check this gate exists to require.

Declared limit: this proves the *plumbing* refuses unknown input. It cannot
prove a flag that is parsed is also honoured -- a script could `add_argument`
and ignore the value. `--require <nonexistent>` self-tests cover that for
individual gates; see tests/unit/test_rtl_require_root_guard.py.
"""
from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FAIL, OK, REFUSED = 1, 0, 2

# Not gates: they are imported, or are fixtures whose argv shape is their caller's
# business. strict_argv is the helper itself.
EXEMPT = {
    "strict_argv.py",
    "fit_report_binding.py",
    "check_argv_contract.py",
}


def uses_parse_args(tree: ast.AST) -> bool:
    return any(
        isinstance(n, ast.Call)
        and getattr(n.func, "attr", None) == "parse_args"
        for n in ast.walk(tree)
    )


def uses_parse_known_args(tree: ast.AST) -> bool:
    return any(
        isinstance(n, ast.Call)
        and getattr(n.func, "attr", None) == "parse_known_args"
        for n in ast.walk(tree)
    )


def uses_refusal(tree: ast.AST) -> bool:
    for n in ast.walk(tree):
        if not isinstance(n, ast.Call):
            continue
        name = getattr(n.func, "attr", None) or getattr(n.func, "id", None)
        if name == "refuse_unrecognised_argv":
            return True
    return False


def reads_argv(tree: ast.AST) -> bool:
    for n in ast.walk(tree):
        if isinstance(n, ast.Attribute) and n.attr == "argv":
            return True
    return False


def is_executable(tree: ast.AST) -> bool:
    """A module nobody runs cannot be handed a flag.

    Import-only helpers have no `__main__` guard and no `main()`. Requiring argv
    handling from them would be a false red of exactly the family this gate
    exists to catch, so they are classified LIBRARY and counted in Scope --
    excluded visibly, never silently.
    """
    for node in ast.walk(tree):
        if isinstance(node, ast.If):
            test = node.test
            if (isinstance(test, ast.Compare)
                    and isinstance(test.left, ast.Name)
                    and test.left.id == "__name__"):
                return True
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "main":
            return True
    return False


def classify(path: Path) -> tuple[str, str]:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8", errors="ignore"))
    except SyntaxError as exc:
        return "UNPARSED", f"{exc}"
    if not is_executable(tree):
        return "LIBRARY", "import-only module: no __main__ guard and no main()"
    if uses_parse_known_args(tree):
        return "ACCEPTS_UNKNOWN", ("calls parse_known_args(), which is argparse's "
                                   "opt-out from rejecting unknown flags")
    if uses_parse_args(tree):
        return "ARGV_OK", "argparse parse_args() rejects unknown flags"
    if uses_refusal(tree):
        return "ARGV_OK", "refuses unrecognised argv explicitly"
    if reads_argv(tree):
        return "MANUAL_ARGV", ("reads sys.argv without argparse and without an "
                               "explicit refusal; unknown flags are discarded")
    return "IGNORES_ARGV", ("never reads sys.argv, so any flag passed to it is "
                            "discarded in silence and the result answers a "
                            "different question than the one asked")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scripts-dir", type=Path, default=ROOT / "scripts")
    ap.add_argument("--show-ok", action="store_true")
    args = ap.parse_args()

    files = sorted(p for p in args.scripts_dir.glob("*.py") if p.name not in EXEMPT)
    verdicts = [(p, *classify(p)) for p in files]
    bad = [v for v in verdicts if v[1] in {"IGNORES_ARGV", "MANUAL_ARGV",
                                           "ACCEPTS_UNKNOWN"}]
    okc = sum(1 for v in verdicts if v[1] == "ARGV_OK")
    lib = sum(1 for v in verdicts if v[1] == "LIBRARY")
    unparsed = sum(1 for v in verdicts if v[1] == "UNPARSED")

    print(f"Scope: scripts_scanned={len(files)} argv_ok={okc} "
          f"ignores_argv={sum(1 for v in bad if v[1] == 'IGNORES_ARGV')} "
          f"manual_argv={sum(1 for v in bad if v[1] == 'MANUAL_ARGV')} "
          f"accepts_unknown={sum(1 for v in bad if v[1] == 'ACCEPTS_UNKNOWN')} "
          f"libraries={lib} unparsed={unparsed}")

    if not files:
        print("ARGV_CONTRACT_REFUSED: no scripts scanned; a contract proved over "
              "nothing is not a pass", file=sys.stderr)
        return REFUSED

    for path, verdict, why in verdicts:
        if verdict in {"IGNORES_ARGV", "MANUAL_ARGV", "ACCEPTS_UNKNOWN"}:
            print(f"{verdict} {path.name} -- {why}")
        elif args.show_ok:
            print(f"ARGV_OK {path.name} -- {why}")

    if bad:
        print(
            f"ARGV_CONTRACT_FAIL: {len(bad)} script(s) silently discard arguments "
            "they were given. Measured instance: a reachability gate with no "
            "argparse returned rc=0 for --require totally_bogus_module_xyz. Use "
            "argparse parse_args(), or strict_argv.refuse_unrecognised_argv() "
            "for scripts that take none.",
            file=sys.stderr,
        )
        return FAIL

    print(f"ARGV_CONTRACT_OK scripts={len(files)} argv_ok={okc} libraries={lib} "
          f"-- proves unknown input is refused, NOT that a parsed flag is honoured")
    return OK


if __name__ == "__main__":
    raise SystemExit(main())
