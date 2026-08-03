# Product path: 960×540 source → 720p glass (not 720p source)

**Parent 2026-08-03** (proxy ladder 5/5 HIT, 1280×720 control −0.4%):

| stream | decode | copy | total | margin |
|--|--|--|--|--|
| 960×540 | 22.75 | 8.42 | **31.17** | **+10.49 PASS** |
| 1024×576 | 26.03 | 9.58 | 35.61 | +6.05 (tight; not ship) |
| 1280×720 | ~35.4 | 14.97 | ~50.3 | FAIL |

**Product:** `TRANSCODE_PROFILE=540p` / `960x540` → ARM decode+copy → fabric
1.333× upscale → native 1280×720 raster. User label: **"540p source / 720p glass"**.

**Not claimed:** true 720p source (needs PL330 or fabric decode).

**Host surfaces (w-path):**
- `ContentPresentPolicy::Source540pFabric720p`
- `contentResolutionFor540pFabric720p()`, profile name `540p`
- `kPlex540pWeakBitrateKbps=2000` (quality default — **not** a PMS geometry floor)
- `kPlex540pH264Level=31` (MaxFS)
- `isGenuine540pDelivery(960,540)` + negatives
- DMA remains upgrade path only (`PARENT_COMMANDS_PL330_FAULT_DIAG.md`)

**Open for parent / other lanes:** PMS live coded size at 960×540; w-scaler
filter; w-clock `clk_pix`; e2e cast on glass.
