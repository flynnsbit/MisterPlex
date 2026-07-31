#!/usr/bin/env bash
# boot_hook_policy.sh — pure policy for MiSTer user-startup + pair root.
#
# Parent 2026-07-31 P0: gate was GREEN against DECOY file
#   /media/fat/linux/_user-startup.sh
# while MiSTer init actually runs (from /etc/init.d/S99user):
#   USER_SCRIPT="/media/fat/linux/user-startup.sh"
# The real boot file still had v1 supervise → cold boot would start stale
# 54f1d916. A gate that validates a decoy manufactures confidence.
#
# RULE: never hardcode the startup path. Derive USER_SCRIPT from S99user.
# If S99user is missing/unparseable → hard FAIL (no guess fallback).
#
# DECOY POLICY: _user-startup.sh (underscore) is NOT executed by MiSTer.
# It must be INERT for MiSTerPlex autostart (no misterplexd lines). Two files
# that look identical and behave differently is the trap that caught us.
#
# Source or run:
#   source scripts/boot_hook_policy.sh
#   boot_hook_parse_user_script <s99_body>
#   boot_hook_check_body <hook_text> <expect_root>
#   boot_hook_check_decoy_body <decoy_text>
#   boot_hook_render_body <expect_root> <old_hook_text>
#
# Exit codes: 0 OK, 1 mismatch/refuse, 3 bad args / unresolvable

# Observed defaults on this lab (documentation only — live resolve must use S99user).
BOOT_HOOK_INIT_PATH="${BOOT_HOOK_INIT_PATH:-/etc/init.d/S99user}"
BOOT_HOOK_DECOY_PATH="${BOOT_HOOK_DECOY_PATH:-/media/fat/linux/_user-startup.sh}"
# Legacy mistaken default — kept as the known decoy name for tests/docs.
BOOT_HOOK_LEGACY_DECOY_PATH="/media/fat/linux/_user-startup.sh"
# Populated only after successful parse; empty means unresolved.
BOOT_HOOK_DEVICE_PATH="${BOOT_HOOK_DEVICE_PATH:-}"
BOOT_HOOK_V1_ROOT="${BOOT_HOOK_V1_ROOT:-/media/fat/misterplex}"
BOOT_HOOK_V2_ROOT="${BOOT_HOOK_V2_ROOT:-/media/fat/misterplex_v2}"
BOOT_HOOK_DEFAULT_ROOT="${BOOT_HOOK_DEFAULT_ROOT:-$BOOT_HOOK_V2_ROOT}"

boot_hook_supervise_relpath() {
  printf 'bin/misterplexd_supervise.sh'
}

boot_hook_line_for_root() {
  local root="${1:-}"
  [ -n "$root" ] || return 3
  printf 'nohup %s/%s >>%s/misterplexd_supervise.log 2>&1 &\n' \
    "$root" "$(boot_hook_supervise_relpath)" "$root"
}

