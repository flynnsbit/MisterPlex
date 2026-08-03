#!/usr/bin/env bash
# parent_playing_gate.sh — single-invocation PLAYING glass gate for the parent.
#
# PURPOSE
#   Eliminate "wrong sequence → misattributed fabric result". Runs preconditions,
#   two-deploy pairing (RBF ≠ daemon), delivered-geometry proof, then the
#   fab-playing capture contract (NEG / P1 pair / optional P2 ARM-out by PID).
#
#   A precondition failure is NEVER reported as a fabric taxonomy class.
#   Grabber failure is UNKNOWN_GRABBER (rc=3), never fabric FAIL/PASS.
#
# Contract docs:
#   docs/fab-playing-parent-capture-contract.md
#   docs/fab-playing-parent-runbook.md
#   docs/evidence/p720-path-20260803/PARENT_DEPLOY_PAIR_540P.md  (w-path pair card)
#   docs/evidence/p720-path-20260803/PMS_540_DELIVERED_GEOMETRY.md
#
# Usage (parent only — agents must not drive the device):
#   EXPECT_RBF_MD5=<full-or-prefix> scripts/parent_playing_gate.sh
#   scripts/parent_playing_gate.sh preflight
#   scripts/parent_playing_gate.sh neg|p1|p2|full
#   scripts/parent_playing_gate.sh score-only T0.png T1.png
#   scripts/parent_playing_gate.sh offline-selftest   # no device
#
# Exit codes:
#   0  VERDICT=A_FABRIC_PLAY_OK (product PASS)
#   1  scored product non-A taxonomy (B/C/D/CONTROL/E …) — glass result
#   2  usage / bad args
#   3  UNKNOWN_GRABBER — not a product verdict
#   4  PRECOND_* — pairing/device/delivery failed; NOT fabric
#   5  P2 black / present-dead after a candidate P1 (present path died)
#
# Env (common):
#   MISTER_HOST (192.168.1.183)  MISTER_PASS (1)  MISTER_USER (root)
#   EXPECT_RBF_MD5   required for full/preflight live (prefix ok, e.g. first 8)
#   BASELINE_RBF_MD5 default c5382bee — Plex_rel.rbf must match prefix (rollback)
#   EXPECT_DAEMON_MD5 optional live /proc/PID/exe md5 prefix
#   EV_DIR           artifact dir (default docs/agent-evidence/playing-gate-<ts>)
#   SKIP_NEG=0|1  SKIP_P2=0|1  SKIP_DELIVERY_FFPROBE=0|1
#   STREAM_SAMPLE    optional local/device path for ffprobe of delivered body
#   PLAYING_GATE_SSH / PLAYING_GATE_SCP  inject for unit tests (never real box)
#   HDMI_DEV  HDMI_SIZE  (passed through to hdmi_capture_idle.sh)
#
# Hard rules:
#   - scripts/hdmi_capture_idle.sh only (never bare ffmpeg -frames:v 1)
#   - kill <PID> only for ARM-out (never killall/pkill)
#   - true rc captured directly (never through a pipe on the decision path)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BASELINE_RBF_MD5="${BASELINE_RBF_MD5:-c5382bee}"
EXPECT_RBF_MD5="${EXPECT_RBF_MD5:-}"
EXPECT_DAEMON_MD5="${EXPECT_DAEMON_MD5:-}"
SKIP_NEG="${SKIP_NEG:-0}"
SKIP_P2="${SKIP_P2:-0}"
SKIP_DELIVERY_FFPROBE="${SKIP_DELIVERY_FFPROBE:-0}"
STREAM_SAMPLE="${STREAM_SAMPLE:-}"
MODE="full"
SCORE_T0=""
SCORE_T1=""

TS="$(date +%Y%m%dT%H%M%S)"
EV_DIR="${EV_DIR:-$ROOT/docs/agent-evidence/playing-gate-$TS}"
CAPTURE="$ROOT/scripts/hdmi_capture_idle.sh"
SCORE="$ROOT/scripts/hdmi_score_pair.sh"
LOG_BUNDLE="$EV_DIR/gate.log"

# --- helpers ------------------------------------------------------------------

usage() {
  sed -n '2,55p' "$0" | sed 's/^# \?//'
}

say() { printf '\n=== %s ===\n' "$*" | tee -a "$LOG_BUNDLE" 2>/dev/null || printf '\n=== %s ===\n' "$*"; }
log() { printf '%s\n' "$*" | tee -a "$LOG_BUNDLE" 2>/dev/null || printf '%s\n' "$*"; }

# Print and return a true rc without piping the subject command.
report_rc() {
  local label="$1" rc="$2"
  log "${label}: true rc=${rc}"
  return "$rc"
}

emit_precond() {
  # PRECOND failures: never a fabric VERDICT= taxonomy.
  local id="$1" detail="$2"
  log "PRECOND_FAIL id=${id} detail=${detail}"
  log "VERDICT=PRECOND_${id}"
  log "NOTE=precondition failure — not a fabric product result; fix pair/device before scoring glass"
  exit 4
}

emit_unknown_grabber() {
  local detail="$1"
  log "GRABBER_FAIL detail=${detail}"
  if [[ -x "$SCORE" ]]; then
    set +e
    "$SCORE" --grabber-not-ready
    local rc=$?
    set -e
    log "score_pair_grabber_path: true rc=${rc}"
  else
    log "VERDICT=UNKNOWN_GRABBER"
  fi
  exit 3
}

emit_scored() {
  local verdict="$1" rc_out="$2"
  log "FINAL_VERDICT=${verdict}"
  log "VERDICT=${verdict}"
  exit "$rc_out"
}

ssh_m() {
  if [[ -n "${PLAYING_GATE_SSH:-}" ]]; then
    # shellcheck disable=SC2086
    $PLAYING_GATE_SSH "$@"
    return
  fi
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o ServerAliveInterval=3 "$USER@$HOST" "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || emit_precond "HOST_TOOL" "missing command: $1"
}

