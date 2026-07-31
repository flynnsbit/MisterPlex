# live_object.inc.sh — reusable "is this the object the system actually uses?" asserts.
#
# Root question (parent 2026-07-31 gate-integrity family):
#   How do I know this is the object the system actually uses?
#
# The one place we get it right: daemon via readlink -f /proc/PID/exe.
# Known failures that this library exists to prevent:
#   - boot hook gated on underscore DECOY (_user-startup.sh) while S99user runs
#     user-startup.sh
#   - on-disk RBF md5 while fabric runs a different bitstream
#   - host [ -f device_path ] while running on the laptop
#   - cmdline substring matching flock
#   - NOTE that never touches rc
#   - elif branch unreachable because an earlier default is always true
#
# Source:  source scripts/live_object.inc.sh
# A check may only PASS if it inspected a LIVE object:
#   - /proc/<pid>/exe or /proc/<pid>/cmdline
#   - HTTP 200 from the running daemon
#   - captured pixels (warm-up-aware)
# Where a live object cannot be inspected → RED (not skip, not NOTE-as-pass).
# Soft-skip 77 and UNSCORED are never success.

# live_object_mark KIND DETAIL
#   KIND=proc_exe|proc_cmdline|http|pixels|claim_mtime|boot_live
live_object_mark() {
  printf 'LIVE_OBJECT kind=%s detail=%s\n' "${1:-unknown}" "${2:-}"
}

# live_object_refuse_disk_only LABEL
#   Call when a gate would pass on disk md5 alone.
live_object_refuse_disk_only() {
  echo "FAIL live-object: $1 is disk-only (not /proc/exe, not HTTP, not pixels)"
  echo "     disk match alone is NOT success (ETXTBSY / decoy / wrong install root)"
  return 1
}

# live_object_refuse_unproven LABEL
#   Cannot establish the live object → RED not skip.
live_object_refuse_unproven() {
  echo "FAIL live-object: $1 unproven — cannot soft-skip; must inspect live object"
  return 1
}

# live_object_assert_http_code CODE
#   Only 200 counts as live HTTP success for promote-class gates.
live_object_assert_http_code() {
  local code="${1:-}"
  case "$code" in
    200)
      live_object_mark http "code=200"
      return 0
      ;;
    '')
      echo "NO-DATA live-object http empty"
      return 4
      ;;
    *)
      echo "FAIL live-object http code=$code (want 200)"
      return 1
      ;;
  esac
}

# live_object_assert_md5_shape NAME VAL — thin wrapper; prefer md5_shape.inc.sh
live_object_assert_md5_shape() {
  if declare -F assert_md5_shape >/dev/null 2>&1; then
    assert_md5_shape "$1" "$2"
    return $?
  fi
  local name="$1" val="$2"
  if [ -z "$val" ]; then
    echo "NO-DATA $name empty"
    return 4
  fi
  if ! printf '%s' "$val" | grep -Eq '^[0-9a-f]{32}$'; then
    echo "FAIL $name shape got='$val'"
    return 1
  fi
  return 0
}
