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
PRODUCT_ROOT = "emu"
REQUIRED_PRODUCT_REACHABLE = {
    "h264_decode_core",
    "h264_cavlc_residual_block",
    "h264_luma4x4_residual_source",
    "h264_intra4x4_mode_deriver",
}
REQUIRED_PRODUCT_EDGES = {
    ("stream_path", "h264_decode_core"),
    ("h264_decode_core", "h264_cavlc_residual_block"),
    ("h264_decode_core", "h264_luma4x4_residual_source"),
    ("h264_decode_core", "h264_intra4x4_mode_deriver"),
}


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
    return [ROOT / line for line in out.splitlines() if line.endswith((".sv", ".v"))]


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
    ap.add_argument("--root", default=PRODUCT_ROOT,
                    help=f"root module for reachability analysis (default: {PRODUCT_ROOT})")
    ap.add_argument("--require", action="append", default=[], metavar="MODULE",
                    help="require MODULE to be reachable from --root; repeatable")
    args = ap.parse_args(argv)
    root = args.root

    print(
        "Scope: all tracked fpga/Plex_MiSTer/rtl modules must be reachable from "
        f"product root {PRODUCT_ROOT}, unless explicitly bench-only; "
        "h264_decode_core is the product decoder and CAVLC/intra4x4 producers "
        "must sit under that core, not a standalone parser branch."
        + (f" Additionally requiring {', '.join(sorted(args.require))} reachable from {root}."
           if args.require else ""),
        flush=True,
    )
    rtl_paths = git_files("fpga/Plex_MiSTer/rtl")
    paths = rtl_paths + [PRODUCT_TOP]
    modules = parse_modules(paths)
    bench_only = parse_bench_only()
    graph = instantiation_graph(modules)
    if root not in modules:
        fail(f"root module does not exist: {root}")
    reachable = reachable_from(root, graph)
    product_reachable = reachable if root == PRODUCT_ROOT else reachable_from(PRODUCT_ROOT, graph)

    rtl_modules = {
        name: mod
        for name, mod in modules.items()
        if RTL_DIR in mod.path.parents or mod.path == RTL_DIR
    }
    unknown_bench = sorted(set(bench_only) - set(rtl_modules))
    if unknown_bench:
        fail("bench-only list names modules that do not exist: " + ", ".join(unknown_bench))

    reachable_bench = sorted(name for name in bench_only if name in product_reachable)
    if reachable_bench:
        fail(
            "bench-only modules are now reachable from product root; remove the declaration: "
            + ", ".join(reachable_bench)
        )

    missing_required = sorted(name for name in REQUIRED_PRODUCT_REACHABLE if name not in product_reachable)
    if missing_required:
        fail(
            "required product modules are not reachable from "
            f"{PRODUCT_ROOT}: " + ", ".join(missing_required)
        )

    missing_edges = sorted((src, dst) for src, dst in REQUIRED_PRODUCT_EDGES if dst not in graph.get(src, set()))
    if missing_edges:
        fail(
            "required product topology edge(s) missing: "
            + ", ".join(f"{src}->{dst}" for src, dst in missing_edges)
        )

    missing = sorted(name for name in rtl_modules if name not in product_reachable and name not in bench_only)
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

    unreachable_required = sorted(name for name in args.require if name not in reachable)
    if unreachable_required:
        fail(f"required RTL modules are not reachable from {root}: " + ", ".join(unreachable_required))

    for name in sorted(args.require):
        print(f"REQUIRED_RTL_MODULE_REACHABLE {name} root={root}")

    print(
        "RTL_MODULE_INSTANTIATION_OK "
        f"rtl_modules={len(rtl_modules)} reachable={sum(1 for n in rtl_modules if n in product_reachable)} "
        f"bench_only={len(bench_only)} root={root}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
