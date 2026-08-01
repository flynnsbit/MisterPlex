#!/usr/bin/env bash
# video_regression.sh — compare a candidate build against the known-good v0.2.0
# baseline on real hardware, using HDMI-over-USB capture.
#
# WHY: the v0.2.0 GitHub release is the last combination proven on hardware to
# render playback without the left-edge defect. Any new core/daemon must be
# measured against it, not against a previous broken build.
#
# BASELINE (do not change without new hardware evidence + updating these hashes):
#   core   /media/fat/_Utility/Plex_v2.rbf              dfebf2bfd08dd70b473b587dd7e81848
#   daemon /media/fat/misterplex_v2/bin/misterplexd     7cd10b4d438c714a9b8c4766dc982d59
#   PRESENT=fpga   (fb0 decodes but never reaches HDMI: pfps stays 0.00)
#
# LIVENESS (verify must not pass on a dead daemon):
#   Authority is the RUNNING process: exact argv0 match via /proc/*/cmdline
#   (first NUL token only — never $ -anchor basename grep; real cmdlines carry
#   --name/--id/--port/--conf args), then md5sum /proc/<pid>/exe, plus an HTTP
#   probe of /resources on the port from that cmdline. On-disk md5 is kept only
#   as a secondary ETXTBSY signal (disk≠live → FAIL).
#   Conf path, if needed, comes from the live process --conf arg — never hardcode
#   which of /media/fat/misterplex{,_v2}/misterplex.conf is active.
#
# THIS SCRIPT IS FOR THE PARENT ORCHESTRATOR ONLY. Agents must not run it —
# they have no device access. See AGENTS.md "Who tests".
#
# Usage:
#   scripts/video_regression.sh baseline    # measure the v0.2.0 reference
#   scripts/video_regression.sh dev         # measure the development build
#   scripts/video_regression.sh verify      # just check baseline hashes + liveness

set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
VIDEO="${VIDEO_DEV:-/dev/video0}"
OUT="${OUT_DIR:-/tmp/vidreg}"
FRAMES="${FRAMES:-45}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BASE_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848

