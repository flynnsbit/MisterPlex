#!/usr/bin/env bash
# prove_baseline_levers.sh — is ANY request lever able to force baseline bitstream?
# Subjects: rk=118 (high/CABAC), rk=119 (main/B-frames). Delivered ffprobe only.
# Token via curl -K mode-0600; never printed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/docs/evidence/p720-path-20260803/baseline_lever_matrix}"
BASE="${PLEX_BASE:-http://127.0.0.1:32400}"
BASE="${BASE%/}"
TOKEN_FILE="${PLEX_TOKEN_FILE:-$ROOT/docs/evidence/p720-path-20260803/baseline_pin_measure/.token}"
FFPROBE_BIN="${FFPROBE:-ffprobe}"
FFMPEG_BIN="${FFMPEG:-ffmpeg}"
SECONDS_N="${SECONDS:-4}"

if [[ ! -r "$TOKEN_FILE" ]]; then
  echo "SKIP-NOT-PASS missing PLEX_TOKEN_FILE" >&2
  echo "true rc=77"; exit 77
fi
TOKEN="$(tr -d '\r\n' <"$TOKEN_FILE")"
[[ -n "$TOKEN" ]] || { echo "SKIP-NOT-PASS empty token"; echo "true rc=77"; exit 77; }

mkdir -p "$OUT/runs"
SESSION="blv-$(date -u +%Y%m%dT%H%M%SZ)-$$"
CURL_CFG="$OUT/runs/curl.cfg"
umask 077
{
  echo "header = \"X-Plex-Token: ${TOKEN}\""
  echo "header = \"X-Plex-Product: Plex Web\""
  echo "header = \"X-Plex-Version: 4.125.0\""
  echo "header = \"X-Plex-Platform: Chrome\""
  echo "header = \"X-Plex-Device: Linux\""
  echo "header = \"X-Plex-Client-Identifier: misterplex-baseline-levers\""
} >"$CURL_CFG"
chmod 600 "$CURL_CFG"
unset TOKEN

SUMMARY="$OUT/summary.tsv"
echo -e "rk\tlever\tpred\tdec_prof\tdec_decision\tdeliv_prof\thas_b\tentropy\twh\tbytes\tcurl_rc\tff_rc\tmatch_pred" >"$SUMMARY"

# Pre-registered predictions (parent miss pattern: publish hits/misses)
# All predicted PIN_IGNORED (High or Main still) unless noted.
declare -A PRED
PRED[L0_http_match]="PIN_IGNORED"
PRED[L1_http_isRequired]="PIN_IGNORED"
PRED[L2_hls_isRequired]="PIN_IGNORED"
PRED[L3_chrome_profile_name]="PIN_IGNORED"
PRED[L4_target_settings]="PIN_IGNORED"
PRED[L5_videoDecoders_only]="PIN_IGNORED"
PRED[L6_no_pin_control]="PIN_IGNORED"

extra_for() {
  local lever="$1" proto="$2"
  case "$lever" in
    L0_http_match)
      printf '%s' "add-transcode-target(type=videoProfile&context=streaming&protocol=${proto}&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)+add-limitation(scope=videoCodec&scopeName=h264&type=match&name=video.profile&list=baseline&replace=true)+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.level&value=31&replace=true)"
      ;;
    L1_http_isRequired)
      printf '%s' "add-transcode-target(type=videoProfile&context=streaming&protocol=${proto}&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)+add-limitation(scope=videoCodec&scopeName=h264&type=match&name=video.profile&list=baseline&isRequired=true&replace=true)+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.level&value=31&isRequired=true&replace=true)+add-limitation(scope=videoTranscodeTarget&scopeName=h264&scopeType=videoCodec&context=streaming&protocol=${proto}&type=match&name=video.profile&list=baseline&isRequired=true)"
      ;;
    L2_hls_isRequired)
      printf '%s' "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)+add-limitation(scope=videoCodec&scopeName=h264&type=match&name=video.profile&list=baseline&isRequired=true&replace=true)+add-limitation(scope=videoTranscodeTarget&scopeName=h264&scopeType=videoCodec&context=streaming&protocol=hls&type=match&name=video.profile&list=baseline&isRequired=true)"
      ;;
    L3_chrome_profile_name)
      # Extra still pins; Client-Profile-Name set via curl header override below
      printf '%s' "add-transcode-target(type=videoProfile&context=streaming&protocol=${proto}&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)+add-limitation(scope=videoCodec&scopeName=h264&type=match&name=video.profile&list=baseline&isRequired=true&replace=true)"
      ;;
    L4_target_settings)
      printf '%s' "add-transcode-target(type=videoProfile&context=streaming&protocol=${proto}&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)+add-transcode-target-settings(type=videoProfile&context=streaming&protocol=${proto}&videoCodec=h264&audioCodec=aac)+add-limitation(scope=videoCodec&scopeName=h264&type=match&name=video.profile&list=baseline&isRequired=true&replace=true)"
      ;;
    L5_videoDecoders_only)
      # No match limitation — only videoDecoders style via query videoProfile=
      printf '%s' "add-transcode-target(type=videoProfile&context=streaming&protocol=${proto}&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)"
      ;;
    L6_no_pin_control)
      printf '%s' ""
      ;;
    *) printf '%s' ""; ;;
  esac
}

