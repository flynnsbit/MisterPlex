#!/usr/bin/env python3
"""W-AUDIT check of the hour27 SDC A/B comparison.

This is intentionally read-only.  It checks the remote build source trees when
available and local remote_out fit artifacts for the competing RBFs.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

DEFAULT_INTEG = Path("/home/flynnsbit/Projects/mp-wt-integ")
DEFAULT_REMOTE = os.environ.get("MISTER_REMOTE_HOST", "docker")
SLOTS = [
    "wfit-hour27-a",
    "wfit-hour27-sdc-a",
    "wfit-hour27-sdc-b",
    "wfit-hour27-bdiag-a",
    "wfit-hour27-bdiag-b",
]


def md5_bytes(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def local_md5(path: Path) -> str:
    return md5_bytes(path.read_bytes()) if path.exists() else "MISSING"


def run(cmd: list[str], *, cwd: Path | None = None) -> tuple[int, str]:
    p = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return p.returncode, p.stdout


def ssh_cat(remote: str, slot: str, rel: str) -> bytes | None:
    path = f"$HOME/mplex-builds/{slot}/Plex_MiSTer/{rel}"
    p = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", remote, f"cat {path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return p.stdout if p.returncode == 0 else None


def ssh_tree_manifest(remote: str, slot: str, subdir: str) -> tuple[str, int] | None:
    script = f"""
from pathlib import Path
import hashlib
root=Path.home()/"mplex-builds/{slot}/Plex_MiSTer/{subdir}"
if not root.exists():
    raise SystemExit(3)
rows=[]
for p in sorted(root.rglob("*")):
    if p.is_file():
        rows.append((str(p.relative_to(root)), hashlib.md5(p.read_bytes()).hexdigest()))
