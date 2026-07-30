# p480-S1 — blocked: user playing (no interrupt)

**TS:** see `00_user_playing_block.txt`  
**SOURCE_SHA:** see file  
**Lane:** device-owner

## S1 status: **NOT MEASURED**

| Check | Result |
|-------|--------|
| User playback | **YES** — `state=playing` `location=fullScreenVideo` |
| ratingKey | **40868** (not soak rk=12) |
| duration | ~5.48e6 ms (~91 min); time was advancing (~282s when first seen) |
| Current tier (cmdline) | **240p** — `videoResolution=320x240` `scale=320:240:...` `maxVideoBitrate=1000` |
| CORENAME | Plex |
| RBF | 14eaeff3 (unchanged; not touched) |
| Action taken | **None that stops/seeks/casts.** No ffprobe on live URL (same session risk). |

**Parent rule honored:** *If the user is watching something, wait or say so.*

## What is proven without S1 (still not S1)

1. **Live product path always has scale in vf** (this session, 240p):  
   `fps=24000/1001,scale=320:240:force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:(oh-ih)/2`  
   Artifact: `00_user_playing_block.txt` ffmpeg cmdline.
2. **Prior soak library source** for rk=12 is **320×240** (XML evidence in p480-verify `11b_recent.xml` / p720-scope REPORT) — **not** a substitute for live bitstream geometry after PMS.
3. **Host cannot reach** `192.168.1.41:32400` from this machine right now (`curl` fail); device reaches PMS via `*.plex.direct` in the live URL.
4. **w-arm gated scale-skip / sws_flags build:** not present in tree as a deployable flag yet (no `SCALE_SKIP` / `sws_flags` implementation hit in arm/ beyond always-append scale). S2 product path waits on their build; manual ffmpeg A/B would need idle device.

## Pre-registered (unchanged; not yet tested)

See `predictions.txt`. Lead prediction **S1a**: 480p cast of SD soak clip → input **320×240** (ARM upscale).

## Next

When timeline returns to `location=navigation` / not playing: run S1 ffprobe on 480p cast URL immediately, report before S2.
