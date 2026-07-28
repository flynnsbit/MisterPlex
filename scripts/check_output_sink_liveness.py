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
DEFAULT_PARENT = "stream_path"
DEFAULT_PRODUCT = "h264_decode_core"
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


PARAM_FIXTURE = """
module pfixture (
    input wire [7:0] src,
    output wire [7:0] dout
);
  localparam int WIDTH = SRC_LIKE;
  assign dout = WIDTH[7:0];
endmodule
"""

SEQ_FIXTURE = """
module sfixture (
    input wire clk,
    input wire [7:0] src,
    output wire [7:0] dout
);
  reg [7:0] stage_r;
  always_ff @(posedge clk) begin
    stage_r <= src;
  end
  assign dout = stage_r;
endmodule
"""

COMMA_FIXTURE = """
module cfixture (
    input wire [7:0] src,
    output wire [7:0] dout
);
  wire [7:0] a = src, b = other_net;
  assign dout = a;
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


def parse_args(argv, product_default, parent_default):
    """Strict argument parsing: an unrecognised flag is a hard error.

    A checker that silently ignores unknown arguments hands out confident greens
    to anyone who pastes a slightly wrong command line, which is exactly the
    forbidden evidence. Refusing is cheaper than explaining.
    """
    parent, product, self_test_only = parent_default, product_default, False
    gate, rtl_dir = "all", None
    idx = 0
    while idx < len(argv):
        arg = argv[idx]
        if arg == "--self-test":
            self_test_only = True
        elif arg in ("--parent", "--product", "--gate", "--rtl-dir"):
            if idx + 1 >= len(argv):
                raise ValueError("%s requires a value" % arg)
            idx += 1
            if arg == "--parent":
                parent = argv[idx]
            elif arg == "--product":
                product = argv[idx]
            elif arg == "--rtl-dir":
                rtl_dir = pathlib.Path(argv[idx])
            else:
                if argv[idx] not in ("all", "path-to-port"):
                    raise ValueError("--gate takes all or path-to-port, not %r"
                                     % argv[idx])
                gate = argv[idx]
        else:
            raise ValueError("unrecognised argument %r" % arg)
        idx += 1
    return parent, product, self_test_only, gate, rtl_dir


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

    dead_ports = module_ports(strip_comments(DEAD_FIXTURE), "fixture")
    if reaches_port(strip_comments(DEAD_FIXTURE), {"a1"}, dead_ports):
        print("SELF_TEST_FAIL: claimed a path to a port in a module with none",
              file=sys.stderr)
        return 1
    print("OK self-test red: no path to a port is reported when none exists")

    live_ports = module_ports(strip_comments(LIVE_FIXTURE), "fixture")
    if "out" not in live_ports:
        print("SELF_TEST_FAIL: output port not parsed from the fixture header",
              file=sys.stderr)
        return 1
    if reaches_port(strip_comments(LIVE_FIXTURE), {"a1"}, live_ports) != {"out"}:
        print("SELF_TEST_FAIL: missed a real path from a1 to out", file=sys.stderr)
        return 1
    print("OK self-test green: a real path to an output port is found")

    # A parameter is an elaboration-time constant. Even where its expression
    # textually mentions a name, it cannot carry runtime data, so SRC_LIKE must
    # not reach dout through WIDTH. Dropping the parameter guard makes this fire.
    param_text = strip_comments(PARAM_FIXTURE)
    param_ports = module_ports(param_text, "pfixture")
    if "dout" not in param_ports:
        print("SELF_TEST_FAIL: output port not parsed from the parameter fixture",
              file=sys.stderr)
        return 1
    bogus = reaches_port(param_text, {"SRC_LIKE"}, param_ports)
    if bogus:
        print("SELF_TEST_FAIL: a parameter declaration invented a path to %s"
              % ", ".join(sorted(bogus)), file=sys.stderr)
        return 1
    print("OK self-test red: a parameter cannot carry data to a port")

    # `wire [7:0] a = src, b = other_net;` declares two nets. Without truncating
    # the right-hand side at the first top-level comma, other_net appears to drive
    # a, and therefore dout. This is the guard that actually removed the false
    # dpb_rd_addr path from the real core, so it is tested separately.
    comma_text = strip_comments(COMMA_FIXTURE)
    comma_ports = module_ports(comma_text, "cfixture")
    if reaches_port(comma_text, {"src"}, comma_ports) != {"dout"}:
        print("SELF_TEST_FAIL: lost the real src -> dout path in the comma fixture",
              file=sys.stderr)
        return 1
    leaked = reaches_port(comma_text, {"other_net"}, comma_ports)
    if leaked:
        print("SELF_TEST_FAIL: a second declarator on the same line invented a "
              "path to %s" % ", ".join(sorted(leaked)), file=sys.stderr)
        return 1
    print("OK self-test red: a second declarator on one line does not leak a path")

    # A registered path is still a path. Synthesis keeps a flop whose output is
    # observed, so a tracer that follows only continuous assignments declares
    # most real pipelines dead. This case was added after it produced exactly
    # that false alarm on another worker's branch.
    seq_text = strip_comments(SEQ_FIXTURE)
    seq_ports = module_ports(seq_text, "sfixture")
    if reaches_port(seq_text, {"src"}, seq_ports) != {"dout"}:
        print("SELF_TEST_FAIL: missed a path that goes through a register",
              file=sys.stderr)
        return 1
    print("OK self-test green: a path through a register is found")
    return 0


def module_ports(text, module):
    """Output port names of `module` as declared in its own header."""
    start = text.find("module " + module)
    if start < 0:
        return set()
    head = text[start:text.find(");", start) + 1]
    return set(re.findall(r"\boutput\s+(?:wire|reg|logic)?\s*(?:signed\s*)?"
                          r"(?:\[[^\]]*\]\s*)?([A-Za-z_]\w*)", head))


def truncate_at_comma(rhs):
    """RHS up to the first comma outside brackets.

    `wire a = x, b = y;` declares two nets; without this, y appears to drive a.
    Concatenations and function calls keep their commas because those are nested.
    """
    depth = 0
    for idx, ch in enumerate(rhs):
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        elif ch == "," and depth == 0:
            return rhs[:idx]
    return rhs


def reaches_port(text, sources, ports):
    """Which of `sources` can influence any name in `ports`, transitively.

    Synthesis keeps logic only where it observably affects an output. This is a
    coarse source-level dataflow: follow every continuous assignment and every
    port connection forward from the core's outputs and see whether the parent's
    own output ports are ever touched. It cannot replace Quartus, but it answers
    the survival question in about a second instead of four minutes, which is the
    difference between iterating dozens of times an hour and a few times a day.
    """
    edges = {}
    for match in re.finditer(r"^[ \t]*(?P<head>(?:assign\s+)?(?:wire|logic|reg|"
                             r"parameter|localparam|input|output|inout)?[^;=\n]*?)"
                             r"\b([A-Za-z_]\w*)\s*=\s*([^;]*);", text, re.M):
        head = match.group("head")
        # A parameter is an elaboration-time constant, not a dataflow carrier, and
        # a port declaration with a default is not an assignment either. Including
        # them invents edges: `parameter int FRAME_W = 320,` in a parameter list
        # let the RHS run to the next semicolon, swallowing the whole port list,
        # and manufactured a path from the core's outputs to dpb_rd_addr that does
        # not exist. That is a false "alive", the one error class this must not make.
        if re.match(r"\s*(?:parameter|localparam|input|output|inout)\b", head):
            continue
        dst, rhs = match.group(2), truncate_at_comma(match.group(3))
        for src in set(re.findall(r"\b([A-Za-z_]\w*)\b", rhs)):
            edges.setdefault(src, set()).add(dst)
    # Procedural assignments carry data too. Omitting them cost a real false
    # alarm: on w-cast-o5 the MC result reaches dpb_wr_data through a register,
    # `p16_wr_data_r <= clip_u8(p16_recon_sum)`, and a continuous-assignment-only
    # tracer called that dead. The left-hand side must start the line, optionally
    # indexed, so `if (a <= b)` cannot be read as an assignment to a.
    for match in re.finditer(r"^[ \t]*([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)?"
                             r"(?:<=|=)(?!=)\s*([^;]*);", text, re.M):
        dst, rhs = match.group(1), truncate_at_comma(match.group(2))
        for src in set(re.findall(r"\b([A-Za-z_]\w*)\b", rhs)):
            edges.setdefault(src, set()).add(dst)
    # Deliberately NOT adding edges between the connections of one instance. That
    # over-approximates badly: it made every core output appear to reach 30 of
    # stream_path's ports on a design Quartus had already deleted. A predictor of
    # deletion must never produce a false "alive", so only real assignments count.
    # The cost is possible false alarms where a submodule genuinely forwards a
    # signal; those are cheap to confirm with Quartus A&S.
    seen, stack = set(sources), list(sources)
    while stack:
        for nxt in edges.get(stack.pop(), ()):
            if nxt not in seen:
                seen.add(nxt)
                stack.append(nxt)
    return seen & ports


def owning_file(module, rtl_dir=None):
    """The tracked RTL file that declares `module`, resolved, never hardcoded."""
    pattern = re.compile(r"^\s*module\s+%s\b" % re.escape(module), re.M)
    for path in sorted((rtl_dir or RTL).glob("*.sv")):
        if pattern.search(strip_comments(path.read_text(errors="replace"))):
            return path
    return None


def main():
    try:
        parent, product, self_test_only, gate, rtl_dir = parse_args(
            sys.argv[1:], DEFAULT_PRODUCT, DEFAULT_PARENT)
    except ValueError as exc:
        print("SINK_LIVENESS_ERROR: %s" % exc, file=sys.stderr)
        return 2
    if self_test_only:
        return self_test()
    PARENT, PRODUCT = parent, product
    parent_path = owning_file(PARENT, rtl_dir)
    if parent_path is None:
        print("SINK_LIVENESS_ERROR: no tracked RTL file declares module %s" % PARENT,
              file=sys.stderr)
        return 2
    product_path = owning_file(PRODUCT, rtl_dir)
    if product_path is None:
        print("SINK_LIVENESS_ERROR: no tracked RTL file declares module %s" % PRODUCT,
              file=sys.stderr)
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

    core_text = strip_comments(product_path.read_text(errors="replace"))
    core_outputs = module_ports(core_text, PRODUCT)
    # Only nets driven BY the core can keep it alive. Tracing from its inputs too
    # counts paths that exist with or without the instance, which is how an
    # earlier version reported 30 reached ports on a design Quartus had deleted.
    core_nets = {v.strip() for port, v in args.items()
                 if port in core_outputs and v.strip() and not CONST.match(v.strip())}
    ports = module_ports(text, PARENT)
    landed = reaches_port(text, core_nets, ports)
    print("CORE_OUTPUT_NETS %d traced from %d declared output ports"
          % (len(core_nets), len(core_outputs)))
    if landed:
        print("OUTPUTS_REACH_PORTS %s -> %s: %s"
              % (PRODUCT, PARENT, ", ".join(sorted(landed))))
    else:
        print("NO_PATH_TO_PORT %s outputs influence none of %s's %d output ports, so "
              "synthesis has no reason to keep the instance: predict "
              "ELABORATED_BUT_OPTIMIZED_AWAY. Confirm with Quartus A&S "
              "(scripts/check_prefit_elaboration.sh)."
              % (PRODUCT, PARENT, len(ports)), file=sys.stderr)

    # --gate path-to-port narrows the verdict to the survival question alone. It
    # is NOT an allowlist for the dead-end defect: that is still printed, loudly,
    # and the wider gate still fails on it. It exists because "does this submodule
    # reach a port of its own parent" is a different question from "does the
    # parent leak its outputs to nothing", and a caller that owns only the first
    # must not be forced to suppress the second to ask it.
    if failures and gate == "path-to-port":
        print("UNGATED_DEAD_ENDS %d aggregator(s) reported above are NOT gated by "
              "--gate path-to-port; run without it to fail on them"
              % len(failures), file=sys.stderr)
    if not landed or (failures and gate == "all"):
        print("SINK_LIVENESS_FAIL aggregators=%d path_to_port=%d product=%s "
              "parent=%s gate=%s"
              % (len(failures), len(landed), PRODUCT, PARENT, gate), file=sys.stderr)
        return 1

    print("SINK_LIVENESS_OK %s outputs reach %d parent port(s); "
          "constant_tied_inputs=%d gate=%s"
          % (PRODUCT, len(landed), len(tied), gate))
    return 0


if __name__ == "__main__":
    sys.exit(main())
