#!/usr/bin/env python3
"""Transitive RTL reachability from the design top through the Quartus file list.

WHY THIS EXISTS
---------------
Ad-hoc greps produced successive wrong answers about fabric H.264 connectivity.
This walks a real instantiation graph: parse files.qip, index module declarations,
extract per-module instantiations from each module..endmodule BODY (not the whole
file), then BFS from the top. Anything not reached is dead.

CRITICAL BUG FIXED (rd-duck NACK)
---------------------------------
Earlier revisions built edges[name] = instantiations(entire_file_text). In a
multi-module .sv every module inherited the UNION of the file's instances, so a
leaf like h264_dpb_i420_addr was falsely assigned file-wide children. Edges are
now extracted only from that module's own body.

LIMITATIONS (stated, not hidden):
  - Does not evaluate generate/ifdef or QSF macros such as PRODUCT_NO_STUB, so
    a module inside a disabled branch is reported reachable here but may not
    survive synthesis. Post-fit hierarchy is the authority for what actually built.
  - Text-based, not a real elaborator. Positive/negative CONTROLS below catch the
    known instrument failure modes; they are not a substitute for fit hierarchy.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

QIP_FILE_RE = re.compile(
    r"set_global_assignment\s+-name\s+(?:SYSTEMVERILOG|VERILOG)_FILE\s+(\S+)", re.I
)
MODULE_DECL_RE = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)", re.M)
MODULE_BODY_RE = re.compile(
    r"^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)\b(.*?)^\s*endmodule\b",
    re.M | re.S,
)
LINE_COMMENT_RE = re.compile(r"//[^\n]*")
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)


def strip_comments(t: str) -> str:
    return LINE_COMMENT_RE.sub("", BLOCK_COMMENT_RE.sub("", t))


def instantiations(text: str, known_modules: set[str]) -> set[str]:
    """Lines that BEGIN with a known module name, then # or an instance id."""
    found: set[str] = set()
    for m in known_modules:
        pat = re.compile(
            r"^[ \t]*" + re.escape(m) + r"(?=[ \t]*(?:#|[A-Za-z_]))", re.M
        )
        if pat.search(text):
            found.add(m)
    return found


def module_bodies(text: str) -> dict[str, str]:
    bodies: dict[str, str] = {}
    for m in MODULE_BODY_RE.finditer(text):
        name, body = m.group(1), m.group(2)
        bodies.setdefault(name, body)
    return bodies


