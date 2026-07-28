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

# A Verilog instance name is either a simple identifier or an escaped identifier:
# a backslash followed by non-whitespace characters and terminated by whitespace.
# w-audit mutation 2026-07-28: `h264_inter_mc_part \\w_audit.escaped_inst ();` is
# legal and was reported unreachable.
INSTANCE_NAME = r"(?:[A-Za-z_]\w*|\\\S+\s)"

# Retired lineages that must never launder a product path.
MASKING_LINEAGES = ("decode_stub",)
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


def _constant_truth(expr: str) -> int | None:
    """Return 1/0 if ``expr`` is an unambiguous integer literal, else None.

    Only literals are folded. Parameters and real expressions are left alone, so
    the parser stays biased toward reporting a module reachable rather than
    silently dropping a live instantiation.
    """
    text = expr.strip()
    while text.startswith("(") and text.endswith(")"):
        text = text[1:-1].strip()
    if not text:
        return None
    sized = re.fullmatch(r"(\d+)?'[sS]?([bBoOdDhH])([0-9a-fA-F_]+)", text)
    if sized:
        base = {"b": 2, "o": 8, "d": 10, "h": 16}[sized.group(2).lower()]
        digits = sized.group(3).replace("_", "")
        try:
            return 1 if int(digits, base) else 0
        except ValueError:
            return None
    if re.fullmatch(r"\d[\d_]*", text):
        return 1 if int(text.replace("_", "")) else 0
    return None


def select_constant_generate_ifs(text: str) -> str:
    """Eliminate ``if (<literal>)`` generate branches.

    w-audit mutation, 2026-07-28: `if (0) begin h264_inter_mc_part u_false(); end`
    injected under h264_decode_core made the module report as reachable. Quartus
    elaborates the branch away; the gate must too.
    """
    pattern = re.compile(
        r"\bif\s*\(([^()`]*)\)\s*begin\b(?:\s*:\s*[A-Za-z_]\w*)?",
        re.S,
    )
    out: list[str] = []
    pos = 0
    changed = False
    while True:
        match = pattern.search(text, pos)
        if not match:
            out.append(text[pos:])
            break
        truth = _constant_truth(match.group(1))
        if truth is None:
            out.append(text[pos : match.end()])
            pos = match.end()
            continue
        out.append(text[pos : match.start()])
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
        out.append(text[true_body_start:true_end_start] if truth else else_body)
        pos = branch_after
        changed = True
    selected = "".join(out)
    if changed and pattern.search(selected):
        return select_constant_generate_ifs(selected)
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
        text = select_constant_generate_ifs(text)
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
                + r"\s*(?:#\s*\(.*?\)\s*)?"
                + INSTANCE_NAME
                + r"(?:\s*\[[^\]]+\])?\s*\("
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


