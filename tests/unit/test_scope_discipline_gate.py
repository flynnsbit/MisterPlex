#!/usr/bin/env python3
"""Red/green for the Scope-discipline ratchet.

Three questions this answers:
  * what does it literally compare -- the set of `make unit` commands whose
    source can emit a `Scope:` line, against a declared exemption manifest;
  * what does it NOT cover -- whether the denominator printed at runtime is
    non-zero, and whether it counts the right thing. Static presence of the
    line is a floor, not a proof;
  * can you make it fail -- yes, in both directions, below.
"""
from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_scope_discipline as sd  # noqa: E402


def run(argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = sd.main(argv)
    except SystemExit as exc:
        rc = int(exc.code or 0)
    return rc, out.getvalue(), err.getvalue()


def case_green() -> None:
    rc, out, err = run([])
    assert rc == 0, (out, err)
    assert out.startswith("Scope: scope_discipline_commands="), out
    assert "SCOPE_DISCIPLINE_OK" in out, out


def case_scope_zero_refused() -> None:
    """A gate over an empty command set must not be able to claim a PASS."""
    original = sd.registered_commands
    sd.registered_commands = lambda: []
    try:
        rc, _out, err = run([])
    finally:
        sd.registered_commands = original
    assert rc == 1, "an empty command set must refuse to pass"
    assert "Scope: 0" in err, err


def case_debt_cannot_grow() -> None:
    """A new unscoped command that is not declared is a hard fail."""
    original = sd.registered_commands
    sd.registered_commands = lambda: original() + ["$(ROOT)/tests/unit/expected_red.py"]
    try:
        rc, _out, err = run([])
    finally:
        sd.registered_commands = original
    assert rc == 1, "an undeclared unscoped command must fail"
    assert "SCOPE_DISCIPLINE_UNDECLARED" in err, err


def case_progress_must_be_recorded() -> None:
    """A command listed as exempt that now prints Scope: is also a hard fail."""
    original = sd.load_manifest
    sd.load_manifest = lambda: original() + ["$(ROOT)/scripts/check_rtl_module_instantiations.py"]
    try:
        rc, _out, err = run([])
    finally:
        sd.load_manifest = original
    assert rc == 1, "a stale exemption must fail so the improvement gets recorded"
    assert "SCOPE_DISCIPLINE_STALE" in err, err


def case_binary_maps_to_its_source() -> None:
    """`$(ROOT)/build/test_x` must be attributed to tests/unit/test_x.cpp."""
    sources = sd.command_sources("$(ROOT)/build/test_osd_menu")
    names = {p.name for p in sources}
    assert "test_osd_menu.cpp" in names, (
        "a compiled unit binary must be traced back to its source, otherwise every "
        f"C++ gate would be silently unattributable: {sorted(names)}"
    )
    assert sd.command_sources("$(ROOT)/build/no_such_binary_at_all") == [], (
        "an unattributable command must yield no sources, i.e. count as unscoped, "
        "never as silently exempt"
    )


def main() -> int:
    cases = [
        case_green,
        case_scope_zero_refused,
        case_debt_cannot_grow,
        case_progress_must_be_recorded,
        case_binary_maps_to_its_source,
    ]
    print(f"Scope: scope_discipline_gate_cases={len(cases)}", flush=True)
    assert cases, "Scope: 0 cannot claim a PASS"
    for case in cases:
        case()
    print(f"SCOPE_DISCIPLINE_GATE_OK cases={len(cases)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
