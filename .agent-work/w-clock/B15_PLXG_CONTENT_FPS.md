# B15 — content_fps via PLXG q5 (parent ABI arbitration #2)

## Defect
Hardwired `content_fps=24` → V_TOTAL always 705 → beam always 24.0007 Hz.

## Parent field (do not renegotiate)

```
q5 @ doorbell+0x828:
  [11:0]  dar_x
  [23:12] dar_y
  [31:24] content_fps     ← w-clock consumes
  [32]    dar_valid       ← w-scaler
  [33]    fps_valid       ← w-clock consumes
  [63:34] RESERVED=0      ← w-mem rejects nonzero
```

Record grows q0–q4 → q0–q5 (`0x800..0x82F`). w-mem owns latch/poller/headers + **B16**
frame-boundary atomic promote (q5 rides with geometry).

## w-clock consumer

`plex_content_fps_sel.sv`:
- `fps_valid && fps!=0` → `content_fps_eff = fps`
- else → **24** (unspecified — do **not** invent 30)
- `FAULT_B15_IGNORE_FPS_VALID` → permanent 24 (red: 30 title → 4 unique frames)

`Plex.sv` stages `plxg_fps_valid`/`plxg_content_fps` until w-mem merge.

## Proof
`tests/unit/test_b15_cadence_framecount.sh`
- valid=1 fps=24 → 4 frames; valid=1 fps=30 → 5 frames
- valid=0 fps=30 → 4 frames (no invent 30)
- RED ignore valid: valid=1 fps=30 → 4 frames

## Ownership
| Lane | Symbol |
|------|--------|
| w-mem | q5 latch, poller, ABI headers, reserved≠0 reject, B16 atomicity |
| w-path | publish fps from PMS/FFmpeg; valid=0 if unknown |
| w-scaler | dar_* only |
| w-clock | content_fps / fps_valid → V_TOTAL only |
