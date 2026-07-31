#!/usr/bin/env bash
# video_regression.sh — compare a candidate build against the known-good v0.2.0
# baseline on real hardware, using HDMI-over-USB capture.
#
# WHY: the v0.2.0 GitHub release is the last combination proven on hardware to
# render playback without the left-edge defect. Any new core/daemon must be
# measured against it, not against a previous broken build.
#
# KNOWN-GOOD PAIRS (do not change without new hardware evidence + updating hashes):
#   SPI daily (rollback slot):
#     core   /media/fat/_Utility/Plex_v2.rbf            dfebf2bfd08dd70b473b587dd7e81848
#     daemon /media/fat/misterplex_v2/bin/misterplexd   50f4eb925de10e29172999a565c87684
#            (also accepts release 7cd10b4d… and PREV_HYBRID 3e2cbb98…)
#   DDR product (first correct silicon DDR path — parent-viewed pixels):
#     core   /media/fat/_Utility/Plex.rbf               c5382bee73cecdee8220b811e529c297
#     daemon live /proc/<pid>/exe                       edc3a46b… (CURRENT; 240p+native 480p)
#            PREV DDR pin e9f79de2… still accepted (rollback)
#   PRESENT=fpga   (fb0 decodes but never reaches HDMI: pfps stays 0.00)
#   Rollback slot Plex_v2.rbf must stay dfebf2bf even when product is DDR so
#   restore never gate-reds. verify PASSes when EITHER pair is fully live.
#   GATE_CORE_IDENTITY=UNVERIFIED until live PLXC proves the running bitstream
#   (on-disk RBF md5 alone is NOT silicon proof — see w-lint contract).
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

# SPI rollback core (Plex_v2.rbf slot). Always required intact.
BASE_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848
# DDR product core (Plex.rbf slot). Parent BUILD_OK leftedge3 + silicon soak.
DDR_CORE_MD5=c5382bee73cecdee8220b811e529c297

# Accepted daemon binaries.
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
# SPI hybrid pins must produce the SAME video fingerprint (hybrid does not touch
# the present path). DDR pin is a different path (yuv420p DDR) and is paired
# with DDR_CORE_MD5 only.
BASE_DAEMON_MD5=7cd10b4d438c714a9b8c4766dc982d59
# 50f4eb92  CURRENT SPI hybrid — clamps DECODE to the 320x240 RGB565 frame store
#           instead of silently skipping FPGA present (pfps was 0.00 at 624x480),
#           opt-in PRESENT_SCALE_TO_STORE, supervisor backoff reset after healthy
#           run. Parent-verified: 240p pfps 23.2 av-lock; 624x480 clamps pfps 23.6.
HYBRID_DAEMON_MD5=50f4eb925de10e29172999a565c87684
# PREV_* kept so a rollback binary never gate-reds after a pin advance.
PREV_HYBRID_DAEMON_MD5=3e2cbb9881b2f54b0e4cb60238655fa7
# edc3a46b  CURRENT DDR companion — parent 2026-07-31: c5382bee + edc3a46b
#           renders 240p AND native 480p correctly (viewed pixels). Full digest
#           may be longer; md5_match accepts unique prefix ≥8 hex.
DDR_DAEMON_MD5=edc3a46b
# e9f79de2  PREV DDR companion — PLXD doorbell-relative; 295s soak drops=2.
#           Kept so rollback never gate-reds after the pin advance.
PREV_DDR_DAEMON_MD5=e9f79de217982aff44207664fdb945c5

# Test clip: the 240p burned-in-telemetry ladder entry. Its overlay text makes
# left-edge clipping obvious to the eye as well as to the measurement.
PMS_ID="${PMS_ID:-bf36a3ad8d4f6810ab3f69ec9f1adb22a7a9dc8a}"
PMS_HOST="${PMS_HOST:-192.168.1.24}"
RATING_KEY="${RATING_KEY:-3}"
TOKEN_FILE="${TOKEN_FILE:-/tmp/.tok}"

