#!/usr/bin/env bash
# Red-proof gate for scripts/check_product_reachability.py (W-DEBLOCK-O5).
#
# w-audit found 24 paths in this repository that can exit 0 without doing any
# work, and then broke the core-subtree reachability gate within an hour of it
# being declared binding.  check_product_reachability.py is a *new* instrument,
# so it is assumed to be defective until each of its checks is shown to go red
# on a deliberate mutation and green again on restore.
#
# The four mutations below are w-audit's own, re-aimed at this helper:
#   1. subtree broken            -> must fail
#   2. required module undefined -> must fail
#   3. RTL file tracked in git but absent from files.qip (w-audit's worst
#      finding: passes every reachability check while not being in the design)
#                                -> must fail
#   4. escaped instance name in stream_path.sv.  The underlying regex checker
#      reads a legal escaped instance as *unreachable*; this helper cross-reads
#      stream_path.sv, so the disagreement surfaces as a broken product trunk
#                                -> must fail
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT/scripts/check_product_reachability.py"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
STREAM="$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
WORK="$ROOT/build/w-deblock-o5-reach-redproof"
mkdir -p "$WORK"

for f in "$HELPER" "$QIP" "$STREAM"; do
  [[ -f "$f" ]] || { echo "REACH REDPROOF ERROR: missing $f" >&2; exit 2; }
done

BASE_ARGS=(
  --label reach_redproof
  --require h264_deblock_mb_filter
  --require h264_deblock_qpc
  --require h264_deblock_writeback_ctrl
)

