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
| 720p DDR ABI (w-mem) | **Option-C locked** in `docs/p720-ddr-abi.md` — base `0x30180000`, stride `0x180000`, doorbell `0x3047F000` (product 480p frozen) |
| DDR push @24 fps | Marginal ~29/42 ms |
| 480p gate | **PASS** (ARM soak) |
| Default | Unchanged **320×240** shipping; **path-720p ladder implemented** (see below) |

v2 “~276% linear totals” arithmetic stands **as arithmetic**; product method invalidated when most cost is scale not decode. See report §0.

## Path tier (w-path, 2026-08-03) — aggressive target

Full evidence: **[`evidence/p720-path-20260803/REPORT.md`](evidence/p720-path-20260803/REPORT.md)**

| Item | Measured |
|---|---|
| PMS true 720p | **Yes** — rk7 `videoResolution=1280x720` + maxBR≥**3500** → coded **1280×720** CB (after MiSTerPlex.xml 1280/L31) |
| maxBR≤3000 trap | coded **720×404** — **not** true 720p |
| Direct Play | **1280×720** CB L30 — **cheapest** route |
| Host ladder | profile `720p`, bitrate **4000**, L31, `isGenuine720pDelivery` |
| DDR present | still **rejects** 1280×720 (`ddrFrameStoreAcceptsResolution=0`) — w-mem |
| ARM 24fps fit | host probe only; bucket-lift projection **does not fit** 41.7 ms; device profile **parent** |
