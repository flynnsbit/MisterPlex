#!/usr/bin/env python3
"""Static lint: harness false-verdict family (parent 2026-07-31 promotion gate).

Three measured false verdicts shared one disease — unstated precondition or
unvalidated capture — not a wrong threshold:

  1. Blind-and-green (historic): OK while measuring nothing.
  2. Blind-and-RED: bash $(...) strips trailing newlines so
       echo "V2_MD5=$v2_md5"  +  set +e
     fused into V2_MD5=<32hex>set +e (commit 92d4434f).
  3. Defective documented recipe: ffmpeg -frames:v 1 on USB grabber yields
     uniform grey warm-up frame (mean_rgb=7 std=0) while the live screen is
     fine; needs -vf select=gte(n\\,20) (or equivalent skip).

This scanner flags scripts under scripts/, tests/unit/, tests/hw/ for:
  A) newline/glue class — fragment concat without an explicit join helper
  B) unvalidated md5 / port captures used in equality
  C) grabber first-frame recipes without warm-up
  D) fail-fast that skips visual after cheap prior fail

Also embeds a RED historic fixture (glue) and asserts the fixed join helper
exists and rejects contaminated md5 shape — a lint that never fires is not
evidence.

Exit 0 = clean. Exit 1 = findings.
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_DIRS = (
    ROOT / "scripts",
    ROOT / "tests" / "unit",
    ROOT / "tests" / "hw",
)

# Reviewed allowlist: path relative posix -> reason
ALLOWLIST: dict[str, str] = {
    # gate_join_remote_parts is the FIX for the glue class; it deliberately
    # concatenates with explicit \\n after stripping one trailing NL.
    "scripts/promotion_gate_check.sh:gate_join_remote_parts": "explicit join helper (92d4434f)",
}

# --- patterns ----------------------------------------------------------------

# Naive remote+= / script+= / blob+= of two command substitutions adjacent.
# remote="${a}${b}" or remote="$a$b" or remote+=$(...)$(...)
ADJACENT_CMD_SUB = re.compile(
    r"""(?:
        (?:remote|script|blob|probe|cmd|ssh_cmd|remote_script|parts?)
        \s*=\s*
        ["']?\$\{?[^}"'\n]+\}?["']?\s*["']?\$\{?[^}"'\n]+\}?
      | (?:remote|script|blob|probe)\s*\+=\s*\$\(
      | ["']\$\([^)]+\)\$\([^)]+\)["']
    )""",
    re.X,
)

# $(part1)$(part2) without newline between
BARE_ADJACENT_SUBSHELL = re.compile(r"\$\([^)]+\)\$\([^)]+\)")

# md5 assigned from command then compared without shape assert nearby
MD5_ASSIGN = re.compile(
    r"""^\s*(?:local\s+)?(?P<var>\w*(?:md5|MD5|hash|HASH)\w*)\s*=\s*(?P<rhs>.+)$"""
)
MD5_COMPARE = re.compile(
    r"""\[\s*["']?\$\{?(?P<var>\w*(?:md5|MD5|hash|HASH)\w*)\}?["']?\s*[=!]=\s*"""
)
SHAPE_HELPER = re.compile(
    r"gate_assert_md5_shape|assert_md5_shape|require_md5_shape|md5_shape|"
    r"classify_obs_hash|"
    r"grep\s+-Eq\s+['\"]?\^\[0-9a-f\]\{32\}\$|\[0-9a-fA-F\]\{32\}"
)

# ffmpeg first-frame without warm-up select
FFMPEG_FRAMES1 = re.compile(
    r"""ffmpeg\b[^\n]*-frames:v\s+1\b|[^\n]*-frames\s+1\b.*ffmpeg""",
    re.I,
)
WARMUP_HINT = re.compile(
    r"""select=gte\(n|skip_frame|warm[-_]?up|drop_frames|n\\?,?\s*2[0-9]|"""
    r"""frames:v\s+2[0-9]|-sseof|select='gte""",
    re.I,
)

# Fail-fast skip visual
SKIP_VISUAL = re.compile(
    r"""(?:
        skip\s+visual
      | visual[^\n]{0,40}skipped
      | if\s+\[\s*["']?\$rc["']?\s+-ne\s+0\s*\]\s*;\s*then\s*[^\n]*visual
      | \[\[\s*\$rc\s+-ne\s+0\s*\]\]\s*&&\s*return
    )""",
    re.I | re.X,
)
VISUAL_ALWAYS = re.compile(
    r"aggregate|always\s+run\s+visual|VISUAL_REQUIRED|never skip visual",
    re.I,
)


def iter_shell_files() -> list[Path]:
    out: list[Path] = []
    for d in SCAN_DIRS:
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*")):
            if not p.is_file():
                continue
            if p.suffix in {".sh", ".bash"} or p.name.endswith(".sh"):
                # skip this lint's own fixtures if any
                if "falsegreen-probe" in p.as_posix():
                    continue
                out.append(p)
    return out


def rel(p: Path) -> str:
    try:
        return p.relative_to(ROOT).as_posix()
    except ValueError:
        return str(p)


def scan_file(path: Path) -> list[str]:
    text = path.read_text(errors="ignore")
    r = rel(path)
    findings: list[str] = []
    lines = text.splitlines()

    # A) adjacent command-sub glue
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        if "gate_join_remote_parts" in line:
            continue
        if BARE_ADJACENT_SUBSHELL.search(line) or ADJACENT_CMD_SUB.search(line):
            key = f"{r}:{i}"
            if any(k in ALLOWLIST for k in (key, f"{r}:gate_join_remote_parts")):
                continue
            # Benign if both sides are single-token path pieces without echo
            if re.search(r"\$\(dirname|\$\(basename|\$\(cd ", line):
                continue
            findings.append(
                f"{r}:{i}: GLUE_RISK adjacent $(...) or fragment concat "
                f"(bash strips trailing NL — parent V2_MD5…set +e class): {line.strip()[:120]}"
            )

    # B) md5 compare without shape in same function window
    # Heuristic: if file compares *md5* vars and never calls a shape helper,
    # and assigns md5 from $(md5sum|ssh|curl), flag once per file (not every line).
    assigns = []
    compares = []
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        m = MD5_ASSIGN.match(line)
        if m and ("$(" in m.group("rhs") or "`" in m.group("rhs")):
            assigns.append((i, m.group("var"), line.strip()))
        if MD5_COMPARE.search(line):
            compares.append((i, line.strip()))
    if assigns and compares and not SHAPE_HELPER.search(text):
        # Only flag gate/verify/promotion/regression scripts (high value)
        if any(
            k in r
            for k in (
                "promotion_gate",
                "video_regression",
                "verify",
                "deploy",
                "rollback",
                "pair_",
                "promote",
            )
        ):
            a = assigns[0]
            findings.append(
                f"{r}:{a[0]}: UNVALIDATED_MD5 assigns {a[1]} from command and "
                f"compares without shape assert (want ^[0-9a-f]{{32}}$ or gate_assert_md5_shape); "
                f"first compare at line {compares[0][0]}"
            )

    # C) ffmpeg -frames:v 1 without warm-up (single-line OR multi-line recipe)
    # Join continued shell lines for detection (backslash newlines).
    logical = []
    buf = ""
    buf_start = 1
    for i, line in enumerate(lines, 1):
        stripped = line.rstrip()
        if buf:
            buf += " " + stripped.lstrip()
        else:
            buf = stripped
            buf_start = i
        if stripped.endswith("\\"):
            buf = buf[:-1].rstrip()
            continue
        logical.append((buf_start, buf))
        buf = ""
    if buf:
        logical.append((buf_start, buf))

    for i, line in logical:
        if not (
            FFMPEG_FRAMES1.search(line)
            or (
                "ffmpeg" in line
                and re.search(r"-frames:v\s+1\b", line)
            )
        ):
            continue
        # window ±20 physical lines around start
        lo, hi = max(0, i - 20), min(len(lines), i + 20)
        window = "\n".join(lines[lo:hi])
        if WARMUP_HINT.search(window) or WARMUP_HINT.search(line):
            continue
        # Explicit anti-recipes / warnings are OK
        if re.search(
            r"DO NOT|DEFECTIVE|BAD|WRONG|warm-?up|uniform grey|false|"
            r"NOT use bare|bare -frames",
            window,
            re.I,
        ):
            continue
        # capture_hdmi_frame.sh is the fix itself
        if r.endswith("capture_hdmi_frame.sh"):
            continue
        findings.append(
            f"{r}:{i}: GRABBER_FIRST_FRAME ffmpeg -frames:v 1 without warm-up "
            f"select (USB grabber grey frame class; use select=gte(n\\,20) or "
            f"scripts/capture_hdmi_frame.sh): {line.strip()[:120]}"
        )

    # D) skip visual on prior fail
    if SKIP_VISUAL.search(text) and not VISUAL_ALWAYS.search(text):
        for i, line in enumerate(lines, 1):
            if SKIP_VISUAL.search(line) and not line.lstrip().startswith("#"):
                findings.append(
                    f"{r}:{i}: FAIL_FAST_SKIPS_VISUAL may skip highest-value "
                    f"evidence after cheap prior fail (prefer aggregate-then-verdict): "
                    f"{line.strip()[:120]}"
                )
                break

    return findings


def prove_glue_red_green() -> list[str]:
    """RED historic fixture + GREEN fixed join — must both fire."""
    errs: list[str] = []
    gate = ROOT / "scripts" / "promotion_gate_check.sh"
    if not gate.is_file():
        return [f"MISSING {rel(gate)} — cannot prove glue RBG (promotion gate required)"]

    text = gate.read_text(errors="ignore")
    if "gate_join_remote_parts" not in text:
        errs.append(f"{rel(gate)}: missing gate_join_remote_parts (92d4434f fix)")
    if "gate_assert_md5_shape" not in text:
        errs.append(f"{rel(gate)}: missing gate_assert_md5_shape")
    # Must not skip visual on prior fail
    if re.search(r"skip visual|skipping visual", text, re.I):
        # allow only if aggregate path still runs visual
        if "VISUAL_REQUIRED" not in text and "aggregate" not in text.lower():
            errs.append(f"{rel(gate)}: still has skip-visual path without aggregate")

    # Extract helpers and run shape RED/GREEN
    # shell-out small proof
    script = r'''
set -euo pipefail
GATE="$1"
# shellcheck disable=SC1090
eval "$(sed -n '/^gate_join_remote_parts()/,/^}/p;/^gate_assert_md5_shape()/,/^}/p' "$GATE")"
# Historic RED: naive concat glues set +e onto V2_MD5 echo
p1=$(printf '%s\n' 'echo "V2_MD5=$v2_md5"')
p1=$(printf '%s' "$p1")
p2=$(printf '%s\n' 'set +e' 'echo N_DAEMON=1')
glued="${p1}${p2}"
printf '%s' "$glued" | grep -Fq 'v2_md5"set +e' || {
  echo "FIXTURE_BROKEN glued repro missing"; exit 2
}
echo "RBG_RED_FIXTURE_OK glued contains v2_md5\"set +e"
joined=$(gate_join_remote_parts "$p1" "$p2")
if printf '%s' "$joined" | grep -Fq 'v2_md5"set +e'; then
  echo "RBG_JOIN_STILL_GLUED"; exit 1
fi
echo "RBG_GREEN_JOIN_OK"
set +e
gate_assert_md5_shape v2 'dfebf2bfd08dd70b473b587dd7e81848set +e'
src=$?
set -e
if [ "$src" -eq 0 ]; then echo "RBG_SHAPE_ACCEPTED_GLUE"; exit 1; fi
echo "RBG_RED_SHAPE_OK rc=$src"
set +e
gate_assert_md5_shape v2 'dfebf2bfd08dd70b473b587dd7e81848'
src=$?
set -e
if [ "$src" -ne 0 ]; then echo "RBG_SHAPE_REJECTED_GOOD"; exit 1; fi
echo "RBG_GREEN_SHAPE_OK"
'''
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
        f.write(script)
        tmp = f.name
    try:
        proc = subprocess.run(
            ["bash", tmp, str(gate)],
            capture_output=True,
            text=True,
            cwd=str(ROOT),
            check=False,
        )
    finally:
        Path(tmp).unlink(missing_ok=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    print(out.rstrip())
    if proc.returncode != 0:
        errs.append(f"glue RBG proof failed true rc={proc.returncode}")
    for need in (
        "RBG_RED_FIXTURE_OK",
        "RBG_GREEN_JOIN_OK",
        "RBG_RED_SHAPE_OK",
        "RBG_GREEN_SHAPE_OK",
    ):
        if need not in out:
            errs.append(f"glue RBG missing marker {need}")
    return errs


def prove_grabber_doc_warns() -> list[str]:
    """Docs that still teach bare -frames:v 1 without warm-up warning are RED."""
    errs: list[str] = []
    # AGENTS.md historically had the bad multi-line recipe — require warm-up
    # warning in the same section (multi-line aware).
    for doc in (
        ROOT / "AGENTS.md",
        ROOT / "docs" / "ddr-daily-promotion.md",
        ROOT / "docs" / "crt-lcd-lab-checklist.md",
    ):
        if not doc.is_file():
            continue
        text = doc.read_text(errors="ignore")
        lines = text.splitlines()
        # Build logical lines (backslash continuations)
        logical: list[tuple[int, str]] = []
        buf, buf_start = "", 1
        for i, line in enumerate(lines, 1):
            s = line.rstrip()
            if buf:
                buf += " " + s.lstrip()
            else:
                buf, buf_start = s, i
            if s.endswith("\\"):
                buf = buf[:-1].rstrip()
                continue
            logical.append((buf_start, buf))
            buf = ""
        if buf:
            logical.append((buf_start, buf))

        for i, line in logical:
            if "ffmpeg" not in line or not re.search(r"-frames:v\s+1\b", line):
                continue
            if re.search(r"select=gte|capture_hdmi_frame", line):
                continue
            window = "\n".join(lines[max(0, i - 8) : min(len(lines), i + 25)])
            if not re.search(
                r"warm-?up|select=gte|gte\(n|uniform grey|NOT\s+use bare|"
                r"bare -frames|DEFECTIVE|first frame|defective",
                window,
                re.I,
            ):
                errs.append(
                    f"{rel(doc)}:{i}: DOC_BAD_GRABBER_RECIPE teaches "
                    f"-frames:v 1 without warm-up warning nearby"
                )
    # Positive: AGENTS must mention warm-up / capture_hdmi_frame (prove fix landed)
    agents = ROOT / "AGENTS.md"
    if agents.is_file():
        at = agents.read_text(errors="ignore")
        if "capture_hdmi_frame" not in at and "select=gte" not in at:
            errs.append("AGENTS.md: missing warm-up capture recipe (fix not landed)")
    return errs


def main() -> int:
    findings: list[str] = []
    for p in iter_shell_files():
        findings.extend(scan_file(p))

    # Sort for stability
    findings = sorted(set(findings))

    # RBG proofs (must pass even if scan is clean)
    rbg = prove_glue_red_green()
    rbg.extend(prove_grabber_doc_warns())

    rc = 0
    if findings:
        print(f"HARNESS_CAPTURE findings={len(findings)}")
        for f in findings:
            print(f"  FIND {f}")
        rc = 1
    else:
        print("HARNESS_CAPTURE scan_clean findings=0")

    if rbg:
        print(f"HARNESS_CAPTURE RBG_FAIL n={len(rbg)}")
        for e in rbg:
            print(f"  RBG_FAIL {e}")
        rc = 1
    else:
        print("HARNESS_CAPTURE RBG_OK glue+shape+docs")

    print(f"true rc={rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