# Accepted daemon binaries for the baseline bundle.
#
#   7cd10b4d  the pristine v0.2.0 release asset. Good video, but it also ships
#             two defects measured on hardware: the Plex Web timeline is frozen
#             at 0:00 (v0.2.0 has no pms_timeline.cpp at all) and the GDM
#             self-reply storm burns a core at idle (measured 99 %onecpu).
#   de173a59  hybrid/v0.2.0-timeline + async-signal-safe crash backtrace handler.
#             Verified by sending SIGSEGV: FATAL block written, supervisor still saw
#             rc=139, daemon respawned. Decode frames with:
#               llvm-addr2line -e <matching unstripped binary> -f -C -a 0xPC ...
#   25f6db43  hybrid + SUSPEND_MAIN_DURING_PLAY opt-in (default 0).
#             ACCEPTED hybrid pin (live /proc/<pid>/exe as of 2026-07-30 w-armdeploy).
#   f5636ac2  hybrid + plextv: 200 without self_in_body logs no-op (not succeeded).
#             ACCEPTED hybrid pin (live /proc/<pid>/exe as of 2026-07-30 w-armdeploy).
#   48a60809  hybrid + modern plex.tv GET api/v2/resources registration
#             (plextv_device backport). Live registration http_status=200.
#             ACCEPTED hybrid pin (live /proc/<pid>/exe as of 2026-07-30 w-armdeploy).
#   fed70681  hybrid + reliable idle paint after stop (always DDR for idle, re-probe
#             latched kick fail, 500ms retry until land, greppable post-stop log).
#             ACCEPTED hybrid pin (live /proc/<pid>/exe as of 2026-07-30 w-armdeploy).
#   ed6af644  hybrid/v0.2.0-timeline: v0.2.0's 320x240 SPI present path plus the
#             PMS timeline reporter and the gdmIsDiscoveryProbe filter. Measured
#             on hardware: timeline advances 0 -> 8511 -> 17874 -> 26637 ms,
#             idle 1 %onecpu, edge fingerprint LEFT spread 0 / RIGHT spread 0.
#   56a53f77  REJECTED — same as de173a59 plus advertise-only
#             Protocol-Capabilities ...,provider-playback. No provider-playback
#             handlers exist; did not fix the cast picker. Reverted; do not pin.
#
# Both must produce the SAME video fingerprint, because the hybrid deliberately
# does not touch the present path. A video difference between them is a real
# regression and must fail.
BASE_DAEMON_MD5=7cd10b4d438c714a9b8c4766dc982d59
# Daemon pin chain (do NOT weaken — unknown md5 still FAILs):
#   9ce2c2d1  CURRENT live DDR (parent glass 2026-08-01; w-osd-hires chevron).
#   3883f5ab  prior live — accepted rollback.
#   7c991e47  post-raster — accepted prefix8.
#   edc3a46b  prior primary — accepted rollback.
#   5996385a  w-instr instrumented — accepted alternate.
#   b981fd20  on-device bak — accepted DDR rollback.
#   e9f79de2  first silicon-correct DDR — accepted rollback.
#   50f4eb92  SPI hybrid clamp path — accepted SPI rollback (NOT current live).
#   3e2cbb98  older hybrid — accepted rollback.
#   7cd10b4d  BASE release (above).
# Name HYBRID_* is historical; value is CURRENT expected live DDR pin.
HYBRID_DAEMON_PREFIX8=9ce2c2d1
HYBRID_DAEMON_MD5_DEFAULT=9ce2c2d13d1c8712683289043e99002c
if [ -f "${REPO:-$(cd "$(dirname "$0")/.." && pwd)}/artifacts/daemon-pins/misterplexd.${HYBRID_DAEMON_PREFIX8}" ]; then
  HYBRID_DAEMON_MD5=$(md5sum "${REPO:-$(cd "$(dirname "$0")/.." && pwd)}/artifacts/daemon-pins/misterplexd.${HYBRID_DAEMON_PREFIX8}" | awk '{print $1}')
  if [ "${HYBRID_DAEMON_MD5:0:8}" != "$HYBRID_DAEMON_PREFIX8" ]; then
    echo "FAIL pin-file md5='$HYBRID_DAEMON_MD5' not prefix $HYBRID_DAEMON_PREFIX8" >&2
    HYBRID_DAEMON_MD5="$HYBRID_DAEMON_MD5_DEFAULT"
  fi
else
  HYBRID_DAEMON_MD5="${HYBRID_DAEMON_MD5:-$HYBRID_DAEMON_MD5_DEFAULT}"
fi
# Documented rollbacks (full when known; prefix8 identity accepted for b981).
DDR_CUR_DAEMON_MD5="$HYBRID_DAEMON_MD5"
DDR_B981_DAEMON_MD5="${DDR_B981_DAEMON_MD5:-b981fd20}"
DDR_EDC3_DAEMON_MD5=edc3a46b9d1c6b86337deb90f896eb0f
DDR_HIST_DAEMON_MD5=e9f79de217982aff44207664fdb945c5
DDR_3883_DAEMON_MD5=3883f5ab8744e070e7b0820c6b9b4376
PREV_HYBRID_DAEMON_MD5=50f4eb925de10e29172999a565c87684
OLDER_HYBRID_DAEMON_MD5=3e2cbb9881b2f54b0e4cb60238655fa7

# Test clip: the 240p burned-in-telemetry ladder entry. Its overlay text makes
# left-edge clipping obvious to the eye as well as to the measurement.
PMS_ID="${PMS_ID:-bf36a3ad8d4f6810ab3f69ec9f1adb22a7a9dc8a}"
PMS_HOST="${PMS_HOST:-192.168.1.24}"
RATING_KEY="${RATING_KEY:-3}"
TOKEN_FILE="${TOKEN_FILE:-/tmp/.tok}"

