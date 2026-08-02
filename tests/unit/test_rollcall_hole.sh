#!/usr/bin/env bash
# Red-before-green for the rollcall hole-close.
# Defect class: tests in Makefile unit-unlocked but absent from EXPECTED_*
# (w-geom UNREGISTERED_COMMAND), multi-line recipe mis-parse, and
# --write-expected laundering coverage loss by dropping removed tests.
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
set +e
out=$(python3 "$ROLLCALL" 2>&1)
rc=$?
set -e
echo "green_real_makefile true rc=$rc"
if [[ "$rc" -eq 0 ]]; then
  note "green_real_makefile PASS"
  echo "$out" | head -1
  pass=$((pass + 1))
else
  note "green_real_makefile FAIL"
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
if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -q 'UNREGISTERED_COMMAND.*test_NEVER_REGISTERED_HOLE'; then
  note "red_unregistered PASS (applied-match UNREGISTERED_COMMAND)"
  pass=$((pass + 1))
else
  note "red_unregistered FAIL expected UNREGISTERED_COMMAND rc!=0"
  echo "$out"
  fail=$((fail + 1))
fi

# --- multi-line recipe is ONE command ---
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
frag_hits=$(printf '%s\n' "$out" | grep -c 'UNREGISTERED_COMMAND --require' || true)
one_hit=$(printf '%s\n' "$out" | grep -c 'UNREGISTERED_COMMAND python3 \$(ROOT)/scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_cavlc_residual_block --require h264_luma4x4_residual_source --require h264_intra4x4_mode_deriver' || true)
if [[ "$rc" -ne 0 && "$one_hit" -eq 1 && "$frag_hits" -eq 0 ]]; then
  note "join_continuation PASS applied-match=1 frag_hits=0"
  pass=$((pass + 1))
else
  note "join_continuation FAIL rc=$rc one_hit=$one_hit frag_hits=$frag_hits"
  echo "$out"
  fail=$((fail + 1))
fi

# --- make rollcall target ---
set +e
out=$(make -C "$ROOT" -n rollcall 2>&1)
rc=$?
set -e
echo "make_rollcall_n true rc=$rc"
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -q 'test_unit_rollcall.py'; then
  note "make_rollcall_target PASS"
  pass=$((pass + 1))
else
  note "make_rollcall_target FAIL"
  echo "$out"
  fail=$((fail + 1))
fi

# --- pre-push hook ---
hook="$ROOT/scripts/git-hooks/pre-push"
if [[ -x "$hook" ]] && grep -q 'rollcall' "$hook"; then
  note "pre_push_hook PASS"
  pass=$((pass + 1))
else
  note "pre_push_hook FAIL path=$hook"
  fail=$((fail + 1))
fi