# Parse USER_SCRIPT= from S99user body. Prints path on stdout; rc 0/1/3.
# Accepts USER_SCRIPT="..." or USER_SCRIPT='...' or unquoted.
boot_hook_parse_user_script() {
  local body="${1:-}" line val
  if [ -z "$body" ]; then
    echo "BOOT_HOOK_RESOLVE_FAIL reason=empty_init_body" >&2
    return 3
  fi
  if [ "$body" = "MISSING" ]; then
    echo "BOOT_HOOK_RESOLVE_FAIL reason=init_missing path=${BOOT_HOOK_INIT_PATH}" >&2
    return 3
  fi
  # Prefer the assignment form used by MiSTer S99user.
  line=$(printf '%s\n' "$body" | grep -E '^[[:space:]]*USER_SCRIPT=' | tail -1 || true)
  if [ -z "$line" ]; then
    echo "BOOT_HOOK_RESOLVE_FAIL reason=USER_SCRIPT_unparseable" >&2
    return 3
  fi
  val=${line#USER_SCRIPT=}
  val=${val#${val%%[![:space:]]*}}  # ltrim
  # strip quotes
  if [[ "$val" == \"*\" ]]; then val=${val:1:${#val}-2}; fi
  if [[ "$val" == \'*\' ]]; then val=${val:1:${#val}-2}; fi
  val=${val%%[[:space:]#]*}
  if [ -z "$val" ] || [[ "$val" != /* ]]; then
    echo "BOOT_HOOK_RESOLVE_FAIL reason=USER_SCRIPT_not_absolute got='$val'" >&2
    return 3
  fi
  # Hard refuse if someone points USER_SCRIPT at the known decoy name by mistake
  # — still "derived", but call it out; MiSTer can legally point anywhere, so
  # we only WARN via stdout tag when it equals the legacy decoy path.
  printf '%s\n' "$val"
  return 0
}

# Given init body, set BOOT_HOOK_DEVICE_PATH and print BOOT_HOOK_PATH=...
boot_hook_resolve_from_init_body() {
  local body="${1:-}" path rc
  set +e
  path=$(boot_hook_parse_user_script "$body" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] || [ -z "$path" ]; then
    boot_hook_parse_user_script "$body" >/dev/null || true
    echo "BOOT_HOOK_PATH="
    echo "BOOT_HOOK_RESOLVED=0"
    return 3
  fi
  BOOT_HOOK_DEVICE_PATH="$path"
  echo "BOOT_HOOK_PATH=$path"
  echo "BOOT_HOOK_RESOLVED=1"
  echo "BOOT_HOOK_INIT=$BOOT_HOOK_INIT_PATH"
  echo "BOOT_HOOK_DECOY=$BOOT_HOOK_DECOY_PATH"
  if [ "$path" = "$BOOT_HOOK_LEGACY_DECOY_PATH" ]; then
    echo "BOOT_HOOK_WARN reason=USER_SCRIPT_is_legacy_decoy_name"
  fi
  # Gate must never silently use underscore decoy as "the" path without init.
  return 0
}

# Remote snippet: observe what the system actually consults (like /proc/exe).
# Prints BOOT_HOOK_PATH= / BOOT_HOOK_RESOLVED= / INIT body markers / decoy scan.
boot_hook_remote_resolve_snippet() {
  cat <<'REMOTE'
set +e
INIT=/etc/init.d/S99user
DECOY=/media/fat/linux/_user-startup.sh
echo "BOOT_HOOK_INIT=$INIT"
if [ ! -f "$INIT" ]; then
  echo "BOOT_HOOK_PATH="
  echo "BOOT_HOOK_RESOLVED=0"
  echo "BOOT_HOOK_RESOLVE_FAIL reason=init_missing"
else
  line=$(grep -E '^[[:space:]]*USER_SCRIPT=' "$INIT" | tail -1)
  echo "BOOT_HOOK_INIT_LINE=$line"
  val=${line#USER_SCRIPT=}
  # trim
  val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  val=$(printf '%s' "$val" | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//')
  if [ -z "$val" ] || [ "${val#/}" = "$val" ]; then
    echo "BOOT_HOOK_PATH="
    echo "BOOT_HOOK_RESOLVED=0"
    echo "BOOT_HOOK_RESOLVE_FAIL reason=USER_SCRIPT_unparseable"
  else
    echo "BOOT_HOOK_PATH=$val"
    echo "BOOT_HOOK_RESOLVED=1"
    if [ -f "$val" ]; then
      echo "BOOT_HOOK_REAL_PRESENT=1"
    else
      echo "BOOT_HOOK_REAL_PRESENT=0"
    fi
  fi
fi
echo "BOOT_HOOK_DECOY=$DECOY"
if [ -f "$DECOY" ]; then
  echo "BOOT_HOOK_DECOY_PRESENT=1"
else
  echo "BOOT_HOOK_DECOY_PRESENT=0"
fi
REMOTE
}

boot_hook_line_is_misterplex() {
  local line="${1:-}"
  case "$line" in
    *misterplexd_supervise.sh*) return 0 ;;
    */misterplex/bin/misterplexd*|*/misterplex_v2/bin/misterplexd*) return 0 ;;
    *misterplexd\ *--conf*|*misterplexd\ --name*) return 0 ;;
    *) return 1 ;;
  esac
}

boot_hook_scan_body() {
  local body="${1:-}" line n=0 roots="" has_v1=0 has_v2=0 has_bare=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    if printf '%s\n' "$line" | grep -q 'misterplexd_supervise\.sh'; then
      n=$((n + 1))
      case "$line" in
        *"${BOOT_HOOK_V1_ROOT}/bin/misterplexd_supervise.sh"*) has_v1=1; roots="${roots}${roots:+ }${BOOT_HOOK_V1_ROOT}" ;;
        *"${BOOT_HOOK_V2_ROOT}/bin/misterplexd_supervise.sh"*) has_v2=1; roots="${roots}${roots:+ }${BOOT_HOOK_V2_ROOT}" ;;
        *) roots="${roots}${roots:+ }UNKNOWN" ;;
      esac
    elif boot_hook_line_is_misterplex "$line"; then
      has_bare=1
      n=$((n + 1))
      case "$line" in
        *"${BOOT_HOOK_V1_ROOT}/bin/misterplexd"*) has_v1=1; roots="${roots}${roots:+ }${BOOT_HOOK_V1_ROOT}-bare" ;;
        *"${BOOT_HOOK_V2_ROOT}/bin/misterplexd"*) has_v2=1; roots="${roots}${roots:+ }${BOOT_HOOK_V2_ROOT}-bare" ;;
        *) roots="${roots}${roots:+ }BARE" ;;
      esac
    fi
  done <<<"$body"
  echo "N_SUP=$n"
  echo "ROOTS=$roots"
  echo "HAS_V1=$has_v1"
  echo "HAS_V2=$has_v2"
  echo "HAS_BARE=$has_bare"
}

# Decoy must be inert: zero MiSTerPlex autostart lines.
boot_hook_check_decoy_body() {
  local body="${1:-}" scan n
  if [ -z "$body" ] || [ "$body" = "MISSING" ] || [ "$body" = "ABSENT" ]; then
    echo "BOOT_HOOK_DECOY_OK reason=absent_or_empty"
    return 0
  fi
  scan=$(boot_hook_scan_body "$body")
  n=$(printf '%s\n' "$scan" | sed -n 's/^N_SUP=//p')
  printf '%s\n' "$scan" | sed 's/^/DECOY_/'
  if [ "${n:-0}" -gt 0 ]; then
    echo "BOOT_HOOK_DECOY_FAIL reason=decoy_has_misterplex_autostart n=$n"
    echo "BOOT_HOOK_DECOY_FAIL detail=underscore_file_is_not_executed_by_S99user_but_looks_live"
    echo "BOOT_HOOK_DECOY_FAIL detail=strip_misterplex_lines_from_${BOOT_HOOK_DECOY_PATH}"
    return 1
  fi
  echo "BOOT_HOOK_DECOY_OK reason=inert_no_misterplex_autostart"
  return 0
}

# rc 0 if REAL hook body autostarts exactly one supervise for expect_root.
boot_hook_check_body() {
  local body="${1:-}" expect="${2:-$BOOT_HOOK_DEFAULT_ROOT}"
  local scan n has_v1 has_v2 has_bare want_line
  if [ -z "$expect" ]; then
    echo "BOOT_HOOK_REFUSE reason=empty_expect_root"
    return 3
  fi
  scan=$(boot_hook_scan_body "$body")
  n=$(printf '%s\n' "$scan" | sed -n 's/^N_SUP=//p')
  has_v1=$(printf '%s\n' "$scan" | sed -n 's/^HAS_V1=//p')
  has_v2=$(printf '%s\n' "$scan" | sed -n 's/^HAS_V2=//p')
  has_bare=$(printf '%s\n' "$scan" | sed -n 's/^HAS_BARE=//p')
  printf '%s\n' "$scan"

  if [ "${has_bare:-0}" = "1" ]; then
    echo "BOOT_HOOK_FAIL reason=bare_misterplexd_autostart (must use misterplexd_supervise.sh)"
    return 1
  fi
  if [ "${n:-0}" -eq 0 ]; then
    echo "BOOT_HOOK_FAIL reason=no_supervise_line expect_root=$expect"
    echo "BOOT_HOOK_FAIL detail=cold_boot_will_not_start_validated_pair"
    return 1
  fi
  if [ "${n:-0}" -gt 1 ]; then
    echo "BOOT_HOOK_FAIL reason=multiple_autostart_lines n=$n (v1+v2 double-daemon class)"
    return 1
  fi
  want_line=$(boot_hook_line_for_root "$expect" | tr -d '\n')
  if ! printf '%s\n' "$body" | grep -F "$expect/bin/misterplexd_supervise.sh" >/dev/null 2>&1; then
    echo "BOOT_HOOK_FAIL reason=supervise_root_mismatch expect=$expect"
    echo "BOOT_HOOK_FAIL detail=hook_does_not_match_live_pair_root"
    return 1
  fi
  if [ "$expect" = "$BOOT_HOOK_V2_ROOT" ] && [ "${has_v1:-0}" = "1" ]; then
    echo "BOOT_HOOK_FAIL reason=v1_hook_present_while_expect_v2"
    return 1
  fi
  if [ "$expect" = "$BOOT_HOOK_V1_ROOT" ] && [ "${has_v2:-0}" = "1" ]; then
    echo "BOOT_HOOK_FAIL reason=v2_hook_present_while_expect_v1"
    return 1
  fi
  echo "BOOT_HOOK_OK expect_root=$expect line=$(printf '%s' "$want_line" | head -c 120)"
  return 0
}

# Render new REAL hook body: strip all MiSTerPlex autostart lines, append exactly one.
boot_hook_render_body() {
  local expect="${1:-$BOOT_HOOK_DEFAULT_ROOT}" old="${2:-}" line
  local -a kept=()
  while IFS= read -r line || [ -n "$line" ]; do
    if boot_hook_line_is_misterplex "$line"; then
      continue
    fi
    case "$line" in
      '# MiSTerPlex pair autostart'*) continue ;;
      '# MiSTerPlex companion'*) continue ;;
    esac
    kept+=("$line")
  done <<<"$old"
  local i=${#kept[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    [ -n "${kept[$i]}" ] && break
    unset "kept[$i]"
  done
  if [ "${#kept[@]}" -gt 0 ]; then
    printf '%s\n' "${kept[@]}"
  fi
  printf '\n# MiSTerPlex pair autostart (atomic with core+daemon+conf; do not hand-edit)\n'
  boot_hook_line_for_root "$expect"
}

