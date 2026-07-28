#!/usr/bin/env python3
"""Failure mode 3 detector: a module that is compiled, instantiated and
elaborated, and then deleted by synthesis because its outputs drive nothing.

w-fit-o5 measured this on w-decode-hour27 2f165ed with Quartus Analysis &
Synthesis: h264_decode_core elaborates under emu|stream_path and is then removed
as dead logic.  Quartus names the fingerprint itself:

    Warning (10036): object "_keep_decode_core_inputs" assigned a value but
                     never read

The keep-alive that was supposed to hold the core in the design is itself never
read, so it holds nothing.

The three known ways a module can be absent from the bitstream:

  1. not compiled      -- missing from files.qip   -> check_qip_coverage.py
  2. not instantiated  -- orphaned from the top    -> check_prefit_hierarchy.py
  3. optimized away    -- outputs drive nothing    -> THIS GATE

Mode 3 is invisible to every source-level graph and to Verilator elaboration,
because the instantiation is real and unconditional.  Both of the gates above
report GREEN on a design in mode 3.  That is measured, not argued: on
w-deblock-o5-converge check_prefit_hierarchy.py reports h264_decode_core
PRESENT while Quartus A&S reports it ABSENT.

HOW THIS GATE WORKS

Quartus deletes logic whose outputs cannot be observed.  Verilator computes the
same property and reports its leaves as UNUSEDSIGNAL.  So:

  * run Verilator lint over exactly the files.qip product list, rooted at the
    product top, and collect every UNUSEDSIGNAL;
  * for the module under test, find the nets bound to its OUTPUT ports;
  * propagate deadness backwards -- a net is dead if it has no readers, or if
    every net that reads it is itself dead;
  * if every output net of the module is dead, the module drives nothing
    observable and synthesis is entitled to delete it.

MEASURED BLIND SPOT -- read before treating a LIVE verdict as permission.

Observability is necessary for survival but not sufficient.  A module whose
outputs are observable can still fold to a constant, contribute zero resources,
and be deleted.  This gate reports it LIVE.  Proved with the dl_probe_constfold
probe in tests/unit/test_deadlogic_sink_redproof.sh, which is asserted to be a
false LIVE so that the boundary cannot rot silently.

This is not hypothetical on the current branch: h264_decode_core's inputs are
tied to constants at stream_path.sv:447-459 (core_rbsp_byte all 8'd0, recon and
residual constant).  So even after someone consumes the core's outputs and this
gate turns green, Quartus may STILL delete the core by constant propagation.
Consuming the outputs and un-tying the inputs are one task, not two.

Therefore: rc=1 here is strong evidence of a defect; rc=0 is a cheap pre-filter
result and NEVER grounds to request a fit.  Step 3 of the gate order
(check_prefit_elaboration.sh, Quartus A&S) remains mandatory.

This is a cheap approximation of Quartus, not a replacement for it.  It is
deliberately CONSERVATIVE: anything it cannot resolve (a port connection to
another instance, a hierarchical reference) counts as a LIVE reader.  It
therefore under-reports deadness, so a rc=1 from this gate is strong evidence
and a rc=0 is weak evidence.  Quartus A&S (scripts/check_prefit_elaboration.sh,
w-fit-o5) remains the pre-fit oracle and make post-fit-hierarchy the final one.

Exit codes: 0 pass, 1 fail, 77 skip (never a pass), 2 usage error.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QIP = ROOT / "fpga" / "Plex_MiSTer" / "files.qip"
FPGA = ROOT / "fpga" / "Plex_MiSTer"
BLACKBOX = ROOT / "tests" / "rtl" / "prefit_blackbox" / "altera_blackbox.sv"
RUN_VERILATOR = ROOT / "scripts" / "run_verilator.sh"

WAIVERS = ["-Wno-fatal", "-Wno-PROCASSWIRE", "-Wno-DECLFILENAME"]

# Verilog keywords and common attributes that the identifier scanner must not
# mistake for nets.  Over-inclusion here is safe (a keyword can never be a real
# reader); under-inclusion only costs a spurious LIVE verdict, never a
# spurious DEAD one.
KEYWORDS = {
    "assign", "always", "always_comb", "always_ff", "always_latch", "begin",
    "end", "if", "else", "case", "casez", "casex", "endcase", "for", "while",
    "posedge", "negedge", "or", "and", "not", "wire", "reg", "logic", "signed",
    "unsigned", "integer", "genvar", "generate", "endgenerate", "localparam",
    "parameter", "default", "function", "endfunction", "task", "endtask",
    "return", "input", "output", "inout", "module", "endmodule", "initial",
    "int", "bit", "byte", "real", "time", "automatic", "static", "const",
    "typedef", "struct", "packed", "enum", "unique", "priority", "break",
    "continue", "repeat", "forever", "do", "wait", "disable", "fork", "join",
}

IDENT = re.compile(r"\\\S+\s|\b[A-Za-z_][A-Za-z0-9_$]*\b")
UNUSED_RE = re.compile(
    r"%Warning-UNUSEDSIGNAL:\s*(?P<file>[^:]+):(?P<line>\d+):\d+:\s*"
    r"Signal is not used:\s*'(?P<name>[^']+)'"
)


def fail(msg: str) -> int:
    print(f"DEADLOGIC_SINK_FAIL: {msg}", file=sys.stderr)
    return 1


def skip(msg: str) -> int:
    print(f"SKIP-NOT-PASS check_deadlogic_sink: {msg}", file=sys.stderr)
    return 77


def qip_sources() -> list[Path]:
    out: list[Path] = []
    pattern = re.compile(
        r"^set_global_assignment\s+-name\s+(?:SYSTEMVERILOG_FILE|VERILOG_FILE)\s+(\S+)"
    )
    for line in QIP.read_text().splitlines():
        m = pattern.match(line.strip())
        if m:
            out.append(FPGA / m.group(1))
    return out


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return text


def idents(text: str) -> set[str]:
    return {t.strip() for t in IDENT.findall(text)} - KEYWORDS


def _header_span(text: str, m) -> tuple[int, int] | None:
    """Character span of a module's PORT list, skipping any `#( ... )`."""
    rest = text[m.end():]
    hm = re.match(r"\s*(?:\\\S+\s|[A-Za-z_][A-Za-z0-9_$]*)?\s*", rest)
    pos = m.end() + (hm.end() if hm else 0)
    if pos < len(text) and text[pos] == "#":
        pos = text.index("(", pos)
        d = 0
        for j in range(pos, len(text)):
            if text[j] == "(":
                d += 1
            elif text[j] == ")":
                d -= 1
                if d == 0:
                    pos = j + 1
                    break
    i = text.find("(", pos)
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return (i, j)
    return None


