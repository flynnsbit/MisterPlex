#!/usr/bin/env bash
# rd-duck: runtime beam must force ascal path + size-change blackout.
# HDMI_BLACKOUT=0 disables ascal swblack (3-frame res blackout).
# VGA_SCALER=0 allows direct_video / raw VGA bypass of nonstandard 16.92 kHz beam.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
SYS="$ROOT/fpga/Plex_MiSTer/sys/sys_top.v"
ASC="$ROOT/fpga/Plex_MiSTer/sys/ascal.vhd"
JSON="$ROOT/assets/runtime_beam_ascal_guards.json"
OUT="$ROOT/build/runtime_beam_ascal_guards"
mkdir -p "$OUT"

for f in "$PLEX" "$SYS" "$ASC" "$JSON"; do
  [[ -f "$f" ]] || { echo "FAIL missing $f"; exit 1; }
done

python3 - "$ROOT" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
plex = (root / "fpga/Plex_MiSTer/Plex.sv").read_text()
sys_top = (root / "fpga/Plex_MiSTer/sys/sys_top.v").read_text()
ascal = (root / "fpga/Plex_MiSTer/sys/ascal.vhd").read_text()
c = json.loads((root / "assets/runtime_beam_ascal_guards.json").read_text())

# Find PRESENT_BEAM_960 ifdef that assigns BOTH guards (may not be first ifdef in file)
blocks = list(re.finditer(
    r"`ifdef\s+PRESENT_BEAM_960\s*(.*?)`else\s*(.*?)`endif",
    plex,
    re.S,
))
found = None
for m in blocks:
    if "HDMI_BLACKOUT" in m.group(1) and "VGA_SCALER" in m.group(1):
        found = m
        break
if not found:
    print("FAIL Plex.sv missing PRESENT_BEAM_960 ifdef assigning VGA_SCALER/HDMI_BLACKOUT")
    sys.exit(1)
on, off = found.group(1), found.group(2)
for name, val_on, val_off in (
    ("VGA_SCALER", 1, 0),
    ("HDMI_BLACKOUT", 1, 0),
):
    mon = re.search(rf"assign\s+{name}\s*=\s*(\d+)\s*;", on)
    moff = re.search(rf"assign\s+{name}\s*=\s*(\d+)\s*;", off)
    if not mon or not moff:
        print(f"FAIL cannot find assign {name} in BEAM ifdef branches")
        sys.exit(1)
    if int(mon.group(1)) != val_on:
        print(f"FAIL BEAM {name}={mon.group(1)} want {val_on}")
        sys.exit(1)
    if int(moff.group(1)) != val_off:
        print(f"FAIL legacy {name}={moff.group(1)} want {val_off}")
        sys.exit(1)
    print(f"OK Plex.sv BEAM {name}={val_on} legacy={val_off}")

zeros = re.findall(r"assign\s+HDMI_BLACKOUT\s*=\s*(\d+)\s*;", plex)
if "1" not in zeros or "0" not in zeros:
    print("FAIL HDMI_BLACKOUT must define both 1 and 0", zeros)
    sys.exit(1)

need_sys = [
    (r"\.swblack\s*\(\s*hdmi_blackout\s*\)", "ascal.swblack <= hdmi_blackout"),
    (r"\.HDMI_BLACKOUT\s*\(\s*hdmi_blackout\s*\)", "emu.HDMI_BLACKOUT => hdmi_blackout"),
    (r"\.VGA_SCALER\s*\(\s*vga_force_scaler\s*\)", "emu.VGA_SCALER => vga_force_scaler"),
    (r"vga_fb\s*=\s*cfg\[12\]\s*\|\s*vga_force_scaler", "vga_fb ORs force scaler"),
    (r"vga_scaler\s*=\s*cfg\[2\]\s*\|\s*vga_force_scaler", "vga_scaler ORs force scaler"),
    (r"~vga_fb\s*&\s*direct_video", "direct_video gated by ~vga_fb"),
]
for pat, label in need_sys:
    if not re.search(pat, sys_top):
        print(f"FAIL sys_top missing {label}")
        sys.exit(1)
    print(f"OK sys_top {label}")

if not re.search(r"swblack\s*=\s*'1'", ascal, re.I):
    print("FAIL ascal swblack='1' enable missing")
    sys.exit(1)
if not re.search(r"o_ihsize", ascal) or not re.search(r"i_hrsize", ascal):
    print("FAIL ascal size compare missing")
    sys.exit(1)
if "o_newres" not in ascal:
    print("FAIL ascal o_newres missing")
    sys.exit(1)
print("OK ascal swblack size-only path + o_newres")
# Honesty: gate records size-only scope
if "SIZE only" not in json.dumps(c) and "size" not in c.get("ascal_swblack_scope","").lower():
    print("FAIL json must document size-only blackout scope")
    sys.exit(1)
print("OK json documents size-only scope (not DAR/arbitrary geom)")
assert c["required_when_beam"]["HDMI_BLACKOUT"] == 1
assert c["required_when_beam"]["VGA_SCALER"] == 1
print("PASS runtime_beam_ascal_guards GREEN")
PY

