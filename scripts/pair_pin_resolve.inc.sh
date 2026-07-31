#!/usr/bin/env bash
# pair_pin_resolve.inc.sh — resolve accepted daemon pins from validated-pair claim.
# Source after rbf_ship_policy or alone.
#
# Order:
#   1) artifacts/validated-pair/CURRENT (DAEMON_MD5 or DAEMON_PREFIX8)
#   2) artifacts/validated-pair/ACCEPTED_DAEMONS
#   3) built-in history (edc3a46b, e9f79de2, SPI hybrids)
# Never invent a full 32 from a prefix.

_PAIR_PIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAIR_PIN_DIR="${PAIR_PIN_DIR:-$_PAIR_PIN_ROOT/artifacts/validated-pair}"
PAIR_PIN_CURRENT="${PAIR_PIN_CURRENT:-$PAIR_PIN_DIR/CURRENT}"
PAIR_PIN_ACCEPTED="${PAIR_PIN_ACCEPTED:-$PAIR_PIN_DIR/ACCEPTED_DAEMONS}"

pair_pin_normalize() {
  printf '%s' "${1:-}" | tr 'A-F' 'a-f' | tr -cd '0-9a-f'
}

# Print CURRENT daemon identity lines: CURRENT_DAEMON_MD5= CURRENT_DAEMON_PREFIX8= CURRENT_CORE_MD5=
pair_pin_read_current() {
  local f="${1:-$PAIR_PIN_CURRENT}" k v
  CURRENT_DAEMON_MD5=""
  CURRENT_DAEMON_PREFIX8=""
  CURRENT_CORE_MD5=""
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    k="${line%%=*}"; v="${line#*=}"
    v=$(pair_pin_normalize "$v")
    case "$k" in
      DAEMON_MD5) CURRENT_DAEMON_MD5="$v" ;;
      DAEMON_PREFIX8) CURRENT_DAEMON_PREFIX8="$v" ;;
      CORE_MD5) CURRENT_CORE_MD5="$v" ;;
    esac
  done <"$f"
  if [ -z "$CURRENT_DAEMON_PREFIX8" ] && [ -n "$CURRENT_DAEMON_MD5" ]; then
    CURRENT_DAEMON_PREFIX8="${CURRENT_DAEMON_MD5:0:8}"
  fi
  echo "CURRENT_DAEMON_MD5=$CURRENT_DAEMON_MD5"
  echo "CURRENT_DAEMON_PREFIX8=$CURRENT_DAEMON_PREFIX8"
  echo "CURRENT_CORE_MD5=$CURRENT_CORE_MD5"
  [ -n "$CURRENT_DAEMON_MD5" ] || [ -n "$CURRENT_DAEMON_PREFIX8" ]
}

# True if md5 (full or prefix) is in CURRENT or ACCEPTED list or built-in history.
pair_pin_daemon_accepted() {
  local got p8 line
  got=$(pair_pin_normalize "${1:-}")
  [ "${#got}" -ge 8 ] || return 1
  p8="${got:0:8}"

  if [ -f "$PAIR_PIN_CURRENT" ]; then
    pair_pin_read_current "$PAIR_PIN_CURRENT" >/dev/null 2>&1 || true
    if [ -n "${CURRENT_DAEMON_MD5:-}" ] && [ "${#CURRENT_DAEMON_MD5}" -ge 32 ] && [ "${got:0:32}" = "${CURRENT_DAEMON_MD5:0:32}" ]; then
      return 0
    fi
    if [ -n "${CURRENT_DAEMON_PREFIX8:-}" ] && [ "$p8" = "$CURRENT_DAEMON_PREFIX8" ]; then
      return 0
    fi
  fi

  if [ -f "$PAIR_PIN_ACCEPTED" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\#*) continue ;; esac
      line=$(pair_pin_normalize "$line")
      [ "${#line}" -ge 8 ] || continue
      if [ "${#line}" -ge 32 ] && [ "${#got}" -ge 32 ]; then
        [ "${got:0:32}" = "${line:0:32}" ] && return 0
      fi
      [ "${got:0:8}" = "${line:0:8}" ] && return 0
      [ "${line:0:8}" = "${got:0:8}" ] && return 0
    done <"$PAIR_PIN_ACCEPTED"
  fi

  # Built-in history (prefix8) — last resort so gates still know rollbacks.
  case "$p8" in
    865d4c8a|edc3a46b|e9f79de2|50f4eb92|7cd10b4d|3e2cbb98) return 0 ;;
  esac
  return 1
}

# Primary CURRENT pin for gates (prefix8 or full). Prefer full when known.
pair_pin_current_daemon() {
  if pair_pin_read_current >/dev/null 2>&1; then
    if [ -n "${CURRENT_DAEMON_MD5:-}" ] && [ "${#CURRENT_DAEMON_MD5}" -ge 32 ]; then
      printf '%s' "${CURRENT_DAEMON_MD5:0:32}"
      return 0
    fi
    if [ -n "${CURRENT_DAEMON_PREFIX8:-}" ]; then
      printf '%s' "$CURRENT_DAEMON_PREFIX8"
      return 0
    fi
  fi
  # Fall back to rbf policy if sourced
  if declare -F rbf_policy_resolve_ddr_daemon_full >/dev/null 2>&1; then
    rbf_policy_resolve_ddr_daemon_full
    return 0
  fi
  printf '%s' "865d4c8a"
}
