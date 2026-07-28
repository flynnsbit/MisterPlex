#!/usr/bin/env bash
# Red-proof for scripts/mailbox_window.py.
#
# The script's job is to stop a probe being aimed at a mailbox window the running
# fabric does not answer on. A wrong window returns stale frozen magics, which
# reads as "alive but silent" for EVERY build — so it silently destroys any A/B
# that depends on the counter advancing. A tool that quietly guesses the wrong
# address is therefore worse than no tool, and each red below is a way this
# script could produce a confidently wrong address.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 2
TOOL="${MAILBOX_WINDOW_TOOL:-scripts/mailbox_window.py}"
WORK="build/mailbox_window_reds"
FAILED=0

rc_of() { "$@" >/dev/null 2>&1; echo $?; }

ok()  { echo "OK   $*"; }
bad() { echo "FAIL $*"; FAILED=1; }

# Never read an exit code through a pipe: capture output and status separately.
run_capture() {
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  LAST_OUT="$out"
  LAST_RC=$rc
}

expect_rc() {
  local want="$1"; shift
  local what="$1"; shift
  run_capture "$@"
  if [ "$LAST_RC" = "$want" ]; then ok "$what (rc=$LAST_RC)"; else
    bad "$what expected rc=$want got rc=$LAST_RC"; fi
}

expect_says() {
  local want="$1"; shift
  local what="$1"; shift
  run_capture "$@"
  # -- so a pattern beginning with '-' is not parsed as an option.
  if printf '%s' "$LAST_OUT" | grep -qF -- "$want"; then ok "$what"; else
    bad "$what (missing: $want)"; fi
}

mkfixture() {
  # Synthetic, so the unit suite stays hermetic: a unit test that depends on a
  # remote branch being fetched either skips (halting `make unit` on exit 77) or
  # silently degrades. The constants below are transcribed from
  # rtl/ddr_frame_layout_params.svh; the real branch is checked separately as a
  # bonus assertion further down.
  local dir="$1"
  mkdir -p "$dir/rtl"
  cat > "$dir/rtl/ddr_frame_layout_params.svh" <<'SVH'
localparam int DDR_FRAME_RGB565_BANK_STRIDE   = 32'h000C_0000;
localparam int DDR_FRAME_YUV420P_BANK_STRIDE  = 32'h0008_0000;
localparam int DDR_FRAME_RGB565_DOORBELL_PHYS = 32'h3017_F000;
localparam int DDR_FRAME_YUV420P_DOORBELL_PHYS = 32'h300F_F000;
SVH
  cat > "$dir/rtl/present_core.sv" <<'SV'
ddr_frame_store #(
    .PHYS_BASE(32'h3000_0000),
    .HPS_BANK_STRIDE_BYTES(DDR_FRAME_YUV420P_BANK_STRIDE),
    .DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS)
) fstore ();
SV
  return 0
}

rm_rf() { [ -n "${1:-}" ] && [ -d "$1" ] && find "$1" -mindepth 1 -delete && rmdir "$1"; }

rm_rf "$WORK"
mkfixture "$WORK/base"

# ---------------------------------------------------------------- green
expect_rc 0 "green: synthetic YUV420p layout resolves cleanly" \
  python3 "$TOOL" --project "$WORK/base"

# The load-bearing assertion. If this address is ever wrong, every downstream
# probe is aimed at DDR that no core is writing.
expect_says "PLXD  0x300FF128" "green: PLXD resolves to the live window 0x300FF128" \
  python3 "$TOOL" --project "$WORK/base"
expect_says "0x00080000" "green: YUV420p bank stride is 0x80000" \
  python3 "$TOOL" --project "$WORK/base"
expect_says "PLXD 0x3007F128" "green: names 0x3007F128 as a DEAD window" \
  python3 "$TOOL" --project "$WORK/base"

# ---------------------------------------------------------------- red 1
# Radix regression. 32'h0008_0000 is all-digits; parsing it as decimal yields
# 0x13880 and a doorbell of 0x30026100. This is not hypothetical -- the first
# version of this script did exactly that, and only the independent
# PHYS+2*stride-4K derivation caught it.
run_capture python3 "$TOOL" --project "$WORK/base"
if printf '%s' "$LAST_OUT" | grep -qF -- "0x30026100"; then
  bad "red1: hex literal parsed as decimal (radix regression)"
else
  ok "red1: hex literal 32'h0008_0000 parsed as 0x80000, not decimal 80000"
fi

# ---------------------------------------------------------------- red 2
# Header doorbell must agree with the arithmetic derivation. Corrupt the header
# doorbell and the cross-check must refuse rather than print the header value.
cp -r "$WORK/base" "$WORK/mismatch"
sed -i "s/DDR_FRAME_YUV420P_DOORBELL_PHYS = 32'h300F_F000/DDR_FRAME_YUV420P_DOORBELL_PHYS = 32'h3007_F000/" \
  "$WORK/mismatch/rtl/ddr_frame_layout_params.svh"
expect_rc 1 "red2: header doorbell disagreeing with stride derivation fails" \
  python3 "$TOOL" --project "$WORK/mismatch"
expect_says "does not match the derivation" "red2: says which two values disagree" \
  python3 "$TOOL" --project "$WORK/mismatch"

# ---------------------------------------------------------------- red 3
# Two families referenced -> the instantiated one is ambiguous. Guessing here is
# how you get a confidently wrong address, so it must refuse.
cp -r "$WORK/base" "$WORK/ambiguous"
printf '\n// .HPS_BANK_STRIDE_BYTES(DDR_FRAME_RGB565_BANK_STRIDE)\n' \
  >> "$WORK/ambiguous/rtl/present_core.sv"
