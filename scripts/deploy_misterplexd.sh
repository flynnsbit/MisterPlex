#!/usr/bin/env bash
# Deploy static ARM misterplexd to MiSTer and restart.
#
# Hard requirements after start (loud fail, never silent):
#   - argv --id is the canonical player id (default misterplex-dev)
#   - /resources machineIdentifier matches that id
#   - conf has product PRESENT=fpga (fb0 alone freezes idle on the core scanout)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BIN="$ROOT/build/arm/misterplexd"
# Canonical cast client id. Wrong id still GDM-advertises; casts target a ghost.
PLAYER_ID="${MISTERPLEX_ID:-misterplex-dev}"
PMS_URL="${PLEX_BASE:-${PMS_URL:-}}"

# Exact argv --id token match (same rule as mister_soft_bounce / remote deploy).
# Returns 0 iff ps line has --id WANT or --id=WANT as a full token.
daemon_ps_id_equals() {
  local ps_line="$1" want="$2"
  # shellcheck disable=SC2086
  set -- $ps_line
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--id" && -n "${2:-}" ]]; then
      [[ "$2" == "$want" ]] && return 0
      return 1
    fi
    if [[ "$1" == --id=* ]]; then
      [[ "${1#--id=}" == "$want" ]] && return 0
      return 1
    fi
    shift
  done
  return 1
}

# Offline gate: wrong --id must hard-fail rc=7 (no SSH, no rebuild).
if [[ "${1:-}" == "--selftest-id-gate" ]]; then
  want="misterplex-dev"
  good='123 1 ./bin/misterplexd --name MiSTerPlex --id misterplex-dev --port 3005'
  bad='123 1 ./bin/misterplexd --name MiSTerPlex --id misterplex-wrong --port 3005'
  old='123 1 ./bin/misterplexd --id misterplex-dev-old --port 3005'
  bare='123 1 ./bin/misterplexd --id misterplex --port 3005'
  if ! daemon_ps_id_equals "$good" "$want"; then
    echo "SELFTEST_FAIL: good id should match" >&2
    exit 1
  fi
  for line in "$bad" "$old" "$bare"; do
    if daemon_ps_id_equals "$line" "$want"; then
      echo "SELFTEST_FAIL: should reject: $line" >&2
      exit 1
    fi
  done
  # Mirror deploy remote: mismatch → exit 7
  if daemon_ps_id_equals "$bad" "$want"; then
    echo "SELFTEST_FAIL: unreachable" >&2
    exit 1
  fi
  echo "deploy_misterplexd: DAEMON_ID_MISMATCH want=${want} (selftest wrong-id)" >&2
  echo "selftest_id_gate would_exit=7"
  # Discriminating exit: callers expect rc=7 on wrong id path.
  exit 7
fi

# Always let make decide. Guarding this with `if [[ ! -f "$BIN" ]]` meant that
# once the binary existed it was never rebuilt again, so every subsequent deploy
# silently shipped a stale daemon and "verified" fixes that were not on the box.
export PATH="${PATH}:${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}"
make -C "$ROOT" arm-plexd
if [[ ! -f "$BIN" ]]; then
  echo "arm-plexd did not produce $BIN" >&2
  exit 1
fi

# Atomic on-device backup + staged install (see scripts/lib_misterplexd_fs.sh).
# Old path: cp→prev, kill -9, rm live, scp — a failed scp left NO binary.
# New path: backup live→prev-c2 (+ timestamped pair), soft-stop, scp to .new, mv.
TAG="before-$(date -u +%Y%m%dT%H%M%SZ)"
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "TAG='$TAG' bash -s" <<'REMOTE_PRE'
set -euo pipefail
BIN=/media/fat/misterplex/bin/misterplexd
PREV=/media/fat/misterplex/bin/misterplexd.prev-c2
CONF=/media/fat/misterplex/misterplex.conf
BDIR=/media/fat/misterplex/backup
mkdir -p /media/fat/misterplex/bin /media/fat/misterplex/scripts "$BDIR"
if [[ -f "$BIN" ]]; then
  tmp="${PREV}.new.$$"
  cp -f "$BIN" "$tmp"
  sync "$tmp" 2>/dev/null || sync || true
  mv -f "$tmp" "$PREV"
  echo "prev_c2_backup_ok md5=$(md5sum "$PREV" | awk '{print $1}')"
  # Timestamped pair so named restore survives a later deploy overwriting prev-c2.
  bt="$BDIR/misterplexd.${TAG}"
  btmp="${bt}.new.$$"
  cp -f "$BIN" "$btmp"
  sync "$btmp" 2>/dev/null || sync || true
  mv -f "$btmp" "$bt"
  if [[ -f "$CONF" ]]; then
    ct="$BDIR/misterplex.conf.${TAG}"
    ctmp="${ct}.new.$$"
    cp -f "$CONF" "$ctmp"
    sync "$ctmp" 2>/dev/null || sync || true
    mv -f "$ctmp" "$ct"
    echo "snapshot_conf=$ct"
  fi
  echo "snapshot_bin=$bt md5=$(md5sum "$bt" | awk '{print $1}')"
