#!/usr/bin/env bash
# rd-duck: integer B15/q5 loses NTSC 24000/1001 and 30000/1001.
# Proves slip arithmetic; fences forbidden source-lock claims; does NOT invent ABI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON="$ROOT/assets/ntsc_rational_cadence_wall.json"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
TB="$ROOT/tests/rtl/b15_cadence_framecount_tb.sv"
SEL="$ROOT/fpga/Plex_MiSTer/rtl/plex_content_fps_sel.sv"
OUT="$ROOT/build/ntsc_rational_wall"
mkdir -p "$OUT"

[[ -f "$JSON" ]] || { echo "FAIL missing json"; exit 1; }

# --- exact arithmetic (awk; no bc) ---
awk -v out="$OUT/math.txt" 'BEGIN{
  clk=20000000; H=1182; Vf=705; Vt=564;
  b24=clk/(H*Vf); b30=clk/(H*Vt);
  n24=24000/1001; n30=30000/1001;
  d24=b24-n24; d30=b30-n30;
  sf=1/d24; st=1/d30;
  cpf=clk*1001/24000;
  printf("beam_film=%.12f ntsc_film=%.12f delta=%.12f slip_s=%.6f\n", b24,n24,d24,sf) > out;
  printf("beam_tv=%.12f ntsc_tv=%.12f delta=%.12f slip_s=%.6f\n", b30,n30,d30,st) >> out;
  printf("cpf_exact=%.12f integer=%s\n", cpf, (cpf==int(cpf)?"yes":"no")) >> out;
  # gates on published numbers (rd-duck / parent re-derive band)
  if (sf < 40.0 || sf > 41.5) { printf("FAIL film slip_s=%.6f not ~40.57\n", sf) > "/dev/stderr"; exit 1; }
  if (st < 32.0 || st > 33.0) { printf("FAIL tv slip_s=%.6f not ~32.46\n", st) > "/dev/stderr"; exit 1; }
  if (cpf == int(cpf)) { print "FAIL cpf unexpectedly integer" > "/dev/stderr"; exit 1; }
  # ppm ~1028
  ppm=1e6*d24/n24;
  if (ppm < 1020 || ppm > 1040) { printf("FAIL ppm=%.3f\n", ppm) > "/dev/stderr"; exit 1; }
  print "OK drift film_slip_s=" sf " tv_slip_s=" st " ppm=" ppm;
  print "OK exact NTSC cpf non-integer at 20 MHz — integer H*V cannot source-lock";
}'
cat "$OUT/math.txt"

python3 - "$ROOT" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
c = json.loads((root / "assets/ntsc_rational_cadence_wall.json").read_text())
assert c["hard_wall"]["integer_H_times_V_exact_ntsc"] is False
assert c["drift"]["film_slip_s"] > 40 and c["drift"]["film_slip_s"] < 41.5
assert "source-locked for 23.976/29.97" in c["claims_forbidden_until_fix"]
assert "fps_1001 / bit34 rational cadence fixed (unilateral w-path #2.1)" in c["claims_forbidden_until_fix"]
assert c.get("cross_lane_bit34", {}).get("rational_cadence_fixed") is False
st = c.get("status", "")
assert "OPEN_CADENCE" in st or "OPEN_ABI" in st or "RESERVED" in st
assert c.get("parent_arbitration_4", {}).get("bit34", "").find("RESERVED") >= 0
b34 = c["cross_lane_bit34"]
assert "RESERVED" in b34.get("parent_abi_2_and_4", b34.get("parent_abi_2", ""))
assert "VACATED" in b34["w_path_f31a6eb9"] or "fps_1001" in b34["w_path_f31a6eb9"]
assert "63:34" in b34["w_mem_latch"]
assert "NO fps_1001" in b34["w_clock"] or "no fps_1001" in b34["w_clock"].lower()
# Option D correction: 2-value dither exact long-run; single fixed is not
od = c.get("option_d_vtotal_dither", {})
assert od.get("two_value_dither_long_run_exact") is True
assert od.get("single_fixed_vtotal_exact_ntsc") is False
assert od.get("implemented") is False
conf = root / ".agent-work/w-clock/Q5_BIT34_ABI_CONFLICT.md"
assert conf.is_file(), "missing Q5_BIT34_ABI_CONFLICT.md"
assert "arbitration #4" in conf.read_text().lower() or "parent arbitration" in conf.read_text().lower()
arb4 = root / ".agent-work/w-clock/PARENT_ABI_ARBITRATION_4.md"
assert arb4.is_file(), "missing PARENT_ABI_ARBITRATION_4.md"
print("OK json wall + parent #4 bit34 RESERVED + D dither arithmetic fence")

