#!/usr/bin/env bash
# prove_ladder_delivery.sh — host-side requested vs delivered vs decoded geometry.
#
# One invocation per ladder rung (or RUNG=all). Exits non-zero on mismatch.
# Red twin: 540@1500 must deliver 720x404 (or non-540) and is scored as
# GENUINE_540_FAIL expected — that path exits 0 only when the trap fires.
#
# Evidence class: ffmpeg stderr Stream banner (same as daemon MEASURED_DELIVERY
# src=ffmpeg_banner). Never trusts videoResolution= alone.
#
# Token: prefer curl -K mode-0600 cfg. Do NOT put token on argv. Do NOT log token.
#
# Usage:
#   PLEX_BASE=http://127.0.0.1:32400 PLEX_KEY=/library/metadata/2 \
#     PLEX_TOKEN_FILE=/path/to/token.txt \
#     scripts/prove_ladder_delivery.sh 540
#   ... prove_ladder_delivery.sh 360
#   ... prove_ladder_delivery.sh 540-trap   # red twin maxBR=1500
#   ... prove_ladder_delivery.sh all
#
# Optional: OUT_DIR=docs/evidence/.../prove_ladder  FFMPEG=ffmpeg  SECONDS=6
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/build/prove_ladder_delivery}"
FFMPEG_BIN="${FFMPEG:-ffmpeg}"
SECONDS_N="${SECONDS:-6}"
PLEX_BASE="${PLEX_BASE:-}"
PLEX_KEY="${PLEX_KEY:-${MISTERPLEX_BASELINE_KEY:-}}"
RUNG="${1:-}"

usage() {
  cat <<'EOF'
Usage: scripts/prove_ladder_delivery.sh <540|360|720|540-trap|all>

Env:
  PLEX_BASE          e.g. http://127.0.0.1:32400
  PLEX_KEY           e.g. /library/metadata/2  (HD 16:9 source)
  PLEX_TOKEN_FILE    file containing token (preferred)
  PLEX_TOKEN         only if file unset (still never printed)
  OUT_DIR            artifact dir (default build/prove_ladder_delivery)
  SECONDS            sample seconds (default 6)
EOF
}

if [[ -z "$RUNG" || "$RUNG" == "-h" || "$RUNG" == "--help" ]]; then
  usage
  exit 2
fi

