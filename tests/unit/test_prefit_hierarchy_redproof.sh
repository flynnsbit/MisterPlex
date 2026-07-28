#!/usr/bin/env bash
# Red proofs for scripts/check_prefit_hierarchy.py.
#
# w-audit found 24 paths in this repository that exit 0 without doing any work.
# A new gate is assumed to be the 25th until mutation says otherwise. Each case
# mutates the tree, asserts the gate goes RED, restores, and asserts it goes
# GREEN again.
#
# Cases 1-3 are the three failure modes that have actually shipped or nearly
# shipped in this project:
#   1. instantiation hidden in a disabled generate  (source checkers false-GREEN)
#   2. RTL file absent from files.qip               (w-fit-o5, never compiled)
#   3. core orphaned from emu                       (fb4bad84, no decoder in silicon)
# Case 4 attacks this gate's own allowlist, which is the same hand-maintained
# attack surface w-fit-o5 flagged in check_qip_coverage.py.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT/scripts/check_prefit_hierarchy.py"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/h264_decode_core.sv"
STREAM="$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
BBOX="$ROOT/tests/rtl/prefit_blackbox/altera_blackbox.sv"
WORK="$ROOT/build/prefit-redproof"
mkdir -p "$WORK"

if [[ ! -f "$GATE" ]]; then
  echo "SKIP-NOT-PASS test_prefit_hierarchy_redproof: missing $GATE" >&2
  exit 77
fi

BASE_ARGS=(--label redproof --require h264_decode_core --require h264_deblock_mb_filter)

snap() { cat "$2" > "$WORK/$1"; }
restore() { cat "$WORK/$1" > "$2"; }

snap core.orig "$CORE"
snap stream.orig "$STREAM"
snap qip.orig "$QIP"
snap bbox.orig "$BBOX"

restore_all() {
  restore core.orig "$CORE"
  restore stream.orig "$STREAM"
  restore qip.orig "$QIP"
  restore bbox.orig "$BBOX"
}
trap restore_all EXIT

run_gate() {
  python3 "$GATE" "$@" > "$WORK/last.log" 2>&1
  echo $?
}

FAILURES=0

expect_red() {
  local what="$1"; local needle="$2"; shift 2
  local rc; rc=$(run_gate "$@")
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL prefit-redproof: $what -- gate PASSED a mutated tree (rc=0)" >&2
    sed -n '1,15p' "$WORK/last.log" >&2
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [[ "$rc" -eq 77 ]]; then
    echo "FAIL prefit-redproof: $what -- gate SKIPPED (rc=77); a skip is not a red" >&2
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! grep -q "$needle" "$WORK/last.log"; then
    echo "FAIL prefit-redproof: $what -- went red (rc=$rc) but without the expected" >&2
    echo "  diagnostic '$needle'; a red for the wrong reason is not a red proof" >&2
    sed -n '1,15p' "$WORK/last.log" >&2
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "OK prefit-redproof red: $what (rc=$rc)"
}

expect_green() {
  local what="$1"; shift
  local rc; rc=$(run_gate "$@")
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL prefit-redproof: $what -- expected green, got rc=$rc" >&2
    sed -n '1,20p' "$WORK/last.log" >&2
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "OK prefit-redproof green: $what"
}

expect_green "baseline unmutated tree" "${BASE_ARGS[@]}"

# ── 1. instantiation hidden in a disabled generate ─────────────────────────
# w-audit measured check_rtl_module_instantiations.py reporting this as
# REACHABLE. An elaborator must disagree.
python3 - "$CORE" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
head = "    h264_deblock_mb_filter u_core_deblock_mb ("
i = text.index(head)
j = text.index(");", text.index(".unsupported_ref", i)) + 2
inst = text[i:j]
open(path, "w").write(
    text[:i] + "    generate if (1'b0) begin : g_dead_prefit\n" + inst
    + "\n    end endgenerate\n" + text[j:])
PY
expect_red "filter hidden in a disabled generate" "PREFIT_HIER_ABSENT h264_deblock_mb_filter" "${BASE_ARGS[@]}"
restore core.orig "$CORE"
expect_green "core restored" "${BASE_ARGS[@]}"

