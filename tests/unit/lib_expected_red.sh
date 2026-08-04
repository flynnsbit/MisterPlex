# Shared by test_*_red.sh — prefix fault-binary stdout so `grep FAIL` on make unit
# logs cannot be mistaken for green failures (parent instrument class, 2026-08-04).
# Source:  . "$ROOT/tests/unit/lib_expected_red.sh"
# Usage:   prefix_expected_red <<<"$OUT"   or   printf '%s\n' "$OUT" | prefix_expected_red

prefix_expected_red() {
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    printf 'EXPECTED_RED %s\n' "$line"
  done
}

emit_expected_red_block() {
  # $1 = multi-line string from a fault binary
  printf '%s\n' "$1" | prefix_expected_red
}
