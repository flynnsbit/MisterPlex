#!/usr/bin/env python3
"""Gate: emitted telemetry/instrument numbers must carry provenance.

Parent class (burned twice as published error):
  ERROR 17 — tools printed hardcoded src_fps=23.976 beside real measurements;
              it was promoted to a "measurement". Asset is measured 24.000.
  Live trunc — media log used std::to_string(vfps).substr(0,4) so the logged
              value could not express a fractional defect.
  av_drift_ms — pinned inside AV_PRESENT_LEAD by construction; must be labelled
              servo_error_not_lipsync, never bare next to real measurements.

Required tags on emitted values (glass_frame_ledger pattern):
  measured | caller_supplied | DEFAULT_ASSUMED
  (+ role tags where applicable, e.g. av_drift_role=servo_error_not_lipsync)

This scanner is static. Exit 0 clean, 1 findings, 2 tool broken.
--self-test plants RED then GREEN fixtures.
"""
from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Truncation that destroys measurement resolution on rate tokens.
TRUNC_SUBSTR = re.compile(
    r"""(?x)
    to_string\s*\(\s*(?P<expr>[^)]*(?:vfps|pfps|fps|drift|rate)[^)]*)\s*\)
    \s*\.\s*substr\s*\(\s*0\s*,\s*[1-4]\s*\)
    |
    # also catch: to_string(vfps).substr(0, 4) with whitespace
    (?:vfps|pfps)\s*\)\s*\.\s*substr\s*\(\s*0\s*,
    """
)

# Bare av_drift_ms= in a log/format string without role on same line or next.
AV_DRIFT_BARE = re.compile(r'av_drift_ms\s*[=:]')
AV_DRIFT_ROLE = re.compile(r"av_drift_role\s*=\s*servo_error_not_lipsync")

# Hardcoded NTSC film rate printed as if measured (ERROR 17).
BARE_23976 = re.compile(
    r"""(?x)
    (?<![\w.])(?:23\.976(?:023976)?|24000\s*/\s*1001)(?![\w.])
    """
)
PROVENANCE_OK_NEAR = re.compile(
    r"(?:DEFAULT_ASSUMED|caller_supplied|measured|src_fps_src|source_fps_src|"
    r"PROVENANCE_|ERROR\s*17|retracted|must not)"
)

# tools that emit rate/offset reports should tag provenance somewhere in file
TOOLS_REQUIRE_PROVENANCE_HINT = re.compile(
    r"(src_fps|source_fps|capture_fps|interval_ms|offset_ms)\s*="
)

SCAN_CPP = (
    "arm/**/*.cpp",
    "arm/**/*.hpp",
    "host/**/*.cpp",
    "host/**/*.hpp",
)
SCAN_PY = (
    "tools/**/*.py",
    "tests/hw/**/*.py",
    "scripts/**/*.py",
)

SKIP_NAMES = {
    "test_telemetry_provenance_guard.py",
    "w_lint_TELEMETRY_PROVENANCE.md",
    "w_lint_AV_DRIFT_BLIND.md",
}


def iter_files(globs: tuple[str, ...]) -> list[Path]:
    seen: set[Path] = set()
    out: list[Path] = []
    for pat in globs:
        for p in ROOT.glob(pat):
            if not p.is_file() or p in seen:
                continue
            if p.name in SKIP_NAMES:
                continue
            if "build" in p.parts:
                continue
            seen.add(p)
            out.append(p)
    return sorted(out)


def audit_cpp(path: Path, text: str) -> list[str]:
    rel = path.relative_to(ROOT).as_posix()
    errs: list[str] = []
    lines = text.splitlines()
    for i, line in enumerate(lines, 1):
        if TRUNC_SUBSTR.search(line):
            errs.append(f"{rel}:{i}: TRUNCATION substr on rate/telemetry token: {line.strip()[:100]}")
        if AV_DRIFT_BARE.search(line) and "av_drift_ms" in line:
            # allow comments documenting the defect
            if line.lstrip().startswith("//") or line.lstrip().startswith("*"):
                continue
            window = "\n".join(lines[max(0, i - 1) : min(len(lines), i + 3)])
            if not AV_DRIFT_ROLE.search(window):
                errs.append(
                    f"{rel}:{i}: av_drift_ms emitted without "
                    f"av_drift_role=servo_error_not_lipsync nearby"
                )
    return errs


