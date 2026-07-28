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
  actual=$(printf '%s\n' "$out" | awk '{print tolower($1); exit}')
  expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
  if [[ "$actual" != "$expected" ]]; then
    hw_skip_not_pass "$name" "resident RBF md5 mismatch actual=${actual:-unset} expected=$expected"
  fi
  echo "RBF_MD5_OK $name actual=$actual expected=$expected"
}
