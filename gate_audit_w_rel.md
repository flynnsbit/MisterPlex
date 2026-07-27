# w-rel Gate Audit — Parent Directive #16

## Gate 1: `intra_mb_exact=300/300` (HEADLINE NUMBER)

**What it literally compares:** HOST C++ decoder (`reconISlice` in `h264_recon.hpp`) → `rec.y/u/v` vs FFmpeg golden planes. Function `mbExactAllPlanes` at `score_h264_native_frames.cpp:149`.

**RTL involvement: ZERO.** The RTL simulation runs, but this scorer ignores its output entirely. It parses the bitstream in C++, runs host-side CAVLC/intra reconstruction, and compares that against FFmpeg. A completely broken RTL that outputs all zeros would still produce `intra_mb_exact=300/300`.

**What a reader would assume it covers:** That the FPGA RTL reconstructs 300 of 300 intra macroblocks bit-exactly. **It does not.**

## Gate 2: MB0 Pipeline Trace

**What it literally compares:** RTL `trace["recon"]` (16 values = first 4×4 block of MB(0,0)) vs host golden `recon_first4`. Also checks `qp`, `total_coeff`, `residual_csum`, `coefficients_zigzag`, `dequant`, `idct`.

**Coverage:**
- Luma: 16 / 76,800 pixels = **0.021%**
- Chroma: 0 / 38,400 pixels = **0%**
- MBs: 1 / 300 = **0.33%**

**Can it fail?** YES — fault injection (`FAULT_TRACE_COEFF0_PLUS1=1`) confirms it goes red. It has caught real bugs (CAVLC scan order, dequant width).

**What it cannot catch:** Any chroma defect. Any defect in MBs 1-299. Any defect in 4×4 blocks 1-15 of MB0.

## Gate 3: Native I420 DPB Write Tap (Intra)

**What it captures:** `dpb_mem_wdata` during `PH_DPB_FILL`, which is `dpb_filtered_sample` — a **synthetic position-dependent test pattern** (`8'h20 ^ x ^ y`), NOT RTL reconstruction output.

**RTL reconstruction is not in the captured data.** The DPB fill writes a diagnostic pattern, not the decoded picture. This tap tells you the DPB write machinery works; it tells you nothing about whether the RTL decoded correctly.

## Gate 4: RGB565 Full-Frame Comparison

**What it compares:** RTL frame store output (through RGB565 encoding) vs host reconstruction.

**Limitation:** RGB565 round-trip destroys chroma precision. A chroma DC Hadamard bug producing ±4 in chroma reconstruction would round-trip to the same RGB565 value. Correctly classified as diagnostic-only.

## Summary

| Gate | RTL Y coverage | RTL chroma coverage | Can fail? |
|------|---------------|---------------------|-----------|
| intra_mb_exact=300/300 | 0% (host only) | 0% (host only) | Yes, for host bugs only |
| MB0 trace | 0.021% (16 pixels) | 0% | Yes |
| Native I420 DPB tap | 0% (synthetic data) | 0% (synthetic data) | N/A |
| RGB565 comparison | ~100% lossy | ~0% effective | Yes (gross errors) |

**The project's headline number `intra_mb_exact=300/300` is true of the HOST decoder, not the RTL.** I have been quoting "ratchet preserved" after every commit. That ratchet tests the C++ reference model, not the hardware I am building.

**RTL chroma reconstruction has NEVER been tested.** RTL luma reconstruction has been tested for 16 of 76,800 pixels.
