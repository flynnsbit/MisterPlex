# Daemon geometry chain — 960×540 storage vs canvas (rd-duck #3)

**Lane:** w-path · **Tip after fix:** see `git log -1` · **Finding:** CONFIRMED (path tip was worse than “1280 canvas”; it used **480p canvas**)

## 1) Confirm / refute

| Claim | Verdict on `w-path-720p` **before** this fix | After fix |
|-------|-----------------------------------------------|-----------|
| `media_player` sets `rawW/rawH` from canvas-ish present geometry | **TRUE** — `threadMain` uses `ddrFrameGeometryForFpgaPresent(outW_,outH_)` then `vfReq.coded_*=raw*` and `frameBytes=rawVideoFrameBytes(...,rawW,rawH)` | Still uses same call sites; selector now returns **storage** |
| Selector returned **1280×720** for 960×540 | **FALSE on path tip** — selector ignored decode and always returned **624×480** | Returns **960×540** for 960×540 |
| Measured +7.16 ms path was what the daemon ran | **FALSE** — daemon forced FFmpeg/publish into **449280 B** canvas (or would have forced 1382400 if canvas were 720p) | **TRUE** when `DECODE=960x540` + FPGA present: raw **960×540 / 777600** |
| `makeDdrFabricOwnedPublishPlan` unwired | **TRUE** on path (helper lives on w-mem; path uses `makeDdrPublishPlan`) | Path still uses `makeDdrPublishPlan`, now Option-C-aware |

### Quoted chain (daemon)

```cpp
// media_player.cpp threadMain
const DdrFrameGeometry ddrGeometry =
    wantFpgaDdrCanvas ? ddrFrameGeometryForFpgaPresent(outW_, outH_)
                      : makeDdrFrameGeometry(outW_, outH_);
const int rawW = ddrGeometry.coded_width.get();
const int rawH = ddrGeometry.coded_height.get();
// ...
vfReq.coded_w = rawW;
vfReq.coded_h = rawH;
// ...
const size_t frameBytes = rawVideoFrameBytes(videoFmt, rawW, rawH);
// ...
DdrPublishFrame frame{txFrame, txBytes, ddrGeometry, ...};
ok = publishDdrFrame(frame, "playback DDR", ...);
// publishDdrFrame → makeDdrPublishPlan → sendDdrFrame
```

**Before:** `ddrFrameGeometryForFpgaPresent` always `productDdrFrameStoreGeometry()` = **624×480**.

**After:** `ddrStorageGeometryForContent` — 960×540 and 1280×720 are identity storage; 320/624 stay 480p canvas.

## 2) Full geometry decision points

| Stage | Who decides | 540 product intent | Failure mode if wrong |
|-------|-------------|--------------------|------------------------|
| 1. Tier select | conf `DECODE=960x540` / `OSD_CONTROL=off` | content 960×540 | OSD O[5:4] has no 540 → falls to 240/480 |
| 2. PMS request | `weakForContentResolution` → `videoResolution=960x540` maxBR=2000 L31 | ask ceiling 960×540 | bitrate &lt;2000 → measured 720×404 |
| 3. Delivered stream | PMS + ffprobe | display **960×540** (SPS MB 544 cropped in libav) | ceiling trap / 4:3 → 720×540 |
| 4. FFmpeg output | `rawW×rawH` from present selector | **960×540** identity_skip when verified | **was 624×480 scale** (pre-fix) |
| 5. Publish payload | `frameBytes` + `makeDdrPublishPlan` | **777600** @ Option-C `0x30180000` | legacy bank overrun; or 1382400 if 720 canvas |
| 6. Fabric read | RBF CODED_W/H + scaler | content 960×540 → glass 1280×720 | Option-C predicate / PLXG (w-mem) |

**Canvas vs content:** DE/glass canvas may be 1280×720 (scaler out). **ARM storage/publish is content 960×540.** Never feed DE canvas dims into FFmpeg `rawW/H`.

## 3) Deploy / select / bitrate (restated)

1. **Build daemon from** `w-path-720p` ≥ this fix commit (also ≥ `8e62f61b` for ladder).  
   Worktree: `/home/flynnsbit/Projects/MisterPlex-wt-path` · `make arm-plexd` · `scripts/deploy_misterplexd.sh build/arm/misterplexd`
2. **Select:** `DECODE=960x540` + `OSD_CONTROL=off`. Grep:  
   `content resolution=960x540 source=conf/--decode`  
   `GEOM requested_pms=960x540` and coded bank / decode_target **960x540** (not 624x480).
3. **Bitrate:** weak **2000** = measured knee; no silent reject; &lt;2000 → 720×404. WARN only if below recommended.

## 4) Live delivery readback (hard PLAYING precondition)

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,coded_width,coded_height,sample_aspect_ratio,profile,level \
  -of default=noprint_wrappers=1 "$BODY"
# PASS: width=height=coded_*=960/540, SAR=1:1, Constrained Baseline, level=31
```

SPS optional: `pic_height_in_map_units_minus1=33` (544) + `frame_crop_bottom_offset=2` → display 540. Bank still **777600**.

## 5) Coordination with w-mem

- Path owns: FFmpeg storage dims + publish length + Option-C phys when payload needs it.
- w-mem owns: RTL Option-C **predicate** (`coded_w>=1280` → capacity), PLXG native_push window, fabric reader strides.
- Path does **not** call `makeDdrFabricOwnedPublishPlan` yet (w-mem helper); equivalent contract: publish_bytes=777600, phys Option-C, storage 960×540.
- Do not hard-code 544 as bank payload (parent+rd-duck).

## 6) Budget claim status

| Claim | Status |
|-------|--------|
| Parent decode+sws+copy **34.50 ms / +7.16** for tight 960×540 | Still a **valid measurement of that workload** |
| “Daemon executes that path end-to-end” | **Was false**; **fixed** on this branch for `DECODE=960x540` + FPGA present |
| Ship until device PLAYING confirms | Still held — device down; glass score needs paired RBF + Option-C RTL |
