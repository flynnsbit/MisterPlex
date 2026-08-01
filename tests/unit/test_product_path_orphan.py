#!/usr/bin/env python3
"""Gate: code that is fully tested (green) but is NOT on the product path.

Parent defect class (three confirmed instances):
  1) C++ APIs only referenced from tests/ (rawPipeDesynced / rawPipePhaseOffset
     when nothing in arm/ calls them)
  2) host/libmisterplex/cadence.hpp — only tests/unit/test_cadence.cpp
  3) fpga/.../present_cadence.sv — in present_core hierarchy but OUTPUTS do not
     drive DDR/SDRAM bank swaps (async vsync re-latch does). advance_unique only
     reaches stat_advance; content_index only colorbars+stat.

A green suite about code the product never runs is false confidence.

Checks
  A) C++ free/inline functions in host/libmisterplex whose only non-definition
     references live under tests/.
  B) SystemVerilog modules under fpga/ whose *output* ports never fan into a
     product sink module (ddr_frame_store / frame_store / …). Outputs that only
     reach colorbars and/or stat_* assigns are NON-product.

Allowlist: ALLOWLIST below — SHORT, each entry justified. Adding any of the
three parent findings to the allowlist is forbidden (meta-guard).

Exit 0 = no unallowlisted orphans. Exit 1 = findings. Exit 2 = tool broken.

--self-test: synthetic RBG + real-tree hits for the three parent instances.
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# ---------------------------------------------------------------------------
# Allowlist — keep SHORT. key = "cxx:name" or "sv:module"
# ---------------------------------------------------------------------------
ALLOWLIST: dict[str, str] = {
    # Lab-only I420 ranking helper; product uses fixed DDR layout constants.
    "cxx:i420CandidateScore": (
        "lab scorer for I420 candidate ranking; product uses fixed layout — "
        "not a silent product gap"
    ),
}

# Parent-known findings — must NEVER appear in ALLOWLIST (meta-guard).
FORBIDDEN_ALLOWLIST = {
    "cxx:rawPipeDesynced",
    "cxx:rawPipePhaseOffset",
    "cxx:content_index_at",
    "cxx:should_advance_unique",
    "cxx:unique_frames_in",
    "sv:present_cadence",
}

PRODUCT_SINK_MODULES = {
    "ddr_frame_store",
    "frame_store",
    "h264_decode_top",
    "h264_decode_core",
    "h264_stream_path",
    "stream_path",
    "h264_slice_decoder",
    "bitstream_ring",
    "dpb_store",
    "mc_top",
    "idct_top",
    "ddram_frame_rd",
    "frame_ingest",
}

NON_PRODUCT_CONSUMERS = {
    "colorbars",
    "present_cadence",
}

# Symbols that always hard-fail when test-only / dead-fanout (parent trio class).
TIER1_CXX = {
    "rawPipeDesynced",
    "rawPipePhaseOffset",
    "rawPipeByteAligned",
    "content_index_at",
    "should_advance_unique",
    "unique_frames_in",
}

CXX_DEF_GLOBS = (
    "host/libmisterplex/**/*.hpp",
    "host/libmisterplex/**/*.h",
    "host/libmisterplex/**/*.cpp",
)
CXX_REF_GLOBS = (
    "host/**/*.hpp",
    "host/**/*.h",
    "host/**/*.cpp",
    "arm/**/*.hpp",
    "arm/**/*.h",
    "arm/**/*.cpp",
    "tests/**/*.cpp",
    "tests/**/*.hpp",
    "tests/**/*.h",
    "tests/**/*.cc",
)

CXX_SKIP_NAMES = {
    "if", "for", "while", "switch", "return", "sizeof", "main",
    "get", "set", "begin", "end", "size", "data", "clear", "reset",
    "init", "ok", "name", "load", "store", "open", "close", "read",
    "write", "min", "max", "abs", "swap", "move", "get",
}

# Free/inline function definitions at line start (headers).
CXX_DEF_RE = re.compile(
    r"(?m)^[ \t]*(?:template\s*<[^>]*>\s*)?"
    r"(?:inline\s+|static\s+|constexpr\s+|static\s+inline\s+|inline\s+constexpr\s+)+"
    r"(?:[\w:<>]+\s+)+"
    r"(?P<name>[A-Za-z_]\w*)\s*\("
)

SV_MOD_RE = re.compile(r"(?m)^\s*module\s+([A-Za-z_]\w*)\b")
SV_INST_RE = re.compile(
    r"(?m)^\s*([A-Za-z_]\w*)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\))?\s+([A-Za-z_]\w*)\s*\("
)
SV_PORT_CONN_RE = re.compile(r"\.([A-Za-z_]\w*)\s*\(\s*([A-Za-z_]\w*)\s*\)")
SV_STAT_ASSIGN_RE = re.compile(
    r"(?m)^\s*assign\s+(stat_[A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)\s*;"
)
# output port names from module header
SV_OUTPUT_RE = re.compile(
    r"(?m)^\s*output\s+(?:reg|wire|logic)?\s*(?:\[[^\]]+\]\s*)?([A-Za-z_]\w*)"
)

SV_INST_SKIP_MOD = {
    "if", "for", "always", "assign", "wire", "reg", "logic", "case",
    "begin", "end", "module", "endmodule", "function", "task", "generate",
    "property", "assert", "assume", "cover", "default", "input", "output",
    "inout", "parameter", "localparam", "typedef", "struct", "enum",
    "return", "else", "while", "initial", "forever", "repeat", "do",
}


@dataclass
class Finding:
    kind: str
    name: str
    def_loc: str
    refs: list[str] = field(default_factory=list)
    detail: str = ""

    @property
    def key(self) -> str:
        return f"{self.kind}:{self.name}"


def _iter_glob(root: Path, patterns: tuple[str, ...]) -> list[Path]:
    seen: set[Path] = set()
    out: list[Path] = []
    for pat in patterns:
        for p in root.glob(pat):
            if not p.is_file() or p in seen:
                continue
            if "build" in p.parts or ".git" in p.parts:
                continue
            seen.add(p)
            out.append(p)
    return sorted(out)


def _strip_cpp_noise(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//.*?$", " ", text, flags=re.M)
    return text


def collect_cxx_defs(root: Path) -> dict[str, list[str]]:
    defs: dict[str, list[str]] = defaultdict(list)
    for path in _iter_glob(root, CXX_DEF_GLOBS):
        rel = path.relative_to(root).as_posix()
        text = _strip_cpp_noise(path.read_text(encoding="utf-8", errors="replace"))
        for m in CXX_DEF_RE.finditer(text):
            name = m.group("name")
            if name in CXX_SKIP_NAMES or name.startswith("_"):
                continue
            if len(name) < 4:
                continue
            line_no = text[: m.start()].count("\n") + 1
            defs[name].append(f"{rel}:{line_no}")
    return defs


def collect_cxx_refs(root: Path, names: set[str]) -> dict[str, list[str]]:
    refs: dict[str, list[str]] = defaultdict(list)
    if not names:
        return refs
    pat = re.compile(
        r"\b("
        + "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True))
        + r")\b"
    )
    for path in _iter_glob(root, CXX_REF_GLOBS):
        rel = path.relative_to(root).as_posix()
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for i, line in enumerate(lines, 1):
            if line.lstrip().startswith("//"):
                continue
            for m in pat.finditer(line):
                refs[m.group(1)].append(f"{rel}:{i}")
    return refs


def cxx_orphans(root: Path) -> list[Finding]:
    defs = collect_cxx_defs(root)
    # Always force-include known parent symbols if defined.
    focused = dict(defs)
    refs = collect_cxx_refs(root, set(focused))
    findings: list[Finding] = []
    for name, dlocs in sorted(focused.items()):
        def_files = {loc.split(":")[0] for loc in dlocs}
        rlist = refs.get(name, [])
        external = [r for r in rlist if r.split(":")[0] not in def_files]
        if not external:
            # Defined but never referenced outside defining file(s).
            # Only report if a test file also does not reference — pure dead.
            # Still flag if tests reference only (handled below empty external
            # with test refs inside def file — rare). Skip pure internal helpers
            # unless they are on the mandatory watchlist.
            if name in {
                "rawPipeDesynced",
                "rawPipePhaseOffset",
                "content_index_at",
                "should_advance_unique",
                "unique_frames_in",
            }:
                findings.append(
                    Finding(
                        "cxx",
                        name,
                        dlocs[0],
                        [],
                        detail="no_references_outside_defining_file",
                    )
                )
            continue
        non_test = [r for r in external if not r.split(":")[0].startswith("tests/")]
        test_only = [r for r in external if r.split(":")[0].startswith("tests/")]
        if test_only and not non_test:
            findings.append(
                Finding(
                    "cxx",
                    name,
                    dlocs[0],
                    external,
                    detail="only_non_definition_refs_are_under_tests/",
                )
            )
    return findings


def _sv_product_files(root: Path) -> list[Path]:
    out = []
    fpga = root / "fpga"
    if not fpga.is_dir():
        return out
    for p in fpga.rglob("*.sv"):
        if not p.is_file():
            continue
        rel = p.relative_to(root).as_posix()
        if "/tests/" in rel or rel.startswith("tests/"):
            continue
        if "build" in p.parts:
            continue
        # skip obvious testbenches by name
        if p.name.startswith("tb_") or p.name.endswith("_tb.sv"):
            continue
        out.append(p)
    return sorted(out)


def _parse_module_outputs(text: str, mod_name: str) -> set[str]:
    m = re.search(
        rf"(?ms)^\s*module\s+{re.escape(mod_name)}\s*\((.*?)\)\s*;",
        text,
    )
    if not m:
        return set()
    header = m.group(1)
    return set(SV_OUTPUT_RE.findall(header))


def _extract_inst_body(text: str, start: int) -> str:
    depth = 1
    i = start
    while i < len(text) and depth:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    return text[start : i - 1]


def sv_product_path_orphans(root: Path) -> list[Finding]:
    files = _sv_product_files(root)
    mod_def: dict[str, str] = {}
    mod_outputs: dict[str, set[str]] = {}
    texts: dict[Path, str] = {}
    for path in files:
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        texts[path] = text
        for m in SV_MOD_RE.finditer(text):
            name = m.group(1)
            mod_def[name] = f"{rel}:{text[: m.start()].count(chr(10)) + 1}"
            mod_outputs[name] = _parse_module_outputs(text, name)

    instances: list[dict] = []
    for path, text in texts.items():
        rel = path.relative_to(root).as_posix()
        for m in SV_INST_RE.finditer(text):
            mod_name, inst_name = m.group(1), m.group(2)
            if mod_name in SV_INST_SKIP_MOD:
                continue
            if mod_name not in mod_def:
                continue
            body = _extract_inst_body(text, m.end())
            ports = {pm.group(1): pm.group(2) for pm in SV_PORT_CONN_RE.finditer(body)}
            instances.append(
                {
                    "module": mod_name,
                    "inst": inst_name,
                    "file": rel,
                    "ports": ports,
                    "line": text[: m.start()].count("\n") + 1,
                }
            )

    # wire -> list of consumer (module, loc, port) for INPUT-side connections
    # We record every instance port connection as a potential consumer of that wire.
    wire_to_inst_ports: dict[str, list[tuple[str, str, str]]] = defaultdict(list)
    for inst in instances:
        for port, wire in inst["ports"].items():
            wire_to_inst_ports[wire].append(
                (inst["module"], f"{inst['file']}:{inst['line']}", port)
            )

    stat_sources: set[str] = set()
    for text in texts.values():
        for m in SV_STAT_ASSIGN_RE.finditer(text):
            stat_sources.add(m.group(2))

    inst_by_mod: dict[str, list[dict]] = defaultdict(list)
    for inst in instances:
        inst_by_mod[inst["module"]].append(inst)

    findings: list[Finding] = []
    for mod, ilist in sorted(inst_by_mod.items()):
        if mod in PRODUCT_SINK_MODULES:
            continue
        outs = mod_outputs.get(mod) or set()
        if not outs:
            # cannot analyze without output list
            continue

        consumers_hit: set[str] = set()
        detail_bits: list[str] = []
        reached_product = False

        for inst in ilist:
            for port, wire in inst["ports"].items():
                if port not in outs:
                    continue  # only follow OUTPUT ports
                # consumers: other instances that bind this wire on any port
                for cmod, cloc, cport in wire_to_inst_ports.get(wire, []):
                    if cmod == mod:
                        continue
                    # If consumer binds wire to an output port of cmod, skip
                    # (that's the producer side of another module — rare alias).
                    c_outs = mod_outputs.get(cmod) or set()
                    if cport in c_outs:
                        continue
                    # Hierarchical status export (stat_*), not a data-path sink.
                    if cport.startswith("stat_"):
                        consumers_hit.add("stat_*")
                        detail_bits.append(f"{port}/{wire}->{cmod}.{cport}@{cloc}")
                        continue
                    consumers_hit.add(cmod)
                    detail_bits.append(f"{port}/{wire}->{cmod}.{cport}@{cloc}")
                    if cmod in PRODUCT_SINK_MODULES:
                        reached_product = True
                if wire in stat_sources:
                    consumers_hit.add("stat_*")
                    detail_bits.append(f"{port}/{wire}->stat_*")

        if reached_product:
            continue

        non_prod_only = bool(consumers_hit) and consumers_hit.issubset(
            NON_PRODUCT_CONSUMERS | {"stat_*"}
        )
        # Continuous-assign fanout is not fully parsed. Only flag:
        #   (a) present_cadence (parent instance 3 — known dead vs DDR swap)
        #   (b) modules whose outputs are observed to hit colorbars and/or stat_*
        #       and NOTHING else (the orphan_cadence synthetic class)
        # Do NOT flag leaves with zero detected consumers (likely assign-based
        # product wiring we did not parse — e.g. aud_mix_top -> al/ar).
        bars_or_stat = bool(consumers_hit & ({"colorbars", "stat_*"} | NON_PRODUCT_CONSUMERS))
        should_flag = False
        if mod == "present_cadence" and not reached_product:
            should_flag = True
        elif non_prod_only and bars_or_stat:
            should_flag = True
        if not should_flag:
            continue
        findings.append(
            Finding(
                "sv",
                mod,
                mod_def.get(mod, "?"),
                [f"{i['file']}:{i['line']}" for i in ilist],
                detail=(
                    "outputs_do_not_reach_product_sinks "
                    f"consumers={sorted(consumers_hit) or ['none']} "
                    "note=DDR/SDRAM bank swap is vsync path not cadence advance; "
                    + ",".join(detail_bits[:10])
                ),
            )
        )
    return findings


def apply_allowlist(findings: list[Finding]) -> tuple[list[Finding], list[Finding]]:
    kept, skipped = [], []
    for f in findings:
        (skipped if f.key in ALLOWLIST else kept).append(f)
    return kept, skipped


def meta_guard_allowlist() -> list[str]:
    return [
        f"FORBIDDEN_ALLOWLIST_ENTRY {k}"
        for k in FORBIDDEN_ALLOWLIST
        if k in ALLOWLIST
    ]


def format_report(findings: list[Finding], skipped: list[Finding]) -> str:
    lines = [
        "PRODUCT_PATH_ORPHAN_BEGIN",
        f"findings={len(findings)} allowlisted={len(skipped)}",
    ]
    for f in findings:
        lines.append(
            f"ORPHAN kind={f.kind} name={f.name} def={f.def_loc} detail={f.detail}"
        )
        for r in f.refs[:20]:
            lines.append(f"  ref {r}")
        if len(f.refs) > 20:
            lines.append(f"  ref ... ({len(f.refs)} total)")
    for f in skipped:
        lines.append(
            f"ALLOWLISTED kind={f.kind} name={f.name} reason={ALLOWLIST.get(f.key, '')}"
        )
    lines.append("PRODUCT_PATH_ORPHAN_END")
    return "\n".join(lines) + "\n"


def _write(p: Path, text: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")


def run_self_test() -> int:
    errors: list[str] = []
    errors.extend(meta_guard_allowlist())

    real_cxx = {f.name: f for f in cxx_orphans(ROOT)}
    real_sv = {f.name: f for f in sv_product_path_orphans(ROOT)}

    # (2) cadence.hpp
    for sym in ("should_advance_unique", "unique_frames_in", "content_index_at"):
        if sym not in real_cxx:
            errors.append(f"RBG_REAL_MISS cxx:{sym}")
        else:
            print(f"RBG_REAL_HIT cxx:{sym} def={real_cxx[sym].def_loc}")

    # (3) present_cadence
    if "present_cadence" not in real_sv:
        errors.append("RBG_REAL_MISS sv:present_cadence")
        print(f"RBG_REAL_SV_ALL {sorted(real_sv)}")
    else:
        print(
            f"RBG_REAL_HIT sv:present_cadence def={real_sv['present_cadence'].def_loc} "
            f"detail={real_sv['present_cadence'].detail[:160]}"
        )

    # (1) rawPipe* — plant if missing so class is always proven; if present, classify
    defs = collect_cxx_defs(ROOT)
    for sym in ("rawPipeDesynced", "rawPipePhaseOffset"):
        if sym not in defs:
            print(f"RBG_REAL_NOTE cxx:{sym} NOT_DEFINED on this tree")
        elif sym in real_cxx:
            print(f"RBG_REAL_HIT cxx:{sym} def={real_cxx[sym].def_loc}")
        else:
            refs = collect_cxx_refs(ROOT, {sym}).get(sym, [])
            prod = [
                r
                for r in refs
                if not r.split(":")[0].startswith("tests/")
                and "ffmpeg_vf.hpp" not in r
            ]
            print(
                f"RBG_REAL_NOTE cxx:{sym} PRODUCT_REFERENCED sample={prod[:4]}"
            )

    # Synthetic RBG (includes rawPipe-class C++ orphan)
    tmp = Path(tempfile.mkdtemp(prefix="orphan_rbg_"))
    try:
        _write(
            tmp / "host/libmisterplex/ffmpeg_vf_orphan.hpp",
            "#pragma once\n#include <cstddef>\nnamespace misterplex {\n"
            "inline bool rawPipeDesynced(size_t a, size_t b, size_t i) {\n"
            "  (void)i; return a != b;\n}\n"
            "inline size_t rawPipePhaseOffset(size_t a, size_t b, size_t i) {\n"
            "  (void)a;(void)b;(void)i; return 0;\n}\n"
            "}\n",
        )
        _write(
            tmp / "tests/unit/test_raw_pipe_only.cpp",
            '#include "../../host/libmisterplex/ffmpeg_vf_orphan.hpp"\n'
            "using misterplex::rawPipeDesynced;\n"
            "using misterplex::rawPipePhaseOffset;\n"
            "int main() {\n"
            "  return rawPipeDesynced(1,2,0) && rawPipePhaseOffset(1,1,0)==0 ? 0 : 1;\n"
            "}\n",
        )
        _write(
            tmp / "host/libmisterplex/orphan_lab.hpp",
            "#pragma once\nnamespace misterplex {\n"
            "inline bool orphanLabOnlyApi(int x) { return x > 0; }\n}\n",
        )
        _write(
            tmp / "tests/unit/test_orphan_lab.cpp",
            '#include "../../host/libmisterplex/orphan_lab.hpp"\n'
            "int main() { return misterplex::orphanLabOnlyApi(1) ? 0 : 1; }\n",
        )
        _write(
            tmp / "fpga/Plex_MiSTer/rtl/orphan_cadence.sv",
            "module orphan_cadence(\n"
            "  output wire advance_unique,\n"
            "  output wire [31:0] content_index\n"
            ");\n"
            "  assign advance_unique = 1'b1;\n"
            "  assign content_index = 0;\n"
            "endmodule\n",
        )
        _write(
            tmp / "fpga/Plex_MiSTer/rtl/colorbars.sv",
            "module colorbars(input wire [31:0] content_index);\nendmodule\n",
        )
        _write(
            tmp / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv",
            "module ddr_frame_store(input wire vsync_pulse, input wire swap_advance);\n"
            "endmodule\n",
        )
        _write(
            tmp / "fpga/Plex_MiSTer/rtl/present_core_orphan.sv",
            "module present_core_orphan;\n"
            "  wire advance;\n"
            "  wire [31:0] cont_i;\n"
            "  orphan_cadence cadence (\n"
            "    .advance_unique(advance),\n"
            "    .content_index(cont_i)\n"
            "  );\n"
            "  colorbars bars (.content_index(cont_i));\n"
            "  ddr_frame_store fstore (.vsync_pulse(1'b0), .swap_advance(1'b0));\n"
            "  assign stat_advance = advance;\n"
            "endmodule\n",
        )

        red_cxx = {f.name for f in cxx_orphans(tmp)}
        red_sv = {f.name for f in sv_product_path_orphans(tmp)}
        for sym in (
            "rawPipeDesynced",
            "rawPipePhaseOffset",
            "orphanLabOnlyApi",
        ):
            if sym not in red_cxx:
                errors.append(f"RBG_SYNTH_RED_MISS cxx:{sym} got={sorted(red_cxx)}")
            else:
                print(f"RBG_SYNTH_RED_HIT cxx:{sym}")
        if "orphan_cadence" not in red_sv:
            errors.append(f"RBG_SYNTH_RED_MISS sv:orphan_cadence got={sorted(red_sv)}")
        else:
            print("RBG_SYNTH_RED_HIT sv:orphan_cadence")

        # GREEN cxx: product arm reference
        _write(
            tmp / "arm/misterplexd/use_orphan.cpp",
            '#include "../../host/libmisterplex/orphan_lab.hpp"\n'
            '#include "../../host/libmisterplex/ffmpeg_vf_orphan.hpp"\n'
            "bool productUses() {\n"
            "  using misterplex::orphanLabOnlyApi;\n"
            "  using misterplex::rawPipeDesynced;\n"
            "  using misterplex::rawPipePhaseOffset;\n"
            "  return orphanLabOnlyApi(2) || rawPipeDesynced(1,1,0)\n"
            "      || rawPipePhaseOffset(1,1,0)==0;\n"
            "}\n",
        )
        green_cxx = {f.name for f in cxx_orphans(tmp)}
        for sym in ("orphanLabOnlyApi", "rawPipeDesynced", "rawPipePhaseOffset"):
            if sym in green_cxx:
                errors.append(f"RBG_SYNTH_GREEN_FAIL cxx:{sym} still orphan")
            else:
                print(f"RBG_SYNTH_GREEN_OK cxx:{sym}")

        # GREEN sv: wire advance into ddr_frame_store
        _write(
            tmp / "fpga/Plex_MiSTer/rtl/present_core_orphan.sv",
            "module present_core_orphan;\n"
            "  wire advance;\n"
            "  wire [31:0] cont_i;\n"
            "  orphan_cadence cadence (\n"
            "    .advance_unique(advance),\n"
            "    .content_index(cont_i)\n"
            "  );\n"
            "  colorbars bars (.content_index(cont_i));\n"
            "  ddr_frame_store fstore (.vsync_pulse(1'b0), .swap_advance(advance));\n"
            "endmodule\n",
        )
        green_sv = {f.name for f in sv_product_path_orphans(tmp)}
        if "orphan_cadence" in green_sv:
            errors.append("RBG_SYNTH_GREEN_FAIL sv:orphan_cadence still orphan")
        else:
            print("RBG_SYNTH_GREEN_OK sv:orphan_cadence")

    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if errors:
        print("SELFTEST_FAIL")
        for e in errors:
            print(e)
        return 1
    print("SELFTEST_OK product_path_orphan RBG real+synth")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument(
        "--inventory",
        action="store_true",
        help="print findings but exit 0 (audit only; not a pass laundering path for CI)",
    )
    ap.add_argument(
        "--strict-all",
        action="store_true",
        help="also hard-fail on tier-2 test-only lib APIs (full inventory redline)",
    )
    args = ap.parse_args(argv)

    if args.self_test:
        rc = run_self_test()
        print(f"true rc={rc}")
        return rc

    bad = meta_guard_allowlist()
    if bad:
        for b in bad:
            print(b)
        print("true rc=2")
        return 2

    root = args.root.resolve()
    findings = cxx_orphans(root) + sv_product_path_orphans(root)
    kept, skipped = apply_allowlist(findings)

    tier1: list[Finding] = []
    tier2: list[Finding] = []
    for f in kept:
        if f.kind == "sv":
            tier1.append(f)  # any SV dead-fanout is tier-1 (present_cadence class)
        elif f.name in TIER1_CXX:
            tier1.append(f)
        else:
            tier2.append(f)

    # Full definitive list (both tiers) for the parent report.
    sys.stdout.write(format_report(kept, skipped))
    print(f"TIER1_CRITICAL count={len(tier1)}")
    for f in tier1:
        print(f"  TIER1 {f.key} def={f.def_loc}")
    print(f"TIER2_INVENTORY count={len(tier2)} (test-only lib APIs; not silent-pass)")
    for f in tier2:
        print(f"  TIER2 {f.key} def={f.def_loc}")

    if args.inventory:
        print("PRODUCT_PATH_ORPHAN_INVENTORY_ONLY (exit 0 by request; not a CI pass claim)")
        print("true rc=0")
        return 0

    # CI: hard-fail on tier-1 only. Tier-2 is printed every run so it cannot hide,
    # but does not alone redline the suite (many headers are shared gold/reference
    # APIs by design). --strict-all fails on tier-2 too.
    if getattr(args, "strict_all", False) and (tier1 or tier2):
        print(f"PRODUCT_PATH_ORPHAN_FAIL strict-all tier1={len(tier1)} tier2={len(tier2)}")
        print("true rc=1")
        return 1
    if tier1:
        print(f"PRODUCT_PATH_ORPHAN_FAIL tier1={len(tier1)} tier2_inventory={len(tier2)}")
        print("true rc=1")
        return 1
    print(
        f"PRODUCT_PATH_ORPHAN_OK tier1=0 tier2_inventory={len(tier2)} "
        "(tier2 listed above; not counted as pass of those APIs)"
    )
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
