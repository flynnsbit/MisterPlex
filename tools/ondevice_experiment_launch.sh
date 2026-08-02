#!/usr/bin/env bash
# Host-side launcher: scp runner+spec, setsid nohup on device, poll COMPLETE.
# SSH is ONLY used for deploy/poll — never inside arm steps (on-device script owns those).
#
# Usage:
#   MISTER_HOST=192.168.1.183 \
#   SPEC=files/device-evidence/experiment_runner/example_bitrate_arms.json \
#   OUT_REMOTE=/media/fat/misterplex_v2/experiments/run_$(date -u +%Y%m%dT%H%M%SZ) \
#   ./tools/ondevice_experiment_launch.sh
#
# Does NOT cast/play beyond what the on-device spec.cast_cmd does.
# Does NOT touch conf from the host.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
SPEC="${SPEC:?set SPEC=path/to/arms.json}"
OUT_REMOTE="${OUT_REMOTE:-/media/fat/misterplex_v2/experiments/run_$(date -u +%Y%m%dT%H%M%SZ)}"
RUNNER_REMOTE="${RUNNER_REMOTE:-/media/fat/misterplex_v2/bin/ondevice_experiment_runner.py}"
SPEC_REMOTE="${SPEC_REMOTE:-$OUT_REMOTE/arms.json}"
POLL_S="${POLL_S:-5}"
TIMEOUT_S="${TIMEOUT_S:-3600}"

ssh_m() {
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      -o LogLevel=ERROR "$USER@$HOST" "$@"
  else
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$USER@$HOST" "$@"
  fi
}
scp_m() {
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o LogLevel=ERROR "$@"
  else
    scp -o StrictHostKeyChecking=no "$@"
  fi
}

echo "launch host=$HOST out=$OUT_REMOTE"
ssh_m "mkdir -p '$(dirname "$RUNNER_REMOTE")' '$OUT_REMOTE'"
scp_m "$ROOT/tools/ondevice_experiment_runner.py" "$USER@$HOST:$RUNNER_REMOTE"
scp_m "$SPEC" "$USER@$HOST:$SPEC_REMOTE"

ssh_m "setsid nohup python3 '$RUNNER_REMOTE' run --spec '$SPEC_REMOTE' --out-dir '$OUT_REMOTE' \
  >'$OUT_REMOTE/runner.stdout' 2>&1 < /dev/null & echo \$! >'$OUT_REMOTE/runner.pid'"
echo "started pid=$(ssh_m "cat '$OUT_REMOTE/runner.pid'")"

elapsed=0
while (( elapsed < TIMEOUT_S )); do
  if ssh_m "test -f '$OUT_REMOTE/COMPLETE'"; then
    echo "COMPLETE after ${elapsed}s"
    ssh_m "cat '$OUT_REMOTE/COMPLETE'; echo '--- result.json ---'; cat '$OUT_REMOTE/result.json'"
    # fetch rc from COMPLETE
    rc_line=$(ssh_m "cat '$OUT_REMOTE/COMPLETE'" | head -1 || true)
    echo "device_COMPLETE_line=$rc_line"
    exit 0
  fi
  sleep "$POLL_S"
  elapsed=$((elapsed + POLL_S))
  echo "poll t=${elapsed}s waiting for COMPLETE"
done
echo "TIMEOUT waiting for COMPLETE after ${TIMEOUT_S}s" >&2
exit 77