def enclosing_module_name(path: Path, offset: int) -> str | None:
    """Name of the module that lexically contains `offset`."""
    text = strip_comments(path.read_text(errors="replace"))
    last = None
    for m in re.finditer(
        r"\bmodule\s+(\\\S+\s|[A-Za-z_][A-Za-z0-9_$]*)", text
    ):
        if m.start() < offset:
            last = m
        else:
            break
    return last.group(1).strip() if last else None


def enclosing_module_ports(path: Path, offset: int) -> set[str]:
    """Every port name of the module that lexically contains `offset`.

    A net that is a port of the enclosing module escapes the file and must
    never be called dead here, however few local readers it has.
    """
    text = strip_comments(path.read_text(errors="replace"))
    last = None
    for m in re.finditer(r"\bmodule\s+(?:\\\S+\s|[A-Za-z_][A-Za-z0-9_$]*)", text):
        if m.start() < offset:
            last = m
        else:
            break
    if last is None:
        return set()
    span = _header_span(text, last)
    if span is None:
        return set()
    header = text[span[0]:span[1]]
    names: set[str] = set()
    for chunk in header.split(","):
        toks = [t.strip() for t in IDENT.findall(chunk)]
        toks = [t for t in toks if t not in KEYWORDS]
        if toks:
            names.add(toks[-1])
    return names


