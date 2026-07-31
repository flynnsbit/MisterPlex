#!/bin/sh
# on_device_pair_boot_check.sh — run ON the MiSTer after cold boot (or as hook rehearse).
# Detached-safe: no SSH dependency once started. Writes a report file.
#
# Parent launches (from lab host):
#   scp scripts/on_device_pair_boot_check.sh root@$HOST:/media/fat/misterplex_v2/bin/
#   ssh root@$HOST 'nohup /media/fat/misterplex_v2/bin/on_device_pair_boot_check.sh \
#        >/media/fat/misterplex_v2/boot-check.nohup.out 2>&1 &'
#   # later:
#   ssh root@$HOST 'cat /media/fat/misterplex_v2/boot-check-report.txt; echo true rc=...'
#
# PASS criteria (DDR primary pair):
#   n_daemon=1
#   live exe md5 starts with edc3a46b (or EXPECT_DAEMON_PREFIX)
#   live conf under misterplex_v2 from cmdline --conf
#   REAL hook (from S99user USER_SCRIPT) has exactly one misterplex_v2 supervise line
#   decoy _user-startup.sh has ZERO misterplex autostart lines
#   /resources 200
#   optional: PLXS magic via devmem if available
#
# Does NOT capture HDMI (host owns grabber). Does NOT load cores.

set -eu

REPORT="${REPORT_PATH:-/media/fat/misterplex_v2/boot-check-report.txt}"
EXPECT_DAEMON_PREFIX="${EXPECT_DAEMON_PREFIX:-edc3a46b}"
EXPECT_ROOT="${EXPECT_ROOT:-/media/fat/misterplex_v2}"
EXPECT_CORE_PREFIX="${EXPECT_CORE_PREFIX:-c5382bee}"
PORT="${PORT:-3005}"
MODE="${1:-postboot}"   # postboot | rehearse-hook

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) $*"; }

mkdir -p "$(dirname "$REPORT")"
: >"$REPORT"
exec >>"$REPORT" 2>&1

log "=== on_device_pair_boot_check mode=$MODE ==="
rc=0

# --- resolve REAL hook from S99user (never assume _user-startup.sh) ---
INIT=/etc/init.d/S99user
DECOY=/media/fat/linux/_user-startup.sh
if [ ! -f "$INIT" ]; then
  log "FAIL no $INIT — cannot derive USER_SCRIPT"
  echo "VERDICT=FAIL reason=no_s99"
  echo "true rc=8"
  exit 8
fi
line=$(grep -E '^[[:space:]]*USER_SCRIPT=' "$INIT" | tail -1 || true)
val=${line#USER_SCRIPT=}
val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')
if [ -z "$val" ] || [ "${val#/}" = "$val" ]; then
  log "FAIL USER_SCRIPT unparseable line='$line'"
  echo "VERDICT=FAIL reason=user_script_unparseable"
  echo "true rc=8"
  exit 8
fi
HOOK=$val
log "OK boot-hook-path-from-init USER_SCRIPT=$HOOK"
case "$HOOK" in
  *_user-startup.sh)
    log "FAIL USER_SCRIPT points at known decoy name $HOOK"
    rc=3
    ;;
esac

if [ "$MODE" = "rehearse-hook" ]; then
  log "rehearse: stop daemon+supervisor then run REAL hook"
  for d in /proc/[0-9]*; do
    [ -r "$d/exe" ] || continue
    x=$(readlink -f "$d/exe" 2>/dev/null) || continue
    b=$(basename "$x")
    case "$b" in
      misterplexd)
        kill "${d#/proc/}" 2>/dev/null || true
        ;;
    esac
  done
  # stop supervisors by exe/name carefully
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *misterplexd_supervise.sh*)
        # only kill if exe is shell running that script — avoid killing unrelated
        kill "${d#/proc/}" 2>/dev/null || true
        ;;
    esac
  done
  sleep 2
  pre=0
  for d in /proc/[0-9]*; do
    x=$(readlink -f "$d/exe" 2>/dev/null) || continue
    [ "$(basename "$x")" = misterplexd ] && pre=$((pre + 1))
  done
  log "pre_hook_n_daemon=$pre"
  if [ -f "$HOOK" ]; then
    # shellcheck disable=SC1090
    sh "$HOOK" || log "NOTE hook exit non-zero (may be ok if only nohup lines)"
  else
    log "FAIL hook missing $HOOK"
    rc=3
  fi
  sleep 5
fi

# --- n_daemon via /proc/exe ONLY ---
n=0
pid=""
live_md5=""
live_exe=""
live_conf=""
live_cmd=""
for d in /proc/[0-9]*; do
  [ -r "$d/exe" ] || continue
  x=$(readlink -f "$d/exe" 2>/dev/null) || continue
  [ "$(basename "$x")" = misterplexd ] || continue
  n=$((n + 1))
  pid=${d#/proc/}
  live_exe=$x
  live_md5=$(md5sum "$d/exe" 2>/dev/null | awk '{print $1}')
  live_cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null || true)
  # parse --conf
  set -- $live_cmd
  while [ $# -gt 0 ]; do
    if [ "$1" = "--conf" ]; then live_conf=${2:-}; break; fi
    shift
  done
done
log "n_daemon=$n pid=$pid"
log "live_exe=$live_exe"
log "live_md5=$live_md5"
log "live_conf=$live_conf"
log "live_cmd=$live_cmd"

if [ "$n" -ne 1 ]; then
  log "FAIL n_daemon=$n want=1"
  rc=9
fi
case "$live_md5" in
  ${EXPECT_DAEMON_PREFIX}*) log "OK live-exe-md5 prefix=$EXPECT_DAEMON_PREFIX" ;;
  *)
    log "FAIL live-exe-md5 got=${live_md5:-empty} want_prefix=$EXPECT_DAEMON_PREFIX"
    rc=3
    ;;