detect_entropy() {
  local sample="$1" tr="$2"
  local ent="unknown"
  set +e
  "$FFMPEG_BIN" -hide_banner -nostdin -loglevel trace -i "$sample" -t 0.4 -c copy -f null - 2>"$tr"
  set -e
  if grep -q 'entropy_coding_mode_flag: 1' "$tr" 2>/dev/null; then ent="cabac"
  elif grep -q 'entropy_coding_mode_flag: 0' "$tr" 2>/dev/null; then ent="cavlc"
  elif grep -qi 'entropy_coding_mode_flag=1' "$tr" 2>/dev/null; then ent="cabac"
  elif grep -qi 'entropy_coding_mode_flag=0' "$tr" 2>/dev/null; then ent="cavlc"
  fi
  echo "$ent"
}

run_one() {
  local rk="$1" lever="$2"
  local pred="${PRED[$lever]}"
  local work="$OUT/runs/rk${rk}_${lever}"
  mkdir -p "$work"
  local proto="http"
  [[ "$lever" == L2_hls_isRequired ]] && proto="hls"
  local extra; extra="$(extra_for "$lever" "$proto")"
  local path_enc="%2Flibrary%2Fmetadata%2F${rk}"
  local vres="624x480" br=4000
  local qcommon="hasMDE=1&path=${path_enc}&mediaIndex=0&partIndex=0&protocol=${proto}&fastSeek=1&directPlay=0&directStream=0&subtitleSize=100&audioBoost=100&location=lan&copyts=1&videoQuality=100&videoResolution=${vres}&maxVideoBitrate=${br}&videoCodec=h264&audioCodec=aac"
  if [[ "$lever" != L6_no_pin_control ]]; then
    qcommon+="&videoProfile=baseline&videoLevel=31"
  fi
  local sess="${SESSION}-rk${rk}-${lever}"
  local start_path="start.mp4"
  [[ "$proto" == "hls" ]] && start_path="start.m3u8"
  local url_nolog="${BASE}/video/:/transcode/universal/${start_path}?${qcommon}&session=${sess}"
  local dec_url="${BASE}/video/:/transcode/universal/decision?${qcommon}&session=${sess}-d"
  echo "=== rk=$rk lever=$lever pred=$pred proto=$proto ===" | tee "$work/run.txt"
  echo "url_nolog=$url_nolog" >>"$work/run.txt"

  local hdr_extra=()
  if [[ -n "$extra" ]]; then
    hdr_extra=(-H "X-Plex-Client-Profile-Extra: ${extra}")
  fi
  local hdr_name=(-H "X-Plex-Client-Profile-Name: MiSTerPlex")
  if [[ "$lever" == L3_chrome_profile_name ]]; then
    hdr_name=(-H "X-Plex-Client-Profile-Name: Chrome")
  fi

  local dec_rc=0
  set +e
  curl -sS -K "$CURL_CFG" "${hdr_name[@]}" "${hdr_extra[@]}" -o "$work/decision.xml" "$dec_url"
  dec_rc=$?
  set -e
  echo "decision_curl true rc=$dec_rc" | tee -a "$work/run.txt"

  python3 - "$work/decision.xml" "$work/decision_summary.txt" <<'PY'
import sys,re,pathlib
xml=pathlib.Path(sys.argv[1]).read_text(errors='replace') if pathlib.Path(sys.argv[1]).is_file() else ''
def a(name):
    m=re.search(rf'\b{name}="([^"]*)"', xml)
    return m.group(1) if m else ''
# prefer VideoStream-ish
prof=a('videoProfile') or ''
# stream profile
ms=re.findall(r'<Stream\b[^>]*>', xml)
for s in ms:
    if 'streamType="1"' in s or 'type="video"' in s or 'codec="h264"' in s.lower() or 'codec="mpeg4"' in s.lower() or True:
        m=re.search(r'\bprofile="([^"]*)"', s)
        if m: prof=m.group(1); break
dec=a('videoDecision') or a('decision')
wh=f"{a('width')}x{a('height')}"
pathlib.Path(sys.argv[2]).write_text(f"decision_profile={prof}\nvideoDecision={dec}\ncontainer={a('container')}\nwh={wh}\n")
print(f"decision_profile={prof} videoDecision={dec} container={a('container')} wh={wh}")
PY

  local sample="$work/sample.bin"
  local curl_rc=0
  set +e
  if [[ "$proto" == "hls" ]]; then
    # fetch playlist then first segment if present
    curl -sS -K "$CURL_CFG" "${hdr_name[@]}" "${hdr_extra[@]}" --max-time 15 -o "$work/start.m3u8" "$url_nolog"
    curl_rc=$?
    # try media playlist / first .ts absolute or relative
    python3 - "$work/start.m3u8" "$BASE" "$work/seg_url.txt" <<'PY'
import sys,re,pathlib
from urllib.parse import urljoin
text=pathlib.Path(sys.argv[1]).read_text(errors='replace') if pathlib.Path(sys.argv[1]).is_file() else ''
base=sys.argv[2]
# if master, pick first media playlist line
lines=[ln.strip() for ln in text.splitlines() if ln.strip() and not ln.startswith('#')]
url=''
if lines:
    url=lines[0]
    if not url.startswith('http'):
        # relative to plex base or start url dir — use as-is with base
        if url.startswith('/'):
            url=base+url
        else:
            url=base.rstrip('/')+'/'+url
pathlib.Path(sys.argv[3]).write_text(url)
print('seg_or_media='+url[:120])
PY
    local seg
    seg="$(cat "$work/seg_url.txt" 2>/dev/null || true)"
    if [[ -n "$seg" ]]; then
      # if media playlist, pull first ts
      if [[ "$seg" == *.m3u8* ]] || grep -q EXTINF "$work/start.m3u8" 2>/dev/null; then
        curl -sS -K "$CURL_CFG" "${hdr_name[@]}" "${hdr_extra[@]}" --max-time 15 -o "$work/media.m3u8" "$seg" || true
        python3 - "$work/media.m3u8" "$work/start.m3u8" "$BASE" "$seg" "$work/ts_url.txt" <<'PY'
import sys,pathlib
from urllib.parse import urljoin
cands=[]
for p in sys.argv[1:3]:
    t=pathlib.Path(p).read_text(errors='replace') if pathlib.Path(p).is_file() else ''
    for ln in t.splitlines():
        ln=ln.strip()
        if ln and not ln.startswith('#'):
            cands.append(ln)
base=sys.argv[3]; parent=sys.argv[4]
url=cands[0] if cands else ''
if url and not url.startswith('http'):
    if url.startswith('/'):
        url=base+url
    else:
        # join against parent playlist URL directory
        if '/' in parent:
            url=parent.rsplit('/',1)[0]+'/'+url
        else:
            url=base+'/'+url
pathlib.Path(sys.argv[5]).write_text(url)
print('ts='+(url[:140] if url else ''))
PY
        local ts
        ts="$(cat "$work/ts_url.txt" 2>/dev/null || true)"
        if [[ -n "$ts" ]]; then
          curl -sS -K "$CURL_CFG" "${hdr_name[@]}" "${hdr_extra[@]}" --max-time "$((SECONDS_N+10))" -o "$sample" "$ts"
          curl_rc=$?
        fi
      else
        curl -sS -K "$CURL_CFG" "${hdr_name[@]}" "${hdr_extra[@]}" --max-time "$((SECONDS_N+10))" -o "$sample" "$seg"
        curl_rc=$?
      fi
    fi
  else
    curl -sS -K "$CURL_CFG" "${hdr_name[@]}" "${hdr_extra[@]}" --max-time "$((SECONDS_N+10))" -o "$sample" "$url_nolog"
    curl_rc=$?
  fi
  set -e
  local bytes=0
  bytes=$(wc -c <"$sample" 2>/dev/null | tr -d ' ' || echo 0)
  echo "sample_curl true rc=$curl_rc bytes=$bytes" | tee -a "$work/run.txt"

  local deliv_prof="NO_DATA" has_b="NO_DATA" wh="NO_DATA" ent="NO_DATA" ff_rc=1
  if [[ -s "$sample" && "$bytes" -gt 2000 ]]; then
    set +e
    "$FFPROBE_BIN" -v error -select_streams v:0 \
      -show_entries stream=codec_name,profile,level,has_b_frames,width,height \
      -of default=nw=1 "$sample" >"$work/ffprobe.txt" 2>"$work/ffprobe.err"
    ff_rc=$?
    set -e
    echo "ffprobe true rc=$ff_rc" | tee -a "$work/run.txt"
    deliv_prof=$(awk -F= '/^profile=/{print $2; exit}' "$work/ffprobe.txt")
    has_b=$(awk -F= '/^has_b_frames=/{print $2; exit}' "$work/ffprobe.txt")
    local w h
    w=$(awk -F= '/^width=/{print $2; exit}' "$work/ffprobe.txt")
    h=$(awk -F= '/^height=/{print $2; exit}' "$work/ffprobe.txt")
    wh="${w}x${h}"
    ent="$(detect_entropy "$sample" "$work/trace.txt")"
  fi
  local dec_prof
  dec_prof=$(awk -F= '/^decision_profile=/{print $2; exit}' "$work/decision_summary.txt" 2>/dev/null || echo "")
  local dec_decision
  dec_decision=$(awk -F= '/^videoDecision=/{print $2; exit}' "$work/decision_summary.txt" 2>/dev/null || echo "")

  # Outcome: BASELINE_FORCED if deliv baseline-like and no B and cavlc
  local outcome="PIN_IGNORED"
  local pl
  pl=$(printf '%s' "$deliv_prof" | tr '[:upper:]' '[:lower:]')
  if [[ "$pl" == *baseline* && "$has_b" == "0" && ( "$ent" == "cavlc" || "$ent" == "cavlc_by_profile" ) ]]; then
    outcome="BASELINE_FORCED"
  elif [[ "$pl" == *baseline* ]]; then
    outcome="BASELINE_SOFT"
  fi
  local match="MISS"
  [[ "$outcome" == "$pred" || ( "$pred" == "PIN_IGNORED" && "$outcome" == "PIN_IGNORED" ) ]] && match="HIT"
  if [[ "$pred" == "PIN_IGNORED" && "$outcome" != "PIN_IGNORED" ]]; then match="MISS_PRED_IGNORED_WAS_FORCED"; fi
  if [[ "$pred" == "PIN_IGNORED" && "$outcome" == "PIN_IGNORED" ]]; then match="HIT"; fi

  echo -e "${rk}\t${lever}\t${pred}\t${dec_prof}\t${dec_decision}\t${deliv_prof}\t${has_b}\t${ent}\t${wh}\t${bytes}\t${curl_rc}\t${ff_rc}\t${match}" | tee -a "$SUMMARY"
  {
    echo "outcome=$outcome"
    echo "match_pred=$match"
    echo "deliv_prof=$deliv_prof has_b=$has_b entropy=$ent wh=$wh"
  } >>"$work/run.txt"
}

