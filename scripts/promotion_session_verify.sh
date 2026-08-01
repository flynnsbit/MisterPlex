#!/usr/bin/env bash
# promotion_session_verify.sh — non-vacuous post-promotion telemetry gate.
#
# Cannot PASS without an established session. No session → UNSCORED rc=77
# (never treat as PASS). Soft-skip is never green.
#
# Inputs (env or --from-log FILE grepping daemon log):
#   DELIVERY_VERIFIED  measured field delivery_verified=
#   MEASURED_DELIVERY  measured_delivery=WxH
#   DROPS              drops=
#   UNACCOUNTED        unaccounted=
#   VFPS               vfps=
#   SOURCE_FPS         source fps (e.g. 23.97)
#   SESSION_ESTABLISHED 0|1  — set 1 only when a real play window was scored
#   REQUIRE_SINGLE_SESSION_EPOCH=1 — with --from-log, also run soak_continuity_assert
#     (P4: counter soak must be one session_epoch; respawn resets drops/presents)
#
#   ./scripts/promotion_session_verify.sh
#   ./scripts/promotion_session_verify.sh --from-log path/to/misterplexd.log
#   PROMO_SESSION_BLOB=$'delivery_verified=1\n...' ./scripts/promotion_session_verify.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=deploy_misterplexd_lib.sh
source "$ROOT/scripts/deploy_misterplexd_lib.sh"

FROM_LOG=""
if [[ "${1:-}" == "--from-log" ]]; then
  FROM_LOG="${2:-}"
fi

pick() {
  local key="$1" default="${2:-}"
  local v="${!key:-}"
  if [[ -n "$v" ]]; then
    printf '%s' "$v"
    return
  fi
  printf '%s' "$default"
}

if [[ -n "${PROMO_SESSION_BLOB:-}" ]]; then
  blob="$PROMO_SESSION_BLOB"
elif [[ -n "$FROM_LOG" ]]; then
  [[ -f "$FROM_LOG" ]] || {
    echo "FAIL missing log $FROM_LOG" >&2
    echo "true rc=2"
    exit 2
  }
  blob=$(cat "$FROM_LOG")
else
  blob=""
fi

# Parse last matching tags from blob when env unset.
parse_last() {
  local re="$1"
  printf '%s\n' "$blob" | grep -E "$re" | tail -1 || true
}

dv=$(pick DELIVERY_VERIFIED "")
md=$(pick MEASURED_DELIVERY "")
drops=$(pick DROPS "")
unacc=$(pick UNACCOUNTED "")
vfps=$(pick VFPS "")
sfps=$(pick SOURCE_FPS "")
sess=$(pick SESSION_ESTABLISHED "")

if [[ -n "$blob" ]]; then
  line=$(parse_last 'delivery_verified=')
  [[ -z "$dv" && -n "$line" ]] && dv=$(printf '%s' "$line" | sed -n 's/.*delivery_verified=\([0-9]\).*/\1/p')
  line=$(parse_last 'measured_delivery=')
  [[ -z "$md" && -n "$line" ]] && md=$(printf '%s' "$line" | sed -n 's/.*measured_delivery=\([0-9x]*\).*/\1/p')
  line=$(parse_last ' drops=')
  [[ -z "$drops" && -n "$line" ]] && drops=$(printf '%s' "$line" | sed -n 's/.*drops=\([0-9][0-9]*\).*/\1/p')
  line=$(parse_last 'unaccounted=')
  [[ -z "$unacc" && -n "$line" ]] && unacc=$(printf '%s' "$line" | sed -n 's/.*unaccounted=\([0-9][0-9]*\).*/\1/p')
  line=$(parse_last 'vfps=')
  [[ -z "$vfps" && -n "$line" ]] && vfps=$(printf '%s' "$line" | sed -n 's/.*vfps=\([0-9.][0-9.]*\).*/\1/p')
fi

# Session established: explicit env wins; else infer from delivery_verified=1 + measured_delivery present.
if [[ -z "$sess" ]]; then
  if [[ "$dv" == "1" && -n "$md" ]]; then
    sess=1
  else
    sess=0
  fi
fi
# Empty everything → definitely no session
if [[ -z "$dv" && -z "$md" && -z "$vfps" && -z "$blob" ]]; then
  sess=0
fi

if [[ -z "$sfps" && -n "$vfps" ]]; then
  # Default source assumption only when vfps looks like 24p class — still scored against vfps.
  sfps="$vfps"
fi

echo "promotion_session_verify: dv=$dv md=$md drops=$drops unacc=$unacc vfps=$vfps sfps=$sfps sess=$sess"

set +e
promotion_assert_session_telemetry "$dv" "$md" "$drops" "$unacc" "$vfps" "$sfps" "$sess"
rc=$?
set -e

# P4 single-session soak: optional hard gate when log path available.
if [[ "${REQUIRE_SINGLE_SESSION_EPOCH:-0}" == "1" ]]; then
  if [[ -z "$FROM_LOG" || ! -f "$FROM_LOG" ]]; then
    echo "FAIL REQUIRE_SINGLE_SESSION_EPOCH=1 needs --from-log FILE (no session_epoch samples otherwise)"
    echo "true rc=77"
    exit 77
  fi
  set +e
  python3 "$ROOT/tools/soak_continuity_assert.py" --log "$FROM_LOG" --require-single-session-epoch
  src=$?
  set -e
  echo "soak_continuity_assert true rc=$src"
  if [[ "$src" -eq 77 ]]; then
    # NO-DATA is not PASS for a required continuity gate
    [[ "$rc" -eq 0 ]] && rc=77
  elif [[ "$src" -ne 0 ]]; then
    rc="$src"
  fi
fi

echo "true rc=$rc"
exit "$rc"
