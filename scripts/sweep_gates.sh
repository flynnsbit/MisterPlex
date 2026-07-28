#!/usr/bin/env bash
# W-DECODE-O5 gate sweep.
#
# Runs every gate command in the `unit-unlocked` and `rtl-sim-unlocked` Makefile
# recipes individually, so one failing gate cannot mask the rest and so a
# truncated gate list cannot masquerade as a pass.  This exists because an
# earlier ad-hoc version of this sweep silently executed only 53 of 102 gates
# and produced a "53/53 rc=0" figure that had to be publicly withdrawn.
#
# Hard-won requirements encoded here:
#   * $(ROOT)/$(UNIT_ANNEXB) must be substituted -- unexpanded make variables
#     produce rc=127 that reads like an RTL regression.
#   * backslash continuations must be joined, or a single gate is counted as
#     several broken fragments.
#   * exit codes are read from $? directly, NEVER through a pipe.
#   * exit 77 is a SKIP and is counted separately -- a skip is not a pass.
#
# Usage: scripts/sweep_gates.sh [outdir]
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/sweep}"
mkdir -p "$OUT"

UNIT_ANNEXB="$(grep -E '^UNIT_ANNEXB[[:space:]]*[:?]?=' "$ROOT/Makefile" |
	head -1 | sed 's/^[^=]*=[[:space:]]*//')"
UNIT_ANNEXB="${UNIT_ANNEXB:-build/plex_real_baseline.264}"
# UNIT_ANNEXB's own value may contain $(ROOT); expand it here or substituting it
# into a recipe re-introduces an unexpanded token that fails as rc=1/127.
UNIT_ANNEXB="${UNIT_ANNEXB//\$(ROOT)/$ROOT}"
UNIT_ANNEXB="${UNIT_ANNEXB#$ROOT/}"

# Derive recipe line ranges rather than hard-coding them: the gate blocks move.
range_for() {
	local target="$1"
	local start end
	start="$(grep -n "^${target}:" "$ROOT/Makefile" | head -1 | cut -d: -f1)"
	[ -n "$start" ] || return 1
	end="$(awk -v s="$start" 'NR>s && /^[a-zA-Z_-]+:/ {print NR; exit}' "$ROOT/Makefile")"
	end="${end:-$(wc -l < "$ROOT/Makefile")}"
	echo "$start $end"
}

collect() {
	local target="$1" start end
	read -r start end < <(range_for "$target") || return 0
	awk -v s="$start" -v e="$end" 'NR>s && NR<e' "$ROOT/Makefile" |
		awk '/^\t/' |
		sed 's/^\t//' |
		# join backslash continuations into one logical command
		sed ':a;/\\$/{N;s/\\\n[[:space:]]*/ /;ba}' |
		grep -vE '^[@-]' |
		sed "s#\$(UNIT_ANNEXB)#$UNIT_ANNEXB#g; s#\$(ROOT)#$ROOT#g"
}

# test_status_telemetry depends on a generated fixture produced by an
# '@'-prefixed recipe line that the filter above deliberately drops.
python3 "$ROOT/scripts/gen_test_annexb_real.py" "$ROOT/$UNIT_ANNEXB" \
	> "$OUT/_fixture.log" 2>&1

pass=0; fail=0; skip=0; n=0
: > "$OUT/summary.txt"

while IFS= read -r cmd; do
	[ -n "${cmd// }" ] || continue
	case "$cmd" in \#*) continue;; esac
	n=$((n + 1))
	log="$OUT/gate_$(printf '%03d' "$n").log"
	( cd "$ROOT" && eval "$cmd" ) > "$log" 2>&1
	rc=$?
	case "$rc" in
		0)  pass=$((pass + 1)); verdict=PASS ;;
		77) skip=$((skip + 1)); verdict=SKIP ;;
		*)  fail=$((fail + 1)); verdict=FAIL ;;
	esac
	printf '%s rc=%d %s\n' "$verdict" "$rc" "$cmd" >> "$OUT/summary.txt"
done < <(collect unit-unlocked; collect rtl-sim-unlocked)

echo "SWEEP total=$n pass=$pass fail=$fail skip=$skip"
grep -E '^(FAIL|SKIP)' "$OUT/summary.txt"
[ "$fail" -eq 0 ] && [ "$skip" -eq 0 ] && [ "$n" -gt 0 ]
