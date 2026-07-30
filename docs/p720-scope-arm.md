# 720p host/ARM scope

Full evidence report (tables, layout math, device recipes, verdict):

**[`docs/evidence/p720-scope-arm-20260730T170939Z/REPORT.md`](evidence/p720-scope-arm-20260730T170939Z/REPORT.md)**

## Headline (v3 — scale separation)

| Item | Result |
|---|---|
| **Binding constraint** | **Open until S1** — scale policy + real input WxH, not “linear decode” |
| 480p ffmpeg shape | **vf ~50%** / h264 **~6%** / mux ~6% (headroom + soak) |
| Soak library source | **320×240** (`11b_recent.xml`) while PMS request is **624×480** |
| Live stream WxH | **Unmeasured** — w-device must `ffprobe` universal URL (report §6.1) |
| 720p24 if ARM upscales SD | **FAIL** ~250% stream (extrapolation) |
| 720p24 if PMS delivers tier + scale skip/cheap | **Plausible** ~70–120% stream (extrapolation) — **may reverse v2 “impossible”** |
| 480p if vf recoverable | stream ~90% → ~**43%** (proj); machine headroom improves |
| MiSTer tax | ~**75% play / 99% idle** — always in machine budget |
| DDR ABI `0x30000000` | Still hard-blocks 720p banks — required remap |
| DDR push @24 fps | Marginal ~29/42 ms |
| 480p gate | **PASS** (ARM soak) |
| Default | Unchanged **320×240**; no tier implemented |

v2 “~276% linear totals” arithmetic stands **as arithmetic**; product method invalidated when most cost is scale not decode. See report §0.