md5_prefix_match() {
  # $1=full_or_prefix_expect  $2=actual_full
  local exp="${1,,}" act="${2,,}"
  [[ -n "$exp" && -n "$act" ]] || return 1
  [[ "$act" == "$exp"* || "$exp" == "$act"* || "$act" == "$exp" ]]
}

ensure_ev() {
  mkdir -p "$EV_DIR"
  : >>"$LOG_BUNDLE"
}

# --- phase 0: local tools -----------------------------------------------------

phase_local_tools() {
  say "0 LOCAL TOOLS"
  need_cmd sshpass
  need_cmd ssh
  need_cmd ping
  need_cmd python3
  [[ -x "$CAPTURE" ]] || emit_precond "HOST_TOOL" "missing $CAPTURE"
  [[ -x "$SCORE" ]] || emit_precond "HOST_TOOL" "missing $SCORE"
  if ! command -v fuser >/dev/null 2>&1; then
    log "WARN: fuser not found — cannot prove /dev/video0 free on host"
  fi
  log "OK local tools"
}

# --- phase 1: device reachability + recover anchors ---------------------------

phase_device_reachable() {
  say "1 DEVICE REACHABILITY"
  if [[ -n "${PLAYING_GATE_SSH:-}" ]]; then
    log "MOCK_SSH=1 — skip host ping (injected PLAYING_GATE_SSH)"
  else
    set +e
    ping -c 2 -W 2 "$HOST" >/dev/null 2>&1
    local prc=$?
    set -e
    report_rc "ping" "$prc" || emit_precond "DEVICE_UNREACHABLE" "ping $HOST failed"
  fi

  set +e
  local up
  up="$(ssh_m 'cat /proc/uptime' 2>/dev/null | head -1)"
  local urc=$?
  set -e
  report_rc "ssh_uptime" "$urc" || emit_precond "DEVICE_SSH" "ssh failed"
  log "uptime_raw=${up}"
  # After the pl330 wedge, parent wants a real power cycle (small uptime). Soft
  # warn only — do not hard-fail a healthy long-running box mid-session.
  local up_s
  up_s="$(awk '{print int($1+0)}' <<<"$up" 2>/dev/null || echo 999999)"
  if [[ "${REQUIRE_FRESH_BOOT:-0}" == "1" && "$up_s" -gt "${MAX_UPTIME_S:-600}" ]]; then
    emit_precond "STALE_BOOT" "uptime_s=${up_s} > MAX_UPTIME_S (set REQUIRE_FRESH_BOOT=0 to allow)"
  fi
  log "OK device reachable uptime_s=${up_s}"
}

phase_dma_and_baseline() {
  say "2 DMA + BASELINE RBF ROLLBACK ANCHOR"
  set +e
  local dma
  dma="$(ssh_m 'ls -l /sys/bus/amba/devices/ffe01000.pdma/driver 2>&1; ls /sys/class/dma 2>/dev/null | wc -l' 2>/dev/null)"
  local drc=$?
  set -e
  report_rc "dma_probe" "$drc" || emit_precond "DMA_PROBE" "could not query pdma driver"
  log "dma_probe_out=${dma}"
  if ! grep -q 'dma-pl330\|driver' <<<"$dma"; then
    log "WARN: dma-pl330 link not obvious — parent should confirm post power-cycle"
  fi

  set +e
  local rbf_lines
  rbf_lines="$(ssh_m 'md5sum /media/fat/_Utility/Plex.rbf /media/fat/_Utility/Plex_rel.rbf 2>&1' 2>/dev/null)"
  local rrc=$?
  set -e
  report_rc "rbf_md5sum" "$rrc" || emit_precond "RBF_INVENTORY" "md5sum remote RBFs failed"
  log "rbf_inventory:"
  log "$rbf_lines"

  local live_md5 rel_md5
  live_md5="$(awk '/Plex\.rbf/{print $1; exit}' <<<"$rbf_lines")"
  rel_md5="$(awk '/Plex_rel\.rbf/{print $1; exit}' <<<"$rbf_lines")"
  log "LIVE_RBF_MD5=${live_md5:-}"
  log "REL_RBF_MD5=${rel_md5:-}"

  if [[ -z "${rel_md5:-}" ]]; then
    emit_precond "BASELINE_MISSING" "Plex_rel.rbf absent — no rollback anchor"
  fi
  if ! md5_prefix_match "$BASELINE_RBF_MD5" "$rel_md5"; then
    emit_precond "BASELINE_MD5" "Plex_rel md5=${rel_md5} does not match BASELINE_RBF_MD5=${BASELINE_RBF_MD5}"
  fi
  log "OK baseline Plex_rel matches prefix ${BASELINE_RBF_MD5}"

  if [[ -z "${EXPECT_RBF_MD5}" ]]; then
    emit_precond "EXPECT_RBF_MD5" "set EXPECT_RBF_MD5 to the integration fit RBF md5 (prefix ok)"
  fi
  if [[ -z "${live_md5:-}" ]]; then
    emit_precond "LIVE_RBF_MISSING" "Plex.rbf missing on device"
  fi
  if ! md5_prefix_match "$EXPECT_RBF_MD5" "$live_md5"; then
    emit_precond "LIVE_RBF_MD5" "live Plex.rbf md5=${live_md5} != EXPECT_RBF_MD5=${EXPECT_RBF_MD5} (deploy fabric RBF first via deploy_plex_core.sh)"
  fi
  log "OK live RBF matches EXPECT_RBF_MD5=${EXPECT_RBF_MD5}"
  printf '%s\n' "$live_md5" >"$EV_DIR/live_rbf.md5"
  printf '%s\n' "$rel_md5" >"$EV_DIR/rel_rbf.md5"
}

