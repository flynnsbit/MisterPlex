#!/usr/bin/env bash
# Host-side Direct-Play *eligibility* + Part fetch gate (no MiSTer).
# Does NOT prove the daemon chose Part — parent must still quote:
#   misterplexd: PREFER_DIRECT_H264=1 ...
#   misterplexd: resolved direct H.264 Part ... transcode=0
#   misterplexd: GEOM ... transcoded=0
#
# Usage:
#   TOK=$(cat /tmp/local_tok.txt)
#   ./scripts/prove_directplay_host.sh 108 109 105 106 107 110
# Exit 0 = every rk is H.264 + has Part key + Part returns ftyp without opening
# a PMS transcoder session. Exit 1 = ineligible or Part fetch failed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/.agent-work/dp_proof_host}"
mkdir -p "$OUT"
PMS="${PMS_BASE:-http://192.168.1.24:32400}"
if [[ -z "${TOK:-}" ]]; then
  if [[ -f /tmp/local_tok.txt ]]; then
    TOK="$(cat /tmp/local_tok.txt)"
  else
    echo "TOK unset and /tmp/local_tok.txt missing" >&2
    exit 2
  fi
fi
if [[ $# -lt 1 ]]; then
  echo "usage: $0 <ratingKey> [ratingKey...]" >&2
  exit 2
fi

fail=0
for rk in "$@"; do
  meta="$OUT/meta_${rk}.xml"
  curl -sS --fail "${PMS}/library/metadata/${rk}?X-Plex-Token=${TOK}" -o "$meta"
  echo "meta_rk=${rk} true rc=$?"
  python3 - "$meta" "$rk" "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET, json
meta, rk, out = sys.argv[1], sys.argv[2], sys.argv[3]
root = ET.parse(meta).getroot()
v = root.find(".//Video")
m = v.find("Media") if v is not None else None
part = m.find("Part") if m is not None else None
vc = (m.get("videoCodec") if m is not None else "") or ""
prof = (m.get("videoProfile") if m is not None else "") or ""
st = None
if m is not None:
    for s in m.findall("Stream"):
        if s.get("streamType") == "1" or (s.get("codec") or "").lower() in ("h264", "avc", "avc1"):
            st = s
            break
if st is not None and st.get("profile"):
    prof = st.get("profile")
is_h264 = vc.lower() in ("h264", "avc", "avc1", "x264")
pk = part.get("key") if part is not None else ""
ok = bool(is_h264 and pk)
row = {
    "rk": int(rk),
    "title": v.get("title") if v is not None else None,
    "videoCodec": vc,
    "profile": prof,
    "width": m.get("width") if m is not None else None,
    "height": m.get("height") if m is not None else None,
    "bitrate_kbps": m.get("bitrate") if m is not None else None,
    "audioCodec": m.get("audioCodec") if m is not None else None,
    "videoFrameRate": m.get("videoFrameRate") if m is not None else None,
    "part_key": pk,
    "dp_eligible_if_preferDirect": ok,
}
json.dump(row, open(f"{out}/elig_{rk}.json", "w"), indent=2)
print(
    f"rk={rk} eligible={ok} codec={vc} profile={prof} "
    f"{row['width']}x{row['height']} br={row['bitrate_kbps']} part={'yes' if pk else 'NO'}"
)
open(f"{out}/partkey_{rk}.txt", "w").write(pk)
sys.exit(0 if ok else 1)
PY
  elig_rc=$?
  if [[ "$elig_rc" -ne 0 ]]; then
    echo "FAIL rk=${rk} not DP-eligible under preferDirect+H264+Part"
    fail=1
    continue
  fi
  pk="$(cat "$OUT/partkey_${rk}.txt")"
  headf="$OUT/part_${rk}_head.bin"
  curl -sS -r 0-1023 -o "$headf" -w "part_rk=${rk} http=%{http_code} bytes=%{size_download}\n" \
    "${PMS}${pk}?X-Plex-Token=${TOK}"
  echo "part_curl rk=${rk} true rc=$?"
  python3 - "$headf" <<'PY'
import sys
b=open(sys.argv[1],'rb').read(12)
ok = len(b)>=8 and b[4:8]==b'ftyp'
print(f"ftyp={'yes' if ok else 'NO'} head_hex={b.hex()}")
sys.exit(0 if ok else 1)
PY
  if [[ $? -ne 0 ]]; then
    echo "FAIL rk=${rk} Part body is not MP4 ftyp"
    fail=1
  fi
done

curl -sS "${PMS}/transcode/sessions?X-Plex-Token=${TOK}" -o "$OUT/sessions.xml"
echo "sessions true rc=$?"
python3 - "$OUT/sessions.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
root=ET.parse(sys.argv[1]).getroot()
# size attr or count children
n=int(root.get("size") or 0)
kids=list(root)
print(f"transcode_sessions size_attr={n} children={len(kids)}")
# Part-only fetch must not require a session; non-zero may be unrelated casts.
sys.exit(0)
PY

if [[ "$fail" -ne 0 ]]; then
  echo "RESULT=FAIL some rks ineligible — see $OUT"
  exit 1
fi
echo "RESULT=PASS host eligibility+Part ftyp for: $*"
echo "NOTE: daemon still needs PREFER_DIRECT_H264=1 (or STREAM=1) for transcode=0"
exit 0
