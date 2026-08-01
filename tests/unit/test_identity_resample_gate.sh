#!/usr/bin/env bash
# Identity-resample gate (parent hole #3 + FOAR vertical correction).
#
# Contract: when expected_delivery == decode_target, product must NOT resample.
# Under SkipIdentity that is identity_skip=1 / arm_rescale=0 and no scale= in vf.
#
# FOAR defect class (parent correction): force_original_aspect_ratio=decrease
# applies min(sx,sy) to BOTH axes. scale=618:480 on a 624x480 source is not a
# "horizontal-only" crop path — it becomes ~618x475 then pad, i.e. a ~1% vertical
# resample of every frame (picture quality, not just CPU). Gate asserts
# NO VERTICAL RESAMPLE, not merely arm_rescale=0.
#
# Parent measured:
#   expected_delivery=624x480 decode_target=624x480 arm_rescale=1 identity_skip=0
#   mode=always display=618x480
#   vf=scale=618:480:...force_original_aspect_ratio=decrease,pad=624:480...
#
# DDR_YUV_FORCE_SCALE is load-bearing for non-identity 480p — not banned here.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${PYTHON:-python3}"
FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; FAILS=$((FAILS + 1)); }

check_line() {
  "$PY" - <<'PY'
import os, re, sys

line = os.environ.get("GEOM_LINE", "")

def dig(key, default=None):
    m = re.search(rf"\b{re.escape(key)}=(\S+)", line)
    return m.group(1) if m else default

def parse_wh(s):
    if not s or "x" not in s:
        return None
    a, b = s.split("x", 1)
    try:
        return int(a), int(b)
    except ValueError:
        return None

delivery = dig("expected_delivery") or dig("requested_pms")
target = dig("decode_target")
arm = dig("arm_rescale")
iskip = dig("identity_skip")
mode = dig("mode")
vf = dig("vf") or ""

print(
    f"COVERAGE gate=identity_resample delivery={delivery} target={target} "
    f"arm_rescale={arm} identity_skip={iskip} mode={mode} vf={vf[:80]}"
)

if not delivery or not target:
    print("UNSCORED identity_resample: missing delivery/target", file=sys.stderr)
    sys.exit(77)
if delivery in ("unknown", "0x0") or target in ("unknown", "0x0"):
    print("UNSCORED identity_resample: unknown geometry", file=sys.stderr)
    sys.exit(77)
if delivery != target:
    print(f"PASS identity_resample: non-identity {delivery}!={target} (out of scope)")
    sys.exit(0)

bad = []
if arm is not None and arm != "0":
    bad.append(f"arm_rescale={arm} want 0")
if iskip is not None and iskip != "1":
    bad.append(f"identity_skip={iskip} want 1")
if arm is None and iskip is None and vf in ("", "(none)"):
    print("UNSCORED identity_resample: no rescale fields", file=sys.stderr)
    sys.exit(77)

# Vertical resample detector: FOAR=decrease on scale=W:H with source Hs.
# Effective out_h = floor(Hs * min(W/Ws, H/Hs)). Any out_h != Hs is vertical resample.
src = parse_wh(delivery)
if src and vf and vf not in ("(none)",):
    sm = re.search(r"scale=(\d+):(\d+)", vf)
    if sm:
        sw, sh = int(sm.group(1)), int(sm.group(2))
        ws, hs = src
        if ws > 0 and hs > 0:
            sx = sw / ws
            sy = sh / hs
            m = min(sx, sy)
            out_h = int(hs * m)  # ffmpeg uses float then round; floor-ish for detect
            # Also flag any scale present on identity tier (skip should omit scale).
            bad.append(f"vf_has_scale={sw}x{sh} on identity tier")
            if "force_original_aspect_ratio=decrease" in vf or "force_original_aspect_ratio=decrease" in line:
                if abs(m - 1.0) > 1e-9 and out_h != hs:
                    bad.append(
                        f"VERTICAL_RESAMPLE foar_decrease min(sx,sy)={m:.6f} "
                        f"out_h≈{out_h} != src_h={hs} (picture quality defect)"
                    )
                elif abs(m - 1.0) > 1e-9:
                    bad.append(f"FOAR_SCALE min={m:.6f} on identity tier")

if bad:
    print(
        "FAIL IDENTITY_RESAMPLE " + "; ".join(bad) + f" (delivery==target=={delivery} mode={mode})",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"PASS identity_resample: identity {delivery} no-rescale "
    f"arm_rescale=0 identity_skip=1 no-vertical-resample mode={mode}"
)
sys.exit(0)
PY
}