# Device transport. Host unit tests inject VIDREG_SSHM (command that receives
# the remote shell snippet as a single argument) so we never need the live box.
# Lab SSH drops ~1/3 ("No route to host"); retry with backoff. Never treat an
# empty observation after a failed transport as a hash MISMATCH.
VIDREG_SSH_TRIES="${VIDREG_SSH_TRIES:-5}"
VIDREG_SSH_BACKOFF_S="${VIDREG_SSH_BACKOFF_S:-1}"

sshm_once() {
  if [ -n "${VIDREG_SSHM:-}" ]; then
    # shellcheck disable=SC2086
    $VIDREG_SSHM "$@"
    return $?
  fi
  sshpass -p "$PASS" ssh     -o StrictHostKeyChecking=no     -o ConnectTimeout=8     -o ServerAliveInterval=2     -o ServerAliveCountMax=2     "root@$HOST" "$@"
}

# Print stdout on success. On exhausted retries return 5 (NETWORK) with no stdout.
sshm() {
  local attempt=0 delay="${VIDREG_SSH_BACKOFF_S}" out rc
  local errf="${VIDREG_SSH_ERRFILE:-$REPO/build/vidreg-ssh.err}"
  mkdir -p "$(dirname "$errf")"
  while [ "$attempt" -lt "$VIDREG_SSH_TRIES" ]; do
    attempt=$((attempt + 1))
    : >"$errf"
    set +e
    out=$(sshm_once "$@" 2>"$errf")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
    echo "sshm-retry attempt=$attempt/${VIDREG_SSH_TRIES} rc=$rc err=$(tr '\n' ' ' <"$errf" | head -c 120)" >&2
    sleep "$delay"
    delay=$((delay * 2))
    [ "$delay" -gt 16 ] && delay=16
  done
  echo "sshm-FAILED NETWORK after ${VIDREG_SSH_TRIES} attempts" >&2
  return 5
}

# Empty string is NO-DATA, never a mismatch against a want hash.
classify_obs_hash() {
  local label="$1" got="$2"
  shift 2
  if [ -z "$got" ]; then
    echo "NO-DATA $label got='' (empty — not a mismatch; SSH drop or remote produced no hash)"
    return 4
  fi
  local w
  for w in "$@"; do
    if [ "$got" = "$w" ]; then
      echo "OK   $label $got"
      return 0
    fi
  done
  echo "FAIL $label got='$got' want=$*"
  return 1
}

# HTTP probe transport. Host tests inject VIDREG_HTTP (cmd receiving URL).
http_probe() {
  local url="$1"
  if [ -n "${VIDREG_HTTP:-}" ]; then
    # shellcheck disable=SC2086
    $VIDREG_HTTP "$url"
    return $?
  fi
  curl -s -o /dev/null -w '%{http_code}' -m 3 "$url" 2>/dev/null || echo "000"
}

BASE_DAEMON_BIN=/media/fat/misterplex_v2/bin/misterplexd
DEV_DAEMON_BIN=/media/fat/misterplex/bin/misterplexd

daemon_md5_accepted() {
  local m="${1:-}" p8
  [ -n "$m" ] || return 1
  case "$m" in
    "$BASE_DAEMON_MD5"|"$HYBRID_DAEMON_MD5"|"$DDR_CUR_DAEMON_MD5"|"$DDR_3883_DAEMON_MD5"|"$DDR_EDC3_DAEMON_MD5"|"$DDR_HIST_DAEMON_MD5"|"$PREV_HYBRID_DAEMON_MD5"|"$OLDER_HYBRID_DAEMON_MD5")
      return 0
      ;;
  esac
  p8="${m:0:8}"
  # Accepted DDR/SPI prefix8 set (current + documented rollbacks). Unknown → FAIL.
  # 50f4eb92 remains SPI undo only — still accepted, not "current live".
  case "$p8" in
    9ce2c2d1|3883f5ab|7c991e47|36b89bcb|5996385a|b981fd20|edc3a46b|e9f79de2|50f4eb92|3e2cbb98|7cd10b4d) return 0 ;;
  esac
  if [ "${#HYBRID_DAEMON_MD5}" -eq 8 ] && [ "$p8" = "$HYBRID_DAEMON_MD5" ]; then
    return 0
  fi
  if [ "$p8" = "$HYBRID_DAEMON_PREFIX8" ] && [ "${HYBRID_DAEMON_MD5:0:8}" = "$HYBRID_DAEMON_PREFIX8" ]; then
    return 0
  fi
  return 1
}

