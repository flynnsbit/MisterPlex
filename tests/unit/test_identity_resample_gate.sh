#!/usr/bin/env bash
# Identity-resample gate (parent hole #3).
#
# Contract: when expected_delivery == decode_target (source tier matches coded
# bank), product path must set arm_rescale=0 / identity_skip=1 under
# SkipIdentity. Parent measured on device:
#   requested_pms=624x480 expected_delivery=624x480 decode_target=624x480
#   arm_rescale=1 identity_skip=0 mode=always display=618x480
#   vf=scale=618:480...pad=624:480  (full per-frame rescale of an identity tier)
#
# DDR_YUV_FORCE_SCALE=1 is load-bearing for non-identity 480p — this gate does
# NOT ban that conf key. It only fails the identity case (delivery==target).
#
# Method: pure GEOM-line checker + product default assert + red-before-green
# mutation on the parent-measured line. w-geom owns the product fix; we own RED.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${PYTHON:-python3}"
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; FAILS=$((FAILS + 1)); }

# --- pure checker (also used as library via --check-line) ---------------------
check_line() {
  # Args via env: GEOM_LINE
  "$PY" - <<'PY'
import os, re, sys
line = os.environ.get("GEOM_LINE", "")
# Accept media: GEOM ... or misterplexd: GEOM ...
def dig(key, default=None):
    m = re.search(rf"\b{re.escape(key)}=(\S+)", line)
    return m.group(1) if m else default

delivery = dig("expected_delivery") or dig("requested_pms")
target = dig("decode_target")
arm = dig("arm_rescale")
iskip = dig("identity_skip")
mode = dig("mode")

print(f"COVERAGE gate=identity_resample delivery={delivery} target={target} "
      f"arm_rescale={arm} identity_skip={iskip} mode={mode}")

if not delivery or not target:
    print("UNSCORED identity_resample: missing delivery/target (empty inspection)", file=sys.stderr)
    sys.exit(77)

if delivery in ("unknown", "0x0") or target in ("unknown", "0x0"):
    print("UNSCORED identity_resample: unknown geometry — not a pass", file=sys.stderr)
    sys.exit(77)

if delivery != target:
    print(f"PASS identity_resample: non-identity {delivery}!={target} (out of scope)")
    sys.exit(0)

# Identity case: delivery == target. Product must skip rescale.
# mode=always with match is exactly the parent RED (wasteful 624→618→624).
bad = []
if arm is not None and arm != "0":
    bad.append(f"arm_rescale={arm} want 0")
if iskip is not None and iskip != "1":
    bad.append(f"identity_skip={iskip} want 1")
if arm is None and iskip is None:
    print("UNSCORED identity_resample: no arm_rescale/identity_skip fields", file=sys.stderr)
    sys.exit(77)
if bad:
    print("FAIL IDENTITY_RESCALE_WASTE " + "; ".join(bad) +
          f" (delivery==target=={delivery} mode={mode})", file=sys.stderr)
    sys.exit(1)
print(f"PASS identity_resample: identity {delivery} arm_rescale=0 identity_skip=1 mode={mode}")
sys.exit(0)
PY
}

# 1) Product default must be skip_identity (main.cpp), not always.
if grep -n 'std::string ffmpegScaleMode = "skip_identity"' \
    "$ROOT/arm/misterplexd/main.cpp" >/dev/null; then
  pass "product default FFMPEG_SCALE=skip_identity in main.cpp"
else
  fail "product default FFMPEG_SCALE is not skip_identity"
fi

# 2) Library SkipIdentity 624==624 already unit-tested in test_ffmpeg_vf; re-check
#    via a synthetic GEOM line that the product path SHOULD emit.
GOOD_LINE='media: GEOM expected_delivery=624x480 decode_target=624x480 arm_rescale=0 reason=identity_skip_crop_pad_clear identity_skip=1 mode=skip_identity display=618x480 vf=(none)'
set +e
GEOM_LINE="$GOOD_LINE" check_line
rc_good=$?
set -e
echo "identity_good true rc=$rc_good"
if [ "$rc_good" -eq 0 ]; then
  pass "synthetic skip_identity identity GEOM"
else
  fail "synthetic good GEOM rc=$rc_good (gate broken)"
fi

# 3) MUTATION RED — exact parent-measured shape (mode=always, rescale on identity).
PARENT_LINE='media: GEOM expected_delivery=624x480 decode_target=624x480 arm_rescale=1 reason=scale_pad_center_flags identity_skip=0 mode=always display=618x480 vf=scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2'
set +e
GEOM_LINE="$PARENT_LINE" check_line
rc_parent=$?
set -e
echo "identity_parent_measured true rc=$rc_parent"
if [ "$rc_parent" -ne 0 ] && [ "$rc_parent" -ne 77 ]; then
  pass "parent-measured identity waste is RED (rc=$rc_parent)"
else
  fail "MUTATION_BLIND: parent identity waste not RED (rc=$rc_parent)"
fi

# 4) Empty / unknown must be UNSCORED (77), never pass.
set +e
GEOM_LINE='media: GEOM expected_delivery=unknown decode_target=624x480 arm_rescale=1' check_line
rc_unk=$?
GEOM_LINE='' check_line
rc_empty=$?
set -e
echo "identity_unknown true rc=$rc_unk"
echo "identity_empty true rc=$rc_empty"
if [ "$rc_unk" -eq 77 ] && [ "$rc_empty" -eq 77 ]; then
  pass "unknown/empty → UNSCORED rc=77 (not pass)"
else
  fail "unknown/empty rcs unk=$rc_unk empty=$rc_empty want 77"
fi

# 5) Non-identity out of scope (must PASS — force-scale path remains valid).
NON_ID='media: GEOM expected_delivery=1920x1080 decode_target=624x480 arm_rescale=1 identity_skip=0 mode=skip_identity'
set +e
GEOM_LINE="$NON_ID" check_line
rc_non=$?
set -e
echo "identity_non_identity true rc=$rc_non"
if [ "$rc_non" -eq 0 ]; then
  pass "non-identity 1920→624 remains in-scope for scale (not this gate)"
else
  fail "non-identity should be out-of-scope PASS rc=$rc_non"
fi

if [ "$FAILS" -ne 0 ]; then
  echo "FAIL test_identity_resample_gate failures=$FAILS" >&2
  exit 1
fi
echo "PASS test_identity_resample_gate (parent waste RED; good identity GREEN; 77≠pass)"
exit 0
