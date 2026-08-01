#!/usr/bin/env bash
# restore_postconditions.sh — host-testable post-conditions for daemon restore.
#
# Parent / rd-review: old restore_misterplexd_prev discarded md5sum || true and
# exited 0 with a dead/wrong daemon. This checker is pure host logic over a
# TEMP ROOT (never touches 192.168.1.183, never mutates user conf on device).
#
# Env / args:
#   RESTORE_ROOT   install root (contains bin/misterplexd, optional conf)
#   RESTORE_PREV   previous binary path that should have been copied
#   RESTORE_STATE  dir with n_daemon, live_md5, http, conf_geometry files (fake device)
#
# Exit:
#   0  all post-conditions hold
#   1  generic fail
#   3  n_daemon != 1
#   4  PREV missing / empty
#   5  installed bytes != PREV (the discarded-md5 class)
#   6  live md5 != installed / PREV
#   7  HTTP not 200
#   8  geometry gate fail (DECODE height vs expected)
#   77 empty inspection set (must not PASS)
set -euo pipefail

ROOT_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/gate_coverage.inc.sh
source "$ROOT_SCRIPT/scripts/lib/gate_coverage.inc.sh"

RESTORE_ROOT="${RESTORE_ROOT:?RESTORE_ROOT required}"
RESTORE_PREV="${RESTORE_PREV:?RESTORE_PREV required}"
RESTORE_STATE="${RESTORE_STATE:?RESTORE_STATE required}"
EXPECT_GEOM="${RESTORE_EXPECT_GEOM:-}"  # e.g. 480 or 240; empty = skip geometry

gate_coverage_begin "restore_postconditions"

BIN="$RESTORE_ROOT/bin/misterplexd"
CONF="$RESTORE_ROOT/misterplex.conf"

fail() {
  local rc="$1"; shift
  echo "FAIL restore_postconditions: $*" >&2
  gate_coverage_finish "$rc" || true
  exit "$rc"
}

# R1/R2: PREV must exist and be non-empty
if [[ ! -f "$RESTORE_PREV" ]]; then
  fail 4 "PREV missing path=$RESTORE_PREV"
fi
gate_coverage_note "prev_exists" "$RESTORE_PREV"
prev_sz=$(wc -c <"$RESTORE_PREV" | tr -d ' ')
if [[ "$prev_sz" -eq 0 ]]; then
  fail 4 "PREV empty (0 bytes) path=$RESTORE_PREV"
fi
gate_coverage_note "prev_nonempty" "bytes=$prev_sz"

if [[ ! -f "$BIN" ]]; then
  fail 5 "installed BIN missing $BIN"
fi
gate_coverage_note "bin_exists" "$BIN"

prev_md5=$(md5sum "$RESTORE_PREV" | awk '{print $1}')
bin_md5=$(md5sum "$BIN" | awk '{print $1}')
gate_coverage_note "md5_compare" "prev=$prev_md5 bin=$bin_md5"
# R3: installed bytes must equal PREV (this is the discarded md5sum class)
if [[ "$bin_md5" != "$prev_md5" ]]; then
  fail 5 "installed md5 $bin_md5 != PREV $prev_md5 (would have been discarded by md5sum||true)"
fi

n=$(cat "$RESTORE_STATE/n_daemon" 2>/dev/null || echo "")
if [[ -z "$n" ]]; then
  fail 3 "n_daemon not measured in state"
fi
gate_coverage_note "n_daemon" "n=$n"
if [[ "$n" != "1" ]]; then
  fail 3 "n_daemon=$n want=1"
fi

live_md5=$(cat "$RESTORE_STATE/live_md5" 2>/dev/null || echo "")
gate_coverage_note "live_md5" "live=$live_md5"
if [[ -z "$live_md5" ]]; then
  fail 6 "live_md5 empty"
fi
if [[ "$live_md5" != "$bin_md5" ]]; then
  fail 6 "live md5 $live_md5 != installed $bin_md5"
fi

http=$(cat "$RESTORE_STATE/http" 2>/dev/null || echo "000")
gate_coverage_note "http" "code=$http"
if [[ "$http" != "200" && "$http" != "204" ]]; then
  fail 7 "HTTP $http (daemon not healthy)"
fi

# R5: geometry — if expected height set, conf DECODE must match
if [[ -n "$EXPECT_GEOM" ]]; then
  if [[ ! -f "$CONF" ]]; then
    fail 8 "geometry expected=$EXPECT_GEOM but conf missing $CONF"
  fi
  gate_coverage_note "conf_present" "$CONF"
  # DECODE=320x240 or 624x480 etc. — height is second field
  dec=$(grep -E '^[[:space:]]*DECODE=' "$CONF" | head -1 | sed 's/.*=//' | tr -d '\r' | awk '{print $1}')
  h=$(printf '%s' "$dec" | awk -F'x' '{print $2}')
  gate_coverage_note "geometry" "DECODE=$dec height=$h expect=$EXPECT_GEOM"
  if [[ -z "$h" ]]; then
    fail 8 "cannot parse DECODE height from conf (DECODE='$dec')"
  fi
  if [[ "$h" != "$EXPECT_GEOM" ]]; then
    fail 8 "geometry height=$h != expect=$EXPECT_GEOM (broken picture class / 480p-as-240p)"
  fi
fi

# R6: process age / start marker — state file started_after_restore=1
started=$(cat "$RESTORE_STATE/started_after_restore" 2>/dev/null || echo "0")
gate_coverage_note "started_after_restore" "flag=$started"
if [[ "$started" != "1" ]]; then
  fail 3 "pre-restore daemon still running / new one never started (started_after_restore=$started)"
fi

echo "RESTORE_POSTCONDITIONS_OK root=$RESTORE_ROOT prev_md5=$prev_md5 live_md5=$live_md5 n=1 http=$http"
gate_coverage_finish 0
exit $?
