"""Decoder-module REACHABILITY for modules claimed delivered.

Extends the PREFIT_REACHABILITY concept: a module that is merely in files.qip
(or compiled as a design unit) but never instantiated from sys_top/emu is the
exact defect class measured on the first 720p map hierarchy (zero h264_*
instances). Claimed-delivered decoder modules must be REACHABLE, not PRUNED.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any, Callable


def _load_prefit_mod(scripts_dir: Path):
    path = scripts_dir / "check_prefit_reachability.py"
    spec = importlib.util.spec_from_file_location("check_prefit_reachability", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def check_claimed_decoder_modules(
    root: Path,
    claimed_modules: list[str],
    *,
    prefit_config: dict[str, Any] | None = None,
    scripts_dir: Path | None = None,
) -> tuple[int, list[str]]:
    """Prove each claimed module is REACHABLE from sys_top/emu.

    Empty claims → PASS (nothing delivered yet is honest).
    Non-empty claim that is PRUNED/NOT_IN_QIP/ABSENT → FAIL.
    """
    msgs: list[str] = ["DECODER_REACHABILITY_EXECUTED begin"]
    if not claimed_modules:
        msgs.append(
            "DECODER_REACHABILITY_CLAIMS n=0 — no modules claimed delivered (honest empty)"
        )
        msgs.append("PASS decoder_reachability: no false delivery claims")
        return 0, msgs

    scripts_dir = scripts_dir or (root / "scripts")
    prefit = _load_prefit_mod(scripts_dir)

    plex_dir = root / "fpga" / "Plex_MiSTer"
    qip = plex_dir / "files.qip"
    sys_top = plex_dir / "sys" / "sys_top.v"
    qsf = plex_dir / "Plex.qsf"
    if not qip.is_file() or not sys_top.is_file():
        msgs.append("DECODER_REACHABILITY_UNKNOWN missing qip/sys_top")
        msgs.append(
            "FAIL decoder_reachability: cannot determine without files.qip+sys_top "
            "(soft-skip is NOT a pass)"
        )
        return 2, msgs

    macros = prefit.parse_active_qsf_macros(qsf)
    qip_files = prefit.parse_qip_sv_files(qip, plex_dir)
    files = list(dict.fromkeys(qip_files + [sys_top]))
    mod_file, children, warnings = prefit.build_graph(files, macros)
    for w in warnings[:10]:
        msgs.append(f"DECODER_REACHABILITY_WARN {w}")

    roots = list((prefit_config or {}).get("roots") or ["sys_top", "emu"])
    reach = prefit.reachable_from(roots, children, mod_file)
    msgs.append(
        f"DECODER_REACHABILITY_GRAPH modules_defined={len(mod_file)} "
        f"reachable={len(reach)} roots={roots}"
    )
    msgs.append(
        "DECODER_REACHABILITY_CLAIMS n="
        + str(len(claimed_modules))
        + " "
        + ",".join(claimed_modules)
    )

    # Local status (mirror prefit status_for enough for claims).
    failures: list[str] = []
    for mod in claimed_modules:
        path = mod_file.get(mod)
        defined = mod in mod_file
        in_qip = False
        if path is not None:
            in_qip = any(p.resolve() == path.resolve() for p in qip_files)
        if not in_qip:
            in_qip = any(p.stem == mod or p.name == f"{mod}.sv" for p in qip_files)

        if not defined:
            st = "ABSENT" if not in_qip else "ABSENT"
            detail = "not defined in design fileset"
            if not in_qip:
                detail = "not in files.qip / not defined"
            failures.append(f"{mod} STATUS={st} {detail}")
            msgs.append(f"DECODER_REACHABILITY_MODULE {mod} STATUS={st} claim=DELIVERED")
            continue

        if mod in reach:
            msgs.append(
                f"DECODER_REACHABILITY_MODULE {mod} STATUS=REACHABLE "
                f"file={mod_file[mod].name} claim=DELIVERED"
            )
            continue

        st = "PRUNED"
        detail = (
            f"defined in {mod_file[mod].name} but not instantiated from {roots} "
            "— QIP-visible / compile-then-strip (map hierarchy zero instances class)"
        )
        failures.append(f"{mod} STATUS={st} {detail}")
        msgs.append(f"DECODER_REACHABILITY_MODULE {mod} STATUS={st} claim=DELIVERED")

    # Optional: if config lists teeth_non_reachable, claiming one of them is
    # always a fail until promoted out of teeth (double-check).
    teeth = set((prefit_config or {}).get("teeth_non_reachable") or [])
    for mod in claimed_modules:
        if mod in teeth and mod not in reach:
            # already failed above; annotate
            msgs.append(
                f"DECODER_REACHABILITY_TEETH {mod} still in teeth_non_reachable "
                "and not REACHABLE — cannot claim delivered"
            )

    if failures:
        for f in failures:
            msgs.append(f"DECODER_REACHABILITY_FAIL {f}")
        msgs.append(
            "FAIL decoder_reachability: claimed-delivered module(s) not REACHABLE "
            "from sys_top/emu (QIP-only is not delivery)"
        )
        return 1, msgs

    msgs.append("PASS decoder_reachability: all claimed modules REACHABLE")
    return 0, msgs