echo "PREDICTIONS: all levers PIN_IGNORED on rk118/119 (parent: bare pin ignored; isRequired also miss)" | tee "$OUT/predictions.txt"

for rk in 118 119; do
  for lever in L0_http_match L1_http_isRequired L2_hls_isRequired L3_chrome_profile_name L4_target_settings L5_videoDecoders_only L6_no_pin_control; do
    run_one "$rk" "$lever" || echo -e "${rk}\t${lever}\tERR\t\t\t\t\t\t\t\t\t\tFAIL_RUN" | tee -a "$SUMMARY"
  done
done

# Hit rate
python3 - "$SUMMARY" "$OUT/REPORT.md" <<'PY'
import sys,pathlib
lines=pathlib.Path(sys.argv[1]).read_text().strip().splitlines()
rows=[ln.split('\t') for ln in lines[1:] if ln.strip()]
hits=sum(1 for r in rows if r[-1]=='HIT')
forced=sum(1 for r in rows if 'baseline' in (r[5] or '').lower())
total=len(rows)
rep=[]
rep.append('# Baseline lever matrix (host PMS)')
rep.append('')
rep.append('## Pre-registered predictions')
rep.append('All levers → PIN_IGNORED (High/Main still) on rk=118 high and rk=119 main.')
rep.append('')
rep.append(f'## Results N={total} HIT={hits} MISS={total-hits} delivered_baseline_count={forced}')
rep.append('')
rep.append('| rk | lever | pred | dec_prof | deliv_prof | has_b | entropy | wh | match |')
rep.append('|---|---|---|---|---|---|---|---|---|')
for r in rows:
    while len(r)<13: r.append('')
    rep.append(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[5]} | {r[6]} | {r[7]} | {r[8]} | {r[12]} |")
rep.append('')
if forced==0:
    rep.append('## Verdict')
    rep.append('**No lever forced baseline.** PMS pin is advisory. Fabric-safe path = Direct Play of already-baseline sources + bitstream gate as route selector, not product hard-fail on High xcode.')
else:
    rep.append('## Verdict')
    rep.append('At least one lever forced baseline — see table.')
pathlib.Path(sys.argv[2]).write_text('\n'.join(rep)+'\n')
print('\n'.join(rep))
print(f'HIT_RATE={hits}/{total}')
PY

echo "true rc=0"
exit 0
