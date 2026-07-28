#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/hw/hw_gate_common.sh"

echo "Scope: verifies daemon build-id label operand equals device /media/fat/_Utility/Plex.rbf md5"
echo "Covers: md5 operand source and daemon-advertised label text; Does-not-cover: HDMI OCR/sidebar pixels"
echo "Failability: set RBF_ID_EXPECT_SHORT=00000000 to red-check a mismatched displayed operand"

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
LOG_PATH="${MISTERPLEXD_LOG:-/media/fat/misterplex/misterplexd.log}"

if ! command -v sshpass >/dev/null 2>&1; then
  hw_skip_not_pass "rbf-identity-label" "sshpass is required to read device md5/log"
fi

md5_out=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
  "$USER@$HOST" 'md5sum /media/fat/_Utility/Plex.rbf' 2>&1) || {
  hw_skip_not_pass "rbf-identity-label" "could not read device RBF md5: $md5_out"
}
actual_md5=$(printf '%s\n' "$md5_out" | tr 'A-F' 'a-f' | grep -oE '\b[0-9a-f]{32}\b' | head -1)
if [[ -z "$actual_md5" ]]; then
  hw_skip_not_pass "rbf-identity-label" "could not parse md5 from: $md5_out"
fi

short_upper=$(printf '%s' "${actual_md5:0:8}" | tr 'a-f' 'A-F')
expected="${RBF_ID_EXPECT_SHORT:-$short_upper}"

log_out=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
  "$USER@$HOST" "cat '$LOG_PATH'" 2>&1) || {
  hw_skip_not_pass "rbf-identity-label" "could not read daemon log $LOG_PATH: $log_out"
}

if ! grep -q "BUILD_ID_LABEL=RBF $expected" <<<"$log_out"; then
  echo "RBF_ID_RESULT=FAIL expected_label=RBF $expected actual_md5=$actual_md5 log=$LOG_PATH" >&2
  exit 1
fi

if [[ "$expected" != "$short_upper" ]]; then
  echo "RBF_ID_RESULT=FAIL expected_label=$expected md5_short=$short_upper" >&2
  exit 1
fi

echo "RBF_ID_RESULT=PASS label=RBF $short_upper md5=$actual_md5 log=$LOG_PATH"
