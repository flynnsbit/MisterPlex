#!/usr/bin/env bash
# promotion_gate_check.sh — executable promotion / health gates (host-side).
#
# Verifies observations already collected (or via SSH when PROMOTE_EXECUTE=1).
# Never treats soft-skip (77) as PASS. Prints true rc=N on the last line of each
# high-level command.
#
# Gates (all must pass for PROMOTE_GATES_OK):
#   1) core disk md5 == EXPECT_CORE_MD5 (product slot Plex.rbf, never Plex_v2)
#   2) V2 rollback core still at known pin (Plex_v2.rbf) — one-step restore
#   3) live daemon md5 via readlink -f /proc/PID/exe (+ md5sum of that path)
#      NEVER disk-only (ETXTBSY leaves stale live image)
#   4) n_daemon == 1
#   5) live --conf path from /proc/PID/cmdline (not a hardcoded misterplex.conf)
#   6) HTTP GET :PORT/resources → 200
#   7) optional motion hook (PROMOTE_MOTION_CMD) — counter-verified TREK24 etc.
#      If unset: MOTION_SKIP rc=77 printed, NOT counted as gate pass.
#
# Usage:
#   scripts/promotion_gate_check.sh policy-local <rbf_path> <daemon_path>
#   scripts/promotion_gate_check.sh verify-live   # needs SSH unless inject vars
#
# Inject for unit tests (no device):
#   PROMOTE_SSH / PROMOTE_HTTP / PROMOTE_GATE_BLOB

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=rbf_ship_policy.sh
source "$ROOT/scripts/rbf_ship_policy.sh"
# shellcheck source=pair_ship_policy.sh
source "$ROOT/scripts/pair_ship_policy.sh"
# shellcheck source=pair_live_probe.inc.sh
source "$ROOT/scripts/pair_live_probe.inc.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
PORT="${MISTERPLEX_PORT:-3005}"

EXPECT_CORE_MD5="${PROMOTE_EXPECT_CORE_MD5:-$RBF_PIN_DDR_CANDIDATE_FULL}"
EXPECT_DAEMON_MD5="${PROMOTE_EXPECT_DAEMON_MD5:-$DAEMON_PIN_DDR_CANDIDATE_FULL}"
EXPECT_V2_CORE_MD5="${PROMOTE_EXPECT_V2_CORE_MD5:-$RBF_PIN_V2_DAILY_FULL}"
PRODUCT_CORE_PATH="${PROMOTE_PRODUCT_CORE:-$DEVICE_CORE_PRODUCT}"
V2_CORE_PATH="${PROMOTE_V2_CORE:-$DEVICE_CORE_V2_DAILY}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*" >&2; }

run_ssh() {
  local remote="$1" out rc
  set +e
  if [ -n "${PROMOTE_SSH:-}" ]; then
    # shellcheck disable=SC2086
    out=$($PROMOTE_SSH "$remote")
    rc=$?
  else
    out=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      "$USER@$HOST" "$remote")
    rc=$?
  fi
  set -e
  printf '%s' "$out"
  return "$rc"
}

http_code() {
  local url="$1" code rc
  set +e
  if [ -n "${PROMOTE_HTTP:-}" ]; then
    # shellcheck disable=SC2086
    code=$($PROMOTE_HTTP "$url")
    rc=$?
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 4 "$url" 2>/dev/null)
    rc=$?
  fi
  set -e
  printf '%s' "${code:-}"
  return "$rc"
}