def module_outputs(name: str, sources: list[Path]) -> tuple[list[str], Path | None]:
    """Output port names of `name`, from its ANSI-style module header."""
    decl = re.compile(r"\bmodule\s+" + re.escape(name) + r"\b")
    for path in sources:
        text = strip_comments(path.read_text(errors="replace"))
        m = decl.search(text)
        if not m:
            continue
        span = _header_span(text, m)
        if span is None:
            return [], path
        header = text[span[0]:span[1]]
        outs: list[str] = []
        for chunk in header.split(","):
            if not re.search(r"\boutput\b", chunk):
                continue
            names = [t.strip() for t in IDENT.findall(chunk)]
            names = [n for n in names if n not in KEYWORDS]
            # Drop packed-dimension survivors; the port name is the last ident.
            if names:
                outs.append(names[-1])
        return outs, path
    return [], None


def instantiation_bindings(
    module: str, sources: list[Path]
) -> list[tuple[Path, dict[str, str], tuple[int, int]]]:
    """Named .port(net) bindings for every instantiation of `module`.

    The character span of the instantiation is returned as well.  It must be
    excised before the reader map is built: a net bound to an OUTPUT port is
    driven there, not read, and counting the instance as a reader of its own
    outputs makes every module read LIVE for free.  That defect was present in
    this gate's first run and is why the span is part of the interface.
    """
    out: list[tuple[Path, dict[str, str], tuple[int, int]]] = []
    inst_re = re.compile(
        r"\b" + re.escape(module) + r"\b\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?"
        r"(?:\\\S+\s|[A-Za-z_][A-Za-z0-9_$]*)\s*\(",
        re.S,
    )
    for path in sources:
        text = strip_comments(path.read_text(errors="replace"))
        # Skip the module's own declaration.
        for m in inst_re.finditer(text):
            pre = text[max(0, m.start() - 12):m.start()]
            if re.search(r"\bmodule\s*$", pre):
                continue
            depth = 0
            end = -1
            start = m.end() - 1
            for j in range(start, len(text)):
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                    if depth == 0:
                        end = j
                        break
            if end < 0:
                continue
            body = text[start + 1:end]
            binds: dict[str, str] = {}
            for pm in re.finditer(r"\.\s*(\w+)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)", body):
                expr = pm.group(2).strip()
                names = [t.strip() for t in IDENT.findall(expr)]
                names = [n for n in names if n not in KEYWORDS]
                if len(names) == 1:
                    binds[pm.group(1)] = names[0]
                elif names:
                    # An expression, not a plain net: treat as live by marking
                    # it with a name that can never appear in UNUSEDSIGNAL.
                    binds[pm.group(1)] = "\x00expr"
            if binds:
                out.append((path, binds, (m.start(), end + 1)))
    return out


def reader_map(path: Path, excise: tuple[int, int] | None = None) -> dict[str, set[str]]:
    """net -> set of nets whose value depends on it, within one file.

    Conservative by construction: statements this parser cannot decompose
    contribute a synthetic LIVE reader rather than being dropped, so a net is
    only ever called dead when nothing observable was found.
    """
    text = strip_comments(path.read_text(errors="replace"))
    if excise is not None:
        a, b = excise
        # Preserve offsets so the blanked region cannot merge two statements.
        text = text[:a] + (" " * (b - a)) + text[b:]
    readers: dict[str, set[str]] = {}
    for stmt in text.split(";"):
        if not stmt.strip():
            continue
        m = re.search(r"(<=|(?<![=!<>+\-*/%&|^])=(?!=))", stmt)
        if not m:
            # Not an assignment.  Port connections and other reads keep their
            # identifiers alive: give every identifier a synthetic live reader.
            if re.search(r"\.\s*\w+\s*\(", stmt):
                for n in idents(stmt):
                    readers.setdefault(n, set()).add("\x00port")
            continue
        pre, post = stmt[:m.start()], stmt[m.end():]
        lhs_names = [t.strip() for t in IDENT.findall(pre)]
        lhs_names = [n for n in lhs_names if n not in KEYWORDS]
        if not lhs_names:
            continue
        lhs = lhs_names[-1]
        # Everything else in the statement -- RHS and any surrounding condition
        # -- is read in order to compute lhs.
        for n in (idents(pre) | idents(post)) - {lhs}:
            readers.setdefault(n, set()).add(lhs)
    return readers