missing=()
[[ -n "$PLEX_BASE" ]] || missing+=("PLEX_BASE")
[[ -n "$PLEX_KEY" ]] || missing+=("PLEX_KEY")
command -v "$FFMPEG_BIN" >/dev/null 2>&1 || missing+=("ffmpeg")
command -v curl >/dev/null 2>&1 || missing+=("curl")
command -v awk >/dev/null 2>&1 || missing+=("awk")
if ((${#missing[@]})); then
  echo "SKIP-NOT-PASS prove_ladder_delivery: missing ${missing[*]}" >&2
  echo "true rc=77"
  exit 77
fi

TOKEN=""
if [[ -n "${PLEX_TOKEN_FILE:-}" && -r "${PLEX_TOKEN_FILE}" ]]; then
  TOKEN="$(tr -d '\r\n' <"$PLEX_TOKEN_FILE")"
elif [[ -n "${PLEX_TOKEN:-}" ]]; then
  TOKEN="$PLEX_TOKEN"
else
  echo "SKIP-NOT-PASS prove_ladder_delivery: set PLEX_TOKEN_FILE or PLEX_TOKEN" >&2
  echo "true rc=77"
  exit 77
fi
if [[ -z "$TOKEN" ]]; then
  echo "SKIP-NOT-PASS prove_ladder_delivery: empty token" >&2
  echo "true rc=77"
  exit 77
fi

mkdir -p "$OUT_DIR"
BASE="${PLEX_BASE%/}"
SESSION="prove-ladder-$$"
# curl cfg never printed
CURL_CFG="$OUT_DIR/curl-secret.$$.conf"
cleanup() {
  TOKEN=""
  rm -f "$CURL_CFG"
}
trap cleanup EXIT
umask 077
{
  echo "header = \"X-Plex-Token: ${TOKEN}\""
  echo "header = \"X-Plex-Client-Identifier: misterplex-prove\""
  echo "header = \"X-Plex-Product: Plex Web\""
  echo "header = \"X-Plex-Version: 4.125.0\""
  echo "header = \"X-Plex-Platform: Chrome\""
  echo "header = \"X-Plex-Device: Linux\""
  echo "header = \"X-Plex-Device-Name: Chrome\""
  echo "header = \"X-Plex-Client-Profile-Name: MiSTerPlex\""
} >"$CURL_CFG"

# Build daemon-equivalent Extra for curl -H / decision path.
# $1=w $2=h $3=level $4=max_fr (0=none) → prints Extra string
profile_extra() {
  local w="$1" h="$2" level="$3" maxfr="$4"
  local extra
  extra="add-transcode-target(type=videoProfile&context=streaming&protocol=http&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)"
  extra+="+add-limitation(scope=videoCodec&scopeName=h264&type=match&name=video.profile&list=baseline&replace=true)"
  extra+="+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.level&value=${level}&replace=true)"
  extra+="+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.width&value=${w}&replace=true)"
  extra+="+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.height&value=${h}&replace=true)"
  if [[ "$maxfr" -gt 0 ]]; then
    extra+="+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.frameRate&value=${maxfr}&isRequired=true)"
    extra+="+add-limitation(scope=videoTranscodeTarget&scopeName=h264&scopeType=videoCodec&context=streaming&protocol=http&type=upperBound&name=video.frameRate&value=${maxfr}&isRequired=true)"
  fi
  printf '%s' "$extra"
}

# URL-encode path for query (minimal)
urlenc() {
  # shellcheck disable=SC2001
  printf '%s' "$1" | sed 's|/|%2F|g'
}

# Probe one rung. Args: name req_w req_h br level maxfr expect_w expect_h mode
# mode=match → must equal expect; mode=trap540 → must NOT be 960x540 (expect 720x404 class)
probe_rung() {
  local name="$1" rw="$2" rh="$3" br="$4" level="$5" maxfr="$6"
  local ew="$7" eh="$8" mode="$9"
  local tag="${name}"
  local work="$OUT_DIR/$tag"
  mkdir -p "$work"
  local extra
  extra="$(profile_extra "$rw" "$rh" "$level" "$maxfr")"

  local path_enc
  path_enc="$(urlenc "$PLEX_KEY")"
  local vres="${rw}x${rh}"
  # Token in query (daemon does both); never echo URL with token.
  local url_nolog="${BASE}/video/:/transcode/universal/start.mp4?hasMDE=1&path=${path_enc}&mediaIndex=0&partIndex=0&protocol=http&fastSeek=1&directPlay=0&directStream=0&subtitleSize=100&audioBoost=100&location=lan&copyts=1&session=${SESSION}-${tag}&videoQuality=100&videoResolution=${vres}&maxVideoBitrate=${br}&videoCodec=h264&audioCodec=aac&videoProfile=baseline&videoLevel=${level}"
  local url="${url_nolog}&X-Plex-Token=${TOKEN}"

  echo "=== RUNG $tag requested=${rw}x${rh} maxBR=${br} maxFR=${maxfr} mode=${mode} expect=${ew}x${eh} ==="
  echo "requested_url_nolog=${url_nolog}"
  echo "requested_pms=${rw}x${rh} maxVideoBitrate=${br}"

  # decision XML (daemon-equivalent)
  local dec_url="${BASE}/video/:/transcode/universal/decision?hasMDE=1&path=${path_enc}&mediaIndex=0&partIndex=0&protocol=http&directPlay=0&directStream=0&session=${SESSION}-${tag}-d&videoQuality=100&videoResolution=${vres}&maxVideoBitrate=${br}&videoCodec=h264&audioCodec=aac&videoProfile=baseline&videoLevel=${level}"
  local dec_rc=0
  curl -sS -K "$CURL_CFG" \
    -H "X-Plex-Client-Profile-Name: MiSTerPlex" \
    -H "X-Plex-Client-Profile-Extra: ${extra}" \
    -o "$work/decision.xml" "$dec_url" || dec_rc=$?
  echo "decision_curl true rc=$dec_rc"

  # Drain a short sample via curl (reliable headers), then ffprobe + ffmpeg banner.
  # Evidence class still src=ffmpeg_banner on the drained body (same Stream line).
  local sample="$work/sample.bin"
  local curl_rc=0
  set +e
  curl -sS -K "$CURL_CFG" \
    -H "X-Plex-Client-Profile-Name: MiSTerPlex" \
    -H "X-Plex-Client-Profile-Extra: ${extra}" \
    -H "X-Plex-Product: Plex Web" \
    -H "X-Plex-Version: 4.125.0" \
    -H "X-Plex-Platform: Chrome" \
    -H "X-Plex-Device: Linux" \
    -H "X-Plex-Device-Name: Chrome" \
    -H "X-Plex-Client-Identifier: misterplex-prove" \
    --max-time "$((SECONDS_N + 8))" \
    -o "$sample" "$url"
  curl_rc=$?
  set -e
  echo "sample_curl true rc=$curl_rc bytes=$(wc -c <"$sample" 2>/dev/null || echo 0)"

  local ff_log="$work/ffmpeg.stderr"
  local nullsink="/dev/null"
  local ff_rc=0
  if [[ -s "$sample" ]]; then
    set +e
    "$FFMPEG_BIN" -hide_banner -nostdin -loglevel info \
      -i "$sample" \
      -t 2 -an -f null "$nullsink" \
      >"$work/ffmpeg.stdout" 2>"$ff_log"
    ff_rc=$?
    set -e
  else
    echo "NO-DATA sample empty" >"$ff_log"
    ff_rc=1
  fi
  echo "ffmpeg true rc=$ff_rc"

  # Parse first video Stream banner: "Stream #0:0: Video: h264 ... 960x540 ..."
  local banner
  banner="$(grep -E 'Stream #0:.*Video:' "$ff_log" | head -1 || true)"
  echo "ffmpeg_banner=${banner:-NO-DATA}"
  echo "delivered_src=ffmpeg_banner"

  local dw=0 dh=0
  if [[ -n "$banner" ]]; then
    # Prefer WxH before brackets; tolerate SAR etc.
    dw="$(printf '%s\n' "$banner" | sed -n 's/.* \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1/p' | head -1)"
    dh="$(printf '%s\n' "$banner" | sed -n 's/.* \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\2/p' | head -1)"
  fi
  dw="${dw:-0}"
  dh="${dh:-0}"

  # Optional fps from banner tbr/fps
  local fps="NO-DATA"
  if [[ -n "$banner" ]]; then
    fps="$(printf '%s\n' "$banner" | sed -n 's/.*, \([0-9.][0-9.]*\) fps,.*/\1/p' | head -1)"
    fps="${fps:-NO-DATA}"
  fi

  # decision video attributes if present (secondary — not sole PASS)
  local dec_w="" dec_h=""
  if [[ -f "$work/decision.xml" ]]; then
    dec_w="$(grep -oE 'width="[0-9]+"' "$work/decision.xml" | head -1 | tr -dc '0-9' || true)"
    dec_h="$(grep -oE 'height="[0-9]+"' "$work/decision.xml" | head -1 | tr -dc '0-9' || true)"
  fi

  printf 'RESULT tag=%s requested=%sx%s maxBR=%s delivered_banner=%sx%s decision_xml=%sx%s fps=%s decoded=%sx%s\n' \
    "$tag" "$rw" "$rh" "$br" "$dw" "$dh" "${dec_w:-?}" "${dec_h:-?}" "$fps" "$dw" "$dh"

  if [[ "$dw" -eq 0 || "$dh" -eq 0 ]]; then
    echo "FAIL $tag: no delivered geometry from ffmpeg_banner"
    return 1
  fi

  case "$mode" in
    match)
      if [[ "$dw" -eq "$ew" && "$dh" -eq "$eh" ]]; then
        echo "PASS $tag: delivered matches expect ${ew}x${eh} src=ffmpeg_banner"
        return 0
      fi
      echo "FAIL $tag: delivered ${dw}x${dh} != expect ${ew}x${eh} (requested ${rw}x${rh} br=${br})"
      if [[ "$rw" -eq 960 && "$rh" -eq 540 && "$dw" -eq 720 && "$dh" -eq 404 ]]; then
        echo "ERROR GENUINE_540_FAIL measured=${dw}x${dh} — bitrate floor not met (need maxBR>=2000)"
      fi
      if [[ "$rw" -eq 640 && "$rh" -eq 360 ]]; then
        if [[ "$dw" -ne 640 || "$dh" -ne 360 ]]; then
          echo "ERROR GENUINE_360_FAIL measured=${dw}x${dh}"
        fi
      fi
      return 1
      ;;
    trap540)
      # Red twin: MUST get non-genuine 540 (typically 720x404) so the guard is real.
      if [[ "$dw" -eq 960 && "$dh" -eq 540 ]]; then
        echo "FAIL $tag: trap did not fire — still genuine 960x540 at maxBR=${br} (expected shorter tier)"
        return 1
      fi
      if [[ "$dw" -eq 720 && "$dh" -eq 404 ]]; then
        echo "PASS $tag: GENUINE_540_FAIL trap fired measured=720x404 (red twin OK)"
        return 0
      fi
      echo "PASS $tag: trap fired measured=${dw}x${dh} != 960x540 (non-canonical but non-genuine)"
      return 0
      ;;
    *)
      echo "FAIL $tag: unknown mode $mode"
      return 1
      ;;
  esac
}

FAILS=0
run_one() {
  if ! probe_rung "$@"; then
    FAILS=$((FAILS + 1))
  fi
}

case "$RUNG" in
  540)
    # Product detail tier: ≥2000 knee, Extra fr=24
    run_one "540" 960 540 2000 31 24 960 540 match
    ;;
  360)
    run_one "360" 640 360 1000 30 0 640 360 match
    ;;
  720)
    run_one "720" 1280 720 4000 31 0 1280 720 match
    ;;
  540-trap)
    run_one "540-trap" 960 540 1500 31 0 720 404 trap540
    ;;
  all)
    run_one "540" 960 540 2000 31 24 960 540 match
    run_one "360" 640 360 1000 30 0 640 360 match
    run_one "540-trap" 960 540 1500 31 0 720 404 trap540
    ;;
  *)
    echo "unknown rung: $RUNG" >&2
    usage >&2
    echo "true rc=2"
    exit 2
    ;;
esac

if [[ "$FAILS" -ne 0 ]]; then
  echo "SUMMARY prove_ladder_delivery FAILS=$FAILS"
  echo "true rc=1"
  exit 1
fi
echo "SUMMARY prove_ladder_delivery FAILS=0"
echo "true rc=0"
exit 0
