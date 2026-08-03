#!/usr/bin/env bash
# I-frame (bitstream frame 0) disabled vs enabled loop-filter gap gate.
#
# Pre-register (before first measure; now locked in manifest expected_gap):
#   P1: disabled ≠ enabled on frame 0.
#   P2: chroma exact (U/V mismatch 0) — pure luma edge filter delta on this IDR.
#   P3: Y mism << cascaded 8f P-slice gap; mb_exact near full frame.
#   P4: Vacuity — identical buffers must not satisfy expected_gap.
# Miss published if re-measure drifts: update manifest only with fresh ffmpeg evidence.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MANIFEST="tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1f_i420_deblock_gap_v1.json"
DIS="tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1f_i420_disabled.yuv"
EN="tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1f_i420_enabled.yuv"

for f in "$MANIFEST" "$DIS" "$EN"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL deblock_iframe_gap: missing $f" >&2
    exit 2
  fi
done

score_gap() {
  local dis_path="$1"
  local en_path="$2"
  python3 - "$dis_path" "$en_path" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

dis_path = Path(sys.argv[1])
en_path = Path(sys.argv[2])
W, H = 624, 480
YB = W * H
CB = (W // 2) * (H // 2)
FB = YB + 2 * CB
MB_W, MB_H = W // 16, H // 16

manifest = json.loads(
    Path("tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1f_i420_deblock_gap_v1.json").read_text()
)
if manifest.get("format") != "misterplex.derived_h264_i420_iframe_deblock_gap.v1":
    print("FAIL deblock_iframe_gap: bad format marker", file=sys.stderr)
    sys.exit(1)

def load(path: Path, meta_key: str | None) -> bytes:
    data = path.read_bytes()
    if len(data) != FB:
        print(f"FAIL deblock_iframe_gap: {path} bytes got={len(data)} want={FB}", file=sys.stderr)
        sys.exit(1)
    if meta_key is not None:
        meta = manifest[meta_key]
        if len(data) != meta["bytes"]:
            print(
                f"FAIL deblock_iframe_gap: {meta_key} bytes got={len(data)} want={meta['bytes']}",
                file=sys.stderr,
            )
            sys.exit(1)
        digest = hashlib.sha256(data).hexdigest()
        if digest != meta["sha256"]:
            print(
                f"FAIL deblock_iframe_gap: {meta_key} sha256 got={digest} want={meta['sha256']}",
                file=sys.stderr,
            )
            sys.exit(1)
    return data

# Only enforce committed digests for the real fixture paths.
dis_meta = "disabled" if dis_path.as_posix() == manifest["disabled"]["path"] else None
en_meta = "enabled" if en_path.as_posix() == manifest["enabled"]["path"] else None
dis = load(dis_path, dis_meta)
en = load(en_path, en_meta)

if dis == en:
    print(
        "FAIL deblock_iframe_gap: disabled and enabled I-frame buffers are identical (gap vacuous)",
        file=sys.stderr,
    )
    sys.exit(1)

def plane_mism(a: bytes, b: bytes, off: int, n: int) -> tuple[int, int]:
    mism = 0
    max_abs = 0
    for i in range(n):
        da = a[off + i]
        db = b[off + i]
        if da != db:
            mism += 1
            d = abs(da - db)
            if d > max_abs:
                max_abs = d
    return mism, max_abs

y_m, y_max = plane_mism(dis, en, 0, YB)
u_m, _ = plane_mism(dis, en, YB, CB)
v_m, _ = plane_mism(dis, en, YB + CB, CB)

mb_exact = 0
bad_mbs = []
for my in range(MB_H):
    for mx in range(MB_W):
        ok = True
        for sy in range(16):
            row = (my * 16 + sy) * W + mx * 16
            if dis[row : row + 16] != en[row : row + 16]:
                ok = False
                break
        if ok:
            for sy in range(8):
                row_u = YB + (my * 8 + sy) * (W // 2) + mx * 8
                row_v = YB + CB + (my * 8 + sy) * (W // 2) + mx * 8
                if dis[row_u : row_u + 8] != en[row_u : row_u + 8] or dis[row_v : row_v + 8] != en[row_v : row_v + 8]:
                    ok = False
                    break
        if ok:
            mb_exact += 1
        else:
            bad_mbs.append([mx, my])

exp = manifest["expected_gap"]
want = (
    exp["y_mismatch_samples"],
    exp["u_mismatch_samples"],
    exp["v_mismatch_samples"],
    exp["y_max_abs"],
    exp["mb_exact"],
    exp["mb_total"],
)
got = (y_m, u_m, v_m, y_max, mb_exact, MB_W * MB_H)
if got != want:
    print(
        f"FAIL deblock_iframe_gap: gap shape got y/u/v/max/mb_exact/mb_total={got} want={want}",
        file=sys.stderr,
    )
    sys.exit(1)

want_mbs = sorted(tuple(x) for x in exp["mismatch_mb_xy"])
got_mbs = sorted(tuple(x) for x in bad_mbs)
if got_mbs != want_mbs:
    print(
        f"FAIL deblock_iframe_gap: mismatch MBs got={bad_mbs} want={exp['mismatch_mb_xy']}",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    "DEBLOCK_IFRAME_GAP bitstream_frame0 "
    f"y_mism={y_m}/{YB} u_mism={u_m}/{CB} v_mism={v_m}/{CB} "
    f"y_max_abs={y_max} mb_exact={mb_exact}/{MB_W * MB_H} "
    f"mismatch_mbs={bad_mbs} "
    "note=pure_filter_delta_before_temporal_cascade"
)
print(
    "OK deblock_iframe_gap: I-frame0 disabled vs enabled gap is small/edge-local "
    f"(Y mism={y_m}, chroma exact, mb_exact={mb_exact}/{MB_W * MB_H}); "
    "cascaded 8f P-slice gap remains large and separate"
)
sys.exit(0)
PY
}

score_gap "$DIS" "$EN"

# RED: enabled path replaced by disabled bytes must not pass.
VAC_DIR=".copilot-w-inter2/deblock_iframe_gap_vacuous"
mkdir -p "$VAC_DIR"
cp -f "$DIS" "$VAC_DIR/enabled_is_disabled.yuv"
set +e
VAC_OUT="$(score_gap "$DIS" "$VAC_DIR/enabled_is_disabled.yuv" 2>&1)"
VAC_RC=$?
set -e
printf '%s\n' "$VAC_OUT"
if [[ "$VAC_RC" -eq 0 ]]; then
  echo "FAIL deblock_iframe_gap: vacuous disabled-as-enabled returned rc=0" >&2
  exit 1
fi
if ! grep -q 'identical (gap vacuous)\|gap shape got' <<<"$VAC_OUT"; then
  echo "FAIL deblock_iframe_gap: vacuous path did not name the defect" >&2
  printf '%s\n' "$VAC_OUT" >&2
  exit 1
fi
echo "OK deblock_iframe_gap red-check: disabled-as-enabled rejected (rc=$VAC_RC)"
rm -f "$VAC_DIR/enabled_is_disabled.yuv"
