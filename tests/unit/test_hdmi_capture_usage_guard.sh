#!/usr/bin/env bash
# test_hdmi_capture_usage_guard.sh — an operator mistake must never render as a
# device observation.
#
# Why this gate exists (real incident): hdmi_capture_idle.sh was invoked with a
# DIRECTORY instead of OUT.png. The stats step raised IsADirectoryError, the
# script fell through to its exhausted-retries branch, and it printed
#     GRABBER_NOT_READY reason=all_tries_uniform_black
#     "if the grabber is healthy this means the device really is outputting
#      black — e.g. a mixed core/daemon pair ... roll back to the stable pair"
# i.e. a typo produced a black-screen verdict that advises rolling back the
# daily driver. In this lab a black verdict is acted on. A bad argument must
# exit 2 with USAGE_ERROR and make no claim about the device at all.
#
# These checks are hardware-independent: the usage guard is required to run
# BEFORE the /dev/video0 probe, so this test must pass with no grabber attached.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/hdmi_capture_idle.sh"
FAILED=0

fail() { echo "FAIL $*"; FAILED=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$SCRIPT" ] || { echo "FAIL missing/not-executable $SCRIPT"; exit 1; }

# Words that assert something about the DEVICE. None may appear when the
# operator simply passed a bad path.
DEVICE_VERDICT_RE='uniform_black|really is outputting black|GRABBER_NOT_READY|mixed core|roll back'

check_usage_error() {
  local label="$1" arg="$2" out rc
  out="$("$SCRIPT" "$arg" 2>&1)"; rc=$?

  [ "$rc" -eq 2 ] || fail "$label: want rc=2 got rc=$rc"

  grep -q 'USAGE_ERROR' <<<"$out" \
    || fail "$label: output lacks USAGE_ERROR: $out"

  # The decisive assertion: no device-shaped verdict for an argument mistake.
  if grep -qE "$DEVICE_VERDICT_RE" <<<"$out"; then
    fail "$label: operator error rendered as a DEVICE verdict: $out"
  fi
}

mkdir -p "$TMP/adir"
check_usage_error "directory"      "$TMP/adir"
check_usage_error "trailing_slash" "$TMP/adir/"
check_usage_error "missing_parent" "$TMP/no/such/dir/idle.png"

# Negative case a naive implementation would fail: the guard must be ordered
# BEFORE the device probe. If it were placed after, these calls would report a
# device condition (rc=1 no_device/device_busy) instead of rc=2 on a host with
# no grabber. Assert the ordering in source so the property cannot silently
# regress by someone moving the block down.
guard_line="$(grep -n 'USAGE_ERROR: OUT must be' "$SCRIPT" | head -1 | cut -d: -f1)"
probe_line="$(grep -n 'reason=no_device' "$SCRIPT" | head -1 | cut -d: -f1)"
if [ -z "$guard_line" ] || [ -z "$probe_line" ]; then
  fail "ordering: could not locate guard ($guard_line) / device probe ($probe_line)"
elif [ "$guard_line" -ge "$probe_line" ]; then
  fail "ordering: usage guard (line $guard_line) must precede device probe (line $probe_line)"
fi

# The success path must NOT be swallowed by the guard: a plain .png in an
# existing directory has to get past it. Without a grabber the script is
# expected to fail at the DEVICE probe (rc=1) or succeed (rc=0) — the one
# outcome that would prove the guard over-reaches is rc=2.
out="$("$SCRIPT" "$TMP/idle.png" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  fail "valid path rejected by usage guard (rc=2): $out"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED hdmi_capture_usage_guard"
  exit 1
fi
echo "OK hdmi_capture_usage_guard: operator error exits 2 and makes no device claim"
