#!/usr/bin/env python3
"""Meta-gate: a gate that cannot evaluate must not exit 0.

The three-state contract, fleet-wide:

    0   evaluated and passed
    1   evaluated and failed
    77  could not evaluate

Nothing else. The defect this catches is **print/exit divergence**: a gate that
detects its own inability to evaluate, says so in text, and then exits 0. The
text goes into a log nobody greps; the exit code goes to every wrapper, Makefile
and CI step. The measured instance -- `check_fitted_line_buffer.py` before
`9043925` -- printed `UNBOUND: no --expect-rbf-md5 given` and then `LINE_BUFFER_OK`
with rc=0.

Detection is AST-based, not textual. For each `print` whose message carries an
inability marker, the gate resolves what the enclosing block actually returns:

  DIVERGENT   the site leads to exit 0
  CONTRACT_OK the site leads to a non-zero exit (1, 2 or 77)
  UNRESOLVED  the disposition depends on state this gate will not guess

**Declared limit:** UNRESOLVED sites are counted and printed but do not fail the
gate. A false RED here would block other workers on a static guess, and this
gate's own credibility depends on not manufacturing confidence either. The count
is published so the hole is visible rather than silent.
"""
from __future__ import annotations

import argparse
import ast
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"

# Strong "I could not evaluate" markers.  Deliberately not "missing"/"error",
# which appear constantly in legitimate failure text that already exits non-zero.
MARKERS = (
    "UNBOUND",
    "UNSCORED",
    "SKIP",
    "N/A",
    "NOT_MEASURED",
    "NO_REPORT",
    "NOT_FOUND",
    "CANNOT EVALUATE",
    "COULD NOT EVALUATE",
    "UNABLE TO EVALUATE",
    "NOT EVALUATED",
    "NO EVIDENCE",
)

EXEMPT = {"check_gate_exit_contract.py"}


@dataclass
class Site:
    file: str
    line: int
    marker: str
    verdict: str
    detail: str