# --- --write-expected REFUSES removals (must not launder deleted tests) ---
cp "$ROLLCALL" "$TMPDIR_RC/we_refuse.py"
cat >"$TMPDIR_RC/Makefile.drop" <<'EOF'
unit-unlocked: unit-rollcall preflight
	mkdir -p $(ROOT)/build
	python3 $(ROOT)/scripts/gen_test_annexb_real.py $(UNIT_ANNEXB)
	chmod +x $(ROOT)/tests/unit/*.sh $(ROOT)/tests/unit/*.py $(ROOT)/tests/hw/*.sh 2>/dev/null || true
EOF
UNIT_ROLLCALL_MAKEFILE="$TMPDIR_RC/Makefile.drop"
set +e
out=$(python3 "$TMPDIR_RC/we_refuse.py" --write-expected 2>&1)
rc=$?
set -e
echo "write_expected_refuse_removal true rc=$rc"
refuse_hit=$(printf '%s\n' "$out" | grep -c 'UNIT_ROLLCALL_WRITE_EXPECTED_REFUSED_REMOVAL' || true)
would_remove=$(printf '%s\n' "$out" | grep -c 'WRITE_EXPECTED_WOULD_REMOVE_COMMAND' || true)
wrote_hit=$(printf '%s\n' "$out" | grep -c 'UNIT_ROLLCALL_WROTE_EXPECTED' || true)
echo "applied_matches refuse_hit=$refuse_hit would_remove=$would_remove wrote_hit=$wrote_hit"
if [[ "$rc" -ne 0 && "$refuse_hit" -eq 1 && "$would_remove" -ge 1 && "$wrote_hit" -eq 0 ]]; then
  note "write_expected_refuse_removal PASS"
  pass=$((pass + 1))
else
  note "write_expected_refuse_removal FAIL"
  printf '%s\n' "$out"
  fail=$((fail + 1))
fi

# --- --write-expected ADDS new commands only (API-level, no real registry mutate) ---
export ROLLCALL_PATH="$ROLLCALL"
export TMPDIR_RC
set +e
out=$(
python3 - <<'PY'
import importlib.util
import sys
import os
from pathlib import Path

src = Path(os.environ["ROLLCALL_PATH"])
tmpdir = Path(os.environ["TMPDIR_RC"])
spec = importlib.util.spec_from_file_location("rc", src)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.EXPECTED_PREREQS = ["unit-rollcall", "preflight"]
mod.EXPECTED_COMMANDS = ["$(ROOT)/build/test_cadence"]
mod.IGNORED_COMMANDS = ["mkdir -p $(ROOT)/build"]
mf = tmpdir / "Makefile.add"
mf.write_text(
    "unit-unlocked: unit-rollcall preflight\n"
    "\tmkdir -p $(ROOT)/build\n"
    "\t$(ROOT)/build/test_cadence\n"
    "\t$(ROOT)/tests/unit/test_NEW_ADDITION_ONLY.sh\n",
    encoding="utf-8",
)
mod.MAKEFILE = mf
target = tmpdir / "we_add_target.py"
target.write_text(
    'EXPECTED_PREREQS = [\n'
    '    "unit-rollcall",\n'
    '    "preflight",\n'
    ']\n'
    'EXPECTED_COMMANDS = [\n'
    '    "$(ROOT)/build/test_cadence",\n'
    ']\n'
    'IGNORED_COMMANDS = [\n'
    '    "mkdir -p $(ROOT)/build",\n'
    ']\n',
    encoding="utf-8",
)
rc = mod.write_expected(mod.MAKEFILE, target)
print(target.read_text(encoding="utf-8"))
sys.exit(rc)
PY
)
rc=$?
set -e
echo "write_expected_add true rc=$rc"
add_hit=$(printf '%s\n' "$out" | grep -c 'test_NEW_ADDITION_ONLY' || true)
wrote_hit=$(printf '%s\n' "$out" | grep -c 'UNIT_ROLLCALL_WROTE_EXPECTED' || true)
echo "applied_matches add_hit=$add_hit wrote_hit=$wrote_hit"
if [[ "$rc" -eq 0 && "$add_hit" -ge 1 && "$wrote_hit" -eq 1 ]]; then
  note "write_expected_add PASS"
  pass=$((pass + 1))
else
  note "write_expected_add FAIL"
  printf '%s\n' "$out"
  fail=$((fail + 1))
fi

# --- --write-expected on in-sync copy of real tree ---
UNIT_ROLLCALL_MAKEFILE="$ROOT/Makefile"
cp "$ROLLCALL" "$TMPDIR_RC/we_sync.py"
set +e
out=$(python3 "$TMPDIR_RC/we_sync.py" --write-expected 2>&1)
rc=$?
set -e
echo "write_expected_noop_sync true rc=$rc"
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$out" | grep -qE 'UNIT_ROLLCALL_WROTE_EXPECTED|UNIT_ROLLCALL_OK'; then
  note "write_expected_noop_sync PASS"
  pass=$((pass + 1))
else
  note "write_expected_noop_sync FAIL"
  printf '%s\n' "$out"
  fail=$((fail + 1))
fi

# Real registry must still pass (never mutated)
UNIT_ROLLCALL_MAKEFILE="$ROOT/Makefile"
set +e
out=$(python3 "$ROLLCALL" 2>&1)
rc=$?
set -e
echo "post_write_real_registry true rc=$rc"
if [[ "$rc" -eq 0 ]]; then
  note "post_write_real_registry PASS"
  pass=$((pass + 1))
else
  note "post_write_real_registry FAIL"
  printf '%s\n' "$out"
  fail=$((fail + 1))
fi

echo "ROLLCALL_HOLE_RBG pass=$pass fail=$fail"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
exit 0
