#!/usr/bin/env bash
# Red-before-green for scripts/vf_delivery_behaviour_check.sh
#
# OBSERVED DEFECT: packaged release vf policy desynced on real PMS 624x350
# delivery → green field on glass. Gate must be behavioural (bytes + chroma),
# artifact-only, and must FAIL the historical release daemon binary without
# hardcoding its md5 as an allow/deny key.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/scripts/vf_delivery_behaviour_check.sh"
PAIR_DAEMON="$ROOT/release_artifacts/ddr-c5382bee-e9f79de2/misterplexd"
PIN_DAEMON="$ROOT/artifacts/daemon-pins/misterplexd.e9f79de2"
HOST_DAEMON="$ROOT/build/misterplexd"
fails=0
applied=0
pass() { echo "PASS $*"; applied=$((applied + 1)); }
fail() { echo "FAIL $*"; fails=$((fails + 1)); applied=$((applied + 1)); }

[ -x "$GATE" ] || chmod +x "$GATE" 2>/dev/null || true
[ -f "$GATE" ] || { echo "FAIL missing $GATE"; exit 1; }

# --- structural: scope honesty + no md5 deny-list of known builds ----------
if grep -q 'arm_producer_only=1' "$GATE" \
  && grep -q 'NOT a hardware pass' "$GATE"; then
  pass "gate states ARM-producer-only gap (not hardware pass)"
else
  fail "gate must state ARM-only scope / not hardware pass"
fi
if grep -qE 'e9f79de2|ea643e99' "$GATE"; then
  # Mentions in comments about the defect are OK; hard-coded deny of those
  # md5s as the decision key is not. Decision path must use policy/vf/bytes.
  if grep -E 'md5.*=.*e9f79de2|case.*e9f79de2|EXPECT.*e9f79de2' "$GATE"; then
    fail "gate must not hardcode content-md5 deny/allow for known builds"
  else
    pass "no md5 deny/allow key on known builds (comment-only mentions OK)"
  fi
else
  pass "no hardcoded build md5s in gate script"
fi

# --- RBG free: historical release daemon binary MUST fail ------------------
hist=""
if [ -f "$PAIR_DAEMON" ]; then
  hist=$PAIR_DAEMON
elif [ -f "$PIN_DAEMON" ]; then
  hist=$PIN_DAEMON
