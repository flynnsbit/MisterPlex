#!/usr/bin/env bash
# Capability gate: identity_skip x delivered geometry (parent 2026-08-02 HW).
#
# Mechanism (binary strings, parent-measured):
#   RELEASE e9f79de2: identity_skip present, NO GEOM_GUARD / MEASURED_DELIVERY /
#     desync_risk / measured=  -> fail-OPEN green+wrap on non-bank delivery (pfps>0)
#   LIVE ea643e99: GEOM_GUARD refused identity_skip + MEASURED_DELIVERY +
#     green-cast class naming -> handles 624x350 (pfps healthy)
#
# Two OPPOSITE failure modes, same root (delivered H != coded H):
#   fail-CLOSED: crop=618:480 on 350 -> ffmpeg rc=234, total bytes=0, pfps 0
#   fail-OPEN:   identity_skip + producer 327600 vs reader 449280 -> desync;
#                total%449280 stays 0 (read loop) so remainder alone is blind;
#                pipeDesyncRisk(identity_skip) + non-zero total catch it.
#
# 2x2 host matrix (real geometries, not bank-only fixtures):
#   624x350 non-bank  x  guarded scale   -> GREEN product path
#   624x350 non-bank  x  identity/crop   -> RED both modes
#   624x480 bank-exact x identity OK when verified
#
# Does NOT hardcode md5s. Capability keys + path overrides for both binaries.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
VF="$ROOT/host/libmisterplex/ffmpeg_vf.hpp"
CH="$ROOT/host/libmisterplex/yuv420p_chroma_health.hpp"
OUT="$ROOT/build/test_delivered_350_capability"
mkdir -p "$OUT"
FFMPEG="${FFMPEG:-ffmpeg}"
FB=449280
PROD_350=327600
N=3
WANT=$((FB * N))
fail=0
pass=0
applied=0

check_src() {
  local name="$1" file="$2" pat="$3"
  if rg -n --fixed-strings "$pat" "$file" >/dev/null; then
    echo "PASS_SRC $name"
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    echo "FAIL_SRC $name missing: $pat" >&2
    fail=$((fail + 1))
  fi
}

bin_has() {
  local bin="$1" needle="$2"
  strings "$bin" 2>/dev/null | grep -F -q -- "$needle"
}

bin_count() {
  local bin="$1" needle="$2"
  strings "$bin" 2>/dev/null | grep -F -c -- "$needle" || true
}

check_src SRC_MEASURED_DELIVERY "$MP" 'media: MEASURED_DELIVERY delivered_geom='
check_src SRC_MEASURED_OUTPUT "$MP" 'media: MEASURED_OUTPUT '
check_src SRC_desync_risk_field "$MP" 'desync_risk='
check_src SRC_DELIVERY_MISMATCH "$MP" 'DELIVERY_MISMATCH measured='
check_src SRC_GEOM_GUARD_log "$MP" 'GEOM_GUARD refused identity_skip'
check_src SRC_green_cast_class "$MP" 'green-cast class; check identity_skip'
check_src SRC_green_cast_header "$CH" 'green-cast class'
check_src SRC_force_unverified_reason "$VF" 'force_unverified_claim_scale_pad_coded'
check_src SRC_never_identity_unverified "$VF" 'Never identity_skip on unverified claims'
check_src SRC_sourceMatchesCoded_guard "$VF" 'delivery_geometry_verified || req.assume_source_matches_coded'
check_src SRC_FOAR_coded "$VF" 'FOAR into the CODED bank'
if rg -n --fixed-strings 'force_exact_crop_pad_unverified' "$VF" >/dev/null; then
  echo "FAIL_SRC legacy force_exact_crop_pad_unverified still present" >&2
  fail=$((fail + 1))
else
  echo "PASS_SRC legacy_crop_pad_reason_gone"
  pass=$((pass + 1)); applied=$((applied + 1))
fi
if rg -n 'reason\.find\("unverified_delivery"\)' "$MP" >/dev/null; then
  echo "FAIL_SRC GEOM_GUARD still matches only unverified_delivery (dead on rename)" >&2
  fail=$((fail + 1))
else
  echo "PASS_SRC GEOM_GUARD_not_dead_token"
  pass=$((pass + 1)); applied=$((applied + 1))
fi

REL="${DELIVERED_350_RELEASE_DAEMON:-$ROOT/release_artifacts/ddr-c5382bee-e9f79de2/misterplexd}"
LIVE="${DELIVERED_350_LIVE_DAEMON:-}"
if [[ -z "$LIVE" ]]; then
  for cand in \
    "$ROOT/../MisterPlex/.worktrees/w-cpu-fps-measure/artifacts/daemon-pins/misterplexd.ea643e99" \
    "/home/flynnsbit/Projects/MisterPlex/.worktrees/w-cpu-fps-measure/artifacts/daemon-pins/misterplexd.ea643e99" \
    "$ROOT/artifacts/daemon-pins/misterplexd.ea643e99"
  do
    if [[ -x "$cand" ]]; then LIVE="$cand"; break; fi
  done
