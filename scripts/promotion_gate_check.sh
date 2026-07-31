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
# shellcheck source=boot_hook_policy.sh
source "$ROOT/scripts/boot_hook_policy.sh"

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

# Join remote script fragments. CRITICAL: $(...) strips trailing newlines, so
# naive remote+="$(part1)$(part2)" glues the next line onto the previous echo
# (parent 2026-07-31: V2_MD5=<md5>set +e). Always rejoin with an explicit \n.
gate_join_remote_parts() {
  local out="" part
  for part in "$@"; do
    # Strip a single trailing newline cluster then force exactly one separator.
    part=${part%$'\n'}
    if [ -z "$out" ]; then
      out="$part"
    else
      out="${out}"$'\n'"${part}"
    fi
  done
  # Final trailing newline so the remote script ends cleanly.
  printf '%s\n' "$out"
}

# Parse KEY=value from probe blob; reject values that are not pure shape.
# md5 fields: exactly 32 lowercase hex, or MISSING, or empty.
# Never "trim to make pass" — malformed capture is FAIL (parent: almost-right md5).
gate_field() {
  local blob="$1" key="$2"
  printf '%s\n' "$blob" | sed -n "s/^${key}=//p" | head -1
}

gate_assert_md5_shape() {
  local name="$1" val="$2"
  # Reject any whitespace / shell residue immediately (the set +e glue class).
  case "$val" in
    *[[:space:]]*|*+*|*\;*|*'set '*|*'$'*)
      echo "FAIL $name shape got='$val' (probe capture contaminated — not pure md5)"
      return 1
      ;;
  esac
  if [ -z "$val" ]; then
    return 0
  fi
  if [ "$val" = "MISSING" ]; then
    return 0
  fi
  if printf '%s' "$val" | grep -Eq '^[0-9a-f]{32}$'; then
    return 0
  fi
  # prefix8 alone is not accepted for disk core pins in verify-live
  echo "FAIL $name shape got='$val' (want exactly 32 hex chars or MISSING; len=${#val})"
  return 1
}

