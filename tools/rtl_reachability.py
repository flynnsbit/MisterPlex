#!/usr/bin/env python3
"""Transitive RTL reachability from the design top through the Quartus file list.

WHY THIS EXISTS
---------------
Ad-hoc greps produced three successive wrong answers on fabric H.264 connectivity.
This walks a module instantiation graph from the top through files.qip.

CRITICAL FIX (rd-duck NACK of db9735e7):
  Graph edges MUST be extracted from each module's own `module`..`endmodule`
  body. Using the entire multi-module .sv file text assigns every sibling's
  instantiations to every module in that file (e.g. leaf h264_dpb_i420_addr
  falsely inherited five file-wide children).

POSITIVE / NEGATIVE CONTROLS (code, not docstring):
  Run before trusting output. Fail closed (rc!=0) if any control fails.

LIMITATIONS (stated, not hidden):
  - Does NOT evaluate `generate` / `ifdef` / QSF macros (e.g. PRODUCT_NO_STUB).
    Product builds that define PRODUCT_NO_STUB omit decode_stub and the whole
    stub-backed h264 branch even if this tool still sees the source edges.
  - Text-based, not a real elaborator. Post-fit hierarchy is authority for
    what actually built into an RBF.
  - Does NOT claim modules are "in the shipping RBF" or that area is "paid".
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

QIP_FILE_RE = re.compile(
    r"set_global_assignment\s+-name\s+(?:SYSTEMVERILOG|VERILOG)_FILE\s+(\S+)",
    re.I,
)
MODULE_DECL_RE = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)", re.M)
ENDMODULE_RE = re.compile(r"^\s*endmodule\b", re.M)
LINE_COMMENT_RE = re.compile(r"//[^\n]*")
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)


def strip_comments(t: str) -> str:
    return LINE_COMMENT_RE.sub("", BLOCK_COMMENT_RE.sub("", t))


def module_bodies(text: str) -> dict[str, str]:
    """Map module name -> full module..endmodule source slice."""
    bodies: dict[str, str] = {}
    pos = 0
    while True:
        m = MODULE_DECL_RE.search(text, pos)
        if not m:
            break
        name = m.group(1)
        em = ENDMODULE_RE.search(text, m.end())
        if not em:
            body = text[m.start() :]
            pos = len(text)
        else:
            body = text[m.start() : em.end()]
            pos = em.end()
        bodies.setdefault(name, body)
    return bodies


def instantiations(text: str, known_modules: set[str]) -> set[str]:
    """Lines that BEGIN with a known module name, then `#` or instance id."""
    found: set[str] = set()
    for m in known_modules:
        pat = re.compile(
            r"^[ \t]*" + re.escape(m) + r"(?=[ \t]*(?:#|[A-Za-z_]))",
            re.M,
        )
        if pat.search(text):
            found.add(m)
    return found


def build_graph(root: Path):
    qip = root / "files.qip"
    if not qip.exists():
        raise FileNotFoundError(f"no files.qip at {qip}")

    qip_files = []
    for line in qip.read_text().splitlines():
        mm = QIP_FILE_RE.search(line)
        if mm:
            qip_files.append(mm.group(1))

    decl_file = {}
    bodies = {}
    all_sv = sorted(list(root.rglob("*.sv")) + list(root.rglob("*.v")))
    for f in all_sv:
        try:
            raw = strip_comments(f.read_text(errors="ignore"))
        except OSError:
            continue
        for name, body in module_bodies(raw).items():
            if name not in decl_file:
                decl_file[name] = f
                bodies[name] = body

    known = set(decl_file)
    in_qip = set()
    for rel in qip_files:
        p = (root / rel).resolve()
        for name, f in decl_file.items():
            if f.resolve() == p:
                in_qip.add(name)

    edges = {}
    for name in known:
        kids = instantiations(bodies.get(name, ""), known)
        kids.discard(name)
        edges[name] = kids

    return decl_file, edges, in_qip, bodies


def bfs(top, edges, in_qip):
    seen = set()
    queue = [top]
    allow = set(in_qip)
    allow.add(top)
    while queue:
        cur = queue.pop()
        if cur in seen:
            continue
        seen.add(cur)
        for child in sorted(edges.get(cur, ())):
            if child in allow and child not in seen:
                queue.append(child)
    return seen


def run_controls(root, decl_file, edges, bodies):
    fails = []
    known = set(decl_file)

    leaf = "h264_dpb_i420_addr"
    if leaf in edges:
        kids = edges[leaf]
        if kids:
            fails.append(
                f"NEGATIVE CONTROL FAIL: {leaf} must have 0 body children, "
                f"got {sorted(kids)} (file-wide union bug still present?)"
            )
    elif any(p.name == "h264_dpb.sv" for p in decl_file.values()):
        fails.append(f"NEGATIVE CONTROL FAIL: expected {leaf} declared in tree")

    dpb_path = None
    for n, f in decl_file.items():
        if f.name == "h264_dpb.sv":
            dpb_path = f
            break
    if dpb_path is not None:
        raw = strip_comments(dpb_path.read_text(errors="ignore"))
        file_wide = instantiations(raw, known)
        for n, f in decl_file.items():
            if f != dpb_path:
                continue
            if edges.get(n, set()) == file_wide and len(file_wide) > 1:
                fails.append(
                    f"NEGATIVE CONTROL FAIL: {n} edges == entire h264_dpb.sv "
                    f"instantiation set ({sorted(file_wide)})"
                )

    stub = "decode_stub"
    if stub in bodies:
        stub_kids = edges.get(stub, set())
        # Transform leaves are always direct under stub in this tree.
        required = {
            "h264_dequant4x4",
            "h264_idct4x4",
            "h264_recon4x4",
        }
        missing = sorted(required - stub_kids)
        if missing:
            fails.append(
                f"POSITIVE CONTROL FAIL: decode_stub body missing {missing}; "
                f"got {sorted(stub_kids)}"
            )
        # DPB seam: either direct one_ref (older stub) or ref_commit wrapper
        # (product path: decode_stub -> h264_dpb_ref_commit -> h264_dpb_one_ref).
        has_direct = "h264_dpb_one_ref" in stub_kids
        has_commit = "h264_dpb_ref_commit" in stub_kids
        if not has_direct and not has_commit:
            fails.append(
                "POSITIVE CONTROL FAIL: decode_stub body has neither "
                "h264_dpb_one_ref nor h264_dpb_ref_commit; "
                f"got {sorted(stub_kids)}"
            )
        if has_commit:
            commit_kids = edges.get("h264_dpb_ref_commit", set())
            if "h264_dpb_one_ref" not in commit_kids:
                fails.append(
                    "POSITIVE CONTROL FAIL: h264_dpb_ref_commit body missing "
                    f"h264_dpb_one_ref; got {sorted(commit_kids)}"
                )
    elif list(root.rglob("decode_stub.sv")):
        fails.append(
            "POSITIVE CONTROL FAIL: decode_stub.sv present but module not indexed"
        )

    if "stream_path" in bodies:
        body = bodies["stream_path"]
        if re.search(r"^[ \t]*decode_stub\b", body, re.M):
            if "decode_stub" not in edges.get("stream_path", set()):
                fails.append(
                    "POSITIVE CONTROL FAIL: stream_path body has decode_stub line "
                    "but edges missed it"
                )
    elif list(root.rglob("stream_path.sv")):
        fails.append(
            "POSITIVE CONTROL FAIL: stream_path.sv present but module not indexed"
        )

    plex_files = list(root.glob("Plex.sv")) + list(root.rglob("Plex.sv"))
    if plex_files:
        raw = strip_comments(plex_files[0].read_text(errors="ignore"))
        pbodies = module_bodies(raw)
        host = "emu" if "emu" in pbodies else ("Plex" if "Plex" in pbodies else None)
        if host:
            for need in ("present_core", "stream_path"):
                if need in known and not re.search(
                    r"^[ \t]*" + need + r"\b", pbodies[host], re.M
                ):
                    fails.append(
                        f"POSITIVE CONTROL FAIL: {host} body does not instantiate {need}"
                    )

    return fails


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    top = sys.argv[2] if len(sys.argv) > 2 else "sys_top"

    try:
        decl_file, edges, in_qip, bodies = build_graph(root)
    except FileNotFoundError as e:
        print(f"FATAL: {e}")
        return 2

    in_qip = set(in_qip)
    in_qip.add(top)

    control_fails = run_controls(root, decl_file, edges, bodies)
    if control_fails:
        print("CONTROL FAILURES (refuse to report LIVE/DEAD as ground truth):")
        for msg in control_fails:
            print(f"  - {msg}")
        return 3

    seen = bfs(top, edges, in_qip)
    known = set(decl_file)
    h264 = sorted(n for n in known if n.startswith("h264_"))
    live = [n for n in h264 if n in seen]
    dead = [n for n in h264 if n not in seen]

    print(
        f"top={top}  modules_declared={len(known)}  in_qip={len(in_qip)}  "
        f"reachable={len(seen)}"
    )
    print("controls=PASS (body-scoped edges; pos+neg asserted in code)")
    print(
        "LIMIT: ifdef/QSF (PRODUCT_NO_STUB) not evaluated — source reachability "
        "!= shipping RBF / post-fit hierarchy"
    )
    print(f"--- h264_* REACHABLE FROM TOP (source graph): {len(live)}")
    for n in live:
        print(f"    LIVE {n:34s} ({decl_file[n].name})")
    print(f"--- h264_* NOT REACHABLE (source graph): {len(dead)}")
    for n in dead:
        why = (
            "not in files.qip"
            if n not in in_qip
            else "in qip but never instantiated on a path from top"
        )
        print(f"    DEAD {n:34s} ({decl_file[n].name}) [{why}]")
    print("--- NON-CLAIMS")
    print("    NOT claimed: modules present in any deployed/shipping RBF")
    print("    NOT claimed: area already paid / fits without PRODUCT_NO_STUB")
    print("    NOT claimed: complete fabric decoder supplies product frames")
    return 0


if __name__ == "__main__":
    sys.exit(main())
