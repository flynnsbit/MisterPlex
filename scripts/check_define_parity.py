#!/usr/bin/env python3
"""Gate Quartus-vs-Verilator macro parity AND DDR frame geometry parity.

1) Product Verilator/lint must compile the same VERILOG_MACRO set Quartus
   synthesizes. Targeted test-only fault macros are allowed only when listed in
   tests/fixtures/define_parity_allowlist.json.

2) host/libmisterplex/ddr_frame_layout.hpp must match
   fpga/.../ddr_frame_layout_params.svh for coded/display/presented geometry,
   YUV line qwords, strides, bank/doorbell. QSF FRAME_W/H must equal the
   *presented* canvas (640x480), not the coded DDR pitch (624). Without (2)
   this gate was GREEN while a 624-writer vs 640-reader pitch shear was still
   possible at the constant layer.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "fpga" / "Plex_MiSTer"
DEFAULT_ALLOWLIST = ROOT / "tests" / "fixtures" / "define_parity_allowlist.json"
DEFAULT_HOST_LAYOUT = ROOT / "host" / "libmisterplex" / "ddr_frame_layout.hpp"
DEFAULT_RTL_LAYOUT = PROJECT / "rtl" / "ddr_frame_layout_params.svh"

# Host↔RTL geometry contract. Historically BLIND in this gate (only QSF
# VERILOG_MACRO names were compared). A 624-writer vs 640-reader pitch is the
# classic 16 px/line shear; these names must stay paired.
DDR_LAYOUT_PAIRS: tuple[tuple[str, str], ...] = (
    ("kPlex480pCodedWidth", "DDR_FRAME_CODED_WIDTH"),
    ("kPlex480pCodedHeight", "DDR_FRAME_CODED_HEIGHT"),
    ("kPlex480pDisplayWidth", "DDR_FRAME_DISPLAY_WIDTH"),
    ("kPlex480pDisplayHeight", "DDR_FRAME_DISPLAY_HEIGHT"),
    ("kPlex480pPresentedWidth", "DDR_FRAME_PRESENTED_WIDTH"),
    ("kPlex480pPresentedHeight", "DDR_FRAME_PRESENTED_HEIGHT"),
    ("kPlex480pCropLeft", "DDR_FRAME_CROP_LEFT"),
    ("kPlex480pCropRight", "DDR_FRAME_CROP_RIGHT"),
    ("kPlex480pCropTop", "DDR_FRAME_CROP_TOP"),
    ("kPlex480pCropBottom", "DDR_FRAME_CROP_BOTTOM"),
    ("kPlex480pPillarboxLeft", "DDR_FRAME_PILLARBOX_LEFT"),
    ("kPlex480pPillarboxRight", "DDR_FRAME_PILLARBOX_RIGHT"),
    ("kPlex480pRgb565LineQwords", "DDR_FRAME_RGB565_LINE_QWORDS"),
    ("kPlex480pYuvLumaLineQwords", "DDR_FRAME_YUV_LUMA_LINE_QWORDS"),
    ("kPlex480pYuvChromaLineQwords", "DDR_FRAME_YUV_CHROMA_LINE_QWORDS"),
    ("kPlex480pYStrideBytes", "DDR_FRAME_Y_STRIDE_BYTES"),
    ("kPlex480pChromaStrideBytes", "DDR_FRAME_CHROMA_STRIDE_BYTES"),
    ("kPlex480pYuv420pBytes", "DDR_FRAME_YUV420P_BYTES"),
    ("kPlex480pYPlaneOffset", "DDR_FRAME_Y_PLANE_OFFSET"),
    ("kPlex480pUPlaneOffset", "DDR_FRAME_U_PLANE_OFFSET"),
    ("kPlex480pVPlaneOffset", "DDR_FRAME_V_PLANE_OFFSET"),
    ("kPlex480pYuv420pBankStride", "DDR_FRAME_YUV420P_BANK_STRIDE"),
    ("kPlex480pYuv420pDoorbellPhys", "DDR_FRAME_YUV420P_DOORBELL_PHYS"),
)

# L4 720p tier (opt-in). Paired separately so 480p presented-coded delta-16 pin stays.
DDR_LAYOUT_720P_PAIRS: tuple[tuple[str, str], ...] = (
    ("kPlex720pCodedWidth", "DDR_FRAME_720P_CODED_WIDTH"),
    ("kPlex720pCodedHeight", "DDR_FRAME_720P_CODED_HEIGHT"),
    ("kPlex720pDisplayWidth", "DDR_FRAME_720P_DISPLAY_WIDTH"),
    ("kPlex720pDisplayHeight", "DDR_FRAME_720P_DISPLAY_HEIGHT"),
    ("kPlex720pPresentedWidth", "DDR_FRAME_720P_PRESENTED_WIDTH"),
    ("kPlex720pPresentedHeight", "DDR_FRAME_720P_PRESENTED_HEIGHT"),
    ("kPlex720pCropLeft", "DDR_FRAME_720P_CROP_LEFT"),
    ("kPlex720pCropRight", "DDR_FRAME_720P_CROP_RIGHT"),
    ("kPlex720pCropTop", "DDR_FRAME_720P_CROP_TOP"),
    ("kPlex720pCropBottom", "DDR_FRAME_720P_CROP_BOTTOM"),
    ("kPlex720pPillarboxLeft", "DDR_FRAME_720P_PILLARBOX_LEFT"),
    ("kPlex720pPillarboxRight", "DDR_FRAME_720P_PILLARBOX_RIGHT"),
    ("kPlex720pYuvLumaLineQwords", "DDR_FRAME_720P_YUV_LUMA_LINE_QWORDS"),
    ("kPlex720pYuvChromaLineQwords", "DDR_FRAME_720P_YUV_CHROMA_LINE_QWORDS"),
    ("kPlex720pYStrideBytes", "DDR_FRAME_720P_Y_STRIDE_BYTES"),
    ("kPlex720pChromaStrideBytes", "DDR_FRAME_720P_CHROMA_STRIDE_BYTES"),
    ("kPlex720pYuv420pBytes", "DDR_FRAME_720P_YUV420P_BYTES"),
    ("kPlex720pYPlaneOffset", "DDR_FRAME_720P_Y_PLANE_OFFSET"),
    ("kPlex720pUPlaneOffset", "DDR_FRAME_720P_U_PLANE_OFFSET"),
    ("kPlex720pVPlaneOffset", "DDR_FRAME_720P_V_PLANE_OFFSET"),
    ("kPlex720pYuv420pBankStride", "DDR_FRAME_720P_YUV420P_BANK_STRIDE"),
    ("kPlex720pPhysBase", "DDR_FRAME_720P_PHYS_BASE"),
    ("kPlex720pYuv420pDoorbellPhys", "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS"),
)


@dataclass(frozen=True)
class Macro:
    name: str
    value: str
    source: str


def strip_hash_comment(line: str) -> str:
    return line.split("#", 1)[0].strip()


def normalize_value(value: str | None) -> str:
    if value is None or value == "":
        return "1"
    return value.strip().strip('"')


def parse_verilog_macro(raw: str, source: str) -> Macro | None:
    raw = raw.strip().strip('"')
    m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)(?:=(.*))?$", raw)
    if not m:
        return None
    return Macro(m.group(1), normalize_value(m.group(2)), source)


def discover_quartus_macros(qsf: Path = PROJECT / "Plex.qsf") -> dict[str, Macro]:
    macros: dict[str, Macro] = {}
    for line_no, raw in enumerate(qsf.read_text(errors="ignore").splitlines(), 1):
        line = strip_hash_comment(raw)
        m = re.search(r"\bset_global_assignment\b.*?-name\s+VERILOG_MACRO\s+(.+)$", line)
        if not m:
            continue
        macro = parse_verilog_macro(m.group(1), f"{qsf.relative_to(ROOT)}:{line_no}")
        if macro:
            macros[macro.name] = macro

    build_id = PROJECT / "sys" / "build_id.tcl"
    if build_id.exists() and "`define BUILD_DATE" in build_id.read_text(errors="ignore"):
        macros["BUILD_DATE"] = Macro(
            "BUILD_DATE",
            "<generated>",
            f"{build_id.relative_to(ROOT)}:8",
        )
    return macros


def verilator_lint_macros(qsf: Path = PROJECT / "Plex.qsf") -> dict[str, Macro]:
    return {
        name: Macro(name, "lint" if name == "BUILD_DATE" else macro.value, "scripts/rtl_lint.py:qsf-macro-injection")
        for name, macro in discover_quartus_macros(qsf).items()
    }


def verilator_define_args(qsf: Path = PROJECT / "Plex.qsf") -> list[str]:
    args: list[str] = []
    for name, macro in sorted(verilator_lint_macros(qsf).items()):
        value = macro.value
        if name == "BUILD_DATE":
            value = '\\"lint\\"'
        args.append(f"-D{name}={value}")
    return args


def discover_test_macros(paths: list[Path] | None = None) -> dict[str, list[Macro]]:
    if paths is None:
        paths = [ROOT / "tests" / "unit", ROOT / "tests" / "rtl", ROOT / "scripts", ROOT / "Makefile"]
    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files.extend(p for p in path.rglob("*") if p.is_file())
        elif path.is_file():
            files.append(path)

    found: dict[str, list[Macro]] = {}
    patterns = [
        re.compile(r"\+define\+([A-Za-z_][A-Za-z0-9_]*)(?:=([^\s\\]+))?"),
        re.compile(r"(?<!\w)-D([A-Za-z_][A-Za-z0-9_]*)(?:=([^\s\"']+))?"),
    ]
    for path in files:
        if path.resolve() == Path(__file__).resolve():
            continue
        if path.suffix not in {".sh", ".py", ".sv", ".svh", ".v", ""} and path.name != "Makefile":
            continue
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(errors="ignore")
        for pattern in patterns:
            for m in pattern.finditer(text):
                name = m.group(1)
                value = normalize_value(m.group(2))
                found.setdefault(name, []).append(Macro(name, value, rel))

    return {name: sorted(items, key=lambda m: m.source) for name, items in sorted(found.items())}


def load_allowlist(path: Path = DEFAULT_ALLOWLIST) -> tuple[dict[str, str], set[str]]:
    data = json.loads(path.read_text())
    return (
        {str(k): str(v) for k, v in data.get("test_only_macros", {}).items()},
        {str(k) for k in data.get("volatile_value_macros", {})},
    )


def format_table(quartus: dict[str, Macro], lint: dict[str, Macro], tests: dict[str, list[Macro]],
                 allow_test: dict[str, str], volatile_values: set[str]) -> str:
    names = sorted(set(quartus) | set(lint) | set(tests))
    lines = ["| macro | Quartus | Verilator/lint | Verilator targeted tests | status |",
             "|---|---|---|---|---|"]
    for name in names:
        q = quartus.get(name)
        l = lint.get(name)
        t = tests.get(name, [])
        qv = f"{q.value} ({q.source})" if q else "—"
        lv = f"{l.value} ({l.source})" if l else "—"
        tv = "<br>".join(f"{m.value} ({m.source})" for m in t) if t else "—"
        if q and l:
            if q.value != l.value and name not in volatile_values:
                status = "VALUE-DIFF"
            else:
                status = "shared"
        elif t and not q and not l and name in allow_test:
            status = f"allowed test-only: {allow_test[name]}"
        elif q and not l:
            status = "QUARTUS-ONLY"
        elif l and not q:
            status = "VERILATOR-LINT-ONLY"
        elif t and not q and not l:
            status = "UNDECLARED TEST-ONLY"
        else:
            status = "mixed"
        lines.append(f"| `{name}` | {qv} | {lv} | {tv} | {status} |")
    return "\n".join(lines)


def _parse_int_token(raw: str) -> int:
    s = raw.strip().strip('"').replace("_", "")
    # Drop C++ integer suffixes: 0x80000u, 624ull, etc.
    s = re.sub(r"[uUlL]+$", "", s)
    # SystemVerilog sized literals: 32'h0008_0000, 10'd624, 'h100
    m = re.fullmatch(r"(?:\d+)?'([hHdDbBoO])([0-9a-fA-F]+)", s)
    if m:
        base = {"h": 16, "H": 16, "d": 10, "D": 10, "b": 2, "B": 2, "o": 8, "O": 8}[m.group(1)]
        return int(m.group(2), base)
    if re.fullmatch(r"0[xX][0-9a-fA-F]+", s):
        return int(s, 16)
    if re.fullmatch(r"-?\d+", s):
        return int(s, 10)
    raise ValueError(f"unparseable integer token: {raw!r}")


def parse_rtl_layout_consts(path: Path = DEFAULT_RTL_LAYOUT) -> dict[str, int]:
    text = path.read_text(errors="ignore")
    out: dict[str, int] = {}
    for m in re.finditer(
        r"localparam\s+int\s+(DDR_FRAME_[A-Z0-9_]+)\s*=\s*([^;]+);",
        text,
    ):
        out[m.group(1)] = _parse_int_token(m.group(2))
    return out


def parse_host_layout_consts(path: Path = DEFAULT_HOST_LAYOUT) -> dict[str, int]:
    text = path.read_text(errors="ignore")
    out: dict[str, int] = {}
    # constexpr Type name{value};  or  constexpr int/uint32_t name = value;
    # Includes kPlex720p* for L4 tier parity with DDR_FRAME_720P_*.
    for m in re.finditer(
        r"constexpr\s+(?:\w+\s+)+(kPlex480p\w+|kPlex720p\w+|kYuv420Black\w+|kDdrFrame\w+)\s*(?:=\s*([^;]+);|\{\s*([^}]+)\s*\}\s*;)",
        text,
    ):
        name = m.group(1)
        raw = m.group(2) if m.group(2) is not None else m.group(3)
        try:
            out[name] = _parse_int_token(raw)
        except ValueError:
            # Skip non-numeric (e.g. other constexpr helpers).
            continue
    return out


def check_ddr_layout_parity(
    host: dict[str, int],
    rtl: dict[str, int],
    quartus: dict[str, Macro],
    *,
    fault_rtl_coded_width: int | None = None,
) -> list[str]:
    """Compare host/libmisterplex/ddr_frame_layout.hpp ↔ rtl params ↔ QSF FRAME_*."""
    errors: list[str] = []
    rtl_eff = dict(rtl)
    if fault_rtl_coded_width is not None:
        rtl_eff["DDR_FRAME_CODED_WIDTH"] = fault_rtl_coded_width
        # Keep the classic shear pair coherent under the fault hook.
        rtl_eff["DDR_FRAME_Y_STRIDE_BYTES"] = fault_rtl_coded_width
        rtl_eff["DDR_FRAME_YUV_LUMA_LINE_QWORDS"] = fault_rtl_coded_width // 8
        rtl_eff["DDR_FRAME_YUV_CHROMA_LINE_QWORDS"] = fault_rtl_coded_width // 16
        rtl_eff["DDR_FRAME_CHROMA_STRIDE_BYTES"] = fault_rtl_coded_width // 2

    print("DEFINE_PARITY_DDR_LAYOUT_BEGIN")
    print("| host | rtl | host_val | rtl_val | status |")
    print("|---|---|---|---|---|")
    for host_name, rtl_name in DDR_LAYOUT_PAIRS:
        hv = host.get(host_name)
        rv = rtl_eff.get(rtl_name)
        if hv is None and rv is None:
            status = "MISSING-BOTH"
            errors.append(f"{host_name}/{rtl_name}: missing on both host and RTL layout headers")
        elif hv is None:
            status = "HOST-MISSING"
            errors.append(f"{host_name}: missing from host ddr_frame_layout.hpp (RTL {rtl_name}={rv})")
        elif rv is None:
            status = "RTL-MISSING"
            errors.append(f"{rtl_name}: missing from ddr_frame_layout_params.svh (host {host_name}={hv})")
        elif hv != rv:
            status = "VALUE-DIFF"
            errors.append(
                f"{host_name}={hv} != {rtl_name}={rv}: ARM writer / RTL reader geometry divergence "
                f"(classic shear if Y stride/CODED_W disagree)"
            )
        else:
            status = "shared"
        print(f"| `{host_name}` | `{rtl_name}` | {hv if hv is not None else '—'} | {rv if rv is not None else '—'} | {status} |")
    print("DEFINE_PARITY_DDR_LAYOUT_END")

    # L4 720p tier pairs (identity canvas; no presented-coded delta-16 pin).
    print("DEFINE_PARITY_DDR_LAYOUT_720P_BEGIN")
    print("| host | rtl | host_val | rtl_val | status |")
    print("|---|---|---|---|---|")
    for host_name, rtl_name in DDR_LAYOUT_720P_PAIRS:
        hv = host.get(host_name)
        rv = rtl.get(rtl_name)  # unfaulted RTL; 720p tier is not in shear-fault path
        if hv is None and rv is None:
            status = "MISSING-BOTH"
            errors.append(f"{host_name}/{rtl_name}: missing on both host and RTL 720p layout headers")
        elif hv is None:
            status = "HOST-MISSING"
            errors.append(f"{host_name}: missing from host ddr_frame_layout.hpp (RTL {rtl_name}={rv})")
        elif rv is None:
            status = "RTL-MISSING"
            errors.append(f"{rtl_name}: missing from ddr_frame_layout_params.svh (host {host_name}={hv})")
        elif hv != rv:
            status = "VALUE-DIFF"
            errors.append(
                f"{host_name}={hv} != {rtl_name}={rv}: L4 ARM writer / RTL reader 720p divergence"
            )
        else:
            status = "shared"
        print(f"| `{host_name}` | `{rtl_name}` | {hv if hv is not None else '—'} | {rv if rv is not None else '—'} | {status} |")
    print("DEFINE_PARITY_DDR_LAYOUT_720P_END")

    coded720 = rtl.get("DDR_FRAME_720P_CODED_WIDTH")
    y_stride720 = rtl.get("DDR_FRAME_720P_Y_STRIDE_BYTES")
    y_qw720 = rtl.get("DDR_FRAME_720P_YUV_LUMA_LINE_QWORDS")
    c_qw720 = rtl.get("DDR_FRAME_720P_YUV_CHROMA_LINE_QWORDS")
    if None not in (coded720, y_stride720) and coded720 != y_stride720:
        errors.append(
            f"DDR_FRAME_720P_Y_STRIDE_BYTES={y_stride720} must equal "
            f"DDR_FRAME_720P_CODED_WIDTH={coded720}"
        )
    if None not in (coded720, y_qw720) and y_qw720 != coded720 // 8:
        errors.append(
            f"DDR_FRAME_720P_YUV_LUMA_LINE_QWORDS={y_qw720} must equal CODED/8="
            f"{coded720 // 8 if coded720 is not None else '?'}"
        )
    if None not in (coded720, c_qw720) and c_qw720 != coded720 // 16:
        errors.append(
            f"DDR_FRAME_720P_YUV_CHROMA_LINE_QWORDS={c_qw720} must equal CODED/16="
            f"{coded720 // 16 if coded720 is not None else '?'}"
        )
    phys720 = rtl.get("DDR_FRAME_720P_PHYS_BASE")
    bank720 = rtl.get("DDR_FRAME_720P_YUV420P_BANK_STRIDE")
    db720 = rtl.get("DDR_FRAME_720P_YUV420P_DOORBELL_PHYS")
    if None not in (phys720, bank720, db720):
        expect_db = phys720 + 2 * bank720 - 0x1000
        if db720 != expect_db:
            errors.append(
                f"DDR_FRAME_720P_YUV420P_DOORBELL_PHYS={db720:#x} != "
                f"phys+2*bank-0x1000={expect_db:#x}"
            )

    # Internal product relations (source-proven; kill 640-as-pitch theories).
    coded = rtl_eff.get("DDR_FRAME_CODED_WIDTH")
    presented = rtl_eff.get("DDR_FRAME_PRESENTED_WIDTH")
    display = rtl_eff.get("DDR_FRAME_DISPLAY_WIDTH")
    y_stride = rtl_eff.get("DDR_FRAME_Y_STRIDE_BYTES")
    y_qw = rtl_eff.get("DDR_FRAME_YUV_LUMA_LINE_QWORDS")
    c_qw = rtl_eff.get("DDR_FRAME_YUV_CHROMA_LINE_QWORDS")
    pillar_l = rtl_eff.get("DDR_FRAME_PILLARBOX_LEFT")
    pillar_r = rtl_eff.get("DDR_FRAME_PILLARBOX_RIGHT")
    if None not in (coded, y_stride) and coded != y_stride:
        errors.append(
            f"DDR_FRAME_Y_STRIDE_BYTES={y_stride} must equal DDR_FRAME_CODED_WIDTH={coded} "
            f"(YUV line pitch is coded width, never presented width)"
        )
    if None not in (coded, y_qw) and y_qw != coded // 8:
        errors.append(
            f"DDR_FRAME_YUV_LUMA_LINE_QWORDS={y_qw} must equal CODED_WIDTH/8={coded // 8 if coded is not None else '?'}"
        )
    if None not in (coded, c_qw) and c_qw != coded // 16:
        errors.append(
            f"DDR_FRAME_YUV_CHROMA_LINE_QWORDS={c_qw} must equal CODED_WIDTH/16={coded // 16 if coded is not None else '?'}"
        )
    if None not in (pillar_l, display, pillar_r, presented) and (
        pillar_l + display + pillar_r != presented
    ):
        errors.append(
            f"pillarbox math broken: {pillar_l}+{display}+{pillar_r} != presented {presented}"
        )
    if None not in (coded, presented) and (presented - coded) != 16:
        # Pin the 16 px figure used in the 624-vs-640 shear arithmetic.
        errors.append(
            f"presented-coded delta is {presented - coded}, expected 16 "
            f"(640-624); used when reasoning about wrong FRAME_W pitch"
        )

    # QSF FRAME_W/H are the *presented* scanout canvas, not coded DDR pitch.
    fw = quartus.get("FRAME_W")
    fh = quartus.get("FRAME_H")
    if fw is None:
        errors.append("FRAME_W: missing from Quartus product macros (presented scanout width)")
    else:
        try:
            fw_v = int(fw.value, 0)
        except ValueError:
            fw_v = None
            errors.append(f"FRAME_W: unparseable Quartus value {fw.value!r}")
        if fw_v is not None and presented is not None and fw_v != presented:
            errors.append(
                f"FRAME_W Quartus={fw_v} != DDR_FRAME_PRESENTED_WIDTH={presented}: "
                f"scanout canvas must match presented width (not coded {coded})"
            )
        if fw_v is not None and coded is not None and fw_v == coded:
            errors.append(
                f"FRAME_W={fw_v} equals CODED_WIDTH — presented scanout collapsed onto coded "
                f"pitch; pillarbox contract lost"
            )
    if fh is None:
        errors.append("FRAME_H: missing from Quartus product macros (presented scanout height)")
    else:
        try:
            fh_v = int(fh.value, 0)
        except ValueError:
            fh_v = None
            errors.append(f"FRAME_H: unparseable Quartus value {fh.value!r}")
        rtl_ph = rtl_eff.get("DDR_FRAME_PRESENTED_HEIGHT")
        if fh_v is not None and rtl_ph is not None and fh_v != rtl_ph:
            errors.append(
                f"FRAME_H Quartus={fh_v} != DDR_FRAME_PRESENTED_HEIGHT={rtl_ph}"
            )

    return errors


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    ap.add_argument("--qsf", type=Path, default=PROJECT / "Plex.qsf")
    ap.add_argument("--host-layout", type=Path, default=DEFAULT_HOST_LAYOUT)
    ap.add_argument("--rtl-layout", type=Path, default=DEFAULT_RTL_LAYOUT)
    ap.add_argument("--drop-verilator-macro", action="append", default=[],
                    help="self-test hook: remove a product lint macro before comparison")
    ap.add_argument(
        "--fault-rtl-coded-width",
        type=int,
        default=None,
        help="self-test hook: override RTL CODED_WIDTH/Y_STRIDE before layout compare "
        "(e.g. 320 reproduces ARM624-vs-RTL320 shear; expect exit 1)",
    )
    args = ap.parse_args(argv[1:])

    quartus = discover_quartus_macros(args.qsf)
    lint = verilator_lint_macros(args.qsf)
    for name in args.drop_verilator_macro:
        lint.pop(name, None)
    tests = discover_test_macros()
    allow_test, volatile_values = load_allowlist(args.allowlist)

    print("DEFINE_PARITY_TABLE_BEGIN")
    print(format_table(quartus, lint, tests, allow_test, volatile_values))
    print("DEFINE_PARITY_TABLE_END")

    errors: list[str] = []
    for name, macro in sorted(quartus.items()):
        if name not in lint:
            errors.append(f"{name}: set by Quartus at {macro.source} but absent from Verilator/lint product macros")
    for name, macro in sorted(lint.items()):
        if name not in quartus:
            errors.append(f"{name}: set by Verilator/lint at {macro.source} but absent from Quartus product macros")
    for name in sorted(set(quartus) & set(lint)):
        if quartus[name].value != lint[name].value and name not in volatile_values:
            errors.append(f"{name}: Quartus value {quartus[name].value!r} != Verilator/lint value {lint[name].value!r}")
    for name in sorted(set(tests) - set(quartus) - set(lint)):
        if name not in allow_test:
            sources = ", ".join(m.source for m in tests[name])
            errors.append(f"{name}: test-only macro is not declared in {args.allowlist} ({sources})")

    host_layout = parse_host_layout_consts(args.host_layout)
    rtl_layout = parse_rtl_layout_consts(args.rtl_layout)
    errors.extend(
        check_ddr_layout_parity(
            host_layout,
            rtl_layout,
            quartus,
            fault_rtl_coded_width=args.fault_rtl_coded_width,
        )
    )

    if errors:
        print("DEFINE_PARITY_REJECTED(exit=1):", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        return 1
    print(
        "PASS define parity: Quartus product macros match Verilator/lint; "
        "test-only macros are allowlisted; "
        "DDR host/RTL layout constants and QSF FRAME_W/H↔presented agree"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