def audit_py(path: Path, text: str) -> list[str]:
    rel = path.relative_to(ROOT).as_posix()
    errs: list[str] = []
    lines = text.splitlines()
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        m = BARE_23976.search(line)
        if m:
            window = "\n".join(lines[max(0, i - 2) : min(len(lines), i + 3)])
            if not PROVENANCE_OK_NEAR.search(window):
                errs.append(
                    f"{rel}:{i}: bare 23.976/24000/1001 without provenance label "
                    f"(ERROR 17 class): {line.strip()[:100]}"
                )
    # If tool emits src_fps= in print/report paths, require provenance vocabulary in file
    if TOOLS_REQUIRE_PROVENANCE_HINT.search(text) and path.parts[0] == "tools":
        if not re.search(
            r"caller_supplied|DEFAULT_ASSUMED|PROVENANCE_MEASURED|fps_src|src_fps_src",
            text,
        ):
            errs.append(
                f"{rel}:1: tool emits fps/rate fields but has no provenance vocabulary "
                f"(measured/caller_supplied/DEFAULT_ASSUMED)"
            )
    return errs


def run_self_test() -> int:
    errors: list[str] = []
    # RED: truncation + bare drift
    bad_cpp = (
        'log("vfps=" + std::to_string(vfps).substr(0, 4) + '
        '" av_drift_ms=" + std::to_string(d));\n'
    )
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "bad.cpp"
        p.write_text(bad_cpp)
        # inline mini audit
        errs = []
        if TRUNC_SUBSTR.search(bad_cpp):
            errs.append("trunc")
        if AV_DRIFT_BARE.search(bad_cpp) and not AV_DRIFT_ROLE.search(bad_cpp):
            errs.append("drift")
        if errs != ["trunc", "drift"]:
            errors.append(f"RBG_RED_MISS got={errs}")
        else:
            print("RBG_RED_HIT truncation+bare_av_drift")

        good_cpp = (
            'log("vfps=" + vfps_b + " vfps_src=measured"\n'
            '    " av_drift_ms=" + std::to_string(d) +\n'
            '    " av_drift_role=servo_error_not_lipsync");\n'
        )
        errs2 = []
        if TRUNC_SUBSTR.search(good_cpp):
            errs2.append("trunc")
        if AV_DRIFT_BARE.search(good_cpp) and not AV_DRIFT_ROLE.search(good_cpp):
            errs2.append("drift")
        if errs2:
            errors.append(f"RBG_GREEN_FAIL got={errs2}")
        else:
            print("RBG_GREEN_OK tagged_no_trunc")

        bad_py = "src_fps=23.976023976\nprint(src_fps)\n"
        if BARE_23976.search(bad_py) and not PROVENANCE_OK_NEAR.search(bad_py):
            print("RBG_RED_HIT bare_23976")
        else:
            errors.append("RBG_RED_MISS bare_23976")
        good_py = "src_fps=23.976  # DEFAULT_ASSUMED historical — do not treat as measured\n"
        if BARE_23976.search(good_py) and PROVENANCE_OK_NEAR.search(good_py):
            print("RBG_GREEN_OK labelled_23976")
        else:
            errors.append("RBG_GREEN_FAIL labelled_23976")

    # Real tree: media_player must not truncate vfps
    mp = ROOT / "arm" / "misterplexd" / "media_player.cpp"
    if mp.is_file():
        t = mp.read_text(encoding="utf-8", errors="replace")
        real = audit_cpp(mp, t)
        if any("TRUNCATION" in e for e in real):
            errors.append(f"REAL_TREE still truncates: {real}")
        else:
            print("RBG_REAL_OK media_player no vfps/pfps substr truncation")
        if any("av_drift_ms emitted without" in e for e in real):
            errors.append(f"REAL_TREE bare av_drift: {real}")
        else:
            print("RBG_REAL_OK media_player av_drift_role present")

    if errors:
        print("SELFTEST_FAIL")
        for e in errors:
            print(e)
        return 1
    print("SELFTEST_OK telemetry_provenance")
    return 0


def main(argv: list[str] | None = None) -> int:
    if argv and "--self-test" in argv:
        rc = run_self_test()
        print(f"true rc={rc}")
        return rc

    findings: list[str] = []
    for path in iter_files(SCAN_CPP):
        text = path.read_text(encoding="utf-8", errors="replace")
        findings.extend(audit_cpp(path, text))
    for path in iter_files(SCAN_PY):
        text = path.read_text(encoding="utf-8", errors="replace")
        findings.extend(audit_py(path, text))

    print("TELEMETRY_PROVENANCE_BEGIN")
    print(f"findings={len(findings)}")
    for f in findings:
        print(f"FIND {f}")
    print("TELEMETRY_PROVENANCE_END")

    if findings:
        print(f"TELEMETRY_PROVENANCE_FAIL count={len(findings)}")
        print("true rc=1")
        return 1
    print("TELEMETRY_PROVENANCE_OK")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
