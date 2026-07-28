#!/usr/bin/env bash
# Red proofs for scripts/check_deadlogic_sink.py (Quartus failure mode 3:
# compiled + instantiated + elaborated, then deleted because the outputs drive
# nothing observable).
#
# w-audit measured 24 paths in this repo that exit 0 without doing any work.
# A new gate is assumed to be one of them until each of its verdicts has been
# made to flip on demand.  Every mutation below is applied, measured, and
# restored with `cmp -s` against a pre-mutation snapshot -- never `git diff
# --quiet`, which compares against HEAD and reads uncommitted work as an
# unrestored mutation.
#
# Exit codes: 0 pass, 1 fail.  This suite never returns 77 -- a gate inside
# `make unit` that exits 77 aborts the whole chain.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
GATE="python3 scripts/check_deadlogic_sink.py"
SP=fpga/Plex_MiSTer/rtl/stream_path.sv
SNAP=build/deadlogic_redproof_snapshot.sv
mkdir -p build

fails=0
pass() { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; fails=$((fails + 1)); }

# Positive control: modules confirmed PRESENT in the fitted silicon of
# fb4bad84 by post-fit hierarchy (the only final oracle).  If these ever read
# DEAD_SINK the analysis has become over-eager and its red verdicts are worth
# nothing.
LIVE_CTL="--require-live decode_stub --require-live line_buf_ram --require-live present_cadence"

echo "== baseline =="
$GATE $LIVE_CTL --label redproof-baseline > build/deadlogic_baseline.txt 2>&1
base_rc=$?
if [ "$base_rc" -ne 0 ]; then
	echo "  BASELINE NOT GREEN (rc=$base_rc) -- modules known present in fitted"
	echo "  silicon read DEAD_SINK, so this suite cannot prove anything."
	sed 's/^/    /' build/deadlogic_baseline.txt
	echo "SKIP-NOT-PASS deadlogic-sink-redproof: positive control is red"
	exit 1
fi
pass "positive control LIVE (decode_stub, line_buf_ram, present_cadence)"

echo "== red 1: unknown argument must be a usage error, never a silent pass =="
# The parent measured check_rtl_module_instantiations.py accepting --help and
# printing a confident green.  Anyone pasting a mandated command line at a gate
# that ignores unknown args gets exactly the evidence that is forbidden.
$GATE $LIVE_CTL --this-flag-does-not-exist > build/deadlogic_r1.txt 2>&1
[ $? -eq 2 ] && pass "unknown argument -> rc=2" || bad "unknown argument did not give rc=2"

echo "== red 2: no --require-live at all must not pass vacuously =="
$GATE --label empty > build/deadlogic_r2.txt 2>&1
[ $? -eq 2 ] && pass "no requirement -> rc=2" || bad "empty requirement list did not give rc=2"

echo "== red 3: a module that does not exist must fail, not pass =="
$GATE --require-live no_such_module_anywhere --label bogus > build/deadlogic_r3.txt 2>&1
r3=$?
if [ "$r3" -eq 1 ] && grep -q "NOT_INSTANTIATED\|NOT_DECLARED" build/deadlogic_r3.txt; then
	pass "unknown module -> rc=1 with a named reason"
else
	bad "unknown module gave rc=$r3 without a named reason"
fi

echo "== red 4: two identical probes, one observable and one not =="
# Self-contained mutation.  A red proof that depends on the exact shape of a
# peer's RTL goes stale the moment they refactor; these two probe modules are
# byte-identical apart from whether their output reaches a port of emu, so the
# ONLY thing the gate can be discriminating on is observability -- which is
# precisely the property Quartus uses to delete logic.
cp "$SP" "$SNAP" || exit 1
python3 tests/unit/deadlogic_probe_mutate.py
if [ $? -ne 0 ]; then
	cp "$SNAP" "$SP"
	bad "could not apply the probe mutation"