# Remote probe: product core, v2 core, live daemon via /proc/exe (not cmdline).
remote_live_blob() {
  if [ -n "${PROMOTE_GATE_BLOB:-}" ]; then
    cat "$PROMOTE_GATE_BLOB"
    return 0
  fi
  local head live remote
  head=$(cat <<REMOTE
PRODUCT=$(printf '%q' "$PRODUCT_CORE_PATH")
V2=$(printf '%q' "$V2_CORE_PATH")
set +e
prod_md5=""; v2_md5=""
if [ ! -f "\$PRODUCT" ]; then prod_md5=MISSING; else prod_md5=\$(md5sum "\$PRODUCT" | awk '{print \$1}'); fi
if [ ! -f "\$V2" ]; then v2_md5=MISSING; else v2_md5=\$(md5sum "\$V2" | awk '{print \$1}'); fi
echo "PRODUCT_CORE=\$PRODUCT"
echo "PRODUCT_MD5=\$prod_md5"
echo "V2_CORE=\$V2"
echo "V2_MD5=\$v2_md5"
REMOTE
)
  live=$(pair_remote_live_daemon_snippet)
  remote=$(gate_join_remote_parts "$head" "$live")
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

  prod=$(gate_field "$blob" PRODUCT_MD5)
  v2=$(gate_field "$blob" V2_MD5)
  n=$(gate_field "$blob" N_DAEMON)
  live=$(gate_field "$blob" LIVE_MD5)
  conf=$(gate_field "$blob" LIVE_CONF)
  root=$(gate_field "$blob" LIVE_ROOT)

  # Shape gates FIRST — contaminated capture must never reach md5 equality.
  for _pair in "product-core:$prod" "v2-rollback-core:$v2" "live-exe-md5:$live"; do
    _name="${_pair%%:*}"
    _val="${_pair#*:}"
    set +e
    gate_assert_md5_shape "$_name" "$_val"
    _src=$?
    set -e
    if [ "$_src" -ne 0 ]; then
      rc=3
    fi
  done
  # n_daemon must be a small integer if present
  if [ -n "$n" ] && ! printf '%s' "$n" | grep -Eq '^[0-9]+$'; then
    echo "FAIL n_daemon shape got='$n' (want digits only)"
    rc=3
  fi

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

  # Boot hook must match live pair root (parent cold-boot defect 2026-07-31).
  if [ "${PROMOTE_SKIP_BOOT_HOOK:-0}" != "1" ]; then
    hook_body=""
    if [ -n "${PROMOTE_HOOK_BLOB:-}" ] && [ -f "${PROMOTE_HOOK_BLOB}" ]; then
      hook_body=$(cat "$PROMOTE_HOOK_BLOB")
    elif [ -n "${PROMOTE_GATE_BLOB:-}" ]; then
      # optional HOOK_BODY=... multiline not in blob; allow PROMOTE_HOOK_BODY env
      hook_body="${PROMOTE_HOOK_BODY:-}"
    fi
    if [ -z "$hook_body" ] && [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
      set +e
      hook_body=$(run_ssh "if [ -f /media/fat/linux/_user-startup.sh ]; then cat /media/fat/linux/_user-startup.sh; else echo MISSING; fi")
      hrc=$?
      set -e
      if [ "$hrc" -eq 5 ]; then echo "true rc=5"; return 5; fi
    fi
    expect_root="${PROMOTE_BOOT_ROOT:-$BOOT_HOOK_DEFAULT_ROOT}"
    if [ -n "$root" ]; then expect_root="$root"; fi
    if [ -z "$hook_body" ] || [ "$hook_body" = "MISSING" ]; then
      # Unit inject path: PROMOTE_GATE_BLOB without PROMOTE_HOOK_* → NOTE only.
      # Live device (no gate blob): default REQUIRE=1 fails closed.
      if [ -n "${PROMOTE_GATE_BLOB:-}" ] && [ -z "${PROMOTE_HOOK_BLOB:-}" ] && [ -z "${PROMOTE_HOOK_BODY:-}" ] \
         && [ "${PROMOTE_REQUIRE_BOOT_HOOK:-0}" != "1" ]; then
        echo "NOTE boot-hook not in gate blob — set PROMOTE_HOOK_BLOB for cold-boot gate"
      elif [ "${PROMOTE_REQUIRE_BOOT_HOOK:-1}" = "1" ]; then
        echo "FAIL boot-hook missing or not injected (cold-boot path unproven)"
        rc=3
      else
        echo "NOTE boot-hook not checked"
      fi
    else
      set +e
      boot_hook_check_body "$hook_body" "$expect_root"
      hrc=$?
      set -e
      if [ "$hrc" -ne 0 ]; then
        echo "FAIL boot-hook vs pair root expect=$expect_root"
        rc=3
      else
        echo "OK boot-hook matches root=$expect_root"
        if [ -n "$root" ] && [ "$root" != "$expect_root" ]; then
          echo "FAIL live-root $root != boot expect $expect_root"
          rc=3
        fi
      fi
    fi
  fi

  # Visual is HARD for claim success and ALWAYS RUNS (aggregate, never fail-fast-skip).
  # Parent 2026-07-31: skipping visual because an earlier check failed loses the only
  # evidence that can confirm the running bitstream (CORENAME is always "Plex").
  # Prefer PROMOTE_VISUAL_CMD; else idle PNG; else PROMOTE_MOTION_CMD / capture dir.
  # motion rc=77 UNSCORED is HARD FAIL (never soft).
  vrc=8
  prior_rc=$rc
  motion_cmd="${PROMOTE_MOTION_CMD:-}"
  if [ -z "$motion_cmd" ] && [ -n "${PROMOTE_MOTION_CAPTURE_DIR:-}" ]; then
    motion_cmd="python3 $(printf '%q' "$ROOT/tools/hdmi_motion_instrument.py") $(printf '%q' "$PROMOTE_MOTION_CAPTURE_DIR")"
  fi
  # Idle visual owns HDMI capture (warm-up baked into hdmi_capture_idle.sh).
  # Parent 2026-07-31: recipe with -frames:v 1 alone → false RED (uniform 7,7,7).
  # Auto-capture when /dev/video0 exists so verify-live needs no human warm-up lore.
  hdmi_dev="${HDMI_DEV:-/dev/video0}"
  auto_idle=0
  if [ "${PROMOTE_AUTO_CAPTURE:-1}" = "1" ] && [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
    # Never auto-open the grabber during injected unit blobs.
    if [ -e "$hdmi_dev" ]; then auto_idle=1; fi
  fi
  if [ -n "${PROMOTE_VISUAL_CMD:-}" ]; then
    set +e
    # shellcheck disable=SC2086
    eval $PROMOTE_VISUAL_CMD
    vrc=$?
    set -e
    echo "visual_hook true rc=$vrc"
  elif [ -n "${PAIR_IDLE_PNG:-}" ] || [ -n "${PAIR_CAPTURE_CMD:-}" ]        || [ "${PROMOTE_VISUAL_IDLE:-0}" = "1" ] || [ "$auto_idle" = "1" ]; then
    if [ "$auto_idle" = "1" ] && [ -z "${PAIR_IDLE_PNG:-}" ] && [ -z "${PAIR_CAPTURE_CMD:-}" ]; then
      echo "visual_idle: auto-capture via scripts/hdmi_capture_idle.sh (warm-up baked in)"
    fi
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
    echo "  and no HDMI device at ${hdmi_dev} for auto-capture."
    echo "  Telemetry-only is insufficient (green screen still returns /resources 200)."
    echo "  Blessed idle: scripts/hdmi_capture_idle.sh   # NEVER ffmpeg -frames:v 1 alone"
    echo "  Playback:     PROMOTE_MOTION_CAPTURE_DIR=/path/to/pngs"
    vrc=8
  fi
  if [ "$vrc" -eq 0 ]; then
    echo "OK visual-or-motion-gate"
    if [ "$prior_rc" -ne 0 ]; then
      echo "NOTE visual OK but earlier gate already failed rc=$prior_rc (aggregate keeps earlier rc)"
    fi
  else
    echo "FAIL visual/motion gate rc=$vrc (hard — cannot claim pair success)"
    if [ "$prior_rc" -ne 0 ]; then
      echo "NOTE visual also failed; keeping earlier rc=$prior_rc (not overwriting with visual-only 8)"
      # keep prior_rc (telemetry/boot more specific); visual failure still reported
      rc=$prior_rc
    else
      rc=8
    fi
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
