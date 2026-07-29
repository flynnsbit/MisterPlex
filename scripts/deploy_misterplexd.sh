#!/usr/bin/env bash
# Deploy static ARM misterplexd to MiSTer and restart.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BIN="$ROOT/build/arm/misterplexd"
PLAYER_ID="${MISTERPLEX_ID:-misterplex-dev}"
PMS_URL="${PLEX_BASE:-${PMS_URL:-}}"

# Always let make decide. Guarding this with `if [[ ! -f "$BIN" ]]` meant that
# once the binary existed it was never rebuilt again, so every subsequent deploy
# silently shipped a stale daemon and "verified" fixes that were not on the box.
export PATH="${PATH}:${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}"
make -C "$ROOT" arm-plexd
if [[ ! -f "$BIN" ]]; then
  echo "arm-plexd did not produce $BIN" >&2
  exit 1
fi

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  'mkdir -p /media/fat/misterplex/bin /media/fat/misterplex/scripts
   if [ -f /media/fat/misterplex/bin/misterplexd ]; then
     cp -f /media/fat/misterplex/bin/misterplexd /media/fat/misterplex/bin/misterplexd.prev-c2
   fi
   for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do
     kill -9 "$p" 2>/dev/null || true
   done
   sleep 0.4
   rm -f /media/fat/misterplex/bin/misterplexd'
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$BIN" "$USER@$HOST:/media/fat/misterplex/bin/misterplexd"
# On-device browse / menu (Phase 4 UX)
if [[ -f "$ROOT/scripts/plex_browse.sh" ]]; then
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
    "$ROOT/scripts/plex_browse.sh" "$ROOT/scripts/plex_menu.sh" \
    "$USER@$HOST:/media/fat/misterplex/scripts/"
fi
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "PLAYER_ID='$PLAYER_ID' PMS_URL='$PMS_URL' bash -s" <<'REMOTE'
set -e
chmod +x /media/fat/misterplex/bin/misterplexd
chmod +x /media/fat/misterplex/scripts/plex_browse.sh /media/fat/misterplex/scripts/plex_menu.sh 2>/dev/null || true
# Startup hook (idempotent)
HOOK=/media/fat/linux/_user-startup.sh
PMS_ARG=""
if [[ -n "${PMS_URL:-}" ]]; then
  PMS_ARG=" --pms ${PMS_URL}"
fi
LINE="/media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id ${PLAYER_ID:-misterplex-dev} --port 3005 --conf /media/fat/misterplex/misterplex.conf${PMS_ARG} >>/media/fat/misterplex/misterplexd.log 2>&1 &"
mkdir -p /media/fat/linux /media/fat/misterplex
touch "$HOOK"
if ! grep -q 'misterplex/bin/misterplexd' "$HOOK" 2>/dev/null; then
  printf '\n# MiSTerPlex companion + media\n%s\n' "$LINE" >>"$HOOK"
  echo "Added startup hook"
fi
# Ensure conf exists (token optional — cast can supply transient tokens)
if [[ ! -f /media/fat/misterplex/misterplex.conf ]]; then
  cat >/media/fat/misterplex/misterplex.conf <<'CONF'
# Set this to your Plex Media Server, for example:
# PLEX_BASE=http://YOUR-PLEX-SERVER:32400
# PLEX_TOKEN=
CONF
  if [[ -n "${PMS_URL:-}" ]]; then
    printf 'PLEX_BASE=%s\n' "$PMS_URL" >>/media/fat/misterplex/misterplex.conf
  fi
fi
: >/media/fat/misterplex/misterplexd.log
nohup /media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id "${PLAYER_ID:-misterplex-dev}" --port 3005 \
  --conf /media/fat/misterplex/misterplex.conf ${PMS_ARG} \
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
sleep 0.8
ps w | grep '[m]isterplexd' || true
wget -qO- http://127.0.0.1:3005/resources | head -c 300; echo
REMOTE
echo "Deployed misterplexd → $HOST"

# After restart the adopted running line is fresh — verify it matches resident core.
# Read-only beyond the deploy already performed above. rc=77 is NOT a pass.
if [[ "${DEPLOY_SKIP_GEOMETRY_GATE:-0}" != "1" ]]; then
  set +e
  "$ROOT/scripts/check_core_conf_geometry.sh"
  geo_rc=$?
  set -e
  case "$geo_rc" in
    0) echo "core_conf_geometry: PASS" ;;
    77) echo "core_conf_geometry: SKIP-NOT-PASS (rc=77) — not scored as deploy success evidence" >&2 ;;
    *)
      echo "core_conf_geometry: FAIL rc=$geo_rc — adopted decode does not match resident core" >&2
      exit "$geo_rc"
      ;;
  esac
fi