# --- policy-local: host artifacts before any device touch --------------------
policy_local() {
  local rbf="${1:-}" daemon="${2:-}"
  local rc=0 out md dmd

  if [ -z "$rbf" ] || [ ! -f "$rbf" ]; then
    echo "FAIL policy-local missing RBF path '$rbf'"
    echo "true rc=2"
    return 2
  fi
  if [ -z "$daemon" ] || [ ! -f "$daemon" ]; then
    echo "FAIL policy-local missing daemon path '$daemon'"
    echo "true rc=2"
    return 2
  fi

  set +e
  out=$(rbf_policy_assert_product_core_path "$PRODUCT_CORE_PATH")
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then echo "true rc=$rc"; return "$rc"; fi

  md=$(md5sum "$rbf" | awk '{print $1}')
  echo "host_rbf_md5=$md path=$rbf"
  set +e
  out=$(rbf_policy_check_md5 "$md")
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then echo "true rc=$rc"; return "$rc"; fi

  if [ "$md" != "$EXPECT_CORE_MD5" ]; then
    echo "FAIL host RBF md5 $md != PROMOTE_EXPECT_CORE_MD5 $EXPECT_CORE_MD5"
    echo "true rc=3"
    return 3
  fi
  echo "OK host-core-pin $md"

  dmd=$(md5sum "$daemon" | awk '{print $1}')
  echo "host_daemon_md5=$dmd path=$daemon"
  if [ "$dmd" != "$EXPECT_DAEMON_MD5" ]; then
    echo "FAIL host daemon md5 $dmd != PROMOTE_EXPECT_DAEMON_MD5 $EXPECT_DAEMON_MD5"
    echo "true rc=3"
    return 3
  fi
  echo "OK host-daemon-pin $dmd"
  # Pair matrix: refuse SPI/DDR mixes and unknown combos before any device touch.
  # Unit tests with synthetic bytes set PROMOTE_PAIR_CHECK=0; production default is 1.
  if [ "${PROMOTE_PAIR_CHECK:-1}" = "1" ]; then
    set +e
    out=$(pair_policy_check "$md" "$dmd")
    rc=$?
    set -e
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
      echo "REFUSE host core+daemon are not a listed matched pair"
      echo "true rc=3"
      return 3
    fi
    echo "OK host-pair-compatibility"
  else
    echo "NOTE PROMOTE_PAIR_CHECK=0 — pair matrix not applied (test/explicit only)"
  fi
  echo "PROMOTE_POLICY_LOCAL_OK"
  echo "true rc=0"
  return 0
}

# Remote probe: product core, v2 core, live daemon via /proc/exe (not cmdline).
remote_live_blob() {
  if [ -n "${PROMOTE_GATE_BLOB:-}" ]; then
    cat "$PROMOTE_GATE_BLOB"
    return 0
  fi
  local remote
  remote="PRODUCT=$(printf '%q' "$PRODUCT_CORE_PATH"); V2=$(printf '%q' "$V2_CORE_PATH"); "
  remote+="$(cat <<'REMOTE'
set +e
prod_md5=""; v2_md5=""
if [ ! -f "$PRODUCT" ]; then prod_md5=MISSING; else prod_md5=$(md5sum "$PRODUCT" | awk '{print $1}'); fi
if [ ! -f "$V2" ]; then v2_md5=MISSING; else v2_md5=$(md5sum "$V2" | awk '{print $1}'); fi
echo "PRODUCT_CORE=$PRODUCT"
echo "PRODUCT_MD5=$prod_md5"
echo "V2_CORE=$V2"
echo "V2_MD5=$v2_md5"
REMOTE
)"
  remote+="$(pair_remote_live_daemon_snippet)"
  run_ssh "$remote"
}

