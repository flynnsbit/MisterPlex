#!/bin/sh
# switch_misterplex_mode.sh — swap RBF + conf + daemon + load core
# Usage: switch_misterplex_mode.sh 240p|480i|480p|status
#
# One companion binary can serve all modes; conf + RBF define the pair.
# Named daemon copies are optional aliases of the same unified build.
#
# 480p product path = e41b FPGA (Plex_480p_e41b_sys437.rbf / md5 2cb76e50),
# NOT legacy Plex_480p_host.rbf (9014 host-paint). Use explicit 480p_host for lab.
set -eu

MODE=${1:-}
ROOT=/media/fat/misterplex
UTIL=/media/fat/_Utility
BIN=$ROOT/bin
LINUX_CONF=/media/fat/linux/misterplex.conf
PROFILES=$ROOT/profiles
LOG=$ROOT/misterplexd.log

die() { echo "switch_mode: $*" >&2; exit 1; }

# Wait briefly for /dev/MiSTer_cmd (can race after core bounce / SPI).
wait_mister_cmd() {
  tries=${1:-40}
  n=0
  while [ "$n" -lt "$tries" ]; do
    if [ -c /dev/MiSTer_cmd ]; then
      return 0
    fi
    # 0.25s * 40 ≈ 10s max
    sleep 0.25 2>/dev/null || sleep 1
    n=$((n + 1))
  done
  return 1
}

# Issue load_core with short retries when MiSTer_cmd exists but write races.
load_core_retry() {
  core=$1
  label=${2:-$core}
  n=0
  while [ "$n" -lt 6 ]; do
    if wait_mister_cmd 8; then
      if printf '%s\n' "load_core $core" >/dev/MiSTer_cmd 2>/dev/null; then
        echo "switch_mode: load_core $label (attempt $((n + 1)))" >&2
        return 0
      fi
    fi
    sleep 0.5 2>/dev/null || sleep 1
    n=$((n + 1))
  done
  echo "switch_mode: FAILED load_core $label — MiSTer_cmd missing or write failed after retries" >&2
  return 1
}

status_mode() {
  echo "=== MisterPlex mode status ==="
  if [ -f "$LINUX_CONF" ]; then
    grep -E '^(CONTENT_RES|DISPLAY_RES|DECODE|MPX_VIDEO_BACKEND|MPX_LEGACY|MPX_PRESENT|IDLE_SCREEN|AUDIO_DELAY)' "$LINUX_CONF" 2>/dev/null || true
  fi
  if [ -f "$UTIL/Plex.rbf" ]; then
    echo -n "live Plex.rbf md5="
    md5sum "$UTIL/Plex.rbf" | awk '{print $1}'
  fi
  if [ -x "$BIN/misterplexd" ]; then
    echo -n "live misterplexd md5="
    md5sum "$BIN/misterplexd" | awk '{print $1}'
  fi
  PID=$(pidof misterplexd 2>/dev/null || true)
  if [ -n "${PID:-}" ]; then echo "misterplexd pid=$PID"; else echo "misterplexd: not running"; fi
  if [ -f /tmp/CORENAME ]; then echo "CORENAME=$(cat /tmp/CORENAME)"; fi
  if [ -c /dev/MiSTer_cmd ]; then
    echo "MiSTer_cmd: present"
  else
    echo "MiSTer_cmd: MISSING"
  fi
}

