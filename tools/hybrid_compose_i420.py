#!/usr/bin/env python3
"""Compose a hybrid I420 candidate from FPGA + host planes under an ownership map.

P3-3l5 product handoff (docs/phase3-3l-idct.md §3.3l-5):
  STREAM may skip host F1 only when FPGA recon_ok on a pure FPGA-owned picture.
  Host fallback on CABAC / fail. Unsupported MBs must be detectably host-owned.

This tool builds the composite frame the product path would present when the
FPGA reconstructs only the MBs it owns and the ARM/host supplies the rest.
It does NOT score — call tools/score_i420_candidate.py on the result so
colorspace / loop-filter refusals stay authoritative.

Ownership map format: misterplex.p3.hybrid_own_map.v1
  owner: "fpga" | "host" per MB (frame_index, mb_index)
  product_recon_ok may be true only if every MB is fpga-owned.

Silent FPGA claim of a host MB is the dangerous failure mode the gate red-checks.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


FORMAT = "misterplex.p3.hybrid_own_map.v1"
OWN_FPGA = "fpga"
OWN_HOST = "host"


class HybridComposeError(Exception):
    pass


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def frame_bytes(width: int, height: int) -> int:
    return width * height * 3 // 2


def copy_mb(
    dst: bytearray,
    src: bytes,
    frame: int,
    width: int,
    height: int,
    mb_x: int,
    mb_y: int,
) -> None:
    y_base = frame * frame_bytes(width, height)
    u_base = y_base + width * height
    v_base = u_base + (width // 2) * (height // 2)
    for yy in range(16):
        y = mb_y * 16 + yy
        row = y_base + y * width + mb_x * 16
        dst[row : row + 16] = src[row : row + 16]
    cw = width // 2
    for yy in range(8):
        y = mb_y * 8 + yy
        urow = u_base + y * cw + mb_x * 8
        vrow = v_base + y * cw + mb_x * 8
        dst[urow : urow + 8] = src[urow : urow + 8]
        dst[vrow : vrow + 8] = src[vrow : vrow + 8]


def zero_plane(dst: bytearray, frame: int, width: int, height: int, plane: str) -> None:
    """Mutation helper: drop one plane of a frame (detectable composite failure)."""
    y_base = frame * frame_bytes(width, height)
    y_count = width * height
    c_count = (width // 2) * (height // 2)
    if plane == "Y":
        for i in range(y_count):
            dst[y_base + i] = 0
    elif plane == "U":
        base = y_base + y_count
        for i in range(c_count):
            dst[base + i] = 0
    elif plane == "V":
        base = y_base + y_count + c_count
        for i in range(c_count):
            dst[base + i] = 0
    else:
        raise HybridComposeError(f"unknown plane {plane}")


def load_own_map(path: Path, width: int, height: int, n_frames: int) -> dict[tuple[int, int], str]:
    data = read_json(path)
    if data.get("format") != FORMAT:
        raise HybridComposeError(f"ownership map format is {data.get('format')!r}, want {FORMAT}")
    geom = data.get("geometry", {})
    if int(geom.get("width", width)) != width or int(geom.get("height", height)) != height:
        raise HybridComposeError("ownership map geometry does not match planes")
    mb_w = width // 16
    mb_h = height // 16
    out: dict[tuple[int, int], str] = {}
    for fr in data.get("frames", []):
        fidx = int(fr["frame_index"])
        if fidx < 0 or fidx >= n_frames:
            raise HybridComposeError(f"ownership map frame_index {fidx} out of range")
        for mb in fr.get("macroblocks", []):
            mb_index = int(mb.get("mb_index", int(mb["mb_y"]) * mb_w + int(mb["mb_x"])))
            owner = str(mb.get("owner", "")).lower()
            if owner not in (OWN_FPGA, OWN_HOST):
                raise HybridComposeError(f"invalid owner {owner!r} at frame={fidx} mb={mb_index}")
            out[(fidx, mb_index)] = owner
        # Optional dense bitmap: owners[mb] = "fpga"/"host" for whole frame
        if "owners" in fr:
            owners = fr["owners"]
            if len(owners) != mb_w * mb_h:
                raise HybridComposeError(
                    f"frame {fidx} owners length {len(owners)} != {mb_w * mb_h}"
                )
            for mb_index, owner in enumerate(owners):
                o = str(owner).lower()
                if o not in (OWN_FPGA, OWN_HOST):
                    raise HybridComposeError(f"invalid dense owner {o!r}")
                out[(fidx, mb_index)] = o
    # Fail closed: every MB must be classified — unmarked is not silent FPGA.
    missing = []
    for fidx in range(n_frames):
        for mb_index in range(mb_w * mb_h):
            if (fidx, mb_index) not in out:
                missing.append((fidx, mb_index))
    if missing:
        f0, m0 = missing[0]
        raise HybridComposeError(
            f"ownership map incomplete: first missing frame={f0} mb={m0} "
            f"(count={len(missing)}). Unmarked MB must not default to FPGA."
        )
    return out


def compose(
    fpga: bytes,
    host: bytes,
    width: int,
    height: int,
    n_frames: int,
    own: dict[tuple[int, int], str],
    *,
    force_unmarked_as_fpga: bool = False,
    drop_plane: str | None = None,
    drop_frame: int = 0,
) -> tuple[bytearray, dict[str, Any]]:
    if len(fpga) != len(host):
        raise HybridComposeError(f"fpga size {len(fpga)} != host size {len(host)}")
    fb = frame_bytes(width, height)
    if len(fpga) != n_frames * fb:
        raise HybridComposeError("plane size does not match geometry/frame count")
    mb_w = width // 16
    mb_h = height // 16
    dst = bytearray(host)  # start from host; overwrite FPGA-owned MBs
    fpga_mbs = 0
    host_mbs = 0
    for fidx in range(n_frames):
        for mby in range(mb_h):
            for mbx in range(mb_w):
                mb_index = mby * mb_w + mbx
                owner = own.get((fidx, mb_index))
                if owner is None:
                    if force_unmarked_as_fpga:
                        owner = OWN_FPGA  # mutation: silent FPGA claim
                    else:
                        raise HybridComposeError(
                            f"unmarked MB frame={fidx} mb={mb_index} (fail closed)"
                        )
                if owner == OWN_FPGA:
                    copy_mb(dst, fpga, fidx, width, height, mbx, mby)
                    fpga_mbs += 1
                else:
                    # already host
                    host_mbs += 1
    if drop_plane:
        zero_plane(dst, drop_frame, width, height, drop_plane)
    total = fpga_mbs + host_mbs
    product_recon_ok = host_mbs == 0 and total > 0
    summary = {
        "format": "misterplex.p3.hybrid_compose.v1",
        "geometry": {"width": width, "height": height, "frames": n_frames},
        "fpga_mb": fpga_mbs,
        "host_mb": host_mbs,
        "total_mb": total,
        "fpga_fraction": (fpga_mbs / total) if total else 0.0,
        "product_recon_ok": product_recon_ok,
        "force_unmarked_as_fpga": force_unmarked_as_fpga,
        "drop_plane": drop_plane,
    }
    return dst, summary


def build_default_own_map(
    width: int,
    height: int,
    frame_kinds: list[str],
    *,
    claim_inter_as_fpga: bool = False,
) -> dict[str, Any]:
    """Default P3-3l5 map: I-frames all FPGA, P-frames all host (CAP_INTER_*=0)."""
    mb_w = width // 16
    mb_h = height // 16
    frames = []
    for fidx, kind in enumerate(frame_kinds):
        if kind == "I" or (kind == "P" and claim_inter_as_fpga):
            owners = [OWN_FPGA] * (mb_w * mb_h)
        else:
            owners = [OWN_HOST] * (mb_w * mb_h)
        frames.append({"frame_index": fidx, "slice_kind": kind, "owners": owners})
    return {
        "format": FORMAT,
        "geometry": {"width": width, "height": height},
        "capability": {
            "CAP_INTRA_I4": 1,
            "CAP_INTRA_I16": 1,
            "CAP_INTER_PSKIP": 1 if claim_inter_as_fpga else 0,
            "CAP_INTER_P16": 1 if claim_inter_as_fpga else 0,
            "CAP_CABAC": 0,
            "note": "Grows as sv-mvd/sv-resadd/sv-ref/sv-traverse land without contract change",
        },
        "frames": frames,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fpga-planes", required=True, help="FPGA candidate I420")
    ap.add_argument("--host-planes", required=True, help="ARM/host I420 (or golden host recon)")
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--frames", type=int, required=True)
    ap.add_argument("--own-map", help="misterplex.p3.hybrid_own_map.v1 JSON")
    ap.add_argument(
        "--default-map-from-kinds",
        help="comma-separated slice kinds per frame (I,P,...) to synthesize default map",
    )
    ap.add_argument("--write-own-map", help="write synthesized/used ownership map JSON")
    ap.add_argument("--output", required=True, help="composed hybrid I420 path")
    ap.add_argument("--summary", help="write compose summary JSON")
    ap.add_argument(
        "--force-unmarked-as-fpga",
        action="store_true",
        help="MUTATION: treat missing ownership as FPGA (must make gate red)",
    )
    ap.add_argument(
        "--claim-inter-as-fpga",
        action="store_true",
        help="MUTATION when synthesizing default map: mark P MBs as FPGA-owned",
    )
    ap.add_argument("--drop-plane", choices=("Y", "U", "V"), help="MUTATION: zero one plane")
    ap.add_argument("--drop-frame", type=int, default=0)
    args = ap.parse_args()

    width, height, n_frames = args.width, args.height, args.frames
    if width % 16 or height % 16:
        raise SystemExit("width/height must be multiples of 16")

    fpga = Path(args.fpga_planes).read_bytes()
    host = Path(args.host_planes).read_bytes()

    if args.own_map:
        own_path = Path(args.own_map)
        own_doc = read_json(own_path)
        if args.force_unmarked_as_fpga:
            # Prefer first non-I frame so silent FPGA claim is observable against a
            # defective FPGA plane; fall back to last frame.
            fr0 = None
            for fr in own_doc.get("frames", []):
                if str(fr.get("slice_kind", "I")).upper() != "I":
                    fr0 = fr
                    break
            if fr0 is None and own_doc.get("frames"):
                fr0 = own_doc["frames"][-1]
            if fr0 is not None:
                if "owners" in fr0 and fr0["owners"]:
                    fr0["owners"] = fr0["owners"][:-1]  # drop last → incomplete
                elif "macroblocks" in fr0 and fr0["macroblocks"]:
                    fr0["macroblocks"] = fr0["macroblocks"][:-1]
            tmp = Path(args.output).with_suffix(".mut_own.json")
            tmp.write_text(json.dumps(own_doc, indent=2) + "\n", encoding="utf-8")
            try:
                own = load_own_map(tmp, width, height, n_frames)
            except HybridComposeError:
                own = {}  # incomplete — compose path uses force flag
            # Rebuild sparse own from remaining
            own = {}
            mb_w = width // 16
            mb_h = height // 16
            for fr in own_doc.get("frames", []):
                fidx = int(fr["frame_index"])
                if "owners" in fr:
                    for i, o in enumerate(fr["owners"]):
                        own[(fidx, i)] = str(o).lower()
                for mb in fr.get("macroblocks", []):
                    mi = int(mb.get("mb_index", int(mb["mb_y"]) * mb_w + int(mb["mb_x"])))
                    own[(fidx, mi)] = str(mb["owner"]).lower()
        else:
            own = load_own_map(own_path, width, height, n_frames)
            own_doc = read_json(own_path)
    elif args.default_map_from_kinds:
        kinds = [k.strip().upper() for k in args.default_map_from_kinds.split(",") if k.strip()]
        if len(kinds) != n_frames:
            raise SystemExit(f"kinds count {len(kinds)} != frames {n_frames}")
        own_doc = build_default_own_map(
            width, height, kinds, claim_inter_as_fpga=args.claim_inter_as_fpga
        )
        if args.write_own_map:
            Path(args.write_own_map).write_text(json.dumps(own_doc, indent=2) + "\n", encoding="utf-8")
        # materialize
        tmp = Path(args.output).with_suffix(".own.json")
        tmp.write_text(json.dumps(own_doc, indent=2) + "\n", encoding="utf-8")
        if args.force_unmarked_as_fpga:
            # drop one owner entry
            own_doc["frames"][0]["owners"] = own_doc["frames"][0]["owners"][:-1]
            own = {}
            for fr in own_doc["frames"]:
                fidx = int(fr["frame_index"])
                for i, o in enumerate(fr.get("owners", [])):
                    own[(fidx, i)] = str(o).lower()
        else:
            own = load_own_map(tmp, width, height, n_frames)
    else:
        raise SystemExit("provide --own-map or --default-map-from-kinds")

    if args.write_own_map and not args.default_map_from_kinds:
        Path(args.write_own_map).write_text(json.dumps(own_doc, indent=2) + "\n", encoding="utf-8")

    dst, summary = compose(
        fpga,
        host,
        width,
        height,
        n_frames,
        own,
        force_unmarked_as_fpga=args.force_unmarked_as_fpga,
        drop_plane=args.drop_plane,
        drop_frame=args.drop_frame,
    )
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_bytes(bytes(dst))
    if args.summary:
        Path(args.summary).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(
        "HYBRID_COMPOSE "
        f"fpga_mb={summary['fpga_mb']}/{summary['total_mb']} "
        f"host_mb={summary['host_mb']}/{summary['total_mb']} "
        f"fpga_fraction={summary['fpga_fraction']:.6f} "
        f"product_recon_ok={1 if summary['product_recon_ok'] else 0}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HybridComposeError as e:
        print(f"hybrid_compose_i420: {e}", file=sys.stderr)
        raise SystemExit(2)
