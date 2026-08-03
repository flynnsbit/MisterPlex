# (1) Scale-disappear prize — results (stop here per parent)

## Which invocation is 34.50?

| spawn | site | argv essence | role |
|-------|------|--------------|------|
| `spawnStreamDemux` | `:1589–1637` | `-c:v copy -f h264 pipe:1` | STREAM=1 remux → recon/F3 — **not** 34.50 |
| `spawnAudioOnly` | `:1644+` | audio s16le only | no video decode |
| **rawvideo present** | **`:3219–3315`** | **`-f rawvideo -pix_fmt … -vf … pipe:1`** | **STREAM=0 continuous F1 — this is 34.50** |

Evidence: code paths above; parent 26.08 was decode+sws+raw on a 960×540 I420 path matching rawvideo, not copy-remux.

**P-role: HIT.**

## What PMS delivers (measured, not assumed)

From prior lab matrices (ffprobe on `start.mp4` bodies; see `PMS_540_DELIVERED_GEOMETRY.md`, `ba_*`, `t360_*`):

| request | maxBR | HD 16:9 source | **delivered** |
|---------|------:|----------------|---------------|
| `videoResolution=960x540` | ≥**2000** | rk2/rk7/rk142 | **960×540** SAR 1:1 CB L31 |
| same | 1500 | same | **720×404** (ceiling trap) |
| same | any | SD (rk9/rk10) | ≤ source (626×352 / 852×480) — cannot invent 540 |
| `videoResolution=640x360` | ≥**1000** | HD 16:9 | **640×360** |
| same | 400–750 | same | 320×180 / 480×270 |

**Request shape (daemon):** `weakForContentResolution` → universal URL
`videoResolution=WxH&maxVideoBitrate=…&videoLevel=31` + MiSTerPlex profile
(+ Extra `video.frameRate=24` on 540 tier when capped).

**P-pms-540 / P-pms-360: HIT** (exact tiers exist when bitrate floor + HD source hold).

## Does product still run `-vf scale` when PMS matches bank?

**Yes at play-time plan freeze** — even when claim is exact 960×540.

Code (`ffmpeg_vf.hpp` Always+exact+unverified):

```
print_540_vf_plan (this segment):
unverified force: scale_applied=1 identity_skip=0
  reason=force_unverified_claim_scale_pad_coded
  vf=scale=960:540:force_original_aspect_ratio=decrease,pad=960:540:(ow-iw)/2:(oh-ih)/2
verified force:   scale_applied=0 identity_skip=1 reason=force_exact_identity vf=(none)
```

Cause: `DDR_YUV_FORCE_SCALE` default ON → SkipIdentity→Always
(`yuv420p_chroma_health.hpp:124-128`); plan built **before**
`delivered_geom` banner sets `delivery_geometry_verified` (`media_player.cpp:2905-2937`).
So product path is the **unverified** branch → **same-size FOAR scale stays in `-vf`**.

Making scale truly disappear requires one of: mid-session vf rebuild after banner,
plan-time verified basis (`direct_play_part` / measured), or safe
`assume_source_matches_coded` — **not** “PMS delivered 960×540” alone under current freeze.

## Scale cost / gap close?

Method: `ffmpeg_cpu_probe` host, `proxy_960x540_30.mp4`, 360f; map via decode share 14.03 of parent 26.08. Log: `probe_run/scale_prize_measure.txt`. All probe `true rc=0`.

| pair | host Δ cpu ms/f | device-class tax |
|------|----------------:|-----------------:|
| null `scale=960:540` vs null | +0.060 (~6.5%) | **~0.92 ms** |
| null scale+pad vs null | noise ≤0 (host variance) | ~0 |
| raw scale+pad vs raw id | ~0 within noise | ~0–1 ms |

Remove best positive tax **0.92** from 34.50 → **33.58 vs 33.333 → still FAIL (−0.25)**.

**P-cost (0.5–4 ms): HIT** (~0.9 ms).  
**P-prize-close-gap (scale alone flips @30): MISS** — does not clear −1.17.

Prior “~3.57 ms force-scale” is **larger than this host same-size delta**; do not budget a 3.5 ms save from deleting identity-sized FOAR on this evidence.

## Answer to parent (1) only

1. **34.50 = STREAM=0 rawvideo child**, not `-c:v copy` demux.  
2. **PMS can and does deliver exact 960×540 / 640×360** (floors 2000 / 1000, HD 16:9).  
3. **Product still inserts same-size `-vf scale`** at plan freeze (unverified Always).  
4. **Scale prize ~0.9 ms device-class — insufficient to fix 540@30.**  
5. Do **not** change fit emission expecting scale-delete to green the 30 fps budget.

`ddrFrameGeometryForFpgaPresent` not touched. (2)/(3) not started this report.
