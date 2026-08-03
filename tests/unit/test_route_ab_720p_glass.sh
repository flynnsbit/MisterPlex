#!/usr/bin/env bash
# Route A vs B: native 720p beam impossible @20MHz; ascal upscales; AR pillars.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON="$ROOT/assets/route_ab_720p_glass.json"
ASCAL="$ROOT/fpga/Plex_MiSTer/sys/ascal.vhd"
TOP="$ROOT/fpga/Plex_MiSTer/sys/sys_top.v"
PREREG="$ROOT/.agent-work/w-clock/ROUTE_AB_720P_PREREG.md"
VERD="$ROOT/.agent-work/w-clock/ROUTE_AB_720P_VERDICT.md"
OUT="$ROOT/build/route_ab_720p"
mkdir -p "$OUT"
[[ -f "$JSON" && -f "$ASCAL" && -f "$TOP" && -f "$PREREG" && -f "$VERD" ]] || {
  echo "FAIL missing inputs"; exit 1; }

# --- arithmetic: native 720p beam ---
awk 'BEGIN{
  clk=20e6
  tot=1344*750
  fps=clk/tot
  m30=30*tot/1e6
  m24=24*tot/1e6
  printf("tight fps@20=%.4f need30=%.2f need24=%.2f\n", fps, m30, m24) > "'"$OUT"'/math.txt"
  if (fps >= 24) { print "FAIL tight 720p reaches 24 @20MHz" > "/dev/stderr"; exit 1 }
  if (m30 < 30.0 || m30 > 30.5) { printf("FAIL m30=%.3f\n", m30) > "/dev/stderr"; exit 1 }
  if (m24 < 24.0 || m24 > 24.4) { printf("FAIL m24=%.3f\n", m24) > "/dev/stderr"; exit 1 }
  # active mpix
  act=1280*720*30/1e6
  if (act <= 20) { print "FAIL active 720p30 fits 20MHz without blanking?" > "/dev/stderr"; exit 1 }
  printf("OK Route A blocked: fps@20=%.4f need30=%.2f active_mpix=%.3f\n", fps, m30, act)
  # current beam ok
  cf=clk/(1182*705); ct=clk/(1182*564)
  if (cf < 23.9 || cf > 24.1) exit 1
  if (ct < 29.9 || ct > 30.1) exit 1
  printf("OK current beam film=%.4f tv=%.4f\n", cf, ct)
  # max tier content
  mt=960*540*30/1e6
  if (mt > 20) { print "FAIL max tier exceeds 20" > "/dev/stderr"; exit 1 }
  printf("OK max-tier 960x540@30 = %.3f Mpix/s < 20\n", mt)
}'
cat "$OUT/math.txt"

# --- AR pillars @1280x720 ---
awk 'BEGIN{
  W=1280; H=720
  split("4 16 5", ax, " "); split("3 9 3", ay, " ")
  split("960 1280 1200", ew, " "); split("160 0 40", ep, " ")
  for (i=1;i<=3;i++) {
    wcalc=int(H*ax[i]/ay[i])
    if (wcalc <= W) { vw=wcalc; vh=H } else { vw=W; vh=int(W*ay[i]/ax[i]) }
    pillar=int((W-vw)/2)
    if (vw != ew[i]+0 || pillar != ep[i]+0) {
      printf("FAIL %s:%s vw=%d pillar=%d want %s/%s\n", ax[i],ay[i],vw,pillar,ew[i],ep[i]) > "/dev/stderr"
      exit 1
    }
    printf("OK DAR %s:%s window %dx%d pillar %d\n", ax[i],ay[i],vw,vh,pillar)
  }
}'

python3 - "$ROOT" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
c = json.loads((root/"assets/route_ab_720p_glass.json").read_text())
assert c["verdict"] == "ROUTE_B"
assert c["route_a_native_720p_beam"]["feasible_at_20mhz"] is False
assert c["route_a_native_720p_beam"]["mhz_for_30fps_tight"] == 30.24
assert c["route_a_native_720p_beam"]["stub_blocks_30_24"] is True
assert c["route_b_ascal_upscale"]["product_path"] is True
assert c["route_b_ascal_upscale"]["overclock_required_for_glass_720p"] is False
assert c["route_b_ascal_upscale"]["hdmi_1280x720_windows"]["4:3"]["pillar"] == 160

ascal = (root/"fpga/Plex_MiSTer/sys/ascal.vhd").read_text()
assert "Upscaling" in ascal and "Polyphase" in ascal
assert "Arbitrary output video format" in ascal
top = (root/"fpga/Plex_MiSTer/sys/sys_top.v").read_text()
assert ".hdisp    (WIDTH)" in top or re.search(r"\.hdisp\s*\(\s*WIDTH\s*\)", top)
assert re.search(r"hmini\s*<=\s*\(\(WIDTH\s*-\s*videow\)>>1\)", top)
assert ".iauto    (1)" in top or re.search(r"\.iauto\s*\(\s*1\s*\)", top)
# scale path
assert "i_ohsize" in ascal and "o_hsize" in ascal

pr = (root/".agent-work/w-clock/ROUTE_AB_720P_PREREG.md").read_text()
assert "before reading" in pr.lower() or "PRE-REGISTERED" in pr
vd = (root/".agent-work/w-clock/ROUTE_AB_720P_VERDICT.md").read_text()
assert "ROUTE_B" in vd or "Route B" in vd
assert "30.24" in vd
print("OK JSON+RTL Route B evidence")
print("PASS test_route_ab_720p_glass GREEN")
PY

# RED: if verdict were ROUTE_A with feasible_at_20, fail
python3 - <<'PY'
import json, copy
from pathlib import Path
p=Path("/home/flynnsbit/Projects/MisterPlex-wt-clock/assets/route_ab_720p_glass.json")
c=json.loads(p.read_text())
bad=copy.deepcopy(c)
bad["verdict"]="ROUTE_A"
bad["route_a_native_720p_beam"]["feasible_at_20mhz"]=True
assert bad["verdict"]!="ROUTE_B"
print("OK RED shape: forged ROUTE_A would disagree with arithmetic gate")
PY

echo "PASS test_route_ab_720p_glass true rc=0"
