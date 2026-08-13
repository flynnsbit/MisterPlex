#!/usr/bin/env bash
# Launch (or re-raise) live HDMI preview with annotate.
# Usage:
#   hdmi_preview.sh              # start if not running
#   hdmi_preview.sh --replace    # restart
#   hdmi_preview.sh grab         # pause + export agent package
#   hdmi_preview.sh status       # print status.json
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$ROOT/../.." && pwd)"
PY="$ROOT/.venv/bin/python"
APP="$ROOT/hdmi_preview.py"
SHARED="${HDMI_PREVIEW_SHARED:-$LAB_ROOT/captures/hdmi_preview_live}"
export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"

mkdir -p "$SHARED/commands" "$SHARED/notes"

cmd="${1:-start}"
case "$cmd" in
  status)
    if [[ -f "$SHARED/status.json" ]]; then
      cat "$SHARED/status.json"
    else
      echo '{"running":false,"msg":"no status"}'
      exit 1
    fi
    ;;
  grab)
    # ask running UI to pause + save agent package
    rm -f "$SHARED/commands/grab_done"
    touch "$SHARED/commands/grab"
    for i in $(seq 1 40); do
      if [[ -f "$SHARED/commands/grab_done" ]]; then
        echo "grab_ok"
        cat "$SHARED/latest_export.txt" 2>/dev/null || true
        ls -la "$SHARED/latest_annotated.jpg" "$SHARED/latest.yuyv" "$SHARED/annotations.json" 2>/dev/null || true
        exit 0
      fi
      sleep 0.25
    done
    echo "grab_timeout — is preview running?" >&2
    exit 2
    ;;
  start|run|"")
    shift || true
    if [[ ! -x "$PY" ]]; then
      echo "missing venv at $ROOT/.venv" >&2
      echo "run: cd \"$ROOT\" && uv venv .venv && uv pip install --python .venv/bin/python -r requirements.txt" >&2
      exit 3
    fi
    # if already running, report and exit 0
    if [[ -f "$SHARED/hdmi_preview.pid" ]]; then
      pid=$(cat "$SHARED/hdmi_preview.pid" 2>/dev/null || true)
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "already_running pid=$pid shared=$SHARED"
        exit 0
      fi
    fi
    # detach GUI so agent shells don't block
    nohup "$PY" "$APP" --shared "$SHARED" "$@" >"$SHARED/preview.log" 2>&1 &
    echo "started pid=$! shared=$SHARED log=$SHARED/preview.log"
    # wait briefly for status
    for i in $(seq 1 20); do
      if [[ -f "$SHARED/status.json" ]] && grep -q '"running": true' "$SHARED/status.json" 2>/dev/null; then
        cat "$SHARED/status.json"
        exit 0
      fi
      sleep 0.25
    done
    echo "started_but_status_pending — check $SHARED/preview.log" >&2
    tail -20 "$SHARED/preview.log" 2>/dev/null || true
    ;;
  replace|restart)
    shift || true
    if [[ -f "$SHARED/hdmi_preview.pid" ]]; then
      pid=$(cat "$SHARED/hdmi_preview.pid" 2>/dev/null || true)
      if [[ -n "${pid:-}" ]]; then kill "$pid" 2>/dev/null || true; fi
      sleep 0.4
    fi
    exec "$0" start --replace "$@"
    ;;
  *)
    # pass-through flags to python app
    exec "$0" start "$@"
    ;;
esac
