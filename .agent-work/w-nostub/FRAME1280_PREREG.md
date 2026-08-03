# FRAME_1280 enablement — PRE-REGISTER (before QSF edit / rtl-lint)

REF: w-nostub-frame-1280 @ 3fa01a9b base
Date: pre-edit

## Change planned
- Plex.qsf: FRAME_W=1280 FRAME_H=720 (was 640/480)
- Possibly present_core / layout select for 720p coded+stride if elaborate requires it

## Expected breaks (prediction BEFORE lint)

1. **WIDTH/bit truncations** — MEDIUM
   - present_core uses `11'(FRAME_W)` in beam path; 1280 fits in 11 bits (0..2047).
   - Template path uses 10-bit hc from colorbars; store scale uses FRAME_W — may WARN not FAIL.

2. **CODED vs FRAME mismatch** — MEDIUM/HIGH
   - ddr_frame_store still gets CODED_W=624 DISPLAY=618 from ddr_frame_layout_params.svh
     while FRAME becomes 1280×720. Likely ELABORATES but is geometrically inconsistent.
   - May hit generate/assert if PRESENT_X+DISPLAY > FRAME (11+618=629 < 1280 → OK).

3. **HPS_BANK_STRIDE still 0x80000** — HIGH product risk, LOW lint risk
   - I420 1280×720 = 1382400 > 524288. Expect lint PASS; runtime corrupt. w-mem owns guard.
   - Will NOT "fix" this in lint; may add compile-time $error if FRAME_W*FRAME_H*3/2 > stride.

4. **define-parity / unit tests** — MEDIUM
   - Anything goldening FRAME_W=640 will fail when suite run; rtl-lint alone may pass.

5. **colorbars / stream_path WIDTH** — LOW
   - Parameterized off FRAME_W; should track.

6. **STORE_X_SCALE overflow** — LOW
   - (1280*39647)/320 = 158588 fits 32-bit int.

7. **Hardcoded 240-row blanking logic** — MEDIUM functional
   - present_core Template path `py >= 10'd240` / V_STORE=240 — will elaborate at FRAME_H=720
     but only maps 240 of 720 store rows into Template DE. Not a lint fail; product bug if left.

## Predicted rtl-lint rc
PREREG_RC=0 (elaborate succeeds) OR 1 if width/truncation hard-fails
Primary unknown: Verilator -Werror on width with 11' vs larger expressions.

## Predicted first real fix needed
Either: (a) nothing for lint, or (b) select DDR_FRAME_720P_* layout when FRAME_W==1280,
or (c) cast/bit-width fix in present_core store path.