# Remote (or injected) one-shot observation of on-disk + running daemon state.
# Exact argv0 match against BIN — first NUL-separated cmdline token only.
# NOT pidof. NOT basename$ grep (live argv includes --name/--conf/... args).
# /proc races: skip unreadable/vanished dirs rather than erroring.
# Prints machine-readable lines:
#   DISK_MD5=<md5|empty>
#   N_MATCH=<int>
#   PIDS=<space-separated or empty>
#   LIVE_MD5=<md5|empty>
#   LIVE_PORT=<int|empty>
#   LIVE_CONF=<path|empty>
#   LIVE_NOTE=<text>
observe_daemon_once() {
  local bin="$1"
  sshm "bin=$(printf '%q' "$bin"); $(cat <<'REMOTE'
set +e
disk=""
if [ -f "$bin" ]; then
  disk=$(md5sum "$bin" 2>/dev/null | awk '{print $1}')
fi
echo "DISK_MD5=${disk}"
pids=""
n=0
port=""
conf=""
for d in /proc/[0-9]*; do
  [ -d "$d" ] || continue
  [ -r "$d/cmdline" ] || continue
  # Portable NUL→newline argv (BusyBox ash has no mapfile). Match argv0
  # EXACTLY to bin path. Do not $ -anchor basename; real cmdlines carry args.
  cmd_nl=$(tr "\0" "\n" <"$d/cmdline" 2>/dev/null) || continue
  a0=$(printf "%s\n" "$cmd_nl" | head -n1)
  [ -n "$a0" ] || continue
  [ "$a0" = "$bin" ] || continue
  p=${d#/proc/}
  [ -d "/proc/$p" ] || continue
  pids="${pids}${pids:+ }$p"
  n=$((n + 1))
  # Capture --port / --conf from THIS match (last wins if multi; multi fails later).
  port=""; conf=""; prev=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$prev" in
      --port) port="$tok"; prev=""; continue ;;
      --conf) conf="$tok"; prev=""; continue ;;
    esac
    case "$tok" in
      --port) prev=--port ;;
      --port=*) port="${tok#--port=}"; prev="" ;;
      --conf) prev=--conf ;;
      --conf=*) conf="${tok#--conf=}"; prev="" ;;
      *) prev="" ;;
    esac
  done <<TOKENS
$cmd_nl
TOKENS
done
echo "N_MATCH=$n"
echo "PIDS=$pids"
live=""
note="none"
if [ "$n" -eq 0 ]; then
  note="no_process"
  port=""; conf=""
elif [ "$n" -gt 1 ]; then
  note="multi_match"
else
  pid=$pids
  if [ ! -e "/proc/$pid/exe" ]; then
    note="exe_vanished"
    port=""; conf=""
  else
    live=$(md5sum "/proc/$pid/exe" 2>/dev/null | awk '{print $1}')
    if [ -z "$live" ]; then
      note="exe_unreadable"
    else
      note="ok"
    fi
  fi
fi
echo "LIVE_MD5=${live}"
echo "LIVE_PORT=${port}"
echo "LIVE_CONF=${conf}"
echo "LIVE_NOTE=${note}"
REMOTE
)"
}

