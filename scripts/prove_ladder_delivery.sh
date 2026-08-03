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
#   ... prove_ladder_delivery.sh no-upscale # SD source asked 960x540 must NOT grow
#   ... prove_ladder_delivery.sh all
#
# Optional: OUT_DIR=docs/evidence/.../prove_ladder  FFMPEG=ffmpeg  SECONDS=6
# no-upscale: NO_UPSCALE_KEY (default /library/metadata/1), SOURCE_W/H (default 320/240)
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
Usage: scripts/prove_ladder_delivery.sh <540|360|720|540-trap|no-upscale|source-aware|align-check|all>

Env:
  PLEX_BASE          e.g. http://127.0.0.1:32400
  PLEX_KEY           e.g. /library/metadata/2  (HD 16:9 for 540/360/720 rungs)
  NO_UPSCALE_KEY     SD source key for no-upscale rung (default /library/metadata/1)
  SOURCE_W SOURCE_H  known source dims for no-upscale (default 320 240)
  SOURCE_AWARE_KEY   library key for source-aware identity rung
  SOURCE_AWARE_W/H   expected source dims (request = snap16(source))
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
  # Avoid matching codec tags like 0x001B (greedy first \d+x\d+ is wrong).
  local banner
  banner="$(grep -E 'Stream #0:.*Video:' "$ff_log" | head -1 || true)"
  echo "ffmpeg_banner=${banner:-NO-DATA}"

  local dw=0 dh=0
  if [[ -n "$banner" ]]; then
    # Prefer geometry after yuv420p…, WWWWxHHHH
    local wh
    wh="$(printf '%s\n' "$banner" | sed -n 's/.*yuv420p[^,]*, \([0-9][0-9]*x[0-9][0-9]*\).*/\1/p' | head -1)"
    if [[ -z "$wh" ]]; then
      wh="$(printf '%s\n' "$banner" | sed -n 's/.* \([1-9][0-9]\{1,4\}x[1-9][0-9]\{1,4\}\)[, [].*/\1/p' | head -1)"
    fi
    if [[ -n "$wh" ]]; then
      dw="${wh%%x*}"
      dh="${wh##*x}"
    fi
  fi
  dw="${dw:-0}"
  dh="${dh:-0}"
  local deliv_src="ffmpeg_banner"

  # Optional fps from banner tbr/fps
  local fps="NO-DATA"
  if [[ -n "$banner" ]]; then
    fps="$(printf '%s\n' "$banner" | sed -n 's/.*, \([0-9.][0-9.]*\) fps,.*/\1/p' | head -1)"
    fps="${fps:-NO-DATA}"
  fi

  # decision video attributes if present (secondary — not sole PASS)
  local dec_w="" dec_h=""
  if [[ -f "$work/decision.xml" ]]; then
    # Prefer Stream streamType="1" then any width/height
    dec_w="$(grep -oE 'streamType="1"[^>]*width="[0-9]+"|width="[0-9]+"[^>]*streamType="1"' "$work/decision.xml" \
      | head -1 | grep -oE 'width="[0-9]+"' | tr -dc '0-9' || true)"
    dec_h="$(grep -oE 'streamType="1"[^>]*height="[0-9]+"|height="[0-9]+"[^>]*streamType="1"' "$work/decision.xml" \
      | head -1 | grep -oE 'height="[0-9]+"' | tr -dc '0-9' || true)"
    if [[ -z "$dec_w" ]]; then
      dec_w="$(grep -oE 'width="[0-9]+"' "$work/decision.xml" | head -1 | tr -dc '0-9' || true)"
      dec_h="$(grep -oE 'height="[0-9]+"' "$work/decision.xml" | head -1 | tr -dc '0-9' || true)"
    fi
  fi
  # Banner miss but decision hit: still usable for no-upscale (log basis).
  if [[ "$dw" -eq 0 || "$dh" -eq 0 ]]; then
    if [[ -n "${dec_w:-}" && -n "${dec_h:-}" && "$dec_w" -gt 0 && "$dec_h" -gt 0 ]]; then
      dw="$dec_w"; dh="$dec_h"; deliv_src="decision_xml"
      echo "WARN $tag: banner WxH miss; using decision_xml ${dw}x${dh}"
    fi
  fi
  echo "delivered_src=${deliv_src}"

  printf 'RESULT tag=%s requested=%sx%s maxBR=%s delivered_banner=%sx%s decision_xml=%sx%s fps=%s decoded=%sx%s src=%s\n' \
    "$tag" "$rw" "$rh" "$br" "$dw" "$dh" "${dec_w:-?}" "${dec_h:-?}" "$fps" "$dw" "$dh" "$deliv_src"

  if [[ "$dw" -eq 0 || "$dh" -eq 0 ]]; then
    echo "FAIL $tag: no delivered geometry from ffmpeg_banner"
    return 1
  fi

  # w-mem rt_raw_ok: coded_w%16==0 and even height. Non-aligned delivery is a
  # hard FAIL (silent shear / geom_reject) — not a soft warn.
  local wmod hmod
  wmod=$(awk -v w="$dw" 'BEGIN{print w%16}')
  hmod=$(awk -v h="$dh" 'BEGIN{print h%2}')
  echo "fabric_align delivered=${dw}x${dh} w%16=${wmod} h%2=${hmod}"
  if [[ "$mode" != "trap540" && "$mode" != "no_upscale" && "$mode" != "expect_unaligned" ]]; then
    if [[ "$wmod" -ne 0 || "$hmod" -ne 0 ]]; then
      echo "FAIL $tag: FABRIC_ALIGN delivered ${dw}x${dh} (w%16=${wmod} h%2=${hmod}) — store rejects"
      echo "ERROR STORE_ALIGN_FAIL measured=${dw}x${dh}"
      return 1
    fi
    echo "PASS_ALIGN $tag: delivered ${dw}x${dh} fabric-store aligned"
  fi

  case "$mode" in
    match)
      if [[ "$dw" -eq "$ew" && "$dh" -eq "$eh" ]]; then
        echo "PASS $tag: delivered matches expect ${ew}x${eh} src=${deliv_src}"
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
    no_upscale)
      # ew/eh = SOURCE dims. Request rw/rh must be strictly larger on at least one axis.
      # PASS: delivered within source±2 (MB tweak) AND not equal to the upscale target.
      # FAIL: any content upscale (delivered > source+2) — contract guard if PMS ever upscales.
      local tol=2
      local max_w=$((ew + tol))
      local max_h=$((eh + tol))
      if [[ "$dw" -gt "$max_w" || "$dh" -gt "$max_h" ]]; then
        echo "FAIL $tag: PMS UPSCALE detected source=${ew}x${eh} delivered=${dw}x${dh} requested=${rw}x${rh} (tol=+${tol})"
        echo "ERROR NO_UPSCALE_CONTRACT_BROKEN measured=${dw}x${dh} source=${ew}x${eh}"
        return 1
      fi
      if [[ "$dw" -eq "$rw" && "$dh" -eq "$rh" && ( "$rw" -gt "$ew" || "$rh" -gt "$eh" ) ]]; then
        echo "FAIL $tag: delivered exact request ${rw}x${rh} from smaller source ${ew}x${eh} (upscale)"
        echo "ERROR NO_UPSCALE_CONTRACT_BROKEN measured=${dw}x${dh} source=${ew}x${eh}"
        return 1
      fi
      echo "PASS $tag: no-upscale held source=${ew}x${eh} requested=${rw}x${rh} delivered=${dw}x${dh} src=${deliv_src}"
      return 0
      ;;
    source_identity)
      # Request == source snap16; expect delivery match request (or source if PMS
      # refuses tiny downscale). Must be fabric-aligned (checked above).
      if [[ "$dw" -eq "$ew" && "$dh" -eq "$eh" ]]; then
        echo "PASS $tag: source-identity delivered ${dw}x${dh} == expect ${ew}x${eh}"
        return 0
      fi
      # Allow ±2 MB tweak on request target
      local dw_lo=$((ew - 2)) dh_lo=$((eh - 2))
      local dw_hi=$((ew + 2)) dh_hi=$((eh + 2))
      if [[ "$dw" -ge "$dw_lo" && "$dw" -le "$dw_hi" && "$dh" -ge "$dh_lo" && "$dh" -le "$dh_hi" ]]; then
        echo "PASS $tag: source-identity within MB tol delivered=${dw}x${dh} expect=${ew}x${eh}"
        return 0
      fi
      echo "FAIL $tag: source-identity delivered ${dw}x${dh} != expect ${ew}x${eh} (req ${rw}x${rh})"
      return 1
      ;;
    expect_unaligned)
      # Red twin: document a known unaligned delivery (e.g. native 426). PASS if unaligned.
      if [[ "$wmod" -ne 0 || "$hmod" -ne 0 ]]; then
        echo "PASS $tag: expect_unaligned measured=${dw}x${dh} (red twin for host pad path)"
        return 0
      fi
      echo "FAIL $tag: expected unaligned delivery but got aligned ${dw}x${dh}"
      return 1
      ;;
    *)
      echo "FAIL $tag: unknown mode $mode"
      return 1
      ;;
  esac
}

