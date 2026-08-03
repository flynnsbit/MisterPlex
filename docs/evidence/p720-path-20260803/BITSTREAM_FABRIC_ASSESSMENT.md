# Bitstream-to-fabric assessment (w-path honest engineering)

Parent ask (3): if ARM writes **H.264 bitstream** not decoded frames, uncached
ceiling stops mattering (~13.5 KB/f @ 2585 kbps/24 ≈ **0.15 ms** @ 88 MiB/s).
What exists, what is missing, weeks.

## Traffic math (real product tier)
| | bytes/frame | @88 MiB/s |
|--|--|--|
| Decoded 720p I420 | 1 382 400 | ~14.97 ms **structural FAIL partner** |
| Bitstream @2585 kbps/24 | ~13 464 | ~0.15 ms **noise** |
| Bitstream ring capacity | 256 KiB | ~19 frames @ that rate |

Arithmetic is correct: **bitstream feed kills the uncached-boundary problem.**

## What already exists (do not rebuild)

### Host / ring ABI — largely DONE
- `host/libmisterplex/ddr_bitstream_ring.hpp` — 256 KiB ring @ `0x30100000`,
  CTRL/READ/ERR/STATn, PLXN records, session/seq, underrun/overrun/desync.
- Producer path in daemon when `STREAM=1` (default **off**): annex-B demux →
  `FpgaBitstreamProducer` → O_SYNC map + barrier before CTRL (ordering sound).
- Analysis: `arm-bitstream-feed-analysis.md` — CTRL=0 is dormant-by-design, not
  a broken producer.

### RTL pieces — many modules, **not one product decoder**
| Piece | Path | Honest status |
|--|--|--|
| Ring reader | `ddr_bitstream_reader.sv` | exists; telemetry PLXE |
| FIFO | `bitstream_fifo.sv` | exists |
| `h264_decode_top` | I-MB recon from **pre-parsed coeffs** | **not** bitstream-in; luma MB path; chroma/I_PCM open |
| `h264_decode_core` | Baseline CAVLC **skeleton** | header says PARTIAL: schedule, full partitions, deblock-before-DPB open; default **320×240** params |
| CAVLC residual | `h264_cavlc_residual.sv` | unit/sim coverage |
| Intra pred + nb ctx | `h264_intra_*`, `h264_intra_nb_ctx` | modules + sims; integration incomplete in product |
| Inter / MC / DPB | `h264_inter_*`, `h264_mc_*`, `h264_dpb*` | modules + tbs; product CAP/wiring incomplete |
| Deblock | `h264_deblock*.sv` | modules; “before DPB” called out open in core header |
| Hybrid own | `h264_hybrid_mb_own.sv` | CABAC/unsupported → host_required |
| Product QSF | post-nostub | full decode pipeline **not** the live HDMI path today |

### Profile luck (important)
Lab PMS after `MiSTerPlex.xml`: true 720p is **Constrained Baseline L3.1**, not
Main/High. **CABAC is not required** for the intended PMS path if the profile
pin holds. That removes the largest entropy-decoding mountain. If profile ever
leaks Main+CABAC, fabric must refuse (hybrid host) or grow a CABAC engine
(multi-month alone).

## Gaps between today and “real PMS 720p on glass from bitstream”

Ordered by dependency (not enthusiasm):

1. **End-to-end stream_path integration (product)**  
   Bitstream reader → NAL/RBSP → SPS/PPS/slice header → MB loop →
   `h264_decode_core` @ **1280×720** → deblock → DPB → **frame store / present**
   with runtime stride. Today: pieces + sims; live core paints ARM F1 / fabric
   pattern/idle — not this pipeline on HDMI.

2. **Entropy + syntax at real bitrate**  
   CAVLC residual exists; full slice walk, mb_skip, all P modes, CBP, qp_delta,
   constrained baseline edge cases under 2585 kbps multi-NAL AU.  
   `h264_decode_top` alone is **coeff-in**, not annex-B-in.

3. **Inter prediction + DPB bandwidth at 720p**  
   Modules exist; product scheduling, ref slot commit order, DDR ref fetch vs
   present/scanout contention is the long pole after “first I-frame correct”.

4. **Deblock before ref commit**  
   Explicitly open in `h264_decode_core` header. Wrong order = subtle ref drift.

5. **Geometry / area / Fmax**  
   Core params and frame store must be 80×45 MBs (720p), not 20×15 (320×240).
   DPB ×720p is a real M10K/DDR budget problem even with nostub reclaim (356 free
   M10K helps; does not delete the work).

6. **Backpressure / underrun policy (ABI mostly ready)**  
   Ring full → producer backoff (exists). Underrun → freeze last frame / error
   OSD / resync on IDR — **product policy still to lock**. Desync sticky must
   force IDR request to PMS, not silent green.

7. **Error concealment**  
   Missing/corrupt NALs: hybrid host path or freeze — must not scramble DPB.

8. **CABAC**  
   Out of scope **if** CB pin holds. Contingency only.

## What is *not* missing
- Motivation/math for bitstream feed  
- A draft ring ABI and ARM producer  
- A pile of verified arithmetic blocks  
- PMS ability to emit CB 720p (path lane already proved ≥3100 maxBR)

## Week-scale honesty (calendar weeks, one focused integration owner + support)

| Milestone | Weeks (cal) | Notes |
|--|--|--|
| STREAM=1 ring alive on glass telemetry (no full decode) | 0.5–1 | producer on; reader level/seq; already half-built |
| First correct **I-frame** 720p CB from ring → bank → HDMI | **3–6** | syntax+intra+IQ/IDCT+writeback+present; many blocks exist |
| **P-frames** + DPB + deblock order, watchable short GOP | **+4–8** | MC/DPB/DDR contention; hard |
| Stable 24 fps cast, seek/error/IDR, ship-quality | **+2–4** | policy + soak |
| **Total to “PMS 720p bitstream on glass durable”** | **~8–16 weeks** | not 2; not “modules exist ⇒ done” |
| CABAC if profile leaks | **+8–16 more** | avoid via profile pin |

If the team treats “5120/5120 luma bit-exact on `h264_decode_top`” as “decoder
done”, the plan dies in month two at **integration + inter + 720p DPB**. The
bit-exact win is real and necessary; it is **not** a bitstream-to-HDMI product.

## Recommendation
1. **This week:** parent runs fixed PL330 bench — only ARM-side escape hatch.  
2. **Do not productize DecodeIntoBank** until route_a probe says otherwise (expect trap).  
3. **Parallel mandate:** keep fabric present/scale/idle fit; grow
   `h264_decode_core` integration toward I-frame 720p from ring as the strategic
   path that makes ARM decode **optional**.  
4. **Protect CB profile** in PMS XML like a load-bearing beam — it deletes CABAC.

## w-path scope boundary
- Own: ring host ABI hygiene, STREAM producer health, PL330/frame ingest benches,
  PMS CB 720p delivery (done), honest traffic math.  
- Do **not** own: finishing `h264_decode_core` P-frame/DPB (fabric decode lanes).  
- Will coordinate ABI offsets so bitstream ring (`0x30100000`) and Option-C
  banks (`0x30180000`) / PL330 scratch (`0x30600000`) never collide — **ring ends
  0x30140000+ctrl; Option-C base 0x30180000 — verify ctrl page family vs 480p
  doorbell 0x300FF000** before STREAM=1 soak (layout audit item).
EOF


## Superseded by
See `H264_GAP_ANALYSIS.md` for week-scale gaps; parent worst-AU 60915 B locked.