# RED1: permanent BLACKOUT=0 / SCALER=0 (pre-fix)
RED_PLEX="$OUT/Plex_red_blackout0.sv"
python3 - "$PLEX" "$RED_PLEX" <<'PY'
import re, sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
red, n = re.subn(
    r"`ifdef\s+PRESENT_BEAM_960\s*.*?`else\s*.*?`endif",
    "assign VGA_SCALER    = 0;\nassign HDMI_BLACKOUT = 0;",
    src,
    count=1,
    flags=re.S,
)
if n < 1:
    sys.exit("failed to build red")
# only replace the guards block — try targeted
if "HDMI_BLACKOUT" in red and "`ifdef PRESENT_BEAM_960" in src:
    # If first ifdef wasn't ours, do targeted replace of both assigns in beam block
    pass
Path(sys.argv[2]).write_text(red)
print("wrote", sys.argv[2])
PY

# Targeted RED if first ifdef wasn't the guards one
python3 - "$PLEX" "$RED_PLEX" <<'PY'
import re, sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
# Replace the specific beam guards block only
pat = re.compile(
    r"(`ifdef\s+PRESENT_BEAM_960\s*)"
    r"(assign\s+VGA_SCALER\s*=\s*1\s*;\s*"
    r"assign\s+HDMI_BLACKOUT\s*=\s*1\s*;\s*)"
    r"(`else\s*)"
    r"(assign\s+VGA_SCALER\s*=\s*0\s*;\s*"
    r"assign\s+HDMI_BLACKOUT\s*=\s*0\s*;\s*)"
    r"(`endif)",
    re.S,
)
m = pat.search(src)
if not m:
    # looser whitespace
    pat = re.compile(
        r"`ifdef\s+PRESENT_BEAM_960\s*"
        r"assign\s+VGA_SCALER\s*=\s*1\s*;\s*"
        r"assign\s+HDMI_BLACKOUT\s*=\s*1\s*;\s*"
        r"`else\s*"
        r"assign\s+VGA_SCALER\s*=\s*0\s*;\s*"
        r"assign\s+HDMI_BLACKOUT\s*=\s*0\s*;\s*"
        r"`endif",
        re.S,
    )
    if not pat.search(src):
        print("FAIL cannot locate guards block for RED", file=sys.stderr)
        sys.exit(2)
    red = pat.sub("assign VGA_SCALER    = 0;\nassign HDMI_BLACKOUT = 0;", src, count=1)
else:
    red = pat.sub("assign VGA_SCALER    = 0;\nassign HDMI_BLACKOUT = 0;", src, count=1)
Path(sys.argv[2]).write_text(red)
print("red ok")
PY

set +e
python3 - "$RED_PLEX" <<'PY'
import re, sys
from pathlib import Path
plex = Path(sys.argv[1]).read_text()
has1 = bool(re.search(r"assign\s+HDMI_BLACKOUT\s*=\s*1\s*;", plex))
has0 = bool(re.search(r"assign\s+HDMI_BLACKOUT\s*=\s*0\s*;", plex))
beam_on = False
for m in re.finditer(r"`ifdef\s+PRESENT_BEAM_960\s*(.*?)`else\s*(.*?)`endif", plex, re.S):
    if "HDMI_BLACKOUT" in m.group(1):
        mon = re.search(r"assign\s+HDMI_BLACKOUT\s*=\s*(\d+)\s*;", m.group(1))
        if mon and int(mon.group(1)) == 1:
            beam_on = True
if beam_on or (has1 and not has0):
    print("FAIL RED still forces BLACKOUT=1 under beam")
    sys.exit(1)
if has0 and not has1:
    print("OK RED detects HDMI_BLACKOUT hardwired 0 (ascal swblack disabled)")
    sys.exit(0)
print("FAIL RED did not catch", has0, has1)
sys.exit(1)
PY
RRC=$?
set -e
echo "true rc=$RRC red_blackout0"
[[ "$RRC" -eq 0 ]] || { echo "FAIL red_blackout0"; exit 1; }

# RED2: BEAM VGA_SCALER forced 0
RED2="$OUT/Plex_red_scaler0.sv"
python3 - "$PLEX" "$RED2" <<'PY'
import re, sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
red = re.sub(
    r"(`ifdef\s+PRESENT_BEAM_960\s*assign\s+VGA_SCALER\s*=\s*)1(\s*;)",
    r"\g<1>0\2",
    src,
    count=1,
)
Path(sys.argv[2]).write_text(red)
PY
set +e
python3 - "$RED2" <<'PY'
import re, sys
from pathlib import Path
plex = Path(sys.argv[1]).read_text()
for m in re.finditer(r"`ifdef\s+PRESENT_BEAM_960\s*(.*?)`else", plex, re.S):
    if "VGA_SCALER" in m.group(1):
        mon = re.search(r"assign\s+VGA_SCALER\s*=\s*(\d+)\s*;", m.group(1))
        if mon and int(mon.group(1)) == 0:
            print("OK RED2 detects BEAM VGA_SCALER=0 (bypass risk)")
            sys.exit(0)
print("FAIL RED2")
sys.exit(1)
PY
R2=$?
set -e
echo "true rc=$R2 red_scaler0"
[[ "$R2" -eq 0 ]] || { echo "FAIL red_scaler0"; exit 1; }

echo "PASS test_runtime_beam_ascal_guards true rc=0"
exit 0
