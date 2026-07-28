#!/usr/bin/env python3
"""Detect the third product-absence failure mode: live source, dead silicon.

w-fit-o5 measured with Quartus Analysis & Synthesis on w-decode-hour27 2f165ed
that h264_decode_core is instantiated unconditionally, compiled, and elaborated:

    Info (12128): Elaborating entity "h264_decode_core" for hierarchy
                  "emu:emu|stream_path:spath|h264_decode_core:product_decode_core"

and is then deleted, because it contributes zero resources. Every source-level
reachability graph we own says GREEN on that design, because the instantiation
really is there. Reachability can never see this.

The mechanism is a dead-end keep-alive: a wire ORs together all of the module's
outputs so they look used, and that wire is itself never read. Quartus removes
the wire, then everything feeding it, then the instance.

This is a source-level detector for that shape, so it costs a second instead of
four minutes of Quartus, and it names the signal to fix.

Reported, not inferred:
  * aggregator wires that are never read (the defect);
  * input ports of the product decoder tied to constants at the instantiation,
    which keep the instance collapsing even after its outputs are consumed.

Exit 0 clean, 1 on a defect, 2 on a usage error. There is no skip path: the
inputs are two tracked source files that are always present.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RTL = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
PARENT = "stream_path"
PRODUCT = "h264_decode_core"
# An OR-reduction of this many distinct signals is a keep-alive, not logic.
AGGREGATE_MIN = 6


def strip_comments(text):
    return re.sub(r"//[^\n]*", " ", re.sub(r"/\*.*?\*/", " ", text, flags=re.S))


def declarations(text):
    """wire/reg name -> its continuous-assignment RHS, for single-assign nets."""
    out = {}
    pattern = re.compile(
        r"\b(?:wire|logic|reg)\b[^;=]*?\b([A-Za-z_]\w*)\s*=\s*(.*?);", re.S)
    for match in pattern.finditer(text):
        out[match.group(1)] = match.group(2)
    for match in re.finditer(r"^\s*assign\s+([A-Za-z_]\w*)\s*=\s*(.*?);", text, re.S | re.M):
        out.setdefault(match.group(1), match.group(2))
    return out


def read_count(text, name):
    """Times `name` appears outside its own declaration/assignment left side."""
    total = 0
    for match in re.finditer(r"\b%s\b" % re.escape(name), text):
        before = text[max(0, match.start() - 200):match.start()]
        after = text[match.end():match.end() + 40]
        if re.match(r"\s*=[^=]", after) and not re.search(r"[=!<>]\s*$", before):
            continue
        total += 1
    return total


def instantiation_args(text, module):
    """Named port connections of the first instantiation of `module`."""
    start = text.find(module + " #(")
    if start < 0:
        start = text.find(module + " ")
    if start < 0:
        return {}
    depth, idx, opened, end = 0, start, False, len(text)
    while idx < len(text):
        if text[idx] == "(":
            depth += 1
            opened = True
        elif text[idx] == ")":
            depth -= 1
            if opened and depth == 0:
                end = idx
                break
        idx += 1
    # `end` closed the parameter list; the port list is the next paren group.
    if text[start:end].lstrip().startswith(module + " #"):
        port_start = text.find("(", end)
        if port_start >= 0:
            depth, idx = 0, port_start
            while idx < len(text):
                if text[idx] == "(":
                    depth += 1
                elif text[idx] == ")":
                    depth -= 1
                    if depth == 0:
                        end = idx
                        break
                idx += 1
            start = port_start
    body = text[start:end]
    return dict(re.findall(r"\.([A-Za-z_]\w*)\s*\(\s*([^()]*?)\s*\)", body))


CONST = re.compile(r"^\d*'?s?[bdho]?[0-9A-Fa-fxzZ_]+$")


DEAD_FIXTURE = """
module fixture (input clk);
  wire a1; wire a2; wire a3; wire a4; wire a5; wire a6; wire a7;
  wire _keep = a1 | a2 | a3 | a4 | a5 | a6 | a7;
endmodule
"""

LIVE_FIXTURE = """
module fixture (input clk, output out);
  wire a1; wire a2; wire a3; wire a4; wire a5; wire a6; wire a7;
  wire _keep = a1 | a2 | a3 | a4 | a5 | a6 | a7;
  assign out = _keep;
endmodule
"""


def dead_ends(text):
    found = []
    for name, rhs in declarations(text).items():
        operands = set(re.findall(r"\b([A-Za-z_]\w*)\b", rhs))
        operands -= {"begin", "end", "if", "else"}
        if len(operands) < AGGREGATE_MIN:
            continue
        if read_count(text, name) > 0:
            continue
        found.append((name, len(operands),
                      sorted(o for o in operands if o.startswith("core_"))))
    return found


def self_test():
    """The detector must fire on a dead-end aggregator and stay silent on a live
    one. Without this, a detector that never fires would look like a clean repo."""
    dead = dead_ends(strip_comments(DEAD_FIXTURE))
    if len(dead) != 1 or dead[0][0] != "_keep":
        print("SELF_TEST_FAIL: detector missed a dead-end aggregator: %r" % (dead,),
              file=sys.stderr)
        return 1
    print("OK self-test red: dead-end aggregator detected (%s, %d operands)"
          % (dead[0][0], dead[0][1]))
    live = dead_ends(strip_comments(LIVE_FIXTURE))
    if live:
        print("SELF_TEST_FAIL: detector fired on an aggregator that IS read: %r"
              % (live,), file=sys.stderr)
        return 1
    print("OK self-test green: an aggregator that is read is not reported")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return self_test()
    parent_path = RTL / (PARENT + ".sv")
    if not parent_path.exists():
        print("SINK_LIVENESS_ERROR: %s not found" % parent_path, file=sys.stderr)
        return 2
    text = strip_comments(parent_path.read_text(errors="replace"))

    print("Scope: %s instantiating %s - detecting outputs that reach no sink, "
          "the failure mode Quartus reports as elaborated-then-optimized-away"
          % (PARENT, PRODUCT))

    failures = dead_ends(text)

    for name, count, touched in failures:
        print("DEAD_END_AGGREGATOR %s: ORs %d signals and is never read, so "
              "synthesis deletes it and everything feeding it%s"
              % (name, count,
                 ("; product signals lost: " + ", ".join(touched)) if touched else ""),
              file=sys.stderr)

    args = instantiation_args(text, PRODUCT)
    tied = sorted(p for p, v in args.items() if CONST.match(v.strip()))
    if tied:
        print("CONSTANT_TIED_INPUTS %s: %d input ports are wired to literals, which "
              "lets synthesis constant-fold the instance away even once its outputs "
              "are consumed: %s" % (PRODUCT, len(tied), ", ".join(tied)))

    if failures:
        print("SINK_LIVENESS_FAIL aggregators=%d product=%s parent=%s"
              % (len(failures), PRODUCT, PARENT), file=sys.stderr)
        return 1

    print("SINK_LIVENESS_OK %s outputs reach real sinks; constant_tied_inputs=%d"
          % (PRODUCT, len(tied)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
