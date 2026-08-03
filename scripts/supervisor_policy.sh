#!/usr/bin/env bash
# supervisor_policy.sh — single source of truth helpers for misterplexd_supervise.
#
# Device cold-boot survival depends on the on-disk supervisor. Parent-measured
# drift (2026-08-02): installed md5 59286a1d existed in NO commit. This policy:
#   1) Names the repo file that deploy MUST ship
#   2) Asserts md5 shape (32 hex) before equality — never fuzzy-trim glue like
#      the V2_MD5 `…81848set +e` blind-RED class
#   3) Asserts proven capabilities (HEALTHY_SECS backoff reset, exact-argv0
#      resume_stopped_main, flock single-instance)
#   4) Boot-hook strip patterns that match v1 AND v2 roots (never leave two lines)
#
# Source:
#   source scripts/supervisor_policy.sh
#   supervisor_repo_path / supervisor_repo_md5 / supervisor_assert_*
#
# Exit codes: 0 OK, 1 mismatch/refuse, 3 bad args / malformed shape, 4 NO-DATA

set -u

SUPERVISOR_REPO_RELPATH="${SUPERVISOR_REPO_RELPATH:-scripts/misterplexd_supervise.sh}"
SUPERVISOR_DEVICE_RELPATH="${SUPERVISOR_DEVICE_RELPATH:-bin/misterplexd_supervise.sh}"
SUPERVISOR_LOCK_PATH="${SUPERVISOR_LOCK_PATH:-/tmp/misterplexd_supervise.lock}"
SUPERVISOR_HEALTHY_SECS_DEFAULT="${SUPERVISOR_HEALTHY_SECS_DEFAULT:-120}"
SUPERVISOR_MAIN_ARGV0="${SUPERVISOR_MAIN_ARGV0:-/media/fat/MiSTer}"

# Shared md5 shape gate (also the V2_MD5 capture fix surface).
# Contaminated values like "<32hex>set +e" MUST fail closed — do not strip.
supervisor_assert_md5_shape() {
  local label="${1:-md5}" got="${2:-}"
  if [ -z "$got" ]; then
    echo "NO-DATA ${label} got='' (empty observation — not a mismatch)"
    return 4
  fi
  # Exactly 32 hex chars. Reject glue/noise (set +e, whitespace, paths).
  # Parent V2_MD5 class: $(ssh) fused echo with next `set +e` → `…81848set +e`.
  if printf '%s' "$got" | grep -Eq '^[0-9a-fA-F]{32}$'; then
    echo "MD5_SHAPE_OK ${label}=$(printf '%s' "$got" | tr 'A-F' 'a-f')"
    return 0
  fi
  echo "FAIL ${label} reason=malformed_capture got='${got}' want=exactly_32_hex"
  echo "FAIL ${label} detail=never_fuzzy_trim_set_+e_glue"
  return 3
}

supervisor_normalize_md5() {
  printf '%s' "${1:-}" | tr 'A-F' 'a-f' | tr -d ' \t\r\n'
}

supervisor_repo_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s' "$here"
}

supervisor_repo_path() {
  local root="${1:-$(supervisor_repo_root)}"
  printf '%s/%s' "$root" "$SUPERVISOR_REPO_RELPATH"
}

supervisor_repo_md5() {
  local path="${1:-$(supervisor_repo_path)}"
  if [ ! -f "$path" ]; then
    echo "FAIL supervisor_repo_md5 missing path=$path" >&2
    return 1
  fi
  md5sum "$path" | awk '{print $1}'
}

# Compare got vs want after shape check. Empty got → NO-DATA rc=4.
# Never leave set -e toggled for the caller (parent capture-glue class).
supervisor_assert_md5_match() {
  local label="${1:-supervisor}" got="${2:-}" want="${3:-}"
  local ng nw rc
  supervisor_assert_md5_shape "${label}-got" "$got" || {
    rc=$?
    return "$rc"
  }
  supervisor_assert_md5_shape "${label}-want" "$want" || {
    rc=$?
    return "$rc"
  }
  ng=$(supervisor_normalize_md5 "$got")
  nw=$(supervisor_normalize_md5 "$want")
  if [ "$ng" = "$nw" ]; then
    echo "OK ${label} md5=$ng"
    return 0
  fi
  echo "FAIL ${label} reason=md5_mismatch got=$ng want=$nw"
  echo "FAIL ${label} detail=installed_supervisor_must_equal_repo_SoT"
  return 1
}

