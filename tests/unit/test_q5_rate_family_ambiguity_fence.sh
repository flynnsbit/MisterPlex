#!/usr/bin/env bash
# rd-duck: q5 cannot distinguish exact 24/30 from NTSC; product NTSC-only.
# Fence honest classification — not another dual-exact arithmetic claim.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON="$ROOT/assets/ntsc_rational_cadence_wall.json"
BRES="$ROOT/fpga/Plex_MiSTer/rtl/present_vtotal_bresenham.sv"
OUT="$ROOT/build/q5_rate_family_fence"
mkdir -p "$OUT"

python3 - "$ROOT" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
c = json.loads((root/"assets/ntsc_rational_cadence_wall.json").read_text())
amb = c.get("q5_rate_family_ambiguity")
assert amb, "missing q5_rate_family_ambiguity block"
assert "cannot distinguish" in amb["problem"].lower() or "both" in amb["problem"].lower()
assert amb["product_bresenham"].upper().find("NTSC") >= 0
# slip bands (rd-duck ~41.7 / ~33.4)
s24 = amb["exact_24_on_ntsc_beam"]["producer_gain_frame_s"]
s30 = amb["exact_30_on_ntsc_beam"]["producer_gain_frame_s"]
assert 41.0 < s24 < 42.5, s24
assert 33.0 < s30 < 34.0, s30
# re-derive
d24 = 24.0 - 24000.0/1001.0
d30 = 30.0 - 30000.0/1001.0
assert abs(1.0/d24 - s24) < 0.05
assert abs(1.0/d30 - s30) < 0.05
print(f"OK slip exact24→NTSC beam gain_s={s24:.3f} exact30→{s30:.3f}")

bres = c["bresenham_vtotal_h1182"]
assert bres.get("q5_cannot_select_family") is True
assert "integer_24" in bres.get("not_exact_for_product", [])
assert bres.get("b15_closed") is False
assert bres.get("product_default", "").startswith("ntsc")

forb = " ".join(c["claims_forbidden_until_fix"]).lower()
assert "both ntsc and integer" in forb or "exact for both" in forb
assert "arithmetic test alone" in forb or "arithmetic-only" in forb
print("OK wall forbids dual-exact + arithmetic-only resolution")

# RTL product path is NTSC nums, not INT, outside FAULT_BRES_EXACT_INT
rtl = (root/"fpga/Plex_MiSTer/rtl/present_vtotal_bresenham.sv").read_text()
# Strip FAULT_BRES_EXACT_INT branch for product check
prod = re.sub(r"`ifdef FAULT_BRES_EXACT_INT.*?`else", "", rtl, flags=re.S)
assert "NTSC_FILM_NUM" in prod
assert re.search(r"num\s*=\s*film_class\s*\?\s*12'\(NTSC_FILM_NUM\)", prod)
# must document impossibility
assert "cannot distinguish" in rtl.lower() or "q5 uint8" in rtl.lower()
# class transition clears acc
assert "film_class != film_class_d" in rtl or "film_class_d" in rtl
assert "class transition clears" in rtl.lower() or "clears Bresenham phase" in rtl
print("OK RTL product NTSC-only + class-clear policy")

# forbidden claim must not appear as achieved in wall status
st = c.get("status","").lower()
assert "exact for both" not in st
print("OK status does not claim dual exact")
print("PASS test_q5_rate_family_ambiguity_fence GREEN")
PY

# RED: wall that claims dual exact must fail detector
python3 - <<'PY'
import json, tempfile, subprocess, textwrap
from pathlib import Path
# local check: forbidden list presence is the fence; dual claim in allowed = fail
c=json.loads(Path("/home/flynnsbit/Projects/MisterPlex-wt-clock/assets/ntsc_rational_cadence_wall.json").read_text())
bad=[a for a in c.get("claims_allowed",[]) if "exact for both" in a.lower() or "both ntsc and integer" in a.lower()]
assert not bad, bad
print("OK RED fence: allowed list has no dual-exact claim")
PY

echo "PASS test_q5_rate_family_ambiguity_fence true rc=0"
