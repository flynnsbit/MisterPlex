#!/usr/bin/env python3
"""Red/green for the fit evidence ladder.

Synthetic Quartus reports, so the suite is scorable on every host and does not
depend on holding a fit. The strings are copied from the shapes actually emitted
by Quartus 17.0.2 in `wfit-hour27-bdiag-b`.
"""
from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_fit_evidence_ladder as ladder  # noqa: E402

SCRATCH = ROOT / "build" / "fit-ladder-cases"

MAP = """
Info (12021): Found 1 design units, including 1 entities, in source file rtl/mod_fitted.sv
    Info (12023): Found entity 1: mod_fitted File: /build/rtl/mod_fitted.sv Line: 3
    Info (12023): Found entity 2: mod_elaborated File: /build/rtl/mod_elaborated.sv Line: 9
    Info (12023): Found entity 3: mod_compiled_only File: /build/rtl/mod_compiled_only.sv Line: 4
    Info (12023): Found entity 4: mod_elaborated_wrapper File: /build/rtl/w.sv Line: 1
    Info (12023): Found entity 5: mod_ghost File: /build/rtl/mod_ghost.sv Line: 2
    Info (12023): Found entity 6: mod_ghost_helper File: /build/rtl/mod_ghost.sv Line: 40
Info (12128): Elaborating entity "mod_fitted" for hierarchy "emu:emu|mod_fitted:u_a"
Info (12128): Elaborating entity "mod_elaborated" for hierarchy "emu:emu|stream_path:spath|decode_stub:stub|mod_elaborated:u_b"
Info (12128): Elaborating entity "mod_ghost_helper" for hierarchy "emu:emu|mod_ghost_helper:u_h"
"""

FIT = """
; Resource Utilization by Entity                                            ;
; |emu:emu|mod_fitted:u_a                 ; 4757 ; 2298 ; 96 ;
"""


def write_reports(name: str, map_text: str = MAP, fit_text: str = FIT) -> tuple[Path, Path]:
    case = SCRATCH / name
    case.mkdir(parents=True, exist_ok=True)
    map_path, fit_path = case / "Plex.map.rpt", case / "Plex.fit.rpt"
    map_path.write_text(map_text)
    fit_path.write_text(fit_text)
    return map_path, fit_path


def run(argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    rc = 0
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = ladder.main(argv)
    except SystemExit as exc:
        rc = int(exc.code or 0)
    return rc, out.getvalue(), err.getvalue()


def base(name: str = "base") -> list[str]:
    map_path, fit_path = write_reports(name)
    return ["--map-rpt", str(map_path), "--fit-rpt", str(fit_path)]


def case_four_rungs_are_distinguished() -> None:
    rc, out, err = run(
        base()
        + [
            "--module", "mod_fitted",
            "--module", "mod_elaborated",
            "--module", "mod_compiled_only",
            "--module", "mod_absent_entirely",
        ]
    )
    assert rc == 0, (out, err)
    assert "FIT_LADDER mod_fitted rung=FITTED" in out, out
    assert "FIT_LADDER mod_elaborated rung=ELABORATED_ONLY" in out, out
    assert "FIT_LADDER mod_compiled_only rung=COMPILED_ONLY" in out, out
    assert "FIT_LADDER mod_absent_entirely rung=NOT_COMPILED" in out, out
    assert "not_compiled=1 compiled_only=1 elaborated_only=1 fitted=1" in out, out


def case_elaborated_only_reports_its_hierarchy() -> None:
    """The hierarchy is the actionable part: it names the parent to fix."""
    _rc, out, _err = run(base() + ["--module", "mod_elaborated"])
    assert "decode_stub:stub|mod_elaborated:u_b" in out, out


def case_require_fitted_fails_below_the_top_rung() -> None:
    for module, rung in (
        ("mod_elaborated", "ELABORATED_ONLY"),
        ("mod_compiled_only", "COMPILED_ONLY"),
        ("mod_absent_entirely", "NOT_COMPILED"),
    ):
        rc, _out, err = run(base() + ["--require-fitted", module])
        assert rc == 1, f"{module} must not satisfy --require-fitted"
        assert f"REQUIRED_MODULE_NOT_FITTED {module} rung={rung}" in err, err
    rc, _out, _err = run(base() + ["--require-fitted", "mod_fitted"])
    assert rc == 0, "a genuinely fitted module must pass"


def case_prefix_is_not_a_match() -> None:
    """A name that merely prefixes another entity's must not borrow its rung.

    `mod_ghost` is compiled and never elaborated; `mod_ghost_helper` is
    elaborated. An unanchored scan for "Elaborating entity .*mod_ghost.*" matches
    the helper's line and promotes `mod_ghost` a whole rung -- reporting a module
    as instantiated when nothing instantiates it, which is this project's exact
    failure mode. The match is anchored on the quoted entity name for that reason.
    """
    _rc, out, _err = run(base() + ["--module", "mod_elaborated_wrapper", "--module", "mod_ghost"])
    assert "FIT_LADDER mod_elaborated_wrapper rung=COMPILED_ONLY" in out, out
    assert "FIT_LADDER mod_ghost rung=COMPILED_ONLY" in out, (
        "mod_ghost is never elaborated; only mod_ghost_helper is. Promoting it to "
        "ELABORATED_ONLY would claim an instantiation that does not exist: " + out
    )


def case_missing_reports_skip_77_not_0() -> None:
    rc, out, err = run(
        ["--map-rpt", str(SCRATCH / "nope" / "Plex.map.rpt"),
         "--fit-rpt", str(SCRATCH / "nope" / "Plex.fit.rpt"),
         "--module", "mod_fitted"]
    )
    assert rc == 77, f"no fit to read is unmeasurable, not a pass: rc={rc}"
    assert "SKIP-NOT-PASS" in err, err
    assert out.startswith("Scope: fit_ladder_modules=1"), out


def case_scope_zero_cannot_pass() -> None:
    map_path, fit_path = write_reports("empty")
    original = ladder.rtl_module_names
    ladder.rtl_module_names = lambda: []
    try:
        rc, _out, err = run(["--map-rpt", str(map_path), "--fit-rpt", str(fit_path)])
    finally:
        ladder.rtl_module_names = original
    assert rc == 1, "Scope: 0 cannot claim a PASS"
    assert "Scope: 0 modules" in err, err


def main() -> int:
    cases = [
        case_four_rungs_are_distinguished,
        case_elaborated_only_reports_its_hierarchy,
        case_require_fitted_fails_below_the_top_rung,
        case_prefix_is_not_a_match,
        case_missing_reports_skip_77_not_0,
        case_scope_zero_cannot_pass,
    ]
    print(f"Scope: fit_ladder_gate_cases={len(cases)} rungs={len(ladder.RUNGS)}", flush=True)
    assert cases, "Scope: 0 cannot claim a PASS"
    for case in cases:
        case()
    print(f"FIT_LADDER_GATE_OK cases={len(cases)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