else
  echo "prev_c2_backup_skip: no live binary"
fi
# Soft stop first; -9 only if still up.
if pidof misterplexd >/dev/null 2>&1 || pidof ffmpeg >/dev/null 2>&1; then
  kill $(pidof misterplexd ffmpeg 2>/dev/null) 2>/dev/null || true
  sleep 0.4
fi
for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do
  kill -9 "$p" 2>/dev/null || true
done
sleep 0.2
# Do NOT rm live before new binary arrives — mid-scp hole is unrecoverable
# without prev. Staged install happens after scp of .new file.
REMOTE_PRE
STAGE_REMOTE="/media/fat/misterplex/bin/misterplexd.new"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$BIN" "$USER@$HOST:${STAGE_REMOTE}"
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  'set -e
   STAGE=/media/fat/misterplex/bin/misterplexd.new
   DEST=/media/fat/misterplex/bin/misterplexd
   chmod +x "$STAGE"
   sync "$STAGE" 2>/dev/null || sync || true
   mv -f "$STAGE" "$DEST"
   echo "install_staged_ok md5=$(md5sum "$DEST" | awk "{print \$1}")"'
# On-device browse / menu (Phase 4 UX)
if [[ -f "$ROOT/scripts/plex_browse.sh" ]]; then
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
    "$ROOT/scripts/plex_browse.sh" "$ROOT/scripts/plex_menu.sh" \
    "$USER@$HOST:/media/fat/misterplex/scripts/"
fi
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "PLAYER_ID='$PLAYER_ID' PMS_URL='$PMS_URL' bash -s" <<'REMOTE'
set -e
ID_WANT="${PLAYER_ID:-misterplex-dev}"
chmod +x /media/fat/misterplex/bin/misterplexd
chmod +x /media/fat/misterplex/scripts/plex_browse.sh /media/fat/misterplex/scripts/plex_menu.sh 2>/dev/null || true
# Startup hook (idempotent). If an older hook has a non-canonical --id, rewrite it.
HOOK=/media/fat/linux/_user-startup.sh
PMS_ARG=""
if [[ -n "${PMS_URL:-}" ]]; then
  PMS_ARG=" --pms ${PMS_URL}"
fi
LINE="/media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id ${ID_WANT} --port 3005 --conf /media/fat/misterplex/misterplex.conf${PMS_ARG} >>/media/fat/misterplex/misterplexd.log 2>&1 &"
mkdir -p /media/fat/linux /media/fat/misterplex
touch "$HOOK"
if ! grep -q 'misterplex/bin/misterplexd' "$HOOK" 2>/dev/null; then
  printf '\n# MiSTerPlex companion + media\n%s\n' "$LINE" >>"$HOOK"
  echo "Added startup hook id=${ID_WANT}"
elif ! grep -qE -- "--id[= ]${ID_WANT}( --|\$)" "$HOOK" 2>/dev/null; then
  # Prior hook may have shipped --id misterplex (package README bug) or another id.
  # Token boundary required: misterplex-dev-old must not satisfy want=misterplex-dev.
  ts=$(date +%Y%m%dT%H%M%S)
  cp -a "$HOOK" "${HOOK}.bak-misterplex-id-${ts}"
  # Drop old misterplexd lines; append canonical line.
  grep -v 'misterplex/bin/misterplexd' "$HOOK" >"${HOOK}.new" || true
  printf '\n# MiSTerPlex companion + media (id fixed %s)\n%s\n' "$ts" "$LINE" >>"${HOOK}.new"
  mv -f "${HOOK}.new" "$HOOK"
  echo "Rewrote startup hook to --id ${ID_WANT} (backup ${HOOK}.bak-misterplex-id-${ts})"