phase_video_mode() {
  say "3 VIDEO_MODE (expect 0 = 720p-class beam; same as control arm)"
  set +e
  local ini
  ini="$(ssh_m 'grep -E "^(video_mode|video_mode_ntsc|video_mode_pal)=" /media/fat/MiSTer.ini 2>/dev/null | head -20' 2>/dev/null)"
  local irc=$?
  set -e
  report_rc "mister_ini_grep" "$irc" || emit_precond "INI" "could not read MiSTer.ini"
  log "ini_video_modes:"
  log "$ini"
  # Prefer [Plex] section if present — sweep script writes all three.
  local vm
  vm="$(grep -E '^video_mode=' <<<"$ini" | tail -1 | cut -d= -f2 | tr -d '[:space:]')"
  log "video_mode=${vm:-}"
  if [[ "${vm:-}" != "0" ]]; then
    emit_precond "VIDEO_MODE" "video_mode=${vm:-unset} want 0 (control arm d1b24e0c binding). Fix MiSTer.ini [Plex] before scoring."
  fi
  log "OK video_mode=0"
}

# --- phase 4: grabber free ----------------------------------------------------

phase_grabber_free() {
  say "4 GRABBER /dev/video0 NOT HELD"
  local dev="${HDMI_DEV:-/dev/video0}"
  if [[ ! -e "$dev" ]]; then
    emit_unknown_grabber "no_device dev=$dev"
  fi
  if command -v fuser >/dev/null 2>&1; then
    set +e
    local holders
    holders="$(fuser -v "$dev" 2>&1 || true)"
    set -e
    if fuser "$dev" >/dev/null 2>&1; then
      log "fuser_out=${holders}"
      emit_unknown_grabber "device_busy dev=$dev — close OBS/preview/nautilus; fuser -v $dev"
    fi
  fi
  log "OK grabber free dev=$dev"
}

# --- phase 5: two-deploy pairing (daemon 540p tier) ---------------------------

phase_daemon_540_pair() {
  say "5 TWO-DEPLOY PAIR — daemon must support + request 540p"
  log "NOTE: fabric RBF (deploy_plex_core.sh) ≠ daemon (deploy_misterplexd.sh)."
  log "NOTE: 540p ladder lives in the DAEMON. Wrong daemon → PMS wrong geom → false D2/D3."

  set +e
  local pid
  pid="$(ssh_m 'pidof misterplexd' 2>/dev/null | tr -d ' \r' | head -1)"
  local prc=$?
  set -e
  report_rc "pidof_misterplexd" "$prc"
  if [[ -z "${pid:-}" ]]; then
    emit_precond "DAEMON_NOT_RUNNING" "pidof misterplexd empty — deploy_misterplexd.sh the w-path 540p binary first"
  fi
  # Reject multi-PID (pidof can return several).
  if [[ "$pid" == *" "* ]]; then
    emit_precond "DAEMON_MULTI" "multiple misterplexd PIDs='$pid' — stop extras; n_daemon must be 1"
  fi
  log "DAEMON_PID=${pid}"
  printf '%s\n' "$pid" >"$EV_DIR/daemon.pid"

  set +e
  local exe_md5 exe_path
  exe_path="$(ssh_m "readlink -f /proc/${pid}/exe" 2>/dev/null | tr -d '\r')"
  exe_md5="$(ssh_m "md5sum /proc/${pid}/exe 2>/dev/null" 2>/dev/null | awk '{print $1}')"
  local erc=$?
  set -e
  report_rc "daemon_exe_md5" "$erc" || emit_precond "DAEMON_EXE" "could not md5 /proc/$pid/exe"
  log "DAEMON_EXE=${exe_path:-} MD5=${exe_md5:-}"
  printf '%s\n' "${exe_md5:-}" >"$EV_DIR/daemon_live.md5"
  if [[ -n "${EXPECT_DAEMON_MD5}" ]]; then
    if ! md5_prefix_match "$EXPECT_DAEMON_MD5" "${exe_md5:-}"; then
      emit_precond "DAEMON_MD5" "live exe md5=${exe_md5} != EXPECT_DAEMON_MD5=${EXPECT_DAEMON_MD5}"
    fi
    log "OK daemon md5 matches EXPECT_DAEMON_MD5"
  fi

  # Binary capability: must contain 540p / 960x540 ladder strings (w-path ≥8e62f61b).
  set +e
  local strings_hit
  strings_hit="$(ssh_m "strings /proc/${pid}/exe 2>/dev/null | grep -E '540p|960x540' | head -20" 2>/dev/null || true)"
  set -e
  log "daemon_strings_540:"
  log "${strings_hit:-<none>}"
  if ! grep -qE '540p|960x540' <<<"${strings_hit:-}"; then
    emit_precond "DAEMON_NO_540_TIER" "live misterplexd lacks 540p/960x540 strings — build from w-path-720p ≥8e62f61b and deploy_misterplexd.sh (not fabric-only deploy)"
  fi
  log "OK daemon binary advertises 540p tier"

  # Conf: DECODE + OSD_CONTROL
  set +e
  local conf
  conf="$(ssh_m 'grep -E "^(DECODE|TRANSCODE_PROFILE|WEAK_RES|WEAK_BITRATE|OSD_CONTROL|OSD_TIER|AUTO_LADDER)=" /media/fat/misterplex/misterplex.conf 2>/dev/null | head -40' 2>/dev/null || true)"
  set -e
  log "misterplex.conf tier keys:"
  log "${conf:-<empty or missing>}"
  printf '%s\n' "$conf" >"$EV_DIR/misterplex.conf.tier"

  local decode osd_ctl weak_br
  decode="$(grep -E '^DECODE=' <<<"$conf" | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  osd_ctl="$(grep -E '^OSD_CONTROL=' <<<"$conf" | tail -1 | cut -d= -f2- | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true)"
  weak_br="$(grep -E '^WEAK_BITRATE=' <<<"$conf" | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  log "DECODE=${decode:-} OSD_CONTROL=${osd_ctl:-} WEAK_BITRATE=${weak_br:-}"

  if [[ "${decode:-}" != "960x540" ]]; then
    # Also accept TRANSCODE_PROFILE=540p / WEAK_RES=960x540 as request path.
    local tp wr
    tp="$(grep -E '^TRANSCODE_PROFILE=' <<<"$conf" | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
    wr="$(grep -E '^WEAK_RES=' <<<"$conf" | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
    if [[ "${tp:-}" != "540p" && "${wr:-}" != "960x540" && "${tp:-}" != "960x540" ]]; then
      emit_precond "CONF_DECODE" "need DECODE=960x540 (or TRANSCODE_PROFILE=540p) in misterplex.conf — got DECODE=${decode:-empty}"
    fi
  fi
  if [[ "${osd_ctl:-}" != "off" && "${osd_ctl:-}" != "0" && "${osd_ctl:-}" != "false" ]]; then
    emit_precond "CONF_OSD_CONTROL" "OSD_CONTROL must be off for 540p test (O[5:4] has no 540 slot and will override DECODE). got=${osd_ctl:-unset}"
  fi
  if [[ -n "${weak_br:-}" && "${weak_br}" =~ ^[0-9]+$ && "${weak_br}" -lt 2000 ]]; then
    emit_precond "CONF_BITRATE" "WEAK_BITRATE=${weak_br} < 2000 — measured PMS knee returns 720x404 not 960x540"
  fi
  log "OK conf requests 540p path with OSD_CONTROL off"

  # Runtime log: requested geometry (not delivered yet)
  set +e
  local dlog
  dlog="$(ssh_m 'grep -E "DECODE adopted|content resolution=|GEOM requested_pms=|GEOMETRY decode_bank=|MEASURED_DELIVERY" /media/fat/misterplex/misterplexd.log 2>/dev/null | tail -40' 2>/dev/null || true)"
  set -e
  log "daemon_log_geom_tail:"
  log "${dlog:-<no matches>}"
  printf '%s\n' "$dlog" >"$EV_DIR/daemon_geom_log.txt"

  # Prefer the latest content resolution / GEOM requested line.
  local req_line
  req_line="$(grep -E 'content resolution=|GEOM requested_pms=' <<<"$dlog" | tail -5 || true)"
  log "req_lines=${req_line:-}"
  if ! grep -qE 'content resolution=960x540|GEOM requested_pms=960x540|pms_request_geometry=960x540|decode_bank=960x540' <<<"$dlog"; then
    emit_precond "LOG_REQUEST_NOT_540" "daemon log lacks 960x540 request/decode evidence after play — cast HD 16:9 with DECODE=960x540 then re-run. See PARENT_DEPLOY_PAIR_540P.md"
  fi
  if grep -qE 'content resolution=(320x240|624x480)|source=OSD O\[4\]' <<<"$dlog" \
    && ! grep -qE 'content resolution=960x540 source=conf' <<<"$dlog"; then
    # Only fail if the *latest* play looks wrong.
    local last_content
    last_content="$(grep 'content resolution=' <<<"$dlog" | tail -1 || true)"
    if ! grep -q '960x540' <<<"${last_content:-}"; then
      emit_precond "LOG_REQUEST_WRONG_TIER" "latest content resolution line not 960x540: ${last_content}"
    fi
    if grep -q 'source=OSD O\[4\]' <<<"${last_content:-}"; then
      emit_precond "LOG_OSD_OVERRIDE" "latest play used OSD O[4] — set OSD_CONTROL=off and replay"
    fi
  fi
  log "OK daemon log shows 960x540 request path"
}

