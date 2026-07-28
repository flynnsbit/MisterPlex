#!/usr/bin/env bash
# Vacuous-control proof for the full-frame deblock gate.
#
# The parent published "netlist-neutral -- exonerated by measurement" on the
# strength of four builds that all carried the SAME new SDC.  The comparison
# never varied the independent variable, so it demonstrated fitter determinism
# and nothing else.  The general test is mechanical, not a matter of
# remembering: DOES THIS COMPARISON ACTUALLY DIFFER IN THE THING IT CLAIMS TO
# TEST?
#
# tests/unit/test_h264_deblock_mb_full_frame.sh compares the product RTL filter
# against an independent clause-8.7 model in tests/rtl/h264_deblock_ref.hpp.
# I flagged the risk myself and never closed it: if the model's alpha/beta/tc0
# tables were the SAME storage as the RTL's, the comparison could never detect a
# table error, and 1170/1170 would be worth what the parent's four builds were
# worth.
#
# This applies the mechanical test.  Each normative table in the RTL is
# perturbed by one entry; the gate must go RED.  A mutation that stays green
# means either the tables are shared or that entry is never exercised -- both
# are vacuity, and both are reported as failures here.
#
# Exit codes: 0 pass, 1 fail.  Never 77 (77 inside make unit aborts the chain).
set -u
# Never read an exit code through a pipe: the repo enforces this mechanically
# via scripts/check_pipe_exit_safety.py, which caught this file.
set -o pipefail
cd "$(dirname "$0")/../.." || exit 1

RTL=fpga/Plex_MiSTer/rtl/h264_deblock.sv
REF=tests/rtl/h264_deblock_ref.hpp
SNAP=build/deblock_table_snapshot.sv
GATE=./tests/unit/test_h264_deblock_mb_full_frame.sh
mkdir -p build

fails=0
pass() { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; fails=$((fails + 1)); }

echo "== independent storage =="
# Physical independence is necessary but NOT sufficient: it does not rule out
# the two copies having been transcribed from each other, which no mechanical
# check can see.  It is reported so the claim is never stronger than the test.
if grep -q "h264_deblock\.sv\|include.*deblock.*sv" "$REF"; then
	bad "$REF includes the RTL -- the model is not an independent oracle"
else
	pass "reference model does not include the RTL (separate storage)"
fi

echo "== baseline =="
$GATE > build/deblock_table_baseline.txt 2>&1
if [ $? -ne 0 ]; then
	bad "baseline gate is not green; mutations below would prove nothing"
	sed 's/^/    /' build/deblock_table_baseline.txt | tail -5
	echo "DEBLOCK_TABLE_VACUITY_FAIL failures=$fails"
	exit 1
fi
pass "baseline full-frame gate green"

# entry:replacement pairs, one per normative table (clause 8.7.2.2 Table 8-16
# alpha and beta, Table 8-17 tc0).  Values chosen inside the QP range the frame
# actually exercises (qp_range=3..33 as reported by the gate itself).
mutate_and_expect_red() {
	local label="$1" pattern="$2" replacement="$3"
	cp "$RTL" "$SNAP" || return 1
	if ! grep -qF "$pattern" "$RTL"; then
		bad "$label: mutation target not found: $pattern"
		return 0
	fi
	python3 - "$RTL" "$pattern" "$replacement" <<'PY'
import sys
path, pat, rep = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
assert pat in s, pat
open(path, "w").write(s.replace(pat, rep, 1))
PY
	if [ $? -ne 0 ]; then
		cp "$SNAP" "$RTL"
		bad "$label: mutation failed to apply"
		return 0
	fi
	if cmp -s "$SNAP" "$RTL"; then
		cp "$SNAP" "$RTL"
		bad "$label: mutation was a no-op -- the independent variable did not vary"
		return 0
	fi
	$GATE > "build/deblock_table_${label}.txt" 2>&1
	local rc=$?
	cp "$SNAP" "$RTL"
	if ! cmp -s "$SNAP" "$RTL"; then
		bad "$label: SOURCE NOT RESTORED"
		return 0
	fi
	if [ "$rc" -ne 0 ]; then
		pass "$label: perturbed table -> gate RED (comparison is not vacuous)"
	else
		bad "$label: perturbed table -> gate STILL GREEN. Either the model shares the RTL's table, or this entry is never exercised. Both make 1170/1170 worthless for this table."
	fi
}