# Render inert decoy: strip ALL misterplex autostart; keep other lines.
boot_hook_render_inert_decoy() {
  local old="${1:-}" line
  local -a kept=()
  while IFS= read -r line || [ -n "$line" ]; do
    if boot_hook_line_is_misterplex "$line"; then
      continue
    fi
    case "$line" in
      '# MiSTerPlex pair autostart'*) continue ;;
      '# MiSTerPlex companion'*) continue ;;
      '# MiSTerPlex DECOY'*) continue ;;
    esac
    kept+=("$line")
  done <<<"$old"
  if [ "${#kept[@]}" -gt 0 ]; then
    printf '%s\n' "${kept[@]}"
  fi
  printf '\n# MiSTerPlex DECOY: this underscore file is NOT run by S99user.\n'
  printf '# Real boot hook is USER_SCRIPT from /etc/init.d/S99user (user-startup.sh).\n'
}

boot_hook_idempotence_patterns() {
  cat <<'EOF'
misterplexd_supervise\.sh
/misterplex/bin/misterplexd
/misterplex_v2/bin/misterplexd
misterplex/bin/misterplexd
misterplex_v2/bin/misterplexd
EOF
}

# Static audit: source files must not hardcode decoy as the sole boot path
# without going through resolve. Used by unit tests.
boot_hook_audit_source_hardcodes() {
  local root="${1:-}"
  local f hits=0
  [ -n "$root" ] || return 3
  for f in \
    "$root/scripts/promotion_gate_check.sh" \
    "$root/scripts/rollback_v2.sh" \
    "$root/scripts/deploy_misterplexd.sh"
  do
    [ -f "$f" ] || continue
    # Flag lines that cat/write the decoy path as the primary hook without resolve nearby.
    if grep -n "linux/_user-startup\.sh" "$f" | grep -vE 'DECOY|decoy|legacy|WARN|NOT run|underscore' >/dev/null 2>&1; then
      echo "AUDIT_HIT file=$f"
      grep -n "linux/_user-startup\.sh" "$f" | grep -vE 'DECOY|decoy|legacy|WARN|NOT run|underscore' | sed 's/^/  /'
      hits=$((hits + 1))
    fi
  done
  if [ "$hits" -gt 0 ]; then
    echo "BOOT_HOOK_AUDIT_FAIL hits=$hits"
    return 1
  fi
  echo "BOOT_HOOK_AUDIT_OK"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cmd="${1:-}"
  case "$cmd" in
    check)
      body="${2:-}"
      expect="${3:-$BOOT_HOOK_DEFAULT_ROOT}"
      if [ -f "$body" ]; then body=$(cat "$body"); fi
      set +e
      boot_hook_check_body "$body" "$expect"
      rc=$?
      set -e
      echo "true rc=$rc"
      exit "$rc"
      ;;
    check-decoy)
      body="${2:-}"
      if [ -f "$body" ]; then body=$(cat "$body"); fi
      set +e
      boot_hook_check_decoy_body "$body"
      rc=$?
      set -e
      echo "true rc=$rc"
      exit "$rc"
      ;;
    parse-init)
      body="${2:-}"
      if [ -f "$body" ]; then body=$(cat "$body"); fi
      set +e
      path=$(boot_hook_parse_user_script "$body")
      rc=$?
      set -e
      echo "USER_SCRIPT=$path"
      echo "true rc=$rc"
      exit "$rc"
      ;;
    resolve)
      body="${2:-}"
      if [ -f "$body" ]; then body=$(cat "$body"); fi
      set +e
      boot_hook_resolve_from_init_body "$body"
      rc=$?
      set -e
      echo "true rc=$rc"
      exit "$rc"
      ;;
    render)
      expect="${2:-$BOOT_HOOK_DEFAULT_ROOT}"
      old="${3:-}"
      if [ -f "$old" ]; then old=$(cat "$old"); fi
      boot_hook_render_body "$expect" "$old"
      echo "true rc=0" >&2
      exit 0
      ;;
    render-decoy)
      old="${2:-}"
      if [ -f "$old" ]; then old=$(cat "$old"); fi
      boot_hook_render_inert_decoy "$old"
      exit 0
      ;;
    line)
      boot_hook_line_for_root "${2:-$BOOT_HOOK_DEFAULT_ROOT}"
      exit 0
      ;;
    audit)
      set +e
      boot_hook_audit_source_hardcodes "${2:-$(cd "$(dirname "$0")/.." && pwd)}"
      rc=$?
      set -e
      echo "true rc=$rc"
      exit "$rc"
      ;;
    *)
      echo "usage: $0 {check|check-decoy|parse-init|resolve|render|render-decoy|line|audit} ..." >&2
      echo "true rc=9"
      exit 9
      ;;
  esac
fi