# --- phase 6: delivered geometry (not requested) ------------------------------

phase_delivered_geometry() {
  say "6 DELIVERED STREAM GEOMETRY (fail-closed if ≠ fabric expect)"
  log "NOTE: videoResolution is a ceiling; PMS has returned smaller geom (720x404 @ maxBR<2000)."

  set +e
  local dlog
  dlog="$(cat "$EV_DIR/daemon_geom_log.txt" 2>/dev/null || true)"
  if [[ -z "$dlog" ]]; then
    dlog="$(ssh_m 'grep -E "MEASURED_DELIVERY|MEASURED_OUTPUT|delivered_geom" /media/fat/misterplex/misterplexd.log 2>/dev/null | tail -30' 2>/dev/null || true)"
  fi
  set -e
  log "delivery_log_tail:"
  log "${dlog:-<none>}"

  local deliv_w="" deliv_h="" basis=""
  # Prefer MEASURED_DELIVERY 960x540 or delivered_geom=960x540
  local last_deliv
  last_deliv="$(grep -E 'MEASURED_DELIVERY' <<<"$dlog" | tail -1 || true)"
  log "last_MEASURED_DELIVERY=${last_deliv:-}"
  if [[ -n "${last_deliv}" ]]; then
    if [[ "$last_deliv" =~ delivered_geom=([0-9]+)x([0-9]+) ]]; then
      deliv_w="${BASH_REMATCH[1]}"; deliv_h="${BASH_REMATCH[2]}"
    elif [[ "$last_deliv" =~ MEASURED_DELIVERY[[:space:]]+([0-9]+)x([0-9]+) ]]; then
      deliv_w="${BASH_REMATCH[1]}"; deliv_h="${BASH_REMATCH[2]}"
    elif [[ "$last_deliv" =~ MEASURED_DELIVERY[[:space:]]+([0-9]+)x([0-9]+) ]]; then
      deliv_w="${BASH_REMATCH[1]}"; deliv_h="${BASH_REMATCH[2]}"
    fi
    # Older format: media: MEASURED_DELIVERY 960x540 bytes=
    if [[ -z "$deliv_w" ]] && [[ "$last_deliv" =~ ([0-9]{2,4})x([0-9]{2,4}) ]]; then
      deliv_w="${BASH_REMATCH[1]}"; deliv_h="${BASH_REMATCH[2]}"
    fi
    if grep -q 'delivery_basis=measured\|delivery_verified=1' <<<"$last_deliv"; then
      basis="measured"
    fi
  fi
  log "PARSED_DELIVERY ${deliv_w:-?}x${deliv_h:-?} basis=${basis:-unknown}"

  if [[ -z "${deliv_w}" || -z "${deliv_h}" ]]; then
    emit_precond "DELIVERY_UNMEASURED" "no MEASURED_DELIVERY WxH in daemon log — play a cast first; do not score glass on request alone"
  fi

  # Hard fail known wrong deliveries
  if [[ "$deliv_w" == "720" && "$deliv_h" == "404" ]]; then
    emit_precond "DELIVERY_BITRATE_KNEE" "delivered 720x404 — maxBR/WEAK_BITRATE below 2000 knee; not 540p"
  fi
  if [[ "$deliv_w" == "624" || "$deliv_h" == "480" ]]; then
    if [[ "$deliv_w"x"$deliv_h" == "624x480" ]]; then
      emit_precond "DELIVERY_LEGACY_480" "delivered 624x480 — daemon/fabric pair is still 480p path"
    fi
  fi
  if [[ "$deliv_w" == "320" && "$deliv_h" == "240" ]]; then
    emit_precond "DELIVERY_240" "delivered 320x240"
  fi
  if [[ "$deliv_w" == "720" && "$deliv_h" == "540" ]]; then
    emit_precond "DELIVERY_4x3_FIT" "delivered 720x540 — 4:3 source aspect fit, not full 960 width; use HD 16:9 asset"
  fi

  if [[ "$deliv_w" != "960" || "$deliv_h" != "540" ]]; then
    emit_precond "DELIVERY_NOT_540" "delivered ${deliv_w}x${deliv_h} want 960x540 (display after SPS crop). Fabric frozen at 960x540 will mis-scale → false D2/D3"
  fi
  log "OK measured delivery 960x540"

  # Optional ffprobe on STREAM_SAMPLE (authoritative body)
  if [[ -n "${STREAM_SAMPLE}" && "${SKIP_DELIVERY_FFPROBE}" != "1" ]]; then
    if [[ ! -f "${STREAM_SAMPLE}" ]]; then
      # try remote path
      set +e
      ssh_m "test -s '${STREAM_SAMPLE}'" 2>/dev/null
      local src=$?
      set -e
      if [[ "$src" -ne 0 ]]; then
        emit_precond "STREAM_SAMPLE" "STREAM_SAMPLE=${STREAM_SAMPLE} not a local or remote file"
      fi
      set +e
      local fp
      fp="$(ssh_m "ffprobe -v error -select_streams v:0 -show_entries stream=width,height,coded_width,coded_height,sample_aspect_ratio,profile,level -of default=nokey=0:noprint_wrappers=1 '${STREAM_SAMPLE}'" 2>/dev/null)"
      local frc=$?
      set -e
      report_rc "ffprobe_remote" "$frc" || emit_precond "FFPROBE" "remote ffprobe failed"
      log "ffprobe_remote:"
      log "$fp"
      printf '%s\n' "$fp" >"$EV_DIR/ffprobe_delivery.txt"
      _check_ffprobe_text "$fp"
    else
      need_cmd ffprobe
      set +e
      local fp
      fp="$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,coded_width,coded_height,sample_aspect_ratio,profile,level \
        -of default=nokey=0:noprint_wrappers=1 "${STREAM_SAMPLE}")"
      local frc=$?
      set -e
      report_rc "ffprobe_local" "$frc" || emit_precond "FFPROBE" "local ffprobe failed"
      log "ffprobe_local:"
      log "$fp"
      printf '%s\n' "$fp" >"$EV_DIR/ffprobe_delivery.txt"
      _check_ffprobe_text "$fp"
    fi
  else
    log "SKIP ffprobe body (set STREAM_SAMPLE to enforce; MEASURED_DELIVERY accepted)"
  fi

  printf '%s\n' "${deliv_w}x${deliv_h}" >"$EV_DIR/delivered_geom.txt"
}

