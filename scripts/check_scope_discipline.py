#!/usr/bin/env python3
"""Ratchet: every `make unit` command must be able to state its denominator.

The house rule is that a gate prints `Scope:` first and that `Scope: 0` cannot
claim a PASS. The rule was never enforced, so it decayed: measured on
`w-gate-hour28`, a full `make unit` run emits 19 `Scope:` lines across 98
registered commands. A command that never prints a denominator is a command that
can exit 0 having compared nothing, which is this project's dominant failure mode
(`w-audit` demonstrated 24 such paths).

Flipping the rule to a hard fail today would red the whole fleet's `make unit`,
which is worse than the disease -- a broken `make unit` blinds every worker. So
this is a **two-directional ratchet** over
`tests/unit/scope_discipline_exempt.txt`:

* a registered command that emits no `Scope:` and is **not** listed is a hard
  fail (`SCOPE_DISCIPLINE_UNDECLARED`) -- the debt cannot grow;
* a listed command that **has** since gained a `Scope:` line is also a hard fail
  (`SCOPE_DISCIPLINE_STALE`) -- progress must be recorded, so the manifest diff
  is the evidence and the number can only move deliberately.

This is a *static* scan of each command's source, not a runtime observation: it
answers "can this command state a denominator at all", not "did it state a
non-zero one on this run". Runtime `Scope: 0` remains the individual gate's
responsibility. Refresh with --update-baseline.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tests" / "unit" / "scope_discipline_exempt.txt"

sys.path.insert(0, str(ROOT / "tests" / "unit"))


def fail(msg: str) -> None:
    print(f"SCOPE_DISCIPLINE_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def registered_commands() -> list[str]:
    import test_unit_rollcall as rollcall  # noqa: PLC0415

    return list(rollcall.EXPECTED_COMMANDS)


def command_sources(command: str) -> list[Path]:
    """Every tracked source file a registered `make unit` command runs.

    A `$(ROOT)/build/test_x` entry is a compiled binary; its evidence lives in
    `tests/unit/test_x.cpp`. The `build/` mapping is tried *first* and the binary
    itself is never read: a stale object file still contains the string literals
    of whatever source last built it, which would let a deleted `Scope:` line keep
    reporting green. Returning [] means "cannot attribute a source", which is
    treated as *no* Scope evidence rather than silently exempted.
    """
    text = command.replace("$(ROOT)/", "").replace("$(ROOT)", "")
    out: list[Path] = []
    for token in re.findall(r"[\w./-]+", text):
        if token in {"bash", "python3", "sh", "make", "env"}:
            continue
        if token.startswith("build/"):
            stem = token[len("build/") :]
            for ext in (".cpp", ".c", ".cc"):
                src = ROOT / "tests" / "unit" / f"{stem}{ext}"
                if src.is_file():
                    out.append(src)
                    break
            continue
        candidate = ROOT / token
        if candidate.is_file():
            out.append(candidate)
    return out


def emits_scope(paths: list[Path]) -> bool:
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if re.search(r"""Scope:""", text):
            return True
    return False


def load_manifest() -> list[str]:
    if not MANIFEST.exists():
        return []
    out = []
    for raw in MANIFEST.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out


def classify(commands: list[str]) -> tuple[list[str], list[str]]:
    scoped, unscoped = [], []
    for command in commands:
        (scoped if emits_scope(command_sources(command)) else unscoped).append(command)
    return scoped, unscoped


def write_manifest(unscoped: list[str]) -> None:
    header = (
        "# `make unit` commands that do not yet print a `Scope:` denominator.\n"
        "# Two-directional ratchet, enforced by scripts/check_scope_discipline.py:\n"
        "#   * an unscoped command missing from this list is a hard fail (debt cannot grow);\n"
        "#   * a listed command that has gained a `Scope:` line is also a hard fail\n"
        "#     (progress must be recorded here, so the diff is the evidence).\n"
        "# Shrinking this file is the goal. Regenerate with:\n"
        "#   python3 scripts/check_scope_discipline.py --update-baseline\n"
    )
    MANIFEST.write_text(header + "\n".join(sorted(unscoped)) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--update-baseline", action="store_true")
    args = ap.parse_args(argv)

    commands = registered_commands()
    scoped, unscoped = classify(commands)
    print(
        "Scope: scope_discipline_commands=%d scoped=%d unscoped=%d"
        % (len(commands), len(scoped), len(unscoped)),
        flush=True,
    )
    if not commands:
        fail("Scope: 0 registered commands; the gate cannot claim a PASS over an empty set")

    if args.update_baseline:
        write_manifest(unscoped)
        print(f"SCOPE_DISCIPLINE_BASELINE_WRITTEN entries={len(unscoped)} file={MANIFEST.relative_to(ROOT)}")
        return 0

    declared = set(load_manifest())
    undeclared = sorted(set(unscoped) - declared)
    stale = sorted(declared - set(unscoped))

    for command in undeclared:
        print(f"SCOPE_DISCIPLINE_UNDECLARED {command}", file=sys.stderr)
    for command in stale:
        print(f"SCOPE_DISCIPLINE_STALE {command}", file=sys.stderr)

    if undeclared:
        fail(
            f"{len(undeclared)} registered make-unit command(s) print no Scope: denominator and are "
            "not declared in " + str(MANIFEST.relative_to(ROOT)) + ". A command that cannot state a "
            "denominator can exit 0 having compared nothing. Add the Scope: line, or record the debt "
            "with --update-baseline and say why in your report."
        )
    if stale:
        fail(
            f"{len(stale)} command(s) now print Scope: but are still listed as exempt in "
            + str(MANIFEST.relative_to(ROOT))
            + "; rerun with --update-baseline so the improvement is recorded."
        )

    print(
        "SCOPE_DISCIPLINE_OK commands=%d scoped=%d exempt=%d"
        % (len(commands), len(scoped), len(declared))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