# Poll until a single matching live daemon appears or deadline.
# Supervisor max backoff is 64s (2,4,8,16,32,64); default wait exceeds that.
# LIVE_WAIT_SEC / LIVE_POLL_SEC overridable for host tests.
wait_for_live_daemon() {
  local bin="$1"
  local wait_sec="${LIVE_WAIT_SEC:-90}"
  local poll_sec="${LIVE_POLL_SEC:-2}"
  local deadline start now attempt=0
  local obs disk n pids live note port conf
  local saw_down=0

  start=$(date +%s)
  deadline=$((start + wait_sec))
  while :; do
    attempt=$((attempt + 1))
    now=$(date +%s)
    obs=$(observe_daemon_once "$bin" 2>/dev/null || true)
    disk=$(printf '%s\n' "$obs" | sed -n 's/^DISK_MD5=//p' | head -1)
    n=$(printf '%s\n' "$obs" | sed -n 's/^N_MATCH=//p' | head -1)
    pids=$(printf '%s\n' "$obs" | sed -n 's/^PIDS=//p' | head -1)
    live=$(printf '%s\n' "$obs" | sed -n 's/^LIVE_MD5=//p' | head -1)
    note=$(printf '%s\n' "$obs" | sed -n 's/^LIVE_NOTE=//p' | head -1)
    port=$(printf '%s\n' "$obs" | sed -n 's/^LIVE_PORT=//p' | head -1)
    conf=$(printf '%s\n' "$obs" | sed -n 's/^LIVE_CONF=//p' | head -1)
    n=${n:-0}
    echo "live-attempt=$attempt t+$((now - start))s bin=$bin n_match=$n pids='${pids}' disk='${disk}' live='${live}' port='${port}' conf='${conf}' note='${note}'"

    if [ "$n" -eq 0 ] || [ "$note" = "no_process" ] || [ "$note" = "exe_vanished" ]; then
      saw_down=1
    elif [ "$n" -gt 1 ] || [ "$note" = "multi_match" ]; then
      printf '%s\n' "$obs"
      echo "LIVE_WAIT_RESULT=multi_match"
      return 3
    elif [ -n "$live" ] && [ "$note" = "ok" ]; then
      printf '%s\n' "$obs"
      if [ "$saw_down" -eq 1 ]; then
        echo "LIVE_WAIT_RESULT=respawned attempt=$attempt"
      else
        echo "LIVE_WAIT_RESULT=up attempt=$attempt"
      fi
      return 0
    fi

    if [ "$now" -ge "$deadline" ]; then
      printf '%s\n' "$obs"
      echo "LIVE_WAIT_RESULT=timeout attempts=$attempt saw_down=$saw_down wait_sec=$wait_sec"
      return 2
    fi
    sleep "$poll_sec"
  done
}

# Probe HTTP liveness using port from the live process cmdline (default 3005).
probe_http_liveness() {
  local port="${1:-3005}"
  local url="http://${HOST}:${port}/resources"
  local code
  code=$(http_probe "$url")
  code=${code:-000}
  echo "HTTP_PROBE url=$url code=$code"
  case "$code" in
    200|204) return 0 ;;
    *) return 1 ;;
  esac
}

