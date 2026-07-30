# 720p host/ARM scope

Full evidence report (tables, layout math, device recipes, verdict):

**[`docs/evidence/p720-scope-arm-20260730T170939Z/REPORT.md`](evidence/p720-scope-arm-20260730T170939Z/REPORT.md)**

## Headline (v2 — CPU correction)

| Item | Result |
|---|---|
| **Binding constraint** | **ARM CPU (mplex+ffmpeg)** — not DDR push |
| Corrected 180s anchors | 240p **22.2%** / 480p **89.8%** total onecpu — **~linear** in pixels (4.04× CPU / 3.90× px) |
| 720p24 projection | **~276 %onecpu > 200%** dual-A9 ceiling — **likely not feasible** |
| ffmpeg threads | Already multi-threaded; 480p cost dominated by **`vf` scale (~50%)**, not a single h264 thread |
| Reduced fps | Only **≤12–15 fps** stays under 200% in projection (unmeasured) |
| DDR ABI `0x30000000` | Still hard-blocks 720p banks (mbox+bitstream) — secondary if CPU kills product |
| DDR push @ 24 fps | Marginal ~29 ms / 42 ms — not first killer |
| 480p gate | **PASS** (ARM soak) |
| Default | Unchanged **320×240**; no tier implemented |

See report §0 for full correction, thread tables, and fps option math.
