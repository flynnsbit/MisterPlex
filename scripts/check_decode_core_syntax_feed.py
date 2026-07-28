#!/usr/bin/env python3
"""Gate the fourth way code goes missing: wired up, but fed constants.

The first three modes are file-not-in-qip, never-instantiated, and
elaborated-then-optimised-away.  This checks a fourth that no reachability gate
can see: a module that IS instantiated on the product path but whose inputs are
tied to literals, so it decodes the same hardcoded macroblock forever.

Rules, all source-level and cheap:

  1. stream_path's h264_decode_core instantiation must drive the slice-syntax
     ports from parser signals, never from a literal.  A literal cbp_luma or
     mb_residual_bit_offset means every macroblock is told the same thing.
  2. The product CAVLC residual instance inside h264_decode_core must take its
     bit budget from the RBSP window port, not from a literal, or residual data
     past that literal is silently truncated.
  3. The RBSP window the core declares and the buffer stream_path hands it must
     be the same depth, so a widened producer cannot outrun a narrow consumer.

Exit codes: 0 pass, 1 fail.  There is no skip: the files are tracked, so
absence is a failure, not a reason to pass.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
STREAM_PATH = RTL / "stream_path.sv"
DECODE_CORE = RTL / "h264_decode_core.sv"

# Ports that carry per-macroblock slice syntax. A literal here is the bug.
SYNTAX_PORTS = (
    "cbp_luma",
    "cbp_chroma",
    "mb_residual_bit_offset",
    "intra4x4_modes",
    "rbsp_byte",
    "rbsp_bit_len",
)
RESIDUAL_INSTANCE = "u_product_p16_residual0"
LITERAL = re.compile(r"^[0-9]+'[sS]?[bodhBODH][0-9a-fA-FxXzZ_]+$|^[0-9]+$|^\{[^a-zA-Z]*\}$")


def fail(msg: str) -> int:
    print(f"DECODE_CORE_SYNTAX_FEED_FAIL: {msg}", file=sys.stderr)
    return 1


def read(path: Path) -> str:
    if not path.is_file():
        raise SystemExit(fail(f"missing tracked source: {path.relative_to(ROOT)}"))
    return path.read_text()


def port_map(text: str, module: str, instance: str | None = None) -> dict[str, str]:
    """Return {port: expression} for the first matching instantiation."""
    def skip_balanced(src: str, i: int) -> int:
        depth = 1
        i += 1
        while i < len(src) and depth:
            depth += (src[i] == "(") - (src[i] == ")")
            i += 1
        return i

    for m in re.finditer(rf"\b{module}\b", text):
        i = m.end()
        while i < len(text) and text[i].isspace():
            i += 1
        if i < len(text) and text[i] == "#":            # parameter block
            i += 1
            while i < len(text) and text[i].isspace():
                i += 1
            if i >= len(text) or text[i] != "(":
                continue
            i = skip_balanced(text, i)
            while i < len(text) and text[i].isspace():
                i += 1
        name = re.match(r"(\w+)", text[i:])
        if not name:
            continue
        if instance and name.group(1) != instance:
            continue
        j = i + name.end()
        while j < len(text) and text[j].isspace():
            j += 1
        if j >= len(text) or text[j] != "(":
            continue
        end = skip_balanced(text, j)
        body = text[j + 1:end - 1]
        break
    else:
        raise SystemExit(fail(f"no instantiation of {module}"
                              + (f" named {instance}" if instance else "")))
    body = re.sub(r"//[^\n]*", "", body)
    return {p: a.strip() for p, a in re.findall(r"\.\s*(\w+)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)", body)}


def is_literal(expr: str) -> bool:
    flat = re.sub(r"\s+", "", expr)
    if LITERAL.match(flat):
        return True
    # Concatenations of only literals, e.g. {6'd0, 10'd0}
    if flat.startswith("{") and flat.endswith("}"):
        return all(LITERAL.match(p) for p in flat[1:-1].split(",") if p)
    return False


def window_depth(text: str, signal: str) -> int | None:
    m = re.search(rf"\b{signal}\s*\[\s*0\s*:\s*(\d+)\s*\]", text)
    return int(m.group(1)) + 1 if m else None


def main() -> int:
    sp, dc = read(STREAM_PATH), read(DECODE_CORE)

    core = port_map(sp, "h264_decode_core")
    tied = sorted(p for p in SYNTAX_PORTS if p in core and is_literal(core[p]))
    absent = sorted(p for p in SYNTAX_PORTS if p not in core)
    if absent:
        return fail("h264_decode_core instantiation does not connect: " + ", ".join(absent))
    if tied:
        detail = ", ".join(f"{p}={core[p]}" for p in tied)
        return fail("slice-syntax ports are tied to literals, so every macroblock "
                    f"decodes the same syntax: {detail}")

    res = port_map(dc, "h264_cavlc_residual_block", RESIDUAL_INSTANCE)
    if "bit_len" not in res:
        return fail(f"{RESIDUAL_INSTANCE} does not connect bit_len")
    if is_literal(res["bit_len"]):
        return fail(f"{RESIDUAL_INSTANCE}.bit_len is the literal {res['bit_len']}; residual "
                    "past that budget is silently truncated regardless of the window width")

    core_depth = window_depth(dc, "rbsp_byte")
    fed = core.get("rbsp_byte", "")
    fed_depth = window_depth(sp, re.sub(r"\W", "", fed))
    if core_depth is None or fed_depth is None:
        return fail(f"could not measure RBSP window depth (core={core_depth} fed={fed_depth})")
    if core_depth != fed_depth:
        return fail(f"RBSP window depth mismatch: h264_decode_core takes {core_depth} bytes "
                    f"but stream_path feeds {fed} of {fed_depth} bytes")

    print(f"DECODE_CORE_SYNTAX_FEED_OK syntax_ports={len(SYNTAX_PORTS)} "
          f"residual_bit_len={res['bit_len']} rbsp_window_bytes={core_depth}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