def assert_controls(
    edges: dict[str, set[str]], seen: set[str], in_qip: set[str]
) -> list[str]:
    fails: list[str] = []

    leaf = "h264_dpb_i420_addr"
    if leaf in edges:
        if edges[leaf]:
            fails.append(
                f"NEGCTRL {leaf} must have 0 body children, got {sorted(edges[leaf])} "
                f"(file-wide edge union bug is back)"
            )
    else:
        fails.append(f"NEGCTRL missing edges entry for {leaf}")

    # mb_write_addr legitimately instantiates i420_addr — not a pure leaf.
    # NEGCTRL is the pure leaf only; also require the known parent edge exists.
    if "h264_dpb_mb_write_addr" in edges:
        if "h264_dpb_i420_addr" not in edges["h264_dpb_mb_write_addr"]:
            fails.append(
                "POSCTRL h264_dpb_mb_write_addr body must instantiate "
                f"h264_dpb_i420_addr (got {sorted(edges['h264_dpb_mb_write_addr'])})"
            )

    stub_must = [
        "h264_dequant4x4",
        "h264_idct4x4",
        "h264_recon4x4",
        "h264_dpb_one_ref",
    ]
    if "decode_stub" in edges:
        for child in stub_must:
            if child not in edges["decode_stub"]:
                fails.append(
                    f"POSCTRL decode_stub body must instantiate {child} "
                    f"(got {sorted(edges['decode_stub'])})"
                )
    else:
        fails.append("POSCTRL decode_stub not in edge index")

    if "stream_path" in edges:
        if "decode_stub" not in edges["stream_path"]:
            fails.append(
                f"POSCTRL stream_path must instantiate decode_stub "
                f"(got {sorted(edges['stream_path'])})"
            )
    else:
        fails.append("POSCTRL stream_path not in edge index")

    if "h264_decode_skeleton" in edges and "h264_decode_skeleton" in in_qip:
        skel_expect_any = [
            "h264_rbsp_filter",
            "h264_baseline_syntax_parser",
            "h264_cavlc_residual_block",
        ]
        if not any(x in edges["h264_decode_skeleton"] for x in skel_expect_any):
            fails.append(
                "POSCTRL h264_decode_skeleton body has no front-end leaves "
                f"{skel_expect_any}; got {sorted(edges['h264_decode_skeleton'])}"
            )

    if "stream_path" in in_qip and "stream_path" not in seen:
        fails.append(
            "POSCTRL stream_path in compile set but not reachable from top"
        )

    return fails


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    top = sys.argv[2] if len(sys.argv) > 2 else "sys_top"
    qip = root / "files.qip"
    if not qip.exists():
        print(f"FATAL: no files.qip at {qip}", file=sys.stderr)
        return 2

    qip_files: list[str] = []
    for line in qip.read_text().splitlines():
        mm = QIP_FILE_RE.search(line)
        if mm:
            qip_files.append(mm.group(1))

    decl_file: dict[str, Path] = {}
    bodies: dict[str, str] = {}
    all_sv = sorted(list(root.rglob("*.sv")) + list(root.rglob("*.v")))
    for f in all_sv:
        try:
            raw = strip_comments(f.read_text(errors="ignore"))
        except OSError:
            continue
        file_bodies = module_bodies(raw)
        for name, body in file_bodies.items():
            if name not in decl_file:
                decl_file[name] = f
                bodies[name] = body
        for name in MODULE_DECL_RE.findall(raw):
            decl_file.setdefault(name, f)
            bodies.setdefault(name, "")

    known = set(decl_file)
    in_qip: set[str] = set()
    for rel in qip_files:
        p = (root / rel).resolve()
        for name, f in decl_file.items():
            if f.resolve() == p:
                in_qip.add(name)
    in_qip.add(top)
    if "emu" in decl_file:
        in_qip.add("emu")
    if "Plex" in decl_file:
        in_qip.add("Plex")

    edges: dict[str, set[str]] = {
        name: instantiations(bodies.get(name, ""), known) for name in known
    }

    seen: set[str] = set()
    queue = [top]
    while queue:
        cur = queue.pop()
        if cur in seen:
            continue
        seen.add(cur)
        for child in sorted(edges.get(cur, ())):
            if child in in_qip and child not in seen:
                queue.append(child)

    control_fails = assert_controls(edges, seen, in_qip)

    h264 = sorted(n for n in known if n.startswith("h264_"))
    live = [n for n in h264 if n in seen]
    dead = [n for n in h264 if n not in seen]

    print(
        f"top={top}  modules_declared={len(known)}  "
        f"in_qip={len(in_qip)}  reachable={len(seen)}"
    )
    print(
        f"parser=module_body_edges  controls="
        f"{'FAIL' if control_fails else 'PASS'}"
    )
    print(f"--- h264_* REACHABLE FROM TOP: {len(live)}")
    for n in live:
        print(f"    LIVE {n:34s} ({decl_file[n].name})")
    print(f"--- h264_* NOT REACHABLE: {len(dead)}")
    for n in dead:
        why = (
            "not in files.qip"
            if n not in in_qip
            else "in qip but never instantiated on a path from top"
        )
        print(f"    DEAD {n:34s} ({decl_file[n].name}) [{why}]")

    for key in (
        "stream_path",
        "decode_stub",
        "h264_decode_skeleton",
        "h264_dpb_i420_addr",
    ):
        if key in edges:
            print(f"--- edges[{key}] ({len(edges[key])}): {sorted(edges[key])}")

    print("CAVEAT: ignores generate/ifdef/PRODUCT_NO_STUB; post-fit hierarchy is authority.")
    print("CAVEAT: source reachability != deployed RBF contents / area paid.")
    print("CAVEAT: LIVE on skeleton branch is not main stub-only LIVE=17.")
    if control_fails:
        print("--- CONTROL FAILURES ---", file=sys.stderr)
        for msg in control_fails:
            print(f"  {msg}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
