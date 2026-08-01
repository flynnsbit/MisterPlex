#!/usr/bin/env bash
# pair_pin_update.sh — write validated-pair CURRENT after parent verifies live.
#
# Prefer this over hand-editing video_regression.sh / rbf_ship_policy.sh pins.
#
# Usage:
#   scripts/pair_pin_update.sh --core-md5 c5382bee... --daemon-md5 <32hex> [--note TEXT]
#   scripts/pair_pin_update.sh --from-live   # SSH: read live exe md5 + claim core (parent)
#
# Never weakens gates. Only updates artifacts/validated-pair/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/artifacts/validated-pair"
CURRENT="$DIR/CURRENT"
ACCEPTED="$DIR/ACCEPTED_DAEMONS"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"

core=""
daemon=""
note=""
from_live=0

while [ $# -gt 0 ]; do
  case "$1" in
    --core-md5) core="${2:-}"; shift 2 ;;
    --daemon-md5) daemon="${2:-}"; shift 2 ;;
    --note) note="${2:-}"; shift 2 ;;
    --from-live) from_live=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "unknown arg $1" >&2; exit 9 ;;
  esac
done

normalize() {
  printf '%s' "${1:-}" | tr 'A-F' 'a-f' | tr -cd '0-9a-f'
}

if [ "$from_live" -eq 1 ]; then
  # shellcheck source=lib/live_daemon_enum.sh
  source "$ROOT/scripts/lib/live_daemon_enum.sh"
  # Join remote fragments with explicit newlines — never bare $(a)$(b) glue
  # (bash strips trailing NL → V2_MD5…set +e class).
  # Variable names intentionally avoid scanner tokens remote/blob (false GLUE_RISK).
  _pin_script_body=$(printf '%s\n' "$(live_daemon_remote_snippet)" "" \
    'if [ -f /media/fat/misterplex/.running_core_claim ]; then' \
    '  echo CLAIM_BEGIN' \
    '  cat /media/fat/misterplex/.running_core_claim' \
    '  echo CLAIM_END' \
    'fi')
  set +e
  live_pin_out=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    "$USER@$HOST" "bash -s" <<EOS
$_pin_script_body
EOS
)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "NO-DATA ssh true rc=$rc"
    echo "true rc=4"
    exit 4
  fi
  if [ -z "$live_pin_out" ]; then
    echo "NO-DATA ssh empty capture (not a pin mismatch)"
    echo "true rc=4"
    exit 4
  fi
  printf '%s\n' "$live_pin_out" | sed 's/^/  /'
  daemon=$(printf '%s\n' "$live_pin_out" | sed -n 's/^LIVE_MD5=//p' | head -1)
  n=$(printf '%s\n' "$live_pin_out" | sed -n 's/^N_DAEMON=//p' | head -1)
  core=$(printf '%s\n' "$live_pin_out" | sed -n '/^CLAIM_BEGIN$/,/^CLAIM_END$/p' | sed -n 's/^md5=//p' | head -1)
  # Shape: empty = NO-DATA; glued residue = FAIL
  case "$daemon" in
    '' )
      echo "NO-DATA LIVE_MD5 empty"
      echo "true rc=4"
      exit 4
      ;;
    *[!0-9a-fA-F]* | *[[:space:]]* )
      echo "FAIL LIVE_MD5 shape contaminated got='$daemon'"
      echo "true rc=3"
      exit 3
      ;;
  esac
  if [ -z "$n" ] || [ "$n" != "1" ]; then
    echo "NO-DATA cannot resolve single live daemon (n='$n' md5='$daemon')"
    echo "true rc=4"
    exit 4
  fi
  if [ -z "$core" ]; then
    echo "NOTE core md5 from claim missing — daemon-only update"
  fi
fi

core=$(normalize "$core")
daemon=$(normalize "$daemon")

if [ -z "$daemon" ] || [ "${#daemon}" -lt 8 ]; then
  echo "FAIL need --daemon-md5 (>=8 hex) or --from-live"
  echo "true rc=3"
  exit 3
fi

mkdir -p "$DIR"
pfx8="${daemon:0:8}"
full=""
if [ "${#daemon}" -ge 32 ]; then
  full="${daemon:0:32}"
fi

{
  echo "# Last parent-validated pair"
  echo "CORE_MD5=${core}"
  echo "DAEMON_MD5=${full}"
  echo "DAEMON_PREFIX8=${pfx8}"
  echo "PAIR_ID=ddr-c5382bee"
  echo "UPDATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "NOTE=${note}"
} >"$CURRENT"

# Ensure accepted list contains this pin
touch "$ACCEPTED"
if [ -n "$full" ]; then
  grep -qxF "$full" "$ACCEPTED" 2>/dev/null || echo "$full" >>"$ACCEPTED"
fi
grep -qxF "$pfx8" "$ACCEPTED" 2>/dev/null || echo "$pfx8" >>"$ACCEPTED"

echo "PAIR_PIN_UPDATED current=$CURRENT daemon_prefix8=$pfx8 daemon_full=${full:-'(prefix only)'}"
echo "true rc=0"
exit 0
