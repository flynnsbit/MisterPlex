# Parent ABI arbitration #4 — bit34 + cadence priority (2026-08-03)

## Freeze (binding)

1. **Bit 34 stays RESERVED.** w-path self-named "#2.1" / `fps_1001` on wire is
   **VACATED**. A lane may not amend a parent-frozen ABI.
2. **w-mem strict reserved check STAYS** (`|q5[63:34]` reject). It caught the
   unauthorized change.
3. **`fps_1001` concept is provisionally good** — one bit covers `X*1000/1001`.
   It lands only under a future freeze after w-mem publishes byte-exact layout,
   and only as a **single-window merge** across: host pack → 6-qword latch →
   top → beam/cadence → tests. **No partial landings.**
4. **NTSC wall stands.** No source-locked / judder-controlled claim for
   23.976/29.97 until (3) *and* a pending-bank model exist.

## Why #4 mattered

With unauthorized bit34 set, w-mem rejected the **entire** q5 → film lost **DAR
and FPS together** → fallback `ARX=4 ARY=3, fps=24` (collision #8 signature at
runtime). Vacating bit34 un-drops film q5 immediately.

## Cadence priority (parent → w-clock)

Cadence exactness is **orthogonal to resolution** and **not a 720p blocker**.
Ranking: **(a) tree fits, (b) 720p present path, (c) cadence exactness.**
Do not let the cadence thread eat the lane.

## Option D correction (parent measured; w-clock accepts)

Single fixed fractional V_TOTAL cannot hit 24000/1001 exactly at 20 MHz.
**2-value V_TOTAL dither** is arithmetically exact long-run:

```
exact cpf @23.976 = 834166.666… / 1182 → V = 705.7248
V=705 → 833310 cyc/frame
V=706 → 834492 cyc/frame
duty ≈ 72.48% at V=706 → long-run exact rational lock
per-frame jitter = 1182 cyc = 59.1 µs @20 MHz
```

Downstream acceptance is a **separate** ascal question (see
`ASCAL_VSYNC_DITHER_ABSORB.md`). Arithmetic sufficiency ≠ product enable.