esac
case "$live_exe" in
  "$EXPECT_ROOT"/*) log "OK live-exe under $EXPECT_ROOT" ;;
  *)
    log "FAIL live-exe not under expect root $EXPECT_ROOT"
    rc=3
    ;;
esac
case "$live_conf" in
  "$EXPECT_ROOT"/*) log "OK live-conf under $EXPECT_ROOT (from cmdline)" ;;
  "")
    log "FAIL live-conf empty"
    rc=9
    ;;
  *)
    log "FAIL live-conf $live_conf not under $EXPECT_ROOT"
    rc=3
    ;;
esac

# --- REAL hook body ---
if [ -f "$HOOK" ]; then
  log "=== REAL hook $HOOK ==="
  grep -n misterplex "$HOOK" || log "(no misterplex lines)"
  nsup=$(grep -c misterplexd_supervise.sh "$HOOK" 2>/dev/null || echo 0)
  nsup=$(echo "$nsup" | tr -d '[:space:]')
  has_v1=0
  has_v2=0
  grep -q '/misterplex/bin/misterplexd' "$HOOK" 2>/dev/null && has_v1=1 || true
  grep -q '/misterplex_v2/bin/misterplexd' "$HOOK" 2>/dev/null && has_v2=1 || true
  log "N_SUP=$nsup HAS_V1=$has_v1 HAS_V2=$has_v2"
  if [ "$nsup" != "1" ] || [ "$has_v1" = "1" ] || [ "$has_v2" != "1" ]; then
    log "FAIL boot-hook body not single v2 supervise"
    rc=3
  else
    log "OK boot-hook single v2 supervise"
  fi
  # hook root vs live root
  if [ -n "$live_exe" ]; then
    live_root=$(dirname "$(dirname "$live_exe")")
    case "$HOOK" in
      *)
        if ! grep -q "$live_root/bin/misterplexd_supervise" "$HOOK" 2>/dev/null; then
          log "FAIL boot-hook/live-root mismatch live_root=$live_root"
          rc=3
        else
          log "OK boot-hook matches live_root=$live_root"
        fi
        ;;
    esac
  fi
else
  log "FAIL REAL hook missing $HOOK"
  rc=3
fi

# --- decoy must be inert ---
if [ -f "$DECOY" ]; then
  log "=== decoy $DECOY (must be inert) ==="
  if grep -qE 'misterplexd_supervise|/misterplex.*/bin/misterplexd' "$DECOY" 2>/dev/null; then
    log "FAIL decoy armed — would confuse operators (not executed but dangerous)"
    grep -n misterplex "$DECOY" || true
    rc=3
  else
    log "OK decoy inert"
  fi
else
  log "OK decoy absent"
fi

# --- product + v2 core disk md5 (on-disk only; NOT execution proof) ---
if [ -f /media/fat/_Utility/Plex.rbf ]; then
  pm=$(md5sum /media/fat/_Utility/Plex.rbf | awk '{print $1}')
  log "product-core-disk md5=$pm (ON-DISK only — not executing bitstream)"
  case "$pm" in
    ${EXPECT_CORE_PREFIX}*) log "OK product-core-disk prefix=$EXPECT_CORE_PREFIX" ;;
    *) log "NOTE product-core-disk prefix mismatch got=$pm (may be intentional SPI daily)" ;;
  esac
else
  log "NOTE product core missing on disk"
fi
if [ -f /media/fat/_Utility/Plex_v2.rbf ]; then
  vm=$(md5sum /media/fat/_Utility/Plex_v2.rbf | awk '{print $1}')
  log "v2-rollback-core-disk md5=$vm"
else
  log "FAIL Plex_v2.rbf missing — one-step undo core gone"
  rc=2
fi

# --- http ---
code=000
if command -v wget >/dev/null 2>&1; then
  code=$(wget -q -O /dev/null -S "http://127.0.0.1:${PORT}/resources" 2>&1 | awk '/HTTP\//{print $2; exit}')
  code=${code:-000}
fi
if [ "$code" != "200" ] && command -v curl >/dev/null 2>&1; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "http://127.0.0.1:${PORT}/resources" || echo 000)
fi
log "http_resources=$code"
if [ "$code" != "200" ]; then
  log "FAIL /resources not 200"
  rc=9
else
  log "OK http /resources 200"
fi

# --- PLXS optional (proves executing ddr_frame_store when present) ---
if command -v devmem >/dev/null 2>&1; then
  m1=$(devmem 0x300FF100 32 2>/dev/null || echo MISSING)
  h1=$(devmem 0x300FF104 32 2>/dev/null || echo MISSING)
  sleep 0.1
  m2=$(devmem 0x300FF100 32 2>/dev/null || echo MISSING)
  h2=$(devmem 0x300FF104 32 2>/dev/null || echo MISSING)
  log "PLXS_MAGIC=$m1 PLXS_HI=$h1"
  log "PLXS_MAGIC2=$m2 PLXS_HI2=$h2"
  case "$(echo "$m1" | tr 'A-F' 'a-f')" in
    0x504c5853|504c5853) log "OK PLXS_MAGIC" ;;
    *)
      log "FAIL PLXS_MAGIC got=$m1 (MENU/other core or absent mailbox)"
      rc=3
      ;;
  esac
else
  log "NOTE devmem absent — PLXS not checked on-device"
fi

if [ "$rc" -eq 0 ]; then
  log "VERDICT=PASS"
else
  log "VERDICT=FAIL"
fi
log "true rc=$rc"
# also leave a one-line stamp for quick ssh cat
echo "$rc" >"${REPORT}.rc"
exit "$rc"