verify_live() {
  local rc=0 blob prod v2 n live conf root code out

  log "verify-live product=$PRODUCT_CORE_PATH expect_core=$EXPECT_CORE_MD5 expect_daemon=$EXPECT_DAEMON_MD5"

  set +e
  blob=$(remote_live_blob)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "NETWORK/SSH live probe failed"
    echo "true rc=5"
    return 5
  fi
  printf '%s\n' "$blob" | sed 's/^/  [probe] /'

  prod=$(printf '%s\n' "$blob" | sed -n 's/^PRODUCT_MD5=//p' | head -1)
  v2=$(printf '%s\n' "$blob" | sed -n 's/^V2_MD5=//p' | head -1)
  n=$(printf '%s\n' "$blob" | sed -n 's/^N_DAEMON=//p' | head -1)
  live=$(printf '%s\n' "$blob" | sed -n 's/^LIVE_MD5=//p' | head -1)
  conf=$(printf '%s\n' "$blob" | sed -n 's/^LIVE_CONF=//p' | head -1)
  root=$(printf '%s\n' "$blob" | sed -n 's/^LIVE_ROOT=//p' | head -1)

  # product core
  if [ -z "$prod" ]; then
    echo "NO-DATA product-core md5 empty"
    rc=4
  elif [ "$prod" = "MISSING" ]; then
    echo "MISSING product core $PRODUCT_CORE_PATH"
    rc=2
  elif [ "$prod" != "$EXPECT_CORE_MD5" ]; then
    echo "FAIL product-core got=$prod want=$EXPECT_CORE_MD5"
    # also refuse if product pin is banned
    set +e
    out=$(rbf_policy_check_md5 "$prod")
    prc=$?
    set -e
    printf '%s\n' "$out"
    rc=3
  else
    set +e
    out=$(rbf_policy_check_md5 "$prod")
    prc=$?
    set -e
    printf '%s\n' "$out"
    if [ "$prc" -ne 0 ]; then rc=$prc; else echo "OK product-core $prod"; fi
  fi

  # V2 rollback slot must remain intact
  if [ -z "$v2" ]; then
    echo "NO-DATA v2-rollback-core md5 empty"
    [ "$rc" -eq 0 ] && rc=4
  elif [ "$v2" = "MISSING" ]; then
    echo "FAIL v2-rollback-core MISSING at $V2_CORE_PATH — refuse promote without rollback path"
    rc=2
  elif [ "$v2" != "$EXPECT_V2_CORE_MD5" ]; then
    echo "FAIL v2-rollback-core got=$v2 want=$EXPECT_V2_CORE_MD5 (do not promote if rollback pin drifted)"
    rc=3
  else
    echo "OK v2-rollback-core $v2"
  fi

  # n_daemon + live exe md5
  n=${n:-}
  if [ -z "$n" ]; then
    echo "NO-DATA n_daemon"
    [ "$rc" -eq 0 ] && rc=4
  elif [ "$n" != "1" ]; then
    echo "FAIL n_daemon=$n want=1"
    rc=9
  else
    echo "OK n_daemon=1"
  fi

  if [ -z "$live" ]; then
    echo "NO-DATA live /proc/PID/exe md5 (disk-only is NOT success)"
    [ "$rc" -eq 0 ] && rc=4
  elif pair_policy_md5_match "$live" "$EXPECT_DAEMON_MD5"; then
    echo "OK live-exe-md5 $live (from readlink -f /proc/PID/exe; want=$EXPECT_DAEMON_MD5)"
  else
    echo "FAIL live-exe-md5 got=$live want=$EXPECT_DAEMON_MD5"
    echo "     hint: verify via readlink -f /proc/PID/exe — never on-disk file alone (ETXTBSY)"
    rc=3
  fi

  if [ -z "$conf" ]; then
    echo "FAIL live --conf empty (must resolve conf from /proc/PID/cmdline, not assume misterplex/ vs _v2)"
    rc=9
  else
    echo "OK live-conf $conf (from cmdline)"
    # conf should live under live root when root known
    if [ -n "$root" ] && [ "$conf" != "$root/misterplex.conf" ]; then
      echo "NOTE conf $conf vs root $root/misterplex.conf — operator must confirm"
    fi
    # Conf keys are part of the DDR pair (FORCE_SCALE + SWS flags).
    if [ -n "${PROMOTE_CONF_BLOB:-}" ] || [ -n "${PROMOTE_CONF_PATH:-}" ]; then
      conf_src="${PROMOTE_CONF_BLOB:-$PROMOTE_CONF_PATH}"
      set +e
      pair_policy_check_conf "${PROMOTE_CONF_PROFILE:-ddr}" "$conf_src"
      crc=$?
      set -e
      if [ "$crc" -ne 0 ]; then
        echo "FAIL live-conf-profile"
        rc=3
      fi
    elif [ "${PROMOTE_REQUIRE_CONF_KEYS:-1}" = "1" ] && [ "${PROMOTE_CONF_PROFILE:-ddr}" = "ddr" ]; then
      echo "NOTE conf-keys not injected — parent must verify DDR_YUV_FORCE_SCALE=1 FFMPEG_SWS_FLAGS=fast_bilinear on device"
      echo "     (set PROMOTE_CONF_BLOB or PROMOTE_CONF_PATH for hard gate)"
    fi
  fi

  set +e
  code=$(http_code "http://${HOST}:${PORT}/resources")
  hrc=$?
  set -e
  if [ -z "$code" ]; then
    echo "NO-DATA http /resources"
    [ "$rc" -eq 0 ] && rc=4
  elif [ "$code" = "200" ]; then
    echo "OK http /resources code=200"
  else
    echo "FAIL http /resources code=$code hrc=$hrc"
    rc=9
  fi

  # Pair matrix on live observations (catches SPI core + DDR daemon green-screen).
  if [ -n "$prod" ] && [ "$prod" != "MISSING" ] && [ -n "$live" ]; then
    set +e
    out=$(pair_policy_check "$prod" "$live")
    prc=$?
    set -e
    printf '%s\n' "$out"
    if [ "$prc" -ne 0 ]; then
      echo "FAIL live pair-compatibility (mixed pair → solid green screen class)"
      rc=3
    else
      echo "OK live-pair-compatibility"
    fi
  fi

  # Visual is HARD for claim success. Parent 2026-07-31: telemetry passed on green screen.
  # Prefer PROMOTE_VISUAL_CMD; else idle PNG gate; else PROMOTE_MOTION_CMD / capture dir.
  # Default motion instrument: tools/hdmi_motion_instrument.py (w-instr).
  # CRITICAL: motion rc=77 UNSCORED is HARD FAIL here (parent: green_cast leaked as 77).
  # Never treat 77 as inconclusive-carry-on for promotion claim success.
  if [ "$rc" -eq 0 ]; then
    vrc=8
    motion_cmd="${PROMOTE_MOTION_CMD:-}"
    if [ -z "$motion_cmd" ] && [ -n "${PROMOTE_MOTION_CAPTURE_DIR:-}" ]; then
      motion_cmd="python3 $(printf '%q' "$ROOT/tools/hdmi_motion_instrument.py") $(printf '%q' "$PROMOTE_MOTION_CAPTURE_DIR")"
    fi
    if [ -n "${PROMOTE_VISUAL_CMD:-}" ]; then
      set +e
      # shellcheck disable=SC2086
      eval $PROMOTE_VISUAL_CMD
      vrc=$?
      set -e
      echo "visual_hook true rc=$vrc"
    elif [ -n "${PAIR_IDLE_PNG:-}" ] || [ -n "${PAIR_CAPTURE_CMD:-}" ] || [ "${PROMOTE_VISUAL_IDLE:-0}" = "1" ]; then
      set +e
      "$ROOT/scripts/pair_visual_gate.sh" idle
      vrc=$?
      set -e
      echo "visual_idle true rc=$vrc"
    elif [ -n "$motion_cmd" ]; then
      set +e
      # shellcheck disable=SC2086
      eval $motion_cmd
      vrc=$?
      set -e
      echo "motion_hook true rc=$vrc cmd=$motion_cmd"
      # Map instrument contract → promotion claim:
      #   0 MOTION_OK → pass
      #   1 FREEZE / 2 COLOR_FAIL → hard fail
      #   77 UNSCORED → HARD FAIL (never soft; green-cast leak class until w-instr lands rc=2)
      if [ "$vrc" -eq 77 ]; then
        echo "FAIL motion UNSCORED rc=77 is HARD FAIL for promotion (not inconclusive)"
        echo "     (parent: broken green burst once reported VERDICT=UNSCORED despite GREEN_CAST_FAIL)"
        vrc=8
      elif [ "$vrc" -ne 0 ]; then
        echo "FAIL motion instrument hard fail rc=$vrc (0=OK 1=FREEZE 2=COLOR_FAIL)"
        vrc=8
      fi
    else
      echo "VISUAL_REQUIRED: unset PROMOTE_VISUAL_CMD / PAIR_IDLE_PNG / PROMOTE_MOTION_CMD / PROMOTE_MOTION_CAPTURE_DIR"
      echo "  Telemetry-only is insufficient (green screen still returns /resources 200)."
      echo "  Playback: PROMOTE_MOTION_CAPTURE_DIR=/path/to/pngs  (tools/hdmi_motion_instrument.py)"
      echo "  Idle:     PAIR_IDLE_PNG=/path/idle.png            (pair_visual_gate.sh)"
      vrc=8
    fi
    if [ "$vrc" -eq 0 ]; then
      echo "OK visual-or-motion-gate"
    else
      # No soft-skip path for claim success. (PROMOTE_ALLOW_VISUAL_SOFT_SKIP removed.)
      echo "FAIL visual/motion gate rc=$vrc (hard — cannot claim pair success)"
      rc=8
    fi
  else
    echo "NOTE skip visual — prior gate already failed rc=$rc"
  fi

  if [ "$rc" -eq 0 ]; then
    echo "PROMOTE_GATES_OK"
  fi
  echo "true rc=$rc"
  return "$rc"
}

cmd="${1:-}"
case "$cmd" in
  policy-local)
    policy_local "${2:-}" "${3:-}"
    ;;
  verify-live)
    verify_live
    ;;
  *)
    echo "usage: $0 {policy-local <rbf> <daemon>|verify-live}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
