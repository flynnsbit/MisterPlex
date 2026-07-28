# Decode numeric fixture mutation audit

Pre-registered prediction before the audit: **SOUND=6, VACUOUS=2, OVER-TIGHT=1** among sampled high-risk decode numeric fixtures.

Observed result after mutation testing: **SOUND=7, VACUOUS=2 (both closed here), OVER-TIGHT=0**. The over-tight prediction did not reproduce in numeric fixtures; the source-shape over-tightness remains in source-text invariants, not in these sampled numeric comparisons.

## Findings

| Area | Property | Mutation | Evidence | Verdict |
| --- | --- | --- | --- | --- |
| DPB/MC | U distinguished from V | `i420_addr` V phase reads plane `2'd1` instead of `2'd2` | `FAIL h264_dpb_mc RTL: chroma window clamp mismatch plane=2 idx=0 got=83 want=191` | Sound |
| DPB/MC | Luma distinguished from chroma | `i420_addr` U phase reads plane `2'd0` instead of `2'd1` | `FAIL h264_dpb_mc RTL: chroma window clamp mismatch plane=1 idx=0 got=17 want=83` | Sound |
| DPB/MC | Lower clamp boundary | Existing bad-clamp red probe | `FAIL h264_dpb_mc RTL: luma window clamp mismatch idx=0 got=18 want=17 src=(0,0)` | Sound |
| DPB/MC | Upper clamp boundary | `clamp_coord` high side returns `limit - 2` instead of `limit - 1` | Before edge sentinels: green. After edge sentinels: `FAIL h264_dpb_mc RTL: upper luma window clamp mismatch idx=202 got=59 want=68 src=(623,476)` | Was vacuous; closed |
| Chroma plane | H/V gradients, chroma constant, offset, clipping | Existing chroma red probes mutate constant, offset, clipping, and H/V | `ALL 4 mutation probes detected — RED proofs complete.` | Sound |
| IDCT/dequant | Coefficient magnitude | Dequant multiplier `* 16` changed to `* 8` | `FAIL real RTL sim: block=0 dequant[0] got -2112 want -4224` | Sound |
| IDCT/dequant | Coefficient position / scan placement | Swap dequant outputs for positions 1 and 4 | `FAIL real RTL sim: block=1 dequant[1] got -224 want 0` | Sound |
| IDCT/recon | Reconstructed-pixel clipping | `clip8` returns `v[7:0]` without saturation | Before clip probe: green. After clip probe: `FAIL real RTL sim: recon clip boundary upper got 247 want 255` | Was vacuous; closed |

## Notes

- The 624×480 derived real clip should improve image-statistics realism, but it is not a substitute for the two closed boundary probes: real content may still avoid exact saturated recon pixels or bottom/right clamp edge sentinels.
- The zigzag helper swap `scan 1 ↔ 2` did not fail because those two positions share the same H.264 dequant matrix class; that mutation is behavior-equivalent for magnitude and is not evidence of vacuity.
