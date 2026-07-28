#!/usr/bin/env python3
"""Gate the build-identity *delivery chain*, not just the digest.

Why this exists (W-OSD-O5, 2026-07)
-----------------------------------
``tests/unit/test_build_identity.sh`` proves the SRC digest behaves correctly:
it tracks fitted sources, ignores build outputs, is reproducible, and refuses to
stamp a tree with no git identity.  Every one of those checks passes even if the
generated identity never reaches the bitstream at all, because the digest and
the delivery are separate concerns and only the digest was gated.

That is the project's signature failure applied to my own deliverable: a
subsystem proven working but not wired into the product.  It matters more here
than usual, because the whole point of the OSD build id is to be trustworthy.
A build id that silently stops updating is strictly worse than none, since it
keeps reporting an identity that used to be true.

The chain, as measured on this project::

    Plex.qsf        source sys/sys.tcl
    sys/sys.tcl     set_global_assignment -name PRE_FLOW_SCRIPT_FILE
                        "quartus_sh:sys/build_id.tcl"
    build_id.tcl    reads build_id_stamp.txt  (written by gen_build_stamp.py)
    build_id.tcl    writes build_id.v: `define BUILD_ID "..."
    Plex.sv         "V,v",`BUILD_ID      inside CONF_STR
    Plex.sv         is in the Quartus file list

Break any single link and the OSD shows a stale or default string while every
other identity test stays green.  Each link below is checked separately so a
failure names the link that broke.

What this does NOT prove: that a fit ran, that the RBF was deployed, or that
the OSD renders the string on a screen.  It proves the wiring exists in the
sources a fit would consume.

Mode 3: optimize-away
---------------------
Correct source wiring is necessary and not sufficient.  A module can be in the
file list, be instantiated, elaborate, and then be **deleted by synthesis** for
contributing zero resources, because nothing downstream observably consumes its
outputs.  No source-level tool can see that; only real synthesis can.

For the build id the module that must survive is the OSD compositor itself: if
`osd` or `hps_io` were optimised away, the string could not be rendered however
correct the CONF_STR wiring is.  Pass `--fit-rpt` (a Quartus fit or map report)
to check that with the strongest oracle available.  Without it this script says
so explicitly rather than letting a source-level green be mistaken for proof.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from quartus_file_list import compiled_files, resolve  # noqa: E402

SCOPE = (
    "Scope: proves the generated BUILD_ID actually reaches a compiled source "
    "file's CONF_STR. Source-level wiring only; it does not prove a fit ran, "
    "that an RBF was deployed, or that the OSD renders the string. With "
    "--fit-rpt it additionally proves the OSD compositor survived synthesis."
)

# If these are optimised away, no CONF_STR wiring can put a build id on screen.
OSD_RENDER_MODULES = ("hps_io", "osd")

# Present in every product build's hierarchy. Its absence means the report could
# not be read as a product hierarchy, which is different from the OSD path being
# absent from the design.
HIERARCHY_ANCHOR = "emu"

MODE3_WARNING = (
    "NOTE source-level checks cannot detect optimize-away: a module can be "
    "compiled, instantiated and elaborated, then deleted by synthesis for "
    "contributing zero resources. Pass --fit-rpt <Plex.fit.rpt|Plex.map.rpt> "
    "to check the OSD compositor actually survived."
)


def check_synthesis_survival(rpt: Path, expect_rbf_md5: str | None) -> int:
    """Mode-3 check: did the OSD render path survive real synthesis?

    Two things this must not do, both learned the hard way:

    * **Read an unbound report.** 55 fit reports exist in this worktree and most
      describe builds nobody is running. A report proves nothing about a
      bitstream unless it is tied to that bitstream's md5, so without
      ``--expect-rbf-md5`` this returns 77 (cannot evaluate) and prints no
      verdict line, rather than a green about an unrelated build.
    * **Confuse "absent" with "unseen".** If the module is missing we can only
      call it optimized away when we have positive evidence the hierarchy was
      actually parsed. The anchor below supplies that. Otherwise a truncated or
      wrong-format report would produce a confident false "optimized away" --
      a self-imposed scope limit silently becoming a claim about the world.
    """
    if not rpt.is_file():
        print(f"FAIL --fit-rpt not found: {rpt}")
        return 1

    rbf = rpt.parent / "Plex.rbf"
    if expect_rbf_md5:
        if not rbf.is_file():
            print(f"UNBOUND: no sibling Plex.rbf beside {rpt}")
            return 1
        got = hashlib.md5(rbf.read_bytes()).hexdigest()
        if not got.startswith(expect_rbf_md5.lower()):
            print(
                f"BINDING_FAIL sibling Plex.rbf md5={got[:8]} "
                f"expected={expect_rbf_md5}"
            )
            return 1
        print(f"BOUND report -> Plex.rbf md5={got[:8]}")
    else:
        # Printing UNBOUND while returning 0 is the print/exit divergence that
        # gets cited as a pass: the text says "do not cite me" and the exit code
        # says green, and every wrapper reads the exit code.
        print(
            f"UNBOUND: no --expect-rbf-md5 given; {rpt.name} may describe a build "
            "that is not deployed anywhere"
        )
        print("SKIP-NOT-PASS cannot evaluate mode 3 without an RBF binding",
              file=sys.stderr)
        return 77

    text = rpt.read_text(errors="replace")
    # Quartus hierarchy rows name instances as |module:instance
    found = set(re.findall(r"\|([A-Za-z_][A-Za-z_0-9]*):", text))
    if not found:
        print(
            f"FAIL --fit-rpt {rpt} contains no |module:instance hierarchy rows; "
            "an empty parse is a broken report, not a design with no modules"
        )
        return 1
    if HIERARCHY_ANCHOR not in found:
        print(
            f"UNSEEN: {rpt.name} parsed {len(found)} module names but not the "
            f"anchor {HIERARCHY_ANCHOR!r}. Every product build has it, so this "
            "report cannot be read as a product hierarchy. Reporting the OSD "
            "path as absent from it would be a claim about the report, not the "
            "design."
        )
        print("SKIP-NOT-PASS mode-3 arm unreadable: anchor missing", file=sys.stderr)
        return 2

    print(f"Scope: {len(found)} distinct modules in {rpt.name}, anchor {HIERARCHY_ANCHOR} present")
    rc = 0
    for mod in OSD_RENDER_MODULES:
        if mod in found:
            print(f"OK survived synthesis: {mod} (from {rpt.name})")
        else:
            print(
                f"FAIL {mod} is absent from {rpt.name}: the OSD render path was "
                "optimized away, so no build id can reach the screen"
            )
            rc = 1
    return rc

STAMP_NAME = "build_id_stamp.txt"
GENERATED_HEADER = "build_id.v"


class Result:
    def __init__(self) -> None:
        self.rc = 0

    def ok(self, msg: str) -> None:
        print(f"OK {msg}")

    def fail(self, msg: str) -> None:
        print(f"FAIL {msg}")
        self.rc = 1


def check_chain(project: Path, quartus_version: str) -> int:
    res = Result()

    qsf_candidates = sorted(project.glob("*.qsf"))
    if len(qsf_candidates) != 1:
        print(f"FAIL expected exactly one .qsf in {project}, found {len(qsf_candidates)}")
        return 1
    qsf = qsf_candidates[0]

    refs = resolve(project, quartus_version)
    files = compiled_files(refs, project)

    unresolved = [r for r in refs if r.unresolved]
    if unresolved:
        for r in unresolved:
            res.fail(f"unresolved Quartus file reference {r.raw!r} from {r.origin}")
        res.fail(
            "the file list is incomplete, so no membership answer below can be trusted"
        )
        return res.rc

    # --- link 1: the pre-flow hook is registered somewhere the flow reads ----
    hook_re = re.compile(
        r"set_global_assignment\s+-name\s+PRE_FLOW_SCRIPT_FILE\s+\"?quartus_sh:(\S+?)\"?\s*$"
    )
    hook_script: Path | None = None
    hook_origin: Path | None = None
    search_files = [qsf] + [
        project / f for f in sorted(files) if f.endswith((".tcl", ".qip"))
    ]
    for candidate in search_files:
        if not candidate.is_file():
            continue
        for line in candidate.read_text(errors="replace").splitlines():
            if line.strip().startswith("#"):
                continue
            m = hook_re.search(line.strip())
            if m:
                hook_script = project / m.group(1)
                hook_origin = candidate
                break
        if hook_script:
            break

    if hook_script is None:
        res.fail(
            "no PRE_FLOW_SCRIPT_FILE is registered in the project or any file it "
            "sources; nothing would generate the build identity"
        )
        return res.rc
    res.ok(
        f"pre-flow hook registered in {hook_origin.relative_to(project)} "
        f"-> {hook_script.relative_to(project)}"
    )

    # --- link 2: that script exists and is the identity generator -----------
    if not hook_script.is_file():
        res.fail(f"pre-flow script {hook_script} is registered but does not exist")
        return res.rc
    tcl = hook_script.read_text(errors="replace")

    # --- link 3: it consumes the stamp gen_build_stamp.py writes ------------
    if STAMP_NAME in tcl:
        res.ok(f"pre-flow script reads {STAMP_NAME} (the gen_build_stamp.py output)")
    else:
        res.fail(
            f"pre-flow script does not read {STAMP_NAME}; the identity would not be "
            "derived from the fit inputs"
        )

    # --- link 4: it emits `define BUILD_ID into the generated header --------
    if GENERATED_HEADER not in tcl:
        res.fail(f"pre-flow script does not write {GENERATED_HEADER}")
    elif re.search(r"`define\s+BUILD_ID", tcl):
        res.ok(f"pre-flow script writes `define BUILD_ID into {GENERATED_HEADER}")
    else:
        res.fail("pre-flow script never defines BUILD_ID")

    # --- link 5: a COMPILED source consumes `BUILD_ID in its CONF_STR -------
    consumers: list[str] = []
    conf_str_consumers: list[str] = []
    for rel in sorted(files):
        if not rel.endswith((".v", ".sv")):
            continue
        path = project / rel
        if not path.is_file():
            continue
        text = path.read_text(errors="replace")
        if "`BUILD_ID" not in text:
            continue
        consumers.append(rel)
        # The OSD sidebar entry is the "V" CONF_STR line; require `BUILD_ID to
        # be the value of a V entry, not merely mentioned in the file.
        if re.search(r'"V,[^"]*"\s*,\s*`BUILD_ID', text):
            conf_str_consumers.append(rel)

    if not consumers:
        res.fail(
            "no compiled source file references `BUILD_ID; the generated identity "
            "is produced and then discarded"
        )
    elif not conf_str_consumers:
        res.fail(
            "`BUILD_ID is referenced by "
            f"{', '.join(consumers)} but never as a CONF_STR \"V\" entry, so it "
            "would not appear in the OSD sidebar"
        )
    else:
        res.ok(
            "`BUILD_ID reaches the OSD via a CONF_STR V entry in "
            + ", ".join(conf_str_consumers)
        )

    # --- link 6: the consumer is genuinely in the Quartus file list ---------
    for rel in conf_str_consumers:
        if rel in files:
            res.ok(f"the CONF_STR consumer {rel} is in the Quartus file list")
        else:  # pragma: no cover - consumers are drawn from files by construction
            res.fail(f"the CONF_STR consumer {rel} is not compiled")

    return res.rc


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=SCOPE)
    ap.add_argument("--project", default="fpga/Plex_MiSTer", type=Path)
    ap.add_argument("--quartus-version", default="17")
    ap.add_argument(
        "--fit-rpt",
        type=Path,
        help="Quartus fit/map report; proves the OSD render path survived synthesis",
    )
    ap.add_argument(
        "--expect-rbf-md5",
        help="bind --fit-rpt to a bitstream: the sibling Plex.rbf must have this "
        "md5 (full or leading prefix). Without it the mode-3 arm is UNBOUND and "
        "cannot be evaluated.",
    )
    args = ap.parse_args(argv)

    if not args.project.is_dir():
        print(f"FAIL project directory not found: {args.project}")
        return 2

    print(SCOPE)
    rc = check_chain(args.project, args.quartus_version)

    if args.fit_rpt is not None:
        src = check_synthesis_survival(args.fit_rpt, args.expect_rbf_md5)
        if rc == 0 and src in (2, 77):
            # The source chain is fine but the mode-3 arm could not be
            # evaluated. Emit no verdict line at all, so no caller can grep
            # BUILD_ID_DELIVERY OK out of a run that proved nothing about
            # synthesis survival.
            return src
        if src != 0:
            rc = 1
    else:
        print(MODE3_WARNING)

    print("BUILD_ID_DELIVERY " + ("OK" if rc == 0 else "BROKEN"))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
