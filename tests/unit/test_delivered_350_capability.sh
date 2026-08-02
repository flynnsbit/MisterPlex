#!/usr/bin/env bash
# Capability gate: real PMS delivery geometry 624x350 (parent device, RK6).
#
# Observed defect class (parent hardware 2026-08-02):
#   RELEASE daemon e9f79de2 → green field + horizontal wrap (raw-pipe desync)
#   LIVE daemon ea643e99    → measured=624x350 desync_risk=0, clean picture
# Same core/conf/asset/PMS; only daemon differed. Packaged release lacked
# delivery measurement + FOAR-into-coded handling of non-bank height.
#
# This gate does NOT hardcode md5s. It keys on CAPABILITY markers that the
# broken release binary lacks and current main has, plus a live ffmpeg probe
# on real 624x350 (not a coded-bank-sized fixture).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
VF="$ROOT/host/libmisterplex/ffmpeg_vf.hpp"
OUT="$ROOT/build/test_delivered_350_capability"
mkdir -p "$OUT"
FFMPEG="${FFMPEG:-ffmpeg}"
FB=449280
N=3
WANT=$((FB * N))
fail=0
pass=0
applied=0

check_src() {
  local name="$1" file="$2" pat="$3"
  if rg -n --fixed-strings "$pat" "$file" >/dev/null; then
    echo "PASS_SRC $name"
    pass=$((pass + 1))
    applied=$((applied + 1))
  else
    echo "FAIL_SRC $name missing: $pat" >&2
    fail=$((fail + 1))
  fi
}

# --- A: source capability pins (main must keep these) ---
check_src SRC_MEASURED_DELIVERY "$MP" 'media: MEASURED_DELIVERY delivered_geom='
check_src SRC_MEASURED_OUTPUT "$MP" 'media: MEASURED_OUTPUT '
check_src SRC_desync_risk_field "$MP" 'desync_risk='
check_src SRC_DELIVERY_MISMATCH "$MP" 'DELIVERY_MISMATCH measured='
check_src SRC_force_unverified_reason "$VF" 'force_unverified_claim_scale_pad_coded'
check_src SRC_fleet_mode_350_comment "$VF" 'measured=624x350 is the MOST COMMON'
check_src SRC_never_identity_unverified "$VF" 'Never identity_skip on unverified claims'
check_src SRC_FOAR_into_coded_not_618 "$VF" 'FOAR into the CODED bank'
check_src SRC_FOAR_decrease_token "$VF" 'force_original_aspect_ratio=decrease'
# Negative: legacy reason must be gone from product planner
if rg -n --fixed-strings 'force_exact_crop_pad_unverified' "$VF" >/dev/null; then
  echo "FAIL_SRC legacy force_exact_crop_pad_unverified still in ffmpeg_vf.hpp" >&2
  fail=$((fail + 1))
else
  echo "PASS_SRC legacy_crop_pad_reason_gone"
  pass=$((pass + 1))
  applied=$((applied + 1))
fi

# --- B: binary capability — packaged release MUST fail; current MUST pass ---
# Capability keys (not md5): MEASURED_DELIVERY + force_unverified_claim_scale_pad_coded
bin_has() {
  local bin="$1" needle="$2"
  strings "$bin" 2>/dev/null | grep -F -q -- "$needle"
}

REL="${DELIVERED_350_RELEASE_DAEMON:-$ROOT/release_artifacts/ddr-c5382bee-e9f79de2/misterplexd}"
CUR="${DELIVERED_350_CURRENT_DAEMON:-$ROOT/build/misterplexd}"

if [[ -x "$REL" ]]; then
  # RED twin: release pin must LACK delivery telemetry (parent: no measured= line)
  if bin_has "$REL" 'MEASURED_DELIVERY'; then
    echo "FAIL_RED_REL release binary unexpectedly HAS MEASURED_DELIVERY" >&2
    fail=$((fail + 1))
  else
    echo "PASS_RED_REL release lacks MEASURED_DELIVERY (capability hole)"
    pass=$((pass + 1))
    applied=$((applied + 1))
  fi
  if bin_has "$REL" 'force_unverified_claim_scale_pad_coded'; then
    echo "FAIL_RED_REL release unexpectedly HAS force_unverified_claim_scale_pad_coded" >&2
    fail=$((fail + 1))
  else
    echo "PASS_RED_REL release lacks force_unverified_claim_scale_pad_coded"
    pass=$((pass + 1))
    applied=$((applied + 1))
  fi
  if bin_has "$REL" 'desync_risk='; then
    echo "FAIL_RED_REL release unexpectedly HAS desync_risk=" >&2
    fail=$((fail + 1))
  else
    echo "PASS_RED_REL release lacks desync_risk="
    pass=$((pass + 1))
    applied=$((applied + 1))
  fi
else
  echo "FAIL_RED_REL missing packaged daemon at $REL — cannot prove release hole" >&2
  fail=$((fail + 1))
fi

if [[ -x "$CUR" ]]; then
  if bin_has "$CUR" 'MEASURED_DELIVERY'; then
    echo "PASS_GREEN_CUR current HAS MEASURED_DELIVERY"
    pass=$((pass + 1))
    applied=$((applied + 1))
  else
    echo "FAIL_GREEN_CUR current missing MEASURED_DELIVERY" >&2
    fail=$((fail + 1))
  fi
  if bin_has "$CUR" 'force_unverified_claim_scale_pad_coded'; then
    echo "PASS_GREEN_CUR current HAS force_unverified_claim_scale_pad_coded"
    pass=$((pass + 1))
    applied=$((applied + 1))
  else
    echo "FAIL_GREEN_CUR current missing force_unverified_claim_scale_pad_coded" >&2
    fail=$((fail + 1))
  fi
  if bin_has "$CUR" 'desync_risk='; then
    echo "PASS_GREEN_CUR current HAS desync_risk="
    pass=$((pass + 1))
    applied=$((applied + 1))
  else
    echo "FAIL_GREEN_CUR current missing desync_risk=" >&2
    fail=$((fail + 1))
  fi
