#!/usr/bin/env bash
# rbf_ship_policy.sh — executable do-not-ship / banned RBF prefix policy.
#
# Source or run:
#   source scripts/rbf_ship_policy.sh
#   rbf_policy_check_md5 <full_or_prefix_md5>
#
# Exit codes (always printed by callers as true rc=N):
#   0  allowed
#   1  banned thrash list (AGENTS residual/multi-drive)
#   2  do-not-ship silicon/timing failures
#   3  empty / unparseable md5
#
# Never SSHes. Host-only pure policy.

# Banned thrash prefixes (AGENTS.md / hard-residual-gate-rcsum6): never re-ship.
RBF_BANNED_PREFIX8=(
  8832824e
  75da8bb1
  4d6ee356
  4deaf6cc
  dabdaeb0
)

# Parent-named do-not-ship (freeze / HARD_FAIL timing / known bad).
RBF_DO_NOT_SHIP_PREFIX8=(
  9eb1431a   # freezes silicon
  ff2e3ca3   # HARD_FAIL timing -0.233/-0.517
  f0d3a385
  2890baac
)

# Known-good pins (prefix8 or full). Used by promotion/rollback docs+gates.
RBF_PIN_V2_DAILY_FULL=dfebf2bfd08dd70b473b587dd7e81848
RBF_PIN_DDR_CANDIDATE_FULL=c5382bee73cecdee8220b811e529c297
DAEMON_PIN_V2_HYBRID_FULL=50f4eb925de10e29172999a565c87684
DAEMON_PIN_V2_RELEASE_FULL=7cd10b4d438c714a9b8c4766dc982d59
DAEMON_PIN_DDR_CANDIDATE_FULL=e9f79de217982aff44207664fdb945c5

# Device path contract — never confuse these two files.
DEVICE_CORE_PRODUCT=/media/fat/_Utility/Plex.rbf          # deploy_plex_core.sh target
DEVICE_CORE_V2_DAILY=/media/fat/_Utility/Plex_v2.rbf      # known-good SPI daily / rollback
DEVICE_CORE_V3=/media/fat/_Utility/Plex_v3.rbf
DEVICE_CORE_MENU=/media/fat/menu.rbf

rbf_policy_normalize_md5() {
  # lowercase hex only; accept full or prefix (>=8).
  local s="${1:-}"
  s=$(printf '%s' "$s" | tr 'A-F' 'a-f' | tr -cd '0-9a-f')
  printf '%s' "$s"
}

rbf_policy_prefix8() {
  local s
  s=$(rbf_policy_normalize_md5 "${1:-}")
  if [ "${#s}" -lt 8 ]; then
    printf ''
    return 1
  fi
  printf '%s' "${s:0:8}"
}

rbf_policy_in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# Prints: ALLOW|BANNED|DO_NOT_SHIP|BAD_MD5 reason
rbf_policy_check_md5() {
  local raw="${1:-}"
  local s p8
  s=$(rbf_policy_normalize_md5 "$raw")
  if [ -z "$s" ] || [ "${#s}" -lt 8 ]; then
    echo "BAD_MD5 empty_or_short input='${raw}'"
    return 3
  fi
  p8="${s:0:8}"
  if rbf_policy_in_list "$p8" "${RBF_BANNED_PREFIX8[@]}"; then
    echo "BANNED prefix8=$p8 (thrash/multi-drive hard-fail list — never ship)"
    return 1
  fi
  if rbf_policy_in_list "$p8" "${RBF_DO_NOT_SHIP_PREFIX8[@]}"; then
    echo "DO_NOT_SHIP prefix8=$p8 (silicon freeze / timing HARD_FAIL / named bad)"
    return 2
  fi
  echo "ALLOW prefix8=$p8 md5=$s"
  return 0
}

# Refuse if a path basename is the V2 daily slot when intending product promote.
rbf_policy_assert_product_core_path() {
  local path="${1:-}"
  local base
  base=$(basename "$path")
  case "$base" in
    Plex.rbf)
      echo "OK product-core-path $path"
      return 0
      ;;
    Plex_v2.rbf)
      echo "REFUSE path=$path is the V2 DAILY/ROLLBACK slot — never overwrite with DDR product"
      echo "REFUSE deploy_plex_core.sh writes Plex.rbf; rollback loads Plex_v2.rbf"
      return 10
      ;;
    Plex_v3.rbf)
      echo "REFUSE path=$path is the V3 fallback slot — not DDR product daily"
      return 10
      ;;
    *)
      echo "REFUSE path=$path basename must be Plex.rbf for product promote (got '$base')"
      return 10
      ;;
  esac
}

# CLI entry when executed (not sourced).
if [ "${BASH_SOURCE[0]-}" = "${0:-}" ]; then
  set -euo pipefail
  cmd="${1:-check}"
  case "$cmd" in
    check)
      set +e
      out=$(rbf_policy_check_md5 "${2:-}")
      rc=$?
      set -e
      printf '%s\n' "$out"
      echo "true rc=$rc"
      exit "$rc"
      ;;
    assert-product-path)
      set +e
      out=$(rbf_policy_assert_product_core_path "${2:-}")
      rc=$?
      set -e
      printf '%s\n' "$out"
      echo "true rc=$rc"
      exit "$rc"
      ;;
    list)
      echo "BANNED_PREFIX8=${RBF_BANNED_PREFIX8[*]}"
      echo "DO_NOT_SHIP_PREFIX8=${RBF_DO_NOT_SHIP_PREFIX8[*]}"
      echo "PIN_V2_DAILY=$RBF_PIN_V2_DAILY_FULL"
      echo "PIN_DDR_CANDIDATE=$RBF_PIN_DDR_CANDIDATE_FULL"
      echo "DEVICE_CORE_PRODUCT=$DEVICE_CORE_PRODUCT"
      echo "DEVICE_CORE_V2_DAILY=$DEVICE_CORE_V2_DAILY"
      echo "true rc=0"
      exit 0
      ;;
    *)
      echo "usage: $0 {check <md5>|assert-product-path <path>|list}" >&2
      echo "true rc=9"
      exit 9
      ;;
  esac
fi
