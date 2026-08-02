#!/usr/bin/env bash
# Red-before-green for the rollcall hole-close.
# Defect class: tests in Makefile unit-unlocked but absent from EXPECTED_*
# (w-geom UNREGISTERED_COMMAND) and multi-line recipe fragments mis-parsed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROLLCALL="$ROOT/tests/unit/test_unit_rollcall.py"
TMPDIR_RC="$ROOT/build/rollcall-hole-rbg"
mkdir -p "$TMPDIR_RC"
export UNIT_ROLLCALL_MAKEFILE

pass=0
fail=0
note() { echo "RBG $*"; }

# --- GREEN: real Makefile must pass ---
UNIT_ROLLCALL_MAKEFILE="$ROOT/Makefile"
if out=$(python3 "$ROLLCALL" 2>&1); then
  note "green_real_makefile PASS"
  echo "$out" | head -1
  pass=$((pass + 1))
else
  note "green_real_makefile FAIL rc=$?"
  echo "$out"
  fail=$((fail + 1))
fi

# --- RED: unregistered recipe command ---
cat >"$TMPDIR_RC/Makefile.unreg" <<'EOF'
unit-unlocked: unit-rollcall preflight
	mkdir -p $(ROOT)/build
	$(ROOT)/build/test_cadence
	$(ROOT)/tests/unit/test_NEVER_REGISTERED_HOLE.sh
EOF
UNIT_ROLLCALL_MAKEFILE="$TMPDIR_RC/Makefile.unreg"
set +e
out=$(python3 "$ROLLCALL" 2>&1)
rc=$?
set -e
echo "unregistered_probe true rc=$rc"
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -q 'UNREGISTERED_COMMAND.*test_NEVER_REGISTERED_HOLE'; then
  note "red_unregistered PASS (applied-match UNREGISTERED_COMMAND)"
  pass=$((pass + 1))
else
  note "red_unregistered FAIL expected UNREGISTERED_COMMAND rc!=0"
  echo "$out"
  fail=$((fail + 1))
fi

# --- RED becomes coherent after join: multi-line recipe is ONE command ---
cat >"$TMPDIR_RC/Makefile.join" <<'EOF'
unit-unlocked: unit-rollcall preflight
	mkdir -p $(ROOT)/build
	python3 $(ROOT)/scripts/check_rtl_module_instantiations.py --root h264_decode_core \
		--require h264_cavlc_residual_block --require h264_luma4x4_residual_source \
		--require h264_intra4x4_mode_deriver
EOF
UNIT_ROLLCALL_MAKEFILE="$TMPDIR_RC/Makefile.join"
set +e
out=$(python3 "$ROLLCALL" 2>&1)
rc=$?
set -e
echo "join_probe true rc=$rc"
# Must treat as one unregistered command, not three fragment lines
frag_hits=$(echo "$out" | grep -c 'UNREGISTERED_COMMAND --require' || true)
one_hit=$(echo "$out" | grep -c 'UNREGISTERED_COMMAND python3 \$(ROOT)/scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_cavlc_residual_block --require h264_luma4x4_residual_source --require h264_intra4x4_mode_deriver' || true)
if [[ "$rc" -ne 0 && "$one_hit" -eq 1 && "$frag_hits" -eq 0 ]]; then
  note "join_continuation PASS applied-match=1 frag_hits=0"
  pass=$((pass + 1))
else
  note "join_continuation FAIL rc=$rc one_hit=$one_hit frag_hits=$frag_hits"
  echo "$out"
  fail=$((fail + 1))
fi

# --- make rollcall target exists and is fast ---
set +e
out=$(make -C "$ROOT" -n rollcall 2>&1)
rc=$?
set -e
echo "make_rollcall_n true rc=$rc"
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q 'test_unit_rollcall.py'; then
  note "make_rollcall_target PASS"
  pass=$((pass + 1))
else
  note "make_rollcall_target FAIL"
  echo "$out"
  fail=$((fail + 1))
fi

# --- pre-push hook present and executable ---
hook="$ROOT/scripts/git-hooks/pre-push"
if [[ -x "$hook" ]] && grep -q 'make rollcall\|make -C .* rollcall' "$hook"; then
  note "pre_push_hook PASS"
  pass=$((pass + 1))
else
  note "pre_push_hook FAIL path=$hook"
  fail=$((fail + 1))
fi

echo "ROLLCALL_HOLE_RBG pass=$pass fail=$fail"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0
