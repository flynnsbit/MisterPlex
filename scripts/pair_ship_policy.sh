#!/usr/bin/env bash
# pair_ship_policy.sh — matched (core, daemon) pairs; never mix SPI core + DDR daemon.
#
# Parent-measured 2026-07-31: rollback restored SPI core dfebf2bf but left DDR
# daemon e9f79de2 live → SOLID GREEN SCREEN (mean luma ~128). Telemetry
# (/resources 200, n_daemon=1, core md5 OK) all passed. Only viewed pixels caught it.
#
# Source or run:
#   source scripts/pair_ship_policy.sh
#   pair_policy_check <core_md5> <daemon_md5>
#   pair_policy_lookup <pair_id>
#
# Exit codes (callers print true rc=N):
#   0  known matched pair
#   1  unknown / mixed / refused combination
#   3  bad args

# shellcheck source=rbf_ship_policy.sh
if [ -z "${RBF_PIN_V2_DAILY_FULL:-}" ]; then
  _PAIR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck disable=SC1091
  source "$_PAIR_ROOT/scripts/rbf_ship_policy.sh"
fi

# Canonical pair IDs. Design for "last verified-good pair", not only v2.
# core_md5|daemon_md5|core_device_path|mode|label
PAIR_MATRIX_ROWS=(
  "${RBF_PIN_V2_DAILY_FULL}|${DAEMON_PIN_V2_HYBRID_FULL}|${DEVICE_CORE_V2_DAILY}|spi|spi-v2-hybrid"
  "${RBF_PIN_V2_DAILY_FULL}|${DAEMON_PIN_V2_RELEASE_FULL}|${DEVICE_CORE_V2_DAILY}|spi|spi-v2-release"
  "${RBF_PIN_DDR_CANDIDATE_FULL}|${DAEMON_PIN_DDR_CANDIDATE_FULL}|${DEVICE_CORE_PRODUCT}|ddr|ddr-c5382bee"
)

# Default rollback target pair id (SPI hybrid). Override with PAIR_ID=...
PAIR_ID_SPI_HYBRID=spi-v2-hybrid
PAIR_ID_SPI_RELEASE=spi-v2-release
PAIR_ID_DDR_C5382=ddr-c5382bee
PAIR_DEFAULT_ROLLBACK="${PAIR_DEFAULT_ROLLBACK:-$PAIR_ID_SPI_HYBRID}"

# Idle visual envelopes (parent HDMI, 2026-07-31):
#   good orange Plex chevron idle: mean ~38.5
#   broken mixed-pair solid green: mean ~128.4, near-uniform
PAIR_IDLE_MEAN_MIN="${PAIR_IDLE_MEAN_MIN:-15}"
PAIR_IDLE_MEAN_MAX="${PAIR_IDLE_MEAN_MAX:-70}"
PAIR_IDLE_GREEN_MEAN_REJECT="${PAIR_IDLE_GREEN_MEAN_REJECT:-100}"

pair_policy_normalize_md5() {
  rbf_policy_normalize_md5 "${1:-}"
}

# Print: PAIR_OK id=... mode=... core=... daemon=... path=...
# or PAIR_REFUSE reason=...
pair_policy_check() {
  local core daemon c d row pc pd path mode label
  core=$(pair_policy_normalize_md5 "${1:-}")
  daemon=$(pair_policy_normalize_md5 "${2:-}")
  if [ "${#core}" -lt 8 ] || [ "${#daemon}" -lt 8 ]; then
    echo "PAIR_REFUSE reason=bad_md5 core='${1:-}' daemon='${2:-}'"
    return 3
  fi
  c="${core:0:8}"
  d="${daemon:0:8}"
  for row in "${PAIR_MATRIX_ROWS[@]}"; do
    IFS='|' read -r pc pd path mode label <<<"$row"
    if [ "${pc:0:8}" = "$c" ] && [ "${pd:0:8}" = "$d" ]; then
      # full-length match when both sides are full md5s
      if [ "${#core}" -ge 32 ] && [ "$core" != "$pc" ]; then
        continue
      fi
      if [ "${#daemon}" -ge 32 ] && [ "$daemon" != "$pd" ]; then
        continue
      fi
      echo "PAIR_OK id=$label mode=$mode core=$pc daemon=$pd path=$path"
      return 0
    fi
  done
  # Explicit known-bad mix called out for operators
  if [ "$c" = "${RBF_PIN_V2_DAILY_FULL:0:8}" ] && [ "$d" = "${DAEMON_PIN_DDR_CANDIDATE_FULL:0:8}" ]; then
    echo "PAIR_REFUSE reason=spi_core_plus_ddr_daemon core=$c daemon=$d"
    echo "PAIR_REFUSE detail=solid_green_screen_parent_2026-07-31 (SPI core has no ddr_frame_store)"
    return 1
  fi
  if [ "$c" = "${RBF_PIN_DDR_CANDIDATE_FULL:0:8}" ] && { [ "$d" = "${DAEMON_PIN_V2_HYBRID_FULL:0:8}" ] || [ "$d" = "${DAEMON_PIN_V2_RELEASE_FULL:0:8}" ]; }; then
    echo "PAIR_REFUSE reason=ddr_core_plus_spi_daemon core=$c daemon=$d"
    return 1
  fi
  echo "PAIR_REFUSE reason=unknown_combination core=$c daemon=$d (not in PAIR_MATRIX_ROWS)"
  return 1
}

