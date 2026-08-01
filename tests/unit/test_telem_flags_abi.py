#!/usr/bin/env python3
"""Positional ABI gate for Plex.sv telem_flags ↔ ARM parseCoreStatus masks.

Hole (parent 2026-07-31): dropping stub_busy from the RTL concat zero-extends
into [7:0] and shifts pps_valid/sps_valid down one bit. Daemon then reads
sps_valid where it expects stub_busy. Severity = wrong-status, not picture loss.
No prior test asserted bit POSITIONS.

Method: parse both sides from source (not grep-of-strings alone), assert the
ordered field list matches the shared SoT in status_telemetry.hpp, then MUTATE
a scratch copy of Plex.sv (remove stub_busy) and prove this gate goes RED.

Coverage declaration (rc=0 over empty inspection is UNSCORED):
  COVERAGE fields=8 rtl_path=... arm_path=... hdr_path=...
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLEX_SV = ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv"
FPGA_SPI = ROOT / "arm" / "misterplexd" / "fpga_spi.cpp"
HDR = ROOT / "host" / "libmisterplex" / "status_telemetry.hpp"
SELF = Path(__file__).resolve()

# MSB-first order as packed in Plex.sv telem_flags concat (bit7 .. bit0).
SOT_MSB_FIRST = [
    "pps_valid",
    "sps_valid",
    "stub_busy",
    "has_idr",
    "audio_underrun",
    "has_stream",
    "has_audio",
    "has_frame",
]

# ARM field name → bit index (LSB=0).
SOT_ARM_BITS = {
    "has_frame": 0,
    "has_audio": 1,
    "has_stream": 2,
    "audio_underrun": 3,
    "has_idr": 4,
    "stub_busy": 5,
    "sps_valid": 6,
    "pps_valid": 7,
}

HDR_CONST = {
    "has_frame": "kTelemFlagHasFrameBit",
    "has_audio": "kTelemFlagHasAudioBit",
    "has_stream": "kTelemFlagHasStreamBit",
    "audio_underrun": "kTelemFlagAudioUnderrunBit",
    "has_idr": "kTelemFlagHasIdrBit",
    "stub_busy": "kTelemFlagStubBusyBit",
    "sps_valid": "kTelemFlagSpsValidBit",
    "pps_valid": "kTelemFlagPpsValidBit",
}


def die(msg: str, rc: int = 1) -> int:
    print(f"FAIL telem_flags_abi: {msg}", file=sys.stderr)
    return rc


def parse_rtl_telem_flags(text: str) -> list[str]:
    """Extract MSB-first field list from wire [7:0] telem_flags = { ... };"""
    m = re.search(
        r"wire\s*\[\s*7\s*:\s*0\s*\]\s*telem_flags\s*=\s*\{([^}]+)\}",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not m:
        raise ValueError("telem_flags concat not found in RTL")
    body = m.group(1)
    # Strip comments
    body = re.sub(r"//.*?$", "", body, flags=re.MULTILINE)
    fields = [p.strip() for p in body.split(",") if p.strip()]
    # Keep only simple identifiers
    out = []
    for f in fields:
        idm = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)$", f)
        if not idm:
            raise ValueError(f"non-identifier telem_flags field: {f!r}")
        out.append(idm.group(1))
    return out


def parse_arm_flag_masks(text: str) -> dict[str, int]:
    """Map s.<field> = (flags & (1u << kTelemFlagX)) or (flags & N)."""
    # Prefer constexpr form after the gate lands.
    pat_const = re.compile(
        r"s\.(has_frame|has_audio|has_stream|audio_underrun|has_idr|stub_busy|"
        r"sps_valid|pps_valid)\s*=\s*\(flags\s*&\s*\(1u\s*<<\s*(kTelemFlag\w+)\s*\)\)"
    )
    pat_lit = re.compile(
        r"s\.(has_frame|has_audio|has_stream|audio_underrun|has_idr|stub_busy|"
        r"sps_valid|pps_valid)\s*=\s*\(flags\s*&\s*(\d+)\s*\)"
    )
    found: dict[str, int] = {}
    # Resolve constexpr names via header values if present in same parse path.
    const_vals = parse_hdr_bits(HDR.read_text(encoding="utf-8", errors="replace"))
    for m in pat_const.finditer(text):
        field, cname = m.group(1), m.group(2)
        if cname not in const_vals:
            raise ValueError(f"ARM uses {cname} but header has no value")
        found[field] = const_vals[cname]
    if len(found) == 8:
        return found
    # Fallback literal masks
    found = {}
    for m in pat_lit.finditer(text):
        field, mask_s = m.group(1), m.group(2)
        mask = int(mask_s)
        if mask <= 0 or (mask & (mask - 1)) != 0:
            raise ValueError(f"ARM mask for {field} not power-of-two: {mask}")
        bit = mask.bit_length() - 1
        found[field] = bit
    if len(found) != 8:
        raise ValueError(f"ARM flag decode incomplete: got {sorted(found)}")
    return found


def parse_hdr_bits(text: str) -> dict[str, int]:
    """kTelemFlagHasFrameBit = 0 → name→value; also reverse field map."""
    out: dict[str, int] = {}
    for m in re.finditer(
        r"inline\s+constexpr\s+int\s+(kTelemFlag\w+Bit)\s*=\s*(\d+)\s*;", text
    ):
        out[m.group(1)] = int(m.group(2))
    return out


def hdr_field_bits(text: str) -> dict[str, int]:
    consts = parse_hdr_bits(text)
    fields: dict[str, int] = {}
    for field, cname in HDR_CONST.items():
        if cname not in consts:
            raise ValueError(f"header missing {cname}")
        fields[field] = consts[cname]
    return fields


def check_paths(rtl_text: str, arm_text: str, hdr_text: str) -> list[str]:
    errs: list[str] = []
    rtl = parse_rtl_telem_flags(rtl_text)
    arm = parse_arm_flag_masks(arm_text)
    hdr = hdr_field_bits(hdr_text)

    if len(rtl) != 8:
        errs.append(f"RTL telem_flags width {len(rtl)} != 8: {rtl}")
        return errs

    if rtl != SOT_MSB_FIRST:
        errs.append(f"RTL order {rtl} != SoT {SOT_MSB_FIRST}")

    # RTL index i is bit (7-i)
    rtl_bits = {name: 7 - i for i, name in enumerate(rtl)}
    for name, bit in SOT_ARM_BITS.items():
        if rtl_bits.get(name) != bit:
            errs.append(
                f"RTL bit for {name}={rtl_bits.get(name)} want {bit} (MSB-first pack)"
            )
        if arm.get(name) != bit:
            errs.append(f"ARM bit for {name}={arm.get(name)} want {bit}")
        if hdr.get(name) != bit:
            errs.append(f"HDR bit for {name}={hdr.get(name)} want {bit}")
        if arm.get(name) != rtl_bits.get(name):
            errs.append(
                f"RTL/ARM drift on {name}: rtl={rtl_bits.get(name)} arm={arm.get(name)}"
            )
    return errs


def run_check(rtl_path: Path, arm_path: Path, hdr_path: Path) -> int:
    rtl_text = rtl_path.read_text(encoding="utf-8", errors="replace")
    arm_text = arm_path.read_text(encoding="utf-8", errors="replace")
    hdr_text = hdr_path.read_text(encoding="utf-8", errors="replace")
    try:
        rtl_fields = parse_rtl_telem_flags(rtl_text)
    except ValueError as e:
        return die(str(e))
    errs = check_paths(rtl_text, arm_text, hdr_text)
    print(
        "COVERAGE gate=telem_flags_abi "
        f"fields={len(rtl_fields)} rtl={rtl_path} arm={arm_path} hdr={hdr_path} "
        f"order_msb_first={','.join(rtl_fields)}"
    )
    if not rtl_fields:
        print("UNSCORED telem_flags_abi: empty inspection set", file=sys.stderr)
        return 77
    if errs:
        for e in errs:
            print(f"FAIL {e}", file=sys.stderr)
        return 1
    print("PASS telem_flags_abi: RTL MSB-first order matches ARM masks and header SoT")
    return 0


def mutate_drop_stub_busy(src: Path, dst: Path) -> None:
    text = src.read_text(encoding="utf-8", errors="replace")
    # Remove stub_busy from the concat (simulates "dead code cleanup").
    new, n = re.subn(
        r"(wire\s*\[\s*7\s*:\s*0\s*\]\s*telem_flags\s*=\s*\{[^}]*?),\s*stub_busy\s*,",
        r"\1,",
        text,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )
    if n != 1:
        # alternate spacing: stub_busy on its own line in the list
        new, n = re.subn(
            r"(\btelem_flags\s*=\s*\{[^}]*?)\bstub_busy\s*,\s*",
            r"\1",
            text,
            count=1,
            flags=re.MULTILINE | re.DOTALL,
        )
    if n != 1:
        raise RuntimeError("mutation failed: stub_busy not found in telem_flags concat")
    dst.write_text(new, encoding="utf-8")


def self_test() -> int:
    """Red-before-green: product GREEN, drop-stub_busy RED, empty UNSCORED≠pass."""
    if not PLEX_SV.is_file() or not FPGA_SPI.is_file() or not HDR.is_file():
        return die("missing product sources for self-test")

    rc_ok = run_check(PLEX_SV, FPGA_SPI, HDR)
    if rc_ok != 0:
        return die(f"product tree already RED rc={rc_ok} (fix ABI before mutations)")

    with tempfile.TemporaryDirectory(prefix="telem_flags_mut_") as td:
        tdir = Path(td)
        mut_sv = tdir / "Plex.sv"
        mutate_drop_stub_busy(PLEX_SV, mut_sv)
        # Run check logic on mutated RTL against product ARM (drift).
        rtl_text = mut_sv.read_text(encoding="utf-8", errors="replace")
        arm_text = FPGA_SPI.read_text(encoding="utf-8", errors="replace")
        hdr_text = HDR.read_text(encoding="utf-8", errors="replace")
        errs = check_paths(rtl_text, arm_text, hdr_text)
        if not errs:
            return die(
                "MUTATION_BLIND: dropping stub_busy did not turn gate RED — gate cannot fail"
            )
        print(
            "MUTATION_RED drop_stub_busy errs="
            + str(len(errs))
            + " sample="
            + errs[0]
        )

        # Empty inspection: no telem_flags → must not be rc=0
        empty = tdir / "empty.sv"
        empty.write_text("// no telem_flags here\n", encoding="utf-8")
        try:
            parse_rtl_telem_flags(empty.read_text())
            return die("empty RTL parse should raise")
        except ValueError:
            print("MUTATION_RED empty_rtl: parse raised (not silent pass)")

    print("PASS telem_flags_abi self-test (product GREEN, drop_stub_busy RED)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--rtl", type=Path, default=PLEX_SV)
    ap.add_argument("--arm", type=Path, default=FPGA_SPI)
    ap.add_argument("--hdr", type=Path, default=HDR)
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    return run_check(args.rtl, args.arm, args.hdr)


if __name__ == "__main__":
    sys.exit(main())
