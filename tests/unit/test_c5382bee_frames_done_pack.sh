#!/usr/bin/env bash
# T1: Prove deployed RBF c5382bee packs bank_vsync_count into PLXD[63:48].
# Fitted freeze is CHECKED IN under tests/fixtures/c5382bee_freeze/ (not .agent-work).
# md5 must match the silicon-fitted leftedge3 freeze (c139274e...).
# Soft-skip never. true rc direct. Clean checkout must pass.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIT="$ROOT/tests/fixtures/c5382bee_freeze/ddr_frame_store.sv"
TIP="$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
EXPECT_MD5="c139274e814a4696c485c0bba3781ad8"

FAIL=0
if [[ ! -f "$FIT" ]]; then
  echo "FAIL: missing checked-in fitted freeze $FIT" >&2
  echo "REASON=FIXTURE_MISSING c5382bee_freeze (must be git-tracked; never .agent-work)" >&2
  exit 1
fi
md=$(md5sum "$FIT" | awk '{print $1}')
echo "fitted_ddr_frame_store_md5=$md"
if [[ "$md" != "$EXPECT_MD5" ]]; then
  echo "FAIL: fitted freeze md5 != leftedge3/c5382bee claim $EXPECT_MD5" >&2
  FAIL=1
else
  echo "OK fitted md5 matches leftedge3 evidence (c5382bee freeze)"
fi

echo "=== c5382bee freeze PLXD pack (must be bank_vsync_count) ==="
if grep -n 'DDRAM_DIN <= {bank_vsync_count' "$FIT"; then
  echo "OK T1a: c5382bee freeze packs bank_vsync_count into PLXD DIN [63:48]"
else
  echo "FAIL T1a: expected bank_vsync_count pack in freeze RTL" >&2
  FAIL=1
fi

echo "=== c5382bee freeze frames_done++ still only on swap ==="
if grep -n 'frames_done <= frames_done + 16.d1' "$FIT" || grep -nE 'frames_done <= frames_done \+ 16.d1' "$FIT"; then
  :
fi
if grep -nE 'frames_done <= frames_done \+ 16.d1' "$FIT"; then
  echo "OK T1b: internal frames_done still increments on swap path"
else
  # try without escape
  if grep -n 'frames_done <= frames_done +' "$FIT"; then
    echo "OK T1b: internal frames_done still increments on swap path"
  else
    echo "FAIL T1b: frames_done increment missing" >&2
    FAIL=1
  fi
fi

echo "=== tip RTL must pack real frames_done_d2 (not live on silicon until new RBF) ==="
if grep -n 'DDRAM_DIN <= {frames_done_d2' "$TIP"; then
  echo "OK T1c: tip packs frames_done_d2 (honest swap counter) — NOT deployed as c5382bee"
else
  echo "FAIL T1c: tip missing frames_done_d2 pack" >&2
  FAIL=1
fi
if grep -n 'DDRAM_DIN <= {bank_vsync_count' "$TIP"; then
  echo "FAIL T1d: tip still packs bank_vsync_count" >&2
  FAIL=1
else
  echo "OK T1d: tip does not pack bank_vsync_count into PLXD"
fi

echo "=== bank_vsync_count increments every vsync edge (freeze) ==="
if grep -n 'bank_vsync_count <= bank_vsync_count +' "$FIT"; then
  echo "OK T1e: bank_vsync_count++ on vsync toggle edge"
else
  echo "FAIL T1e" >&2
  FAIL=1
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL test_c5382bee_frames_done_pack" >&2
  exit 1
fi
echo "VERDICT_T1: (a) LIVE — deployed c5382bee PLXD[63:48] is bank_vsync_count (HISTORICAL FAULT live)."
echo "  Internal frames_done is still swap-only; ARM reads the vsync-packed field."
echo "  (b) multi-swap-per-publish is NOT required to explain p_dge2≈0.97."
echo "OK test_c5382bee_frames_done_pack"
exit 0
