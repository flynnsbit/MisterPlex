#!/usr/bin/env python3
"""First-class gate: emu reachability is masked by decode_stub; core-subtree is not.

Parent ruling, 2026-07-28: no product-completeness claim may cite plain `emu`
reachability while `decode_stub` is instantiated. The retired diagnostic painter
is still a child of `stream_path`, so MC/DPB/ref/deblock modules appear in an
emu-rooted reachable set while being absent from the real decoder.

Measured at w-decode-hour27 ddb7c97:

    emu_reachable_rtl = 47
    core_subtree      = 15
    stub_masked       = 9   (8 real capability modules + decode_stub itself)

This gate makes that distinction non-optional. It classifies every module named
in the decode capability manifest as:

    CORE_REACHABLE  reachable from h264_decode_core -- real product evidence
    STUB_MASKED     reachable from emu only via decode_stub -- NOT evidence
    ABSENT          not reachable from emu at all

STUB_MASKED is a ratchet against fpga/Plex_MiSTer/rtl/stub_masked_modules.txt:

* a module that is stub-masked but undeclared is a hard fail -- new masking;
* a declared module that is no longer stub-masked is a hard fail -- the stale
  declaration must be deleted, so the number can only be driven down deliberately
  and the manifest diff becomes the evidence of progress.

Run with --update-baseline to rewrite the manifest from measurement; commit the
diff as the record of what moved.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import check_rtl_module_instantiations as rtl  # noqa: E402

PRODUCT_DECODER = "h264_decode_core"
MASKING_LINEAGES = ("decode_stub",)
CAPABILITY_MANIFEST = rtl.RTL_DIR / "decode_capability_modules.txt"
STUB_MASKED_MANIFEST = rtl.RTL_DIR / "stub_masked_modules.txt"

MANIFEST_HEADER = """\
# Modules reachable from the product root `emu` ONLY through a retired masking
# lineage ({lineages}), and NOT through the product decoder {decoder}.
#
# Their presence in an emu-rooted reachable set is NOT evidence of product decode
# capability. Parent ruling 2026-07-28.
#
# This file is a ratchet, enforced by scripts/check_decode_core_subtree.py:
#   * a stub-masked module missing from this list fails the gate (new masking);
#   * a listed module that is no longer stub-masked fails the gate (stale entry).
#
# Regenerate with: python3 scripts/check_decode_core_subtree.py --update-baseline
"""


def fail(msg: str) -> None:
    print(f"DECODE_CORE_SUBTREE_FAIL: {msg}", file=sys.stderr)
    raise SystemExit(1)


def parse_capabilities() -> dict[str, tuple[list[str], str]]:
    if not CAPABILITY_MANIFEST.exists():
        fail(f"missing capability manifest {CAPABILITY_MANIFEST}")
    caps: dict[str, tuple[list[str], str]] = {}
    for raw in CAPABILITY_MANIFEST.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(":", 2)
        if len(parts) != 3:
            fail(f"malformed capability line: {raw!r}")
        category, modules, reason = (p.strip() for p in parts)
        caps[category] = ([m.strip() for m in modules.split(",") if m.strip()], reason)
    if not caps:
        fail("capability manifest declares no categories")
    return caps


def parse_masked_manifest() -> dict[str, str]:
    if not STUB_MASKED_MANIFEST.exists():
        return {}
    out: dict[str, str] = {}
    for raw in STUB_MASKED_MANIFEST.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, _, reason = line.partition(":")
        out[name.strip()] = reason.strip()
    return out


def write_masked_manifest(masked: dict[str, str]) -> None:
    body = MANIFEST_HEADER.format(
        lineages=", ".join(MASKING_LINEAGES), decoder=PRODUCT_DECODER
    )
    lines = [body]
    for name in sorted(masked):
        lines.append(f"{name}: {masked[name]}")
    STUB_MASKED_MANIFEST.write_text("\n".join(lines) + "\n")


def classify(
    graph: dict[str, set[str]],
    modules: dict[str, object],
    emu_reachable: set[str],
) -> tuple[set[str], set[str], set[str]]:
    core = rtl.reachable_from(PRODUCT_DECODER, graph) if PRODUCT_DECODER in graph else set()
    if PRODUCT_DECODER in modules:
        core = core | {PRODUCT_DECODER}
    if PRODUCT_DECODER not in emu_reachable:
        # A decoder that is not in the product cannot lend product evidence to
        # anything beneath it. Its subtree is empty for gating purposes.
        core = set()
    masking = set()
    for lineage in MASKING_LINEAGES:
        if lineage in emu_reachable and lineage in graph:
            masking |= rtl.reachable_from(lineage, graph) | {lineage}
    return core, masking, emu_reachable


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--update-baseline",
        action="store_true",
        help="Rewrite the stub-masked manifest from measurement and exit 0.",
    )
    args = ap.parse_args(argv)

    paths = rtl.git_files("fpga/Plex_MiSTer/rtl") + [rtl.PRODUCT_TOP]
    modules, graph, emu_reachable = rtl.build_reachable(paths)
    rtl_names = {
        name for name, mod in modules.items()
        if rtl.RTL_DIR in mod.path.parents or mod.path == rtl.RTL_DIR
    }
    caps = parse_capabilities()
    capability_modules = sorted({m for mods, _ in caps.values() for m in mods})

    core, masking, _ = classify(graph, modules, emu_reachable)
    core_rtl = core & rtl_names
    stub_masked = sorted((emu_reachable & rtl_names & masking) - core)

    print(
        "Scope: rtl_modules=%d emu_reachable=%d core_subtree=%d masking_subtree=%d "
        "capability_categories=%d capability_modules=%d product_decoder=%s "
        "product_decoder_in_product=%s"
        % (
            len(rtl_names),
            len(emu_reachable & rtl_names),
            len(core_rtl),
            len(masking & rtl_names),
            len(caps),
            len(capability_modules),
            PRODUCT_DECODER,
            "yes" if PRODUCT_DECODER in emu_reachable else "no",
        ),
        flush=True,
    )
    if not rtl_names or not capability_modules:
        fail("Scope: 0 modules or 0 capability modules; the gate cannot claim a PASS")

    unknown = [m for m in capability_modules if m not in modules]
    if unknown:
        fail("capability manifest names modules that do not exist: " + ", ".join(sorted(unknown)))

    measured_masked = {
        name: "reachable from emu only via " + ",".join(sorted(set(MASKING_LINEAGES)))
        for name in stub_masked
    }
    if args.update_baseline:
        write_masked_manifest(measured_masked)
        print(f"DECODE_CORE_SUBTREE_BASELINE_WRITTEN entries={len(measured_masked)}")
        return 0

    for category, (mods, _reason) in sorted(caps.items()):
        in_core = [m for m in mods if m in core]
        masked = [m for m in mods if m not in core and m in masking and m in emu_reachable]
        absent = [m for m in mods if m not in core and m not in masked]
        print(
            f"DECODE_CAPABILITY {category} core={len(in_core)}/{len(mods)} "
            f"stub_masked={len(masked)} absent={len(absent)} "
            f"masked_modules={','.join(masked) if masked else '<none>'}",
            flush=True,
        )

    declared = parse_masked_manifest()
    undeclared = sorted(set(stub_masked) - set(declared))
    stale = sorted(set(declared) - set(stub_masked))

    for name in stub_masked:
        print(f"STUB_MASKED_MODULE {name} product_decoder_subtree=no", flush=True)

    for name in undeclared:
        print(
            f"STUB_MASKED_UNDECLARED {name} is reachable from emu only through "
            f"{','.join(MASKING_LINEAGES)}",
            file=sys.stderr,
        )
    for name in stale:
        print(
            f"STUB_MASKED_STALE {name} is no longer stub-masked; delete the declaration",
            file=sys.stderr,
        )

    if undeclared:
        fail(
            "new decode_stub masking: these modules count as product-reachable only through "
            "the retired painter and must not be cited as decode capability: "
            + ", ".join(undeclared)
        )
    if stale:
        fail(
            "stale stub-masked declarations; the ratchet must be tightened by deleting them: "
            + ", ".join(stale)
        )

    print(
        "DECODE_CORE_SUBTREE_OK "
        f"emu_reachable={len(emu_reachable & rtl_names)} "
        f"core_subtree={len(core_rtl)} "
        f"stub_masked={len(stub_masked)} "
        f"capability_categories={len(caps)} "
        f"product_decoder={PRODUCT_DECODER} "
        f"product_decoder_in_product={'yes' if PRODUCT_DECODER in emu_reachable else 'no'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
