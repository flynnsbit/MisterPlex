#!/usr/bin/env bash
# prove_baseline_pin.sh — does PMS honour videoProfile=baseline on the *bitstream*?
#
# Evidence class: ffprobe on drained universal/start body (not decision XML alone).
# Modes:
#   force-xcode  directPlay=0 directStream=0 + profile Extra + videoProfile=baseline
#   prefer-direct directPlay=1 directStream=1 (original may pass through)
#
# Token: PLEX_TOKEN_FILE mode-0600 preferred. Never print token.
# Usage:
#   PLEX_BASE=http://127.0.0.1:32400 PLEX_TOKEN_FILE=... \
#     scripts/prove_baseline_pin.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/docs/evidence/p720-path-20260803/baseline_pin_measure}"
PICKS="${PICKS:-$OUT_DIR/picks.json}"
FFPROBE_BIN="${FFPROBE:-ffprobe}"
FFMPEG_BIN="${FFMPEG:-ffmpeg}"
SECONDS_N="${SECONDS:-5}"
PLEX_BASE="${PLEX_BASE:-http://127.0.0.1:32400}"

missing=()
[[ -n "$PLEX_BASE" ]] || missing+=("PLEX_BASE")
command -v curl >/dev/null || missing+=("curl")
command -v "$FFPROBE_BIN" >/dev/null || missing+=("ffprobe")
command -v python3 >/dev/null || missing+=("python3")
[[ -r "$PICKS" ]] || missing+=("PICKS=$PICKS")
if ((${#missing[@]})); then
  echo "SKIP-NOT-PASS prove_baseline_pin: missing ${missing[*]}" >&2
  echo "true rc=77"
  exit 77
fi

TOKEN=""
if [[ -n "${PLEX_TOKEN_FILE:-}" && -r "${PLEX_TOKEN_FILE}" ]]; then
  TOKEN="$(tr -d '\r\n' <"$PLEX_TOKEN_FILE")"
elif [[ -n "${PLEX_TOKEN:-}" ]]; then
  TOKEN="$PLEX_TOKEN"
else
  echo "SKIP-NOT-PASS prove_baseline_pin: set PLEX_TOKEN_FILE" >&2
  echo "true rc=77"
  exit 77
fi
[[ -n "$TOKEN" ]] || { echo "SKIP-NOT-PASS empty token"; echo "true rc=77"; exit 77; }

mkdir -p "$OUT_DIR/runs"
BASE="${PLEX_BASE%/}"
SESSION="bp-$(date -u +%Y%m%dT%H%M%SZ)-$$"
CURL_CFG="$OUT_DIR/runs/curl.cfg"
umask 077
{
  echo "header = \"X-Plex-Token: ${TOKEN}\""
  echo "header = \"X-Plex-Product: Plex Web\""
  echo "header = \"X-Plex-Version: 4.125.0\""
  echo "header = \"X-Plex-Platform: Chrome\""
  echo "header = \"X-Plex-Device: Linux\""
  echo "header = \"X-Plex-Device-Name: Chrome\""
  echo "header = \"X-Plex-Client-Identifier: misterplex-baseline-pin\""
  echo "header = \"X-Plex-Client-Profile-Name: MiSTerPlex\""
} >"$CURL_CFG"
chmod 600 "$CURL_CFG"

profile_extra() {
  local w="$1" h="$2" level="$3"
  local extra
  extra="add-transcode-target(type=videoProfile&context=streaming&protocol=http&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)"
  extra+="+add-limitation(scope=videoCodec&scopeName=h264&type=match&name=video.profile&list=baseline&replace=true)"
  extra+="+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.level&value=${level}&replace=true)"
  extra+="+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.width&value=${w}&replace=true)"
  extra+="+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.height&value=${h}&replace=true)"
  # Force profile on transcode target (daemon isRequired path)
  extra+="+add-limitation(scope=videoTranscodeTarget&scopeName=h264&scopeType=videoCodec&context=streaming&protocol=http&type=match&name=video.profile&list=baseline&isRequired=true)"
  printf '%s' "$extra"
}

# Probe entropy via SPS/PPS if possible: baseline => CAVLC by spec.
# Also try ffmpeg trace_headers for entropy_coding_mode_flag.
detect_entropy() {
  local sample="$1" out="$2"
  local ent="unknown"
  if [[ ! -s "$sample" ]]; then
    echo "$ent"
    return
  fi
  # Prefer PPS entropy_coding_mode_flag from trace_headers
  local tr
  tr="$out/trace_headers.txt"
  set +e
  "$FFMPEG_BIN" -hide_banner -nostdin -loglevel trace \
    -i "$sample" -t 0.5 -c copy -f null - 2>"$tr"
  set -e
  if grep -q 'entropy_coding_mode_flag: 1' "$tr" 2>/dev/null; then
    ent="cabac"
  elif grep -q 'entropy_coding_mode_flag: 0' "$tr" 2>/dev/null; then
    ent="cavlc"
  elif grep -qi 'entropy_coding_mode_flag=1' "$tr" 2>/dev/null; then
    ent="cabac"
  elif grep -qi 'entropy_coding_mode_flag=0' "$tr" 2>/dev/null; then
    ent="cavlc"
  fi
  # Fallback: profile name implies CAVLC for baseline
  if [[ "$ent" == "unknown" ]]; then
    local prof
    prof="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=profile \
      -of default=nw=1:nk=1 "$sample" 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]')"
    if [[ "$prof" == *baseline* ]]; then
      ent="cavlc_by_profile"
    elif [[ "$prof" == *high* || "$prof" == *main* ]]; then
      ent="likely_cabac_unconfirmed"
    fi
  fi
  echo "$ent"
}

probe_one() {
  local class="$1" rk="$2" src_w="$3" src_h="$4" src_prof="$5" mode="$6"
  local tag="${class}_rk${rk}_${mode}"
  local work="$OUT_DIR/runs/$tag"
  mkdir -p "$work"
  local rw="$src_w" rh="$src_h"
  # Request source geometry (product source-aware); clamp max box 960x540 for HD
  if [[ "$rw" -gt 960 ]]; then rw=960; fi
  if [[ "$rh" -gt 540 ]]; then rh=540; fi
  # even
  rw=$((rw - rw % 2)); rh=$((rh - rh % 2))
  local level=31 br=4000
  local extra
  extra="$(profile_extra "$rw" "$rh" "$level")"
  local path_enc
  path_enc="$(printf '%s' "/library/metadata/${rk}" | sed 's|/|%2F|g')"
  local dp=0 ds=0
  if [[ "$mode" == "prefer-direct" ]]; then
    dp=1; ds=1
  fi
  local vres="${rw}x${rh}"
  local url_nolog="${BASE}/video/:/transcode/universal/start.mp4?hasMDE=1&path=${path_enc}&mediaIndex=0&partIndex=0&protocol=http&fastSeek=1&directPlay=${dp}&directStream=${ds}&subtitleSize=100&audioBoost=100&location=lan&copyts=1&session=${SESSION}-${tag}&videoQuality=100&videoResolution=${vres}&maxVideoBitrate=${br}&videoCodec=h264&audioCodec=aac&videoProfile=baseline&videoLevel=${level}"
  local url="${url_nolog}&X-Plex-Token=${TOKEN}"
  local dec_url="${BASE}/video/:/transcode/universal/decision?hasMDE=1&path=${path_enc}&mediaIndex=0&partIndex=0&protocol=http&directPlay=${dp}&directStream=${ds}&session=${SESSION}-${tag}-d&videoQuality=100&videoResolution=${vres}&maxVideoBitrate=${br}&videoCodec=h264&audioCodec=aac&videoProfile=baseline&videoLevel=${level}"

  echo "=== $tag src=${src_w}x${src_h} src_prof=${src_prof} req=${vres} mode=${mode} ==="
  echo "url_nolog=${url_nolog}"

  local dec_rc=0
  curl -sS -K "$CURL_CFG" \
    -H "X-Plex-Client-Profile-Extra: ${extra}" \
    -o "$work/decision.xml" "$dec_url" || dec_rc=$?
  echo "decision_curl true rc=$dec_rc"

  # decision claims
  python3 - "$work/decision.xml" "$work/decision_summary.txt" <<'PY'
import sys,re,pathlib
xml=pathlib.Path(sys.argv[1]).read_text(errors='replace') if pathlib.Path(sys.argv[1]).is_file() else ''
out=pathlib.Path(sys.argv[2])
def attr(tag,name):
    m=re.search(rf'<{tag}\b[^>]*\b{name}="([^"]*)"', xml)
    return m.group(1) if m else ''
# VideoStream often nested
prof=attr('VideoStream','profile') or attr('Stream','profile') or attr('Media','videoProfile')
level=attr('VideoStream','level') or attr('Stream','level')
w=attr('VideoStream','width') or attr('Stream','width')
h=attr('VideoStream','height') or attr('Stream','height')
dec=attr('Media','videoDecision') or attr('Stream','decision') or ''
# general decision
m=re.search(r'videoDecision="([^"]*)"', xml)
if m: dec=m.group(1)
m=re.search(r'directPlayDecision="([^"]*)"', xml)
dp=m.group(1) if m else ''
lines=[f'decision_profile={prof}',f'decision_level={level}',f'decision_wh={w}x{h}',
       f'videoDecision={dec}',f'directPlayDecision={dp}',f'xml_bytes={len(xml)}']
out.write_text('\n'.join(lines)+'\n')
print('\n'.join(lines))
PY

  local sample="$work/sample.bin"
  local curl_rc=0
  set +e
  curl -sS -K "$CURL_CFG" \
    -H "X-Plex-Client-Profile-Extra: ${extra}" \
    --max-time "$((SECONDS_N + 10))" \
    -o "$sample" "$url"
  curl_rc=$?
  set -e
  local bytes=0
  bytes=$(wc -c <"$sample" 2>/dev/null || echo 0)
  echo "sample_curl true rc=$curl_rc bytes=$bytes"

  local probe_txt="$work/ffprobe.txt"
  local profile="NO_DATA" level_n="NO_DATA" has_b="NO_DATA" codec="NO_DATA" wh="NO_DATA"
  if [[ -s "$sample" && "$bytes" -gt 1000 ]]; then
    set +e
    "$FFPROBE_BIN" -v error -select_streams v:0 \
      -show_entries stream=codec_name,profile,level,has_b_frames,width,height \
      -of default=nw=1 "$sample" >"$probe_txt" 2>"$work/ffprobe.err"
    local prc=$?
    set -e
    echo "ffprobe true rc=$prc"
    profile=$(awk -F= '/^profile=/{print $2; exit}' "$probe_txt")
    level_n=$(awk -F= '/^level=/{print $2; exit}' "$probe_txt")
    has_b=$(awk -F= '/^has_b_frames=/{print $2; exit}' "$probe_txt")
    codec=$(awk -F= '/^codec_name=/{print $2; exit}' "$probe_txt")
    local pw ph
    pw=$(awk -F= '/^width=/{print $2; exit}' "$probe_txt")
    ph=$(awk -F= '/^height=/{print $2; exit}' "$probe_txt")
    wh="${pw}x${ph}"
  else
    echo "ffprobe SKIP empty sample" | tee "$probe_txt"
  fi
  local entropy
  entropy="$(detect_entropy "$sample" "$work")"
  echo "delivered profile=${profile:-?} level=${level_n:-?} has_b_frames=${has_b:-?} entropy=${entropy} wh=${wh} codec=${codec:-?}"

  # fabric-safe?
  local safe=0
  local pl
  pl=$(printf '%s' "${profile:-}" | tr '[:upper:]' '[:lower:]')
  if [[ "$pl" == *baseline* ]] && [[ "${has_b:-1}" == "0" ]] && [[ "$entropy" == cavlc* || "$entropy" == cavlc_by_profile ]]; then
    safe=1
  elif [[ "$pl" == *baseline* ]] && [[ "${has_b:-1}" == "0" ]]; then
    # baseline + no B ⇒ CAVLC by H.264; entropy tool may miss
    safe=1
    [[ "$entropy" == "unknown" ]] && entropy="cavlc_implied_baseline"
  fi

  # one-line TSV for rollup (no secrets)
  printf '%s\t%s\t%s\t%sx%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n' \
    "$class" "$rk" "$mode" "$src_w" "$src_h" "${src_prof:-?}" \
    "${profile:-NO_DATA}" "${level_n:-?}" "${has_b:-?}" "$entropy" "$wh" "$bytes" "$safe" \
    | tee -a "$OUT_DIR/runs/results.tsv"
}

# header
echo -e "class\trk\tmode\tsrc_wh\tsrc_prof\tdel_profile\tdel_level\thas_b\tentropy\tdel_wh\tbytes\tfabric_safe" \
  >"$OUT_DIR/runs/results.tsv"

# Iterate picks via python driver calling this shell's probe_one is awkward;
# expand picks to a simple list file.
python3 - "$PICKS" "$OUT_DIR/runs/jobs.txt" <<'PY'
import json,sys,pathlib
picks=json.loads(pathlib.Path(sys.argv[1]).read_text())
lines=[]
for p in picks:
    src_prof=(p.get('stream_profile') or p.get('media_profile') or '?').replace(' ','_')
    # force-xcode always; prefer-direct for high/main sources + one baseline control
    modes=['force-xcode']
    pl=src_prof.lower()
    if 'high' in pl or 'main' in pl or p.get('class','').startswith('high'):
        modes=['force-xcode','prefer-direct']
    # one baseline control with prefer-direct (first 624x480)
    lines.append((p['class'], p['rk'], p['w'], p['h'], src_prof, modes))
# add prefer-direct for first item of each class once
seen=set()
out=[]
for class_,rk,w,h,sp,modes in lines:
    for m in modes:
        out.append(f"{class_}\t{rk}\t{w}\t{h}\t{sp}\t{m}")
    if class_ not in seen and 'prefer-direct' not in modes:
        out.append(f"{class_}\t{rk}\t{w}\t{h}\t{sp}\tprefer-direct")
        seen.add(class_)
pathlib.Path(sys.argv[2]).write_text('\n'.join(out)+'\n')
print(f"jobs={len(out)}")
PY

while IFS=$'\t' read -r class rk w h sp mode; do
  [[ -n "$class" ]] || continue
  probe_one "$class" "$rk" "$w" "$h" "$sp" "$mode" || echo "WARN probe_one failed $class rk=$rk mode=$mode"
done <"$OUT_DIR/runs/jobs.txt"

# Rollup
python3 - "$OUT_DIR" <<'PY'
import pathlib, collections, json, sys
root=pathlib.Path(sys.argv[1])
rows=[]
for line in (root/'runs'/'results.tsv').read_text().splitlines()[1:]:
    if not line.strip(): continue
    p=line.split('\t')
    if len(p)<12: continue
    rows.append(dict(class_=p[0], rk=p[1], mode=p[2], src_wh=p[3], src_prof=p[4],
                     del_profile=p[5], del_level=p[6], has_b=p[7], entropy=p[8],
                     del_wh=p[9], bytes=p[10], fabric_safe=int(p[11])))

fx=[r for r in rows if r['mode']=='force-xcode' and r['del_profile']!='NO_DATA']
pd=[r for r in rows if r['mode']=='prefer-direct' and r['del_profile']!='NO_DATA']
n_fx=len(fx); ok_fx=sum(1 for r in fx if r['fabric_safe']==1)
n_pd=len(pd); ok_pd=sum(1 for r in pd if r['fabric_safe']==1)

def pct(a,b):
    return 0.0 if b==0 else 100.0*a/b

# library source hit rate from items.json
items=json.loads((root.parent/'library_source_survey'/'items.json').read_text())
src_ok=0
for it in items:
    pl=(it.get('stream_profile') or it.get('media_profile') or '').lower()
    if 'baseline' in pl:
        src_ok+=1
N=len(items)

lines=[]
lines.append('# Baseline profile pin — measured hit rate')
lines.append('')
lines.append(f'Library N={N}; source already constrained baseline: {src_ok}/{N} ({pct(src_ok,N):.1f}%)')
lines.append(f'force-xcode delivered fabric-safe: {ok_fx}/{n_fx} ({pct(ok_fx,n_fx):.1f}%)')
lines.append(f'prefer-direct delivered fabric-safe: {ok_pd}/{n_pd} ({pct(ok_pd,n_pd):.1f}%)')
lines.append('')
lines.append('## force-xcode rows')
for r in fx:
    lines.append(f"- {r['class']} rk={r['rk']} src={r['src_wh']} src_prof={r['src_prof']} → "
                 f"del={r['del_profile']} L={r['del_level']} B={r['has_b']} ent={r['entropy']} "
                 f"wh={r['del_wh']} safe={r['fabric_safe']}")
lines.append('')
lines.append('## prefer-direct rows')
for r in pd:
    lines.append(f"- {r['class']} rk={r['rk']} src={r['src_wh']} src_prof={r['src_prof']} → "
                 f"del={r['del_profile']} L={r['del_level']} B={r['has_b']} ent={r['entropy']} "
                 f"wh={r['del_wh']} safe={r['fabric_safe']}")
# High source special
high=[r for r in rows if 'high' in r['src_prof'].lower() or r['class'].startswith('high')]
lines.append('')
lines.append('## High/Main source pin behaviour')
if not high:
    lines.append('(no high/main in sample)')
for r in high:
    lines.append(f"- mode={r['mode']} rk={r['rk']} src_prof={r['src_prof']} → del={r['del_profile']} "
                 f"B={r['has_b']} ent={r['entropy']} safe={r['fabric_safe']}")

# Verdict
lines.append('')
lines.append('## Verdict')
if n_fx and ok_fx==n_fx:
    lines.append('PIN_HONOURED on force-xcode path (directPlay=0,directStream=0): all sampled deliveries baseline/no-B.')
elif n_fx and ok_fx>0:
    lines.append(f'PIN_PARTIAL force-xcode: {ok_fx}/{n_fx} fabric-safe. See rows for refusals.')
elif n_fx==0:
    lines.append('PIN_UNSCORED: no force-xcode samples with data.')
else:
    lines.append('PIN_IGNORED on force-xcode: zero fabric-safe deliveries — pin is advisory/ignored.')

# prefer-direct high
hi_pd=[r for r in high if r['mode']=='prefer-direct']
if hi_pd and any(r['fabric_safe']==0 for r in hi_pd):
    lines.append('DIRECT_PLAY_BYPASS: prefer-direct on High source returns non-baseline (pin does not rewrite original).')
if hi_pd and all(r['fabric_safe']==1 for r in hi_pd):
    lines.append('UNEXPECTED: prefer-direct High still baseline (check if source was mis-tagged).')

text='\n'.join(lines)+'\n'
(root/'REPORT.md').write_text(text)
print(text)
(root/'runs'/'summary.json').write_text(json.dumps({
    'library_n': N, 'source_baseline_n': src_ok,
    'force_xcode_n': n_fx, 'force_xcode_safe': ok_fx,
    'prefer_direct_n': n_pd, 'prefer_direct_safe': ok_pd,
    'rows': rows,
}, indent=2))
PY

echo "REPORT=$OUT_DIR/REPORT.md"
echo "true rc=0"
exit 0