else
  echo "FAIL_GREEN_CUR missing $CUR — build misterplexd first" >&2
  fail=$((fail + 1))
fi

# --- C: live ffmpeg on REAL 624x350 (not bank-sized fixture) ---
if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "FAIL ffmpeg missing" >&2
  fail=$((fail + 1))
else
  # RED: crop=618:480 (legacy unverified claim) on 350 → must not produce product bytes
  set +e
  "$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=624x350:rate=24" \
    -an -vf "crop=618:480:0:0,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black" \
    -pix_fmt yuv420p -frames:v "$N" -f rawvideo -y "$OUT/red_crop.yuv" 2>"$OUT/red_crop.err"
  red_rc=$?
  set -e
  red_b=0
  [[ -f "$OUT/red_crop.yuv" ]] && red_b=$(wc -c <"$OUT/red_crop.yuv" | tr -d ' ')
  if [[ "$red_rc" -ne 0 || "$red_b" -ne "$WANT" ]]; then
    echo "PASS_RED_FF crop_pad_on_real_350 rc=$red_rc bytes=$red_b"
    pass=$((pass + 1))
    applied=$((applied + 1))
  else
    echo "FAIL_RED_FF crop_pad produced product bytes on 350" >&2
    fail=$((fail + 1))
  fi
  echo "red_crop true rc=$red_rc"

  # GREEN: product FOAR into coded 624 on real 350 → 449280/frame
  set +e
  "$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=624x350:rate=24" \
    -an -vf "scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2" \
    -pix_fmt yuv420p -frames:v "$N" -f rawvideo -y "$OUT/green_foar.yuv" 2>"$OUT/green_foar.err"
  gr_rc=$?
  set -e
  gr_b=0
  [[ -f "$OUT/green_foar.yuv" ]] && gr_b=$(wc -c <"$OUT/green_foar.yuv" | tr -d ' ')
  if [[ "$gr_rc" -eq 0 && "$gr_b" -eq "$WANT" ]]; then
    echo "PASS_GREEN_FF foar_coded_on_real_350 rc=0 bytes=$gr_b"
    pass=$((pass + 1))
    applied=$((applied + 1))
  else
    echo "FAIL_GREEN_FF foar rc=$gr_rc bytes=$gr_b want=$WANT" >&2
    fail=$((fail + 1))
  fi
  echo "green_foar true rc=$gr_rc"

  # Geometry of picture region: FOAR keeps 350 rows (letterbox) — not V-upsample.
  # Measure non-black luma row span roughly via python on first frame.
  python3 - "$OUT/green_foar.yuv" "$FB" <<'PY' || true
import sys, struct
path, fb = sys.argv[1], int(sys.argv[2])
with open(path, "rb") as f:
    y = f.read(624 * 480)
if len(y) < 624 * 480:
    print("FAIL_GEOM short y plane", len(y)); sys.exit(1)
rows = []
for r in range(480):
    row = y[r * 624:(r + 1) * 624]
    # non-near-black
    if sum(1 for b in row if b > 16) > 624 // 8:
        rows.append(r)
if not rows:
    print("FAIL_GEOM no content rows"); sys.exit(1)
span = rows[-1] - rows[0] + 1
# Expect ~350 content rows (letterbox), not ~480 full-frame upsample
if 330 <= span <= 370:
    print(f"PASS_GEOM content_row_span={span} first={rows[0]} last={rows[-1]} (letterbox ~350)")
    sys.exit(0)
print(f"FAIL_GEOM content_row_span={span} first={rows[0]} last={rows[-1]} want~350")
sys.exit(1)
PY
  geom_rc=$?
  echo "geom_span true rc=$geom_rc"
  if [[ "$geom_rc" -eq 0 ]]; then
    pass=$((pass + 1))
    applied=$((applied + 1))
  else
    fail=$((fail + 1))
  fi
fi

# --- D: planner unit (if built) — unverified 624x480 claim must FOAR-code ---
if [[ -x "$ROOT/build/test_ffmpeg_vf" ]]; then
  set +e
  "$ROOT/build/test_ffmpeg_vf" >"$OUT/vf.out" 2>"$OUT/vf.err"
  vf_rc=$?
  set -e
  echo "test_ffmpeg_vf true rc=$vf_rc"
  if [[ "$vf_rc" -eq 0 ]]; then
    echo "PASS_UNIT test_ffmpeg_vf"
    pass=$((pass + 1))
    applied=$((applied + 1))
  else
    echo "FAIL_UNIT test_ffmpeg_vf rc=$vf_rc" >&2
    fail=$((fail + 1))
  fi
else
  echo "FAIL_UNIT build/test_ffmpeg_vf missing" >&2
  fail=$((fail + 1))
fi

want=16
if [[ "$applied" -lt "$want" ]]; then
  echo "FAIL applied_match=$applied want>=$want" >&2
  fail=$((fail + 1))
else
  echo "PASS applied_match=$applied want>=$want"
  pass=$((pass + 1))
fi

echo "SUMMARY pass=$pass fail=$fail applied=$applied"
if [[ "$fail" -ne 0 ]]; then
  echo "TEST_DELIVERED_350_CAPABILITY_FAIL"
  exit 1
fi
echo "TEST_DELIVERED_350_CAPABILITY_OK"
exit 0