# Device transport. Host unit tests inject VIDREG_SSHM (command that receives
# the remote shell snippet as a single argument) so we never need the live box.
sshm() {
  if [ -n "${VIDREG_SSHM:-}" ]; then
    # shellcheck disable=SC2086
    $VIDREG_SSHM "$@"
    return $?
  fi
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "root@$HOST" "$@"
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
BASE_CORE_PATH=/media/fat/_Utility/Plex_v2.rbf
DDR_CORE_PATH=/media/fat/_Utility/Plex.rbf

# md5_match PIN GOT — full equality, or PIN is unique prefix (≥8 hex) of GOT.
md5_match() {
  local pin="$1" got="$2"
  [ -n "$pin" ] && [ -n "$got" ] || return 1
  if [ "$pin" = "$got" ]; then return 0; fi
  local plen=${#pin}
  if [ "$plen" -ge 8 ] && [ "${got:0:plen}" = "$pin" ]; then return 0; fi
  return 1
}

# SPI hybrid/release pins (pair with BASE_CORE_MD5 on Plex_v2.rbf).
spi_daemon_md5_accepted() {
  case "$1" in
    "$BASE_DAEMON_MD5"|"$HYBRID_DAEMON_MD5"|"$PREV_HYBRID_DAEMON_MD5") return 0 ;;
    *) return 1 ;;
  esac
}

# DDR companion pins (pair with DDR_CORE_MD5 on Plex.rbf). CURRENT + PREV.
ddr_daemon_md5_accepted() {
  if [ -n "${DDR_DAEMON_MD5:-}" ] && md5_match "$DDR_DAEMON_MD5" "$1"; then return 0; fi
  if [ -n "${PREV_DDR_DAEMON_MD5:-}" ] && md5_match "$PREV_DDR_DAEMON_MD5" "$1"; then return 0; fi
  return 1
}