verify_baseline() {
  echo "== verifying baseline hashes on device =="
  local got_core got_disk rc=0
  local wait_out wait_rc disk live n note pids port conf
  local http_out http_rc

  # Capture ssh rc DIRECTLY (never through a pipe). Empty stdout after rc=0 is
  # NO-DATA; rc=5 is NETWORK. Never report empty as FAIL mismatch.
  set +e
  got_core=$(sshm "md5sum /media/fat/_Utility/Plex_v2.rbf 2>/dev/null | cut -d' ' -f1")
  ssh_rc=$?
  set -e
  if [ "$ssh_rc" -eq 5 ]; then
    echo "NETWORK core-disk (SSH failed after retries)"
    rc=5
  else
    set +e
    classify_obs_hash "core" "$got_core" "$BASE_CORE_MD5"
    step_rc=$?
    set -e
    if [ "$step_rc" -eq 4 ]; then rc=4; elif [ "$step_rc" -ne 0 ]; then rc=1; fi
  fi

  # On-disk check remains as an *additional* signal (ETXTBSY detection needs it).
  set +e
  got_disk=$(sshm "md5sum $BASE_DAEMON_BIN 2>/dev/null | cut -d' ' -f1")
  ssh_rc=$?
  set -e
  if [ "$ssh_rc" -eq 5 ]; then
    echo "NETWORK daemon-disk (SSH failed after retries)"
    [ "$rc" -eq 0 ] && rc=5
  elif [ -z "$got_disk" ]; then
    echo "NO-DATA daemon-disk got='' (empty — not a mismatch; SSH drop or remote produced no hash)"
    [ "$rc" -eq 0 ] && rc=4
  elif daemon_md5_accepted "$got_disk"; then
    echo "OK   daemon-disk $got_disk"
  else
    echo "FAIL daemon-disk got='$got_disk' want=accepted{9ce2c2d1,3883f5ab,edc3a46b,5996385a,b981fd20,e9f79de2,50f4eb92,7cd10b4d,...}"
    rc=1
  fi

  echo "== verifying RUNNING baseline daemon (/proc argv0 + /proc/PID/exe + HTTP) =="
  set +e
  wait_out=$(wait_for_live_daemon "$BASE_DAEMON_BIN")
  wait_rc=$?
  set -e
  printf '%s\n' "$wait_out"

  disk=$(printf '%s\n' "$wait_out" | sed -n 's/^DISK_MD5=//p' | tail -1)
  live=$(printf '%s\n' "$wait_out" | sed -n 's/^LIVE_MD5=//p' | tail -1)
  n=$(printf '%s\n' "$wait_out" | sed -n 's/^N_MATCH=//p' | tail -1)
  note=$(printf '%s\n' "$wait_out" | sed -n 's/^LIVE_NOTE=//p' | tail -1)
  pids=$(printf '%s\n' "$wait_out" | sed -n 's/^PIDS=//p' | tail -1)
  port=$(printf '%s\n' "$wait_out" | sed -n 's/^LIVE_PORT=//p' | tail -1)
  conf=$(printf '%s\n' "$wait_out" | sed -n 's/^LIVE_CONF=//p' | tail -1)
  n=${n:-0}
  port=${port:-3005}

  if [ "$wait_rc" -eq 3 ] || [ "$n" -gt 1 ]; then
    echo "FAIL daemon-live multi-match n=$n pids='$pids' (refuse ambiguous bundle)"
    rc=1
  elif [ "$wait_rc" -ne 0 ] || [ "$n" -eq 0 ] || [ -z "$live" ]; then
    echo "FAIL daemon-live n_daemon=0 (no running process with argv0=$BASE_DAEMON_BIN after wait)"
    echo "     supervisor may be in backoff, but it never came back — hard FAIL"
    rc=1
  elif ! daemon_md5_accepted "$live"; then
    echo "FAIL daemon-live md5='$live' not in accepted {9ce2c2d1,3883f5ab,edc3a46b,5996385a,b981fd20,e9f79de2,50f4eb92,...} pid='$pids'"
    rc=1
  else
    if printf '%s\n' "$wait_out" | grep -q 'LIVE_WAIT_RESULT=respawned'; then
      echo "OK   daemon-live $live pid=$pids conf='${conf}' (respawned during wait — supervisor backoff observed)"
    else
      echo "OK   daemon-live $live pid=$pids conf='${conf}'"
    fi
    if [ -n "$conf" ]; then
      echo "OK   daemon-conf $conf (from live --conf; not hardcoded)"
    else
      echo "NOTE daemon-conf empty (process had no --conf arg)"
    fi

    # Real liveness signal: HTTP must answer. A process that exists but is
    # wedged / not listening is still a FAIL.
    set +e
    http_out=$(probe_http_liveness "$port")
    http_rc=$?
    set -e
    printf '%s\n' "$http_out"
    if [ "$http_rc" -eq 0 ]; then
      echo "OK   daemon-http port=$port /resources"
    else
      echo "FAIL daemon-http port=$port /resources not healthy ($http_out)"
      rc=1
    fi
  fi

  # ETXTBSY / silent failed deploy: disk says new, running says old (or other).
  # Both sides must be non-empty — empty is NO-DATA, never a mismatch.
  if [ -n "$got_disk" ] && [ -n "$live" ] && [ "$got_disk" != "$live" ]; then
    echo "FAIL daemon-disk/live mismatch disk='$got_disk' live='$live'"
    echo "     hint: cp over a RUNNING binary fails ETXTBSY and leaves the old"
    echo "     image executing — stop first, then verify /proc/PID/exe (not disk alone)"
    rc=1
  fi

  return $rc
}