mutate_and_expect_green() {
	local label="$1" pattern="$2" replacement="$3"
	cp "$RTL" "$SNAP" || return 1
	if ! grep -qF "$pattern" "$RTL"; then
		bad "$label: mutation target not found: $pattern"
		return 0
	fi
	python3 - "$RTL" "$pattern" "$replacement" <<'PY'
import sys
path, pat, rep = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
assert pat in s, pat
open(path, "w").write(s.replace(pat, rep, 1))
PY
	if cmp -s "$SNAP" "$RTL"; then
		cp "$SNAP" "$RTL"
		bad "$label: mutation was a no-op -- the independent variable did not vary"
		return 0
	fi
	$GATE > "build/deblock_table_${label}.txt" 2>&1
	local rc=$?
	cp "$SNAP" "$RTL"
	if [ "$rc" -eq 0 ]; then
		pass "$label: +-1 perturbation NOT detected -- documented sensitivity limit holds"
	else
		bad "$label: +-1 perturbation IS now detected. The gate got stronger than its documentation: update the sensitivity claim in this file and in the handoff."
	fi
}

echo "== red: does the comparison vary the thing it claims to test? =="
# GROSS perturbation. If the model shared the RTL's table, BOTH sides would move
# together and the frame would still match. These going red is the measurement
# that refutes the shared-storage hypothesis I raised against my own gate.
mutate_and_expect_red alpha_gross "6'd30: alpha_lut = 8'd25;" "6'd30: alpha_lut = 8'd0;"
mutate_and_expect_red beta_gross  "6'd30: beta_lut = 8'd8;"   "6'd30: beta_lut = 8'd0;"
mutate_and_expect_red tc0_gross   "9'o363: tc0 = 6'd2;"       "9'o363: tc0 = 6'd3;"
mutate_and_expect_red alpha_pm1   "6'd20: alpha_lut = 8'd7;"  "6'd20: alpha_lut = 8'd8;"

echo "== boundary: the sensitivity limit, asserted so it cannot rot =="
# MEASURED: a +-1 table error is detected at alpha[20] but NOT at alpha[28],
# alpha[30], alpha[33], beta[28] or beta[30]. The filter decision only changes
# if some sample pair sits exactly on the moved threshold, and this frame's
# content does not straddle those. So "1170/1170" is a MACROBLOCK denominator,
# not a table-entry one: it does not mean every table entry is verified to +-1.
#
# Asserted rather than described, for the same reason as the constant-fold blind
# spot: if richer content later makes these detectable, THIS TEST FAILS and
# forces the claim to be re-stated instead of the gate quietly becoming stronger
# than its own documentation.
mutate_and_expect_green alpha_pm1_insensitive "6'd30: alpha_lut = 8'd25;" "6'd30: alpha_lut = 8'd26;"
mutate_and_expect_green beta_pm1_insensitive  "6'd30: beta_lut = 8'd8;"   "6'd30: beta_lut = 8'd9;"

echo
if [ "$fails" -eq 0 ]; then
	echo "DEBLOCK_TABLE_VACUITY_OK tables=3 gross_perturbations_detected=3/3" \
	     "pm1_detected_at=alpha[20] pm1_NOT_detected_at=alpha[28,30,33],beta[28,30]"
	echo "  The model is an INDEPENDENT oracle: gross table perturbations are"
	echo "  detected, so the comparison does vary the thing it claims to test."
	echo "  NOT PROVEN: (a) sensitivity to a +-1 table error at every index --"
	echo "  1170/1170 is a macroblock denominator, not a table-entry one;"
	echo "  (b) that either copy matches the H.264 standard. Both were typed by"
	echo "  hand from clause 8.7.2.2, and a transcription error made identically"
	echo "  on both sides is invisible to any comparison between them."
	exit 0
fi
echo "DEBLOCK_TABLE_VACUITY_FAIL failures=$fails"
exit 1