expect_rc 1 "red3: two layout families in present_core.sv refuses to guess" \
  python3 "$TOOL" --project "$WORK/ambiguous"
expect_says "refusing to guess" "red3: refusal is explicit" \
  python3 "$TOOL" --project "$WORK/ambiguous"

# ---------------------------------------------------------------- red 4
# No family referenced at all -> must not fall back to a default window.
cp -r "$WORK/base" "$WORK/nofamily"
sed -i 's/DDR_FRAME_YUV420P_BANK_STRIDE/SOME_OTHER_STRIDE/g; s/DDR_FRAME_YUV420P_DOORBELL_PHYS/SOME_OTHER_DOORBELL/g' \
  "$WORK/nofamily/rtl/present_core.sv"
expect_rc 1 "red4: no layout family found does not fall back to a default" \
  python3 "$TOOL" --project "$WORK/nofamily"

# ---------------------------------------------------------------- red 5
# Missing inputs must fail, not silently emit a plausible window.
cp -r "$WORK/base" "$WORK/noheader"
find "$WORK/noheader/rtl" -name 'ddr_frame_layout_params.svh' -delete
expect_rc 1 "red5: missing layout header fails" \
  python3 "$TOOL" --project "$WORK/noheader"

expect_rc 2 "red6: missing project directory fails" \
  python3 "$TOOL" --project "$WORK/does_not_exist"

# ---------------------------------------------------------------- red 7
# Fleet-wide trap: a checker that ignores unknown args hands anyone pasting a
# mandated command line a confident green. argparse must reject them.
expect_rc 2 "red7: unknown argument is a hard error" \
  python3 "$TOOL" --project "$WORK/base" --bogus-flag
expect_rc 2 "red8: a typo'd flag is not silently ignored" \
  python3 "$TOOL" --projct "$WORK/base"

# ---------------------------------------------------------------- scope
expect_says "does not prove the fabric is alive" \
  "scope: states it cannot prove liveness" python3 "$TOOL" --project "$WORK/base"

# ------------------------------------------------- bonus: the real branch
# The fixture above is a transcription, so it would keep passing if the real
# layout header changed underneath it. When the branch that produced the
# resident bitstream is available, assert against it directly. Unavailable is a
# NOTE, not a skip: this must never halt `make unit`, and it must never be
# mistaken for the hermetic assertions above.
REALDIR="$WORK/realbranch"
mkdir -p "$REALDIR/rtl"
if git show "origin/parent/integ-hour27:fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh" \
      > "$REALDIR/rtl/ddr_frame_layout_params.svh" 2>/dev/null \
   && git show "origin/parent/integ-hour27:fpga/Plex_MiSTer/rtl/present_core.sv" \
      > "$REALDIR/rtl/present_core.sv" 2>/dev/null \
   && [ -s "$REALDIR/rtl/present_core.sv" ]; then
  expect_says "PLXD  0x300FF128" \
    "bonus: origin/parent/integ-hour27 (source of fb4bad84) resolves PLXD to 0x300FF128" \
    python3 "$TOOL" --project "$REALDIR"
else
  echo "NOTE origin/parent/integ-hour27 not fetched; hermetic assertions above still ran"
fi
rm_rf "$REALDIR"

# ------------------------------------------------- probed-address validation
# The asymmetry this exists for: an ADVANCING counter proves its own instrument
# (a dead window is frozen and cannot advance), but a SILENT one does not -- a
# wedged live window and any dead window are byte-identical. So a null verdict
# needs separate proof the instrument was live.
expect_rc 1 "red9: probing the dead 0x3007F128 fails against a YUV420p build" \
  python3 "$TOOL" --project "$WORK/base" --probed 0x3007F128
expect_says "PROBE_WINDOW_FAIL" "red9: emits a machine-greppable verdict" \
  python3 "$TOOL" --project "$WORK/base" --probed 0x3007F128
expect_says "this build publishes PLXD at 0x300FF128" \
  "red9: names the address that should have been used" \
  python3 "$TOOL" --project "$WORK/base" --probed 0x3007F128
expect_rc 1 "red10: RGB565's 0x3017F128 is also rejected for a YUV420p build" \
  python3 "$TOOL" --project "$WORK/base" --probed 0x3017F128
expect_rc 1 "red11: a malformed address is rejected, not ignored" \
  python3 "$TOOL" --project "$WORK/base" --probed notanaddress
expect_rc 1 "red12: one bad address among good ones still fails" \
  python3 "$TOOL" --project "$WORK/base" --probed 0x300FF128 --probed 0x3007F128
expect_rc 0 "green: the live PLXD/PLXS addresses validate" \
  python3 "$TOOL" --project "$WORK/base" --probed 0x300FF128 --probed 0x300FF100
expect_says "PROBE_WINDOW_OK" "green: emits the positive verdict" \
  python3 "$TOOL" --project "$WORK/base" --probed 0x300FF128

rm_rf "$WORK/mismatch"; rm_rf "$WORK/ambiguous"; rm_rf "$WORK/nofamily"
rm_rf "$WORK/noheader"; rm_rf "$WORK/base"; rm_rf "$WORK"

if [ "$FAILED" = 0 ]; then
  echo "MAILBOX_WINDOW_RESULT=PASS"
  exit 0
fi
echo "MAILBOX_WINDOW_RESULT=FAIL"
exit 1
