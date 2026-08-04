#!/usr/bin/env python3
"""Pre-fit reachability gate — critical modules must be in files.qip AND reachable.

Named capability: refuse the exclusive Quartus fit when a product "critical"
module is absent from files.qip or only appears in a pruned subtree.
Historical defect (teeth_non_reachable): h264_cavlc_residual was in files.qip
but its only parent h264_decode_skeleton was not — Quartus compiled CAVLC and
pruned it to zero logic while decode_stub sat in stream_path. That class stays
as teeth until fabric decode is deliberately landed and promoted to critical.

Proves: QIP membership + static instantiation reachability from sys_top/emu.
Does NOT prove: functional correctness, timing, or post-fit area.

Exit codes (soft-skip 77 is NEVER a pass):
  0  all required modules REACHABLE
  1  one or more ABSENT / NOT_IN_QIP / PRUNED / UNKNOWN
  2  bad args / missing project files (cannot determine → fail, not pass)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict, deque
from pathlib import Path

ROOT_DEFAULT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = (
    ROOT_DEFAULT / "tests" / "fixtures" / "critical_prefit_reachability.json"
)

# Strip line comments; keep strings crude (good enough for inst graphs).
_LINE_COMMENT = re.compile(r"//.*?$", re.M)
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_MODULE_DEF = re.compile(r"\bmodule\s+(\w+)\b")
# type #(...) inst (   OR   type inst (
_INST = re.compile(
    r"(?<![\w$])(\w+)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\))?\s+(\w+)\s*\(",
    re.S,
)
_QIP_SV = re.compile(
    r"set_global_assignment\s+-name\s+(?:SYSTEMVERILOG_FILE|VERILOG_FILE)\s+(\S+)",
    re.I,
)


def _strip_comments(text: str) -> str:
    text = _BLOCK_COMMENT.sub(" ", text)
    text = _LINE_COMMENT.sub(" ", text)
    return text


def _read(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def parse_qip_sv_files(qip: Path, plex_dir: Path) -> list[Path]:
    """Active (non-//) SYSTEMVERILOG/VERILOG entries under Plex_MiSTer."""
    raw = _read(qip)
    out: list[Path] = []
    for line in raw.splitlines():
        s = line.strip()
        if not s or s.startswith("//") or s.startswith("#"):
            continue
        m = _QIP_SV.search(s)
        if not m:
            continue
        rel = m.group(1).strip().strip('"')
        # Tcl [file join ...] not used in product files.qip — plain relative paths.
        if rel.startswith("["):
            continue
        p = (plex_dir / rel).resolve()
        out.append(p)
    return out


def extract_modules_and_insts(
    path: Path, text: str
) -> tuple[list[str], list[tuple[str, str]]]:
    """Return (defined_module_names, list of (parent_module, child_type))."""
    body = _strip_comments(text)
    defined = _MODULE_DEF.findall(body)
    if not defined:
        return [], []

    # Split roughly by module boundaries for parent attribution.
    parts = re.split(r"\bmodule\s+", body)
    # parts[0] is preamble; parts[i] starts with name ...
    inst_edges: list[tuple[str, str]] = []
    for part in parts[1:]:
        mname_m = re.match(r"(\w+)\b", part)
        if not mname_m:
            continue
        parent = mname_m.group(1)
        # Drop the module header until first ';' after ports — still OK to scan all.
        for im in _INST.finditer(part):
            typ, inst = im.group(1), im.group(2)
            if typ in {
                "if",
                "for",
                "while",
                "case",
                "casex",
                "casez",
                "function",
                "task",
                "begin",
                "end",
                "else",
                "return",
                "assign",
                "typedef",
                "struct",
                "enum",
                "union",
                "property",
                "assert",
                "assume",
                "cover",
                "generate",
                "genvar",
                "parameter",
                "localparam",
                "input",
                "output",
                "inout",
                "wire",
                "reg",
                "logic",
                "always",
                "always_ff",
                "always_comb",
                "always_latch",
                "initial",
                "final",
                "module",
                "endmodule",
                "interface",
                "modport",
                "package",
                "import",
                "export",
                "typedef",
            }:
                continue
            if typ == parent:
                continue  # not a self-decl
            if inst in {"module", "endmodule"}:
                continue
            # `module foo (` has no instance name — our regex requires inst token.
            inst_edges.append((parent, typ))
    return defined, inst_edges


def build_graph(
    files: list[Path],
) -> tuple[dict[str, Path], dict[str, set[str]], list[str]]:
    """module -> path; parent -> children types; warnings."""
    mod_file: dict[str, Path] = {}
    children: dict[str, set[str]] = defaultdict(set)
    warnings: list[str] = []
    for path in files:
        if not path.is_file():
            warnings.append(f"MISSING_FILE {path}")
            continue
        if path.suffix.lower() not in {".sv", ".v", ".vh"}:
            continue
        text = _read(path)
        defined, edges = extract_modules_and_insts(path, text)
        for d in defined:
            if d in mod_file and mod_file[d] != path:
                warnings.append(f"DUP_MODULE {d} {mod_file[d]} vs {path}")
            mod_file[d] = path
        for parent, child in edges:
            children[parent].add(child)
    return mod_file, children, warnings


def reachable_from(
    roots: list[str], children: dict[str, set[str]], mod_file: dict[str, Path]
) -> set[str]:
    """BFS: only traverse modules that exist in mod_file (design-defined)."""
    seen: set[str] = set()
    q: deque[str] = deque()
    for r in roots:
        if r in mod_file:
            q.append(r)
            seen.add(r)
    while q:
        cur = q.popleft()
        for ch in children.get(cur, ()):
            if ch not in mod_file:
                continue  # primitive / external / unknown — not a design module edge
            if ch in seen:
                continue
            seen.add(ch)
            q.append(ch)
    return seen


def git_ref(root: Path) -> tuple[str, str]:
    import subprocess

    br, sha = "UNKNOWN", "UNKNOWN"
    try:
        b = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--abbrev-ref", "HEAD"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        s = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if b.returncode == 0:
            br = (b.stdout or "").strip() or br
        if s.returncode == 0:
            sha = (s.stdout or "").strip() or sha
    except OSError:
        pass
    return br, sha


def load_config(path: Path) -> dict:
    data = json.loads(path.read_text())
    if "critical_modules" not in data or "expect_reachable" not in data:
        raise ValueError("config needs critical_modules and expect_reachable")
    # teeth_non_reachable optional: historical prune class (must stay non-reachable)
    data.setdefault("teeth_non_reachable", [])
    return data


def run_gate(
    root: Path,
    config: dict,
    *,
    require_critical: bool = True,
) -> tuple[int, list[str]]:
    msgs: list[str] = ["PREFIT_REACHABILITY_EXECUTED begin"]
    br, sha = git_ref(root)
    msgs.append(f"PREFIT_REACHABILITY_REF branch={br} sha={sha} root={root}")

    plex_dir = root / "fpga" / "Plex_MiSTer"
    qip = plex_dir / "files.qip"
    sys_top = plex_dir / "sys" / "sys_top.v"
    if not qip.is_file():
        msgs.append("PREFIT_REACHABILITY_UNKNOWN missing files.qip")
        msgs.append(
            "FAIL PREFIT_REACHABILITY: cannot determine reachability without "
            "files.qip (soft-skip is NOT a pass)"
        )
        return 2, msgs
    if not sys_top.is_file():
        msgs.append("PREFIT_REACHABILITY_UNKNOWN missing sys/sys_top.v")
        msgs.append(
            "FAIL PREFIT_REACHABILITY: cannot determine reachability without "
            "sys_top (TOP_LEVEL_ENTITY)"
        )
        return 2, msgs

    qip_files = parse_qip_sv_files(qip, plex_dir)
    # Design file set: QIP + always sys_top (via sys.qip, not files.qip)
    files = list(dict.fromkeys(qip_files + [sys_top]))
    msgs.append(f"PREFIT_REACHABILITY_FILESET n_qip_sv={len(qip_files)} +sys_top=1")

    mod_file, children, warnings = build_graph(files)
    for w in warnings[:20]:
        msgs.append(f"PREFIT_REACHABILITY_WARN {w}")

    roots = list(config.get("roots") or ["sys_top", "emu"])
    reach = reachable_from(roots, children, mod_file)
    msgs.append(
        f"PREFIT_REACHABILITY_GRAPH modules_defined={len(mod_file)} "
        f"reachable_from_root={len(reach)} roots={roots}"
    )

    qip_basenames = {p.name for p in qip_files}

    def status_for(mod: str) -> tuple[str, str]:
        """Return (STATUS, detail). STATUS in REACHABLE|PRUNED|NOT_IN_QIP|ABSENT."""
        path = mod_file.get(mod)
        defined = mod in mod_file
        # On-disk: defining file or rtl/<mod>.sv
        on_disk = bool(path and path.is_file())
        if not on_disk:
            cand = plex_dir / "rtl" / f"{mod}.sv"
            on_disk = cand.is_file()

        # In QIP: defining file is a QIP entry, OR rtl/<mod>.sv is listed
        # (multi-module files: h264_cavlc_residual.sv defines residual_block).
        in_qip = False
        if path is not None:
            in_qip = any(p.resolve() == path.resolve() for p in qip_files)
        if not in_qip:
            in_qip = any(p.stem == mod or p.name == f"{mod}.sv" for p in qip_files)
        if not in_qip and mod == "emu":
            in_qip = any(p.name == "Plex.sv" for p in qip_files)
        if mod == "sys_top":
            in_qip = True  # via sys/sys.qip, not files.qip

        if not on_disk and not defined:
            return "ABSENT", "no rtl file and not defined in design fileset"

        if not defined:
            # File may exist on disk but not in QIP → Quartus never compiles it
            if not in_qip:
                return (
                    "NOT_IN_QIP",
                    "file/module not in files.qip — Quartus never sees it",
                )
            return "ABSENT", "in QIP path but module name not defined in fileset"

        # Defined in design fileset (file was compiled)
        if mod in reach:
            return "REACHABLE", f"file={mod_file[mod].name}"
        # Compile-then-strip: e.g. cavlc_* only under skeleton not in QIP
        detail = (
            f"defined in {mod_file[mod].name} (in design fileset) but not "
            f"instantiated from root {roots} — Quartus prunes to zero logic"
        )
        if not in_qip and mod not in {"sys_top", "emu"}:
            return "NOT_IN_QIP", detail + " (defining file also outside files.qip)"
        return "PRUNED", detail

    failures: list[str] = []
    critical = list(config.get("critical_modules") or [])
    expect_ok = list(config.get("expect_reachable") or [])

    msgs.append("PREFIT_REACHABILITY_CRITICAL_BEGIN")
    for mod in critical:
        st, detail = status_for(mod)
        line = f"MODULE {mod} STATUS={st} {detail}"
        msgs.append(line)
        if require_critical and st != "REACHABLE":
            failures.append(f"{mod}:{st}")
    msgs.append("PREFIT_REACHABILITY_CRITICAL_END")

    msgs.append("PREFIT_REACHABILITY_EXPECT_OK_BEGIN")
    for mod in expect_ok:
        st, detail = status_for(mod)
        line = f"MODULE {mod} STATUS={st} {detail}"
        msgs.append(line)
        if st != "REACHABLE":
            failures.append(f"expect_ok_{mod}:{st}")
    msgs.append("PREFIT_REACHABILITY_EXPECT_OK_END")

    teeth = list(config.get("teeth_non_reachable") or [])
    msgs.append("PREFIT_REACHABILITY_TEETH_BEGIN")
    teeth_fail: list[str] = []
    for mod in teeth:
        st, detail = status_for(mod)
        line = f"MODULE {mod} STATUS={st} {detail}"
        msgs.append(line)
        # Product fit may keep these non-reachable; if REACHABLE, config must promote them.
        if st == "REACHABLE":
            teeth_fail.append(f"{mod}:REACHABLE_but_listed_as_teeth")
    msgs.append("PREFIT_REACHABILITY_TEETH_END")
    if teeth_fail:
        # Not a silent pass: landing decoder without updating critical is a config error.
        failures.extend(teeth_fail)

    if failures:
        msgs.append(
            "FAIL PREFIT_REACHABILITY critical/expect/teeth: "
            + ",".join(failures)
        )
        msgs.append(
            "NOTE soft-skip rc=77 is NOT a pass; UNKNOWN/missing inputs → rc=2"
        )
        return 1, msgs

    msgs.append(
        "PASS PREFIT_REACHABILITY all critical_modules and expect_reachable "
        "are REACHABLE from sys_top; teeth_non_reachable remain non-reachable "
        "(presence only — not correctness; post-fit needs FIT_RPT)"
    )
    return 0, msgs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--root",
        type=Path,
        default=ROOT_DEFAULT,
        help="repo root (default: parent of scripts/)",
    )
    ap.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG,
        help="JSON critical module list",
    )
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="require historical RED on decoder + GREEN on expect_reachable",
    )
    args = ap.parse_args()
    root = args.root.resolve()
    cfg_path = args.config
    if not cfg_path.is_file():
        # allow config relative to root
        alt = root / "tests" / "fixtures" / "critical_prefit_reachability.json"
        if alt.is_file():
            cfg_path = alt
        else:
            print(
                f"FAIL PREFIT_REACHABILITY missing config {args.config}",
                file=sys.stderr,
            )
            print("true rc=2")
            return 2

    try:
        config = load_config(cfg_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL PREFIT_REACHABILITY bad config: {exc}", file=sys.stderr)
        print("true rc=2")
        return 2

    if args.self_test:
        # Self-test: product critical/expect must be REACHABLE; historical
        # teeth_non_reachable must stay ABSENT/NOT_IN_QIP/PRUNED (CAVLC class).
        rc, msgs = run_gate(root, config, require_critical=True)
        for m in msgs:
            print(m)
        teeth = {m: None for m in config.get("teeth_non_reachable") or []}
        ok = {m: None for m in config["expect_reachable"]}
        crit = {m: None for m in config["critical_modules"]}
        for line in msgs:
            if line.startswith("MODULE "):
                parts = line.split()
                name = parts[1]
                st = parts[2].split("=", 1)[1]
                if name in teeth:
                    teeth[name] = st
                if name in ok:
                    ok[name] = st
                if name in crit:
                    crit[name] = st

        red_teeth = any(
            st in {"ABSENT", "NOT_IN_QIP", "PRUNED"} for st in teeth.values()
        ) and len(teeth) > 0
        pruned_cavlc = any(
            n.startswith("h264_cavlc") and st == "PRUNED" for n, st in teeth.items()
        )
        green_ok = all(st == "REACHABLE" for st in ok.values()) and len(ok) > 0
        green_crit = all(st == "REACHABLE" for st in crit.values()) and len(crit) > 0
        print(
            f"SELFTEST_TEETH red_on_teeth={int(red_teeth)} "
            f"pruned_cavlc={int(pruned_cavlc)} green_on_expect={int(green_ok)} "
            f"green_on_critical={int(green_crit)} full_gate_rc={rc}"
        )
        print(f"SELFTEST_TEETH_STATUS {teeth}")
        print(f"SELFTEST_CRITICAL_STATUS {crit}")
        print(f"SELFTEST_EXPECT_OK_STATUS {ok}")
        if rc != 0:
            print("FAIL SELFTEST: full product gate not green on this tree")
            print("true rc=1")
            return 1
        if not red_teeth:
            print(
                "FAIL SELFTEST: teeth_non_reachable has no ABSENT/NOT_IN_QIP/PRUNED "
                "— CAVLC/decoder prune teeth missing (or decoder landed; update config)"
            )
            print("true rc=1")
            return 1
        if not pruned_cavlc:
            print(
                "FAIL SELFTEST: expected h264_cavlc_* PRUNED tooth missing "
                "(QIP-but-pruned class not detected)"
            )
            print("true rc=1")
            return 1
        if not green_ok or not green_crit:
            print(
                "FAIL SELFTEST: product critical/expect not REACHABLE — "
                f"crit={crit} ok={ok}"
            )
            print("true rc=1")
            return 1
        print(
            "PASS SELFTEST PREFIT_REACHABILITY teeth=1 "
            "(product critical REACHABLE; teeth non-reachable; "
            "CAVLC PRUNED class detected=1)"
        )
        print("true rc=0")
        return 0

    rc, msgs = run_gate(root, config, require_critical=True)
    for m in msgs:
        print(m)
    print(f"true rc={rc}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
