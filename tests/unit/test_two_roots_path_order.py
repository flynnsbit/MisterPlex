#!/usr/bin/env python3
"""Two-roots trap gate — v1-before-v2 / bare v1 log defaults must be RED.

Parent 2026-08-01 (sixth occurrence): 
  /media/fat/misterplex/misterplexd.log EXISTS but is STALE (days old) while the
  live daemon writes /media/fat/misterplex_v2/misterplexd.log. First-hit-wins on
  a hardcoded list, or bare default LOG=.../misterplex/..., silently reads the
  corpse → false UNSCORED / voided measurements (daemon_ok=False, vfps NO-DATA).

Authority: tools/avsync_live_log_resolve.inc.sh (live /proc/*/exe → root log).
Fallback lists must put misterplex_v2 BEFORE misterplex.

This gate:
  - FAILs bare default .../misterplex/misterplexd.log (no _v2)
  - FAILs ordered candidate lists where v1 path appears before v2 path
    (log, conf, bin/plexctl, bin/misterplexd)
  - Does NOT weaken UNSCORED/rc=77 behaviour of scorers
  - Mutation: BROKEN fixture (pair v1 default) must RED; product must GREEN

Exit: 0 pass, 1 fail, 2 usage.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SELF = Path(__file__).resolve()

# Product scan roots (not docs, not history fixtures except explicit --path).
SCAN_DIRS = ("tools", "scripts", "tests")
SKIP_PARTS = {
    ".git",
    "build",
    "artifacts",
    ".agent-work",
    "tests/fixtures/two_roots",  # intentional BROKEN fixtures
    "node_modules",
}
EXTS = {".sh", ".py", ".bash", ".inc"}

# Bare default / assignment of the STALE v1 log (measurement-corrupting class).
BARE_V1_LOG = re.compile(
    r"""(?x)
    (?:
        \$\{[^}]*:-/media/fat/misterplex/misterplexd\.log\}
      | (?:LOG|LOG_REMOTE|DAEMON_LOG|DAEMON_LOG_REMOTE|DEVICE_LOG|LOG_PATH_ON_DEVICE)
        \s*=\s*["']?/media/fat/misterplex/misterplexd\.log
    )
    """
)

# Path pairs (v1, v2) — if both appear in a short window, v1 must not precede v2.
PATH_PAIRS = [
    (
        "/media/fat/misterplex/misterplexd.log",
        "/media/fat/misterplex_v2/misterplexd.log",
        "log",
    ),
    (
        "/media/fat/misterplex/misterplex.conf",
        "/media/fat/misterplex_v2/misterplex.conf",
        "conf",
    ),
    (
        "/media/fat/misterplex/bin/misterplexd",
        "/media/fat/misterplex_v2/bin/misterplexd",
        "bin_daemon",
    ),
    (
        "/media/fat/misterplex/bin/plexctl.sh",
        "/media/fat/misterplex_v2/bin/plexctl.sh",
        "bin_plexctl",
    ),
]

# Install/docs recipes that *write* v1 intentionally (not read-live).
ALLOW_RE = re.compile(
    r"(?i)(TWO_ROOTS_OK|install.?target|package_release|scp conf/|"
    r"mkdir -p /media/fat/misterplex[^\w_]|"
    r"NOT automatically live|v1 root|"
    r"example only|documentation)"
)


def should_skip(path: Path) -> bool:
    rel = path.relative_to(ROOT).as_posix()
    if path.resolve() == SELF.resolve():
        return True  # this file embeds path pairs as data
    if rel.endswith("test_two_roots_path_order.py"):
        return True
    for part in SKIP_PARTS:
        if part in rel.split("/") or rel.startswith(part.rstrip("/")):
            return True
        if rel.startswith(part):
            return True
    if "tests/fixtures/two_roots" in rel:
        return True
    if path.suffix not in EXTS and not path.name.endswith(".inc.sh"):
        return True
    if path.name.endswith(".BROKEN_v1_default.sh") or "BROKEN_v1" in path.name:
        return True
    return False


def strip_comment_noise(line: str) -> str:
    # Keep code; crude strip of full-line comments
    s = line.strip()
    if s.startswith("#"):
        return ""
    if s.startswith("//"):
        return ""
    return line


def _token_spans(hay: str, needle: str) -> list[int]:
    """Indices where needle appears as a full path token (not a longer path prefix)."""
    out: list[int] = []
    start = 0
    while True:
        i = hay.find(needle, start)
        if i < 0:
            return out
        end = i + len(needle)
        nxt = hay[end : end + 1]
        # Allow end-of-string or shell delimiters; reject .prev / _v2 path continuation.
        if nxt == "" or nxt in " \t\r\n\"'`;)|&$":
            out.append(i)
        start = i + 1


def find_order_violations(text: str, rel: str) -> list[str]:
    errs: list[str] = []
    lines = text.splitlines()
    # Sliding window of 12 lines for multi-line for-lists
    for i in range(len(lines)):
        window_lines = lines[i : i + 12]
        code = "\n".join(strip_comment_noise(L) for L in window_lines)
        if not code.strip():
            continue
        for v1, v2, kind in PATH_PAIRS:
            s1, s2 = _token_spans(code, v1), _token_spans(code, v2)
            if not s1 or not s2:
                continue
            if min(s1) < min(s2):
                joined = "\n".join(window_lines)
                if ALLOW_RE.search(joined):
                    continue
                errs.append(
                    f"{rel}:{i+1}: v1_before_v2 kind={kind} "
                    f"(two-roots first-hit trap)"
                )
    return errs


def find_bare_v1_log(text: str, rel: str) -> list[str]:
    errs: list[str] = []
    for i, line in enumerate(text.splitlines(), 1):
        code = strip_comment_noise(line)
        if not code:
            continue
        if BARE_V1_LOG.search(code):
            # Allow explicit install recipes in package_release only
            if rel.startswith("scripts/package_release.sh"):
                continue
            if "TWO_ROOTS_OK" in line:
                continue
            errs.append(
                f"{rel}:{i}: bare_v1_log_default "
                f"(stale /media/fat/misterplex/misterplexd.log — use live resolve)"
            )
    return errs


def scan_tree() -> list[str]:
    errs: list[str] = []
    for dname in SCAN_DIRS:
        base = ROOT / dname
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file() or should_skip(path):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as e:
                errs.append(f"{path}: read error {e}")
                continue
            rel = path.relative_to(ROOT).as_posix()
            errs.extend(find_bare_v1_log(text, rel))
            errs.extend(find_order_violations(text, rel))
    return errs


def scan_path(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    rel = path.as_posix()
    return find_bare_v1_log(text, rel) + find_order_violations(text, rel)


def self_test() -> int:
    """Red-before-green on fixtures + product pair/wait must GREEN."""
    broken_pair = ROOT / "tests/fixtures/two_roots/avsync_pair_daemon_hdmi.BROKEN_v1_default.sh"
    broken_wait = ROOT / "tests/fixtures/two_roots/avsync_wait_session.BROKEN_v1_first.sh"
    if not broken_pair.is_file():
        print("FAIL two_roots: missing BROKEN pair fixture", file=sys.stderr)
        return 1
    if not broken_wait.is_file():
        print("FAIL two_roots: missing BROKEN wait fixture", file=sys.stderr)
        return 1

    be = scan_path(broken_pair)
    if not be:
        print(
            "FAIL two_roots MUTATION_BLIND: BROKEN pair fixture did not RED "
            "(gate cannot catch bare v1 DAEMON_LOG_REMOTE default)",
            file=sys.stderr,
        )
        return 1
    print(f"MUTATION_RED broken_pair errs={len(be)} sample={be[0]}")

    we = scan_path(broken_wait)
    if not we:
        print(
            "FAIL two_roots MUTATION_BLIND: BROKEN wait v1-before-v2 did not RED",
            file=sys.stderr,
        )
        return 1
    print(f"MUTATION_RED broken_wait errs={len(we)} sample={we[0]}")

    # Product fixed tools must be clean when present
    for rel in (
        "tools/avsync_pair_daemon_hdmi.sh",
        "tools/avsync_wait_session.sh",
        "tools/avsync_live_log_resolve.inc.sh",
    ):
        p = ROOT / rel
        if not p.is_file():
            print(f"FAIL two_roots: missing product {rel}", file=sys.stderr)
            return 1
        pe = scan_path(p)
        if pe:
            print(f"FAIL two_roots product still dirty {rel}: {pe[0]}", file=sys.stderr)
            return 1
        print(f"MUTATION_GREEN product_clean {rel}")

    # Live resolve fallback must be v2-before-v1
    inc = (ROOT / "tools/avsync_live_log_resolve.inc.sh").read_text(encoding="utf-8")
    i2 = inc.find("/media/fat/misterplex_v2/misterplexd.log")
    i1 = inc.find("/media/fat/misterplex/misterplexd.log")
    # Prefer the fallback list occurrence (second pair if comment first)
    # Find both in fallback for-loop region
    fb = inc.find("Fallback")
    region = inc[fb:] if fb >= 0 else inc
    i2 = region.find("/media/fat/misterplex_v2/misterplexd.log")
    i1 = region.find("/media/fat/misterplex/misterplexd.log")
    if i2 < 0 or i1 < 0 or not (i2 < i1):
        print("FAIL two_roots: live resolve fallback not v2-before-v1", file=sys.stderr)
        return 1
    print("MUTATION_GREEN resolve_fallback v2_before_v1")

    print(
        "PASS two_roots self-test (broken pair/wait RED; product GREEN; "
        "resolve v2-before-v1)"
    )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument(
        "--path",
        type=Path,
        action="append",
        default=[],
        help="Scan only these paths (mutation / focused)",
    )
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.path:
        errs: list[str] = []
        for p in args.path:
            errs.extend(scan_path(p if p.is_absolute() else ROOT / p))
    else:
        errs = scan_tree()
    print(
        f"COVERAGE gate=two_roots_path_order scanned=tools,scripts,tests "
        f"errs={len(errs)}"
    )
    if errs:
        for e in errs[:40]:
            print(f"FAIL {e}", file=sys.stderr)
        if len(errs) > 40:
            print(f"FAIL ... +{len(errs)-40} more", file=sys.stderr)
        print(
            "FAIL two_roots_path_order: fix via tools/avsync_live_log_resolve.inc.sh "
            "(live /proc exe); never v1-before-v2 first-hit; never bare v1 log default",
            file=sys.stderr,
        )
        return 1
    print("PASS two_roots_path_order: no bare v1 log default; no v1-before-v2 lists")
    return 0


if __name__ == "__main__":
    sys.exit(main())