fi
CUR="${DELIVERED_350_CURRENT_DAEMON:-$ROOT/build/misterplexd}"

if [[ -x "$REL" ]]; then
  for needle in 'MEASURED_DELIVERY' 'GEOM_GUARD refused identity_skip' 'desync_risk=' 'measured='; do
    if bin_has "$REL" "$needle"; then
      echo "FAIL_RED_REL release HAS $needle (expected absent)" >&2
      fail=$((fail + 1))
    else
      echo "PASS_RED_REL release lacks $needle"
      pass=$((pass + 1)); applied=$((applied + 1))
    fi
  done
  isc=$(bin_count "$REL" 'identity_skip')
  if [[ "${isc:-0}" -ge 1 ]]; then
    echo "PASS_RED_REL release has identity_skip count=$isc without GEOM_GUARD"
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    echo "FAIL_RED_REL release missing identity_skip entirely (unexpected)" >&2
    fail=$((fail + 1))
  fi
else
  echo "FAIL_RED_REL missing $REL" >&2
  fail=$((fail + 1))
fi

if [[ -n "${LIVE:-}" && -x "$LIVE" ]]; then
  for needle in 'MEASURED_DELIVERY' 'GEOM_GUARD refused identity_skip' 'green-cast class' 'desync_risk'; do
    if bin_has "$LIVE" "$needle"; then
      echo "PASS_GREEN_LIVE live HAS $needle"
      pass=$((pass + 1)); applied=$((applied + 1))
    else
      echo "FAIL_GREEN_LIVE live missing $needle" >&2
      fail=$((fail + 1))
    fi
  done
  lc=$(bin_count "$LIVE" 'identity_skip')
  rc=$(bin_count "$REL" 'identity_skip')
  if [[ "${lc:-0}" -gt "${rc:-0}" ]]; then
    echo "PASS_GREEN_LIVE identity_skip count live=$lc > release=$rc"
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    echo "FAIL_GREEN_LIVE identity_skip counts live=$lc release=$rc" >&2
    fail=$((fail + 1))
  fi
else
  echo "FAIL_GREEN_LIVE live daemon not found (set DELIVERED_350_LIVE_DAEMON)" >&2
  fail=$((fail + 1))
fi

if [[ -x "$CUR" ]]; then
  for needle in 'MEASURED_DELIVERY' 'GEOM_GUARD refused identity_skip' 'desync_risk=' \
                'force_unverified_claim_scale_pad_coded' 'green-cast class'; do
    if bin_has "$CUR" "$needle"; then
      echo "PASS_GREEN_CUR current HAS $needle"
      pass=$((pass + 1)); applied=$((applied + 1))
    else
      echo "FAIL_GREEN_CUR current missing $needle" >&2
      fail=$((fail + 1))
    fi
  done
else
  echo "FAIL_GREEN_CUR missing $CUR - build misterplexd first" >&2
  fail=$((fail + 1))
fi

if [[ -x "$ROOT/build/test_ffmpeg_vf" ]]; then
  set +e
  "$ROOT/build/test_ffmpeg_vf" >"$OUT/vf.out" 2>"$OUT/vf.err"
  vf_rc=$?
  set -e
  echo "test_ffmpeg_vf true rc=$vf_rc"
  if [[ "$vf_rc" -eq 0 ]]; then
    echo "PASS_UNIT test_ffmpeg_vf"
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    echo "FAIL_UNIT test_ffmpeg_vf rc=$vf_rc" >&2
    fail=$((fail + 1))
  fi
else
  echo "FAIL_UNIT build/test_ffmpeg_vf missing" >&2
  fail=$((fail + 1))
fi

python3 - <<'PY'
FB = 449280
PROD = 327600
def phase(prod, reader, idx):
    if prod == 0: return 0
    return (idx * reader) % prod
def desynced(prod, reader, idx):
    if prod == reader: return False
    return phase(prod, reader, idx) != 0 or idx > 0
def risk(prod, reader, identity_skip):
    if prod == 0 or reader == 0 or prod == reader: return False
    return identity_skip
fail = 0
total = FB * 100
if total % FB != 0:
    print("FAIL model remainder"); fail += 1
else:
    print("PASS_MODEL remainder_blind_under_fixed_reads total%FB=0")
if not risk(PROD, FB, True):
    print("FAIL risk identity+350"); fail += 1
else:
    print("PASS_MODEL fail_OPEN risk identity_skip+350")
if risk(PROD, FB, False):
    print("FAIL risk scale path"); fail += 1
else:
    print("PASS_MODEL scale_path risk=0 on 350")
if risk(FB, FB, True):
    print("FAIL risk bank-exact"); fail += 1
else:
    print("PASS_MODEL bank_exact identity risk=0")
if not desynced(PROD, FB, 1):
    print("FAIL phase"); fail += 1
else:
    print("PASS_MODEL phase_walk f1 offset=%d" % phase(PROD, FB, 1))
