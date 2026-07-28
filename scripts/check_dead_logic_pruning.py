#!/usr/bin/env python3
"""Failure mode 3: compiled, instantiated, elaborated -- then optimized away.

W-FIT-O5 measured this on `w-decode-hour27` `2f165ed` with Quartus Analysis &
Synthesis: `h264_decode_core` is instantiated unconditionally at
`stream_path.sv:484`, is in `files.qip`, elaborates with a full hierarchy path,
and is then **deleted** because it contributes zero resources. Conditions 1 and
2 of the fit ruling were both green at that commit. A fit on that evidence
would have produced a fifth decoder-less bitstream.

Source reachability cannot see this, and I should not pretend otherwise: the
instantiation really is there. What *is* visible in source is the reason the
fitter is entitled to delete it -- **nothing reads what the instance drives**.
On the merge base every output of the core is consumed by exactly one
expression, a reduction wire `_keep`, which is itself read by nobody. A
keep-alive that is never read keeps nothing.

So this gate answers one question: **can this instance influence the design at
all?** If no output net of the instance reaches a live sink, the synthesiser is
correct to remove it and the module is not going to be in the bitstream.

Deliberate bias: **toward calling a net live.** A false RED here would block
another worker's real work on my say-so, and Quartus A&S is only four minutes
away as the real oracle. Unknown constructs therefore count as consumption. The
cost of that choice is that this gate can miss dead logic; it should not invent
it. Verified empirically rather than assumed -- on the merge base it agrees
with A&S on both `h264_decode_core` (dead) and `decode_stub` (live).

Declared limits, up front:
  * It reasons inside the instantiating module only. A net that escapes through
    a parent port is called live without asking whether the parent is itself
    dead. That is the safe direction, and the trunk gate covers orphaned parents.
  * It does not evaluate expressions. `assign x = 1'b0 & y;` reads as y being
    consumed.
  * `(* keep *)` and `(* preserve *)` are honoured as live sinks because
    Quartus honours them. A stale keep attribute will therefore hide deadness --
    which is exactly what a keep attribute is for.
  * Elaborated-but-pruned is the *third* failure mode, not a replacement for the
    other two. Compilation (`check_qip_coverage.py`), instantiation
    (`check_rtl_module_instantiations.py`) and A&S/post-fit all remain required.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_rtl_module_instantiations as rtl  # noqa: E402

VERILOG_KEYWORDS = {
    "assign", "always", "always_ff", "always_comb", "always_latch", "begin", "end",
    "if", "else", "case", "casez", "casex", "endcase", "for", "while", "generate",
    "endgenerate", "wire", "reg", "logic", "input", "output", "inout", "parameter",
    "localparam", "signed", "unsigned", "integer", "genvar", "posedge", "negedge",
    "module", "endmodule", "function", "endfunction", "task", "endtask", "default",
    "begin_keywords", "or", "and", "not", "xor", "nand", "nor", "xnor", "bit", "byte",
    "int", "shortint", "longint", "real", "time", "initial", "final", "unique",
    "priority", "return", "break", "continue", "typedef", "struct", "union", "enum",
    "packed", "const", "static", "automatic", "keep", "preserve", "syn_keep",
}

DIRECTION_RE = re.compile(r"^\s*(input|output|inout)\b")
BRACKETS_RE = re.compile(r"\[[^\]]*\]")
IDENT_RE = re.compile(r"(?<![\w'`.])(?:\\(\S+)\s|([A-Za-z_]\w*))")
KEEP_ATTR_RE = re.compile(r"\(\*[^*]*\b(keep|preserve|syn_keep|noprune)\b[^*]*\*\)\s*"
                          r"(?:wire|reg|logic)?[^;=]*?([A-Za-z_]\w*)\s*[=;]")


def identifiers(text: str) -> set[str]:
    out: set[str] = set()
    for escaped, plain in IDENT_RE.findall(text):
        name = escaped or plain
        if name and name not in VERILOG_KEYWORDS:
            out.add(name)
    return out


def balanced(text: str, open_idx: int) -> tuple[str, int]:
    """Return the content of the parenthesis group starting at open_idx."""
    depth = 0
    for i in range(open_idx, len(text)):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i], i
    return "", len(text)


def split_top_level(text: str, sep: str = ",") -> list[str]:
    parts, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == sep and depth == 0:
            parts.append(text[start:i])
            start = i + 1
    parts.append(text[start:])
    return parts


def declared_name(item: str) -> str | None:
    """The port name in one declaration item, ignoring packed/unpacked ranges."""
    cleaned = BRACKETS_RE.sub(" ", item)
    cleaned = re.sub(r"=.*$", " ", cleaned, flags=re.S)
    names = [n for n in re.findall(r"(?<![\w'`.])([A-Za-z_]\w*)", cleaned)
             if n not in VERILOG_KEYWORDS]
    return names[-1] if names else None


def module_port_directions(body: str) -> dict[str, str]:
    """Map port name -> direction for ANSI headers and legacy declarations.

    The first version of this used one regex per direction keyword with a
    greedy name group. It swallowed every following port across the commas, so
    `h264_decode_core` reported **zero** outputs and the gate then failed it for
    having no live outputs -- a true rc=1 about nothing. Verilog direction
    persists across comma-separated items until the next keyword, so the list
    has to be split first and the direction carried forward.
    """
    ports: dict[str, str] = {}

    header = ""
    idx = 0
    if body.lstrip().startswith("#"):
        hash_idx = body.index("#")
        open_idx = body.index("(", hash_idx)
        _, close = balanced(body, open_idx)
        idx = close + 1
    open_idx = body.find("(", idx)
    if open_idx >= 0:
        header, _ = balanced(body, open_idx)

    direction = None
    for item in split_top_level(header):
        match = DIRECTION_RE.match(item)
        if match:
            direction = match.group(1)
        if direction is None:
            continue
        name = declared_name(item)
        if name:
            ports[name] = direction

    # Legacy style: `output reg [7:0] foo;` in the body.
    for statement in body.split(";"):
        match = DIRECTION_RE.match(statement)
        if not match:
            continue
        direction = match.group(1)
        for item in split_top_level(statement):
            name = declared_name(item)
            if name:
                ports[name] = direction
    return ports


def instance_connections(parent_body: str, child: str) -> list[tuple[str, dict[str, str]]]:
    """Every instantiation of `child` in `parent_body` as (instance, {port: expr})."""
    found: list[tuple[str, dict[str, str]]] = []
    pattern = re.compile(
        rf"\b{re.escape(child)}\b\s*(?:#\s*\()?", re.S
    )
    for match in pattern.finditer(parent_body):
        pos = match.end() - 1
        if parent_body[match.end() - 1: match.end()] == "(":
            _, close = balanced(parent_body, pos)
            rest = close + 1
        else:
            rest = match.end()
        tail = parent_body[rest:]
        head = re.match(rf"\s*({rtl.INSTANCE_NAME})\s*\(", tail, re.S)
        if not head:
            continue
        open_idx = rest + head.end() - 1
        conn_text, _ = balanced(parent_body, open_idx)
        conns: dict[str, str] = {}
        idx = 0
        while True:
            dot = conn_text.find(".", idx)
            if dot < 0:
                break
            name_match = re.match(r"\.\s*([A-Za-z_]\w*)\s*\(", conn_text[dot:], re.S)
            if not name_match:
                idx = dot + 1
                continue
            expr, close = balanced(conn_text, dot + name_match.end() - 1)
            conns[name_match.group(1)] = expr
            idx = close + 1
        found.append((head.group(1).strip(), conns))
    return found


def assignment_edges(body: str) -> dict[str, set[str]]:
    """net -> nets it feeds. Covers assign, wire-with-initialiser and procedural."""
    edges: dict[str, set[str]] = {}

    def add(lhs_text: str, rhs_text: str) -> None:
        targets = identifiers(lhs_text)
        sources = identifiers(rhs_text)
        for src in sources:
            edges.setdefault(src, set()).update(targets)

    stripped = re.sub(r"\(\*.*?\*\)", " ", body, flags=re.S)
    for statement in stripped.split(";"):
        if "=" not in statement:
            continue
        # Ignore comparisons and the condition halves of ternaries on the left.
        split = re.split(r"(?<![<>=!])<=(?!=)|(?<![<>=!+\-*/%&|^])=(?![=~])", statement, maxsplit=1)
        if len(split) != 2:
            continue
        lhs, rhs = split
        if re.search(r"\b(if|while|case|casez|casex|for)\b\s*\($", lhs.strip()):
            continue
        lhs = re.sub(r"\bassign\b|\bwire\b|\breg\b|\blogic\b|\bsigned\b|\bunsigned\b", " ", lhs)
        lhs_names = identifiers(re.sub(r"\[[^\]]*\]", " ", lhs))
        if not lhs_names:
            continue
        add(" ".join(sorted(lhs_names)), rhs)
    return edges


def live_sinks(parent: rtl.ModuleDef, skip_instance_of: str,
               known_modules: set[str]) -> set[str]:
    """Nets whose value can leave the module or is pinned by an attribute.

    `known_modules` is not a convenience: the first version detected sibling
    instances with a bare `identifier (` regex, which matches `if (`, a
    function call, any parenthesised expression -- so nearly every net in the
    file became a "sink" and every module looked live. That produced a
    confident GREEN on `h264_decode_core`, which Quartus had already deleted.
    Only a name that is actually a module in this design is an instantiation.
    """
    ports = module_port_directions(parent.body)
    sinks = {n for n, d in ports.items() if d in ("output", "inout")}
    for match in KEEP_ATTR_RE.finditer(parent.body):
        sinks.add(match.group(2))
    for match in re.finditer(r"\b([A-Za-z_]\w*)\s*(?:#\s*\()?", parent.body):
        child = match.group(1)
        if child not in known_modules or child == skip_instance_of:
            continue
        for _instance, conns in instance_connections(parent.body, child):
            for expr in conns.values():
                sinks |= identifiers(expr)
    return sinks


def reaches_sink(start: set[str], edges: dict[str, set[str]], sinks: set[str]) -> bool:
    seen: set[str] = set()
    queue = list(start)
    while queue:
        net = queue.pop()
        if net in sinks:
            return True
        if net in seen:
            continue
        seen.add(net)
        queue.extend(edges.get(net, ()))
    return False


def analyse(module: str, modules: dict[str, rtl.ModuleDef]) -> tuple[str, int, list[str]]:
    """Return (verdict, live_output_nets, report lines) for every instance.

    verdict is one of: live, pruned, not_instantiated, no_outputs.  The last two
    are *not* deadness findings and must never be scored as one -- I hit exactly
    that while building this: a broken port parser reported outputs=0 and the
    gate happily failed the module for having no live outputs, which is a true
    rc=1 about nothing.
    """
    target = modules[module]
    known_modules = set(modules)
    ports = module_port_directions(target.body)
    outputs = sorted(n for n, d in ports.items() if d in ("output", "inout"))
    inputs = sorted(n for n, d in ports.items() if d == "input")
    lines: list[str] = []
    live_total = 0
    sites = 0
    for parent in modules.values():
        if parent.name == module:
            continue
        for instance, conns in instance_connections(parent.body, module):
            sites += 1
            edges = assignment_edges(parent.body)
            sinks = live_sinks(parent, module, known_modules)
            live_here: list[str] = []
            dead_here: list[str] = []
            for port in outputs:
                expr = conns.get(port)
                if expr is None or not expr.strip():
                    dead_here.append(f"{port}=<unconnected>")
                    continue
                nets = identifiers(expr)
                if not nets:
                    dead_here.append(f"{port}={expr.strip()[:24]}")
                    continue
                if reaches_sink(nets, edges, sinks):
                    live_here.append(port)
                else:
                    dead_here.append(f"{port}={','.join(sorted(nets))[:40]}")
            const_inputs = sum(
                1 for p in inputs
                if p in conns and not identifiers(conns[p])
            )
            live_total += len(live_here)
            lines.append(
                f"INSTANCE {module} in {parent.name}:{instance} "
                f"outputs={len(outputs)} live={len(live_here)} dead={len(dead_here)} "
                f"const_tied_inputs={const_inputs}/{len(inputs)}"
            )
            for entry in dead_here:
                lines.append(f"  DEAD_OUTPUT_NET {module}.{entry}")
            for port in live_here:
                lines.append(f"  LIVE_OUTPUT_NET {module}.{port}")
    if not outputs:
        lines.append(
            f"NO_OUTPUT_PORTS {module} -- this gate cannot judge a module with no "
            "outputs; outputs=0 is a Scope: 0, not a finding"
        )
        return "no_outputs", 0, lines
    if sites == 0:
        lines.append(
            f"NOT_INSTANTIATED {module} -- no instantiation site to analyse; that is "
            "failure mode 2, ask check_rtl_module_instantiations.py"
        )
        return "not_instantiated", 0, lines
    return ("live" if live_total else "pruned"), live_total, lines


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--require", action="append", default=[], metavar="MODULE",
                    help="module that must be able to influence the design")
    ap.add_argument("--project-root", default=None,
                    help="measure another MiSTerPlex checkout without copying this script")
    args = ap.parse_args(argv)

    if args.project_root:
        rtl.rebind_project_root(args.project_root)

    paths = rtl.git_files("fpga/Plex_MiSTer/rtl") + [rtl.PRODUCT_TOP]
    paths = [p for p in paths if p.exists()]
    if not paths:
        print("Scope: 0 -- no tracked RTL found")
        print("SKIP: nothing to analyse")
        return 77

    modules = rtl.parse_modules(paths)
    required = args.require
    print(f"Scope: rtl_files={len(paths)} rtl_modules={len(modules)} "
          f"requires={len(required)}")
    if not required:
        print("SKIP: --require names no module; this gate answers a question "
              "about a specific instance and has no default subject")
        return 77

    unknown = [m for m in required if m not in modules]
    if unknown:
        print("DEAD_LOGIC_GATE_FAIL: --require names modules that do not exist: "
              + ", ".join(sorted(unknown)), file=sys.stderr)
        return 1

    pruned: list[str] = []
    orphaned: list[str] = []
    unjudgeable: list[str] = []
    for module in required:
        verdict, _live, lines = analyse(module, modules)
        for line in lines:
            print(line)
        if verdict == "pruned":
            pruned.append(module)
        elif verdict == "not_instantiated":
            orphaned.append(module)
        elif verdict == "no_outputs":
            unjudgeable.append(module)

    if args.project_root:
        print(f"FOREIGN_PROJECT_ROOT {rtl.ROOT} -- structural claims only")

    if unjudgeable:
        print(
            "DEAD_LOGIC_GATE_REFUSED: no output ports found for "
            + ", ".join(sorted(unjudgeable))
            + " -- this gate has no question to answer about them and will not "
            "manufacture a verdict either way",
            file=sys.stderr,
        )
        return 2

    if orphaned:
        print(
            "DEAD_LOGIC_GATE_FAIL: not instantiated anywhere, so there is no "
            "instance to keep or prune: " + ", ".join(sorted(orphaned)),
            file=sys.stderr,
        )
        return 1

    if pruned:
        print(
            "DEAD_LOGIC_GATE_FAIL: nothing reads what these instances drive, so "
            "synthesis is entitled to delete them and they will not be in the "
            "bitstream: " + ", ".join(sorted(pruned)),
            file=sys.stderr,
        )
        print(
            "  This is failure mode 3 (elaborated then optimized away). Confirm "
            "with scripts/check_prefit_elaboration.sh -- Analysis & Synthesis is "
            "the oracle; this gate is the four-minutes-cheaper pre-filter.",
            file=sys.stderr,
        )
        return 1

    print(f"DEAD_LOGIC_GATE_OK modules={len(required)} "
          "verdict=can_influence_design (NOT a claim of post-fit presence)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
