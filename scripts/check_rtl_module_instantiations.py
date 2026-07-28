#!/usr/bin/env python3
"""Gate that every RTL module is reachable from product synthesis or bench-only.

The check is intentionally source-graph based.  It parses every module under
fpga/Plex_MiSTer/rtl plus the product Plex.sv top, follows known-module
instantiations from emu, then requires all rtl/ module declarations to be either
reachable or named with a reason in rtl/bench_only_modules.txt.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL_DIR = ROOT / "fpga" / "Plex_MiSTer" / "rtl"
PRODUCT_TOP = ROOT / "fpga" / "Plex_MiSTer" / "Plex.sv"
BENCH_ONLY = RTL_DIR / "bench_only_modules.txt"
DIAGNOSTIC_ONLY = RTL_DIR / "diagnostic_only_modules.txt"
PRODUCT_ROOT = "emu"


@dataclass(frozen=True)
class ModuleDef:
    name: str
    path: Path
    body: str


def fail(msg: str) -> None:
    print(f"RTL_MODULE_INSTANTIATION_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def git_files(*roots: str) -> list[Path]:
    try:
        out = subprocess.check_output(
            ["git", "ls-files", "--", *roots],
            cwd=ROOT,
            text=True,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        fail(f"could not enumerate tracked RTL files: {exc}")
    # `git ls-files` emits an unmerged path once per stage (1/2/3), so a tree
    # sitting on an unresolved merge would hand the same file to the parser
    # several times and be reported as a duplicate module definition.
    seen: set[str] = set()
    ordered: list[Path] = []
    for line in out.splitlines():
        if not line.endswith((".sv", ".v")) or line in seen:
            continue
        seen.add(line)
        ordered.append(ROOT / line)
    return ordered


def strip_comments(text: str) -> str:
    out: list[str] = []
    i = 0
    in_string = False
    while i < len(text):
        c = text[i]
        n = text[i + 1] if i + 1 < len(text) else ""
        if in_string:
            out.append(c)
            if c == "\\" and n:
                out.append(n)
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
        elif c == '"':
            in_string = True
            out.append(c)
            i += 1
        elif c == "/" and n == "/":
            while i < len(text) and text[i] != "\n":
                i += 1
            out.append("\n")
        elif c == "/" and n == "*":
            i += 2
            while i + 1 < len(text) and not (text[i] == "*" and text[i + 1] == "/"):
                if text[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def parse_modules(paths: list[Path]) -> dict[str, ModuleDef]:
    modules: dict[str, ModuleDef] = {}
    for path in paths:
        text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        for match in re.finditer(r"\bmodule\s+([A-Za-z_]\w*)\b(?P<body>.*?)\bendmodule\b", text, re.S):
            name = match.group(1)
            if name in modules:
                other = modules[name].path.relative_to(ROOT)
                fail(f"duplicate module {name}: {other} and {path.relative_to(ROOT)}")
            modules[name] = ModuleDef(name, path, match.group("body"))
    return modules


def parse_bench_only() -> dict[str, str]:
    if not BENCH_ONLY.exists():
        fail(f"missing explicit bench-only list {BENCH_ONLY.relative_to(ROOT)}")
    entries: dict[str, str] = {}
    for lineno, raw in enumerate(BENCH_ONLY.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            fail(f"{BENCH_ONLY.relative_to(ROOT)}:{lineno}: expected 'module: reason'")
        name, reason = [part.strip() for part in line.split(":", 1)]
        if not re.fullmatch(r"[A-Za-z_]\w*", name):
            fail(f"{BENCH_ONLY.relative_to(ROOT)}:{lineno}: invalid module name {name!r}")
        if len(reason) < 12:
            fail(f"{BENCH_ONLY.relative_to(ROOT)}:{lineno}: bench-only reason is too vague")
        if name in entries:
            fail(f"{BENCH_ONLY.relative_to(ROOT)}:{lineno}: duplicate bench-only module {name}")
        entries[name] = reason
    return entries


def parse_diagnostic_only() -> tuple[dict[str, str], dict[str, str]]:
    """Parse the diagnostic-root / diagnostic-debt declaration file.

    Returns (roots, debt) as {module: reason}.  Diagnostic roots are pruned
    before product reachability is computed so that a diagnostic subtree can
    never satisfy a product reachability requirement.
    """
    if not DIAGNOSTIC_ONLY.exists():
        fail(f"missing explicit diagnostic-only list {DIAGNOSTIC_ONLY.relative_to(ROOT)}")
    sections: dict[str, dict[str, str]] = {"roots": {}, "debt": {}}
    current: str | None = None
    for lineno, raw in enumerate(DIAGNOSTIC_ONLY.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip()
            if current not in sections:
                fail(f"{DIAGNOSTIC_ONLY.relative_to(ROOT)}:{lineno}: unknown section {current!r}")
            continue
        if current is None:
            fail(f"{DIAGNOSTIC_ONLY.relative_to(ROOT)}:{lineno}: entry before any [section]")
        if ":" not in line:
            fail(f"{DIAGNOSTIC_ONLY.relative_to(ROOT)}:{lineno}: expected 'module: reason'")
        name, reason = [part.strip() for part in line.split(":", 1)]
        if not re.fullmatch(r"[A-Za-z_]\w*", name):
            fail(f"{DIAGNOSTIC_ONLY.relative_to(ROOT)}:{lineno}: invalid module name {name!r}")
        if len(reason) < 12:
            fail(f"{DIAGNOSTIC_ONLY.relative_to(ROOT)}:{lineno}: diagnostic reason is too vague")
        if name in sections[current]:
            fail(f"{DIAGNOSTIC_ONLY.relative_to(ROOT)}:{lineno}: duplicate entry {name}")
        sections[current][name] = reason
    if not sections["roots"]:
        fail(
            f"{DIAGNOSTIC_ONLY.relative_to(ROOT)}: [roots] is empty; delete the file only "
            "when no diagnostic subtree remains in the product hierarchy"
        )
    return sections["roots"], sections["debt"]


def instantiation_graph(modules: dict[str, ModuleDef]) -> dict[str, set[str]]:
    graph: dict[str, set[str]] = {name: set() for name in modules}
    known = sorted(modules, key=len, reverse=True)
    for owner, mod in modules.items():
        body = mod.body
        for candidate in known:
            if candidate == owner:
                continue
            pattern = (
                r"\b"
                + re.escape(candidate)
                + r"\s*(?:#\s*\(.*?\)\s*)?[A-Za-z_]\w*(?:\s*\[[^\]]+\])?\s*\("
            )
            if re.search(pattern, body, re.S):
                graph[owner].add(candidate)
    return graph


def reachable_from(root: str, graph: dict[str, set[str]]) -> set[str]:
    if root not in graph:
        fail(f"product root module {root!r} not parsed from {PRODUCT_TOP.relative_to(ROOT)}")
    seen: set[str] = set()
    stack = [root]
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        stack.extend(sorted(graph.get(name, set()) - seen))
    return seen


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--root",
        default=PRODUCT_ROOT,
        help="Root module for reachability analysis (default: emu).",
    )
    ap.add_argument(
        "--require",
        action="append",
        default=[],
        help="Require a specific RTL module to be product-reachable from the product root.",
    )
    args = ap.parse_args(argv)

    rtl_paths = git_files("fpga/Plex_MiSTer/rtl")
    paths = rtl_paths + [PRODUCT_TOP]
    modules = parse_modules(paths)
    bench_only = parse_bench_only()
    diag_roots, diag_debt = parse_diagnostic_only()
    graph = instantiation_graph(modules)
    if args.root not in modules:
        fail(f"root module does not exist: {args.root}")
    reachable = reachable_from(args.root, graph)

    unknown_diag = sorted((set(diag_roots) | set(diag_debt)) - set(modules))
    if unknown_diag:
        fail(
            f"{DIAGNOSTIC_ONLY.relative_to(ROOT)} names modules that do not exist: "
            + ", ".join(unknown_diag)
        )
    overlap = sorted(set(diag_debt) & set(bench_only))
    if overlap:
        fail(
            "modules cannot be both bench-only and diagnostic debt: " + ", ".join(overlap)
        )

    # Product reachability deliberately prunes diagnostic subtrees.  A module
    # that is only reachable through decode_stub is NOT product reachable, and
    # --require is answered from this pruned view so a diagnostic painter can
    # never manufacture a product green.
    product_graph = {name: (set() if name in diag_roots else dsts) for name, dsts in graph.items()}
    product_reachable = reachable_from(args.root, product_graph) - set(diag_roots)
    measured_debt = sorted(reachable - product_reachable - set(diag_roots))

    rtl_modules = {
        name: mod
        for name, mod in modules.items()
        if RTL_DIR in mod.path.parents or mod.path == RTL_DIR
    }
    unknown_bench = sorted(set(bench_only) - set(rtl_modules))
    if unknown_bench:
        fail("bench-only list names modules that do not exist: " + ", ".join(unknown_bench))

    if args.root == PRODUCT_ROOT:
        missing_roots = sorted(name for name in diag_roots if name not in reachable)
        if missing_roots:
            fail(
                "diagnostic roots are no longer instantiated in the product hierarchy; "
                f"delete them from {DIAGNOSTIC_ONLY.relative_to(ROOT)}: " + ", ".join(missing_roots)
            )
        declared_debt = sorted(diag_debt)
        if measured_debt != declared_debt:
            for name in sorted(set(measured_debt) - set(declared_debt)):
                print(
                    f"UNDECLARED_DIAGNOSTIC_ONLY_MODULE {name} "
                    f"file={modules[name].path.relative_to(ROOT)}",
                    file=sys.stderr,
                )
            for name in sorted(set(declared_debt) - set(measured_debt)):
                print(
                    f"STALE_DIAGNOSTIC_DEBT_ENTRY {name} is now product-reachable; "
                    f"remove it from {DIAGNOSTIC_ONLY.relative_to(ROOT)}",
                    file=sys.stderr,
                )
            fail(
                "diagnostic-only module set does not match "
                f"{DIAGNOSTIC_ONLY.relative_to(ROOT)} [debt]"
            )

        reachable_bench = sorted(name for name in bench_only if name in reachable)
        if reachable_bench:
            fail(
                "bench-only modules are now reachable from product root; remove the declaration: "
                + ", ".join(reachable_bench)
            )

        missing = sorted(name for name in rtl_modules if name not in reachable and name not in bench_only)
        if missing:
            for name in missing:
                mod = rtl_modules[name]
                parents = sorted(src for src, dsts in graph.items() if name in dsts)
                parent_note = f" parents={','.join(parents)}" if parents else " parents=<none>"
                print(
                    f"UNINSTANTIATED_RTL_MODULE {name} file={mod.path.relative_to(ROOT)}{parent_note}",
                    file=sys.stderr,
                )
            fail(
                "RTL modules must be product-reachable from emu or explicitly listed in "
                f"{BENCH_ONLY.relative_to(ROOT)}"
            )

    unknown_required = sorted(set(args.require) - set(rtl_modules))
    if unknown_required:
        fail("required RTL modules do not exist: " + ", ".join(unknown_required))

    unreachable_required = sorted(name for name in args.require if name not in product_reachable)
    if unreachable_required:
        for name in unreachable_required:
            mod = rtl_modules[name]
            parents = sorted(src for src, dsts in graph.items() if name in dsts)
            parent_note = f" parents={','.join(parents)}" if parents else " parents=<none>"
            diag_note = " reachable_only_via_diagnostic_root=1" if name in reachable else ""
            print(
                f"REQUIRED_RTL_MODULE_UNREACHABLE {name} file={mod.path.relative_to(ROOT)}"
                f"{parent_note}{diag_note}",
                file=sys.stderr,
            )
        fail(
            f"required RTL modules are not product-reachable from {args.root} "
            f"(diagnostic subtrees pruned: {','.join(sorted(diag_roots))})"
        )

    for name in args.require:
        print(f"REQUIRED_RTL_MODULE_REACHABLE {name} root={args.root}")

    print(
        "RTL_MODULE_INSTANTIATION_OK "
        f"rtl_modules={len(rtl_modules)} reachable={sum(1 for n in rtl_modules if n in reachable)} "
        f"product_reachable={sum(1 for n in rtl_modules if n in product_reachable)} "
        f"diagnostic_roots={len(diag_roots)} diagnostic_debt={len(measured_debt)} "
        f"bench_only={len(bench_only)} root={args.root}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