_check_ffprobe_text() {
  local fp="$1"
  local w h cw ch
  w="$(grep -E '^width=' <<<"$fp" | head -1 | cut -d= -f2)"
  h="$(grep -E '^height=' <<<"$fp" | head -1 | cut -d= -f2)"
  cw="$(grep -E '^coded_width=' <<<"$fp" | head -1 | cut -d= -f2)"
  ch="$(grep -E '^coded_height=' <<<"$fp" | head -1 | cut -d= -f2)"
  log "ffprobe_parsed w=${w} h=${h} cw=${cw} ch=${ch}"
  if [[ "$w" != "960" || "$h" != "540" ]]; then
    emit_precond "FFPROBE_DISPLAY" "ffprobe display ${w}x${h} want 960x540"
  fi
  # ffprobe coded_* is post-crop (parent settled); expect 960x540 not 544.
  if [[ -n "$cw" && -n "$ch" && ( "$cw" != "960" || "$ch" != "540" ) ]]; then
    emit_precond "FFPROBE_CODED" "ffprobe coded ${cw}x${ch} want 960x540 (post-crop). 544 is SPS-only."
  fi
  log "OK ffprobe genuine 540p delivery"
}

# --- capture helpers ----------------------------------------------------------

capture_one() {
  local out="$1"
  say "CAPTURE $out"
  set +e
  "$CAPTURE" "$out"
  local crc=$?
  set -e
  report_rc "hdmi_capture_idle $(basename "$out")" "$crc"
  if [[ "$crc" -eq 1 ]]; then
    emit_unknown_grabber "hdmi_capture_idle rc=1 for $out"
  fi
  if [[ "$crc" -eq 2 ]]; then
    emit_precond "CAPTURE_USAGE" "hdmi_capture_idle usage error for $out"
  fi
  if [[ "$crc" -ne 0 ]]; then
    emit_precond "CAPTURE_RC" "hdmi_capture_idle unexpected rc=$crc for $out"
  fi
  if [[ ! -s "$out" ]]; then
    emit_unknown_grabber "empty capture $out"
  fi
}

