# Unvarnished gap: `h264_decode_top` → real PMS 720p24 bitstream on glass

**Audience:** parent + fabric lanes. **Author:** w-path.  
**Date context:** parent proved bitstream move is free (mean 13 507 B → 0.146 ms;
**worst AU 60 915 B → 0.660 ms** on real `real720p_2600k.mp4`, 4/4 pre-reg).
Data movement is solved. **Decode is the remaining problem.**

This is weeks and module truth — not vibes, not a plan that dies in month two.

---

## One-sentence verdict

`h264_decode_top` is a **real, bit-exact intra luma MB recon engine fed pre-parsed
coefficients**. A PMS 720p24 cast needs a **Baseline CAVLC annex-B → full-frame
YUV → present** product pipeline at 80×45 MB, with working **P-frames, deblock
before DPB, and DDR ref traffic**. That is **not 10% left**; it is the other
**~80% of a decoder**, much of it integration. **Honest calendar: ~8–16 weeks
focused** to durable glass; **~3–6 weeks** to first correct I-frame only if
stream_path integration is staffed hard. **CABAC is not on the critical path
if the CB profile pin holds.**

---

## What `h264_decode_top` actually is (quoted from its own header)

- Processes **16 luma 4×4 blocks** of one MB through dequant→IDCT→recon.
- **Inputs:** `mb_type`, QP, neighbour samples, **per-block coefficients already
  parsed**, I4/I16 modes — **not** annex-B, not RBSP bits, not NAL.
- **Output:** `recon_y[0:255]` for one MB; hybrid ownership ports.
- **I_PCM:** TODO. **Chroma:** not this module’s full product job.
- Parent’s `5120/5120` luma bit-exact is **genuine** and necessary. It does
  **not** mean “decoder done.”

`h264_decode_core.sv` header is blunter: **STATUS: PARTIAL PRODUCT DATAPATH**;
default `FRAME_W=320`; “Full partition modes, deblock-before-DPB, and full decode
scheduling remain open”; architecture diagram comments include
**“not yet implemented — interface contracts below.”**

---

## Parent traffic lock (cite this, not nominal bitrate)

| Payload | Bytes | @88 MiB/s uncached |
|--|--|--|
| Decoded 720p I420 | 1 382 400 | **14.97 ms** structural |
| Mean bitstream AU (1440f real file) | **13 506.6** | **0.146 ms** |
| **Worst keyframe AU** | **60 915** | **0.660 ms** |
| 24 fps mean ingest | 0.32 MB/s | 0.35% of ceiling |

Ring ABI (`ddr_bitstream_ring.hpp`): **256 KiB** @ `0x30100000` holds
**~4.3× worst AU** — OK if consumer keeps up; w-mem should treat **≥64 KiB
single-AU** and **≥4× worst** as sizing floor (current ring meets 4×; do not
shrink). Record header 32 B + AU must fit contiguous producer write.

---

## Gap list (dependency order) — each is real work

### G0 — Product glue (blocks everything)
Wire **live** path: `ddr_bitstream_reader` → NAL/RBSP → SPS/PPS/slice → MB
scheduler → decode → deblock → DPB → **Option-C / present** (runtime stride).
Today: ARM F1 or fabric pattern/idle on glass; bitstream path **STREAM=0**
dormant; decode modules largely **not** the HDMI owner.
**Weeks: 2–4** even with blocks ready (CDC, QSF, elision, doorbell, credit).

### G1 — Annex-B / CAVLC syntax front-end (not decode_top)
`decode_top` wants coeffs. PMS gives NALs. Need: start codes, EBSP→RBSP,
exp-Golomb, SPS/PPS, slice header, mb_skip, mb_type, CBP, qp_delta, residual
CAVLC into coeff arrays, multi-NAL AU, constrained-baseline edge cases at
**real** 2585 kbps / 60 KB IDR.
Pieces: `h264_cavlc_residual`, syntax primitives, host goldens — **not** one
closed product FSM at 720p.
**Weeks: 2–5** to robust I-slice; **+2–4** for full P syntax.

### G2 — Chroma + I_PCM + complete I-frame writeback
Luma-only bit-exact ≠ watchable frame. Chroma DC/AC, 8×8 pred, pack to I420
bank, first pixel on HDMI.
**Weeks: 1–3** after G1 I-path (modules exist; glue is the bill).

