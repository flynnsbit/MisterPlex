#!/usr/bin/env python3
"""Decoder conformance gate — shared harness framework for fabric H.264 decode.

Named feature: replace ARM H.264 decode with fabric. Observed defect class:
h264_* modules in files.qip are compiled then never instantiated (zero map
hierarchy instances). This gate does NOT implement per-stage tests; it provides:

  1. Bit-exact ARM-vs-RTL compare with first-divergence RCA (MB/component/sample)
  2. Runtime corpus selection with recorded seed (anti demo-path hardcoding)
  3. Coverage ledger that fails empty/unproven completeness claims
  4. Claimed-delivered decoder REACHABILITY (extend PREFIT_REACHABILITY)

Controls: --self-test runs POS+NEG for each check (fixtures assembled at
runtime where text-scan risk exists). Exit 77 is never used as pass.

Exit codes:
  0  all selected checks PASS
  1  check failure (claim/compare/coverage/reachability)
  2  bad args / missing inputs (cannot determine → fail, not skip)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT_DEFAULT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT_DEFAULT / "scripts"))

from decoder_conformance.compare import (  # noqa: E402
    compare_i420,
    format_first_divergence,
    refuse_same_path,
)
from decoder_conformance.corpus import (  # noqa: E402
    load_corpus_manifest,
    select_subjects,
    paths_exist,
)
from decoder_conformance.coverage import (  # noqa: E402
    check_coverage_claims,
    claimed_rtl_modules,
    load_coverage_ledger,
)
from decoder_conformance.reachability_claims import (  # noqa: E402
    check_claimed_decoder_modules,
)


DEFAULT_CORPUS = (
    ROOT_DEFAULT / "tests" / "fixtures" / "decoder_conformance" / "corpus_manifest.json"
)
DEFAULT_COVERAGE = (
    ROOT_DEFAULT / "tests" / "fixtures" / "decoder_conformance" / "coverage_ledger.json"
)
DEFAULT_PREFIT = (
    ROOT_DEFAULT / "tests" / "fixtures" / "critical_prefit_reachability.json"
)


def _print(msgs: list[str]) -> None:
    for m in msgs:
        print(m)


def cmd_compare(args: argparse.Namespace) -> int:
    arm_p = Path(args.arm)
    rtl_p = Path(args.rtl)
    taut = refuse_same_path(arm_p, rtl_p)
    if taut:
        print(f"FAIL {taut}")
        return 1
    if not arm_p.is_file() or not rtl_p.is_file():
        print("FAIL compare: missing arm or rtl blob")
        return 2
    arm = arm_p.read_bytes()
    rtl = rtl_p.read_bytes()
    if args.format == "i420":
        if args.width <= 0 or args.height <= 0:
            print("FAIL compare: i420 requires --width/--height")
            return 2
        r = compare_i420(arm, rtl, args.width, args.height, stage=args.stage or "")
    else:
        from decoder_conformance.compare import compare_bytes

        r = compare_bytes(arm, rtl, stage=args.stage or "", fmt=args.format)
    print(format_first_divergence(r))
    if r.ok:
        print("PASS decoder_compare bit-exact")
        return 0
    print("FAIL decoder_compare bit-exact mismatch")
    return 1


def cmd_select_corpus(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    man_path = Path(args.manifest)
    try:
        man = load_corpus_manifest(man_path)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"FAIL corpus manifest: {e}")
        return 2
    try:
        sel = select_subjects(
            man,
            seed=args.seed,
            k=args.k,
            manifest_path=str(man_path),
            require_non_dev=bool(args.require_non_dev),
        )
    except (ValueError, RuntimeError) as e:
        print(f"FAIL corpus select: {e}")
        return 1
    missing = paths_exist(root, sel)
    out = sel.to_dict()
    out["missing_paths"] = missing
    text = json.dumps(out, indent=2) + "\n"
    if args.seed_out:
        Path(args.seed_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.seed_out).write_text(f"{sel.seed}\n")
    if args.selection_out:
        Path(args.selection_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.selection_out).write_text(text)
    print(
        f"CORPUS_SELECTION seed={sel.seed} k={sel.k} "
        f"ids={out['selected_ids']} non_dev={sel.non_dev_ids} dev_only={int(sel.dev_only)}"
    )
    if missing:
        print(f"FAIL corpus: missing subject files {missing}")
        return 1
    if args.require_non_dev and sel.dev_only:
        print("FAIL corpus: dev_only selection under require_non_dev")
        return 1
    print("PASS corpus selection recorded")
    return 0


def cmd_coverage(args: argparse.Namespace) -> int:
    try:
        led = load_coverage_ledger(Path(args.ledger))
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"FAIL coverage ledger: {e}")
        return 2
    rc, msgs = check_coverage_claims(led)
    _print(msgs)
    return rc


def cmd_reachability(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    claimed: list[str] = []
    if args.modules:
        claimed.extend(args.modules)
    if args.ledger:
        try:
            led = load_coverage_ledger(Path(args.ledger))
            claimed.extend(claimed_rtl_modules(led))
        except (OSError, ValueError, json.JSONDecodeError) as e:
            print(f"FAIL reachability ledger: {e}")
            return 2
    # de-dupe preserve order
    seen: set[str] = set()
    uniq: list[str] = []
    for m in claimed:
        if m not in seen:
            seen.add(m)
            uniq.append(m)
    prefit_cfg = {}
    pref = Path(args.prefit_config)
    if pref.is_file():
        prefit_cfg = json.loads(pref.read_text())
    rc, msgs = check_claimed_decoder_modules(
        root, uniq, prefit_config=prefit_cfg, scripts_dir=root / "scripts"
    )
    _print(msgs)
    return rc


def cmd_gate(args: argparse.Namespace) -> int:
    """Full gate: coverage + claimed reachability + corpus path existence sample."""
    print("EXECUTED check_decoder_conformance gate")
    root = Path(args.root).resolve()
    worst = 0

    # Coverage
    led_path = Path(args.ledger)
    try:
        led = load_coverage_ledger(led_path)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"FAIL gate coverage load: {e}")
        return 2
    rc_c, msgs_c = check_coverage_claims(led)
    _print(msgs_c)
    worst = max(worst, rc_c)

    claimed = claimed_rtl_modules(led)
    prefit_cfg = {}
    pref = Path(args.prefit_config)
    if pref.is_file():
        prefit_cfg = json.loads(pref.read_text())
    rc_r, msgs_r = check_claimed_decoder_modules(
        root, claimed, prefit_config=prefit_cfg, scripts_dir=root / "scripts"
    )
    _print(msgs_r)
    worst = max(worst, rc_r)

    # Corpus: record a selection (does not require non-dev unless any stage claims)
    man_path = Path(args.manifest)
    try:
        man = load_corpus_manifest(man_path)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"FAIL gate corpus load: {e}")
        return 2
    any_claim = any(
        bool(st.get("claimed_complete")) or bool(st.get("claim_delivered"))
        for st in (led.get("stages") or {}).values()
        if isinstance(st, dict)
    )
    try:
        sel = select_subjects(
            man,
            seed=args.seed,
            k=min(args.k, len(man["pool"])),
            manifest_path=str(man_path),
            require_non_dev=any_claim,
        )
    except (ValueError, RuntimeError) as e:
        print(f"FAIL gate corpus select: {e}")
        return 1
    missing = paths_exist(root, sel)
    print(
        f"CORPUS_SELECTION seed={sel.seed} k={sel.k} ids={[s.id for s in sel.selected]} "
        f"non_dev={sel.non_dev_ids} dev_only={int(sel.dev_only)} "
        f"require_non_dev={int(any_claim)}"
    )
    if args.selection_out:
        p = Path(args.selection_out)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(sel.to_dict(), indent=2) + "\n")
        print(f"CORPUS_SELECTION_WRITTEN {p}")
    if missing:
        print(f"FAIL gate corpus missing files: {missing}")
        worst = max(worst, 1)

    if worst == 0:
        print("PASS decoder_conformance gate")
    else:
        print("FAIL decoder_conformance gate")
    return worst


def _self_test(root: Path) -> int:
    """POS+NEG controls for each harness leg. Fixtures assembled at runtime."""
    print("EXECUTED check_decoder_conformance --self-test")
    failures: list[str] = []

    def note(name: str, got: int, want: int, detail: str = "") -> None:
        # Control outcome: rc=0 means this POS/NEG control behaved as expected.
        ok = got == want
        line = (
            f"SELFTEST {name}: rc={0 if ok else 1} "
            f"got={got} expect={want}"
        )
        if detail:
            line += f" {detail}"
        print(line)
        if not ok:
            failures.append(line)

    # --- Compare POS: identical I420 ---
    w, h = 32, 16  # 2x1 MBs
    y = w * h
    c = (w // 2) * (h // 2)
    arm = bytes([i % 256 for i in range(y + 2 * c)])
    rtl = bytes(arm)
    r = compare_i420(arm, rtl, w, h, stage="selftest")
    note("POS_compare_identical", 0 if r.ok else 1, 0, r.summary_line())

    # --- Compare NEG: single sample fault in MB1 (x=16.. of Y) ---
    fault = bytearray(arm)
    # MB index 1: mb_x=1 mb_y=0 → Y offset = 16 (first pixel of second MB)
    fault_off = 16
    fault[fault_off] = (fault[fault_off] + 1) % 256
    r2 = compare_i420(arm, bytes(fault), w, h, stage="selftest")
    rc_neg = 0 if (
        (not r2.ok)
        and r2.mb_index == 1
        and r2.mb_x == 1
        and r2.mb_y == 0
        and r2.component == "Y"
        and r2.offset == fault_off
        and r2.expected == arm[fault_off]
        and r2.actual == fault[fault_off]
    ) else 1
    note(
        "NEG_compare_first_divergence",
        rc_neg,
        0,
        format_first_divergence(r2),
    )
    # runner exit for mismatch path
    note("NEG_compare_exit", 0 if not r2.ok else 1, 0)

    # --- Tautology path guard ---
    # Project-local scratch (never /tmp — harness policy).
    scratch = root / "build" / "decoder_conformance" / "selftest_scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    blob = scratch / "same.yuv"
    blob.write_bytes(arm)
    taut = refuse_same_path(blob, blob)
    note("NEG_tautological_same_path", 0 if taut else 1, 0, taut or "missed")
    try:
        blob.unlink(missing_ok=True)
    except OSError:
        pass

    # --- Corpus POS: selection with non-dev ---
    man = {
        "schema": "misterplex.decoder_corpus.v1",
        "dev_fixture_ids": ["dev_a"],
        "min_non_dev_when_claiming": 1,
        "pool": [
            {"id": "dev_a", "path": "tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264",
             "tags": ["dev"], "kind": "annexb", "width": 320, "height": 240},
            {"id": "inter_320", "path": "tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264",
             "tags": ["inter"], "kind": "annexb", "width": 320, "height": 240},
            {"id": "planes_i420", "path": "tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv",
             "tags": ["i420"], "kind": "i420", "width": 320, "height": 240},
        ],
    }
    # Find a seed that includes non-dev when k=2
    pos_seed = None
    for s in range(0, 5000):
        sel = select_subjects(man, seed=s, k=2, require_non_dev=False)
        if not sel.dev_only:
            pos_seed = s
            break
    if pos_seed is None:
        note("POS_corpus_non_dev", 1, 0, "could not find seed")
    else:
        sel = select_subjects(man, seed=pos_seed, k=2, require_non_dev=True)
        miss = paths_exist(root, sel)
        note(
            "POS_corpus_non_dev",
            0 if (not sel.dev_only and not miss) else 1,
            0,
            f"seed={sel.seed} ids={[x.id for x in sel.selected]} missing={miss}",
        )

    # --- Corpus NEG: force dev-only under require_non_dev ---
    # pool where only dev exists when k=1 and only pick dev
    man_dev = {
        "schema": "misterplex.decoder_corpus.v1",
        "dev_fixture_ids": ["dev_a", "dev_b"],
        "pool": [
            {"id": "dev_a", "path": "tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264",
             "kind": "annexb"},
            {"id": "dev_b", "path": "tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264",
             "kind": "annexb"},
        ],
    }
    try:
        select_subjects(man_dev, seed=1, k=1, require_non_dev=True)
        note("NEG_corpus_dev_only_claim", 1, 0, "should have raised")
    except RuntimeError as e:
        note("NEG_corpus_dev_only_claim", 0, 0, str(e)[:80])

    # --- Coverage POS: honest incomplete ---
    led_pos = {
        "schema": "misterplex.decoder_coverage.v1",
        "stages": {
            "cavlc": {
                "claimed_complete": False,
                "rtl_modules": [],
                "features": {
                    "coeff_token": {
                        "capability": "CAVLC coeff_token table decode",
                        "status": "unproven",
                        "evidence": "",
                    }
                },
            }
        },
    }
    rc, _ = check_coverage_claims(led_pos)
    note("POS_coverage_honest_incomplete", rc, 0)

    # --- Coverage NEG: claimed complete + empty features (runtime-assembled) ---
    led_neg_empty = {
        "schema": "misterplex.decoder_coverage.v1",
        "stages": {
            "intra": {
                "claimed_complete": True,
                "rtl_modules": ["h264_intra_pred"],
                "features": {},
            }
        },
    }
    rc, msgs = check_coverage_claims(led_neg_empty)
    note("NEG_coverage_empty_complete", rc, 1, msgs[-1] if msgs else "")

    # --- Coverage NEG: claimed complete + unproven feature ---
    led_neg_unp = {
        "schema": "misterplex.decoder_coverage.v1",
        "stages": {
            "idct": {
                "claimed_complete": True,
                "rtl_modules": ["h264_iq_idct_4x4"],
                "features": {
                    "idct4x4": {
                        "capability": "4x4 integer inverse transform",
                        "status": "unproven",
                        "evidence": "",
                    }
                },
            }
        },
    }
    rc, _ = check_coverage_claims(led_neg_unp)
    note("NEG_coverage_unproven_complete", rc, 1)

    # --- Reachability POS: empty claims on live tree ---
    rc, msgs = check_claimed_decoder_modules(
        root, [], prefit_config=json.loads((root / "tests/fixtures/critical_prefit_reachability.json").read_text()),
        scripts_dir=root / "scripts",
    )
    note("POS_reachability_empty_claims", rc, 0)

    # --- Reachability NEG: claim a known teeth/PRUNED module (runtime claim list) ---
    # Do not hardcode as a "definition site" in fixtures — assemble claim here.
    teeth_mod = "h264_cavlc_residual_block"  # known QIP-then-prune class
    pref = json.loads((root / "tests/fixtures/critical_prefit_reachability.json").read_text())
    rc, msgs = check_claimed_decoder_modules(
        root,
        [teeth_mod],
        prefit_config=pref,
        scripts_dir=root / "scripts",
    )
    detail = next((m for m in msgs if "STATUS=" in m and teeth_mod in m), msgs[-1] if msgs else "")
    note("NEG_reachability_claim_pruned_h264", rc, 1, detail)

    # --- Live product gate must PASS today (no false completeness / empty claims) ---
    import io
    from contextlib import redirect_stdout

    ns = argparse.Namespace(
        root=str(root),
        ledger=str(root / "tests/fixtures/decoder_conformance/coverage_ledger.json"),
        manifest=str(root / "tests/fixtures/decoder_conformance/corpus_manifest.json"),
        prefit_config=str(root / "tests/fixtures/critical_prefit_reachability.json"),
        seed=42,
        k=2,
        selection_out="",
    )
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc_live = cmd_gate(ns)
    out_live = buf.getvalue()
    print(out_live.rstrip())
    note("POS_live_gate_no_claims", rc_live, 0)

    if failures:
        print("FAIL decoder_conformance self-test:")
        for f in failures:
            print(f"  {f}")
        return 1
    print("PASS decoder_conformance self-test")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=str(ROOT_DEFAULT))
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="Run POS/NEG harness controls (no device, no fit)",
    )
    ap.add_argument(
        "--gate",
        action="store_true",
        help="Run full decoder conformance gate on product fixtures",
    )
    ap.add_argument("--ledger", default=str(DEFAULT_COVERAGE))
    ap.add_argument("--manifest", default=str(DEFAULT_CORPUS))
    ap.add_argument("--prefit-config", default=str(DEFAULT_PREFIT))
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--k", type=int, default=2)
    ap.add_argument("--selection-out", default="")
    sub = ap.add_subparsers(dest="cmd")

    def add_root(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--root", default=str(ROOT_DEFAULT))

    p_cmp = sub.add_parser("compare", help="Bit-exact ARM vs RTL blob compare")
    add_root(p_cmp)
    p_cmp.add_argument("--arm", required=True)
    p_cmp.add_argument("--rtl", required=True)
    p_cmp.add_argument("--format", choices=("i420", "raw"), default="i420")
    p_cmp.add_argument("--width", type=int, default=0)
    p_cmp.add_argument("--height", type=int, default=0)
    p_cmp.add_argument("--stage", default="")

    p_sel = sub.add_parser("select-corpus", help="Runtime corpus selection + seed record")
    add_root(p_sel)
    p_sel.add_argument("--manifest", default=str(DEFAULT_CORPUS))
    p_sel.add_argument("--seed", type=int, default=None)
    p_sel.add_argument("--k", type=int, default=2)
    p_sel.add_argument("--seed-out", default="")
    p_sel.add_argument("--selection-out", default="")
    p_sel.add_argument("--require-non-dev", action="store_true")

    p_cov = sub.add_parser("coverage", help="Check coverage ledger claims")
    add_root(p_cov)
    p_cov.add_argument("--ledger", default=str(DEFAULT_COVERAGE))

    p_r = sub.add_parser("reachability", help="Claimed decoder module REACHABILITY")
    add_root(p_r)
    p_r.add_argument("--ledger", default="")
    p_r.add_argument("--modules", nargs="*", default=[])
    p_r.add_argument("--prefit-config", default=str(DEFAULT_PREFIT))

    args = ap.parse_args(argv)
    root = Path(args.root).resolve()

    if args.self_test:
        return _self_test(root)
    if args.gate or args.cmd is None:
        # default invocation = full gate
        if args.cmd is None or args.gate:
            return cmd_gate(args)

    if args.cmd == "compare":
        return cmd_compare(args)
    if args.cmd == "select-corpus":
        return cmd_select_corpus(args)
    if args.cmd == "coverage":
        return cmd_coverage(args)
    if args.cmd == "reachability":
        return cmd_reachability(args)

    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