def literal_text(node: ast.AST) -> str:
    """Best-effort literal text of a print argument, including f-string prefixes."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        return "".join(
            part.value for part in node.values
            if isinstance(part, ast.Constant) and isinstance(part.value, str)
        )
    if isinstance(node, ast.BinOp):
        return literal_text(node.left) + literal_text(node.right)
    return ""


PHRASES = ("cannot evaluate", "could not evaluate", "unable to evaluate",
           "not evaluated", "no evidence", "cannot be evaluated")
# Tokens that name a skip without announcing one -- verdict labels and gate
# names.  `SKIP_EXIT_CODE_OK` is a PASS; matching `SKIP` inside it flagged the
# success line of the very gate that enforces skip codes.
TOKEN_MARKERS = {m for m in MARKERS if " " not in m} | {"SKIP-NOT-PASS", "SKIP_NOT_PASS"}


def marker_of(text: str) -> str | None:
    lowered = text.lower()
    for phrase in PHRASES:
        if phrase in lowered:
            return phrase.upper()
    # A line that announces a PASS is not announcing an inability, even when it
    # reports how many unbound things it counted.
    if re.search(r"\b[A-Z][A-Z0-9_]*_OK\b", text):
        return None
    for match in re.finditer(r"[A-Za-z0-9_\-/]+", text):
        token = match.group(0).upper().strip("-")
        if token not in TOKEN_MARKERS:
            continue
        # `unbound=0` is a metric key, not an announcement.
        tail = text[match.end():match.end() + 1]
        if tail == "=":
            continue
        return token
    return None


def exit_code_of(node: ast.AST) -> int | None | str:
    """Return the literal exit code of a return/exit statement, or a marker."""
    if isinstance(node, ast.Return):
        value = node.value
    elif isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
        call = node.value
        name = getattr(call.func, "id", None) or getattr(call.func, "attr", None)
        if name not in {"exit", "_exit"}:
            return "not-exit"
        value = call.args[0] if call.args else None
    elif isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call):
        name = getattr(node.exc.func, "id", None)
        if name != "SystemExit":
            return "not-exit"
        value = node.exc.args[0] if node.exc.args else None
    else:
        return "not-exit"

    if value is None:
        return 0
    if isinstance(value, ast.Constant):
        if value.value is None:
            return 0
        if isinstance(value.value, int):
            return value.value
    return "dynamic"


def find_print_sites(tree: ast.AST) -> list[tuple[ast.AST, list[list[ast.stmt]], str]]:
    """(print_stmt, blocks innermost->outermost, marker) for every inability print."""
    sites: list[tuple[ast.AST, list[list[ast.stmt]], str]] = []

    def walk_block(block: list[ast.stmt], chain: list[list[ast.stmt]] | None = None) -> None:
        chain = [block] + (chain or [])
        for stmt in block:
            if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call):
                func = stmt.value.func
                if getattr(func, "id", None) == "print" and stmt.value.args:
                    text = " ".join(literal_text(a) for a in stmt.value.args)
                    marker = marker_of(text)
                    if marker:
                        sites.append((stmt, chain, marker))
            for field in ("body", "orelse", "finalbody"):
                inner = getattr(stmt, field, None)
                if isinstance(inner, list) and inner and isinstance(inner[0], ast.stmt):
                    walk_block(inner, chain)
            for handler in getattr(stmt, "handlers", []) or []:
                walk_block(handler.body, chain)

    walk_block(getattr(tree, "body", []))
    return sites


def enclosing_function(tree: ast.AST, lineno: int) -> ast.FunctionDef | None:
    best = None
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.lineno <= lineno <= (node.end_lineno or node.lineno):
                if best is None or node.lineno > best.lineno:
                    best = node
    return best


def terminal_code(func: ast.FunctionDef | None) -> int | str | None:
    if func is None or not func.body:
        return "dynamic"
    last = func.body[-1]
    code = exit_code_of(last)
    if code == "not-exit":
        return 0 if not isinstance(last, (ast.Return, ast.Raise)) else "dynamic"
    return code


def classify(stmt: ast.AST, chain: list[list[ast.stmt]], tree: ast.AST) -> tuple[str, str]:
    """Resolve what actually happens after the announcement.

    The disposition may be set by any enclosing block, not just the innermost
    one: a print inside a `for` whose enclosing `if` returns 1 conforms to the
    contract.  Examining only the innermost block reported the skip-code gate's
    own findings loop as divergent.
    """
    rc_names: dict[str, int] = {}
    node: ast.AST = stmt
    for block in chain:
        try:
            index = block.index(node)  # type: ignore[arg-type]
        except ValueError:
            continue
        for follower in block[index + 1:]:
            code = exit_code_of(follower)
            if code != "not-exit":
                if code == "dynamic":
                    named = _exit_name(follower)
                    if named is not None:
                        constant = _module_constant(tree, named)
                        if constant is not None:
                            return (("CONTRACT_OK", f"exits {named}={constant}")
                                    if constant != 0
                                    else ("DIVERGENT", f"exits {named}=0"))
                    resolved = _resolve_named_return(follower, stmt, rc_names, tree)
                    if resolved is not None:
                        return resolved
                    return "UNRESOLVED", "returns a computed value"
                return (("DIVERGENT", "exits 0 after announcing it could not evaluate")
                        if code == 0 else ("CONTRACT_OK", f"exits {code}"))
            if isinstance(follower, ast.Assign) and isinstance(follower.value, ast.Constant):
                for target in follower.targets:
                    if isinstance(target, ast.Name) and isinstance(follower.value.value, int):
                        rc_names.setdefault(target.id, follower.value.value)
            if isinstance(follower, (ast.Continue, ast.Break)):
                return "UNRESOLVED", "loop control; disposition set elsewhere"
        # Nothing decided in this block: ask the block that contains it.
        node = _owner_of(block, chain, node)
        if node is None:
            break

    func = enclosing_function(tree, stmt.lineno)
    if rc_names:
        if all(value != 0 for value in rc_names.values()):
            return "CONTRACT_OK", f"sets {rc_names} then falls through"
        return "DIVERGENT", f"sets {rc_names} then falls through to success"

    code = terminal_code(func)
    if code == "dynamic":
        if func is not None and _initial_rc(func) == 0:
            return ("DIVERGENT",
                    "falls through to a return of a status initialised to 0")
        return "UNRESOLVED", "function returns a computed value"
    if code == 0:
        return "DIVERGENT", "falls through to exit 0"
    return "CONTRACT_OK", f"falls through to exit {code}"


def _owner_of(block: list[ast.stmt], chain: list[list[ast.stmt]],
              node: ast.AST) -> ast.AST | None:
    """The statement in the next outer block that owns `block`."""
    position = chain.index(block)
    if position + 1 >= len(chain):
        return None
    for candidate in chain[position + 1]:
        for field in ("body", "orelse", "finalbody"):
            if getattr(candidate, field, None) is block:
                return candidate
        for handler in getattr(candidate, "handlers", []) or []:
            if handler.body is block:
                return candidate
    return None


def _resolve_named_return(follower: ast.stmt, site: ast.AST,
                          rc_names: dict[str, int],
                          tree: ast.AST) -> tuple[str, str] | None:
    """Resolve `return rc` when rc is a plain status variable.

    This is the shape of the measured instance: `rc = 0` early, an inability
    branch that prints and does not touch rc, then `return rc`.  Reporting it
    UNRESOLVED let the gate miss the exact defect it exists to catch.
    """
    if not isinstance(follower, ast.Return) or not isinstance(follower.value, ast.Name):
        return None
    name = follower.value.id
    # `return UNSCORED` where UNSCORED = 77 at module level is a conforming exit,
    # not an unresolvable one.  Leaving these UNRESOLVED inflated the blind spot.
    constant = _module_constant(tree, name)
    if constant is not None:
        return (("CONTRACT_OK", f"returns {name}={constant}") if constant != 0
                else ("DIVERGENT", f"returns {name}=0"))
    if name in rc_names:
        return (("CONTRACT_OK", f"sets {name}={rc_names[name]} then returns it")
                if rc_names[name] != 0
                else ("DIVERGENT", f"sets {name}=0 then returns it"))
    func = enclosing_function(tree, site.lineno)
    if func is None:
        return None
    # Only assignments at the function's own statement level are guaranteed to
    # dominate the site.  An `rc = 1` inside a sibling branch does not run on the
    # path through the announcement, and counting it called the measured defect
    # CONTRACT_OK -- a confident wrong answer from the detector itself.
    before = sorted(
        (node.lineno, node.value.value)
        for node in func.body
        if isinstance(node, ast.Assign)
        and isinstance(node.value, ast.Constant)
        and isinstance(node.value.value, int)
        and node.lineno < site.lineno
        and any(isinstance(t, ast.Name) and t.id == name for t in node.targets)
    )
    if not before:
        return None
    dominating = before[-1][1]
    if dominating == 0:
        return ("DIVERGENT",
                f"announces inability, leaves {name}=0 from line {before[-1][0]}, "
                "then returns it")
    return None


def _exit_name(node: ast.stmt) -> str | None:
    """The variable a return/exit statement hands back, if it is a bare name."""
    value = None
    if isinstance(node, ast.Return):
        value = node.value
    elif isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call):
        if getattr(node.exc.func, "id", None) == "SystemExit" and node.exc.args:
            value = node.exc.args[0]
    elif isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
        call = node.value
        name = getattr(call.func, "id", None) or getattr(call.func, "attr", None)
        if name in {"exit", "_exit"} and call.args:
            value = call.args[0]
    return value.id if isinstance(value, ast.Name) else None


def _module_constant(tree: ast.AST, name: str) -> int | None:
    for node in getattr(tree, "body", []):
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant):
            if isinstance(node.value.value, int) and any(
                isinstance(t, ast.Name) and t.id == name for t in node.targets
            ):
                return node.value.value
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Tuple):
            targets = node.targets[0] if node.targets else None
            if isinstance(targets, ast.Tuple):
                for target, value in zip(targets.elts, node.value.elts):
                    if (isinstance(target, ast.Name) and target.id == name
                            and isinstance(value, ast.Constant)
                            and isinstance(value.value, int)):
                        return value.value
    return None


def _initial_rc(func: ast.FunctionDef) -> int | None:
    """Value of the variable the function ultimately returns, if trivially set."""
    last = func.body[-1]
    if not isinstance(last, ast.Return) or not isinstance(last.value, ast.Name):
        return None
    name = last.value.id
    value: int | None = None
    for node in ast.walk(func):
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    if isinstance(node.value.value, int) and value is None:
                        value = node.value.value
    return value


def scan(path: Path) -> list[Site]:
    tree = ast.parse(path.read_text(encoding="utf-8", errors="ignore"), filename=str(path))
    sites: list[Site] = []
    for stmt, chain, marker in find_print_sites(tree):
        verdict, detail = classify(stmt, chain, tree)
        sites.append(Site(path.name, stmt.lineno, marker, verdict, detail))
    return sites


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scripts-dir", type=Path, default=SCRIPTS)
    ap.add_argument("--show-ok", action="store_true", help="also list conforming sites")
    args = ap.parse_args(argv)

    files = sorted(p for p in args.scripts_dir.glob("*.py") if p.name not in EXEMPT)
    all_sites: list[Site] = []
    unparsed: list[str] = []
    for path in files:
        try:
            all_sites.extend(scan(path))
        except SyntaxError as exc:
            unparsed.append(f"{path.name}:{exc.lineno}")

    divergent = [s for s in all_sites if s.verdict == "DIVERGENT"]
    unresolved = [s for s in all_sites if s.verdict == "UNRESOLVED"]
    conforming = [s for s in all_sites if s.verdict == "CONTRACT_OK"]

    print(
        f"Scope: gates_scanned={len(files)} inability_sites={len(all_sites)} "
        f"divergent={len(divergent)} contract_ok={len(conforming)} "
        f"unresolved={len(unresolved)} unparsed={len(unparsed)}"
    )

    if not all_sites and not unparsed:
        print(
            "GATE_EXIT_CONTRACT_REFUSED: no inability sites found in any gate. "
            "Either every gate stopped reporting non-evaluation or the detector "
            "is broken; an empty scan cannot certify a contract.",
            file=sys.stderr,
        )
        return 2

    for site in divergent:
        print(f"DIVERGENT {site.file}:{site.line} marker={site.marker} -- {site.detail}")
    for site in unresolved:
        print(f"UNRESOLVED {site.file}:{site.line} marker={site.marker} -- {site.detail}")
    if args.show_ok:
        for site in conforming:
            print(f"CONTRACT_OK {site.file}:{site.line} marker={site.marker} -- {site.detail}")
    for item in unparsed:
        print(f"UNPARSED {item}")

    if divergent:
        print(
            "GATE_EXIT_CONTRACT_FAIL: "
            f"{len(divergent)} site(s) announce that they cannot evaluate and then "
            "exit 0. The text goes to a log nobody greps; the exit code goes to "
            "every wrapper. Use 77 for 'could not evaluate'.",
            file=sys.stderr,
        )
        return 1

    print(
        f"GATE_EXIT_CONTRACT_OK gates={len(files)} sites={len(all_sites)} divergent=0 "
        f"unresolved={len(unresolved)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