### G3 — Inter prediction + DPB @ 720p (long pole after first I)
80×45 MB/frame × 24 = **86 400 MB/s** (w-clock’s number).  
Need: MV pred, qpel/epel MC, ref slot commit **after deblock**, DDR ref read
vs scanout/bitstream reader arbitration, multi-ref if any (CB often 1–2).
Modules `h264_inter_*`, `h264_mc_*`, `h264_dpb*` exist with TBs; product
scheduling and **DDR contention** are the month-two killer if underestimated.
**Weeks: 4–8** to short-GOP watchable; more if DPB in on-chip RAM thrash.

### G4 — Deblock before DPB
Core header: recon can write **unfiltered** samples today; Baseline needs LF
before ref use or drift accumulates (looks “almost right” then rots).
**Weeks: 1–3** once MB recon solid (blocks exist).

### G5 — Geometry / area / Fmax @ 1280×720
Params still 320×240-class in core defaults. Frame store stride, M10K, Fmax
after wiring decode (nostub bought room; decode eats it).  
**Weeks: overlapping 2–4** with G0/G3; risk of fit thrash.

### G6 — Runtime policy
Underrun (freeze / OSD / IDR request), desync→IDR, seek, hybrid host_required
for unsupported MB, STREAM session teardown. ABI flags exist; **product
behavior not locked**.
**Weeks: 1–2** soak + daemon.

### G7 — CABAC (contingency only)
**Not required** for lab PMS true-720 after `MiSTerPlex.xml` (Constrained
Baseline). If profile leaks Main+CABAC: refuse (hybrid) or **+8–16 weeks**
engine. **Protect the pin like a beam.**

---

## What is *not* a gap (do not rebuild)
- Motivation: bitstream move is free (parent measured worst case).
- Host ring producer + ordering (`STREAM=1` path).
- Intra luma arithmetic quality bar (`decode_top` bit-exact).
- PMS delivery of real 1280×720 CB (w-path geometry floor 3100).

---

## Milestone table (calendar weeks, one integration owner + support)

| Milestone | Weeks | Exit evidence |
|--|--|--|
| Ring soak STREAM=1, reader seq/level, no full decode | 0.5–1 | PLXR/PLXT live; no fantasy |
| **First correct I-frame 720p CB** ring→bank→HDMI | **3–6** | capture ≠ ARM orange; score vs host recon |
| Short GOP P-frames watchable 10–30 s | **+4–8** | no ref rot; 24 fps hold |
| Cast-quality: seek, underrun, IDR, soak | **+2–4** | daemon policy locked |
| **Sum durable PMS 720p bitstream on glass** | **~8–16** | not 2; not “top is done” |
| CABAC if pin fails | **+8–16** | avoid |

**Critical path:** G0∥G1 → G2 → **G3+G4** → G6. G5 parallel.  
**If w-clock says 86 400 MB/s unreachable at clk_sys:** stop and redesign
(pipeline depth / MB parallel) **before** week 6 of P-frame work.

---

## Implications by lane
| Lane | Do |
|--|--|
| **w-path** | Keep CB pin + STREAM producer healthy; PL330 is backup only; no DecodeIntoBank product; ring must not collide Option-C (`0x30140000` data end vs `0x30180000` base — 256 KiB gap OK). |
| **w-mem** | Ring sized for **60 915 B worst AU + headroom** (256 KiB OK; don’t shrink); bitstream reader + bank writer arbitration. |
| **w-clock** | MB/s and Fmax gate G3; speak early if red. |
| **w-scaler/osd/nostub** | Present path still the near-term glass proof; decode does not block that fit. |
| **decode integration** | Staff G0–G4 as the programme; modules without stream_path are inventory. |

---

## Hard truths worth repeating
1. Moving pixels ARM→bank is **dead**. Moving bitstream is **done** (budget).
2. `h264_decode_top` ≠ product decoder. Coeff-in I-luma ≠ PMS stream.
3. Inter+DPB+deblock order is where schedules die if you celebrate I-frame early.
4. **8–16 weeks** durable; **3–6** first I-frame — if those slip past **20 weeks**
   without I-frame on glass, the plan is failing, not “almost there.”
5. I will not defend Route A or inflated DMA numbers. Same standard here:
   **no HDMI bitstream frame yet = not solved.**
EOF