# snap W down to multiple of 16 (daemon selectSourceAwarePmsRequest)
snap16_down() {
  awk -v w="$1" 'BEGIN{ if (w<16) {print 16; exit} print w - (w%16) }'
}
even_floor() {
  awk -v h="$1" 'BEGIN{ if (h<2) {print 2; exit} print int(h/2)*2 }'
}

FAILS=0
run_one() {
  if ! probe_rung "$@"; then
    FAILS=$((FAILS + 1))
  fi
}

case "$RUNG" in
  540)
    # Product detail tier: ≥2000 knee, Extra fr=24 — requires HD source (PLEX_KEY)
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
  no-upscale)
    # Contract: PMS must not upscale. Default SD subject metadata/1 = 320x240.
    # Override with NO_UPSCALE_KEY + SOURCE_W/H. Does not use PLEX_KEY.
    PLEX_KEY="${NO_UPSCALE_KEY:-/library/metadata/1}"
    local_sw="${SOURCE_W:-320}"
    local_sh="${SOURCE_H:-240}"
    echo "no-upscale subject PLEX_KEY=${PLEX_KEY} SOURCE=${local_sw}x${local_sh}"
    # Ask 960x540 (larger than source) — must stay ≤ source±2
    run_one "no-upscale-540" 960 540 2000 31 0 "$local_sw" "$local_sh" no_upscale
    # Ask 640x360 (also larger) — same contract
    run_one "no-upscale-360" 640 360 1000 30 0 "$local_sw" "$local_sh" no_upscale
    ;;
  source-aware)
    # Identity request for a named source class (default majority 624x480).
    # Expect fabric-aligned delivery equal to snap16(source).
    PLEX_KEY="${SOURCE_AWARE_KEY:-/library/metadata/36}"
    local_sw="${SOURCE_AWARE_W:-624}"
    local_sh="${SOURCE_AWARE_H:-480}"
    local_rw="$(snap16_down "$local_sw")"
    local_rh="$(even_floor "$local_sh")"
    local_br=2000
    if [[ "$local_rh" -le 240 ]]; then local_br=500; fi
    if [[ "$local_rh" -le 360 && "$local_rh" -gt 240 ]]; then local_br=1000; fi
    echo "source-aware subject PLEX_KEY=${PLEX_KEY} SOURCE=${local_sw}x${local_sh} REQ=${local_rw}x${local_rh}"
    run_one "source-aware-${local_sw}x${local_sh}" "$local_rw" "$local_rh" "$local_br" 30 0 "$local_rw" "$local_rh" source_identity
    ;;
  align-check)
    # Survey classes: source-identity where possible; 426 native = unaligned red twin;
    # 426@416 and 426@432 measured for host pad policy.
    _saved_key="$PLEX_KEY"
    # 624x480 majority
    PLEX_KEY="/library/metadata/36"
    run_one "align-624x480" 624 480 2000 30 0 624 480 source_identity
    # 320x240
    PLEX_KEY="/library/metadata/53"
    run_one "align-320x240" 320 240 500 30 0 320 240 source_identity
    # 640x480
    PLEX_KEY="/library/metadata/41"
    run_one "align-640x480" 640 480 2000 30 0 640 480 source_identity
    # 704x396
    PLEX_KEY="/library/metadata/42"
    run_one "align-704x396" 704 396 2000 30 0 704 396 source_identity
    # 426 native unaligned (red twin — host pad required)
    PLEX_KEY="/library/metadata/69"
    run_one "align-426-native" 426 240 1000 30 0 426 240 expect_unaligned
    # 426 floor 416: measured deliv 416x234 (aligned). Expect WxH within MB AR tol on H.
    run_one "align-426-req416" 416 240 1000 30 0 416 234 source_identity
    # 432 ceil: measured still 426 unaligned — must FABRIC_ALIGN-fail (red twin)
    if probe_rung "align-426-req432" 432 240 1000 30 0 432 240 source_identity; then
      echo "FAIL align-426-req432: expected unaligned/keep-source, got PASS"
      FAILS=$((FAILS + 1))
    else
      echo "PASS align-426-req432: 432 request does not yield aligned delivery (expected)"
    fi
    # Bad AR-fit control: 624@640x360 must fail FABRIC_ALIGN (468x360)
    PLEX_KEY="/library/metadata/36"
    if probe_rung "align-bad-360-arfit" 640 360 1000 30 0 468 360 match; then
      echo "FAIL align-bad-360-arfit: expected STORE_ALIGN_FAIL on 468-class delivery"
      FAILS=$((FAILS + 1))
    else
      echo "PASS align-bad-360-arfit: non-aligned AR-fit rejected (expected)"
    fi
    PLEX_KEY="$_saved_key"
    ;;
  all)
    run_one "540" 960 540 2000 31 24 960 540 match
    run_one "360" 640 360 1000 30 0 640 360 match
    run_one "540-trap" 960 540 1500 31 0 720 404 trap540
    # Preserve HD PLEX_KEY for above; no-upscale switches key internally.
    _saved_key="$PLEX_KEY"
    PLEX_KEY="${NO_UPSCALE_KEY:-/library/metadata/1}"
    local_sw="${SOURCE_W:-320}"
    local_sh="${SOURCE_H:-240}"
    echo "no-upscale subject PLEX_KEY=${PLEX_KEY} SOURCE=${local_sw}x${local_sh}"
    run_one "no-upscale-540" 960 540 2000 31 0 "$local_sw" "$local_sh" no_upscale
    run_one "no-upscale-360" 640 360 1000 30 0 "$local_sw" "$local_sh" no_upscale
    # Majority source-aware identity
    PLEX_KEY="${SOURCE_AWARE_KEY:-/library/metadata/36}"
    run_one "source-aware-624x480" 624 480 2000 30 0 624 480 source_identity
    PLEX_KEY="$_saved_key"
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
