#!/usr/bin/env bash
# boot_hook_policy.sh — pure policy for MiSTer _user-startup.sh + pair root.
#
# Parent 2026-07-31 measured cold-boot defect:
#   hook pointed at v1 /media/fat/misterplex/bin/misterplexd_supervise.sh
#   with stale daemon 54f1d916 and untuned conf, while live validated pair
#   was misterplex_v2 + edc3a46b. /tmp/plexctl_supervise.sh does not survive reboot.
#
# Idempotence trap: grepping only 'misterplex/bin/misterplexd' does NOT match
# 'misterplex_v2/bin/misterplexd', so v1+v2 lines can coexist → TWO daemons
# both binding :3005 and driving DDR banks.
#
# Source or run:
#   source scripts/boot_hook_policy.sh
#   boot_hook_check_body <hook_text> <expect_root>
#   boot_hook_render_body <expect_root> <old_hook_text>
#
# Exit codes: 0 OK, 1 mismatch/refuse, 3 bad args

BOOT_HOOK_DEVICE_PATH="${BOOT_HOOK_DEVICE_PATH:-/media/fat/linux/_user-startup.sh}"
BOOT_HOOK_V1_ROOT="${BOOT_HOOK_V1_ROOT:-/media/fat/misterplex}"
BOOT_HOOK_V2_ROOT="${BOOT_HOOK_V2_ROOT:-/media/fat/misterplex_v2}"
# Default daily-driver pair root (DDR + SPI hybrid on this lab both use v2).
BOOT_HOOK_DEFAULT_ROOT="${BOOT_HOOK_DEFAULT_ROOT:-$BOOT_HOOK_V2_ROOT}"

boot_hook_supervise_relpath() {
  printf 'bin/misterplexd_supervise.sh'
}

boot_hook_line_for_root() {
  local root="${1:-}"
  [ -n "$root" ] || return 3
  # Single line boot starts the durable supervisor (which flock-guards itself).
  printf 'nohup %s/%s >>%s/misterplexd_supervise.log 2>&1 &\n' \
    "$root" "$(boot_hook_supervise_relpath)" "$root"
}

# True if a hook line is any MiSTerPlex boot autostart (supervise or bare daemon).
boot_hook_line_is_misterplex() {
  local line="${1:-}"
  case "$line" in
    *misterplexd_supervise.sh*) return 0 ;;
    */misterplex/bin/misterplexd*|*/misterplex_v2/bin/misterplexd*) return 0 ;;
    *misterplexd\ *--conf*|*misterplexd\ --name*) return 0 ;;
    *) return 1 ;;
  esac
}

# Count supervise lines and report which roots they target.
# Prints: N_SUP= ROOTS= HAS_V1= HAS_V2= HAS_BARE=
boot_hook_scan_body() {
  local body="${1:-}" line n=0 roots="" has_v1=0 has_v2=0 has_bare=0 r
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
      # bare daemon autostart (legacy package_release / old deploy)
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

# rc 0 if hook body autostarts exactly one supervise for expect_root, nothing else.
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
  # Exactly one line — must be supervise under expect root.
  want_line=$(boot_hook_line_for_root "$expect" | tr -d '\n')
  if ! printf '%s\n' "$body" | grep -F "$expect/bin/misterplexd_supervise.sh" >/dev/null 2>&1; then
    echo "BOOT_HOOK_FAIL reason=supervise_root_mismatch expect=$expect"
    echo "BOOT_HOOK_FAIL detail=hook_does_not_match_live_pair_root"
    return 1
  fi
  # If expect is v2, v1 must be absent (and vice versa).
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

# Render new hook body: strip all MiSTerPlex autostart lines, append exactly one.
boot_hook_render_body() {
  local expect="${1:-$BOOT_HOOK_DEFAULT_ROOT}" old="${2:-}" line
  local -a kept=()
  while IFS= read -r line || [ -n "$line" ]; do
    if boot_hook_line_is_misterplex "$line"; then
      continue
    fi
    # drop previous marker-only lines we own
    case "$line" in
      '# MiSTerPlex pair autostart'*) continue ;;
      '# MiSTerPlex companion'*) continue ;;
    esac
    kept+=("$line")
  done <<<"$old"
  # trim trailing empty lines
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

# Idempotence patterns that MUST match BOTH roots (the old bug).
boot_hook_idempotence_patterns() {
  cat <<'EOF'
misterplexd_supervise\.sh
/misterplex/bin/misterplexd
/misterplex_v2/bin/misterplexd
misterplex/bin/misterplexd
misterplex_v2/bin/misterplexd
EOF
}

# CLI
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
    render)
      expect="${2:-$BOOT_HOOK_DEFAULT_ROOT}"
      old="${3:-}"
      if [ -f "$old" ]; then old=$(cat "$old"); fi
      boot_hook_render_body "$expect" "$old"
      echo "true rc=0" >&2
      exit 0
      ;;
    line)
      boot_hook_line_for_root "${2:-$BOOT_HOOK_DEFAULT_ROOT}"
      exit 0
      ;;
    *)
      echo "usage: $0 {check|render|line} ..." >&2
      echo "true rc=9"
      exit 9
      ;;
  esac
fi