score_pair() {
  local t0="$1" t1="$2" label="${3:-P1}"
  say "SCORE $label $t0 $t1"
  set +e
  local out
  out="$("$SCORE" "$t0" "$t1" 2>&1)"
  local src=$?
  set -e
  log "$out"
  report_rc "hdmi_score_pair_$label" "$src"
  if [[ "$src" -eq 3 ]]; then
    emit_unknown_grabber "score_pair rc=3"
  fi
  if [[ "$src" -eq 2 ]]; then
    emit_precond "SCORE_USAGE" "score_pair usage/shape rc=2"
  fi
  local verdict
  verdict="$(grep -E '^VERDICT=' <<<"$out" | tail -1 | cut -d= -f2-)"
  if [[ -z "${verdict}" ]]; then
    emit_precond "SCORE_NO_VERDICT" "score_pair produced no VERDICT line"
  fi
  log "${label}_VERDICT=${verdict}"
  printf '%s\n' "$out" >"$EV_DIR/score_${label}.txt"
  printf '%s\n' "$verdict" >"$EV_DIR/verdict_${label}.txt"
  # Export for caller
  LAST_VERDICT="$verdict"
  LAST_SCORE_RC="$src"
}

# --- contract phases ----------------------------------------------------------

phase_neg_control() {
  say "P0 NEG CONTROL (must not score A)"
  if [[ "$SKIP_NEG" == "1" ]]; then
    log "SKIP_NEG=1"
    return 0
  fi
  log "NOTE: NEG is meaningful on macros-OFF / control-class idle. If already in PLAYING cast, parent may SKIP_NEG=1 after a prior control snap."
  local f="$EV_DIR/play-neg-control.png"
  capture_one "$f"
  score_pair "$f" "$f" "NEG"
  case "$LAST_VERDICT" in
    A_FABRIC_PLAY_OK)
      emit_precond "NEG_FALSE_GREEN" "control/neg frame scored A — scorer or scene bug; refuse product PASS"
      ;;
    CONTROL_ARM_IDLE|C1_ARM_LETTERBOX|B3_IDLE|B2_STATIC_FULL_RASTER|UNSCORED|D2_UPSCALE_GEOM)
      log "OK NEG class=${LAST_VERDICT} (not A)"
      ;;
    E_NOSIGNAL)
      emit_precond "NEG_NOSIGNAL" "neg capture is no-signal — device/grabber, not fabric score"
      ;;
    *)
      log "OK NEG class=${LAST_VERDICT} (not A) — continuing"
      ;;
  esac
}

phase_p1_playing() {
  say "P1 PLAYING PAIR (1 s apart)"
  log "PRE-REG: cast known-motion 960x540 content; FAB_IDLE off; prefer PLAY_BEACON on this fit."
  local t0="$EV_DIR/play-t0.png"
  local t1="$EV_DIR/play-t1.png"
  capture_one "$t0"
  sleep 1
  capture_one "$t1"
  score_pair "$t0" "$t1" "P1"
  P1_VERDICT="$LAST_VERDICT"
}

phase_p2_arm_out() {
  say "P2 ARM-OUT FREEZE (kill PID only)"
  if [[ "$SKIP_P2" == "1" ]]; then
    log "SKIP_P2=1"
    return 0
  fi
  set +e
  local pid
  pid="$(ssh_m 'pidof misterplexd' 2>/dev/null | tr -d ' \r' | head -1)"
  local prc=$?
  set -e
  report_rc "pidof_before_kill" "$prc"
  if [[ -z "${pid:-}" ]]; then
    emit_precond "P2_NO_PID" "misterplexd not running at P2 — cannot run ARM-out arm"
  fi
  if [[ "$pid" == *" "* ]]; then
    emit_precond "P2_MULTI_PID" "multiple PIDs — refuse kill; n=1 required"
  fi
  log "P2_KILL_PID=${pid} (killall/pkill BANNED)"
  set +e
  ssh_m "kill ${pid}"
  local krc=$?
  set -e
  report_rc "kill_pid" "$krc" || emit_precond "P2_KILL" "kill $pid failed"
  sleep 2
  # Confirm dead
  set +e
  local still
  still="$(ssh_m 'pidof misterplexd' 2>/dev/null | tr -d ' \r' || true)"
  set -e
  if [[ -n "${still:-}" ]]; then
    log "WARN: misterplexd still present after kill: $still"
  fi
  local t0="$EV_DIR/play-nodaemon-t0.png"
  local t1="$EV_DIR/play-nodaemon-t1.png"
  capture_one "$t0"
  sleep 1
  capture_one "$t1"
  score_pair "$t0" "$t1" "P2"
  P2_VERDICT="$LAST_VERDICT"
  case "$P2_VERDICT" in
    E_NOSIGNAL|B1_ONE_SHOT_THEN_DEAD)
      log "P2 present path died after ARM-out"
      log "P1_VERDICT=${P1_VERDICT:-} P2_VERDICT=${P2_VERDICT}"
      log "FINAL_VERDICT=B1_ONE_SHOT_THEN_DEAD"
      log "VERDICT=B1_ONE_SHOT_THEN_DEAD"
      exit 5
      ;;
  esac
  log "OK P2 class=${P2_VERDICT} (freeze expected; black is fail)"
}

