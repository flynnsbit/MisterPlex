#!/usr/bin/env bash
# Parent-only present-lag discriminator for the 117.10 ms A/V clusters.
#
# PURPOSE
#   Measure Δt = t(first PLXD frames_done++) − t(audio_release mono) and
#   convert to N = round(Δt / T_disp) with T_disp = 16.715600 ms (RTL).
#
#   PRE-REGISTERED meanings (do not reinterpret after measuring):
#     same N in cluster A and B  →  first-present lag is NOT the 117 ms cause
#     ΔN ≈ 7 between clusters    →  video present lag IS a viable discriminator
#     ΔN ≈ 3 @ content 24 fps    →  REJECTED by arithmetic (125 vs 117.10; err 7.9)
#
#   This script does NOT touch the device by default. It prints the recipe and
#   can optionally parse a parent-supplied log of (t_mono_ms, plxd_hi) samples.
#
# CONSTRAINTS
#   - Parent owns hardware. Agents must not ssh / deploy / fit.
#   - PLXD4 @ 0x300FF12C is VIDEO frames_done (high word of PLXD), not audio.
#   - Short captures have a common-mode ~25 ms startup transient — use first
#     flash/beep pair for cluster ID; lag N is a separate metric.
#
# Usage:
#   scripts/parent_plxd_present_lag_protocol.sh            # print recipe
#   scripts/parent_plxd_present_lag_protocol.sh parse FILE # compute N from log
#
# Log format (one sample per line, # comments ok):
#   t_mono_ms plxd_hi_hex
# Example:
#   12045.312 0x00070005
#   12050.100 0x00080005

set -euo pipefail

T_DISP_MS="16.715600"
# 7 * T_disp for reference (arithmetic only — mechanism NOT-FOUND in RTL)
SEVEN_T_MS=$(awk -v t="$T_DISP_MS" 'BEGIN{printf "%.6f", 7*t}')
PARENT_SEP_MS="117.10"
PRODUCT_PLXD4="0x300FF12C"
PRODUCT_PLXD="0x300FF128"

print_recipe() {
  cat <<EOF
=== parent_plxd_present_lag_protocol (w-geom) ===
tag=rtl-literal T_disp_ms=${T_DISP_MS}  (638*524/20e6; colorbars+pll)
tag=derived     7*T_disp_ms=${SEVEN_T_MS}  (arith vs parent_sep=${PARENT_SEP_MS})
tag=caller-supplied parent cluster sep ms = ${PARENT_SEP_MS}

PLXD addresses (product doorbell 0x300FF000):
  lo magic+status  ${PRODUCT_PLXD}   ("PLXD")
  hi frames_done   ${PRODUCT_PLXD4}  (bits[31:16]=frames_done)

PRE-REGISTERED:
  H0: N_A == N_B  → kill video-present-lag as 117 ms cause
  H1: |N_A - N_B| == 7  → video lag discriminates clusters (still need mechanism)
  H_KILL: |N_A - N_B| == 3 content frames @24fps  already REJECTED (125.00 vs 117.10)

RECIPE (parent on device; do not run from agent):
  1. Start playback of the A/V flash-beep fixture (same conf both clusters).
  2. Capture daemon mono time of the audio_release log line (or gate open).
  3. Poll PLXD4 with busybox devmem ${PRODUCT_PLXD4} 32 at ~1 ms until
     frames_done increments from the pre-start baseline.
  4. Record: t0_audio_release_ms, t1_first_frames_done_ms, plxd_hi_before, after.
  5. N = round( (t1-t0) / ${T_DISP_MS} )
  6. Repeat until both HDMI clusters A and B are observed (external measure).
  7. Compare N_A vs N_B against H0/H1 above. Publish miss if neither.

Optional log for this script:
  t_mono_ms  plxd_hi_hex
  ...
  Then: $0 parse path/to/log

NOTE: kernel MiSTer-audio-spi.c is OUT OF TREE — if H0 holds, residual suspect
is the audio handoff below /dev/MrAudio write (not in this repo).
EOF
}

parse_log() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "missing log: $f" >&2
    exit 2
  fi
  # Find first frames_done increase; require a baseline sample first.
  awk -v T="$T_DISP_MS" '
    BEGIN{FS="[ \t]+"; bas=-1; t0=""; n=0}
    /^#/ || NF<2 {next}
    {
      t=$1+0; hi=strtonum($2); fd=int(hi/65536);
      if (bas<0) { bas=fd; t_base=t; next }
      if (fd != bas && t1=="") { t1=t; fd1=fd; t0=t_base }
    }
    END{
      if (t1=="") { print "NO_INCREMENT: frames_done never moved"; exit 1 }
      dt=t1-t0;
      n=int(dt/T + 0.5);
      printf "baseline_fd=%d t_base=%.3f first_inc_fd=%d t1=%.3f dt_ms=%.3f N=%d T_disp=%s\n",
             bas, t_base, fd1, t1, dt, n, T;
      printf "PREDICTION_CHECK: compare this N across cluster A vs B (H0 same / H1 ΔN=7)\n";
    }
  ' "$f"
}

case "${1:-}" in
  parse)
    parse_log "${2:?usage: $0 parse FILE}"
    ;;
  ""|recipe|help|-h|--help)
    print_recipe
    ;;
  *)
    echo "usage: $0 [recipe|parse FILE]" >&2
    exit 2
    ;;
esac
