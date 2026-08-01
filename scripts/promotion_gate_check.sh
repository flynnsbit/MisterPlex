#!/usr/bin/env bash
# promotion_gate_check.sh - executable promotion / health gates (host-side).
#
# Verifies observations already collected (or via SSH when PROMOTE_EXECUTE=1).
# Never treats soft-skip (77) as PASS. Prints true rc=N on the last line of each
# high-level command.
#
# Gates (all must pass for PROMOTE_GATES_OK):
#   1) core disk md5 == EXPECT_CORE_MD5 (product slot Plex.rbf, never Plex_v2)
#   2) V2 rollback core still at known pin (Plex_v2.rbf) - one-step restore
#   3) live daemon md5 via readlink -f /proc/PID/exe (+ md5sum of that path)
#      NEVER disk-only (ETXTBSY leaves stale live image)
#   4) n_daemon == 1
#   5) live --conf path from /proc/PID/cmdline (not a hardcoded misterplex.conf)
#   6) HTTP GET :PORT/resources -> 200
#   7) optional motion hook (PROMOTE_MOTION_CMD) - counter-verified TREK24 etc.
#      If unset: MOTION_SKIP rc=77 printed, NOT counted as gate pass.
#
# Usage:
#   scripts/promotion_gate_check.sh policy-local <rbf_path> <daemon_path>
#   scripts/promotion_gate_check.sh verify-live   # needs SSH unless inject vars
#
# Inject for unit tests (no device):
#   PROMOTE_SSH / PROMOTE_HTTP / PROMOTE_GATE_BLOB

# Rule 0: quoted code / true rc= / measured artifacts only.
#
# RETRACTED as PASS criteria (never re-add):
#   clock=av-lock, av_drift_ms — CIRCULAR + BLIND to HDMI lip-sync.
#   2026-08-01 rd-review: av_drift_ms is stored inside the A/V hold loop vs leadMs
#   (media_player.cpp ~4122-4130) — controller deadband, not glass accuracy.
#   Always-negative band is a setpoint signature (AV_PRESENT_LEAD_MS), not error.
#   A/V is UNSCORED until grabber-side measure (w-avsync); grabber is video-only.
#   UNSCORED / rc=77 is never promote PASS. Do not gate on these fields.
#   Historical: ~117 ms HDMI offset bimodality was SESSION-LATCHED device defect;
#   still not a promote PASS criterion (superseded by A/V UNSCORED / P6).
#
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
  # Always end the blob with a newline. $(...) strips trailing NLs; without this
  # a later host-side append can glue the next token onto the last probe field.
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
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
    echo "NOTE PROMOTE_PAIR_CHECK=0 - pair matrix not applied (test/explicit only)"
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
# Never "trim to make pass" - malformed capture is FAIL (parent: almost-right md5).
gate_field() {
  local blob="$1" key="$2" line
  # CR-strip (Windows/SSH artifacts); take first matching line only.
  line=$(printf '%s\n' "$blob" | tr -d '\r' | sed -n "s/^${key}=//p" | head -1)
  printf '%s' "$line"
}

gate_assert_md5_shape() {
  local name="$1" val="$2"
  # Empty / MISSING ok (caller decides whether absence is hard fail).
  if [ -z "$val" ] || [ "$val" = "MISSING" ]; then
    return 0
  fi
  # Pure 32 lowercase hex only. NEVER trim trailing garbage to pass
  # (parent: tempting fix for V2_MD5=<32hex>set +e is to strip - forbidden).
  if printf '%s' "$val" | grep -Eq '^[0-9a-f]{32}$'; then
    return 0
  fi
  case "$val" in
    *set*|*+*|*[[:space:]]*|*\;*|*'$'*)
      echo "FAIL $name shape got='$val' (probe capture contaminated - not pure md5)"
      return 1
      ;;
  esac
  # prefix8 / wrong length - still fail closed
  echo "FAIL $name shape got='$val' (want exactly 32 hex chars or MISSING; len=${#val})"
  return 1
}

