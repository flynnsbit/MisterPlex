#!/usr/bin/env bash
# Hard power-cycle MiSTer via Enbrighten plug at ENBRIGHTEN_IP (default 192.168.1.91).
# Post-2026-08-13: OpenBeken HTTP (tuya-cloudcutter/flash-enbrighten.sh). Not tinytuya.
# Prefer SSH soft recovery first. See Memory/lab/ops/ENBRIGHTEN_POWER_PLUG_MISTER.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENBRIGHTEN_ENV:-$HOME/.config/misterplex/enbrighten-mister.env}"
MISTER_HOST="${MISTER_HOST:-192.168.1.183}"
OFF_SECS="${OFF_SECS:-8}"
SSH_WAIT_SECS="${SSH_WAIT_SECS:-120}"
PY="${ENBRIGHTEN_PYTHON:-}"
if [[ -z "$PY" ]]; then
  if [[ -x "$HOME/tuya-venv/bin/python" ]]; then
    PY="$HOME/tuya-venv/bin/python"
  elif [[ -x /tmp/tuya-venv/bin/python ]]; then
    PY=/tmp/tuya-venv/bin/python
  else
    PY=python3
  fi
fi

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  echo "WARN: $ENV_FILE missing — need ENBRIGHTEN_DEVICE_ID + ENBRIGHTEN_LOCAL_KEY" >&2
fi

export ENBRIGHTEN_IP="${ENBRIGHTEN_IP:-192.168.1.91}"

echo "=== Enbrighten cycle plug=${ENBRIGHTEN_IP} mister=${MISTER_HOST} off_secs=${OFF_SECS} ==="
"$PY" "$ROOT/scripts/enbrighten_tuya_plug.py" cycle --off-secs "$OFF_SECS"

echo "Waiting for SSH ${MISTER_HOST} up to ${SSH_WAIT_SECS}s..."
deadline=$((SECONDS + SSH_WAIT_SECS))
while (( SECONDS < deadline )); do
  if sshpass -p 1 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
      -o BatchMode=yes root@"$MISTER_HOST" 'echo SSH_OK; uptime' 2>/dev/null; then
    echo "=== MiSTer SSH recovered ==="
    exit 0
  fi
  # some images use password auth only (no BatchMode keys)
  if sshpass -p 1 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
      root@"$MISTER_HOST" 'echo SSH_OK; uptime' 2>/dev/null; then
    echo "=== MiSTer SSH recovered ==="
    exit 0
  fi
  sleep 3
done
echo "ERROR: plug cycled but SSH to ${MISTER_HOST} not up within ${SSH_WAIT_SECS}s" >&2
exit 2
