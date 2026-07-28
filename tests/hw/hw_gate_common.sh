#!/usr/bin/env bash
# Shared helpers for hardware gates. Source this from bash tests only.

HW_RC_UNSCORED="${HW_RC_UNSCORED:-77}"

hw_skip_not_pass() {
  local name="$1" reason="$2"
  echo "SKIP-NOT-PASS ${name}: ${reason}" >&2
  exit "$HW_RC_UNSCORED"
}

hw_require_expected_rbf_md5() {
  local name="$1" host="$2" pass="$3" user="$4" expected="${5:-}"
  if [[ -z "$expected" ]]; then
    hw_skip_not_pass "$name" "EXPECTED_RBF_MD5/HW_EXPECTED_RBF_MD5 is required for hardware-state scoring"
  fi
  if ! command -v sshpass >/dev/null 2>&1; then
    hw_skip_not_pass "$name" "sshpass is required to verify resident RBF provenance"
  fi
  local out actual
  if ! out=$(sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "$user@$host" 'md5sum /media/fat/_Utility/Plex.rbf' 2>&1); then
    hw_skip_not_pass "$name" "could not read resident Plex.rbf md5: $out"
  fi
  # ssh may print banners (e.g. the post-quantum key-exchange warning) ahead of the
  # md5sum line, so select the first 32-hex token instead of field 1 of line 1.
  # Reporting a parse failure as a "mismatch" would blame the RBF for a read fault.
  actual=$(printf '%s\n' "$out" | tr 'A-F' 'a-f' | grep -oE '\b[0-9a-f]{32}\b' | head -1)
  if [[ -z "$actual" ]]; then
    hw_skip_not_pass "$name" "could not parse resident RBF md5 from device output: $out"
  fi
  expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
  if [[ "$actual" != "$expected" ]]; then
    hw_skip_not_pass "$name" "resident RBF md5 mismatch actual=${actual:-unset} expected=$expected"
  fi
  echo "RBF_MD5_OK $name actual=$actual expected=$expected"
}

# ---------------------------------------------------------------------------
# HDMI capture lock — serialises /dev/video0 access across all HW gates.
#
# V4L2 is NOT safely shareable: concurrent opens produce corrupt frames.
# Every gate that opens /dev/video0 MUST call capture_lock_acquire before
# capture and the lock is released automatically on script exit.
#
# Protocol:
#   source "$ROOT/tests/hw/hw_gate_common.sh"
#   capture_lock_acquire          # blocks up to $CAPTURE_LOCK_TIMEOUT_S (default 60)
#   ... run capture ...
#   # capture_lock_release is called automatically via EXIT trap, or call explicitly
#
# CAPTURE_LOCK_FILE   path to the lock file  [default: $ROOT/build/video0.lock]
# CAPTURE_LOCK_TIMEOUT_S  max seconds to wait [default: 60]
# ---------------------------------------------------------------------------

_CAPTURE_LOCK_FD=9   # file descriptor reserved for the lock
_CAPTURE_LOCK_HELD=0

capture_lock_acquire() {
  local timeout="${CAPTURE_LOCK_TIMEOUT_S:-60}"
  # Determine repo root from this file's location (tests/hw/hw_gate_common.sh)
  local _gate_root
  _gate_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  # The lock MUST be shared by every checkout on this machine: /dev/video0 is a
  # single physical device, but this repo runs ~20 git worktrees in parallel and
  # a per-worktree lock path gives each agent its own private lock, serialising
  # nothing.  git's common dir is identical for the main checkout and every
  # linked worktree, so anchoring there yields one real lock per machine.
  local _lock_anchor
  _lock_anchor="$(cd "$_gate_root" && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .)" && pwd)" \
    || _lock_anchor="$_gate_root"
  local lock_file="${CAPTURE_LOCK_FILE:-$_lock_anchor/video0.lock}"
  mkdir -p "$(dirname "$lock_file")"
  # Open/create the lock file on fd _CAPTURE_LOCK_FD
  eval "exec ${_CAPTURE_LOCK_FD}>\"$lock_file\""
  if ! flock -w "$timeout" "$_CAPTURE_LOCK_FD"; then
    echo "SKIP: could not acquire HDMI capture lock within ${timeout}s" \
         "(another gate is holding /dev/video0 — set CAPTURE_LOCK_TIMEOUT_S to wait longer)" >&2
    exit "${HW_RC_UNSCORED:-77}"
  fi
  _CAPTURE_LOCK_HELD=1
  echo "CAPTURE_LOCK acquired: $lock_file (fd=${_CAPTURE_LOCK_FD})"
}

capture_lock_release() {
  if [[ "$_CAPTURE_LOCK_HELD" == "1" ]]; then
    flock -u "$_CAPTURE_LOCK_FD" 2>/dev/null || true
    eval "exec ${_CAPTURE_LOCK_FD}>&-" 2>/dev/null || true
    _CAPTURE_LOCK_HELD=0
  fi
}

# Auto-release on script exit so callers don't need explicit release.
# Multiple sourced files adding EXIT traps is safe — bash chains them.
trap 'capture_lock_release' EXIT
