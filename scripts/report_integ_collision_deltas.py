#!/usr/bin/env python3
"""Report collision #7 (beam ports) and #8 (path layout symbols). Do not fix."""
from __future__ import annotations
import os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MEM = Path(os.environ.get("MEM_WT", "/home/flynnsbit/Projects/MisterPlex-wt-mem"))
CLK = Path(os.environ.get("CLK_WT", "/home/flynnsbit/Projects/MisterPlex-wt-clock"))
SCL = Path(os.environ.get("SCL_WT", "/home/flynnsbit/Projects/MisterPlex-wt-scaler"))
PATHWT = Path(os.environ.get("PATH_WT", "/home/flynnsbit/Projects/MisterPlex-wt-path"))
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "docs/agent-evidence/integ-collision-deltas.txt"

lines: list[str] = []
def add(s: str = "") -> None:
    lines.append(s)

def ports(p: Path) -> list[str]:
    t = p.read_text()
    return [m.group(1) for m in re.finditer(
        r"(?:input|output)\s+wire(?:\s+\[[^\]]+\])?\s+(\w+)", t)]

add("# Integration collision deltas (report-only)")
add()
add("## Collision #7 — present_beam_content_de port list")
add("Owner (parent): w-clock. Consumer: w-scaler.")
add()
cpath = CLK / "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
spath = SCL / "fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
add("### w-clock ports")
for i, l in enumerate(cpath.read_text().splitlines(), 1):
    if re.search(r"^\s*(input|output)\s+wire", l):
        add(f"{i}:{l}")
add()
add("### w-scaler ports")
for i, l in enumerate(spath.read_text().splitlines(), 1):
    if re.search(r"^\s*(input|output)\s+wire", l):
        add(f"{i}:{l}")
add()
cs, ss = set(ports(cpath)), set(ports(spath))
add(f"clock_only: {sorted(cs - ss)}")
add(f"scaler_only: {sorted(ss - cs)}")
add(f"shared: {sorted(cs & ss)}")
add()
add("## Collision #8 — path layout symbols vs scaler/mem layout")
syms = [
    "ddrStorageGeometryForContent", "ddrFfmpegGeometryForPresent",
    "kPlex360pCodedWidth", "kPlex360pCodedHeight",
    "ddrIsProduct960x540Content", "makePlex720pOutputFrom540pSourcePlan",
    "kDdrFramePlxgOffset", "kPlxgOffset",
]
lanes = {
    "path": PATHWT / "host/libmisterplex/ddr_frame_layout.hpp",
    "mem": MEM / "host/libmisterplex/ddr_frame_layout.hpp",
    "scaler": SCL / "host/libmisterplex/ddr_frame_layout.hpp",
}
add(f"{'symbol':40} path mem scaler")
for s in syms:
    row = [s]
    for L in ("path", "mem", "scaler"):
        t = lanes[L].read_text() if lanes[L].exists() else ""
        row.append("Y" if s in t else "n")
    add(f"{row[0]:40} {row[1]:4} {row[2]:3} {row[3]}")
pt = lanes["path"].read_text()
st = lanes["scaler"].read_text() if lanes["scaler"].exists() else ""
pf = set(re.findall(r"\binline\b[^{;]*?\b([A-Za-z_]\w*)\s*\(", pt))
sf = set(re.findall(r"\binline\b[^{;]*?\b([A-Za-z_]\w*)\s*\(", st))
add(f"path_only_funcs sample: {sorted(pf - sf)[:50]}")
add(f"scaler_only_funcs sample: {sorted(sf - pf)[:50]}")
add()
add("## Store marker counts")
for label, p in (
    ("mem", MEM / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"),
    ("scaler", SCL / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"),
    ("integ", ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"),
):
    if not p.exists():
        add(f"{label} MISSING")
        continue
    t = p.read_text()
    add(
        f"{label} lines={t.count(chr(10)) + 1} "
        f"rt_need_optc={t.count('rt_need_optc')} "
        f"align={len(re.findall(r'rt_coded_w\[3:0\]', t))} "
        f"geom_reject={t.count('geom_reject')}"
    )

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(lines) + "\n")
print(OUT.read_text())
print(f"wrote {OUT}")