fi
if [ -n "$hist" ]; then
  set +e
  out=$("$GATE" "$hist" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out" | tail -n 20
  echo "hist_daemon true rc=$rc"
  if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'VF_DELIVERY_FAIL' \
    && printf '%s\n' "$out" | grep -q 'legacy_identity\|not_multiple_of_bank\|zero_total'; then
    pass "historical release daemon FAILS behavioural gate (rc=2) applied-match"
  else
    fail "historical release daemon must FAIL rc=2 behavioural; rc=$rc"
  fi
else
  fail "NO-DATA: no historical release daemon at pair or pins path"
fi

# --- explicit legacy policy must fail (no binary needed) -------------------
set +e
leg_out=$("$GATE" --policy legacy_identity /dev/null 2>&1)
leg_rc=$?
set -e
echo "legacy_policy true rc=$leg_rc"
if [ "$leg_rc" -eq 2 ] && printf '%s\n' "$leg_out" | grep -q 'VF_DELIVERY_FAIL'; then
  pass "legacy_identity policy FAILS (rc=2) applied-match"
else
  fail "legacy_identity must FAIL rc=2; rc=$leg_rc"
  printf '%s\n' "$leg_out" | tail -n 15
fi

# --- product policy must pass ----------------------------------------------
set +e
prod_out=$("$GATE" --policy product_foar_coded /dev/null 2>&1)
prod_rc=$?
set -e
echo "product_policy true rc=$prod_rc"
if [ "$prod_rc" -eq 0 ] && printf '%s\n' "$prod_out" | grep -q 'VF_DELIVERY_OK'; then
  pass "product_foar_coded policy PASSES (rc=0) applied-match"
else
  fail "product_foar_coded must PASS rc=0; rc=$prod_rc"
  printf '%s\n' "$prod_out" | tail -n 20
fi

# --- current host build (same headers as packaged source) must pass --------
if [ ! -x "$HOST_DAEMON" ]; then
  make -C "$ROOT" "$HOST_DAEMON" >/dev/null 2>&1 || true
fi
if [ -x "$HOST_DAEMON" ]; then
  set +e
  host_out=$("$GATE" "$HOST_DAEMON" 2>&1)
  host_rc=$?
  set -e
  echo "host_daemon true rc=$host_rc"
  if [ "$host_rc" -eq 0 ] && printf '%s\n' "$host_out" | grep -q 'product_foar_coded' \
    && printf '%s\n' "$host_out" | grep -q 'VF_DELIVERY_OK'; then
    pass "host build misterplexd PASSES product policy (rc=0) applied-match"
  else
    fail "host build must PASS; rc=$host_rc"
    printf '%s\n' "$host_out" | tail -n 20
  fi
else
  fail "NO-DATA: host build/misterplexd missing"
fi

# --- chroma inspector: dead U/V must FAIL (green-field class) ---------------
HEALTH="$ROOT/build/test_vf_bank_output_health"
if [ ! -x "$HEALTH" ]; then
  make -C "$ROOT" "$HEALTH" >/dev/null 2>&1 || true
fi
if [ -x "$HEALTH" ]; then
  dead="$ROOT/build/vf_delivery_dead_chroma.yuv"
  python3 - <<'PY' "$dead"
import sys, pathlib
p = pathlib.Path(sys.argv[1])
w, h = 624, 480
yb = w * h
cb = yb // 4
# Y populated, U=V=0 — parent green-field fingerprint
buf = bytes([128]) * yb + bytes([0]) * cb + bytes([0]) * cb
p.write_bytes(buf * 2)
PY
  dead_log="$ROOT/build/vf_delivery_dead_chroma.log"
  set +e
  "$HEALTH" "$dead" 624 480 >"$dead_log" 2>&1
  dead_rc=$?
  set -e
  echo "dead_chroma true rc=$dead_rc"
  if [ "$dead_rc" -eq 2 ] && grep -q 'dead_chroma' "$dead_log"; then
    pass "dead chroma bank frames FAIL health (rc=2) applied-match"
  else
    fail "dead chroma must FAIL health rc=2; rc=$dead_rc"
    tail -n 10 "$dead_log" 2>/dev/null || true
  fi
  rm -f "$dead"
else
  fail "NO-DATA: test_vf_bank_output_health missing"
fi

# --- package scripts consult the behavioural gate (not capability markers) -
if grep -q 'vf_delivery_behaviour_check.sh' "$ROOT/scripts/package_release.sh"; then
  pass "package_release.sh consults vf_delivery_behaviour_check.sh"
else
  fail "package_release.sh must call vf_delivery_behaviour_check.sh"
fi
if grep -q 'vf_delivery_behaviour_check.sh' "$ROOT/scripts/package_validated_pair.sh"; then
  pass "package_validated_pair.sh consults vf_delivery_behaviour_check.sh"
else
  fail "package_validated_pair.sh must call vf_delivery_behaviour_check.sh"
fi
# Capability marker gate must not remain the ship decision.
if grep -q 'daemon_capability_check.sh' "$ROOT/scripts/package_release.sh" \
  || grep -q 'daemon_capability_check.sh' "$ROOT/scripts/package_validated_pair.sh"; then
  fail "package path still calls removed capability marker gate"
else
  pass "package path no longer uses daemon_capability_check.sh"
fi

# Gate before tar in package_release
cap_line=$(grep -n 'vf_delivery_behaviour_check' "$ROOT/scripts/package_release.sh" | head -1 | cut -d: -f1)
tar_line=$(grep -n 'tar -C' "$ROOT/scripts/package_release.sh" | head -1 | cut -d: -f1)
if [ -n "$cap_line" ] && [ -n "$tar_line" ] && [ "$cap_line" -lt "$tar_line" ]; then
  pass "vf gate (line $cap_line) runs before tar (line $tar_line)"
else
  fail "vf gate must run before tar (gate=$cap_line tar=$tar_line)"
fi

# --- package_validated_pair refuses historical pair (behavioural) ----------
if [ -f "$PAIR_DAEMON" ] && [ -x "$ROOT/scripts/package_validated_pair.sh" ]; then
  e2e="$ROOT/build/unit-vf-delivery-e2e"
  rm -rf "$e2e"
  mkdir -p "$e2e"
  set +e
  OUT_DIR="$e2e" VERSION=vf-delivery-e2e PACKAGE_ALLOW_NO_FFMPEG=1 \
    "$ROOT/scripts/package_validated_pair.sh" >"$e2e/pkg.log" 2>&1
  e2e_rc=$?
  set -e
  echo "package_validated_pair hist true rc=$e2e_rc"
  if [ "$e2e_rc" -eq 7 ] && grep -q 'VF_DELIVERY_FAIL\|vf delivery' "$e2e/pkg.log" \
    && [ ! -f "$e2e/misterplex-vf-delivery-e2e.tar.gz" ]; then
    pass "package_validated_pair refuses legacy-vf pair (rc=7, no tarball)"
  else
    fail "expected package refuse rc=7; rc=$e2e_rc"
    sed -n '1,40p' "$e2e/pkg.log" || true
  fi
else
  echo "NOTE: skip package_validated_pair e2e — pair missing"
fi

echo "applied_match_count=$applied fails=$fails"
if [ "$fails" -ne 0 ]; then
  echo "test_vf_delivery_behaviour: FAILED"
  exit 1
fi
echo "test_vf_delivery_behaviour: OK"
exit 0