fi
# Ensure conf exists with product keys. Missing PRESENT used to default to fb0 in
# older daemons and freeze idle; never bootstrap a conf without PRESENT=fpga.
CONF=/media/fat/misterplex/misterplex.conf
if [[ ! -f "$CONF" ]]; then
  ts=$(date +%Y%m%dT%H%M%S)
  cat >"$CONF" <<CONF
# Bootstrap from deploy_misterplexd.sh (${ts})
# Set PLEX_BASE to your Plex Media Server.
# PLEX_BASE=http://YOUR-PLEX-SERVER:32400
# PLEX_TOKEN=
DECODE=320x240
PRESENT=fpga
STREAM=0
OSD_CONTROL=1
CONF
  if [[ -n "${PMS_URL:-}" ]]; then
    printf 'PLEX_BASE=%s\n' "$PMS_URL" >>"$CONF"
  fi
  echo "Created conf with product PRESENT=fpga DECODE=320x240 STREAM=0 OSD_CONTROL=1"
else
  # Loud warn only — never silently rewrite a live conf the user may have tuned.
  if ! grep -qE '^[[:space:]]*PRESENT=fpga([[:space:]]|$)' "$CONF" 2>/dev/null; then
    echo "WARNING: $CONF has no PRESENT=fpga line — idle/HDMI may freeze if PRESENT=fb0 or missing on old daemons" >&2
    grep -nE '^[[:space:]]*PRESENT=' "$CONF" 2>/dev/null || echo "WARNING: no PRESENT= key at all" >&2
  fi
fi
: >/media/fat/misterplex/misterplexd.log
nohup /media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id "${ID_WANT}" --port 3005 \
  --conf /media/fat/misterplex/misterplex.conf ${PMS_ARG} \
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
sleep 0.8

# --- Post-start hard checks (silent wrong id kills casting) ---
ps_line=$(ps -o pid,ppid,args 2>/dev/null | grep '[m]isterplexd' || ps w 2>/dev/null | grep '[m]isterplexd' || true)
echo "daemon_ps=${ps_line:-NONE}"
if [[ -z "$ps_line" ]]; then
  echo "DEPLOY_FAIL: misterplexd not running after start" >&2
  tail -n 40 /media/fat/misterplex/misterplexd.log 2>/dev/null || true
  exit 6
fi
# Exact --id token (not substring): --id misterplex-dev-old must not pass.
id_ok=0
set -- $ps_line
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--id" && -n "${2:-}" ]]; then
    [[ "$2" == "$ID_WANT" ]] && id_ok=1
    break
  fi
  if [[ "$1" == --id=* ]]; then
    [[ "${1#--id=}" == "$ID_WANT" ]] && id_ok=1
    break
  fi
  shift
done
if [[ "$id_ok" != "1" ]]; then
  echo "DEPLOY_FAIL: DAEMON_ID_MISMATCH want=${ID_WANT} ps=${ps_line}" >&2
  exit 7
fi
echo "daemon_id_ok=${ID_WANT}"

# /resources can lag bind after nohup (single sleep+wget raced → spurious rc=7).
# Retry; exit 7 only means real id mismatch / dead HTTP after ready window.
res=""
resources_ok=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  res=$(wget -qO- http://127.0.0.1:3005/resources 2>/dev/null || true)
  if printf '%s' "$res" | grep -q "machineIdentifier=\"${ID_WANT}\""; then
    resources_ok=1
    echo "resources_attempt=${attempt} ok"
    break
  fi
  echo "resources_attempt=${attempt} empty_or_mismatch"
  sleep 0.2
done
echo "resources_head=$(printf '%s' "$res" | head -c 300)"
if [[ "$resources_ok" != "1" ]]; then
  echo "DEPLOY_FAIL: /resources machineIdentifier != ${ID_WANT} after retries" >&2
  printf '%s\n' "$res" | head -c 500 >&2
  exit 7
fi
echo "resources_id_ok=${ID_WANT}"
REMOTE
echo "Deployed misterplexd → $HOST (id=$PLAYER_ID verified)"

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