# Never read an exit code through a pipe: capture to a file, then read $?.
run_helper() {
  local out="$1"; shift
  set +e
  python3 "$HELPER" "$@" >"$out" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

expect_green() {
  local label="$1"; shift
  local out="$WORK/green.log" rc
  rc="$(run_helper "$out" "$@")"
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL reach-redproof: baseline '$label' should be green but rc=$rc" >&2
    cat "$out" >&2
    exit 1
  fi
  if ! grep -q 'PRODUCT_REACH_OK' "$out"; then
    echo "FAIL reach-redproof: baseline '$label' rc=0 without a PRODUCT_REACH_OK verdict" >&2
    cat "$out" >&2
    exit 1
  fi
  echo "OK reach-redproof green: $label -> $(grep -o 'scope=[A-Z_]*' "$out" | head -1)"
}

expect_red() {
  local label="$1" needle="$2"; shift 2
  local out="$WORK/red.log" rc
  rc="$(run_helper "$out" "$@")"
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL reach-redproof: mutation '$label' was not detected (rc=0)" >&2
    cat "$out" >&2
    exit 1
  fi
  if ! grep -q "$needle" "$out"; then
    echo "FAIL reach-redproof: mutation '$label' failed for the wrong reason" >&2
    echo "  expected diagnostic matching: $needle" >&2
    cat "$out" >&2
    exit 1
  fi
  echo "OK reach-redproof red: $label"
}

restore() {
  local backup="$1" target="$2"
  [[ -f "$backup" ]] || { echo "REACH REDPROOF ERROR: lost backup $backup" >&2; exit 2; }
  cat "$backup" > "$target"
}

# ── baseline ────────────────────────────────────────────────────────────────
expect_green "unmutated tree" "${BASE_ARGS[@]}"

# ── mutation 1: subtree broken ──────────────────────────────────────────────
# Deliberately self-contained: an earlier version of this case required a peer
# module (h264_inter_mc_part) to be absent from the core, and went stale the
# moment w-decode-o5 legitimately landed MC under the core.  Mutating our own
# instantiation instead is branch-independent -- it stays a valid red however
# the integration around it moves.
CORE="$ROOT/fpga/Plex_MiSTer/rtl/h264_decode_core.sv"
cat "$CORE" > "$WORK/h264_decode_core.sv.orig"
trap 'restore "$WORK/h264_decode_core.sv.orig" "$CORE"' EXIT
python3 - "$CORE" <<'MUT'
import sys
path = sys.argv[1]
text = open(path).read()
head = "h264_deblock_mb_filter u_core_deblock_mb ("
i = text.index(head)
open(path, "w").write(
    text[:i] + "h264_deblock_mb_filter_RENAMED_BY_REDPROOF u_core_deblock_mb ("
    + text[i + len(head):])
MUT
expect_red "h264_deblock_mb_filter no longer instantiated under h264_decode_core" \
  'REQUIRED_RTL_MODULE_UNREACHABLE h264_deblock_mb_filter' \
  --label reach_redproof --require h264_deblock_mb_filter
restore "$WORK/h264_decode_core.sv.orig" "$CORE"
trap - EXIT
expect_green "h264_decode_core.sv restored" "${BASE_ARGS[@]}"

# ── mutation 2: required module does not exist ──────────────────────────────
expect_red "required module has no RTL definition" \
  'no RTL file defines module h264_deblock_no_such_module_zzz' \
  --label reach_redproof --require h264_deblock_no_such_module_zzz

# ── mutation 3: RTL file absent from files.qip ──────────────────────────────
# This is the mutation nothing in the repository caught before: the graph is
# perfectly happy, the file is tracked in git, and Quartus never compiles it.
cat "$QIP" > "$WORK/files.qip.orig"
trap 'restore "$WORK/files.qip.orig" "$QIP"; restore "$WORK/stream_path.sv.orig" "$STREAM" 2>/dev/null || true' EXIT
grep -v 'rtl/h264_deblock.sv' "$WORK/files.qip.orig" > "$QIP"
if grep -q 'rtl/h264_deblock.sv' "$QIP"; then
  echo "FAIL reach-redproof: could not remove h264_deblock.sv from files.qip" >&2
  exit 1
fi
expect_red "h264_deblock.sv tracked in git but absent from files.qip" \
  'is not listed in files.qip' "${BASE_ARGS[@]}"
# The per-module check above only sees files defining a --require'd module.
# w-fit-o5's whole-tree gate is what catches a product file nobody happened to
# name, so assert it independently noticed this same file go missing.
if ! grep -q 'qip_coverage|.*h264_deblock\.sv' "$WORK/red.log"; then
  echo "FAIL reach-redproof: whole-tree check_qip_coverage did not report h264_deblock.sv" >&2
  echo "  (a product claim must not survive an incomplete Quartus file list)" >&2
  cat "$WORK/red.log" >&2
  exit 1
fi
echo "OK reach-redproof red: check_qip_coverage independently saw h264_deblock.sv leave files.qip"
restore "$WORK/files.qip.orig" "$QIP"
expect_green "files.qip restored" "${BASE_ARGS[@]}"

# ── mutation 4: escaped instance name in stream_path.sv ─────────────────────
# Legal SystemVerilog that check_rtl_module_instantiations.py mis-reads as
# "not instantiated".  The helper must notice stream_path.sv does instantiate
# the product root while emu cannot reach it, and call that broken wiring.
cat "$STREAM" > "$WORK/stream_path.sv.orig"
python3 - "$STREAM" <<'MUT'
import re, sys
path = sys.argv[1]
text = open(path).read()
# Disable any real instantiation first, so the only remaining reference to the
# product root is the escaped one.  The regex checker cannot see escaped
# instance names, so it reports the core as unreachable while the source plainly
# instantiates it -- exactly the disagreement this helper must call out.
text = re.sub(r"^(\s*)h264_decode_core(\s*#?)", r"\1h264_decode_core_DISABLED_BY_REDPROOF\2",
              text, flags=re.MULTILINE)
marker = "\nh264_decode_core \\w_deblock.escaped_probe ();\n"
m = re.search(r"^endmodule\s*$", text, re.MULTILINE)
if not m:
    sys.exit("no endmodule in stream_path.sv")
open(path, "w").write(text[:m.start()] + marker + text[m.start():])
MUT
expect_red "escaped instance of h264_decode_core in stream_path.sv" \
  'the product trunk is broken' "${BASE_ARGS[@]}"
restore "$WORK/stream_path.sv.orig" "$STREAM"
expect_green "stream_path.sv restored" "${BASE_ARGS[@]}"

trap - EXIT
if ! git -C "$ROOT" diff --quiet -- "$QIP" "$STREAM" "$CORE"; then
  echo "FAIL reach-redproof: mutated files were not restored cleanly" >&2
  git -C "$ROOT" --no-pager diff --stat -- "$QIP" "$STREAM" "$CORE" >&2
  exit 1
fi

echo "OK check_product_reachability red-proofs: 5 mutations detected, tree restored clean"
echo "NOTE: source-level reachability is a pre-filter in both directions."
echo "NOTE: make post-fit-hierarchy remains the only oracle for what is in the bitstream."
