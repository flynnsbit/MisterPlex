#!/usr/bin/env bash
# B15 product connectivity: plex_content_fps_sel must drive content_fps (parent miss #11).
# Presence in files.qip is NOT enough — must instantiate; no bare 8'd24 outside FAULT.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
SEL="$ROOT/fpga/Plex_MiSTer/rtl/plex_content_fps_sel.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"

[[ -f "$PLEX" && -f "$SEL" && -f "$QIP" && -f "$CORE" ]] || { echo "FAIL missing files"; exit 1; }

grep -q 'plex_content_fps_sel' "$QIP" || { echo "FAIL sel not in files.qip"; exit 1; }
grep -q 'plex_content_fps_sel' "$PLEX" || { echo "FAIL sel never instantiated in Plex.sv"; exit 1; }
grep -q 'u_content_fps_sel' "$PLEX" || { echo "FAIL missing instance name u_content_fps_sel"; exit 1; }

# plxg_* canonical producer names (ABI #2 / arbitration #3)
grep -q 'plxg_fps_valid' "$PLEX" || { echo "FAIL missing plxg_fps_valid"; exit 1; }
grep -q 'plxg_content_fps' "$PLEX" || { echo "FAIL missing plxg_content_fps"; exit 1; }

# Bare hardwire 8'd24 content_fps only under FAULT_B15_FPS_HARDWIRE_24
python3 - "$PLEX" <<'PY'
import re, sys
from pathlib import Path
t = Path(sys.argv[1]).read_text()
# Remove FAULT ifdef blocks
t2 = re.sub(
    r"`ifdef\s+FAULT_B15_FPS_HARDWIRE_24.*?`else.*?`endif",
    "/*FAULT_STRIPPED*/",
    t,
    flags=re.S,
)
# Also strip other FAULT hardwire single-line ifdefs
if re.search(r"wire\s*\[\s*7:0\s*\]\s*content_fps\s*=\s*8'd24\s*;", t2):
    print("FAIL bare content_fps=8'd24 outside FAULT hardwire twin")
    sys.exit(1)
# Must have continuous assign from sel
if "content_fps_eff(content_fps)" not in t and ".content_fps_eff(content_fps)" not in t:
    # instance connect
    if not re.search(r"plex_content_fps_sel\s+\w+\s*\([^;]*content_fps", t, re.S):
        print("FAIL selector does not drive content_fps")
        sys.exit(1)
if "content_fps_eff" not in t:
    print("FAIL no content_fps_eff connect")
    sys.exit(1)
print("OK Plex.sv: sel instantiated; no bare hardwire 24; plxg_* present")
PY

# present_core still consumes content_fps port (not internal hardwire)
grep -q 'input  wire \[7:0\]  content_fps' "$CORE" || { echo "FAIL core missing content_fps input"; exit 1; }
grep -q 'beam_film_class' "$CORE" || { echo "FAIL core missing film class"; exit 1; }
grep -q 'cadence_display_hz' "$CORE" || { echo "FAIL core missing cadence_display_hz"; exit 1; }

# RED: hardwire without sel
RED="$ROOT/build/b15_wiring_red_Plex.sv"
mkdir -p "$ROOT/build"
python3 - "$PLEX" "$RED" <<'PY'
import re, sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
# collapse sel to hardwire 24
red = re.sub(
    r"`ifdef\s+FAULT_B15_FPS_HARDWIRE_24.*?`endif",
    "wire [7:0] content_fps = 8'd24;",
    src,
    count=1,
    flags=re.S,
)
if "plex_content_fps_sel" in red and "u_content_fps_sel" in red:
    # force remove instance block
    red = re.sub(
        r"wire\s+plxg_fps_valid.*?plex_content_fps_sel.*?content_fps_eff\(content_fps\)\s*\);",
        "wire [7:0] content_fps = 8'd24;",
        red,
        count=1,
        flags=re.S,
    )
Path(sys.argv[2]).write_text(red)
print("wrote red")
PY
set +e
python3 - "$RED" <<'PY'
import re, sys
from pathlib import Path
t = Path(sys.argv[1]).read_text()
t2 = re.sub(r"`ifdef\s+FAULT_B15_FPS_HARDWIRE_24.*?`endif", "", t, flags=re.S)
if re.search(r"content_fps\s*=\s*8'd24", t2) and "plex_content_fps_sel" not in t2:
    print("OK RED catches hardwire-only content_fps")
    sys.exit(0)
if re.search(r"content_fps\s*=\s*8'd24", t2):
    print("OK RED catches hardwire 24 present")
    sys.exit(0)
print("FAIL RED")
sys.exit(1)
PY
R=$?
set -e
echo "true rc=$R red"
[[ "$R" -eq 0 ]] || exit 1

echo "PASS test_b15_product_fps_wiring true rc=0"
exit 0