# ── 2. RTL file tracked in git but absent from files.qip ───────────────────
# w-fit-o5 measured exactly this on the branch fb4bad84 was built from.
grep -v 'rtl/h264_deblock\.sv' "$WORK/qip.orig" > "$QIP"
expect_red "h264_deblock.sv removed from files.qip" "PREFIT_HIER_FAIL" "${BASE_ARGS[@]}"
restore qip.orig "$QIP"
expect_green "files.qip restored" "${BASE_ARGS[@]}"

# ── 3. core orphaned from emu ──────────────────────────────────────────────
# This is the fb4bad84 failure mode: the module compiles, but nothing in the
# emu lineage instantiates it, so there is no decoder in the chip.
python3 - "$STREAM" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
# The core is instantiated with a parameter list: "h264_decode_core #(".
# Match the instantiation site specifically, never the module declaration.
new, n = re.subn(r"(?<!module )\bh264_decode_core\b(?=\s*#?\s*\()",
                 "h264_decode_core_orphaned", text, count=1)
if n != 1:
    sys.exit("could not find the h264_decode_core instantiation to orphan")
open(path, "w").write(new)
PY
expect_red "core no longer instantiated by stream_path" "PREFIT_HIER_FAIL" "${BASE_ARGS[@]}"
restore stream.orig "$STREAM"
expect_green "stream_path restored" "${BASE_ARGS[@]}"

# ── 4. rogue entry in the blackbox allowlist file ──────────────────────────
# A stub can make an absent module look present. That is this gate's own
# equivalent of check_qip_coverage.py's hand-maintained ALLOWED_ABSENT list.
printf '\nmodule h264_deblock_mb_filter_smuggled (input wire clk);\nendmodule\n' >> "$BBOX"
expect_red "decode-shaped module smuggled into the blackbox stub file" \
  "outside the vendor allowlist" "${BASE_ARGS[@]}"
restore bbox.orig "$BBOX"
expect_green "blackbox stub file restored" "${BASE_ARGS[@]}"

# ── 5. the gate must not silently pass an unknown module ───────────────────
expect_red "requiring a module that does not exist" "PREFIT_HIER_ABSENT no_such_module" \
  --label redproof --require no_such_module

# ── 6. stale Verilator output must not fake a pass ─────────────────────────
# Verilator writes the modules that survive elaboration; it does not delete the
# ones that stopped surviving. Reusing an output directory therefore let a
# mutated tree read as green, which is how this gate failed its own first red
# proof. Prove the purge is real: plant a header for a module that is not in
# the design and confirm the gate does not count it.
MDIR="$ROOT/build/prefit-redproof-stale"
mkdir -p "$MDIR"
printf '// planted stale artefact\n' > "$MDIR/Vemu_h264_totally_fictional_module.h"
expect_red "planted stale header for a module that is not in the design" \
  "PREFIT_HIER_ABSENT h264_totally_fictional_module" \
  --label redproof --require h264_totally_fictional_module --mdir build/prefit-redproof-stale
if [[ -f "$MDIR/Vemu_h264_totally_fictional_module.h" ]]; then
  echo "FAIL prefit-redproof: planted stale header survived the purge" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "OK prefit-redproof: stale header was purged before elaboration"
fi

# ── 7. unknown arguments must be a hard error ──────────────────────────────
# The parent measured check_rtl_module_instantiations.py on parent/integ-hour27
# silently accepting unknown args and printing a confident green.
python3 "$GATE" --not-a-real-flag > "$WORK/unknown.log" 2>&1
UNKNOWN_RC=$?
if [[ "$UNKNOWN_RC" -eq 0 ]]; then
  echo "FAIL prefit-redproof: gate accepted an unknown argument and exited 0" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "OK prefit-redproof red: unknown argument rejected (rc=$UNKNOWN_RC)"
fi

trap - EXIT
restore_all
for pair in "core.orig:$CORE" "stream.orig:$STREAM" "qip.orig:$QIP" "bbox.orig:$BBOX"; do
  if ! cmp -s "$WORK/${pair%%:*}" "${pair#*:}"; then
    echo "FAIL prefit-redproof: ${pair#*:} was not restored cleanly" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

if [[ "$FAILURES" -ne 0 ]]; then
  echo "FAIL check_prefit_hierarchy red-proofs: $FAILURES case(s) failed" >&2
  exit 1
fi
echo "OK check_prefit_hierarchy red-proofs: 7 mutations detected, tree restored clean"