print(hashlib.md5("\\n".join(f"{{n}} {{m}}" for n,m in rows).encode()).hexdigest(), len(rows))
"""
    p = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", remote, "python3 -"],
        input=script,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if p.returncode != 0:
        return None
    h, n = p.stdout.strip().split()
    return h, int(n)


@dataclass(frozen=True)
class Row:
    entity: str
    full: str
    aluts: float
    regs: float
    bits: float
    m10k: float
    dsp: float


def split_row(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip(";").split(";")]


def parse_num(text: str) -> float:
    m = re.search(r"-?\d+(?:,\d{3})*(?:\.\d+)?", text)
    return float(m.group(0).replace(",", "")) if m else 0.0


def parse_fit_rows(path: Path) -> list[Row]:
    rows: list[Row] = []
    header: list[str] | None = None
    for line in path.read_text(errors="ignore").splitlines():
        if "Compilation Hierarchy Node" in line and "Full Hierarchy Name" in line:
            header = [re.sub(r"\s+", " ", c.strip()) for c in split_row(line)]
            continue
        if not header or not line.lstrip().startswith(";"):
            continue
        cells = split_row(line)
        if len(cells) != len(header) or not cells or not cells[0].startswith("|"):
            continue
        data = dict(zip(header, cells))
        entity = data.get("Entity Name", "")
        full = data.get("Full Hierarchy Name", "")
        if not entity or not full:
            continue
        rows.append(
            Row(
                entity=entity,
                full=full,
                aluts=parse_num(data.get("Combinational ALUTs", "0")),
                regs=parse_num(data.get("Dedicated Logic Registers", "0")),
                bits=parse_num(data.get("Block Memory Bits", "0")),
                m10k=parse_num(data.get("M10Ks", "0")),
                dsp=parse_num(data.get("DSP Blocks", "0")),
            )
        )
    return rows


def parse_util(path: Path) -> dict[str, tuple[int, int, int]]:
    pats = {
        "alms": r"Logic utilization \(in ALMs\)\s*;\s*([\d,]+)\s*/\s*([\d,]+)\s*\(\s*(\d+)\s*%\s*\)",
        "block_bits": r"Total block memory bits\s*;\s*([\d,]+)\s*/\s*([\d,]+)\s*\(\s*(\d+)\s*%\s*\)",
        "m10k": r"Total RAM Blocks\s*;\s*([\d,]+)\s*/\s*([\d,]+)\s*\(\s*(\d+)\s*%\s*\)",
        "dsp": r"Total DSP Blocks\s*;\s*([\d,]+)\s*/\s*([\d,]+)\s*\(\s*(\d+)\s*%\s*\)",
    }
    text = path.read_text(errors="ignore")
    out: dict[str, tuple[int, int, int]] = {}
    for k, pat in pats.items():
        m = re.search(pat, text)
        if m:
            out[k] = tuple(int(x.replace(",", "")) for x in m.groups())  # type: ignore[assignment]
    return out


def sdc_features(text: str) -> str:
    set_lines = [line.strip() for line in text.splitlines() if re.match(r"^\s*set_(?:false_path|max_delay)\b", line)]
    false_paths = sum(line.startswith("set_false_path") for line in set_lines)
    max_delay = sum(line.startswith("set_max_delay") for line in set_lines)
    diag_false = int(any(line.startswith("set_false_path") and "underrun_count" in line for line in set_lines))
    diag_max = int(any(line.startswith("set_max_delay") and "underrun_count" in line for line in set_lines))
    return f"false_paths={false_paths} max_delay={max_delay} diag_false={diag_false} diag_max={diag_max}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--integ-root", type=Path, default=DEFAULT_INTEG)
    ap.add_argument("--remote", default=DEFAULT_REMOTE)
    args = ap.parse_args()

    out_root = args.integ_root / "fpga/Plex_MiSTer/remote_out"
    print(f"INTEG_ROOT {args.integ_root}")
    print(f"REMOTE {args.remote}")

    remote_files: dict[tuple[str, str], bytes] = {}
    for slot in SLOTS:
        print(f"SLOT {slot}")
        for rel in ["output_files/Plex.rbf", "Plex.sdc", "Plex.sv", "Plex.qsf", "files.qip", "build_id.v"]:
            data = ssh_cat(args.remote, slot, rel)
            if data is not None:
                remote_files[(slot, rel)] = data
                print(f"  REMOTE_MD5 {rel} {md5_bytes(data)} len={len(data)}")
                if rel == "Plex.sdc":
                    print(f"  SDC_FEATURES {sdc_features(data.decode(errors='ignore'))}")
        for sub in ["rtl", "sys"]:
            manifest = ssh_tree_manifest(args.remote, slot, sub)
            if manifest is not None:
                print(f"  REMOTE_TREE {sub} md5={manifest[0]} files={manifest[1]}")
        local_slot = out_root / slot
        for rel in ["Plex.rbf", "Plex.fit.rpt", "Plex.map.rpt"]:
            print(f"  LOCAL_MD5 {rel} {local_md5(local_slot / rel)}")
        fit = local_slot / "Plex.fit.rpt"
        if fit.exists():
            rows = parse_fit_rows(fit)
            print(f"  FIT rows={len(rows)} util={parse_util(fit)}")

    a_sdc = remote_files.get(("wfit-hour27-a", "Plex.sdc"), b"").decode(errors="ignore").splitlines()
    b_sdc = remote_files.get(("wfit-hour27-bdiag-b", "Plex.sdc"), b"").decode(errors="ignore").splitlines()
    if a_sdc and b_sdc:
        diff = list(difflib.unified_diff(a_sdc, b_sdc, fromfile="wfit-hour27-a/Plex.sdc", tofile="wfit-hour27-bdiag-b/Plex.sdc", lineterm=""))
        print(f"SDC_A_TO_BDIAG_DIFF_LINES {len(diff)}")
        for line in diff[:120]:
            print(f"  {line}")

    a_fit = out_root / "wfit-hour27-a/Plex.fit.rpt"
    b_fit = out_root / "wfit-hour27-bdiag-b/Plex.fit.rpt"
    if a_fit.exists() and b_fit.exists():
        ar = {(r.entity, r.full): r for r in parse_fit_rows(a_fit)}
        br = {(r.entity, r.full): r for r in parse_fit_rows(b_fit)}
        print(f"FIT_KEY_DIFF only_a={len(set(ar)-set(br))} only_b={len(set(br)-set(ar))} common={len(set(ar)&set(br))}")
        resource_diffs = []
        for key in sorted(set(ar) & set(br)):
            a = ar[key]
            b = br[key]
            if (a.aluts, a.regs, a.bits, a.m10k, a.dsp) != (b.aluts, b.regs, b.bits, b.m10k, b.dsp):
                resource_diffs.append((key, a, b))
        print(f"FIT_RESOURCE_DIFFS {len(resource_diffs)}")
        for (entity, full), a, b in resource_diffs[:80]:
            print(
                "  RESOURCE_DIFF "
                f"entity={entity} hierarchy={full} "
                f"aluts={a.aluts:g}->{b.aluts:g} regs={a.regs:g}->{b.regs:g} "
                f"bits={a.bits:g}->{b.bits:g} m10k={a.m10k:g}->{b.m10k:g} dsp={a.dsp:g}->{b.dsp:g}"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
