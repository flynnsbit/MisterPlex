#!/usr/bin/env bash
# Idle-logo DDR frame-store integrity gate (ARM write path).
#
# WHAT IT LITERALLY COMPARES
#   The full I420 payload sitting in a live DDR frame-store bank
#   (read back through /dev/mem on the MiSTer) against the exact bytes the
#   product renderer (host/libmisterplex/idle_screen.hpp) produces for the same
#   idle mode at the product DDR geometry (624x480 coded, stride 624). The
#   comparison is positional and byte-exact over the whole frame, so a wrong
#   line stride, a pillarbox offset applied twice, or an unmasked partial first
#   burst per line all show up — none of which a byte-value spot check can see.
#
# WHAT IT DOES *NOT* COVER
#   * It says nothing about HDMI output. DDR content being correct does not mean
#     the RTL scans it out correctly; on a line-buffer miss ddr_frame_store.sv
#     forces the pixel to RGB(0,0,0) regardless of what is in DDR.
#   * It does not cover playback frames, only the idle screen (which the ARM
#     renders deterministically, so a reference exists).
#   * It does not prove the FPGA read the bank the ARM last published.
#
# CAN IT FAIL?
#   Yes, two ways. `--self-test` on the checker runs three synthetic damage
#   shapes that must be detected (stride, shift, left-edge run). And
#   IDLE_DDR_RED=1 compares the live bank against the *wrong* idle mode's
#   reference, which must fail.
#
# Usage:
#   MISTER_HOST=... MISTER_PASS=... tests/hw/test_idle_ddr_frame.sh [--bank 0|1]
#   IDLE_MODE=logo|black|screensaver  (default: read IDLE_SCREEN from the device)
# Exit 0 pass, 1 fail, 77 skip/unscored.
set -o pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER_NAME="${MISTER_USER:-root}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/hw/hw_gate_common.sh"

BANK="${IDLE_DDR_BANK:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bank) BANK="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

OUT="$ROOT/build/idle_ddr_frame"
mkdir -p "$OUT"

command -v sshpass >/dev/null 2>&1 || \
  hw_skip_not_pass "test_idle_ddr_frame" "sshpass is required to read the device DDR"

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
     -o LogLevel=ERROR "$USER_NAME@$HOST")

# Connectivity preflight. An unreachable device is UNSCORED (77), not a failure:
# reporting "the ARM writes the wrong bytes" because ssh timed out would be a
# true number about the wrong thing.
"${SSH[@]}" 'echo DEVICE_OK' > "$OUT/preflight.txt" 2>"$OUT/preflight.err"
rc=$?
if [[ $rc -ne 0 ]] || ! grep -q DEVICE_OK "$OUT/preflight.txt"; then
  hw_skip_not_pass "test_idle_ddr_frame" \
    "device $HOST unreachable (ssh rc=$rc): $(head -c 200 "$OUT/preflight.err")"
fi

# Provenance. This gate measures the ARM write path, which is independent of
# which bitstream is resident, so the resident md5 is *recorded* rather than
# pinned — but no claim may be made from this gate without it on the record.
"${SSH[@]}" 'md5sum /media/fat/_Utility/Plex.rbf' > "$OUT/rbf_md5.txt" 2>&1
RBF_MD5=$(tr 'A-F' 'a-f' < "$OUT/rbf_md5.txt" | grep -oE '\b[0-9a-f]{32}\b' | head -1)
[[ -n "$RBF_MD5" ]] || RBF_MD5=unknown
echo "RESIDENT_RBF_MD5 $RBF_MD5 (recorded, not pinned: this gate scores the ARM write path)"

# The daemon must actually have published a frame, or the bank holds whatever
# was there before and grading it proves nothing either way.
# NOTE: the MiSTer userland is busybox and has NO pgrep (rc=127). An earlier
# revision of this check used `pgrep -x` and reported DAEMON_DOWN on every run
# because 127 is falsy -- a false skip that would have silently disabled this
# gate forever. Use ps, and assert we can see ps output at all.
"${SSH[@]}" 'ps w 2>/dev/null || ps 2>/dev/null' > "$OUT/ps.txt" 2>&1
if [[ ! -s "$OUT/ps.txt" ]]; then
  hw_skip_not_pass "test_idle_ddr_frame" \
    "cannot enumerate processes on $HOST, so daemon liveness is unknown"
fi
if ! grep -q 'misterplexd' "$OUT/ps.txt"; then
  hw_skip_not_pass "test_idle_ddr_frame" \
    "misterplexd is not running, so no idle frame has been published to grade"