finalize_verdict() {
  say "FINAL"
  local v="${P1_VERDICT:-UNKNOWN}"
  log "P1_VERDICT=${v}"
  log "P2_VERDICT=${P2_VERDICT:-skipped}"
  log "EV_DIR=${EV_DIR}"
  log "RAW_SCORE_P1:"
  if [[ -f "$EV_DIR/score_P1.txt" ]]; then
    cat "$EV_DIR/score_P1.txt" | tee -a "$LOG_BUNDLE" >/dev/null || cat "$EV_DIR/score_P1.txt"
  fi
  # One machine-readable line for parent grepping:
  # VERDICT=... P1=... P2=... LIVE_RBF=... DELIVERY=...
  local live deliv
  live="$(cat "$EV_DIR/live_rbf.md5" 2>/dev/null || echo na)"
  deliv="$(cat "$EV_DIR/delivered_geom.txt" 2>/dev/null || echo na)"
  log "SUMMARY VERDICT=${v} P1=${v} P2=${P2_VERDICT:-skipped} LIVE_RBF=${live} DELIVERY=${deliv} EV=${EV_DIR}"

  case "$v" in
    A_FABRIC_PLAY_OK)
      emit_scored "$v" 0
      ;;
    UNKNOWN_GRABBER)
      emit_unknown_grabber "finalize"
      ;;
    *)
      emit_scored "$v" 1
      ;;
  esac
}

# --- offline self-test (no device) --------------------------------------------

offline_selftest() {
  # Red-before-green for precondition paths + scorer wiring. No SSH to MiSTer.
  # Keep residue out of docs/agent-evidence (parent artifacts only).
  EV_DIR="${EV_DIR:-$ROOT/build/parent_playing_gate_offline}"
  rm -rf "$EV_DIR"
  ensure_ev
  say "OFFLINE SELFTEST"
  local fails=0
  local mock="$EV_DIR/mock_ssh.sh"
  cat >"$mock" <<'MOCK'
#!/usr/bin/env bash
# argv is remote command string(s)
cmd="$*"
case "$PLAYING_MOCK_PROFILE" in
  unreachable)
    exit 255
    ;;
  no540)
    case "$cmd" in
      *pidof*) echo "1234"; exit 0 ;;
      *readlink*) echo "/media/fat/misterplex/misterplexd"; exit 0 ;;
      *md5sum\ /proc*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  /proc/1234/exe"; exit 0 ;;
      *strings*) echo "480p"; echo "624x480"; exit 0 ;;
      *misterplex.conf*) echo "DECODE=624x480"; echo "OSD_CONTROL=on"; exit 0 ;;
      *misterplexd.log*) echo "content resolution=624x480 source=OSD O[4]"; exit 0 ;;
      *Plex.rbf*) echo "${MOCK_LIVE_MD5:-abcdef0102030405060708090a0b0c0d}  /media/fat/_Utility/Plex.rbf"; echo "c5382bee000000000000000000000000  /media/fat/_Utility/Plex_rel.rbf"; exit 0 ;;
      *video_mode*) echo "video_mode=0"; exit 0 ;;
      *uptime*|/proc/uptime) echo "12.0 48.0"; exit 0 ;;
      *pdma*) echo "driver -> dma-pl330"; echo "4"; exit 0 ;;
      *) echo "mock-default"; exit 0 ;;
    esac
    ;;
  good_pair_bad_delivery)
    case "$cmd" in
      *pidof*) echo "1234"; exit 0 ;;
      *readlink*) echo "/media/fat/misterplex/misterplexd"; exit 0 ;;
      *md5sum\ /proc*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  /proc/1234/exe"; exit 0 ;;
      *strings*) echo "540p"; echo "960x540"; exit 0 ;;
      *misterplex.conf*) echo "DECODE=960x540"; echo "OSD_CONTROL=off"; echo "WEAK_BITRATE=2000"; exit 0 ;;
      *misterplexd.log*)
        echo "misterplexd: DECODE adopted coded 960x540 from conf"
        echo "misterplexd: content resolution=960x540 source=conf/--decode weak=960x540 bitrate=2000"
        echo "misterplexd: GEOM requested_pms=960x540 decode_target=960x540"
        echo "media: MEASURED_DELIVERY 720x404 bytes=436800 delivery_verified=1"
        exit 0
        ;;
      *Plex.rbf*) echo "${MOCK_LIVE_MD5:-abcdef0102030405060708090a0b0c0d}  /media/fat/_Utility/Plex.rbf"; echo "c5382bee000000000000000000000000  /media/fat/_Utility/Plex_rel.rbf"; exit 0 ;;
      *video_mode*) echo "video_mode=0"; exit 0 ;;
      *uptime*|/proc/uptime) echo "12.0 48.0"; exit 0 ;;
      *pdma*) echo "driver -> dma-pl330"; echo "4"; exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  good_all)
    case "$cmd" in
      *pidof*) echo "1234"; exit 0 ;;
      *readlink*) echo "/media/fat/misterplex/misterplexd"; exit 0 ;;
      *md5sum\ /proc*) echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  /proc/1234/exe"; exit 0 ;;
      *strings*) echo "540p"; echo "960x540"; exit 0 ;;
      *misterplex.conf*) echo "DECODE=960x540"; echo "OSD_CONTROL=off"; echo "WEAK_BITRATE=2000"; exit 0 ;;
      *misterplexd.log*)
        echo "misterplexd: DECODE adopted coded 960x540 from conf"
        echo "misterplexd: content resolution=960x540 source=conf/--decode weak=960x540 bitrate=2000"
        echo "misterplexd: GEOM requested_pms=960x540 decode_target=960x540"
        echo "media: MEASURED_DELIVERY 960x540 bytes=777600 delivery_verified=1 delivery_basis=measured"
        exit 0
        ;;
      *Plex.rbf*) echo "${MOCK_LIVE_MD5:-abcdef0102030405060708090a0b0c0d}  /media/fat/_Utility/Plex.rbf"; echo "c5382bee000000000000000000000000  /media/fat/_Utility/Plex_rel.rbf"; exit 0 ;;
      *video_mode*) echo "video_mode=0"; exit 0 ;;
      *uptime*|/proc/uptime) echo "12.0 48.0"; exit 0 ;;
      *pdma*) echo "driver -> dma-pl330"; echo "4"; exit 0 ;;
      *kill*) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
