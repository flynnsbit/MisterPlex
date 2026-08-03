#!/usr/bin/env bash
# test_glass_ledger_fixture.sh — host gate: glass ledger decodable via BAR contract
# after simulated present_core even-row cull + capture squash. NO device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$ROOT/scripts/gen_glass_ledger_fixture.py"
OUT="$ROOT/build/glass_ledger_fixture"
DUR="${GLASS_TEST_DURATION:-8}"
PASS=0
FAIL=0

mkdir -p "$OUT"
rm -rf "${OUT:?}/"*
mkdir -p "$OUT/frames" "$OUT/culled"

if [[ ! -f "$GEN" ]]; then echo "FAIL missing $GEN"; exit 1; fi

FIX="$OUT/glass_short.mp4"
set +e
python3 "$GEN" --out "$FIX" --duration "$DUR" >"$OUT/gen.log" 2>&1
grc=$?
set -e
echo "gen true_rc=$grc"
if [[ "$grc" -ne 0 ]]; then echo "FAIL gen"; tail -20 "$OUT/gen.log"; exit 1; fi
PASS=$((PASS + 1))
echo "PASS gen"

set +e
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,profile,has_b_frames,codec_name,duration \
  -of json "$FIX" >"$OUT/v.json" 2>"$OUT/v.err"
vrc=$?
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,sample_rate,channels \
  -of json "$FIX" >"$OUT/a.json" 2>"$OUT/a.err"
arc=$?
set -e
echo "ffprobe_v true_rc=$vrc ffprobe_a true_rc=$arc"
if [[ "$vrc" -ne 0 || "$arc" -ne 0 ]]; then echo "FAIL ffprobe"; exit 1; fi

set +e
python3 - <<PY
import json
from pathlib import Path
v=json.loads(Path("$OUT/v.json").read_text())["streams"][0]
a=json.loads(Path("$OUT/a.json").read_text())["streams"][0]
gt_frames=int(round(float("$DUR")*24))
errs=[]
if v.get("width")!=624 or v.get("height")!=480: errs.append(f"geom {v.get('width')}x{v.get('height')}")
if v.get("r_frame_rate")!="24/1": errs.append(f"r_frame_rate={v.get('r_frame_rate')}")
if v.get("avg_frame_rate")!="24/1": errs.append(f"avg_frame_rate={v.get('avg_frame_rate')}")
if v.get("profile")!="Constrained Baseline": errs.append(f"profile={v.get('profile')}")
if "has_b_frames" not in v or int(v["has_b_frames"]) != 0: errs.append(f"has_b_frames={v.get('has_b_frames')}")
if v.get("codec_name")!="h264": errs.append("not h264")
nb=int(v.get("nb_frames") or 0)
if nb!=gt_frames: errs.append(f"nb_frames={nb} ground_truth={gt_frames}")
if a.get("codec_name")!="aac": errs.append("audio not aac")
if str(a.get("sample_rate"))!="48000": errs.append(f"sr={a.get('sample_rate')}")
if errs:
    print("FAIL contract "+"; ".join(errs))
    raise SystemExit(2)
print(f"PASS contract 624x480 r=24/1 CB has_b=0 nb_frames={nb}==gt aac48k src=measured")
PY
crc=$?
set -e
echo "contract true_rc=$crc"
if [[ "$crc" -ne 0 ]]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi

set +e
ffmpeg -y -hide_banner -loglevel error -i "$FIX" -vsync 0 "$OUT/frames/f_%05d.png"
frc=$?
set -e
echo "extract true_rc=$frc"
if [[ "$frc" -ne 0 ]]; then echo "FAIL extract"; exit 1; fi

set +e
python3 - <<'PY'
import sys
from pathlib import Path
import numpy as np
from PIL import Image

sys.path.insert(0, "tools")
from glass_frame_id import decode_bars_from_rgb, simulate_capture_chain, DIGITS, format_text

root = Path("build/glass_ledger_fixture")
frames = sorted((root / "frames").glob("f_*.png"))
if len(frames) < 4:
    print(f"FAIL too few frames {len(frames)}")
    raise SystemExit(2)

idxs = list(range(min(24, len(frames))))
if len(frames) > 40:
    idxs += [len(frames)//2, len(frames)//2+1, len(frames)-2, len(frames)-1]
idxs = sorted(set(idxs))

ok = 0
bad = []
recovered = []
for i in idxs:
    src = np.array(Image.open(frames[i]).convert("RGB"))
    r = decode_bars_from_rgb(src)
    if not r.ok:
        cap = simulate_capture_chain(src)
        Image.fromarray(cap).save(root / "culled" / f"c_{i:05d}.png")
        r = decode_bars_from_rgb(cap)
    expect = i
    if not r.ok or r.n != expect:
        bad.append((i, f"status={r.status} n={r.n} expect={expect} reason={r.reason}"))
        continue
    ok += 1
    recovered.append(int(r.n))

print(f"bar_decode ok={ok} checked={len(idxs)} bad={len(bad)}")
for b in bad[:8]:
    print("  BAD", b)
if len(recovered) != len(set(recovered)):
    print("FAIL recovered n not unique")
    raise SystemExit(3)
if ok < len(idxs) or bad:
    print("FAIL countable")
    raise SystemExit(4)
assert len(format_text(2358).split("n=")[1].split()[0]) == DIGITS
print(f"PASS countable_bars recovered={recovered[:12]}...")
raise SystemExit(0)
PY
orc=$?
set -e
echo "bar_gate true_rc=$orc"
if [[ "$orc" -ne 0 ]]; then FAIL=$((FAIL+1)); echo "FAIL bar_gate"; else PASS=$((PASS+1)); echo "PASS bar_gate"; fi

set +e
ffmpeg -y -hide_banner -loglevel error -i "$FIX" -c:v copy -bsf:v h264_mp4toannexb -an -f h264 "$OUT/annex.264"
brc=$?
set -e
echo "annexb true_rc=$brc"
if [[ "$brc" -eq 0 && -f "$OUT/annex.264" ]]; then
  set +e
  python3 - <<'PY'
from pathlib import Path
data=Path("build/glass_ledger_fixture/annex.264").read_bytes()
i=0
found=None
while i+5 < len(data):
    if data[i:i+4]==b'\x00\x00\x00\x01':
        nal=data[i+4]; typ=nal & 0x1f; hdr=5
    elif data[i:i+3]==b'\x00\x00\x01':
        nal=data[i+3]; typ=nal & 0x1f; hdr=4
    else:
        i+=1; continue
    if typ==7 and i+hdr < len(data):
        profile_idc=data[i+hdr]
        print(f"SPS profile_idc={profile_idc} (expect 66) src=measured")
        found=profile_idc
        break
    i+=1
if found!=66:
    print(f"FAIL profile_idc={found}")
    raise SystemExit(5)
print("PASS profile_idc=66")
PY
  prc=$?
  set -e
  echo "sps true_rc=$prc"
  if [[ "$prc" -ne 0 ]]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
else
  echo "FAIL annexb extract"
  FAIL=$((FAIL + 1))
fi

echo "=== SUMMARY pass=$PASS fail=$FAIL ==="
if [[ "$FAIL" -ne 0 ]]; then
  echo "GLASS_LEDGER_FIXTURE_FAIL"
  exit 1
fi
echo "GLASS_LEDGER_FIXTURE_OK pass=$PASS"
exit 0