fi
echo "DAEMON_PRESENT $(grep -m1 misterplexd "$OUT/ps.txt" | awk '{print $1}')"

# Resolve the idle mode actually configured on the device unless overridden.
MODE="${IDLE_MODE:-}"
if [[ -z "$MODE" ]]; then
  "${SSH[@]}" 'grep -E "^IDLE_SCREEN=" /media/fat/misterplex/misterplex.conf' \
    > "$OUT/idle_mode.txt" 2>"$OUT/idle_mode.err"
  # No IDLE_SCREEN key means the daemon default, which is logo.
  MODE=$(sed -n 's/^IDLE_SCREEN=\([a-z]*\).*/\1/p' "$OUT/idle_mode.txt" 2>/dev/null)
  [[ -n "$MODE" ]] || MODE=logo
fi
case "$MODE" in
  logo|black|screensaver) ;;
  lastframe|last_frame)
    hw_skip_not_pass "test_idle_ddr_frame" \
      "IDLE_SCREEN=$MODE never repaints, so no reference payload exists" ;;
  *) hw_skip_not_pass "test_idle_ddr_frame" "unsupported IDLE_SCREEN=$MODE" ;;
esac

if [[ "$MODE" == "screensaver" ]]; then
  hw_skip_not_pass "test_idle_ddr_frame" \
    "screensaver phase is not observable from the host, so the reference is ambiguous"
fi

make -C "$ROOT" gen-idle-frame > "$OUT/gen_build.log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "FAIL could not build gen_idle_frame (rc=$rc); see $OUT/gen_build.log" >&2
  exit 1
fi

"$ROOT/build/gen_idle_frame" --mode "$MODE" --out "$OUT/ref_${MODE}.i420" \
  > "$OUT/gen_run.log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "FAIL gen_idle_frame rc=$rc; see $OUT/gen_run.log" >&2
  exit 1
fi

# Every DDR address is derived from host/libmisterplex/ddr_frame_layout.hpp so
# that the readback and the ARM writer cannot drift apart.
LAYOUT_ARGS=$(python3 "$ROOT/scripts/ddr_layout_consts.py" --dump-args)
rc=$?
if [[ $rc -ne 0 || -z "$LAYOUT_ARGS" ]]; then
  echo "FAIL cannot derive DDR layout from ddr_frame_layout.hpp (rc=$rc)" >&2
  exit 1
fi
echo "LAYOUT_ARGS $LAYOUT_ARGS"

"${SSH[@]}" "python3 - --bank $BANK $LAYOUT_ARGS" < "$ROOT/scripts/ddr_frame_dump_device.py" \
  > "$OUT/bank${BANK}.txt" 2>"$OUT/bank${BANK}.err"
rc=$?
if [[ $rc -eq 77 ]]; then
  hw_skip_not_pass "test_idle_ddr_frame" "device readback skipped: $(cat "$OUT/bank${BANK}.err")"
fi
if [[ $rc -ne 0 ]]; then
  echo "FAIL DDR readback rc=$rc: $(cat "$OUT/bank${BANK}.err")" >&2
  exit 1
fi

# A doorbell without the PLXK magic means the ARM never published to this
# window; grading stale memory would be scoring the wrong thing. Unscored (77).
if ! grep -q 'DOORBELL lo=0x504C584B' "$OUT/bank${BANK}.txt"; then
  hw_skip_not_pass "test_idle_ddr_frame" \
    "doorbell magic PLXK absent ($(grep -m1 DOORBELL "$OUT/bank${BANK}.txt")); no published frame to grade"
fi

REF="$OUT/ref_${MODE}.i420"
LABEL="live bank${BANK} idle mode=${MODE} host=${HOST}"
if [[ "${IDLE_DDR_RED:-0}" == "1" ]]; then
  # Deliberate red: grade the live bank against the wrong idle mode.
  WRONG=logo
  [[ "$MODE" == "logo" ]] && WRONG=black
  "$ROOT/build/gen_idle_frame" --mode "$WRONG" --out "$OUT/ref_${WRONG}.i420" \
    > "$OUT/gen_wrong.log" 2>&1
  REF="$OUT/ref_${WRONG}.i420"
  LABEL="$LABEL (RED: graded against mode=${WRONG})"
fi

python3 "$ROOT/scripts/check_idle_ddr_frame.py" --dump "$OUT/bank${BANK}.txt" \
  --ref "$REF" --label "$LABEL" > "$OUT/check_bank${BANK}.log" 2>&1
rc=$?
cat "$OUT/check_bank${BANK}.log"
exit $rc