def dead_closure(readers: dict[str, set[str]], seed: set[str]) -> set[str]:
    """Nets that cannot influence anything observable.

    Seeded with Verilator's UNUSEDSIGNAL leaves, then propagated backwards: a
    net is dead when it has at least one known reader and every one of those
    readers is dead.  A net with no entry in the map is NOT assumed dead -- it
    may be read by something this parser did not model.
    """
    dead = set(seed)
    changed = True
    while changed:
        changed = False
        for net, rs in readers.items():
            if net in dead or not rs:
                continue
            if all(r in dead for r in rs):
                dead.add(net)
                changed = True
    return dead


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--top", default="emu")
    ap.add_argument(
        "--require-live",
        action="append",
        default=[],
        help="Module whose outputs must reach something observable.",
    )
    ap.add_argument("--label", default="deadlogic")
    args, unknown = ap.parse_known_args(argv)
    if unknown:
        print(f"DEADLOGIC_SINK_USAGE: unknown arguments: {' '.join(unknown)}",
              file=sys.stderr)
        return 2
    if not args.require_live:
        print("DEADLOGIC_SINK_USAGE: at least one --require-live is required",
              file=sys.stderr)
        return 2
    if not QIP.is_file():
        return fail(f"missing {QIP.relative_to(ROOT)}")
    if not RUN_VERILATOR.is_file():
        return skip(f"missing {RUN_VERILATOR.relative_to(ROOT)}")

    sources = qip_sources()
    missing = [p for p in sources if not p.is_file()]
    if missing:
        return fail("files.qip lists missing files: "
                    + ", ".join(str(p) for p in missing))

    inc = ROOT / "build" / "prefit_inc"
    inc.mkdir(parents=True, exist_ok=True)
    (inc / "build_id.v").write_text('`define BUILD_DATE "000000"\n')

    cmd = [
        str(RUN_VERILATOR), "--lint-only", "-Wall", "--top-module", args.top,
        *WAIVERS, f"-I{inc}",
        "-y", str(FPGA / "rtl"), "-y", str(FPGA),
        "-y", str(FPGA / "sys"), "-y", str(FPGA / "rtl" / "pll"),
        "+libext+.sv+.v",
    ]
    if BLACKBOX.is_file():
        cmd.append(str(BLACKBOX))
    cmd += [str(p) for p in sources]

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    except FileNotFoundError:
        return skip("verilator wrapper not executable")

    unused: dict[Path, set[str]] = {}
    total_unused = 0
    for m in UNUSED_RE.finditer(proc.stderr + proc.stdout):
        unused.setdefault(Path(m.group("file")).resolve(), set()).add(m.group("name"))
        total_unused += 1

    if total_unused == 0:
        # Non-vacuity floor.  This design has hundreds of unused signals; zero
        # means the lint run did not happen or the warning was suppressed, and
        # every module would then read LIVE for free.  w-audit's "exits 0
        # without doing any work" class -- refuse to pass instead.
        tail = (proc.stderr or proc.stdout).strip().splitlines()[-6:]
        return fail(
            "verilator produced no UNUSEDSIGNAL warnings at all -- the analysis "
            "did not run, so a LIVE verdict would be vacuous; last output: "
            + " | ".join(tail)
        )

    # Liveness must be TRANSITIVE to the product top.  A module whose outputs
    # are consumed inside a parent that is itself deleted is deleted with it --
    # h264_deblock_mb_filter is fully consumed inside h264_decode_core, and the
    # core is a DEAD_SINK, so the filter goes too.  Reporting the filter LIVE on
    # its local evidence alone would be the same subtree-without-trunk fallacy
    # that let a decoder-less bitstream ship, reproduced inside this gate.
    stats = {"nets": 0}
    memo: dict[str, tuple[bool, str]] = {}

    def live(name: str, stack: tuple[str, ...] = ()) -> tuple[bool, str]:
        if name == args.top:
            return True, args.top
        if name in memo:
            return memo[name]
        if name in stack:
            return False, "CYCLE"
        memo[name] = (False, "IN_PROGRESS")
        insts = instantiation_bindings(name, sources)
        if not insts:
            memo[name] = (False, "NOT_INSTANTIATED")
            return memo[name]
        outs, decl_path = module_outputs(name, sources)
        if decl_path is None:
            memo[name] = (False, "NOT_DECLARED_IN_QIP_SOURCES")
            return memo[name]
        best = (False, "NO_LIVE_PATH")
        for path, binds, span in insts:
            nets = [binds[o] for o in outs if o in binds]
            parent = enclosing_module_name(path, span[0])
            if parent is None:
                continue
            if not outs or not nets:
                # A module with no outputs at all (or none bound) cannot be
                # judged by this method; defer to the parent and say so.
                local_live = bool(outs) is False
                reason = "NO_OUTPUTS" if not outs else "NO_OUTPUT_BINDINGS"
            else:
                readers = reader_map(path, excise=span)
                seed = set(unused.get(path.resolve(), set()))
                parent_ports = enclosing_module_ports(path, span[0])
                for net in binds.values():
                    if net.startswith("\x00"):
                        continue  # unanalysable binding; never seed it dead
                    if net not in readers and net not in parent_ports:
                        seed.add(net)
                dead = dead_closure(readers, seed)
                # A binding this parser could not reduce to a single net (an
                # indexed target such as .rd_data(line_q[li]), or any
                # expression) counts as LIVE.  Conservatism must always point
                # away from declaring something dead: a false DEAD_SINK would
                # send someone hunting a defect that is not there.  Measured:
                # line_buf_ram read DEAD_SINK before this rule for exactly that
                # reason, and it is genuinely live in ddr_frame_store.
                live_nets = [
                    n for n in nets
                    if n.startswith("\x00")
                    or (n not in dead and (n in readers or n in parent_ports))
                ]
                stats["nets"] += len(nets)
                local_live = bool(live_nets)
                reason = f"{len(live_nets)}/{len(nets)}_live_outputs"
            if not local_live:
                if best[0] is False and best[1] == "NO_LIVE_PATH":
                    best = (False, f"{parent}:{reason}")
                continue
            p_live, p_chain = live(parent, stack + (name,))
            if p_live:
                memo[name] = (True, f"{p_chain}|{name}")
                return memo[name]
            best = (False, f"DEAD_PARENT[{p_chain}]->{name}")
        memo[name] = best
        return best

    verdicts: list[str] = []
    bad: list[str] = []
    for module in args.require_live:
        ok, chain = live(module)
        verdicts.append(f"{module}=" + ("LIVE" if ok else "DEAD_SINK") + f" [{chain}]")
        if not ok:
            bad.append(f"{module}={chain}")
    checked_nets = stats["nets"]

    print(
        f"Scope: label={args.label} top={args.top} qip_sources={len(sources)} "
        f"unusedsignal_warnings={total_unused} modules_checked={len(args.require_live)} "
        f"output_nets_examined={checked_nets}"
    )
    for v in verdicts:
        print("  " + v)

    if bad:
        return fail(
            "module outputs drive nothing observable, so synthesis may delete "
            "them (Quartus failure mode 3): " + ", ".join(bad)
        )
    print(f"DEADLOGIC_SINK_OK label={args.label} modules={len(args.require_live)} "
          f"output_nets_examined={checked_nets} "
          f"detects=unobservable_outputs "
          f"BLIND_SPOT=constant_fold_collapse_NOT_detected "
          f"(a module whose outputs ARE observable but which folds to a "
          f"constant contributes zero resources and Quartus deletes it anyway; "
          f"measured false-LIVE on probe dl_probe_constfold. This rc=0 is NOT "
          f"sufficient to request a fit -- run check_prefit_elaboration.sh)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