# Remote probe: product core, v2 core, live daemon via /proc/exe (not cmdline).
# STRUCTURAL FIX (parent V2_MD5=...81848set +e):
#   1) ONE remote script in a single heredoc - never $(frag1)$(frag2).
#   2) md5 lines use printf '%s\n' only - never echo "V2_MD5=$x" adjacent to set.
#   3) set +e is ONLY on its own line, BEFORE any md5 computation, never after.
#   4) gate_join_remote_parts remains for unit tests of the glue class only.
remote_live_blob() {
  if [ -n "${PROMOTE_GATE_BLOB:-}" ]; then
    cat "$PROMOTE_GATE_BLOB"
    return 0
  fi
  local remote
  # Unquoted heredoc only for host-side %q of paths; remote expansions stay \$/\%.
  # IMPORTANT: do not place `set +e` immediately after any MD5 printf/echo line.
  remote=$(cat <<REMOTE
PRODUCT=$(printf '%q' "$PRODUCT_CORE_PATH")
V2=$(printf '%q' "$V2_CORE_PATH")
# disable errexit for probe body (token alone on next line - never glue)
set +e
prod_md5=
v2_md5=
if [ ! -f "\$PRODUCT" ]; then
  prod_md5=MISSING
else
  prod_md5=\$(md5sum "\$PRODUCT" 2>/dev/null | awk '{print \$1}')
fi
if [ ! -f "\$V2" ]; then
  v2_md5=MISSING
else
  v2_md5=\$(md5sum "\$V2" 2>/dev/null | awk '{print \$1}')
fi
# Emit KEY=value on isolated lines. printf format ends with \\n - the next
# statement is always a new physical line in this heredoc (never adjacent set).
printf 'PRODUCT_CORE=%s\n' "\$PRODUCT"
printf 'PRODUCT_MD5=%s\n' "\$prod_md5"
printf 'V2_CORE=%s\n' "\$V2"
printf 'V2_MD5=%s\n' "\$v2_md5"
printf 'CORE_MD5_PROBE_DONE=%s\n' "1"
# --- live daemon identity (inlined; do NOT append pair_remote_live_daemon_snippet) ---
n=0
pids=
live=
conf=
port=
exe=
root=
for d in /proc/[0-9]*; do
  [ -e "\$d/exe" ] || continue
  p=\${d#/proc/}
  x=\$(readlink -f "\$d/exe" 2>/dev/null) || continue
  case "\$x" in
    *"(deleted)"*) continue ;;
  esac
  base=\$(basename "\$x" 2>/dev/null) || continue
  [ "\$base" = "misterplexd" ] || continue
  m=\$(md5sum "\$d/exe" 2>/dev/null | awk '{print \$1}')
  [ -n "\$m" ] || continue
  n=\$((n + 1))
  pids="\${pids}\${pids:+ }\$p"
  exe=\$x
  live=\$m
  root=\$(dirname "\$(dirname "\$x")")
  conf=
  port=
  prev=
  if [ -r "\$d/cmdline" ]; then
    cmd=\$(tr '\\0' ' ' <"\$d/cmdline" 2>/dev/null) || cmd=
    for tok in \$cmd; do
      case "\$prev" in
        --port) port="\$tok"; prev=; continue ;;
        --conf) conf="\$tok"; prev=; continue ;;
      esac
      case "\$tok" in
        --port) prev=--port ;;
        --port=*) port="\${tok#--port=}"; prev= ;;
        --conf) prev=--conf ;;
        --conf=*) conf="\${tok#--conf=}"; prev= ;;
        *) prev= ;;
      esac
    done
  fi