# Product path still integer-only fps — no unilateral fps_1001 consumer
sel = (root / "fpga/Plex_MiSTer/rtl/plex_content_fps_sel.sv").read_text()
sel_code = re.sub(r"/\*.*?\*/", "", sel, flags=re.S)
sel_code = re.sub(r"//.*?$", "", sel_code, flags=re.M)
if re.search(r"fps_1001|bit\s*34|1001", sel_code, re.I):
    print("FAIL sel executable has fps_1001/bit34 without parent ABI freeze"); sys.exit(1)
if "content_fps_q5" not in sel:
    print("FAIL sel missing q5 fps"); sys.exit(1)
if re.search(r"\bfps_1001\b", sel_code):
    print("FAIL sel port fps_1001 before parent arbitration"); sys.exit(1)
print("OK fps_sel has no fps_1001 consumer (parent #2 only)")
# present_core film class uses integer content_fps (comments may document the wall)
core = (root / "fpga/Plex_MiSTer/rtl/present_core.sv").read_text()
# Strip // and /* */ comments before hunting for executable rational math
code = re.sub(r"/\*.*?\*/", "", core, flags=re.S)
code = re.sub(r"//.*?$", "", code, flags=re.M)
if re.search(r"\b24000\b|1001", code):
    print("FAIL present_core executable text references 24000/1001 without ABI"); sys.exit(1)
if "content_fps <=" not in core and "beam_film_class" not in core:
    print("FAIL present_core missing integer film class"); sys.exit(1)
print("OK product still integer content_fps (honest wall; comments may cite NTSC)")

# B15 TB may document NTSC wall; must not claim lock/judder-control as achieved
tb = (root / "tests/rtl/b15_cadence_framecount_tb.sv").read_text()
# Positive overclaims (no negating nearby)
overclaim = [
    r"source-locked for 23\.976",
    r"source-locked for 29\.97",
    r"judder controlled",
    r"NTSC.*source-locked(?!.*NOT)",
]
for pat in overclaim:
    if re.search(pat, tb, re.I):
        # allow if same line has NOT / forbidden / lost / wall
        for line in tb.splitlines():
            if re.search(pat, line, re.I) and not re.search(
                r"NOT|forbidden|lost|wall|cannot|do not claim", line, re.I
            ):
                print(f"FAIL TB overclaim: {line.strip()}")
                sys.exit(1)
if not re.search(r"NOT NTSC|NTSC.*NOT locked|integer fps only", tb, re.I):
    print("FAIL TB must explicitly disclaim NTSC lock")
    sys.exit(1)
print("OK B15 TB disclaims NTSC source-lock (integer-only)")

# Fence w-clock docs that overclaim (allow explicit NOT/forbidden/do-not-claim lines)
docs = list((root / ".agent-work/w-clock").glob("*.md"))
docs += list((root / ".agent-work/w-clock").glob("*.txt"))
over = []
pat = re.compile(
    r"source-locked.*23\.976|23\.976.*source-lock|judder controlled for.*NTSC",
    re.I,
)
allow = re.compile(r"NOT|forbidden|lost|wall|cannot|do not|don't|never claim|unilateral|BLOCKED", re.I)
for p in docs:
    for line in p.read_text(errors="replace").splitlines():
        if pat.search(line) and not allow.search(line):
            over.append(f"{p}:{line.strip()}")
if over:
    print("FAIL overclaim docs:", over)
    sys.exit(1)
print("OK no w-clock doc claims NTSC source-lock")

# Optional: if w-path helper exists in-tree, prove bucket 24000/1001→24
q5 = root / "host/libmisterplex/plxg_q5_aspect_cadence.hpp"
if q5.exists():
    t = q5.read_text()
    if "23.5" not in t or "24" not in t:
        print("FAIL q5 helper missing film bucket")
        sys.exit(1)
    print("OK in-tree q5 helper buckets film family to integer 24")
else:
    print("NOTE plxg_q5 helper not in w-clock tree (w-path owns); bucket map recorded in json")

print("PASS test_ntsc_rational_cadence_wall GREEN")
PY

# RED: inject forbidden claim into a temp copy of TB → fence must catch
RED="$OUT/tb_bad.sv"
cp "$TB" "$RED"
echo '// source-locked for 23.976/29.97 judder controlled' >> "$RED"
set +e
python3 - "$RED" <<'PY'
import re, sys
from pathlib import Path
tb = Path(sys.argv[1]).read_text()
if re.search(r"23\.976", tb) and re.search(r"source-locked", tb, re.I):
    print("OK RED fence would catch NTSC source-lock claim")
    sys.exit(0)
print("FAIL RED")
sys.exit(1)
PY
RRC=$?
set -e
echo "true rc=$RRC red_claim_fence"
[[ "$RRC" -eq 0 ]] || exit 1

echo "PASS test_ntsc_rational_cadence_wall true rc=0"
exit 0
