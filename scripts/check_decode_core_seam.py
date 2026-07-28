#!/usr/bin/env python3
"""Anti-vacuity gate for the product decode core seam in stream_path.

`h264_decode_core` being *instantiated* from `stream_path` is not the same as
`h264_decode_core` being *connected*.  As measured on branch `w-decode-o5`, most
of the core's inputs are tied to constants and every one of its outputs
terminates in the synthesis `_keep` wire, so the core cannot decode anything and
nothing it produces is observable.  Meanwhile `decode_stub` is the sole driver of
`fs_wr_en / fs_wr_pixel / fs_wr_reset / fs_swap`.

This gate measures that vacuity from the RTL source and pins it against an
explicit manifest.  The manifest must match the measurement exactly in BOTH
directions:

  * tying a new core port to a constant fails (no new vacuity),
  * wiring a declared-vacuous port up fails until the manifest entry is deleted
    (progress must be recorded, never silently absorbed).

Exit codes: 0 pass, 1 fail.  This gate never skips.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL_DIR = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
STREAM_PATH = RTL_DIR / "stream_path.sv"
CORE_RTL = RTL_DIR / "h264_decode_core.sv"
MANIFEST = RTL_DIR / "decode_core_seam_debt.txt"

CORE_MODULE = "h264_decode_core"
CORE_INSTANCE = "product_decode_core"
# Frame-store write port of stream_path.  Whoever drives these drives the picture.
PRESENTATION_PORTS = ("fs_wr_en", "fs_wr_pixel", "fs_wr_reset", "fs_swap")

CONST_RE = re.compile(r"^\d*'[sS]?[hHdDbBoO][0-9a-fA-FxXzZ_]+$")


def fail(msg: str) -> None:
    print(f"DECODE_CORE_SEAM_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def port_directions(core_text: str) -> dict[str, str]:
    header = core_text.split(")(", 1)
    if len(header) < 2:
        fail(f"could not locate {CORE_MODULE} port list in {CORE_RTL.relative_to(ROOT)}")
    body = header[1]
    depth = 0
    end = None
    for i, ch in enumerate(body):
        if ch == "(":
            depth += 1
        elif ch == ")":
            if depth == 0:
                end = i
                break
            depth -= 1
    if end is None:
        fail(f"unterminated {CORE_MODULE} port list")
    dirs: dict[str, str] = {}
    current: str | None = None
    for decl in body[:end].split(","):
        m = re.search(r"\b(input|output|inout)\b", decl)
        if m:
            current = m.group(1)
        if current is None:
            continue
        flat = re.sub(r"\[[^\]]*\]", " ", decl)
        cand = re.findall(r"\b([A-Za-z_]\w*)\b", flat)
        if cand:
            dirs[cand[-1]] = current
    return dirs


def instance_connections(sp_text: str) -> tuple[dict[str, str], str]:
    m = re.search(
        r"\b" + CORE_MODULE + r"\b[^;]*?\b" + CORE_INSTANCE + r"\s*\(",
        sp_text,
        re.S,
    )
    if not m:
        fail(
            f"{STREAM_PATH.relative_to(ROOT)} does not instantiate {CORE_MODULE} "
            f"as {CORE_INSTANCE}; the product decode root moved without updating this gate"
        )
    start = m.end()
    depth = 1
    i = start
    while i < len(sp_text) and depth:
        if sp_text[i] == "(":
            depth += 1
        elif sp_text[i] == ")":
            depth -= 1
        i += 1
    body = sp_text[start : i - 1]
    conns: dict[str, str] = {}
    for pm in re.finditer(r"\.\s*([A-Za-z_]\w*)\s*\(", body):
        j = pm.end()
        d = 1
        while j < len(body) and d:
            if body[j] == "(":
                d += 1
            elif body[j] == ")":
                d -= 1
            j += 1
        conns[pm.group(1)] = " ".join(body[pm.end() : j - 1].split())
    if not conns:
        fail(f"parsed zero port connections for {CORE_INSTANCE}; gate would be vacuous")
    return conns, body


def is_constant(expr: str) -> bool:
    e = expr.strip()
    if not e:
        return False
    if CONST_RE.match(e):
        return True
    return bool(re.fullmatch(r"\d+", e))


def constant_fed_arrays(sp_text: str, conns: dict[str, str], dirs: dict[str, str]) -> set[str]:
    """Array ports are fed via wires assigned constants in a generate loop."""
    out: set[str] = set()
    for port, expr in conns.items():
        if dirs.get(port) != "input" or is_constant(expr):
            continue
        if not re.fullmatch(r"[A-Za-z_]\w*", expr):
            continue
        assigns = re.findall(
            r"\bassign\s+" + re.escape(expr) + r"\s*\[[^\]]*\]\s*=\s*([^;]+);", sp_text
        )
        if assigns and all(is_constant(a) for a in assigns):
            out.add(port)
    return out


def multibit_ports(core_text: str) -> set[str]:
    """Ports declared with a packed range, i.e. data rather than 1-bit control."""
    out: set[str] = set()
    for m in re.finditer(
        r"\b(?:input|output|inout)\b[^;,)]*?\[[^\]]*\][^;,)]*", core_text
    ):
        decl = m.group(0)
        ids = re.findall(r"[A-Za-z_]\w*", decl)
        if ids:
            out.add(ids[-1])
    return out


def synthetic_reg_inputs(
    sp_text: str, conns: dict[str, str], dirs: dict[str, str], wide: set[str]
) -> set[str]:
    """Core inputs fed by a local reg whose only non-reset source is a literal.

    A port tie like `.cbp_luma(4'hf)` is obvious.  The dangerous case is the
    port that LOOKS wired - `.luma4x4_total_coeff(core_luma4x4_total_coeff)` -
    where the driving register is only ever assigned a constant.  That is a
    synthetic value wearing the costume of real data, and it is invisible to a
    port-tie check.  Reset-block assignments are ignored; a register that is
    only ever reset is already covered by the constant-input check.
    """
    out: set[str] = set()
    for port, expr in conns.items():
        if dirs.get(port) != "input" or is_constant(expr):
            continue
        if port not in wide:
            continue
        if not re.fullmatch(r"[A-Za-z_]\w*", expr):
            continue
        # Only consider signals declared as regs in stream_path.
        if not re.search(r"\breg\b[^;]*\b" + re.escape(expr) + r"\b", sp_text):
            continue
        rhs = re.findall(
            r"\b" + re.escape(expr) + r"\s*(?:\[[^\]]*\])?\s*<=\s*([^;]+);", sp_text
        )
        rhs += re.findall(
            r"\bassign\s+" + re.escape(expr) + r"\s*=\s*([^;]+);", sp_text
        )
        if not rhs:
            continue
        if all(is_constant(r) for r in rhs):
            out.add(port)
    return out


def unobserved_outputs(
    sp_text: str, inst_body: str, conns: dict[str, str], dirs: dict[str, str]
) -> set[str]:
    """Core outputs with no consumer outside the anti-prune wire or a self-loop.

    Every mention of the output net is examined in its enclosing statement.  A
    statement whose assignment target is itself connected to the same core
    instance is feedback, not observation (for example
    `core_dpb_rd_valid <= core_dpb_rd_en;`), and so is the `_keep` anti-prune
    wire.  Anything else -- including use as an `if`/ternary condition -- counts
    as a real consumer and the port stops being vacuous.
    """
    core_nets = {
        e.strip() for e in conns.values() if re.fullmatch(r"[A-Za-z_]\w*", e.strip())
    }
    # Blank out the core instance connection list so its own ports do not read
    # as consumers of themselves.
    rest = sp_text.replace(inst_body, " " * len(inst_body), 1)
    chunks = rest.split(";")
    decl_re = re.compile(r"^\s*(?:\(\*.*?\*\)\s*)?(?:wire|reg|logic|integer|genvar)\b")
    lhs_re = re.compile(r"\b([A-Za-z_]\w*)\s*(?:<=|=)(?!=)")

    out: set[str] = set()
    for port, expr in conns.items():
        if dirs.get(port) != "output":
            continue
        net = expr.strip()
        if not re.fullmatch(r"[A-Za-z_]\w*", net):
            continue
        pat = re.compile(r"\b" + re.escape(net) + r"\b")
        real_consumer = False
        for chunk in chunks:
            if not pat.search(chunk):
                continue
            targets = set(lhs_re.findall(chunk))
            if decl_re.match(chunk) and not targets:
                continue  # plain net declaration
            if targets and targets <= (core_nets | {"_keep"}):
                continue  # feedback into the same instance, or the anti-prune wire
            if not targets:
                continue  # no assignment at all: port map fragment or similar
            real_consumer = True
            break
        if not real_consumer:
            out.add(port)
    return out


def presentation_driver(sp_text: str) -> str:
    """Which instantiated module drives the stream_path frame-store write port."""
    drivers: set[str] = set()
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?([A-Za-z_]\w*)\s*\(", sp_text):
        mod_name = m.group(1)
        if mod_name in ("module", "if", "for", "case", "always", "assign", "begin", "function", "task"):
            continue
        start = m.end()
        depth = 1
        i = start
        while i < len(sp_text) and depth:
            if sp_text[i] == "(":
                depth += 1
            elif sp_text[i] == ")":
                depth -= 1
            i += 1
        body = sp_text[start : i - 1]
        if not re.search(r"\.\s*\w+\s*\(", body):
            continue
        for port in PRESENTATION_PORTS:
            if re.search(r"\.\s*\w+\s*\(\s*" + re.escape(port) + r"\s*\)", body):
                drivers.add(mod_name)
    if len(drivers) != 1:
        fail(
            "could not resolve a single driver for the frame-store write port "
            f"{PRESENTATION_PORTS}; resolved={sorted(drivers)}"
        )
    return drivers.pop()


def parse_manifest() -> tuple[dict[str, dict[str, str]], str]:
    if not MANIFEST.exists():
        fail(f"missing seam manifest {MANIFEST.relative_to(ROOT)}")
    sections: dict[str, dict[str, str]] = {
        "constant_inputs": {},
        "synthetic_reg_inputs": {},
        "unobserved_outputs": {},
    }
    driver = ""
    current: str | None = None
    for lineno, raw in enumerate(MANIFEST.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip()
            if current not in sections and current != "presentation_driver":
                fail(f"{MANIFEST.relative_to(ROOT)}:{lineno}: unknown section {current!r}")
            continue
        if current is None:
            fail(f"{MANIFEST.relative_to(ROOT)}:{lineno}: entry before any [section]")
        if current == "presentation_driver":
            driver = line
            continue
        if ":" not in line:
            fail(f"{MANIFEST.relative_to(ROOT)}:{lineno}: expected 'port: reason'")
        name, reason = [p.strip() for p in line.split(":", 1)]
        if not re.fullmatch(r"[A-Za-z_]\w*", name):
            fail(f"{MANIFEST.relative_to(ROOT)}:{lineno}: invalid port name {name!r}")
        if len(reason) < 12:
            fail(f"{MANIFEST.relative_to(ROOT)}:{lineno}: reason is too vague")
        if name in sections[current]:
            fail(f"{MANIFEST.relative_to(ROOT)}:{lineno}: duplicate entry {name}")
        sections[current][name] = reason
    if not driver:
        fail(f"{MANIFEST.relative_to(ROOT)}: [presentation_driver] must name the frame-store driver")
    return sections, driver


def diff_report(label: str, measured: set[str], declared: set[str]) -> bool:
    bad = False
    for name in sorted(measured - declared):
        print(f"UNDECLARED_{label} {name}", file=sys.stderr)
        bad = True
    for name in sorted(declared - measured):
        print(
            f"STALE_{label} {name} is no longer vacuous; delete it from "
            f"{MANIFEST.relative_to(ROOT)}",
            file=sys.stderr,
        )
        bad = True
    return bad


FALSE_LITERAL = re.compile(r"^\(*\s*(?:1'[bdh]0|'0|0+)\s*\)*$")


def enclosing_generate_conditions(sp_text: str) -> list[tuple[str, str]]:
    """Conditions of every `if (...) begin` block that encloses the core instance.

    w-audit mutation M1: an instantiation inside a disabled `if (0)` generate is
    not in the design at all, yet a source-level reachability graph still counts
    it.  The seam gate is the right place to catch this: a core inside a dead
    generate is the most vacuous seam possible.
    """
    inst = re.search(
        rf"\b{CORE_MODULE}\b\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?"
        rf"(?:\\)?{CORE_INSTANCE}\b",
        sp_text,
    )
    if inst is None:
        return [("<core-instance-not-found>", "<none>")]
    at = inst.start()

    found: list[tuple[str, str]] = []
    for m in re.finditer(r"\bif\s*\(", sp_text):
        if m.start() > at:
            break
        depth, i = 1, m.end()
        while i < len(sp_text) and depth:
            depth += (sp_text[i] == "(") - (sp_text[i] == ")")
            i += 1
        cond = sp_text[m.end() : i - 1].strip()
        tail = sp_text[i : i + 400]
        bm = re.match(r"\s*begin\b", tail)
        if not bm:
            continue
        j = i + bm.end()
        depth = 1
        for tok in re.finditer(r"\b(begin|end)\b", sp_text[j:]):
            depth += 1 if tok.group(1) == "begin" else -1
            if depth == 0:
                if j + tok.start() > at:
                    found.append((cond, sp_text[m.end() : i - 1].strip()))
                break
    return found


def dead_generate_guard(sp_text: str) -> list[str]:
    dead = []
    for cond, _raw in enclosing_generate_conditions(sp_text):
        if cond == "<core-instance-not-found>":
            dead.append("core instance not found in stream_path")
        elif FALSE_LITERAL.match(cond.replace(" ", "")):
            dead.append(f"core instantiated inside disabled generate `if ({cond})`")
    return dead


QIP = RTL_DIR.parent / "files.qip"


def qip_filenames() -> set[str]:
    if not QIP.exists():
        return set()
    return {
        Path(f).name
        for f in re.findall(r"[\w./-]+\.s?v", QIP.read_text(encoding="utf-8"))
    }


def core_subtree_qip_guard() -> tuple[list[str], int]:
    """Every module under the core must be in the Quartus file list.

    w-audit mutation M3: a module can be tracked in git, pass every source-level
    reachability check, and still be absent from files.qip -- i.e. not compiled
    into the design at all.  Reachability says yes; the bitstream says no.
    """
    mod_file: dict[str, str] = {}
    bodies: dict[str, str] = {}
    for path in sorted(RTL_DIR.rglob("*.sv")) + sorted(RTL_DIR.rglob("*.v")):
        body = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        for m in re.finditer(
            r"^\s*module\s+([A-Za-z_]\w*)(.*?)^endmodule", body, re.M | re.S
        ):
            mod_file.setdefault(m.group(1), path.name)
            bodies.setdefault(m.group(1), m.group(2))

    known = set(mod_file)
    inst = re.compile(
        r"^[ \t]*([A-Za-z_]\w*)[ \t\r\n]*"
        r"(?:#[ \t\r\n]*\((?:[^()]|\([^()]*\))*\)[ \t\r\n]*)?"
        r"\\?([A-Za-z_]\w*)[ \t\r\n]*\(",
        re.M,
    )
    seen = {CORE_MODULE}
    stack = [CORE_MODULE]
    while stack:
        for child, iname in inst.findall(bodies.get(stack.pop(), "")):
            if child in known and child != iname and child not in seen:
                seen.add(child)
                stack.append(child)

    in_qip = qip_filenames()
    missing = sorted(
        f"{m} ({mod_file[m]}) is under {CORE_MODULE} but absent from files.qip"
        for m in seen
        if mod_file[m] not in in_qip
    )
    return missing, len(seen)


def main() -> int:
    for path in (STREAM_PATH, CORE_RTL, MANIFEST):
        if not path.exists():
            fail(f"missing required file {path.relative_to(ROOT)}")
    sp_text = strip_comments(STREAM_PATH.read_text(encoding="utf-8"))
    core_text = strip_comments(CORE_RTL.read_text(encoding="utf-8"))

    dirs = port_directions(core_text)
    conns, inst_body = instance_connections(sp_text)

    unknown = sorted(p for p in conns if p not in dirs)
    if unknown:
        fail("instance connects ports not declared by the core: " + ", ".join(unknown))

    const_inputs = {
        p for p, e in conns.items() if dirs.get(p) == "input" and is_constant(e)
    }
    const_inputs |= constant_fed_arrays(sp_text, conns, dirs)
    synthetic = synthetic_reg_inputs(sp_text, conns, dirs, multibit_ports(core_text))
    unobserved = unobserved_outputs(sp_text, inst_body, conns, dirs)
    driver = presentation_driver(sp_text)

    for problem in dead_generate_guard(sp_text):
        fail(problem)

    qip_missing, subtree_n = core_subtree_qip_guard()
    for problem in qip_missing:
        print(f"CORE_MODULE_NOT_IN_QIP {problem}", file=sys.stderr)
    if qip_missing:
        fail(
            f"{len(qip_missing)} module(s) under {CORE_MODULE} are not in the "
            "Quartus file list; they cannot be in the bitstream"
        )

    sections, declared_driver = parse_manifest()

    bad = diff_report("CONSTANT_CORE_INPUT", const_inputs, set(sections["constant_inputs"]))
    bad |= diff_report("SYNTHETIC_CORE_INPUT", synthetic, set(sections["synthetic_reg_inputs"]))
    bad |= diff_report("UNOBSERVED_CORE_OUTPUT", unobserved, set(sections["unobserved_outputs"]))

    if driver != declared_driver:
        print(
            f"PRESENTATION_DRIVER_CHANGED measured={driver} declared={declared_driver}",
            file=sys.stderr,
        )
        bad = True

    total_inputs = sum(1 for p in conns if dirs.get(p) == "input")
    total_outputs = sum(1 for p in conns if dirs.get(p) == "output")
    if bad:
        fail(
            f"{STREAM_PATH.relative_to(ROOT)} decode-core seam does not match "
            f"{MANIFEST.relative_to(ROOT)}"
        )

    print(
        "DECODE_CORE_SEAM_OK "
        f"core_inputs={total_inputs} constant_inputs={len(const_inputs)} "
        f"synthetic_reg_inputs={len(synthetic)} "
        f"core_outputs={total_outputs} unobserved_outputs={len(unobserved)} "
        f"presentation_driver={driver} live_generate=yes "
        f"core_subtree={subtree_n} core_subtree_in_qip={subtree_n}"
    )
    if driver != CORE_MODULE:
        print(
            "DECODE_CORE_SEAM_NOTE product pixels are NOT produced by "
            f"{CORE_MODULE}; frame-store writes come from {driver}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
