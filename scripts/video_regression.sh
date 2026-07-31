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
# RUNNING CORE (verify must not pass on a mixed SPI-core + DDR-daemon pair):
#   /tmp/CORENAME and /tmp/RBFNAME are vacuous (always "Plex"). On-disk RBF md5
#   is NOT the fabric. Authority is:
#     1) /media/fat/misterplex/.running_core_claim written only after a verified
#        load_core (RBFNAME mtime advanced), valid iff claim.rbfname_mtime matches
#        live /tmp/RBFNAME mtime;
#     2) (core,daemon) pair table — SPI and DDR pins must not mix;
#     3) future PLXC mailbox (docs/core-running-bitstream-identity.md).
#   Missing/stale claim or unknown pair → HARD FAIL (never soft-skip/PASS).
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
# 50f4eb92  CURRENT — clamps DECODE to the 320x240 RGB565 frame store instead of
#           silently skipping FPGA present (pfps was 0.00 at 624x480), opt-in
#           PRESENT_SCALE_TO_STORE, and supervisor backoff reset after a healthy
#           run. Parent-verified on hardware: 240p unchanged (pfps 23.2, av-lock,
#           3 distinct HDMI md5s); 624x480 clamps and presents (pfps 23.6).
HYBRID_DAEMON_MD5=50f4eb925de10e29172999a565c87684
PREV_HYBRID_DAEMON_MD5=3e2cbb9881b2f54b0e4cb60238655fa7

# DDR product pair (parent silicon 2026-07-31):
#   core prefix c5382bee + daemon edc3a46b — 240p AND native 480p on viewed pixels.
# Full digests registered when available; md5_match accepts unique prefix ≥8 hex.
# NEVER weaken pins to skip — demote previous CURRENT into PREV_* on advance.
DDR_CORE_MD5_PREFIX=c5382bee
# CURRENT DDR companion (parent-verified with c5382bee).
DDR_DAEMON_MD5=edc3a46b
# PRIOR DDR companion kept as accepted rollback (was CURRENT before edc3a46b).
PREV_DDR_DAEMON_MD5=e9f79de2
# Back-compat alias used in older messages / pair helpers.
DDR_DAEMON_MD5_PREFIX="$DDR_DAEMON_MD5"

# Claim file written by plexctl load_core / deploy after RBFNAME mtime advances.
RUNNING_CORE_CLAIM="${RUNNING_CORE_CLAIM:-/media/fat/misterplex/.running_core_claim}"
V2_CORE_PATH=/media/fat/_Utility/Plex_v2.rbf
DEV_CORE_PATH=/media/fat/_Utility/Plex.rbf

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

spi_daemon_md5_accepted() {
  case "$1" in
    "$BASE_DAEMON_MD5"|"$HYBRID_DAEMON_MD5"|"$PREV_HYBRID_DAEMON_MD5") return 0 ;;
    *) return 1 ;;
  esac
}

ddr_daemon_md5_accepted() {
  # CURRENT + PREV rollback pins (prefix or full via md5_match).
  if [ -n "${DDR_DAEMON_MD5:-}" ] && md5_match "$DDR_DAEMON_MD5" "$1"; then return 0; fi
  if [ -n "${PREV_DDR_DAEMON_MD5:-}" ] && md5_match "$PREV_DDR_DAEMON_MD5" "$1"; then return 0; fi
  return 1
}

daemon_md5_accepted() {
  spi_daemon_md5_accepted "$1" || ddr_daemon_md5_accepted "$1"
}

# md5_match PIN GOT — full equality, or PIN is unique prefix (≥8 hex) of GOT.
md5_match() {
  local pin="$1" got="$2"
  [ -n "$pin" ] && [ -n "$got" ] || return 1
  if [ "$pin" = "$got" ]; then return 0; fi
  local plen=${#pin}
  if [ "$plen" -ge 8 ] && [ "$plen" -lt 32 ]; then
    case "$got" in
      "$pin"*) return 0 ;;
    esac
  fi
  return 1
}

# Empty string is NO-DATA / probe error — never a hash MISMATCH.
# Returns: 0=OK match, 1=FAIL wrong hash, 4=NO-DATA empty.
classify_obs_hash() {
  local label="$1" got="$2"
  shift 2
  if [ -z "$got" ]; then
    echo "NO-DATA $label got='' (empty — not a mismatch; SSH drop or remote produced no hash)"
    return 4
  fi
  local w
  for w in "$@"; do
    [ -n "$w" ] || continue
    if [ "$got" = "$w" ] || md5_match "$w" "$got"; then
      echo "OK   $label $got"
      return 0
    fi
  done
  echo "FAIL $label got='$got' want=$*"
  return 1
}

