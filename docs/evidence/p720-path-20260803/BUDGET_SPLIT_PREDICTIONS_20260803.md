# (2) Pre-registered split of parent 34.50 ms — before measure

Parent authority: decode+sws+raw **26.08** + copy-to-DDR **8.42** = **34.50** ms @960×540.

| bucket | prediction (ms) | basis |
|--------|----------------:|-------|
| decode (h264→AVFrame, null sink class) | **14–17** | ~55–65% of 26.08; dual-A9 already multi under FFmpeg default |
| convert/scale (sws / -vf / pix_fmt) | **0–3** | product yuv420p + identity_skip when delivery==bank; residual is pack-to-raw only |
| pack/raw pipe (FFmpeg→stdout I420) | **8–12** | rest of 26.08 after decode |
| copy-to-DDR (daemon present) | **8.42** | parent number; not re-derived here |
| **sum** | **34.50** | fixed |

**P-colour:** convert away from I420 is **not** on product path → colour-to-fabric prize ≈ **0**.

**P-thread-headroom:** product has no `-threads`; if FFmpeg default is already auto-MT, enabling `-threads 2` buys **≤10%** of decode wall, **not** enough alone to clear −1.17 vs 33.333.
