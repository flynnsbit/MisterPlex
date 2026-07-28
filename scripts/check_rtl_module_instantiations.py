#!/usr/bin/env python3
"""Gate that every RTL module is product-reachable, default-off, or bench-only.

The check is intentionally source-graph based.  It parses every module under
fpga/Plex_MiSTer/rtl plus the product Plex.sv top, follows known-module
instantiations from emu, then requires all rtl/ module declarations to be either:

* product-reachable under checked-in default macros;
* NONDEFAULT_CONFIG_REACHABLE: reachable only when checked-in product macros
  differ from the QSF defaults, with an explicit reason in
  rtl/nondefault_config_modules.txt; or
* DEFAULT_OFF_DEFINE_DROPS_*: default-reachable modules lost when a
  product-default-off define is flipped on, classified in
  rtl/default_off_drop_modules.txt; or
* bench-only, with an explicit reason in rtl/bench_only_modules.txt.
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
PRODUCT_QSF = ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf"
BENCH_ONLY = RTL_DIR / "bench_only_modules.txt"
NONDEFAULT_CONFIG = RTL_DIR / "nondefault_config_modules.txt"
DEFAULT_OFF_DROPS = RTL_DIR / "default_off_drop_modules.txt"
PRODUCT_ROOT = "emu"
DROP_CATEGORIES = {"stub-only", "real-decode-bypass"}


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


def eval_condition(expr: str, macros: dict[str, int]) -> bool:
    expr = expr.strip()
    if expr.startswith("`"):
        return bool(macros.get(expr[1:].strip(), 0))
    if expr in {"", "0"}:
        return False
    if expr == "1":
        return True
    m = re.fullmatch(r"defined\s*\(?\s*`?([A-Za-z_]\w*)\s*\)?", expr)
    if m:
        return m.group(1) in macros
    m = re.fullmatch(r"`?([A-Za-z_]\w*)", expr)
    if m:
        return bool(macros.get(m.group(1), 0))
    return False


def preprocess_lines(text: str, macros: dict[str, int]) -> str:
    out: list[str] = []
    stack: list[dict[str, bool]] = []

    def active() -> bool:
        return all(frame["current"] for frame in stack)

    def begin(cond: bool) -> None:
        parent = active()
        stack.append({"parent": parent, "current": parent and cond, "seen": cond})

    def alternate(cond: bool) -> None:
        if not stack:
            return
        frame = stack[-1]
        take = frame["parent"] and not frame["seen"] and cond
        frame["current"] = take
        frame["seen"] = frame["seen"] or cond

    for raw in text.splitlines(keepends=True):
        directive = re.match(r"\s*`(ifdef|ifndef|if|elsif|else|endif|define)\b\s*(.*)", raw)
        if directive:
            op, rest = directive.group(1), directive.group(2).strip()
            if op == "ifdef":
                begin(rest.split()[0] in macros if rest.split() else False)
            elif op == "ifndef":
                begin(rest.split()[0] not in macros if rest.split() else False)
            elif op == "if":
                begin(eval_condition(rest, macros))
            elif op == "elsif":
                alternate(eval_condition(rest, macros))
            elif op == "else":
                alternate(True)
            elif op == "endif":
                if stack:
                    stack.pop()
            elif op == "define" and active():
                parts = rest.split(None, 1)
                if parts:
                    value_text = parts[1].strip() if len(parts) > 1 else "1"
                    try:
                        value = int(value_text, 0)
                    except ValueError:
                        value = 1 if value_text else 0
                    macros[parts[0]] = value
            out.append("\n" if raw.endswith("\n") else "")
            continue
        if active():
            out.append(raw)
        else:
            out.append("\n" if raw.endswith("\n") else "")
    return "".join(out)


def matching_end(text: str, begin_token_end: int) -> tuple[int, int]:
    depth = 1
    for token in re.finditer(r"\bbegin\b|\bend\b", text[begin_token_end:]):
        word = token.group(0)
        start = begin_token_end + token.start()
        end = begin_token_end + token.end()
        if word == "begin":
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return start, end
    fail("could not match generate begin/end while selecting macro-controlled branch")


def select_generate_macro_ifs(text: str, macros: dict[str, int]) -> str:
    pattern = re.compile(
        r"\bif\s*\(\s*`([A-Za-z_]\w*)\s*\)\s*begin\b(?:\s*:\s*[A-Za-z_]\w*)?",
        re.S,
    )
    out: list[str] = []
    pos = 0
    while True:
        match = pattern.search(text, pos)
        if not match:
            out.append(text[pos:])
            break
        out.append(text[pos : match.start()])
        macro = match.group(1)
        true_body_start = match.end()
        true_end_start, true_end_after = matching_end(text, true_body_start)
        else_match = re.match(
            r"\s*else\s+begin\b(?:\s*:\s*[A-Za-z_]\w*)?",
            text[true_end_after:],
            re.S,
        )
        else_body = ""
        branch_after = true_end_after
        if else_match:
            else_body_start = true_end_after + else_match.end()
            else_end_start, else_end_after = matching_end(text, else_body_start)
            else_body = text[else_body_start:else_end_start]
            branch_after = else_end_after
        chosen = text[true_body_start:true_end_start] if macros.get(macro, 0) else else_body
        out.append(chosen)
        pos = branch_after
    selected = "".join(out)
    if pattern.search(selected):
        return select_generate_macro_ifs(selected, macros)
    return selected


def qsf_macros() -> dict[str, int]:
    macros: dict[str, int] = {}
    text = PRODUCT_QSF.read_text(encoding="utf-8", errors="ignore")
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = re.search(r'\bVERILOG_MACRO\s+"([A-Za-z_]\w*)(?:=([^"]+))?"', stripped)
        if not m:
            continue
        value_text = m.group(2) or "1"
        try:
            value = int(value_text, 0)
        except ValueError:
            value = 1
        macros[m.group(1)] = value
    return macros


def apply_macro_overrides(macros: dict[str, int], overrides: dict[str, int | None]) -> dict[str, int]:
    out = dict(macros)
    for name, value in overrides.items():
        if value is None:
            out.pop(name, None)
        else:
            out[name] = value
    return out


def parse_modules(paths: list[Path], macro_overrides: dict[str, int | None] | None = None) -> dict[str, ModuleDef]:
    modules: dict[str, ModuleDef] = {}
    base_macros = apply_macro_overrides(qsf_macros(), macro_overrides or {})
    for path in paths:
        macros = dict(base_macros)
        text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        text = preprocess_lines(text, macros)
        text = select_generate_macro_ifs(text, macros)
        for match in re.finditer(r"\bmodule\s+([A-Za-z_]\w*)\b(?P<body>.*?)\bendmodule\b", text, re.S):
            name = match.group(1)
            if name in modules:
                other = modules[name].path.relative_to(ROOT)
                fail(f"duplicate module {name}: {other} and {path.relative_to(ROOT)}")
            modules[name] = ModuleDef(name, path, match.group("body"))
    return modules


def parse_reason_file(path: Path, label: str) -> dict[str, str]:
    if not path.exists():
        fail(f"missing explicit {label} list {path.relative_to(ROOT)}")
    entries: dict[str, str] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            fail(f"{path.relative_to(ROOT)}:{lineno}: expected 'module: reason'")
        name, reason = [part.strip() for part in line.split(":", 1)]
        if not re.fullmatch(r"[A-Za-z_]\w*", name):
            fail(f"{path.relative_to(ROOT)}:{lineno}: invalid module name {name!r}")
        if len(reason) < 12:
            fail(f"{path.relative_to(ROOT)}:{lineno}: {label} reason is too vague")
        if name in entries:
            fail(f"{path.relative_to(ROOT)}:{lineno}: duplicate {label} module {name}")
        entries[name] = reason
    return entries


def parse_drop_file() -> dict[str, tuple[str, str]]:
    if not DEFAULT_OFF_DROPS.exists():
        fail(f"missing explicit default-off drop list {DEFAULT_OFF_DROPS.relative_to(ROOT)}")
    entries: dict[str, tuple[str, str]] = {}
    for lineno, raw in enumerate(DEFAULT_OFF_DROPS.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split(":", 2)]
        if len(parts) != 3:
            fail(f"{DEFAULT_OFF_DROPS.relative_to(ROOT)}:{lineno}: expected 'module: category: reason'")
        name, category, reason = parts
        if not re.fullmatch(r"[A-Za-z_]\w*", name):
            fail(f"{DEFAULT_OFF_DROPS.relative_to(ROOT)}:{lineno}: invalid module name {name!r}")
        if category not in DROP_CATEGORIES:
            fail(
                f"{DEFAULT_OFF_DROPS.relative_to(ROOT)}:{lineno}: invalid category {category!r}; "
                f"expected one of {sorted(DROP_CATEGORIES)}"
            )
        if len(reason) < 12:
            fail(f"{DEFAULT_OFF_DROPS.relative_to(ROOT)}:{lineno}: drop reason is too vague")
        if name in entries:
            fail(f"{DEFAULT_OFF_DROPS.relative_to(ROOT)}:{lineno}: duplicate default-off drop module {name}")
        entries[name] = (category, reason)
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


def nondefault_variants(paths: list[Path]) -> list[tuple[str, int | None, int | None]]:
    qsf = qsf_macros()
    variants: list[tuple[str, int | None, int | None]] = []
    for name, value in sorted(qsf.items()):
        if value == 0:
            variants.append((name, value, 1))
        elif value == 1:
            variants.append((name, value, None))
    found: set[str] = set()
    pattern = re.compile(r"`ifndef\s+([A-Za-z_]\w*)\s*\n\s*`define\s+\1\s+0\b", re.M)
    for path in paths:
        text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        found.update(pattern.findall(text))
    for name in sorted(found - set(qsf)):
        variants.append((name, 0, 1))
    return variants


def parse_define_args(items: list[str]) -> dict[str, int | None]:
    out: dict[str, int | None] = {}
    for item in items:
        if "=" in item:
            name, value_text = item.split("=", 1)
        else:
            name, value_text = item, "1"
        if not re.fullmatch(r"[A-Za-z_]\w*", name):
            fail(f"invalid --define name {name!r}")
        try:
            value = int(value_text, 0)
        except ValueError as exc:
            fail(f"invalid --define value {item!r}: {exc}")
        out[name] = value
    return out


def build_reachable(paths: list[Path], macro_overrides: dict[str, int | None] | None = None) -> tuple[dict[str, ModuleDef], dict[str, set[str]], set[str]]:
    modules = parse_modules(paths, macro_overrides)
    graph = instantiation_graph(modules)
    return modules, graph, reachable_from(PRODUCT_ROOT, graph)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--define", action="append", default=[], help="Override a Verilog macro for reachability reporting, e.g. DECODE_REAL_INTRA=1")
    ap.add_argument("--list-reachable", action="store_true", help="Print modules reachable under the requested --define configuration")
    args = ap.parse_args(argv)
    print(
        "Scope: RTL source instantiation reachability from product root emu under QSF/default "
        "macros and requested --define overrides. It classifies default-reachable, "
        "DEFAULT_OFF_DEFINE_REACHABLE_MODULE, default-off dropouts, and bench-only RTL. "
        "It does not cover post-fit retention, timing, or functional dataflow.",
        flush=True,
    )

    rtl_paths = git_files("fpga/Plex_MiSTer/rtl")
    paths = rtl_paths + [PRODUCT_TOP]
    default_modules, default_graph, default_reachable = build_reachable(paths)
    bench_only = parse_reason_file(BENCH_ONLY, "bench-only")
    nondefault_declared = parse_reason_file(NONDEFAULT_CONFIG, "NONDEFAULT_CONFIG_REACHABLE")
    drop_declared = parse_drop_file()
    variants = nondefault_variants(paths)
    override_macros = parse_define_args(args.define)
    _, override_graph, override_reachable = build_reachable(paths, override_macros)

    rtl_modules = {
        name: mod
        for name, mod in default_modules.items()
        if RTL_DIR in mod.path.parents or mod.path == RTL_DIR
    }
    rtl_module_names = set(rtl_modules)

    unknown_bench = sorted(set(bench_only) - set(rtl_modules))
    if unknown_bench:
        fail("bench-only list names modules that do not exist: " + ", ".join(unknown_bench))

    unknown_nondefault = sorted(set(nondefault_declared) - set(rtl_modules))
    if unknown_nondefault:
        fail("NONDEFAULT_CONFIG_REACHABLE list names modules that do not exist: " + ", ".join(unknown_nondefault))

    unknown_drops = sorted(set(drop_declared) - set(rtl_modules))
    if unknown_drops:
        fail("default-off drop list names modules that do not exist: " + ", ".join(unknown_drops))

    overlap = sorted(set(bench_only) & set(nondefault_declared))
    if overlap:
        fail("modules cannot be both bench-only and NONDEFAULT_CONFIG_REACHABLE: " + ", ".join(overlap))

    discovered_nondefault: dict[str, list[str]] = {}
    default_value_by_module: dict[str, list[int | None]] = {}
    discovered_drops: dict[str, list[str]] = {}
    for macro, default_value, variant_value in variants:
        _, _, enabled_reachable = build_reachable(paths, {macro: variant_value})
        for name in sorted((enabled_reachable - default_reachable) & rtl_module_names):
            value_text = "<undefined>" if variant_value is None else str(variant_value)
            discovered_nondefault.setdefault(name, []).append(f"{macro}={value_text}")
            default_value_by_module.setdefault(name, []).append(default_value)
        if default_value == 0 and variant_value == 1:
            for name in sorted((default_reachable - enabled_reachable) & rtl_module_names):
                discovered_drops.setdefault(name, []).append(f"{macro}=1")

    reachable_bench = sorted(name for name in bench_only if name in default_reachable)
    if reachable_bench:
        fail(
            "bench-only modules are now reachable from product root; remove the declaration: "
            + ", ".join(reachable_bench)
        )

    reachable_nondefault = sorted(name for name in nondefault_declared if name in default_reachable)
    if reachable_nondefault:
        fail(
            "NONDEFAULT_CONFIG_REACHABLE modules are now default product-reachable; remove the declaration: "
            + ", ".join(reachable_nondefault)
        )

    undisclosed_nondefault = sorted(set(discovered_nondefault) - set(nondefault_declared))
    if undisclosed_nondefault:
        for name in undisclosed_nondefault:
            macros = ",".join(discovered_nondefault[name])
            print(f"NONDEFAULT_CONFIG_REACHABLE_UNDECLARED {name} defines={macros}", file=sys.stderr)
        fail(
            "modules reachable only under non-default product macro configurations must be declared in "
            f"{NONDEFAULT_CONFIG.relative_to(ROOT)}"
        )

    stale_nondefault = sorted(set(nondefault_declared) - set(discovered_nondefault))
    if stale_nondefault:
        fail(
            "NONDEFAULT_CONFIG_REACHABLE declarations are not reachable under any discovered non-default macro configuration: "
            + ", ".join(stale_nondefault)
        )

    undisclosed_drops = sorted(set(discovered_drops) - set(drop_declared))
    if undisclosed_drops:
        for name in undisclosed_drops:
            macros = ",".join(discovered_drops[name])
            print(f"DEFAULT_OFF_DEFINE_DROP_UNDECLARED {name} defines={macros}", file=sys.stderr)
        fail(
            "modules lost when product-default-off defines are enabled must be classified in "
            f"{DEFAULT_OFF_DROPS.relative_to(ROOT)}"
        )

    stale_drops = sorted(set(drop_declared) - set(discovered_drops))
    if stale_drops:
        fail(
            "default-off drop declarations are not dropped by any discovered product-default-off define: "
            + ", ".join(stale_drops)
        )

    missing = sorted(
        name
        for name in rtl_modules
        if name not in default_reachable and name not in bench_only and name not in nondefault_declared
    )
    if missing:
        for name in missing:
            mod = rtl_modules[name]
            parents = sorted(src for src, dsts in default_graph.items() if name in dsts)
            parent_note = f" parents={','.join(parents)}" if parents else " parents=<none>"
            print(
                f"UNINSTANTIATED_RTL_MODULE {name} file={mod.path.relative_to(ROOT)}{parent_note}",
                file=sys.stderr,
            )
        fail(
            "RTL modules must be default product-reachable from emu, NONDEFAULT_CONFIG_REACHABLE, "
            f"or explicitly listed in {BENCH_ONLY.relative_to(ROOT)}"
        )

    for name in sorted(nondefault_declared):
        macros = ",".join(discovered_nondefault[name])
        default_values = set(default_value_by_module.get(name, []))
        if default_values == {0}:
            prefix = "DEFAULT_OFF_DEFINE_REACHABLE_MODULE"
        else:
            prefix = "NONDEFAULT_CONFIG_REACHABLE_MODULE"
        print(f"{prefix} {name} defines={macros}")

    for name in sorted(drop_declared):
        macros = ",".join(discovered_drops[name])
        category, _ = drop_declared[name]
        if category == "stub-only":
            prefix = "DEFAULT_OFF_DEFINE_DROPS_STUB_ONLY_MODULE"
        else:
            prefix = "DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE"
        print(f"{prefix} {name} defines={macros}")

    if args.list_reachable:
        for name in sorted(override_reachable & rtl_module_names):
            print(f"REACHABLE_MODULE {name}")

    variant_summary = ",".join(
        f"{macro}={'<undefined>' if value is None else value}"
        for macro, _, value in variants
    ) if variants else "<none>"

    print(
        "RTL_MODULE_INSTANTIATION_OK "
        f"rtl_modules={len(rtl_modules)} "
        f"default_reachable={sum(1 for n in rtl_modules if n in default_reachable)} "
        f"nondefault_config_reachable={len(nondefault_declared)} "
        f"default_off_dropouts={len(drop_declared)} "
        f"default_off_real_decode_dropouts={sum(1 for v in drop_declared.values() if v[0] == 'real-decode-bypass')} "
        f"bench_only={len(bench_only)} "
        f"config_reachable={sum(1 for n in rtl_modules if n in override_reachable)} "
        f"nondefault_variants={variant_summary} "
        f"root={PRODUCT_ROOT}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
