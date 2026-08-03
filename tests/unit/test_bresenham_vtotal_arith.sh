#!/usr/bin/env bash
# rd-duck: Bresenham V_TOTAL averages exact; swap≠advance fence; B15 not closed on cadence.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON="$ROOT/assets/ntsc_rational_cadence_wall.json"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
DOC="$ROOT/.agent-work/w-clock/BRESENHAM_VTOTAL_SOURCE_LOCK.md"
OUT="$ROOT/build/bresenham_vtotal"
mkdir -p "$OUT"
[[ -f "$JSON" && -f "$CORE" && -f "$DOC" ]] || { echo "FAIL missing inputs"; exit 1; }

awk 'BEGIN{
  clk=20000000; H=1182
  # exact mean V rationals
  split("1251250/1773 1001000/1773 1250000/1773 1000000/1773", avg, " ")
  split("24000/1001 30000/1001 24 30", rate, " ")
  for (i=1;i<=4;i++) {
    split(avg[i], a, "/"); V=a[1]/a[2]
    if (index(rate[i],"/")) { split(rate[i],r,"/"); R=r[1]/r[2] } else R=rate[i]+0
    hz=clk/(H*V)
    err=hz-R
    if (err < -1e-9 || err > 1e-9) {
      printf("FAIL rate %s hz=%.15f want=%.15f err=%g\n", rate[i], hz, R, err) > "/dev/stderr"
      exit 1
    }
    printf("OK %s mean_V=%s hz=%.12f\n", rate[i], avg[i], hz)
  }
  # fixed slip minutes for integer 24/30
  b24=clk/(H*705); b30=clk/(H*564)
  s24=(1/(b24-24))/60; s30=(1/(b30-30))/60
  if (s24 < 24.5 || s24 > 25.2) { printf("FAIL i24 slip_min=%.3f\n", s24) > "/dev/stderr"; exit 1 }
  if (s30 < 19.5 || s30 > 20.2) { printf("FAIL i30 slip_min=%.3f\n", s30) > "/dev/stderr"; exit 1 }
  printf("OK fixed integer slip_min 24→%.3f 30→%.3f\n", s24, s30)
  # duty checks
  f=(1251250/1773)-705; if (f<0.72||f>0.73) exit 1
  t=(1001000/1773)-564; if (t<0.57||t>0.59) exit 1
  print "OK duties film@706=" f " n30@565=" t
  # parent miss: 0.72476 at 706 not 705
  if (f < 0.7247 || f > 0.7248) exit 1
  print "OK PARENT MISS corrected: duty@706=" f
}' | tee "$OUT/math.txt"

python3 - "$ROOT" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
c = json.loads((root/"assets/ntsc_rational_cadence_wall.json").read_text())
assert c["bresenham_vtotal_h1182"]["implemented"] is True
assert c["bresenham_vtotal_h1182"].get("b15_closed") is False
assert c["bresenham_vtotal_h1182"]["long_run_hz_exact"] is True
assert c["swap_vs_advance"]["ddr_swap"].find("swap_pending") >= 0
assert "B15 closed via present_cadence" in " ".join(c["claims_forbidden_until_fix"]) or \
       any("advance_unique" in x for x in c["claims_forbidden_until_fix"])
core = (root/"fpga/Plex_MiSTer/rtl/present_core.sv").read_text()
if not re.search(r"NOT advance|not advance", core, re.I):
    print("FAIL present_core must document swap NOT advance"); sys.exit(1)
if not re.search(r"swap_pending", core):
    print("FAIL no swap_pending"); sys.exit(1)
# must not wire advance into swap in product (structural)
code = re.sub(r"/\*.*?\*/", "", core, flags=re.S)
code = re.sub(r"//.*?$", "", code, flags=re.M)
# crude: swap_pending port connect should not be advance
if re.search(r"\.swap_pending\s*\(\s*advance", code):
    print("FAIL swap_pending tied to advance"); sys.exit(1)
doc = (root/".agent-work/w-clock/BRESENHAM_VTOTAL_SOURCE_LOCK.md").read_text()
assert "Do not close B15" in doc or "Do not close B15" in doc.replace("do not","Do not")
assert "1251250/1773" in doc and "1001000/1773" in doc
print("OK json+core swap≠advance fence; Bresenham implemented=True b15_closed=False")
print("PASS test_bresenham_vtotal_arith GREEN")
PY

# RED: claim B15 closed on advance alone must be forbidden in wall
python3 - <<'PY'
import json
from pathlib import Path
c=json.loads(Path("/home/flynnsbit/Projects/MisterPlex-wt-clock/assets/ntsc_rational_cadence_wall.json").read_text())
bad=[x for x in c["claims_forbidden_until_fix"] if "advance" in x.lower() or "cadence" in x.lower()]
assert bad, "missing forbidden cadence-close claims"
print("OK forbidden list includes cadence-only close:", bad[0][:60])
PY

echo "PASS test_bresenham_vtotal_arith true rc=0"
