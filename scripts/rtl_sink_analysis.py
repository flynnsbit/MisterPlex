#!/usr/bin/env python3
"""Source-level liveness analysis for the outputs of an instantiated RTL module.

Structural reachability answers "is this module instantiated?".  It cannot answer
"does anything downstream consume what it produces?".  A module whose outputs
only feed a dangling anti-prune OR-reduction is instantiated in source, gets
pruned by synthesis, and contributes nothing to the bitstream -- while every
reachability gate stays green.

This module classifies each output net of a child instantiation inside its
parent module body as:

* ``live``       - reaches a parent output port, or another module instance, or
                   any net that is itself live;
* ``dead_end``   - every consumer chain terminates on a net with no further
                   fanout (the classic ``wire _keep = a | b | c;`` anti-prune);
* ``unconnected``- the port connection is empty or a literal.

The analysis is deliberately textual and conservative: anything it cannot prove
is a dead end is reported as live, so it produces no false failures.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

IDENT = r"[A-Za-z_]\w*"
_KEYWORDS = {
    "always", "always_ff", "always_comb", "always_latch", "assign", "begin",
    "case", "casex", "casez", "default", "else", "end", "endcase", "endfunction",
    "endgenerate", "endmodule", "endtask", "for", "function", "generate", "if",
    "initial", "input", "integer", "localparam", "logic", "module", "output",
    "parameter", "posedge", "negedge", "reg", "return", "signed", "task",
    "unsigned", "wire", "genvar", "int", "bit", "byte", "typedef", "struct",
    "packed", "automatic", "static", "inout", "const", "void", "or", "and",
    "not", "xor", "nand", "nor", "xnor", "buf", "while", "repeat", "forever",
    "break", "continue", "unique", "priority", "inside", "real", "time",
}


@dataclass(frozen=True)
class PortConn:
    port: str
    net: str | None
    raw: str
    nets: tuple[str, ...] = ()


@dataclass(frozen=True)
class OutputSink:
    port: str
    net: str | None
    status: str  # live | dead_end | unconnected
    detail: str


def _balanced(text: str, start: int) -> tuple[str, int]:
    """Return the parenthesised group beginning at ``start`` and its end index."""
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1 : i], i + 1
        i += 1
    return "", len(text)


def module_port_directions(body: str) -> dict[str, str]:
    """Map port name -> 'input'/'output'/'inout' from an ANSI-style header."""
    cursor = 0
    pm = re.match(r"\s*#\s*\(", body)
    if pm:
        _, cursor = _balanced(body, pm.end() - 1)
    open_idx = body.find("(", cursor)
    if open_idx < 0:
        return {}
    header, _ = _balanced(body, open_idx)
    out: dict[str, str] = {}
    direction: str | None = None
    for chunk in header.split(","):
        m = re.search(r"\b(input|output|inout)\b", chunk)
        if m:
            direction = m.group(1)
        if direction is None:
            continue
        # last identifier before an optional unpacked dimension is the port name
        stripped = re.sub(r"\[[^\]]*\]\s*$", "", chunk.strip())
        names = re.findall(IDENT, stripped)
        names = [n for n in names if n not in _KEYWORDS]
        if names:
            out[names[-1]] = direction
    return out


def find_instantiation(parent_body: str, child_module: str) -> tuple[str, int, int] | None:
    """Return (port_text, span_start, span_end) for the first ``child_module`` instance."""
    found = find_instantiations(parent_body, child_module)
    return found[0] if found else None


def find_instantiations(parent_body: str, child_module: str) -> list[tuple[str, int, int]]:
    """Return (port_text, span_start, span_end) for every ``child_module`` instance.

    Generate blocks and parameterised duplication can instantiate the same module
    more than once; analysing only the first would let a live decoy instance hide
    a dead product instance (or the reverse).
    """
    out: list[tuple[str, int, int]] = []
    for m in re.finditer(rf"\b{re.escape(child_module)}\b", parent_body):
        i = m.end()
        rest = parent_body[i:]
        pm = re.match(r"\s*#\s*\(", rest)
        cursor = i
        if pm:
            _, end = _balanced(parent_body, i + pm.end() - 1)
            cursor = end
        nm = re.match(rf"\s*({IDENT})\s*\(", parent_body[cursor:])
        if not nm:
            continue
        open_idx = cursor + nm.end() - 1
        ports, end = _balanced(parent_body, open_idx)
        out.append((ports, m.start(), end))
    return out


def parse_port_conns(port_text: str) -> list[PortConn]:
    conns: list[PortConn] = []
    for m in re.finditer(rf"\.\s*({IDENT})\s*\(", port_text):
        inner, _ = _balanced(port_text, m.end() - 1)
        expr = inner.strip()
        nets = [n for n in re.findall(IDENT, expr) if n not in _KEYWORDS]
        # slices, concatenations and part-selects still carry real nets; only a
        # literal or empty connection genuinely has none.
        net = nets[0] if nets else None
        conns.append(PortConn(m.group(1), net, expr, tuple(dict.fromkeys(nets))))
    return conns


def _statements(body: str, exclude: list[tuple[int, int]]) -> list[tuple[str, int]]:
    """Split a module body into ';'-terminated statements, skipping given spans."""
    out: list[tuple[str, int]] = []
    start = 0
    for m in re.finditer(r";", body):
        end = m.start()
        overlaps = any(not (end < lo or start >= hi) for lo, hi in exclude)
        if overlaps:
            start = m.end()
            continue
        out.append((body[start:end], start))
        start = m.end()
    if start < len(body):
        out.append((body[start:], start))
    return out


def _assign_target(stmt: str) -> str | None:
    m = re.search(r"(<=|(?<![=!<>+\-*/%&|^])=(?!=))", stmt)
    if not m:
        return None
    lhs = stmt[: m.start()]
    lhs = re.sub(r"\[[^\]]*\]", " ", lhs)
    names = [n for n in re.findall(IDENT, lhs) if n not in _KEYWORDS]
    if not names:
        return None
    return names[-1]


def analyze_output_sinks(
    parent_body: str,
    child_body: str,
    child_module: str,
) -> tuple[list[OutputSink], dict[str, str]]:
    """Classify every output net of ``child_module`` instantiated in ``parent_body``.

    All instances are analysed together: every instance's own port-connection
    statement is excluded from the liveness fixpoint, so an instance cannot vouch
    for itself, and a port is reported live if any instance drives a live net.
    """
    instances = find_instantiations(parent_body, child_module)
    if not instances:
        return [], {}
    directions = module_port_directions(child_body)
    parent_ports = module_port_directions(parent_body)
    parent_outputs = {n for n, d in parent_ports.items() if d in ("output", "inout")}

    spans = [(start, end) for _ports, start, end in instances]
    stmts = _statements(parent_body, spans)
    targets: list[str | None] = []
    uses: dict[str, set[int]] = {}
    for idx, (stmt, _pos) in enumerate(stmts):
        tgt = _assign_target(stmt)
        targets.append(tgt)
        rhs = stmt
        if tgt is not None:
            m = re.search(r"(<=|(?<![=!<>+\-*/%&|^])=(?!=))", stmt)
            rhs = stmt[m.end() :] if m else stmt
            lhs_names = [n for n in re.findall(IDENT, stmt[: m.start()] if m else "") if n not in _KEYWORDS]
            for name in lhs_names[:-1]:
                uses.setdefault(name, set()).add(idx)
        for name in re.findall(IDENT, rhs):
            if name in _KEYWORDS:
                continue
            uses.setdefault(name, set()).add(idx)

    # A statement with no assignment target that carries named port connections is
    # another module instance: nets appearing in it escape into that instance.
    instance_conn = [
        targets[i] is None and re.search(rf"\.\s*{IDENT}\s*\(", stmts[i][0]) is not None
        for i in range(len(stmts))
    ]

    live: set[str] = set(parent_outputs)
    changed = True
    while changed:
        changed = False
        for name, idxs in uses.items():
            if name in live:
                continue
            for idx in idxs:
                tgt = targets[idx]
                if tgt is None:
                    if instance_conn[idx]:
                        live.add(name)
                        changed = True
                        break
                    continue
                if tgt in live:
                    live.add(name)
                    changed = True
                    break

    best: dict[str, OutputSink] = {}
    rank = {"live": 0, "dead_end": 1, "unconnected": 2}
    for ports, _start, _end in instances:
        for conn in parse_port_conns(ports):
            if directions.get(conn.port) != "output":
                continue
            if not conn.nets:
                sink = OutputSink(conn.port, None, "unconnected", conn.raw[:40] or "<empty>")
            elif any(n in live for n in conn.nets):
                sink = OutputSink(conn.port, conn.net, "live", "reaches parent output or another instance")
            else:
                consumers = sorted(
                    {targets[i] or "<none>" for n in conn.nets for i in uses.get(n, set())}
                )
                sink = OutputSink(
                    conn.port,
                    conn.net,
                    "dead_end",
                    ",".join(consumers) if consumers else "no_consumers",
                )
            prev = best.get(conn.port)
            if prev is None or rank[sink.status] < rank[prev.status]:
                best[conn.port] = sink
    ordered = [best[p] for p in directions if p in best]
    return ordered, {n: d for n, d in directions.items() if d == "output"}