run_bundle() {
  local which="$1" core conf_root daemon_bin
  case "$which" in
    baseline) core=/media/fat/_Utility/Plex_v2.rbf; conf_root=/media/fat/misterplex_v2; daemon_bin=$BASE_DAEMON_BIN ;;
    dev)      core=/media/fat/_Utility/Plex.rbf;    conf_root=/media/fat/misterplex;    daemon_bin=$DEV_DAEMON_BIN ;;
    *) echo "unknown bundle: $which"; exit 1 ;;
  esac

  # plexctl holds an exclusive flock, so exactly one daemon can ever run.
  # Duplicate daemons were observed competing as frame writers.
  echo "== starting $which bundle (single-instance enforced) =="
  sshm "/media/fat/misterplex/bin/plexctl.sh $(
        [ "$which" = baseline ] && echo v2 || echo dev)" | head -3

  echo "== loading core $core =="
  sshm "printf '%s\n' 'load_core $core' > /dev/MiSTer_cmd"
  sleep 14

  # Exact argv0 match for this bundle — not pidof (plexctl.sh deliberately
  # abandoned pidof: BusyBox name truncation + no bundle-path distinction).
  echo "== waiting for live daemon $daemon_bin =="
  local wait_out wait_rc n port conf http_out http_rc
  set +e
  wait_out=$(wait_for_live_daemon "$daemon_bin")
  wait_rc=$?
  set -e
  printf '%s\n' "$wait_out"
  n=$(printf '%s\n' "$wait_out" | sed -n 's/^N_MATCH=//p' | tail -1)
  port=$(printf '%s\n' "$wait_out" | sed -n 's/^LIVE_PORT=//p' | tail -1)
  conf=$(printf '%s\n' "$wait_out" | sed -n 's/^LIVE_CONF=//p' | tail -1)
  n=${n:-0}
  port=${port:-3005}
  [ "$wait_rc" -eq 0 ] && [ "$n" -eq 1 ] \
    || { echo "FAIL expected exactly 1 live daemon argv0=$daemon_bin, n=$n wait_rc=$wait_rc"; exit 3; }
  echo "daemon count OK: $n (live argv0 match) conf='${conf}'"

  set +e
  http_out=$(probe_http_liveness "$port")
  http_rc=$?
  set -e
  printf '%s\n' "$http_out"
  [ "$http_rc" -eq 0 ] \
    || { echo "FAIL daemon-http port=$port /resources not healthy"; exit 3; }

  # Telemetry log path: prefer live --conf directory; fall back to bundle root.
  local log_path
  if [ -n "$conf" ]; then
    log_path="$(dirname "$conf")/misterplexd.log"
  else
    log_path="$conf_root/misterplexd.log"
  fi

  echo "== casting ratingKey=$RATING_KEY =="
  local tok; tok=$(cat "$TOKEN_FILE")
  curl -s -m 25 "http://$HOST:${port}/player/playback/playMedia\
?address=$PMS_HOST&port=32400&protocol=http\
&key=%2Flibrary%2Fmetadata%2F$RATING_KEY&machineIdentifier=$PMS_ID\
&offset=0&commandID=1&X-Plex-Token=$tok" >/dev/null
  sleep 22

  echo "== telemetry =="
  sshm "tail -3 $log_path"

  echo "== capturing $FRAMES frames =="
  mkdir -p "$OUT/$which"; rm -f "$OUT/$which"/*.png
  ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
         -i "$VIDEO" -frames:v "$FRAMES" -y "$OUT/$which/f_%02d.png"

  echo "== measuring =="
  python3 "$REPO/tools/measure_edges.py" "$OUT/$which"/*.png
}

# Host unit tests source this file with VIDREG_LIB_ONLY=1 to call helpers.
if [ "${VIDREG_LIB_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

case "${1:-verify}" in
  verify)   verify_baseline ;;
  baseline) verify_baseline; run_bundle baseline ;;
  dev)      run_bundle dev ;;
  *) echo "usage: $0 {baseline|dev|verify}"; exit 1 ;;
esac
