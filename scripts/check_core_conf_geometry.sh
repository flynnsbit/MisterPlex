#!/usr/bin/env bash
# Gate: resident core geometry must match daemon-ADOPTED decode size.
#
# WHY NOT PARSE THE CONF FILE:
#   arm/misterplexd/main.cpp defaults kDefaultCodedDecodeSize (320x240), then
#   conf DECODE= / argv --decode go through adoptExternalCodedSize (typed).
#   Static conf parsing still misses CLI precedence and REJECTED keep-default
#   cases. The daemon prints what it actually adopted on
#   "misterplexd: running ... decode=WxH ..." — THAT line is SoT for this gate.
#
# Exit codes:
#   0  PASS  — known core md5, adopted decode matches mapped geometry
#   1  FAIL  — known core md5, adopted decode mismatches (or bad args)
#   77 SKIP-NOT-PASS — unknown core, missing inputs, unparseable evidence
#
# Usage:
#   scripts/check_core_conf_geometry.sh                  # live device (read-only)
#   scripts/check_core_conf_geometry.sh --md5 HEX --log PATH
#   CORE_MD5=... ADOPTED_LOG=... scripts/check_core_conf_geometry.sh
#   FIXTURE_DIR=dir  (expects core.md5 + misterplexd.log)
#
# Env:
#   MISTER_HOST MISTER_USER MISTER_PASS  — live ssh (defaults lab box)
#   CORE_GEOMETRY_MAP  — override map path
#   RBF_PATH_ON_DEVICE — default /media/fat/_Utility/Plex.rbf
#   LOG_PATH_ON_DEVICE — default /media/fat/misterplex/misterplexd.log
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../tests/hw/hw_gate_common.sh
source "$ROOT/tests/hw/hw_gate_common.sh"

MAP="${CORE_GEOMETRY_MAP:-$ROOT/assets/core_geometry_map.tsv}"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
RBF_REMOTE="${RBF_PATH_ON_DEVICE:-/media/fat/_Utility/Plex.rbf}"
LOG_REMOTE="${LOG_PATH_ON_DEVICE:-/media/fat/misterplex/misterplexd.log}"

CORE_MD5="${CORE_MD5:-}"
ADOPTED_LOG="${ADOPTED_LOG:-}"
FIXTURE_DIR="${FIXTURE_DIR:-}"
NAME="core_conf_geometry"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --md5) CORE_MD5="${2:-}"; shift 2 ;;
    --log) ADOPTED_LOG="${2:-}"; shift 2 ;;
    --map) MAP="${2:-}"; shift 2 ;;
    --fixture-dir) FIXTURE_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "FAIL $NAME: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# FIXTURE_DIR is strictly offline: never fall back to the live device when a
# fixture piece is missing (that would turn absent-log into a vacuous PASS).
if [[ -n "$FIXTURE_DIR" ]]; then
  if [[ -z "$CORE_MD5" ]]; then
    if [[ -f "$FIXTURE_DIR/core.md5" ]]; then
      CORE_MD5="$(tr -d ' \t\r\n' <"$FIXTURE_DIR/core.md5")"
    else
      hw_skip_not_pass "$NAME" "FIXTURE_DIR=$FIXTURE_DIR missing core.md5"
    fi
  fi
  if [[ -z "$ADOPTED_LOG" ]]; then
    if [[ -f "$FIXTURE_DIR/misterplexd.log" ]]; then
      ADOPTED_LOG="$FIXTURE_DIR/misterplexd.log"
    else
      hw_skip_not_pass "$NAME" "FIXTURE_DIR=$FIXTURE_DIR missing misterplexd.log"
    fi
  fi
fi

lookup_expected_geometry() {
  local md5="$1"
  [[ -f "$MAP" ]] || return 1
  # Prefer awk over cut so comments/blank lines are ignored safely.
  awk -v m="$md5" '
    BEGIN { found=0 }
    /^#/ || NF==0 { next }
    {
      key=$1
      gsub(/\r/,"",key)
      if (tolower(key)==tolower(m)) {
        print $2
        found=1
        exit 0
      }
    }
    END { exit found?0:1 }
  ' "$MAP"
}