def tracked_qip_sources() -> set[Path]:
    """Every RTL/HDL source file referenced by any tracked .qip in the project."""
    out: set[Path] = set()
    try:
        listing = subprocess.check_output(
            ["git", "ls-files", "--", "fpga/Plex_MiSTer"],
            cwd=ROOT,
            text=True,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        fail(f"could not enumerate tracked Quartus IP files: {exc}")
    for rel in listing.splitlines():
        if not rel.endswith(".qip"):
            continue
        qip = ROOT / rel
        base = qip.parent
        for raw in qip.read_text(encoding="utf-8", errors="ignore").splitlines():
            # Quartus TCL comments start with '#'. A commented-out assignment does
            # not compile anything, so it must not count as coverage.
            line = raw.split("#", 1)[0]
            if "set_global_assignment" not in line:
                continue
            for token in re.findall(r"[\w./\\-]+\.s?v\b", line):
                out.add((base / token.replace("\\", "/")).resolve())
    return out


def qip_membership_gaps(
    modules: dict[str, ModuleDef], reachable: set[str]
) -> list[tuple[str, str]]:
    """Product-reachable modules whose source file no tracked .qip compiles.

    Source-graph reachability proves a module is instantiated.  It does not prove
    Quartus ever reads the file: a module can be instantiated from the product
    root and still be missing from files.qip, in which case it is absent from the
    bitstream no matter how green the instantiation gate is.
    """
    compiled = tracked_qip_sources()
    gaps: list[tuple[str, str]] = []
    for name in sorted(reachable):
        mod = modules.get(name)
        if mod is None:
            continue
        path = mod.path.resolve()
        if path == PRODUCT_TOP.resolve() or path in compiled:
            continue
        gaps.append((name, str(path.relative_to(ROOT))))
    return gaps


def build_reachable(paths: list[Path], macro_overrides: dict[str, int | None] | None = None) -> tuple[dict[str, ModuleDef], dict[str, set[str]], set[str]]:
    modules = parse_modules(paths, macro_overrides)
    graph = instantiation_graph(modules)
    return modules, graph, reachable_from(PRODUCT_ROOT, graph)


def instantiating_parents(child: str, graph: dict[str, set[str]]) -> list[str]:
    return sorted(parent for parent, kids in graph.items() if child in kids)


def instantiation_path(root: str, target: str, graph: dict[str, set[str]]) -> list[str] | None:
    """Shortest instantiation path root -> ... -> target, or None."""
    if root == target:
        return [root]
    seen = {root}
    queue: list[list[str]] = [[root]]
    while queue:
        path = queue.pop(0)
        for child in sorted(graph.get(path[-1], set())):
            if child in seen:
                continue
            if child == target:
                return path + [child]
            seen.add(child)
            queue.append(path + [child])
    return None


def check_required_modules(
    required: list[str],
    root: str,
    graph: dict[str, set[str]],
    modules: dict[str, ModuleDef],
    product_reachable: set[str],
    allow_non_product_root: bool,
) -> None:
    """Evaluate --require, refusing to dress a subtree claim up as product evidence."""
    if root not in modules:
        fail(f"--root names a module that does not exist: {root}")

    root_is_product = root == PRODUCT_ROOT or root in product_reachable
    trunk = instantiation_path(PRODUCT_ROOT, root, graph) if root_is_product else None
    if trunk is not None:
        masked = [lineage for lineage in MASKING_LINEAGES if lineage in trunk]
        print(
            "TRUNK_PROOF %s path=%s hops=%d via_masking_lineage=%s"
            % (
                root,
                "->".join(trunk),
                len(trunk) - 1,
                ",".join(masked) if masked else "no",
            )
        )
        if masked:
            fail(
                f"the only product path to --root {root} runs through the retired masking lineage "
                + ",".join(masked)
                + "; that is not a product decode path"
            )
    if not root_is_product:
        parents = instantiating_parents(root, graph)
        detail = ",".join(parents) if parents else "<none>"
        print(
            f"NON_PRODUCT_ROOT {root} product_reachable=no instantiating_parents={detail}",
            file=sys.stderr,
        )
        if not allow_non_product_root:
            fail(
                f"--root {root} is not reachable from the product root {PRODUCT_ROOT}; a requirement "
                "proved from it is a subtree claim, not product presence. Wire the root into the "
                "product or pass --allow-non-product-root and report it as SUBTREE_ONLY_CLAIM."
            )

    if not required:
        return

    reachable = reachable_from(root, graph) if root in graph else {root}
    missing = [name for name in required if name not in modules]
    if missing:
        fail("--require names modules that do not exist: " + ", ".join(sorted(missing)))

    unreachable = [name for name in required if name not in reachable]
    for name in unreachable:
        parents = instantiating_parents(name, graph)
        detail = ",".join(parents) if parents else "<none>"
        print(
            f"REQUIRED_RTL_MODULE_UNREACHABLE {name} root={root} instantiating_parents={detail}",
            file=sys.stderr,
        )
    if unreachable:
        fail(f"required RTL modules are not reachable from {root}: " + ", ".join(sorted(unreachable)))

    # A required module that Quartus never compiles is absent from the bitstream
    # however green the graph is. This runs at every root, not only the product root.
    compiled = tracked_qip_sources()
    uncompiled = []
    for name in required:
        mod = modules.get(name)
        if mod is None:
            continue
        path = mod.path.resolve()
        if path == PRODUCT_TOP.resolve() or path in compiled:
            continue
        uncompiled.append((name, str(path.relative_to(ROOT))))
    for name, rel in uncompiled:
        print(f"REQUIRED_RTL_MODULE_NOT_COMPILED {name} file={rel}", file=sys.stderr)
    if uncompiled:
        fail(
            "required RTL modules are in no tracked .qip, so Quartus never compiles them: "
            + ", ".join(name for name, _ in uncompiled)
        )

    label = "REQUIRED_RTL_MODULE_PRODUCT_REACHABLE" if root_is_product else "SUBTREE_ONLY_CLAIM"
    for name in required:
        print(f"{label} {name} root={root} product_reachable={'yes' if root_is_product else 'no'}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--define", action="append", default=[], help="Override a Verilog macro for reachability reporting, e.g. DECODE_REAL_INTRA=1")
    ap.add_argument("--list-reachable", action="store_true", help="Print modules reachable under the requested --define configuration")
    ap.add_argument(
        "--root",
        default=PRODUCT_ROOT,
        help=(
            f"Root module for --require queries. Defaults to the product root {PRODUCT_ROOT!r}. "
            "Any other root only proves subtree containment, never product presence."
        ),
    )
    ap.add_argument(
        "--require",
        action="append",
        default=[],
        metavar="MODULE",
        help=(
            "Require MODULE to be reachable from --root. With the product root this is a "
            "product-presence claim; with any other root it is only a subtree claim and the root "
            "must itself be product-reachable, or --allow-non-product-root must be passed."
        ),
    )
    ap.add_argument(
        "--allow-non-product-root",
        action="store_true",
        help=(
            "Permit --root to name a module that is not product-reachable. Results are then "
            "labelled SUBTREE_ONLY_CLAIM and must never be reported as product evidence."
        ),
    )
    args = ap.parse_args(argv)

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

    print(
        "Scope: rtl_files=%d rtl_modules=%d product_root=%s query_root=%s requires=%d"
        % (len(rtl_paths), len(rtl_modules), PRODUCT_ROOT, args.root, len(args.require)),
        flush=True,
    )
    if not rtl_modules:
        fail("Scope: 0 RTL modules parsed; the gate cannot claim a PASS over an empty set")

    check_required_modules(
        args.require,
        args.root,
        default_graph,
        default_modules,
        default_reachable,
        args.allow_non_product_root,
    )

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

    qip_missing = qip_membership_gaps(default_modules, default_reachable)
    for name, rel in qip_missing:
        print(f"REACHABLE_MODULE_NOT_COMPILED {name} file={rel}", file=sys.stderr)
    if qip_missing:
        fail(
            "product-reachable modules whose source file is in no tracked .qip are absent from the "
            "Quartus compile and therefore from the bitstream: "
            + ", ".join(name for name, _ in qip_missing)
        )

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
