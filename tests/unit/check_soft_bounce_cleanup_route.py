#!/usr/bin/env python3
"""Discriminating checker: cleanup() must restore via soft_bounce, not direct deploy.

Brace-depth extracts cleanup() only. A loose slice to do_claim() was vacuous
against the unfixed parent (rule-0). Red twin of the old direct-deploy path
must fail this checker.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def extract_func(text: str, name: str) -> str:
    m = re.search(rf"^{re.escape(name)}\(\)\s*\{{", text, re.M)
    if not m:
        raise SystemExit(f"FAIL: {name}() not found")
    i = m.end() - 1  # at '{'
    depth = 0
    for j in range(i, len(text)):
        c = text[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[m.start() : j + 1]
    raise SystemExit(f"FAIL: {name}() unclosed")


def check_cleanup(body: str) -> None:
    if 'soft_bounce "release_cleanup"' not in body and "soft_bounce 'release_cleanup'" not in body:
        raise SystemExit("FAIL: cleanup missing soft_bounce release_cleanup")
    for i, line in enumerate(body.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if "deploy_plex_core.sh" in s or re.search(r"\bDEPLOY_LOAD=menu\b", s):
            raise SystemExit(
                f"FAIL: cleanup line {i} invokes deploy directly "
                f"(must use soft_bounce only): {s}"
            )
    if "lock_is_ours" not in body and "LOCK_DIR/pid" not in body:
        raise SystemExit(
            "FAIL: cleanup must gate release on lock ownership (pid), not HOLDING alone"
        )


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} path/to/mister_soft_bounce.sh", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    text = path.read_text()
    body = extract_func(text, "cleanup")
    check_cleanup(body)
    print("PASS cleanup routes restore through soft_bounce (brace-depth)")

    # RED TWIN: old GAP3 direct-deploy cleanup must be rejected.
    bad = r"""
cleanup() {
  local ec=$?
  if [[ "$HOLDING" == "1" ]]; then
    HOLDING=0
    DEPLOY_LOAD=menu DEPLOY_SKIP_COPY=1 DEPLOY_RECOVER=none \
      ./scripts/deploy_plex_core.sh || true
    release_lock || true
  fi
  exit "$ec"
}
"""
    try:
        check_cleanup(extract_func(bad, "cleanup"))
    except SystemExit as e:
        msg = str(e)
        if "deploy directly" not in msg and "soft_bounce" not in msg:
            print(f"FAIL: red twin raised unexpected: {e}", file=sys.stderr)
            return 1
        print(f"PASS red twin: direct-deploy cleanup rejected ({e})")
        return 0
    print("FAIL: red twin direct-deploy cleanup was accepted (checker vacuous)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