# Proven behaviour required on any shippable supervisor (parent HW contract).
supervisor_assert_capabilities() {
  local path="${1:-}" applied=0
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    echo "FAIL supervisor_caps reason=missing path='${path}'"
    return 1
  fi
  local body
  body=$(cat "$path")

  if printf '%s\n' "$body" | grep -qE 'HEALTHY_SECS=([0-9]+|\$\{?[A-Za-z_][A-Za-z0-9_]*:-120\}?)'; then
    echo "CAP_OK healthy_secs"
    applied=$((applied + 1))
  else
    echo "FAIL supervisor_caps reason=missing_HEALTHY_SECS path=$path"
    return 1
  fi

  if printf '%s\n' "$body" | grep -q 'resume_stopped_main'; then
    echo "CAP_OK resume_stopped_main_fn"
    applied=$((applied + 1))
  else
    echo "FAIL supervisor_caps reason=missing_resume_stopped_main path=$path"
    return 1
  fi

  # Exact argv0 — substring match on MiSTer is the flock-class trap.
  if printf '%s\n' "$body" | grep -F "\"$SUPERVISOR_MAIN_ARGV0\"" >/dev/null 2>&1 \
    || printf '%s\n' "$body" | grep -F "=$SUPERVISOR_MAIN_ARGV0" >/dev/null 2>&1 \
    || printf '%s\n' "$body" | grep -F "\"$SUPERVISOR_MAIN_ARGV0\"" >/dev/null 2>&1; then
    echo "CAP_OK exact_main_argv0"
    applied=$((applied + 1))
  else
    # allow single-quoted form
    if printf '%s\n' "$body" | grep -F "$SUPERVISOR_MAIN_ARGV0" >/dev/null 2>&1 \
      && printf '%s\n' "$body" | grep -q 'a0.*='; then
      echo "CAP_OK exact_main_argv0"
      applied=$((applied + 1))
    else
      echo "FAIL supervisor_caps reason=missing_exact_argv0 want=$SUPERVISOR_MAIN_ARGV0"
      return 1
    fi
  fi

  if printf '%s\n' "$body" | grep -qE 'flock[[:space:]]+-n'; then
    echo "CAP_OK flock_single_instance"
    applied=$((applied + 1))
  else
    echo "FAIL supervisor_caps reason=missing_flock_n path=$path"
    return 1
  fi

  # Must not kill child on a timer (only wait + respawn; TERM/INT trap OK).
  if printf '%s\n' "$body" | grep -qiE 'sleep[[:space:]]+[0-9]+.*kill|kill.*timeout|health.*kill'; then
    echo "FAIL supervisor_caps reason=timer_or_health_kill_forbidden"
    return 1
  fi
  echo "CAP_OK no_timer_kill"
  applied=$((applied + 1))

  echo "SUPERVISOR_CAPS_OK path=$path applied_match=$applied"
  return 0
}

# Grep -vE pattern that strips ALL MiSTerPlex autostart lines (v1 + v2 + bare).
# Used by deploy boot-hook rewrite so a v1 line cannot coexist with v2.
supervisor_boot_strip_eregex() {
  # shellcheck disable=SC2016
  printf '%s' \
    'misterplexd_supervise\.sh|plexctl_supervise\.sh|/misterplex/bin/misterplexd|/misterplex_v2/bin/misterplexd|misterplex/bin/misterplexd|misterplex_v2/bin/misterplexd'
}

supervisor_device_path_for_root() {
  local root="${1:-}"
  [ -n "$root" ] || return 3
  printf '%s/%s' "$root" "$SUPERVISOR_DEVICE_RELPATH"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cmd="${1:-}"
  case "$cmd" in
    repo-md5)
      md=$(supervisor_repo_md5 "${2:-}")
      echo "SUPERVISOR_REPO_MD5=$md"
      echo "SUPERVISOR_REPO_PATH=$(supervisor_repo_path "${2:-}")"
      echo "true rc=0"
      exit 0
      ;;
    assert-md5)
      set +e
      supervisor_assert_md5_match "${2:-sup}" "${3:-}" "${4:-}"
      rc=$?
      set -e
      echo "true rc=$rc"
      exit "$rc"
      ;;
    assert-shape)
      set +e
      supervisor_assert_md5_shape "${2:-md5}" "${3:-}"
      rc=$?
      set -e
      echo "true rc=$rc"
      exit "$rc"
      ;;
    assert-caps)
      set +e
      supervisor_assert_capabilities "${2:-$(supervisor_repo_path)}"
      rc=$?
      set -e
      echo "true rc=$rc"
      exit "$rc"
      ;;
    strip-re)
      supervisor_boot_strip_eregex
      echo
      exit 0
      ;;
    *)
      echo "usage: $0 {repo-md5|assert-md5|assert-shape|assert-caps|strip-re} ..." >&2
      echo "true rc=9"
      exit 9
      ;;
  esac
fi