# Lookup pair by id. Prints KEY=value lines.
pair_policy_lookup() {
  local want="${1:-}" row pc pd path mode label
  [ -n "$want" ] || { echo "PAIR_REFUSE reason=empty_pair_id"; return 3; }
  for row in "${PAIR_MATRIX_ROWS[@]}"; do
    IFS='|' read -r pc pd path mode label <<<"$row"
    if [ "$label" = "$want" ]; then
      echo "PAIR_ID=$label"
      echo "PAIR_MODE=$mode"
      echo "PAIR_CORE_MD5=$pc"
      echo "PAIR_DAEMON_MD5=$pd"
      echo "PAIR_CORE_PATH=$path"
      return 0
    fi
  done
  echo "PAIR_REFUSE reason=unknown_pair_id id=$want"
  return 1
}

pair_policy_list() {
  local row pc pd path mode label
  echo "PAIR_DEFAULT_ROLLBACK=$PAIR_DEFAULT_ROLLBACK"
  for row in "${PAIR_MATRIX_ROWS[@]}"; do
    IFS='|' read -r pc pd path mode label <<<"$row"
    echo "PAIR id=$label mode=$mode core=${pc:0:8} daemon=${pd:0:8} path=$path"
  done
}

# Host-side search for a daemon binary matching want md5 (full or prefix8+).
# Prints path on stdout; rc 0 if found.
pair_policy_find_daemon_artifact() {
  local want root cand m tops tl base
  want=$(pair_policy_normalize_md5 "${1:-}")
  [ "${#want}" -ge 8 ] || return 1
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # Explicit path overrides always win (and are the only search if set alone).
  for cand in \
    "${ROLLBACK_DAEMON:-}" \
    "${PAIR_DAEMON_ARTIFACT:-}" \
    "${PROMOTE_DAEMON:-}"
  do
    [ -n "$cand" ] || continue
    [ -f "$cand" ] || continue
    m=$(md5sum "$cand" | awk '{print $1}')
    if [ "$m" = "$want" ]; then echo "$cand"; return 0; fi
    if [ "${#want}" -eq 8 ] && [ "${m:0:8}" = "$want" ]; then
      echo "$cand"; return 0
    fi
  done
  # PAIR_POLICY_SEARCH_ROOTS=dir[:dir...] — unit tests isolate pins (no main leak).
  # PAIR_POLICY_DISABLE_DEFAULT_ROOTS=1 — only explicit overrides + SEARCH_ROOTS.
  tops=()
  if [ -n "${PAIR_POLICY_SEARCH_ROOTS:-}" ]; then
    IFS=':' read -r -a tops <<<"$PAIR_POLICY_SEARCH_ROOTS"
  elif [ "${PAIR_POLICY_DISABLE_DEFAULT_ROOTS:-0}" = "1" ]; then
    tops=()
  else
    tops=("$root")
    if command -v git >/dev/null 2>&1; then
      tl=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)
      [ -n "$tl" ] && tops+=("$tl")
      tops+=("/home/flynnsbit/Projects/MisterPlex")
    fi
  fi
  for base in "${tops[@]}"; do
    [ -n "$base" ] || continue
    for cand in \
      "$base/artifacts/daemon-pins/misterplexd.${want:0:8}" \
      "$base/artifacts/daemon-pins/misterplexd" \
      "$base/release_artifacts/daemon-pins/misterplexd.${want:0:8}" \
      "$base/misterplexd.${want:0:8}" \
      "$base/misterplexd"
    do
      [ -f "$cand" ] || continue
      m=$(md5sum "$cand" | awk '{print $1}')
      if [ "$m" = "$want" ]; then echo "$cand"; return 0; fi
      if [ "${#want}" -eq 8 ] && [ "${m:0:8}" = "$want" ]; then
        echo "$cand"; return 0
      fi
    done
  done
  return 1
}

# Print actionable fetch instructions when a pin is missing (never bare NOT_FOUND alone).
pair_policy_missing_daemon_help() {
  local want pfx
  want=$(pair_policy_normalize_md5 "${1:-}")
  pfx="${want:0:8}"
  cat <<HELP
MISSING_DAEMON_PIN want=${want:-empty} prefix8=$pfx
  Pins are gitignored ARM ELFs under artifacts/daemon-pins/ (not in git).
  Fetch from the MiSTer (parent only):
    scripts/fetch_daemon_pins.sh both
    # or: scripts/fetch_daemon_pins.sh spi   # 50f4eb92
    # or: scripts/fetch_daemon_pins.sh ddr   # e9f79de2
  Then re-run:
    scripts/pair_ship_policy.sh find-daemon $pfx
  Override:
    ROLLBACK_DAEMON=/path/to/misterplexd.$pfx
HELP
}

# CLI
if [ "${BASH_SOURCE[0]-}" = "${0:-}" ]; then
  set -euo pipefail
  cmd="${1:-list}"
  case "$cmd" in
    check)
      set +e
      out=$(pair_policy_check "${2:-}" "${3:-}")
      rc=$?
      set -e
      printf '%s\n' "$out"
      echo "true rc=$rc"
      exit "$rc"
      ;;
    lookup)
      set +e
      out=$(pair_policy_lookup "${2:-}")
      rc=$?
      set -e
      printf '%s\n' "$out"
      echo "true rc=$rc"
      exit "$rc"
      ;;
    find-daemon)
      set +e
      path=$(pair_policy_find_daemon_artifact "${2:-}")
      rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then
        echo "FOUND $path"
        md5sum "$path"
      else
        echo "NOT_FOUND want=${2:-}"
        pair_policy_missing_daemon_help "${2:-}"
      fi
      echo "true rc=$rc"
      exit "$rc"
      ;;
    list)
      pair_policy_list
      echo "true rc=0"
      exit 0
      ;;
    *)
      echo "usage: $0 {list|check <core_md5> <daemon_md5>|lookup <pair_id>|find-daemon <md5>}" >&2
      echo "true rc=9"
      exit 9
      ;;
  esac
fi