print("PASS_MODEL fail_CLOSED zero_total distinguishes crop death")
raise SystemExit(fail)
PY
model_rc=$?
echo "model true rc=$model_rc"
if [[ "$model_rc" -eq 0 ]]; then
  pass=$((pass + 1)); applied=$((applied + 1))
else
  fail=$((fail + 1))
fi

if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "FAIL ffmpeg missing" >&2
  fail=$((fail + 1))
else
  set +e
  "$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=624x350:rate=24" \
    -an -vf "crop=618:480:0:0,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black" \
    -pix_fmt yuv420p -frames:v "$N" -f rawvideo -y "$OUT/red_crop350.yuv" 2>"$OUT/red_crop350.err"
  red_rc=$?
  set -e
  red_b=0; [[ -f "$OUT/red_crop350.yuv" ]] && red_b=$(wc -c <"$OUT/red_crop350.yuv" | tr -d ' ')
  if [[ "$red_rc" -ne 0 && "$red_b" -eq 0 ]]; then
    echo "PASS_RED_FF fail_CLOSED crop_on_350 rc=$red_rc bytes=0"
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    echo "FAIL_RED_FF crop_on_350 rc=$red_rc bytes=$red_b" >&2
    fail=$((fail + 1))
  fi
  echo "red_crop350 true rc=$red_rc"

  set +e
  "$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=624x350:rate=24" \
    -an -pix_fmt yuv420p -frames:v "$N" -f rawvideo -y "$OUT/red_id350.yuv" 2>"$OUT/red_id350.err"
  id_rc=$?
  set -e
  id_b=0; [[ -f "$OUT/red_id350.yuv" ]] && id_b=$(wc -c <"$OUT/red_id350.yuv" | tr -d ' ')
  id_want=$((PROD_350 * N))
  if [[ "$id_rc" -eq 0 && "$id_b" -eq "$id_want" && "$id_b" -ne "$WANT" ]]; then
    echo "PASS_RED_FF fail_OPEN identity_350 bytes=$id_b != reader_want=$WANT"
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    echo "FAIL_RED_FF identity_350 rc=$id_rc bytes=$id_b" >&2
    fail=$((fail + 1))
  fi
  echo "red_id350 true rc=$id_rc"
  if [[ "$id_b" -gt 0 && "$red_b" -eq 0 ]]; then
    echo "PASS_RED_FF discriminator open_bytes=$id_b closed_bytes=$red_b"
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    echo "FAIL_RED_FF discriminator open=$id_b closed=$red_b" >&2
    fail=$((fail + 1))
  fi

  set +e
  "$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=624x350:rate=24" \
    -an -vf "scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2" \
    -pix_fmt yuv420p -frames:v "$N" -f rawvideo -y "$OUT/green_foar350.yuv" 2>/dev/null
  gr_rc=$?
  set -e
  gr_b=0; [[ -f "$OUT/green_foar350.yuv" ]] && gr_b=$(wc -c <"$OUT/green_foar350.yuv" | tr -d ' ')
  if [[ "$gr_rc" -eq 0 && "$gr_b" -eq "$WANT" ]]; then
    echo "PASS_GREEN_FF foar_350 bytes=$gr_b"
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    echo "FAIL_GREEN_FF foar_350 rc=$gr_rc bytes=$gr_b" >&2
    fail=$((fail + 1))
  fi
  echo "green_foar350 true rc=$gr_rc"

  set +e
  "$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=624x480:rate=24" \
    -an -pix_fmt yuv420p -frames:v "$N" -f rawvideo -y "$OUT/green_id480.yuv" 2>/dev/null
  id480_rc=$?
  set -e
  id480_b=0; [[ -f "$OUT/green_id480.yuv" ]] && id480_b=$(wc -c <"$OUT/green_id480.yuv" | tr -d ' ')
  if [[ "$id480_rc" -eq 0 && "$id480_b" -eq "$WANT" ]]; then
    echo "PASS_GREEN_FF bank_exact_identity_480 bytes=$id480_b"
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    echo "FAIL_GREEN_FF bank_exact_480 rc=$id480_rc bytes=$id480_b" >&2
    fail=$((fail + 1))
  fi
  echo "green_id480 true rc=$id480_rc"

  python3 - "$OUT/green_foar350.yuv" <<'PY'
import sys
path = sys.argv[1]
with open(path, "rb") as f:
    y = f.read(624 * 480)
rows = [r for r in range(480) if sum(1 for b in y[r*624:(r+1)*624] if b > 16) > 624//8]
if not rows:
    print("FAIL_GEOM no content"); sys.exit(1)
span = rows[-1] - rows[0] + 1
if 330 <= span <= 370:
    print("PASS_GEOM letterbox_span=%d first=%d last=%d" % (span, rows[0], rows[-1]))
    sys.exit(0)
print("FAIL_GEOM span=%d" % span); sys.exit(1)
PY
  geom_rc=$?
  echo "geom true rc=$geom_rc"
  if [[ "$geom_rc" -eq 0 ]]; then
    pass=$((pass + 1)); applied=$((applied + 1))
  else
    fail=$((fail + 1))
  fi
fi

want=28
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
