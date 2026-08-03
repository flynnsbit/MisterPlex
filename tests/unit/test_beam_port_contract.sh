#!/usr/bin/env bash
# COLLISION #7: beam port contract presence + elab. Fails if merge drops ports.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
JSON="$ROOT/assets/present_beam_port_contract.json"
RV="$ROOT/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/beam_port_contract"
mkdir -p "$OUT"

[[ -f "$BEAM" ]] || { echo "FAIL missing beam"; exit 1; }
[[ -f "$JSON" ]] || { echo "FAIL missing port contract json"; exit 1; }

REQUIRED=(
  use_rt_vtotal rt_vtotal use_rt_geom rt_h_de rt_h_total rt_v_active
  hde_active htot_active vact_active vtot_active
  ce_pix HBlank HSync VBlank VSync frame_start hc_out vc_out
)
echo "PORT_CONTRACT checking required ports in beam RTL"
for p in "${REQUIRED[@]}"; do
  if ! grep -F -q "$p" "$BEAM"; then
    echo "FAIL PINABSENT $p — beam port contract broken (COLLISION #7 class)"
    exit 1
  fi
  echo "OK present $p"
done

python3 - <<PY
import json, re, sys
from pathlib import Path
root = Path(r"$ROOT")
c = json.loads((root / "assets/present_beam_port_contract.json").read_text())
names = set(c["required_port_names"])
need = {
 "use_rt_vtotal","rt_vtotal","use_rt_geom","rt_h_de","rt_h_total","rt_v_active",
 "hde_active","htot_active","vact_active","vtot_active"
}
miss = need - names
if miss:
    print("FAIL json missing", miss); sys.exit(1)
print("OK json required_port_names covers load-bearing set")
t = (root / "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv").read_text()
m = re.search(r"module\s+present_beam_content_de\s*(?:#\s*\([^;]*?\))?\s*\((.*?)\);", t, re.S)
if not m:
    print("FAIL cannot parse module port list"); sys.exit(1)
ports = m.group(1)
for p in ("rt_h_total", "htot_active", "rt_h_de", "rt_v_active", "use_rt_geom",
          "use_rt_vtotal", "hde_active", "vact_active", "vtot_active"):
    if p not in ports:
        print("FAIL port %r not in module port list" % p); sys.exit(1)
    print("OK portlist", p)
print("OK module port list contains load-bearing runtime ports")
PY

rm -rf "$OUT/elab"
mkdir -p "$OUT/elab"
set +e
"$RV" -Wno-fatal --binary --timing --top-module beam_port_contract_tb \
  -Mdir "$OUT/elab" \
  "$ROOT/tests/rtl/beam_port_contract_tb.sv" "$BEAM" >"$OUT/elab/build.log" 2>&1
BRC=$?
set -e
if [[ "$BRC" -ne 0 ]]; then
  echo "FAIL elab/build rc=$BRC (PINNOTFOUND class?)"
  tail -50 "$OUT/elab/build.log"
  exit 1
fi
set +e
"$OUT/elab/Vbeam_port_contract_tb" >"$OUT/elab/run.log" 2>&1
RRC=$?
set -e
cat "$OUT/elab/run.log"
echo "true rc=$RRC"
[[ "$RRC" -eq 0 ]] || { echo "FAIL sim rc=$RRC"; exit 1; }
grep -q "PASS beam_port_contract_tb" "$OUT/elab/run.log" || { echo "FAIL pass marker"; exit 1; }
grep -q "htot_active=1182" "$OUT/elab/run.log" || { echo "FAIL htot"; exit 1; }

# RED twin: rename load-bearing ports so presence check would fail
RED="$OUT/beam_strip.sv"
python3 - <<PY
from pathlib import Path
src = Path(r"$BEAM").read_text()
red = src.replace("rt_h_total", "rt_h_tot_REMOVED").replace("htot_active", "htot_act_REMOVED")
Path(r"$RED").write_text(red)
print("wrote strip twin")
PY
if grep -F -q "rt_h_total" "$RED"; then
  echo "FAIL red strip still has rt_h_total"; exit 1
fi
if grep -F -q "htot_active" "$RED"; then
  echo "FAIL red strip still has htot_active"; exit 1
fi
echo "OK RED strip twin lacks rt_h_total/htot_active (would fail this gate)"

echo "PASS test_beam_port_contract true rc=0"
exit 0