if grep -n 'std::string ffmpegScaleMode = "skip_identity"' \
    "$ROOT/arm/misterplexd/main.cpp" >/dev/null; then
  pass "product default FFMPEG_SCALE=skip_identity"
else
  fail "product default not skip_identity"
fi

GOOD_LINE='media: GEOM expected_delivery=624x480 decode_target=624x480 arm_rescale=0 reason=identity_skip_crop_pad_clear identity_skip=1 mode=skip_identity display=618x480 vf=(none)'
set +e
GEOM_LINE="$GOOD_LINE" check_line
rc_good=$?
set -e
echo "identity_good true rc=$rc_good"
[ "$rc_good" -eq 0 ] && pass "good identity GEOM" || fail "good GEOM rc=$rc_good"

# Parent measured FOAR vertical path (scale=618:480 + decrease on 624x480 → ~475h)
PARENT_LINE='media: GEOM expected_delivery=624x480 decode_target=624x480 arm_rescale=1 reason=scale_pad_crop_flags identity_skip=0 mode=always display=618x480 vf=scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black'
set +e
GEOM_LINE="$PARENT_LINE" check_line
rc_parent=$?
set -e
echo "identity_parent_foar true rc=$rc_parent"
if [ "$rc_parent" -ne 0 ] && [ "$rc_parent" -ne 77 ]; then
  pass "parent FOAR identity path RED (rc=$rc_parent)"
else
  fail "MUTATION_BLIND parent FOAR not RED rc=$rc_parent"
fi

# Explicit vertical-resample-only line: arm_rescale could be mis-logged 0 but vf scales
SNEAKY='media: GEOM expected_delivery=624x480 decode_target=624x480 arm_rescale=0 identity_skip=1 mode=skip_identity vf=scale=618:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2'
set +e
GEOM_LINE="$SNEAKY" check_line
rc_sneaky=$?
set -e
echo "identity_sneaky_vf true rc=$rc_sneaky"
if [ "$rc_sneaky" -ne 0 ] && [ "$rc_sneaky" -ne 77 ]; then
  pass "sneaky vf scale on identity RED (vertical FOAR catch)"
else
  fail "MUTATION_BLIND sneaky vf not RED rc=$rc_sneaky"
fi

set +e
GEOM_LINE='media: GEOM expected_delivery=unknown decode_target=624x480 arm_rescale=1' check_line
rc_unk=$?
GEOM_LINE='' check_line
rc_empty=$?
set -e
echo "identity_unknown true rc=$rc_unk"
echo "identity_empty true rc=$rc_empty"
[ "$rc_unk" -eq 77 ] && [ "$rc_empty" -eq 77 ] && pass "unknown/empty rc=77" || fail "unk=$rc_unk empty=$rc_empty"

NON_ID='media: GEOM expected_delivery=1920x1080 decode_target=624x480 arm_rescale=1 identity_skip=0 mode=skip_identity vf=scale=624:480:force_original_aspect_ratio=decrease'
set +e
GEOM_LINE="$NON_ID" check_line
rc_non=$?
set -e
echo "identity_non_identity true rc=$rc_non"
[ "$rc_non" -eq 0 ] && pass "non-identity out of scope" || fail "non-identity rc=$rc_non"

if [ "$FAILS" -ne 0 ]; then
  echo "FAIL test_identity_resample_gate failures=$FAILS" >&2
  exit 1
fi
echo "PASS test_identity_resample_gate (no vertical resample on identity; FOAR RED)"
exit 0