# Any accepted known-good daemon (SPI or DDR). Pairing is enforced in verify.
daemon_md5_accepted() {
  spi_daemon_md5_accepted "$1" || ddr_daemon_md5_accepted "$1"
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
  echo "== verifying known-good pair hashes on device =="
  local got_core_v2 got_core_ddr got_disk rc=0
  local wait_out wait_rc disk live n note pids port conf
  local http_out http_rc
  local daemon_bin pair="" live_ok=0
  local spi_disk_ok=0 ddr_disk_ok=0

  # Rollback slot must always stay the SPI daily driver so restore never gate-reds.
  got_core_v2=$(sshm "md5sum $BASE_CORE_PATH 2>/dev/null | cut -d' ' -f1" || true)
  if [ "$got_core_v2" = "$BASE_CORE_MD5" ]; then
    echo "OK   core-v2 (rollback) $got_core_v2"
  else
    echo "FAIL core-v2 (rollback) got='$got_core_v2' want='$BASE_CORE_MD5'"
    rc=1
  fi

  # Product slot: optional until DDR is promoted; when present must be the
  # known-good DDR core (or empty/absent is fine for pure-SPI daily).
  got_core_ddr=$(sshm "md5sum $DDR_CORE_PATH 2>/dev/null | cut -d' ' -f1" || true)
  if [ -z "$got_core_ddr" ]; then
    echo "NOTE core-ddr (product) absent/unreadable — SPI-only layout OK"
  elif [ "$got_core_ddr" = "$DDR_CORE_MD5" ]; then
    echo "OK   core-ddr (product) $got_core_ddr"
  else
    echo "FAIL core-ddr (product) got='$got_core_ddr' want='$DDR_CORE_MD5' or absent"
    rc=1
  fi

  # Prefer the live daemon path: try v2 root first (daily), then dev root.
  # DDR hand-installs often land on the v2 path; SPI daily always does.
  # Do not fall through on multi-match (rc=3) — that is already a hard FAIL.
  echo "== verifying RUNNING known-good daemon (/proc argv0 + /proc/PID/exe + HTTP) =="
  daemon_bin="$BASE_DAEMON_BIN"
  set +e
  wait_out=$(wait_for_live_daemon "$BASE_DAEMON_BIN")
  wait_rc=$?
  set -e
  n=$(printf '%s\n' "$wait_out" | sed -n 's/^N_MATCH=//p' | tail -1)
  n=${n:-0}
  if [ "$wait_rc" -ne 3 ] && { [ "$wait_rc" -ne 0 ] || [ "$n" -eq 0 ]; }; then
    set +e
    wait_out=$(wait_for_live_daemon "$DEV_DAEMON_BIN")
    wait_rc=$?
    set -e
    daemon_bin="$DEV_DAEMON_BIN"
  fi
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
  got_disk=$disk

  # On-disk secondary signal (ETXTBSY). Accept either pin family on disk.
  if [ -n "$got_disk" ] && daemon_md5_accepted "$got_disk"; then
    echo "OK   daemon-disk $got_disk"
    spi_daemon_md5_accepted "$got_disk" && spi_disk_ok=1
    ddr_daemon_md5_accepted "$got_disk" && ddr_disk_ok=1
  elif [ -n "$got_disk" ]; then
    echo "FAIL daemon-disk got='$got_disk' want SPI{$BASE_DAEMON_MD5,$HYBRID_DAEMON_MD5,$PREV_HYBRID_DAEMON_MD5} or DDR{$DDR_DAEMON_MD5${PREV_DDR_DAEMON_MD5:+,$PREV_DDR_DAEMON_MD5}}"
    rc=1
  else
    echo "NOTE daemon-disk empty (process root may differ from probed bin)"
  fi

  if [ "$wait_rc" -eq 3 ] || [ "$n" -gt 1 ]; then
    echo "FAIL daemon-live multi-match n=$n pids='$pids' (refuse ambiguous bundle)"
    rc=1
  elif [ "$wait_rc" -ne 0 ] || [ "$n" -eq 0 ] || [ -z "$live" ]; then
    echo "FAIL daemon-live n_daemon=0 (no running process with argv0 in {$BASE_DAEMON_BIN,$DEV_DAEMON_BIN} after wait)"
    echo "     supervisor may be in backoff, but it never came back — hard FAIL"
    rc=1
  elif ! daemon_md5_accepted "$live"; then
    echo "FAIL daemon-live md5='$live' not in accepted SPI{$BASE_DAEMON_MD5,$HYBRID_DAEMON_MD5,$PREV_HYBRID_DAEMON_MD5} or DDR{$DDR_DAEMON_MD5${PREV_DDR_DAEMON_MD5:+,$PREV_DDR_DAEMON_MD5}} pid='$pids'"
    rc=1
  else
    live_ok=1
    if printf '%s\n' "$wait_out" | grep -q 'LIVE_WAIT_RESULT=respawned'; then
      echo "OK   daemon-live $live pid=$pids conf='${conf}' bin=$daemon_bin (respawned during wait — supervisor backoff observed)"
    else
      echo "OK   daemon-live $live pid=$pids conf='${conf}' bin=$daemon_bin"
    fi
    if [ -n "$conf" ]; then
      echo "OK   daemon-conf $conf (from live --conf; not hardcoded)"
    else
      echo "NOTE daemon-conf empty (process had no --conf arg)"
    fi

    # Pairing: SPI daemon requires rollback core; DDR daemon requires product core.
    if spi_daemon_md5_accepted "$live"; then
      if [ "$got_core_v2" = "$BASE_CORE_MD5" ]; then
        pair=spi
        echo "OK   pair SPI core-v2=$got_core_v2 daemon=$live"
      else
        echo "FAIL pair SPI daemon=$live but core-v2='$got_core_v2' want='$BASE_CORE_MD5'"
        rc=1
      fi
    elif ddr_daemon_md5_accepted "$live"; then
      if [ "$got_core_ddr" = "$DDR_CORE_MD5" ] && [ "$got_core_v2" = "$BASE_CORE_MD5" ]; then
        pair=ddr
        echo "OK   pair DDR core-ddr=$got_core_ddr daemon=$live (rollback core-v2 intact)"
      else
        echo "FAIL pair DDR daemon=$live requires core-ddr='$DDR_CORE_MD5' (got '$got_core_ddr') and core-v2='$BASE_CORE_MD5' (got '$got_core_v2')"
        rc=1
      fi
    fi

    # Running-bitstream identity (PLXC). On-disk RBF md5 is blind during mixed
    # promotion (DDR daemon + SPI core = black screen but file gate green).
    # Parent injects VIDREG_CORE_ID=absent|ddr|spi[,prov=0x....] from a live PLXC
    # read (doorbell+0x130). Fail CLOSED on identity: default stamp is
    # GATE_CORE_IDENTITY=UNVERIFIED — GREEN pair/liveness is NOT silicon proof
    # of the running bitstream (w-lint contract). VERIFIED_PLXC only when a live
    # PLXC path=ddr|spi inject is present. VIDREG_REQUIRE_CORE_ID=1 forces RED
    # on missing/absent inject (post identity RBF).
    gate_core_identity=UNVERIFIED
    if [ -n "${VIDREG_CORE_ID:-}" ]; then
      id_path="${VIDREG_CORE_ID%%,*}"
      id_prov=""
      case ",${VIDREG_CORE_ID}," in
        *,prov=*) id_prov="${VIDREG_CORE_ID#*prov=}"; id_prov="${id_prov%%,*}" ;;
      esac
      echo "NOTE core-id inject path='$id_path' prov='${id_prov:-none}'"
      if [ "$pair" = "spi" ]; then
        if [ "$id_path" = "ddr" ]; then
          echo "FAIL core-id RED_SPI_DAEMON_DDR_CORE (running PLXC CAP_DDR with SPI daemon — mixed black-screen class)"
          rc=1
        else
          echo "OK   core-id path=$id_path compatible with SPI pair"
          # SPI daily has no ddr_frame_store PLXC; path=absent stays UNVERIFIED.
          # path=spi (future SPI stamp) or path=ddr would be fabric-proven.
          if [ "$id_path" = "spi" ] || [ "$id_path" = "ddr" ]; then
            gate_core_identity=VERIFIED_PLXC
          fi
        fi
      elif [ "$pair" = "ddr" ]; then
        if [ "$id_path" = "spi" ]; then
          echo "FAIL core-id RED_DDR_DAEMON_NON_DDR_CORE (SPI stamp with DDR daemon)"
          rc=1
        elif [ "$id_path" = "ddr" ]; then
          echo "OK   core-id path=ddr compatible with DDR pair"
          gate_core_identity=VERIFIED_PLXC
        elif [ "$id_path" = "absent" ]; then
          # c5382bee pre-identity: allow until first PLXC-bearing RBF is daily.
          if [ "${VIDREG_REQUIRE_CORE_ID:-0}" = "1" ]; then
            echo "FAIL core-id absent but VIDREG_REQUIRE_CORE_ID=1 (identity RBF required)"
            rc=1
          else
            echo "OK   core-id absent allowed for pre-identity DDR core (set VIDREG_REQUIRE_CORE_ID=1 after first PLXC RBF)"
          fi
          gate_core_identity=UNVERIFIED
        else
          echo "FAIL core-id path='$id_path' invalid (want absent|ddr|spi)"
          rc=1
        fi
      fi
    elif [ "${VIDREG_REQUIRE_CORE_ID:-0}" = "1" ]; then
      echo "FAIL core-id missing inject (VIDREG_REQUIRE_CORE_ID=1)"
      rc=1
      gate_core_identity=UNVERIFIED
    else
      echo "NOTE core-id not injected (VIDREG_CORE_ID unset) — on-disk pair only; running-core identity UNVERIFIED"
      gate_core_identity=UNVERIFIED
    fi
    echo "GATE_CORE_IDENTITY=$gate_core_identity"
    if [ "$gate_core_identity" = UNVERIFIED ]; then
      echo "NOTE GATE_CORE_IDENTITY=UNVERIFIED — pair/liveness may PASS; fabric hash not silicon-proven (no PLXC). NOT silicon proof of bitstream content hash."
    elif [ "$gate_core_identity" = VERIFIED_PLXC ]; then
      echo "OK   GATE_CORE_IDENTITY=VERIFIED_PLXC"
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
  if [ -n "$got_disk" ] && [ -n "$live" ] && [ "$got_disk" != "$live" ]; then
    echo "FAIL daemon-disk/live mismatch disk='$got_disk' live='$live'"
    echo "     hint: cp over a RUNNING binary fails ETXTBSY and leaves the old"
    echo "     image executing — stop first, then verify /proc/PID/exe (not disk alone)"
    rc=1
  fi

  if [ "$rc" -eq 0 ] && [ "$live_ok" -eq 1 ]; then
    echo "OK   known-good pair=$pair"
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