case "$MODE" in
  status|"")
    if [ "$MODE" = status ] || [ -z "$MODE" ] && [ "${2:-}" = "" ] && [ $# -ge 1 ] && [ "$1" = status ]; then
      status_mode
      exit 0
    fi
    if [ -z "$MODE" ]; then
      echo "usage: $0 240p|480i|480p|status" >&2
      exit 1
    fi
    ;;
esac

case "$MODE" in
  240p)
    RBF=$UTIL/Plex_240p_AU32.rbf
    CONF=$PROFILES/misterplex.conf.240p
    DAE=$BIN/misterplexd.unified
    [ -x "$DAE" ] || DAE=$BIN/misterplexd.240p_au32_hq
    LABEL="240p FPGA (AU32)"
    ;;
  480i)
    if [ -f "$UTIL/Plex_480i_host_audio.rbf" ]; then
      RBF=$UTIL/Plex_480i_host_audio.rbf
    else
      RBF=$UTIL/Plex_480i_host.rbf
    fi
    CONF=$PROFILES/misterplex.conf.480i
    DAE=$BIN/misterplexd.unified
    [ -x "$DAE" ] || DAE=$BIN/misterplexd.480i_host_audio
    LABEL="480i host-paint (lipsync)"
    ;;
  480p|480p_fpga|480p-fpga|e41b)
    # Product 480p = sealed e41b FPGA path (2cb76e50), not 9014 host-paint.
    MODE=480p
    if [ -f "$UTIL/Plex_480p_e41b_sys437.rbf" ]; then
      RBF=$UTIL/Plex_480p_e41b_sys437.rbf
    elif [ -f "$UTIL/Plex_480p_fpga.rbf" ]; then
      RBF=$UTIL/Plex_480p_fpga.rbf
    else
      die "missing e41b RBF (expected $UTIL/Plex_480p_e41b_sys437.rbf md5 2cb76e50…); refuse Plex_480p_host/9014"
    fi
    if [ -f "$PROFILES/misterplex.conf.480p" ]; then
      CONF=$PROFILES/misterplex.conf.480p
    elif [ -f "$PROFILES/misterplex.conf.480p_e41b" ]; then
      CONF=$PROFILES/misterplex.conf.480p_e41b
    else
      die "missing conf $PROFILES/misterplex.conf.480p (fpga-h264 e41b)"
    fi
    DAE=$BIN/misterplexd.unified
    [ -x "$DAE" ] || DAE=$BIN/misterplexd.f303
    [ -x "$DAE" ] || DAE=$BIN/misterplexd.480p_host
    LABEL="480p FPGA e41b (2cb76e50)"
    ;;
  480p_host|480p-host)
    # Explicit lab escape hatch only — NOT product default on .183/.42.
    MODE=480p_host
    RBF=$UTIL/Plex_480p_host.rbf
    CONF=$PROFILES/misterplex.conf.480p_host
    DAE=$BIN/misterplexd.unified
    [ -x "$DAE" ] || DAE=$BIN/misterplexd.480p_host
    LABEL="480p host-paint 9014 (lab only — not product)"
    ;;
  status)
    status_mode
    exit 0
    ;;
  *)
    die "usage: $0 240p|480i|480p|status"
    ;;
esac

[ -f "$RBF" ] || die "missing RBF $RBF"
[ -f "$CONF" ] || die "missing conf $CONF"
[ -x "$DAE" ] || die "missing daemon $DAE (install misterplexd.unified)"

# Guard: product 480p must not silently pick 9014 host-paint.
if [ "$MODE" = 480p ]; then
  rbf_md5=$(md5sum "$RBF" | awk '{print $1}')
  case "$rbf_md5" in
    9014f49e*)
      die "refusing 480p product path on host-paint RBF md5=$rbf_md5 (need e41b 2cb76e50…)"
      ;;
  esac
  case "$rbf_md5" in
    2cb76e50*) ;;
    *)
      echo "switch_mode: WARN expected e41b prefix 2cb76e50, got ${rbf_md5}" >&2
      ;;
  esac
fi

# Preserve live token / server URL across profile swap (snapshot BEFORE overwrite)
preserve_key() {
  key=$1
  src=$2
  dest=$3
  val=$(grep "^${key}=" "$src" 2>/dev/null | head -1 | cut -d= -f2- || true)
  if [ -n "$val" ]; then
    if grep -q "^${key}=" "$dest"; then
      grep -v "^${key}=" "$dest" >"${dest}.tmp" || true
      mv "${dest}.tmp" "$dest"
    fi
    echo "${key}=${val}" >>"$dest"
  fi
}

TOK_SRC=
if [ -f "$ROOT/misterplex.conf" ]; then
  TOK_SRC=$ROOT/misterplex.conf
elif [ -f "$LINUX_CONF" ]; then
  TOK_SRC=$LINUX_CONF
fi
if [ -n "$TOK_SRC" ]; then
  cp -f "$TOK_SRC" "$ROOT/misterplex.conf.tokenbak" 2>/dev/null || true
fi
cp -f "$CONF" "$ROOT/misterplex.conf"
cp -f "$CONF" "$LINUX_CONF"
if [ -f "$ROOT/misterplex.conf.tokenbak" ]; then
  preserve_key PLEX_TOKEN "$ROOT/misterplex.conf.tokenbak" "$ROOT/misterplex.conf"
  preserve_key PLEX_BASE "$ROOT/misterplex.conf.tokenbak" "$ROOT/misterplex.conf"
  preserve_key PLEX_SERVERS "$ROOT/misterplex.conf.tokenbak" "$ROOT/misterplex.conf"
  preserve_key PMS_URL "$ROOT/misterplex.conf.tokenbak" "$ROOT/misterplex.conf"
fi
cp -f "$ROOT/misterplex.conf" "$LINUX_CONF"