esac
exit 0
MOCK
  chmod +x "$mock"

  run_case() {
    local name="$1" profile="$2" expect_rc="$3" expect_grep="$4"
    shift 4 || true
    local ed="$EV_DIR/case-$name"
    mkdir -p "$ed"
    set +e
    env PLAYING_GATE_SSH="$mock" PLAYING_MOCK_PROFILE="$profile" \
      MOCK_LIVE_MD5="abcdef0102030405060708090a0b0c0d" \
      EXPECT_RBF_MD5="abcdef01" BASELINE_RBF_MD5="c5382bee" \
      EV_DIR="$ed" SKIP_NEG=1 SKIP_P2=1 \
      HDMI_DEV="/dev/null/no-such-grabber-for-offline" \
      bash "$0" preflight-device >"$ed/out.txt" 2>&1
    local rc=$?
    set -e
    if [[ "$rc" -ne "$expect_rc" ]]; then
      echo "FAIL $name: want rc=$expect_rc got rc=$rc" >&2
      cat "$ed/out.txt" >&2 || true
      fails=$((fails + 1))
      return
    fi
    if ! grep -qE "$expect_grep" "$ed/out.txt"; then
      echo "FAIL $name: want grep /$expect_grep/" >&2
      cat "$ed/out.txt" >&2 || true
      fails=$((fails + 1))
      return
    fi
    # Must not claim fabric A/B/C on precond fail
    if [[ "$expect_rc" -eq 4 ]] && grep -qE 'VERDICT=A_|VERDICT=B|VERDICT=C|VERDICT=D' "$ed/out.txt"; then
      echo "FAIL $name: precond path emitted fabric taxonomy" >&2
      fails=$((fails + 1))
      return
    fi
    echo "OK $name rc=$rc"
  }

  run_case "no540_binary" no540 4 'PRECOND_.*DAEMON_NO_540|PRECOND_FAIL id=DAEMON_NO_540'
  run_case "bad_delivery_720x404" good_pair_bad_delivery 4 'DELIVERY_BITRATE_KNEE|DELIVERY_NOT_540|720x404'
  run_case "good_preflight" good_all 0 'OK measured delivery 960x540|preflight OK'

  # Grabber unknown path
  set +e
  env EV_DIR="$EV_DIR/grab" bash "$SCORE" --grabber-not-ready >"$EV_DIR/grab_out.txt" 2>&1
  local grc=$?
  set -e
  if [[ "$grc" -ne 3 ]] || ! grep -q 'UNKNOWN_GRABBER' "$EV_DIR/grab_out.txt"; then
    echo "FAIL grabber path rc=$grc" >&2
    fails=$((fails + 1))
  else
    echo "OK grabber unknown rc=3"
  fi

  # Real held frames must not score A on control
  if [[ -f "$ROOT/docs/agent-evidence/ctrl720_arm.png" ]]; then
    set +e
    out="$("$SCORE" "$ROOT/docs/agent-evidence/ctrl720_arm.png" "$ROOT/docs/agent-evidence/ctrl720_arm.png" 2>&1)"
    src=$?
    set -e
    echo "$out"
    if grep -q 'VERDICT=A_' <<<"$out"; then
      echo "FAIL control scored A" >&2
      fails=$((fails + 1))
    else
      echo "OK control not A (rc=$src)"
    fi
  fi

  if [[ "$fails" -ne 0 ]]; then
    echo "OFFLINE_SELFTEST_FAIL fails=$fails" >&2
    exit 1
  fi
  echo "OFFLINE_SELFTEST_OK"
  exit 0
}

# --- preflight-device (used by offline + live) --------------------------------

preflight_device() {
  ensure_ev
  phase_local_tools
  phase_device_reachable
  phase_dma_and_baseline
  phase_video_mode
  # Grabber check only if device node looks real (skip in pure mock without node)
  if [[ -e "${HDMI_DEV:-/dev/video0}" ]]; then
    phase_grabber_free
  else
    log "SKIP grabber node check (no ${HDMI_DEV:-/dev/video0}) — live full run will require it"
  fi
  phase_daemon_540_pair
  phase_delivered_geometry
  log "preflight OK — pair and delivery hold; safe to score glass"
}

# --- arg parse ----------------------------------------------------------------

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ge 1 ]]; then
  case "$1" in
    preflight|preflight-device|neg|p1|p2|full|score-only|offline-selftest)
      MODE="$1"
      shift
      ;;
    *)
      ;;
  esac
fi

if [[ "$MODE" == "score-only" ]]; then
  SCORE_T0="${1:?score-only needs T0.png}"
  SCORE_T1="${2:?score-only needs T1.png}"
fi

P1_VERDICT=""
P2_VERDICT=""
LAST_VERDICT=""
LAST_SCORE_RC=0

case "$MODE" in
  offline-selftest)
    ensure_ev
    offline_selftest
    ;;
  score-only)
    ensure_ev
    phase_local_tools
    score_pair "$SCORE_T0" "$SCORE_T1" "P1"
    P1_VERDICT="$LAST_VERDICT"
    finalize_verdict
    ;;
  preflight|preflight-device)
    preflight_device
    exit 0
    ;;
  neg)
    ensure_ev
    phase_local_tools
    phase_grabber_free
    phase_neg_control
    exit 0
    ;;
  p1)
    ensure_ev
    preflight_device
    phase_grabber_free
    phase_p1_playing
    finalize_verdict
    ;;
  p2)
    ensure_ev
    phase_local_tools
    phase_grabber_free
    phase_p2_arm_out
    exit 0
    ;;
  full)
    ensure_ev
    preflight_device
    phase_grabber_free
    phase_neg_control
    phase_p1_playing
    phase_p2_arm_out
    finalize_verdict
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