done
printf 'N_DAEMON=%s\n' "\$n"
printf 'PIDS=%s\n' "\$pids"
printf 'LIVE_MD5=%s\n' "\$live"
printf 'LIVE_EXE=%s\n' "\$exe"
printf 'LIVE_PORT=%s\n' "\$port"
printf 'LIVE_CONF=%s\n' "\$conf"
printf 'LIVE_ROOT=%s\n' "\$root"
printf 'LIVE_PROBE_DONE=%s\n' "1"
REMOTE
)
  # Host-side structural guard (must never ship a glued script).
  if printf '%s\n' "$remote" | grep -Eq 'MD5=.*set \+e|MD5=[0-9a-f]{32}set|PROBE_DONE=1[a-zA-Z]|v2_md5"set'; then
    echo "FAIL host-side remote script still has MD5/PROBE glue" >&2
    printf '%s\n' "$remote" | cat -A | grep -E 'MD5=|PROBE_DONE=|set \+e' | head -20 | sed 's/^/  /' >&2
    return 3
  fi
  # Every set +e must be alone on its line (cat -A style check without requiring cat -A).
  if printf '%s\n' "$remote" | grep -n 'set +e' | grep -vE '^[0-9]+:set \+e$'; then
    echo "FAIL host-side remote script: set +e not alone on its line" >&2
    return 3
  fi
  if [ "${PROMOTE_DUMP_REMOTE:-0}" = "1" ]; then
    printf '%s\n' "$remote"
    return 0
  fi
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

  # Shape gates FIRST - contaminated capture must never reach md5 equality.
  # Track per-field shape so a glue-contaminated V2_MD5 does not also emit a
  # misleading "got=...set +e want=<clean>" drift message (blind-and-RED class).
  shape_prod=0
  shape_v2=0
  shape_live=0
  set +e
  gate_assert_md5_shape "product-core" "$prod"
  shape_prod=$?
  gate_assert_md5_shape "v2-rollback-core" "$v2"
  shape_v2=$?
  gate_assert_md5_shape "live-exe-md5" "$live"
  shape_live=$?
  set -e
  if [ "$shape_prod" -ne 0 ] || [ "$shape_v2" -ne 0 ] || [ "$shape_live" -ne 0 ]; then
    rc=3
  fi
  # n_daemon must be a small integer if present
  if [ -n "$n" ] && ! printf '%s' "$n" | grep -Eq '^[0-9]+$'; then
    echo "FAIL n_daemon shape got='$n' (want digits only)"
    rc=3
  fi

  # product core (skip equality when shape already failed - do not look like pin drift)
  if [ "$shape_prod" -ne 0 ]; then
    echo "SKIP product-core equality (shape failed - fix probe capture, do not relax compare)"
  elif [ -z "$prod" ]; then
    echo "NO-DATA product-core md5 empty"
    rc=4
  elif [ "$prod" = "MISSING" ]; then
    echo "MISSING product core $PRODUCT_CORE_PATH"
    rc=2
  elif [ "$prod" != "$EXPECT_CORE_MD5" ]; then
    echo "FAIL product-core-disk got=$prod want=$EXPECT_CORE_MD5"
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
    if [ "$prc" -ne 0 ]; then rc=$prc; else echo "OK product-core-disk $prod"; fi
  fi

  # V2 rollback slot must remain intact
  if [ "$shape_v2" -ne 0 ]; then
    echo "SKIP v2-rollback-core equality (shape failed - capture contaminated; comparison not relaxed)"
  elif [ -z "$v2" ]; then
    echo "NO-DATA v2-rollback-core md5 empty"
    [ "$rc" -eq 0 ] && rc=4
  elif [ "$v2" = "MISSING" ]; then
    echo "FAIL v2-rollback-core MISSING at $V2_CORE_PATH - refuse promote without rollback path"
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

  if [ "$shape_live" -ne 0 ]; then
    echo "SKIP live-exe-md5 equality (shape failed - fix probe capture)"
  elif [ -z "$live" ]; then
    echo "NO-DATA live /proc/PID/exe md5 (disk-only is NOT success)"
    [ "$rc" -eq 0 ] && rc=4
  elif pair_policy_md5_match "$live" "$EXPECT_DAEMON_MD5"; then
    echo "OK live-exe-md5 $live (from readlink -f /proc/PID/exe; primary=$EXPECT_DAEMON_MD5)"
  elif rbf_policy_ddr_daemon_accepted "$live"; then
    # Accepted rollback/alternate pins (edc3/5996385a/b981/e9f79) must still verify-live GREEN.
    # Primary pin is the promote target; gate must not force exclusive primary match.
    echo "OK live-exe-md5 $live (accepted DDR pin; primary=$EXPECT_DAEMON_MD5)"
  else
    echo "FAIL live-exe-md5 got=$live want=primary:$EXPECT_DAEMON_MD5 or accepted DDR pin set"
    echo "     hint: verify via readlink -f /proc/PID/exe - never on-disk file alone (ETXTBSY)"
    rc=3
  fi

  if [ -z "$conf" ]; then
    echo "FAIL live --conf empty (must resolve conf from /proc/PID/cmdline, not assume misterplex/ vs _v2)"
    rc=9
  else
    echo "OK live-conf $conf (from cmdline)"
    # conf should live under live root when root known
    if [ -n "$root" ] && [ "$conf" != "$root/misterplex.conf" ]; then
      echo "NOTE conf $conf vs root $root/misterplex.conf - operator must confirm"
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
    elif [ "${PROMOTE_REQUIRE_CONF_KEYS:-1}" = "1" ]; then
      # Hard default: a key named REQUIRE must not soft-NOTE. Parent 2026-07-31:
      # green run never gated DDR_YUV_FORCE_SCALE / FFMPEG_SWS_FLAGS.
      conf_body=""
      if [ -n "${PROMOTE_CONF_BLOB:-}" ] || [ -n "${PROMOTE_CONF_PATH:-}" ]; then
        :
      elif [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
        set +e
        conf_body=$(run_ssh "if [ -f $(printf '%q' "$conf") ]; then cat $(printf '%q' "$conf"); else echo MISSING; fi")
        crc=$?
        set -e
        if [ "$crc" -eq 5 ]; then echo "true rc=5"; return 5; fi
        if [ -z "$conf_body" ] || [ "$conf_body" = "MISSING" ]; then
          echo "FAIL conf-keys cannot read live conf path=$conf"
          rc=3
        else
          conf_tmp="$ROOT/build/promote-live-conf.$$.txt"
          mkdir -p "$(dirname "$conf_tmp")"
          printf '%s
' "$conf_body" >"$conf_tmp"
          set +e
          pair_policy_check_conf "${PROMOTE_CONF_PROFILE:-ddr}" "$conf_tmp"
          crc=$?
          set -e
          rm -f "$conf_tmp"
          if [ "$crc" -ne 0 ]; then
            echo "FAIL live-conf-profile (keys required)"
            rc=3
          fi
        fi
      else
        echo "FAIL conf-keys not injected (PROMOTE_REQUIRE_CONF_KEYS=1; set PROMOTE_CONF_BLOB)"
        rc=3
      fi
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
      echo "FAIL live pair-compatibility (mixed pair -> solid green screen class)"
      rc=3
    else
      echo "OK live-pair-compatibility"
    fi
  fi

  # product-core-disk md5 proves the ON-DISK RBF file only - not that the FPGA is
# executing it (CORENAME=MENU still possible). Executing proof = PLXS magic+seq.
  # Running bitstream proof: PLXS mailbox magic (only ddr_frame_store publishes).
  # Parent: RBF md5 + daemon md5 pass while CORENAME=MENU. Disk ≠ executing core.
  # FpgaSpi::readOsdMailbox requires magic + mbox_seq advance; gate requires magic
  # at product phys (and optional seq delta when two samples available).
  if [ "${PROMOTE_SKIP_PLXS:-0}" != "1" ]; then
    plxs="${PROMOTE_PLXS_MAGIC:-}"
    plxs2="${PROMOTE_PLXS_MAGIC2:-}"
    seq1="${PROMOTE_PLXS_SEQ:-}"
    seq2="${PROMOTE_PLXS_SEQ2:-}"
    if [ -z "$plxs" ] && [ -n "$blob" ]; then
      plxs=$(gate_field "$blob" PLXS_MAGIC)
      plxs2=$(gate_field "$blob" PLXS_MAGIC2)
      seq1=$(gate_field "$blob" PLXS_SEQ)
      seq2=$(gate_field "$blob" PLXS_SEQ2)
    fi
    if [ -z "$plxs" ] && [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
      set +e
      plxs_blob=$(run_ssh "$(cat <<'REMOTE'
set +e
# Product DDR layout (480p bank geometry): PLXS at 0x300FF100
# Also probe 0x3007F100 (320x240-era) for older pins.
read_u32() {
  addr="$1"
  if command -v devmem >/dev/null 2>&1; then
    devmem "$addr" 32 2>/dev/null || echo MISSING
  elif [ -r /dev/mem ]; then
    # best-effort hexdump
    echo MISSING
  else
    echo MISSING
  fi
}
m1=$(read_u32 0x300FF100)
m1b=$(read_u32 0x300FF104)
sleep 0.05
m2=$(read_u32 0x300FF100)
m2b=$(read_u32 0x300FF104)
echo "PLXS_MAGIC=$m1"
echo "PLXS_HI=$m1b"
echo "PLXS_MAGIC2=$m2"
echo "PLXS_HI2=$m2b"
m3=$(read_u32 0x3007F100)
echo "PLXS_MAGIC_ALT=$m3"
REMOTE
)")
      prc=$?
      set -e
      if [ "$prc" -eq 5 ]; then echo "true rc=5"; return 5; fi
      plxs=$(gate_field "$plxs_blob" PLXS_MAGIC)
      plxs2=$(gate_field "$plxs_blob" PLXS_MAGIC2)
      hi1=$(gate_field "$plxs_blob" PLXS_HI)
      hi2=$(gate_field "$plxs_blob" PLXS_HI2)
      alt=$(gate_field "$plxs_blob" PLXS_MAGIC_ALT)
      printf '%s\n' "$plxs_blob" | sed 's/^/  [plxs] /'
      # seq in upper 16 of hi word (fpga_spi readOsdMailbox)
      if [ -n "$hi1" ] && [ "$hi1" != "MISSING" ]; then
        _h=${hi1#0x}; _h=${_h#0X}
        seq1=$(( 16#${_h} >> 16 & 65535 )) || seq1=""
      fi
      if [ -n "$hi2" ] && [ "$hi2" != "MISSING" ]; then
        _h=${hi2#0x}; _h=${_h#0X}
        seq2=$(( 16#${_h} >> 16 & 65535 )) || seq2=""
      fi
      if [ -z "$plxs" ] || [ "$plxs" = "MISSING" ] || [ "$plxs" = "0x00000000" ] || [ "$plxs" = "0x0" ]; then
        if [ -n "$alt" ] && [ "$alt" != "MISSING" ]; then plxs="$alt"; fi
      fi
    fi
    # Normalize
    plxs_n=$(printf '%s' "$plxs" | tr 'A-F' 'a-f')
    want_plxs="0x504c5853"
    if [ -z "$plxs" ] || [ "$plxs" = "MISSING" ]; then
      if [ "${PROMOTE_REQUIRE_PLXS:-1}" = "1" ]; then
        echo "FAIL PLXS mailbox unread (cannot prove executing bitstream is Plex ddr_frame_store)"
        echo "     inject PROMOTE_PLXS_MAGIC=0x504C5853 for unit tests; live uses devmem 0x300FF100"
        rc=3
      else
        echo "NOTE PLXS not checked (PROMOTE_REQUIRE_PLXS=0)"
      fi
    else
      case "$plxs_n" in
        0x504c5853|504c5853) echo "OK PLXS_MAGIC=$plxs (executing core publishes ddr mailbox)" ;;
        *)
          echo "FAIL PLXS_MAGIC got=$plxs want=0x504C5853 (MENU/other core or stale/absent mailbox)"
          rc=3
          ;;
      esac
      # Parent: magic alone can be leftover from a previous core; advancing
      # mbox_seq proves the fabric is executing. Default REQUIRE=1.
      if [ "${PROMOTE_REQUIRE_PLXS_SEQ_ADVANCE:-1}" = "1" ]; then
        if [ -z "$seq1" ] || [ -z "$seq2" ]; then
          echo "FAIL PLXS_SEQ samples missing (need two reads to prove mbox_seq advance; hung/stale magic possible)"
          echo "     inject PLXS_SEQ + PLXS_SEQ2 (differing) for unit tests"
          rc=3
        elif [ "$seq1" = "$seq2" ]; then
          echo "FAIL PLXS_SEQ did not advance seq=$seq1 (stuck mailbox = hung core / leftover magic)"
          rc=3
        else
          echo "OK PLXS_SEQ advanced $seq1 -> $seq2 (fabric executing)"
        fi
      else
        if [ -n "$seq1" ] && [ -n "$seq2" ] && [ "$seq1" = "$seq2" ]; then
          echo "NOTE PLXS_SEQ unchanged seq=$seq1 (PROMOTE_REQUIRE_PLXS_SEQ_ADVANCE=0)"
        elif [ -n "$seq1" ] && [ -n "$seq2" ] && [ "$seq1" != "$seq2" ]; then
          echo "OK PLXS_SEQ advanced $seq1 -> $seq2"
        fi
      fi
    fi
  fi

  # Boot hook must match live pair root (parent cold-boot defect 2026-07-31).
  # P0 2026-07-31: path MUST come from /etc/init.d/S99user USER_SCRIPT= - never
  # hardcode _user-startup.sh (decoy). Gate green-on-decoy nearly stranded daily driver.
  if [ "${PROMOTE_SKIP_BOOT_HOOK:-0}" != "1" ]; then
    hook_body=""
    decoy_body=""
    s99_body=""
    resolved_hook_path=""
    expect_root="${PROMOTE_BOOT_ROOT:-$BOOT_HOOK_DEFAULT_ROOT}"
    if [ -n "$root" ]; then expect_root="$root"; fi

    # --- resolve path from init (observe what the system consults) ---
    if [ -n "${PROMOTE_S99_BLOB:-}" ] && [ -f "${PROMOTE_S99_BLOB}" ]; then
      s99_body=$(cat "$PROMOTE_S99_BLOB")
    elif [ -n "${PROMOTE_S99_BODY:-}" ]; then
      s99_body="${PROMOTE_S99_BODY}"
    elif [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
      set +e
      s99_body=$(run_ssh "if [ -f /etc/init.d/S99user ]; then cat /etc/init.d/S99user; else echo MISSING; fi")
      hrc=$?
      set -e
      if [ "$hrc" -eq 5 ]; then echo "true rc=5"; return 5; fi
    fi

    if [ -n "$s99_body" ]; then
      set +e
      resolved_hook_path=$(boot_hook_parse_user_script "$s99_body" 2>/dev/null)
      rrc=$?
      set -e
      if [ "$rrc" -ne 0 ] || [ -z "$resolved_hook_path" ]; then
        echo "FAIL boot-hook path not derived from S99user (no guess fallback)"
        boot_hook_parse_user_script "$s99_body" 2>&1 | sed 's/^/  /' || true
        rc=3
      else
        echo "OK boot-hook-path-from-init USER_SCRIPT=$resolved_hook_path"
        BOOT_HOOK_DEVICE_PATH="$resolved_hook_path"
      fi
    elif [ -n "${PROMOTE_HOOK_PATH:-}" ]; then
      resolved_hook_path="${PROMOTE_HOOK_PATH}"
      echo "NOTE boot-hook path from PROMOTE_HOOK_PATH=$resolved_hook_path (init not injected)"
    elif [ -n "${PROMOTE_GATE_BLOB:-}" ] && [ -z "${PROMOTE_HOOK_BLOB:-}" ] && [ -z "${PROMOTE_HOOK_BODY:-}" ] \
         && [ "${PROMOTE_REQUIRE_BOOT_HOOK:-0}" != "1" ]; then
      echo "NOTE boot-hook not in gate blob - set PROMOTE_S99_BLOB + PROMOTE_HOOK_BLOB"
    elif [ "${PROMOTE_REQUIRE_BOOT_HOOK:-1}" = "1" ] && [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
      echo "FAIL boot-hook S99user body unavailable - cannot derive USER_SCRIPT"
      rc=3
    fi

    if [ -n "$resolved_hook_path" ] && [ "$resolved_hook_path" = "$BOOT_HOOK_LEGACY_DECOY_PATH" ]; then
      echo "WARN USER_SCRIPT points at legacy decoy name $resolved_hook_path"
    fi

    # --- load REAL hook body ---
    if [ -n "${PROMOTE_HOOK_BLOB:-}" ] && [ -f "${PROMOTE_HOOK_BLOB}" ]; then
      hook_body=$(cat "$PROMOTE_HOOK_BLOB")
    elif [ -n "${PROMOTE_HOOK_BODY:-}" ]; then
      hook_body="${PROMOTE_HOOK_BODY}"
    elif [ -n "$resolved_hook_path" ] && [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
      set +e
      hook_body=$(run_ssh "if [ -f $(printf '%q' "$resolved_hook_path") ]; then cat $(printf '%q' "$resolved_hook_path"); else echo MISSING; fi")
      hrc=$?
      set -e
      if [ "$hrc" -eq 5 ]; then echo "true rc=5"; return 5; fi
    fi

    # --- load DECOY body (must be inert) ---
    if [ -n "${PROMOTE_DECOY_HOOK_BLOB:-}" ] && [ -f "${PROMOTE_DECOY_HOOK_BLOB}" ]; then
      decoy_body=$(cat "$PROMOTE_DECOY_HOOK_BLOB")
    elif [ -n "${PROMOTE_DECOY_HOOK_BODY:-}" ]; then
      decoy_body="${PROMOTE_DECOY_HOOK_BODY}"
    elif [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
      set +e
      decoy_body=$(run_ssh "if [ -f /media/fat/linux/_user-startup.sh ]; then cat /media/fat/linux/_user-startup.sh; else echo ABSENT; fi")
      hrc=$?
      set -e
      if [ "$hrc" -eq 5 ]; then echo "true rc=5"; return 5; fi
    fi

    if [ -z "$hook_body" ] || [ "$hook_body" = "MISSING" ]; then
      if [ -n "${PROMOTE_GATE_BLOB:-}" ] && [ -z "${PROMOTE_HOOK_BLOB:-}" ] && [ -z "${PROMOTE_HOOK_BODY:-}" ] \
         && [ "${PROMOTE_REQUIRE_BOOT_HOOK:-0}" != "1" ]; then
        echo "NOTE boot-hook body not injected"
      elif [ "${PROMOTE_REQUIRE_BOOT_HOOK:-1}" = "1" ]; then
        echo "FAIL boot-hook REAL body missing (path=${resolved_hook_path:-unresolved})"
        rc=3
      else
        echo "NOTE boot-hook not checked"
      fi
    else
      if [ -n "$resolved_hook_path" ]; then
        echo "boot-hook-real-path=$resolved_hook_path"
      elif [ "${PROMOTE_REQUIRE_S99:-1}" = "1" ] && [ -n "${PROMOTE_HOOK_BLOB:-}${PROMOTE_HOOK_BODY:-}" ]; then
        # Injected hook without S99 is incomplete for claim success when required.
        if [ -n "${PROMOTE_S99_BLOB:-}${PROMOTE_S99_BODY:-}" ] || [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
          :
        elif [ "${PROMOTE_REQUIRE_BOOT_HOOK:-0}" = "1" ]; then
          echo "FAIL boot-hook injected without S99user derivation (decoy class)"
          rc=3
        fi
      fi
      set +e
      boot_hook_check_body "$hook_body" "$expect_root"
      hrc=$?
      set -e
      if [ "$hrc" -ne 0 ]; then
        echo "FAIL boot-hook vs pair root expect=$expect_root path=${resolved_hook_path:-unknown}"
        rc=3
      else
        echo "OK boot-hook matches root=$expect_root path=${resolved_hook_path:-injected}"
        if [ -n "$root" ] && [ "$root" != "$expect_root" ]; then
          echo "FAIL live-root $root != boot expect $expect_root"
          rc=3
        fi
      fi
    fi

    # Decoy inertness
    if [ -n "$decoy_body" ]; then
      set +e
      boot_hook_check_decoy_body "$decoy_body"
      drc=$?
      set -e
      if [ "$drc" -ne 0 ]; then
        echo "FAIL boot-hook decoy _user-startup.sh is not inert (underscore file is NOT executed)"
        rc=3
      else
        echo "OK boot-hook decoy inert"
      fi
    fi
  fi

  # Visual ALWAYS RUNS (aggregate). Parent 2026-07-31:
  # 1) auto-idle elif hid motion - motion unreachable when grabber present (backwards).
  # 2) idle luma envelope passed MiSTer MENU while CORENAME=MENU / Plex not loaded.
  # Require positive chevron idle AND motion when grabber present (or both injected).
  vrc=8
  prior_rc=$rc
  motion_cmd="${PROMOTE_MOTION_CMD:-}"
  if [ -z "$motion_cmd" ] && [ -n "${PROMOTE_MOTION_CAPTURE_DIR:-}" ]; then
    motion_cmd="python3 $(printf '%q' "$ROOT/tools/hdmi_motion_instrument.py") $(printf '%q' "$PROMOTE_MOTION_CAPTURE_DIR")"
  fi
  hdmi_dev="${HDMI_DEV:-/dev/video0}"
  auto_cap=0
  if [ "${PROMOTE_AUTO_CAPTURE:-1}" = "1" ] && [ -z "${PROMOTE_GATE_BLOB:-}" ]; then
    if [ -e "$hdmi_dev" ]; then auto_cap=1; fi
  fi

  run_idle_visual() {
    set +e
    "$ROOT/scripts/pair_visual_gate.sh" idle
    local irc=$?
    set -e
    echo "visual_idle true rc=$irc"
    return "$irc"
  }
  run_motion_visual() {
    set +e
    # shellcheck disable=SC2086
    eval $motion_cmd
    local mrc=$?
    set -e
    echo "motion_hook true rc=$mrc cmd=$motion_cmd"
    if [ "$mrc" -eq 77 ]; then
      echo "FAIL motion UNSCORED rc=77 is HARD FAIL for promotion (not inconclusive)"
      return 8
    fi
    if [ "$mrc" -ne 0 ]; then
      echo "FAIL motion instrument hard fail rc=$mrc (0=OK 1=FREEZE 2=COLOR_FAIL)"
      return 8
    fi
    return 0
  }

  if [ -n "${PROMOTE_VISUAL_CMD:-}" ]; then
    set +e
    # shellcheck disable=SC2086
    eval $PROMOTE_VISUAL_CMD
    vrc=$?
    set -e
    echo "visual_hook true rc=$vrc"
  else
    want_idle=0
    want_motion=0
    if [ -n "${PAIR_IDLE_PNG:-}" ] || [ -n "${PAIR_CAPTURE_CMD:-}" ] || [ "${PROMOTE_VISUAL_IDLE:-0}" = "1" ] || [ "$auto_cap" = "1" ]; then
      want_idle=1
    fi
    if [ -n "$motion_cmd" ]; then
      want_motion=1
    fi
    # Motion must not lose to auto-idle. When grabber present, require BOTH unless
    # operator explicitly allows idle-only (incomplete promote).
    if [ "$auto_cap" = "1" ]; then
      want_idle=1
      if [ "${PROMOTE_ALLOW_IDLE_ONLY:-0}" != "1" ]; then
        want_motion=1
      fi
    fi
    # Unit inject: if only motion_cmd set, run motion; if only idle, idle.
    # If both flags set, run both and require both pass.
    irc=0
    mrc=0
    ran=0
    if [ "$want_idle" = "1" ]; then
      if [ "$auto_cap" = "1" ] && [ -z "${PAIR_IDLE_PNG:-}" ] && [ -z "${PAIR_CAPTURE_CMD:-}" ]; then
        echo "visual_idle: auto-capture via scripts/hdmi_capture_idle.sh (warm-up baked in)"
      fi
      set +e
      run_idle_visual
      irc=$?
      set -e
      ran=1
    fi
    if [ "$want_motion" = "1" ]; then
      if [ -z "$motion_cmd" ]; then
        echo "FAIL motion observation required when grabber present (set PROMOTE_MOTION_CAPTURE_DIR or PROMOTE_MOTION_CMD)"
        echo "     idle-only is not a promotion gate (parent: PROMOTE_GATES_OK never saw playback)"
        mrc=8
      else
        set +e
        run_motion_visual
        mrc=$?
        set -e
      fi
      ran=1
    fi
    if [ "$ran" -eq 0 ]; then
      echo "VISUAL_REQUIRED: need idle chevron ID and/or motion observation"
      echo "  Idle:   PAIR_IDLE_PNG=... or auto /dev/video0 via hdmi_capture_idle.sh"
      echo "  Motion: PROMOTE_MOTION_CAPTURE_DIR=... (beats idle-only; required with grabber)"
      vrc=8
    elif [ "$want_idle" = "1" ] && [ "$want_motion" = "1" ]; then
      if [ "$irc" -eq 0 ] && [ "$mrc" -eq 0 ]; then
        echo "OK visual-idle+motion (both observed)"
        vrc=0
      else
        echo "FAIL visual combined idle_rc=$irc motion_rc=$mrc (both required)"
        vrc=8
      fi
    elif [ "$want_idle" = "1" ]; then
      vrc=$irc
    else
      vrc=$mrc
    fi
  fi

  if [ "$vrc" -eq 0 ]; then
    echo "OK visual-or-motion-gate"
    if [ "$prior_rc" -ne 0 ]; then
      echo "NOTE visual OK but earlier gate already failed rc=$prior_rc (aggregate keeps earlier rc)"
    fi
  else
    echo "FAIL visual/motion gate rc=$vrc (hard - cannot claim pair success)"
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
  dump-remote-live)
    # Host-only: print the exact remote probe script (no SSH). For glue audits.
    PROMOTE_DUMP_REMOTE=1 remote_live_blob
    echo "true rc=0"
    ;;
  *)
    echo "usage: $0 {policy-local <rbf> <daemon>|verify-live|dump-remote-live}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