parse_adopted_decode() {
  # Last "misterplexd: running ... decode=WxH" wins (restart after conf edit).
  # Tolerate ssh banners / mixed case; never take field-1 of line-1.
  local src="$1"
  if [[ ! -f "$src" ]]; then
    return 1
  fi
  # grep may exit 1 when absent — do not trip set -e.
  local line
  line="$(grep -E 'misterplexd: running .*decode=[0-9]+x[0-9]+' "$src" 2>/dev/null | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi
  if [[ "$line" =~ decode=([0-9]+x[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

fetch_live_md5() {
  if ! command -v sshpass >/dev/null 2>&1; then
    hw_skip_not_pass "$NAME" "sshpass required for live core md5 read"
  fi
  local out
  if ! out=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      "$USER@$HOST" "md5sum '$RBF_REMOTE'" 2>&1); then
    hw_skip_not_pass "$NAME" "could not read resident RBF md5: $out"
  fi
  local actual
  actual="$(hw_parse_md5_hex "$out")"
  if [[ -z "$actual" ]]; then
    hw_skip_not_pass "$NAME" "could not parse resident RBF md5 from: $out"
  fi
  printf '%s\n' "$actual"
}

fetch_live_log() {
  if ! command -v sshpass >/dev/null 2>&1; then
    hw_skip_not_pass "$NAME" "sshpass required for live adopted-log read"
  fi
  mkdir -p "$ROOT/build"
  local tmp
  tmp="$(mktemp "$ROOT/build/core-conf-geometry.XXXXXX.log")"
  if ! sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      "$USER@$HOST" "cat '$LOG_REMOTE'" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    hw_skip_not_pass "$NAME" "could not read $LOG_REMOTE from $HOST"
  fi
  printf '%s\n' "$tmp"
}

# --- resolve inputs ---
mkdir -p "$ROOT/build"
LIVE_LOG_TMP=""
cleanup() {
  # Always return 0: under set -e a failed [[ in an EXIT trap steals the
  # process exit status (PASS would become rc=1 — a vacuous-green inverse).
  if [[ -n "${LIVE_LOG_TMP:-}" && -f "$LIVE_LOG_TMP" ]]; then
    rm -f "$LIVE_LOG_TMP" || true
  fi
  return 0
}
trap cleanup EXIT

if [[ -z "$CORE_MD5" ]]; then
  if [[ -n "$FIXTURE_DIR" ]]; then
    hw_skip_not_pass "$NAME" "fixture mode but core md5 empty"
  fi
  CORE_MD5="$(fetch_live_md5)"
fi
CORE_MD5="$(printf '%s' "$CORE_MD5" | tr 'A-F' 'a-f' | tr -d ' \t\r\n')"
if [[ ! "$CORE_MD5" =~ ^[0-9a-f]{32}$ ]]; then
  hw_skip_not_pass "$NAME" "core md5 not a 32-hex digest: '${CORE_MD5:-empty}'"
fi

if [[ -z "$ADOPTED_LOG" ]]; then
  if [[ -n "$FIXTURE_DIR" ]]; then
    hw_skip_not_pass "$NAME" "fixture mode but adopted log empty"
  fi
  # Explicit CORE_MD5/ADOPTED_LOG env without FIXTURE_DIR: allow live log fetch
  # only when ADOPTED_LOG was not provided at all.
  LIVE_LOG_TMP="$(fetch_live_log)"
  ADOPTED_LOG="$LIVE_LOG_TMP"
fi
if [[ ! -f "$ADOPTED_LOG" ]]; then
  hw_skip_not_pass "$NAME" "adopted log missing: $ADOPTED_LOG"
fi

if [[ ! -f "$MAP" ]]; then
  echo "FAIL $NAME: geometry map missing: $MAP" >&2
  exit 1
fi

EXPECTED="$(lookup_expected_geometry "$CORE_MD5" || true)"
if [[ -z "${EXPECTED:-}" ]]; then
  hw_skip_not_pass "$NAME" \
    "unknown core md5=$CORE_MD5 (not in $MAP) — refuse silent pass; add mapping or deploy a known core"
fi

ADOPTED="$(parse_adopted_decode "$ADOPTED_LOG" || true)"
if [[ -z "${ADOPTED:-}" ]]; then
  hw_skip_not_pass "$NAME" \
    "no 'misterplexd: running ... decode=WxH' line in $ADOPTED_LOG — daemon not started or log wiped"
fi

echo "$NAME: source=adopted-running-line (NOT conf file)"
echo "$NAME: core_md5=$CORE_MD5 expected_geometry=$EXPECTED adopted_decode=$ADOPTED map=$MAP"

if [[ "$ADOPTED" != "$EXPECTED" ]]; then
  cat >&2 <<EOF
FAIL $NAME: geometry mismatch
  resident core md5 : $CORE_MD5
  expected geometry : $EXPECTED  (from core→geometry map)
  adopted decode    : $ADOPTED   (from daemon running line)
  bank1 note        : 320x240→0x30040000; 624/640x480→0x30080000
  fix               : set DECODE=$EXPECTED in misterplex.conf (and matching PRESENT/STREAM),
                      restart misterplexd, re-check the adopted running line — do NOT
                      trust conf alone; idle screens can look perfect with a bad DECODE.
EOF
  exit 1
fi

echo "PASS $NAME: core $CORE_MD5 adopted decode=$ADOPTED matches expected $EXPECTED"
exit 0