else
	$GATE --require-live dl_probe_dead --label probe-dead > build/deadlogic_r4a.txt 2>&1
	r4a=$?
	if [ "$r4a" -eq 1 ] && grep -q "dl_probe_dead=DEAD_SINK" build/deadlogic_r4a.txt; then
		pass "unobservable probe -> rc=1 DEAD_SINK"
	else
		bad "unobservable probe gave rc=$r4a without DEAD_SINK (mode 3 not detected)"
		sed 's/^/    /' build/deadlogic_r4a.txt
	fi
	$GATE --require-live dl_probe_live --label probe-live > build/deadlogic_r4b.txt 2>&1
	r4b=$?
	if [ "$r4b" -eq 0 ] && grep -q "dl_probe_live=LIVE" build/deadlogic_r4b.txt; then
		pass "observable probe -> rc=0 LIVE (gate is not stuck red)"
	else
		bad "observable probe gave rc=$r4b without LIVE -- gate reports dead unconditionally"
		sed 's/^/    /' build/deadlogic_r4b.txt
	fi
	cp "$SNAP" "$SP"
fi
if cmp -s "$SNAP" "$SP"; then
	pass "source restored (cmp -s against pre-mutation snapshot)"
else
	bad "SOURCE NOT RESTORED -- $SP differs from $SNAP"
fi

echo "== red 5: the analysis must refuse to run vacuously =="
# If UNUSEDSIGNAL is ever suppressed the dead-net seed is empty and every
# module reads LIVE for free.  The gate must fail instead of passing.
cp scripts/check_deadlogic_sink.py build/deadlogic_gate_snapshot.py || exit 1
python3 - <<'PY'
p = "scripts/check_deadlogic_sink.py"
s = open(p).read()
s = s.replace('WAIVERS = ["-Wno-fatal"', 'WAIVERS = ["-Wno-UNUSEDSIGNAL", "-Wno-fatal"', 1)
open(p, "w").write(s)
PY
$GATE $LIVE_CTL --label vacuous > build/deadlogic_r5.txt 2>&1
r5=$?
if [ "$r5" -eq 1 ] && grep -q "no UNUSEDSIGNAL warnings at all" build/deadlogic_r5.txt; then
	pass "suppressed UNUSEDSIGNAL -> rc=1 (refuses a vacuous LIVE)"
else
	bad "suppressed UNUSEDSIGNAL gave rc=$r5 -- a vacuous LIVE would be reported as proof"
	sed 's/^/    /' build/deadlogic_r5.txt
fi
cp build/deadlogic_gate_snapshot.py scripts/check_deadlogic_sink.py
if cmp -s build/deadlogic_gate_snapshot.py scripts/check_deadlogic_sink.py; then
	pass "gate restored (cmp -s against pre-mutation snapshot)"
else
	bad "GATE NOT RESTORED"
fi

echo "== red 6: the DOCUMENTED BLIND SPOT must stay documented =="
# Not a defect proof -- a boundary proof.  dl_probe_constfold has an observable
# output and folds to a constant, so Quartus deletes it while this gate reports
# LIVE.  Asserting the false green keeps the limitation honest: if anyone later
# teaches the gate constant propagation, THIS TEST FAILS and forces the
# docstring, the OK line and the handoff to be corrected together, instead of
# the gate quietly becoming stronger than its own documentation.
cp "$SP" "$SNAP" || exit 1
python3 tests/unit/deadlogic_probe_mutate.py --constfold
if [ $? -ne 0 ]; then
	cp "$SNAP" "$SP"
	bad "could not apply the constant-fold probe mutation"
else
	$GATE --require-live dl_probe_constfold --label blindspot > build/deadlogic_r6.txt 2>&1
	r6=$?
	if [ "$r6" -eq 0 ] && grep -q "dl_probe_constfold=LIVE" build/deadlogic_r6.txt; then
		pass "constant-fold collapse reports LIVE -- blind spot present as documented"
	else
		bad "constant-fold probe gave rc=$r6, not the documented false LIVE -- the gate has changed behaviour and its documented boundary is now WRONG; update the docstring, the OK line and the handoff"
		sed 's/^/    /' build/deadlogic_r6.txt
	fi
	cp "$SNAP" "$SP"
fi
if cmp -s "$SNAP" "$SP"; then
	pass "source restored (cmp -s against pre-mutation snapshot)"
else
	bad "SOURCE NOT RESTORED -- $SP differs from $SNAP"
fi

echo
if [ "$fails" -eq 0 ]; then
	echo "DEADLOGIC_SINK_REDPROOF_OK mutations=6 all_flipped=yes blind_spot=constant_fold_documented"
	exit 0
fi
echo "DEADLOGIC_SINK_REDPROOF_FAIL failures=$fails"
exit 1