# Product idle glass: always chevron logo (never sticky last frame from lab off/last).
for conf in "$ROOT/misterplex.conf" "$LINUX_CONF"; do
  if grep -q '^IDLE_SCREEN=' "$conf" 2>/dev/null; then
    grep -v '^IDLE_SCREEN=' "$conf" >"${conf}.idlefix" || true
    echo 'IDLE_SCREEN=logo' >>"${conf}.idlefix"
    mv -f "${conf}.idlefix" "$conf"
  else
    echo 'IDLE_SCREEN=logo' >>"$conf"
  fi
done

# Active RBF + daemon
cp -f "$RBF" "$UTIL/Plex.rbf"
cp -f "$RBF" /media/fat/Plex.rbf 2>/dev/null || true
cp -f "$DAE" "$BIN/misterplexd"
chmod +x "$BIN/misterplexd"

# LAN IP for cast name (never advertise 127.0.0.1)
IP=$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\./ { split($4,a,"/"); print a[1]; exit }' || true)
if [ -z "${IP:-}" ]; then
  IP=$(ip -4 -o addr show 2>/dev/null | awk '$4 !~ /^127\./ && $4 !~ /^169\.254\./ { split($4,a,"/"); print a[1]; exit }' || true)
fi
[ -n "${IP:-}" ] || IP=192.168.1.42

# Stop any running companion (numeric PIDs only)
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import os, glob, signal, time
for p in glob.glob('/proc/[0-9]*'):
    try:
        exe = os.readlink(p + '/exe')
    except Exception:
        continue
    if 'misterplexd' in exe:
        try:
            os.kill(int(os.path.basename(p)), signal.SIGTERM)
        except Exception:
            pass
time.sleep(0.3)
for p in glob.glob('/proc/[0-9]*'):
    try:
        exe = os.readlink(p + '/exe')
    except Exception:
        continue
    if 'misterplexd' in exe:
        try:
            os.kill(int(os.path.basename(p)), signal.SIGKILL)
        except Exception:
            pass
PY
else
  PID=$(pidof misterplexd 2>/dev/null || true)
  if [ -n "${PID:-}" ]; then
    kill $PID 2>/dev/null || true
    sleep 1
    PID2=$(pidof misterplexd 2>/dev/null || true)
    if [ -n "${PID2:-}" ]; then kill -9 $PID2 2>/dev/null || true; fi
  fi
fi
sleep 1

echo "==== switch $MODE $(date -u +%Y%m%dT%H%M%SZ) ip=$IP label=$LABEL ====" >>"$LOG"

# Soft core reload: Menu then Plex. Always attempt when MiSTer_cmd can appear;
# wait/retry instead of silently skipping on a brief race.
LOAD_OK=0
if wait_mister_cmd 20 || [ -c /dev/MiSTer_cmd ]; then
  if load_core_retry /media/fat/menu.rbf menu; then
    sleep 2
  else
    echo "switch_mode: menu load_core failed; continuing to Plex attempt" >&2
  fi
  # After menu bounce, cmd node may vanish briefly — wait again.
  if load_core_retry "$UTIL/Plex.rbf" "Plex ($LABEL)"; then
    LOAD_OK=1
    sleep 3
  fi
else
  echo "switch_mode: no /dev/MiSTer_cmd after wait — RBF+conf copied; load Plex from Menu manually" >&2
fi
if [ "$LOAD_OK" -ne 1 ]; then
  echo "switch_mode: WARNING core may still be previous RBF; verify CORENAME / md5 after manual load" >&2
fi

nohup "$BIN/misterplexd" \
  --name "MiSTerPlex-${IP}" \
  --id "misterplex-${IP}" \
  --port 3005 \
  --conf "$LINUX_CONF" \
  >>"$LOG" 2>&1 &
sleep 2

# start helper for reboot/watch paths
cat >"$BIN/start_misterplexd.sh" <<ST
#!/bin/sh
exec $BIN/misterplexd \\
  --name MiSTerPlex-${IP} \\
  --id misterplex-${IP} \\
  --port 3005 \\
  --conf $LINUX_CONF \\
  >>$LOG 2>&1
ST
chmod +x "$BIN/start_misterplexd.sh"

echo "OK mode=$MODE ($LABEL)"
echo "  rbf=$(basename "$RBF") md5=$(md5sum "$RBF" | awk '{print $1}')"
echo "  daemon md5=$(md5sum "$BIN/misterplexd" | awk '{print $1}')"
echo "  conf=$LINUX_CONF ip=$IP load_core_ok=$LOAD_OK"
PID=$(pidof misterplexd 2>/dev/null || true)
echo "  misterplexd pid=${PID:-none}"
grep -E '^(CONTENT_RES|DECODE|MPX_VIDEO_BACKEND|MPX_LEGACY|MPX_PRESENT|IDLE_SCREEN|AUDIO_DELAY)' "$LINUX_CONF" || true
