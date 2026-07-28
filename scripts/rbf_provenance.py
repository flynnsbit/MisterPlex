#!/usr/bin/env python3
"""Record and resolve Plex.rbf provenance.

A bitstream on an SD card carries no identity of its own. The lab has already
been bitten by this: ``/media/fat/Plex_20260727.rbf`` and
``/media/fat/_Utility/Plex.rbf`` were different builds, and the one that was
actually loaded could only be told apart by md5 against a build nobody had
kept. ``record`` writes the md5 of a freshly fitted RBF next to the BUILD_ID
that was baked into its CONF_STR ``V`` entry; ``resolve`` answers "which source
produced the bitstream with this md5?".

An md5 that is not in the ledger is a hard FAIL, not a shrug: an untraceable
bitstream is exactly the state that makes every downstream pixel claim
unfalsifiable.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "fpga" / "Plex_MiSTer" / "rbf_provenance.jsonl"
RC_FAIL = 1
RC_USAGE = 2

SCOPE = (
    "Scope: joins an RBF file md5 to the BUILD_ID/commit that produced it, using a "
    "ledger appended at fit time. It does not prove the bitstream is loaded in the "
    "FPGA, that the OSD renders the id, or that the build works."
)


def file_digests(path: Path) -> tuple[str, str, int]:
    data = path.read_bytes()
    return hashlib.md5(data).hexdigest(), hashlib.sha256(data).hexdigest(), len(data)


def load_ledger(ledger: Path) -> list[dict]:
    if not ledger.is_file():
        return []
    rows: list[dict] = []
    for line in ledger.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


def cmd_record(args: argparse.Namespace) -> int:
    rbf = Path(args.rbf)
    if not rbf.is_file():
        print(f"RBF_PROVENANCE_RESULT=FAIL reason=rbf-missing path={rbf}")
        return RC_FAIL
    md5, sha256, size = file_digests(rbf)
    entry = {
        "md5": md5,
        "sha256": sha256,
        "bytes": size,
        "build_id": args.build_id,
        "git": args.git,
        "src_full": args.src_full,
        "slot": args.slot,
        "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    ledger = Path(args.ledger)
    ledger.parent.mkdir(parents=True, exist_ok=True)
    existing = {row.get("md5") for row in load_ledger(ledger)}
    if md5 not in existing:
        with ledger.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, sort_keys=True) + "\n")
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(entry, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"RBF_PROVENANCE_RESULT=RECORDED md5={md5} build_id={args.build_id}"
        f" git={args.git} bytes={size} ledger={ledger}"
    )
    return 0


def cmd_resolve(args: argparse.Namespace) -> int:
    if args.rbf:
        rbf = Path(args.rbf)
        if not rbf.is_file():
            print(f"RBF_PROVENANCE_RESULT=FAIL reason=rbf-missing path={rbf}")
            return RC_FAIL
        md5 = file_digests(rbf)[0]
    elif args.md5:
        md5 = args.md5.strip().lower()
    else:
        print("RBF_PROVENANCE_RESULT=FAIL reason=no-operand (pass --rbf or --md5)")
        return RC_USAGE

    rows = [row for row in load_ledger(Path(args.ledger)) if row.get("md5") == md5]
    if not rows:
        print(
            f"RBF_PROVENANCE_RESULT=FAIL reason=untraceable-bitstream md5={md5}"
            f" ledger={args.ledger} ledger_entries={len(load_ledger(Path(args.ledger)))}"
        )
        return RC_FAIL
    row = rows[-1]
    if args.expect_build_id and row.get("build_id") != args.expect_build_id:
        print(
            f"RBF_PROVENANCE_RESULT=FAIL reason=build-id-mismatch md5={md5}"
            f" ledger_build_id={row.get('build_id')} expected={args.expect_build_id}"
        )
        return RC_FAIL
    print(
        f"RBF_PROVENANCE_RESULT=OK md5={md5} build_id={row.get('build_id')}"
        f" git={row.get('git')} slot={row.get('slot')} utc={row.get('utc')}"
    )
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Record/resolve Plex.rbf provenance.")
    ap.add_argument("--ledger", default=str(DEFAULT_LEDGER), help="provenance ledger (jsonl)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    rec = sub.add_parser("record", help="append an RBF md5 -> BUILD_ID entry")
    rec.add_argument("--rbf", required=True)
    rec.add_argument("--build-id", required=True)
    rec.add_argument("--git", default="")
    rec.add_argument("--src-full", default="")
    rec.add_argument("--slot", default="")
    rec.add_argument("--out", default="", help="also write this single entry as JSON")
    rec.set_defaults(func=cmd_record)

    res = sub.add_parser("resolve", help="look an RBF md5 up in the ledger")
    res.add_argument("--rbf", default="")
    res.add_argument("--md5", default="")
    res.add_argument("--expect-build-id", default="")
    res.set_defaults(func=cmd_resolve)

    args = ap.parse_args(argv)
    print(SCOPE)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
