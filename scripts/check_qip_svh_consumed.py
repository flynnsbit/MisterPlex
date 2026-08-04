#!/usr/bin/env python3
"""Fail dead .svh listed in files.qip with no `include consumer (rd-duck).

Dead compilation-unit localparams do not constrain product RTL and must not
count as fabric work. plex_720p_bw_contract.svh is the named defect class.

Also audits optional tests/fixtures/p720_bw_contract.json:
  - R_req lock 33.1776 MB/s/dir stands
  - must NOT claim rd-duck accepted reader CLOSED @ 38.53 MB/s
  - must NOT claim free-core overlap or ARM-never-touches-payload

Exit: 0 ok, 1 dead contract / forbidden claim, 2 bad inputs
Soft-skip 77 is never used as pass.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
R_REQ = 33.1776  # MB/s per direction @720p24 — locked arithmetic


def qip_sv_files(qip: Path) -> list[str]:
    out: list[str] = []
    if not qip.is_file():
        return out
    for line in qip.read_text(errors="ignore").splitlines():
        s = line.strip()
        if s.startswith("#"):
            continue
        m = re.search(r'SYSTEMVERILOG_FILE\s+(\S+)', s)
        if m:
            out.append(m.group(1).strip().strip('"'))
    return out


def rtl_corpus(root: Path) -> str:
    chunks: list[str] = []
    rtl = root / "fpga/Plex_MiSTer"
    for pat in ("**/*.sv", "**/*.v", "**/*.svh", "**/*.vh"):
        for p in rtl.glob(pat):
            if "pll" in p.parts and p.suffix == ".v":
                continue
            try:
                chunks.append(p.read_text(errors="ignore"))
            except OSError:
                pass
    return "\n".join(chunks)


def consumers_of(basename: str, corpus: str) -> int:
    # `include "rtl/foo.svh" or "foo.svh"
    pat = re.compile(
        rf'`include\s+"([^"]*{re.escape(basename)})"',
        re.I,
    )
    return len(pat.findall(corpus))


def audit_p720_fixture(path: Path) -> list[str]:
    errs: list[str] = []
    if not path.is_file():
        return errs
    data = json.loads(path.read_text())
    text = json.dumps(data).lower()

    # Locked arithmetic must appear if fixture claims rates
    blob = path.read_text()
    if "33.1776" not in blob and "33177600" not in blob:
        # only enforce when fixture is the p720 contract
        if "p720" in path.name or "720p" in blob.lower():
            errs.append("p720 fixture missing locked R_req 33.1776 (or 33177600 B/s)")

    # Forbidden: imply rd-duck accepted 38.53 as closed fabric BW
    if re.search(r"38\.53", blob):
        if "rd-duck" in text and re.search(r"38\.53", blob):
            # allow if explicitly marked NOT accepted / OPEN / rejected
            nearby_ok = re.search(
                r"38\.53[^\n]{0,120}(not established|open|nack|reject|invalid|do not)",
                blob,
                re.I,
            ) or re.search(
                r"(not established|open|nack|reject)[^\n]{0,120}38\.53",
                blob,
                re.I,
            )
            if not nearby_ok:
                errs.append(
                    "fixture mentions 38.53 near contract — must not imply "
                    "rd-duck accepted 38.53 MB/s CLOSED (mark NACK/not established)"
                )

    ack = data.get("audit_ack") or []
    if isinstance(ack, list) and any("rd-duck" in str(a).lower() for a in ack):
        # rd-duck ACK is arithmetic labels only — fixture must not say reader CLOSED via ack
        title = str(data.get("title", ""))
        if re.search(r"reader\s+CLOSED", title, re.I) and "rd-duck" in title.lower():
            errs.append(
                "title ties rd-duck to reader CLOSED — ACK is arithmetic labels only "
                "(rd-duck NACK on CLOSED/38.53)"
            )
        # claim_split reader CLOSED is ok as *lane claim* but must not say audit_ack proves it
        notes = str(data.get("notes", data.get("fabric_bw_closed_means", "")))
        if re.search(r"audit_ack.*(reader|38\.53|CLOSED)", notes, re.I):
            errs.append("notes must not treat audit_ack as reader CLOSED proof")

    # Forbidden language
    if re.search(r"free core", blob, re.I):
        errs.append("forbidden 'free core' (49% idle was before decode)")
    if re.search(r"arm never touches (the )?(frame|payload|pixels)", blob, re.I):
        errs.append("forbidden 'ARM never touches payload/frame' (DMA=publication memcpy only)")

    return errs


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv[1:])
    root = args.root.resolve()

    print("QIP_SVH_CONSUMED_EXECUTED")
    print(f"ROOT={root}")
    print(f"R_req_MBps_per_dir_LOCKED={R_REQ}")

    if args.self_test:
        dead = "set_global_assignment -name SYSTEMVERILOG_FILE rtl/plex_720p_bw_contract.svh\n"
        live_corpus = '// no include\n'
        assert consumers_of("plex_720p_bw_contract.svh", live_corpus) == 0
        assert consumers_of("plex_720p_bw_contract.svh", '`include "rtl/plex_720p_bw_contract.svh"\n') == 1
        print("SELFTEST include detect ok")
        print("PASS QIP_SVH_CONSUMED self-test")
        return 0

    qip = root / "fpga/Plex_MiSTer/files.qip"
    files = qip_sv_files(qip)
    corpus = rtl_corpus(root)
    print(f"QIP_SV_COUNT={len(files)}")

    dead: list[str] = []
    watched = [f for f in files if f.endswith(".svh") or "bw_contract" in f]
    # Always watch named contract even if only on disk
    contract_rel = "rtl/plex_720p_bw_contract.svh"
    contract_path = root / "fpga/Plex_MiSTer" / contract_rel
    if contract_path.is_file() and contract_rel not in files and not any(
        f.endswith("plex_720p_bw_contract.svh") for f in files
    ):
        print("CONTRACT_ON_DISK_NOT_IN_QIP=1  # ok if docs-only; still must be included to constrain RTL")
        n = consumers_of("plex_720p_bw_contract.svh", corpus)
        print(f"CONTRACT_INCLUDE_COUNT={n}")
        if n == 0:
            print(
                "DEAD_CONTRACT_WARNING plex_720p_bw_contract.svh on disk, zero includes — "
                "not fabric work (rd-duck)"
            )
            print("BLOCKER_DEAD_BW_CONTRACT=required  # consume in present/store or synth-active assert")
            fixp = root / "tests/fixtures/p720_bw_contract.json"
            if fixp.is_file() and "plex_720p_bw_contract" in fixp.read_text():
                print(
                    "FAIL DEAD_CONTRACT claimed by p720 fixture but zero `include consumers",
                    file=sys.stderr,
                )
                # mark for fail — set via nonlocal pattern: append to dead list equivalent
                dead.append(contract_rel + " (fixture-claimed, zero include)")

    for f in files:
        base = Path(f).name
        if not (base.endswith(".svh") or base.endswith(".vh")):
            continue
        # Skip known legit includes infrastructure
        n = consumers_of(base, corpus)
        print(f"QIP_HEADER {f} include_count={n}")
        if n == 0:
            # build_id.v / emu_ports may be included with different patterns
            if base in {"build_id.v"}:
                continue
            dead.append(f)

    fail = 0
    for d in dead:
        print(f"FAIL DEAD_QIP_HEADER no `include consumer: {d}", file=sys.stderr)
        fail = 1
        if "720p_bw_contract" in d or "bw_contract" in d:
            print(
                "DEAD_CONTRACT plex_720p_bw_contract — localparams do not constrain product RTL",
                file=sys.stderr,
            )

    # Fixture audit (optional)
    fix = root / "tests/fixtures/p720_bw_contract.json"
    ferrs = audit_p720_fixture(fix)
    for e in ferrs:
        print(f"FAIL P720_FIXTURE {e}", file=sys.stderr)
        fail = 1
    if fix.is_file():
        print(f"P720_FIXTURE_AUDITED={fix}")
    else:
        print("P720_FIXTURE_AUDITED=absent")

    print("BLOCKER_BW_CONTRACT_CONSUMED=required_if_claimed_as_fabric_work")
    print("BLOCKER_MBS_FROM_ELAPSED_SIM_TIME=required  # not beats*8*24 without sys_cyc norm")
    print("NOTE: rd-duck NACK 38.53 MB/s claim — runCase phase/window not established")
    print("NOTE: audit_ack ≠ reader CLOSED; arithmetic ACK labels only")
    print("NOTE: 49% idle before decode; DMA=publication memcpy only after pin/coherent")
    print(f"NOTE: R_req lock {R_REQ} MB/s/dir stands")

    if fail:
        print("QIP_SVH_CONSUMED REJECT")
        return 1
    print("PASS QIP_SVH_CONSUMED (no dead QIP headers; fixture audit clean or absent)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