# Map a core md5 (full or prefix) to family: spi|ddr|unknown
core_family() {
  local c="$1"
  if md5_match "$BASE_CORE_MD5" "$c" || [ "$c" = "$BASE_CORE_MD5" ]; then
    echo spi; return 0
  fi
  if md5_match "$DDR_CORE_MD5_PREFIX" "$c"; then
    echo ddr; return 0
  fi
  echo unknown
}

daemon_family() {
  local d="$1"
  if spi_daemon_md5_accepted "$d"; then
    echo spi; return 0
  fi
  if ddr_daemon_md5_accepted "$d"; then
    echo ddr; return 0
  fi
  echo unknown
}

# Pair coherent iff both families known and equal.
pair_coherent() {
  local core_md5="$1" daemon_md5="$2"
  local cf df
  cf=$(core_family "$core_md5")
  df=$(daemon_family "$daemon_md5")
  echo "PAIR core=$core_md5 family=$cf daemon=$daemon_md5 family=$df"
  if [ "$cf" = unknown ] || [ "$df" = unknown ]; then
    return 2
  fi
  if [ "$cf" != "$df" ]; then
    return 1
  fi
  return 0
}

# Remote observation of core identity surfaces + running-core claim.
# Prints machine-readable lines (never treat CORENAME/RBFNAME strings as id):
#   CORENAME=...
#   RBFNAME=...
#   RBFNAME_MTIME=<epoch|empty>
#   DISK_V2_MD5=...
#   DISK_DEV_MD5=...
#   CLAIM_PRESENT=0|1
#   CLAIM_MD5=...
#   CLAIM_PATH=...
#   CLAIM_RBFNAME_MTIME=...
#   CLAIM_SOURCE=...
#   FPGA_MGR_STATE=...   (empty if sysfs absent)
#   PLXK_WORD=...        (devmem if present; empty otherwise)
#   PLXS_WORD=...
#   PLXD_WORD=...
#   PLXC_WORD=...        (future build-id mailbox; empty until RTL lands)
observe_core_once() {
  local claim_path="${RUNNING_CORE_CLAIM}"
  sshm "CLAIM_PATH=$(printf '%q' "$claim_path"); V2=$(printf '%q' "$V2_CORE_PATH"); DEV=$(printf '%q' "$DEV_CORE_PATH"); $(cat <<'REMOTE'
set +e
echo "CORENAME=$(cat /tmp/CORENAME 2>/dev/null | tr -d '\r' | head -n1)"
echo "RBFNAME=$(cat /tmp/RBFNAME 2>/dev/null | tr -d '\r' | head -n1)"
mt=""
if [ -e /tmp/RBFNAME ]; then
  mt=$(stat -c %Y /tmp/RBFNAME 2>/dev/null || echo "")
fi
echo "RBFNAME_MTIME=${mt}"
v2=""
dev=""
if [ -f "$V2" ]; then v2=$(md5sum "$V2" 2>/dev/null | awk '{print $1}'); fi
if [ -f "$DEV" ]; then dev=$(md5sum "$DEV" 2>/dev/null | awk '{print $1}'); fi
echo "DISK_V2_MD5=${v2}"
echo "DISK_DEV_MD5=${dev}"
cp=0
cmd5=""; cpath=""; cmt=""; csrc=""
if [ -f "$CLAIM_PATH" ]; then
  cp=1
  # claim is KEY=VAL lines
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      md5=*) cmd5=${line#md5=} ;;
      path=*) cpath=${line#path=} ;;
      rbfname_mtime=*) cmt=${line#rbfname_mtime=} ;;
      source=*) csrc=${line#source=} ;;
    esac
  done <"$CLAIM_PATH"
fi
echo "CLAIM_PRESENT=$cp"
echo "CLAIM_MD5=${cmd5}"
echo "CLAIM_PATH_FIELD=${cpath}"
echo "CLAIM_RBFNAME_MTIME=${cmt}"
echo "CLAIM_SOURCE=${csrc}"
fmgr=""
for s in /sys/class/fpga_manager/*/state; do
  if [ -r "$s" ]; then fmgr=$(cat "$s" 2>/dev/null | tr -d '\r'); break; fi
done
echo "FPGA_MGR_STATE=${fmgr}"
# Optional mailbox peeks (family signals / future PLXC). Never sole identity.
peek() {
  local addr="$1"
  if [ -x /usr/sbin/devmem ]; then
    /usr/sbin/devmem "$addr" 32 2>/dev/null | tr -d '\r'
  else
    echo ""
  fi
}
# Product doorbell control page (0x300FF000 family).
echo "PLXK_WORD=$(peek 0x300FF000)"
echo "PLXS_WORD=$(peek 0x300FF100)"
echo "PLXD_WORD=$(peek 0x300FF128)"
echo "PLXC_WORD=$(peek 0x300FF130)"
REMOTE
)"
}

# Resolve running core from observe_core_once output.
# Prints: RUNNING_CORE_MD5=... RUNNING_CORE_PATH=... RUNNING_CORE_VIA=claim|fail
# Returns 0 on resolved, 1 on unknown (caller must FAIL hard).
resolve_running_core() {
  local obs="$1"
  local cn rn mt v2 dev cp cmd5 cpath cmt csrc plxc
  cn=$(printf '%s\n' "$obs" | sed -n 's/^CORENAME=//p' | head -1)
  rn=$(printf '%s\n' "$obs" | sed -n 's/^RBFNAME=//p' | head -1)
  mt=$(printf '%s\n' "$obs" | sed -n 's/^RBFNAME_MTIME=//p' | head -1)
  v2=$(printf '%s\n' "$obs" | sed -n 's/^DISK_V2_MD5=//p' | head -1)
  dev=$(printf '%s\n' "$obs" | sed -n 's/^DISK_DEV_MD5=//p' | head -1)
  cp=$(printf '%s\n' "$obs" | sed -n 's/^CLAIM_PRESENT=//p' | head -1)
  cmd5=$(printf '%s\n' "$obs" | sed -n 's/^CLAIM_MD5=//p' | head -1)
  cpath=$(printf '%s\n' "$obs" | sed -n 's/^CLAIM_PATH_FIELD=//p' | head -1)
  cmt=$(printf '%s\n' "$obs" | sed -n 's/^CLAIM_RBFNAME_MTIME=//p' | head -1)
  csrc=$(printf '%s\n' "$obs" | sed -n 's/^CLAIM_SOURCE=//p' | head -1)
  plxc=$(printf '%s\n' "$obs" | sed -n 's/^PLXC_WORD=//p' | head -1)

  echo "CORE_NAME_STR='${cn}' (vacuous — not identity)"
  echo "RBF_NAME_STR='${rn}' (vacuous — not identity)"
  echo "RBFNAME_MTIME='${mt}'"
  echo "DISK_V2_MD5='${v2}' DISK_DEV_MD5='${dev}'"
  echo "CLAIM present=$cp md5='${cmd5}' path='${cpath}' mtime='${cmt}' source='${csrc}'"
  echo "PLXC_WORD='${plxc}' (empty until RTL; not yet authoritative)"

  # Future: PLXC magic 0x504C5843 ("PLXC") low 32-bits LE → build_id in high half.
  # Until present, claim file is mandatory.

  if [ "${cp:-0}" != "1" ] || [ -z "$cmd5" ] || [ -z "$cmt" ]; then
    echo "RUNNING_CORE_MD5="
    echo "RUNNING_CORE_PATH="
    echo "RUNNING_CORE_VIA=fail_no_claim"
    echo "FAIL running-core: no verified load claim at $RUNNING_CORE_CLAIM"
    echo "     CORENAME/RBFNAME strings cannot identify the fabric bitstream."
    echo "     Reload via plexctl/deploy (writes claim after RBFNAME mtime advances)."
    return 1
  fi
  if [ -z "$mt" ]; then
    echo "RUNNING_CORE_MD5="
    echo "RUNNING_CORE_PATH="
    echo "RUNNING_CORE_VIA=fail_no_rbfname_mtime"
    echo "FAIL running-core: /tmp/RBFNAME mtime unreadable — cannot validate claim"
    return 1
  fi
  if [ "$cmt" != "$mt" ]; then
    echo "RUNNING_CORE_MD5="
    echo "RUNNING_CORE_PATH="
    echo "RUNNING_CORE_VIA=fail_stale_claim"
    echo "FAIL running-core: claim stale claim_mtime=$cmt rbfname_mtime=$mt"
    echo "     A load happened without rewriting the claim (or claim is from another load)."
    return 1
  fi

  # Claim md5 must match the on-disk file it names (or known bundle paths).
  local disk=""
  if [ -n "$cpath" ]; then
    case "$cpath" in
      *Plex_v2.rbf*) disk="$v2" ;;
      *Plex.rbf*) disk="$dev" ;;
    esac
  fi
  if [ -z "$disk" ]; then
    # Fall back: claim md5 equals one of the disk digests.
    if [ -n "$v2" ] && md5_match "$cmd5" "$v2"; then disk="$v2"; cpath="${cpath:-$V2_CORE_PATH}"; fi
    if [ -z "$disk" ] && [ -n "$dev" ] && md5_match "$cmd5" "$dev"; then disk="$dev"; cpath="${cpath:-$DEV_CORE_PATH}"; fi
  fi
  if [ -n "$disk" ] && ! md5_match "$cmd5" "$disk"; then
    echo "RUNNING_CORE_MD5="
    echo "RUNNING_CORE_PATH="
    echo "RUNNING_CORE_VIA=fail_claim_disk_mismatch"
    echo "FAIL running-core: claim md5=$cmd5 != disk md5=$disk for path=$cpath"
    echo "     SD file changed after load claim — fabric may still be old bitstream."
    return 1
  fi

  echo "RUNNING_CORE_MD5=$cmd5"
  echo "RUNNING_CORE_PATH=${cpath}"
  echo "RUNNING_CORE_VIA=claim"

  # PLXC fabric identity (magic 0x504C5843) — not in shipping RTL yet.
  # Claim+mtime is interim only: always stamp UNVERIFIED unless PLXC proves it.
  local plxc_norm identity
  plxc_norm=$(printf '%s' "$plxc" | tr 'A-F' 'a-f' | tr -d 'x')
  case "$plxc_norm" in
    *504c5843*|*0x504c5843*) identity=VERIFIED_PLXC ;;
    *) identity=UNVERIFIED ;;
  esac
  echo "RUNNING_CORE_IDENTITY=$identity"
  if [ "$identity" = UNVERIFIED ]; then
    echo "NOTE running-core identity is claim+RBFNAME-mtime only — PLXC fabric register absent."
    echo "     GREEN here is NOT silicon proof of bitstream content hash."
  else
    echo "OK   running-core identity VERIFIED via PLXC mailbox"
  fi
  return 0
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
  echo "== verifying RUNNING core identity + baseline pair coherence =="
  local rc=0
  local core_obs resolve_out resolve_rc run_core run_path run_via
  local got_disk wait_out wait_rc disk live n note pids port conf
  local http_out http_rc pair_out pair_rc cf

  set +e
  core_obs=$(observe_core_once)
  set -e
  printf '%s\n' "$core_obs"

  set +e
  resolve_out=$(resolve_running_core "$core_obs")
  resolve_rc=$?
  set -e
  printf '%s\n' "$resolve_out"
  run_core=$(printf '%s\n' "$resolve_out" | sed -n 's/^RUNNING_CORE_MD5=//p' | tail -1)
  run_path=$(printf '%s\n' "$resolve_out" | sed -n 's/^RUNNING_CORE_PATH=//p' | tail -1)
  run_via=$(printf '%s\n' "$resolve_out" | sed -n 's/^RUNNING_CORE_VIA=//p' | tail -1)

  if [ "$resolve_rc" -ne 0 ] || [ -z "$run_core" ]; then
    echo "FAIL core-running unresolved via='${run_via}' (cannot soft-skip unknown fabric)"
    rc=1
  else
    echo "OK   core-running $run_core path='${run_path}' via=$run_via"
    # Accept any *registered* core pin (SPI baseline or DDR product). Pair
    # coherence (below) is what rejects SPI/DDR mixes. Unknown pin = FAIL.
    cf=$(core_family "$run_core")
    if [ "$cf" = unknown ]; then
      echo "FAIL core-running md5='$run_core' unregistered (not spi baseline, not ddr pin)"
      rc=1
    elif [ "$cf" = spi ]; then
      if ! md5_match "$BASE_CORE_MD5" "$run_core" && [ "$run_core" != "$BASE_CORE_MD5" ]; then
        echo "FAIL core-running md5='$run_core' not baseline pin '$BASE_CORE_MD5'"
        rc=1
      else
        echo "OK   core-pin family=spi $run_core"
      fi
    else
      echo "OK   core-pin family=$cf $run_core"
    fi
  fi

  # On-disk check is *additional* ETXTBSY signal only — empty is NO-DATA, not FAIL.
  set +e
  # No local pipeline: capture full md5sum line then strip first field in-shell.
  got_disk_raw=$(sshm "md5sum $BASE_DAEMON_BIN 2>/dev/null")
  ssh_rc=$?
  set -e
  got_disk=${got_disk_raw%% *}
  got_disk=${got_disk//$'\r'/}
  if [ "$ssh_rc" -ne 0 ] && [ -z "$got_disk" ]; then
    echo "NO-DATA daemon-disk (ssh rc=$ssh_rc empty — not a mismatch)"
    [ "$rc" -eq 0 ] && rc=4
  else
    set +e
    classify_obs_hash "daemon-disk" "$got_disk"       "$BASE_DAEMON_MD5" "$HYBRID_DAEMON_MD5" "$PREV_HYBRID_DAEMON_MD5"       "$DDR_DAEMON_MD5" "$PREV_DDR_DAEMON_MD5"
    step_rc=$?
    set -e
    if [ "$step_rc" -eq 4 ]; then
      [ "$rc" -eq 0 ] && rc=4
    elif [ "$step_rc" -ne 0 ]; then
      rc=1
    fi
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
    echo "FAIL daemon-live md5='$live' not in accepted pins pid='$pids'"
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
  elif [ -z "$got_disk" ] || [ -z "$live" ]; then
    echo "NOTE daemon-disk/live ETXTBSY check skipped (NO-DATA on one side)"
  fi

  # PAIR COHERENCE — the mixed-state killer (SPI core + DDR daemon etc.).
  if [ -n "$run_core" ] && [ -n "$live" ]; then
    set +e
    pair_out=$(pair_coherent "$run_core" "$live")
    pair_rc=$?
    set -e
    printf '%s\n' "$pair_out"
    if [ "$pair_rc" -eq 0 ]; then
      echo "OK   pair-coherent core=$run_core daemon=$live"
    elif [ "$pair_rc" -eq 2 ]; then
      echo "FAIL pair-unknown core=$run_core daemon=$live (unregistered pin — not a pass)"
      rc=1
    else
      echo "FAIL pair-mismatch core=$run_core daemon=$live (SPI/DDR mix — black/green screen class)"
      echo "     non-visual HTTP/liveness is NOT sufficient; refuse mixed pair"
      rc=1
    fi
  else
    echo "FAIL pair-coherent skipped — running core or live daemon unresolved"
    rc=1
  fi

  # Loud identity stamp — claim path is interim; do not over-read GREEN.
  ident=$(printf '%s\n' "$resolve_out" | sed -n 's/^RUNNING_CORE_IDENTITY=//p' | tail -1)
  ident=${ident:-UNKNOWN}
  echo "GATE_CORE_IDENTITY=$ident"
  if [ "$ident" = UNVERIFIED ]; then
    echo "NOTE GATE_CORE_IDENTITY=UNVERIFIED — pair/liveness may PASS; fabric hash not silicon-proven (no PLXC)."
  elif [ "$ident" = VERIFIED_PLXC ]; then
    echo "OK   GATE_CORE_IDENTITY=VERIFIED_PLXC"
  elif [ -n "$run_core" ]; then
    echo "NOTE GATE_CORE_IDENTITY=$ident"
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

  echo "== loading core $core (claim after RBFNAME mtime) =="
  # Prefer plexctl load_core if present (writes running-core claim). Fallback:
  # MiSTer_cmd + inline claim writer with the same mtime rule.
  sshm "core=$(printf '%q' "$core"); claim=$(printf '%q' "$RUNNING_CORE_CLAIM"); $(cat <<'REMOTE'
set +e
if [ -x /media/fat/misterplex/bin/plexctl.sh ]; then
  # plexctl may be a multi-command script; call load path if exported — else raw.
  :
fi
before=$(stat -c %Y /tmp/RBFNAME 2>/dev/null || echo 0)
printf '%s\n' "load_core $core" > /dev/MiSTer_cmd
i=0
after=$before
while [ "$i" -lt 40 ]; do
  sleep 0.5
  after=$(stat -c %Y /tmp/RBFNAME 2>/dev/null || echo 0)
  if [ "$after" != "$before" ]; then
    break
  fi
  i=$((i + 1))
done
if [ "$after" = "$before" ]; then
  echo "FAIL CORE_LOAD_UNCONFIRMED $core (RBFNAME mtime did not advance)"
  exit 4
fi
md=$(md5sum "$core" 2>/dev/null | awk '{print $1}')
if [ -z "$md" ]; then
  echo "FAIL CORE_CLAIM_NO_MD5 $core"
  exit 4
fi
mkdir -p "$(dirname "$claim")"
{
  echo "version=1"
  echo "md5=$md"
  echo "path=$core"
  echo "rbfname_mtime=$after"
  echo "source=video_regression"
} >"$claim"
echo "CORE_LOADED $core md5=$md rbfname_mtime=$after claim=$claim"
sleep 3
REMOTE
)"

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
