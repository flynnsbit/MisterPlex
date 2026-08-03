# PMS stream target profile contract — path lane

**Branch tip at measure/commit:** pin worktree; quote `git rev-parse --abbrev-ref HEAD` + sha.  
**Subjects:** library items **≠ rk=7** (used rk=3,6,9,23,28,83).  
**No tokens in this file.** Session token never committed.

## Pre-registered predictions (before measure)

1. `/identity` → HTTP 200  
2. Universal **start.mp4** with full Chrome/MiSTerPlex identity +  
   `protocol=http&directPlay=0&directStream=0&videoResolution&maxVideoBitrate&videoQuality`  
   → deliverable media for at least 240p on a real item  
3. `videoResolution` is a **ceiling** (aspect fit), not exact coded pin  
4. 480p/720p start may need **decision→start** session pairing on this PMS  

### Misses published

| Prediction | Actual |
|------------|--------|
| Bare start.mp4 at 640x480 always 200 | **rk6/rk9 bare start → HTTP 400** (89-byte HTML); **decision then start → 200** |
| 1280x720 always exact | Delivered **960x720** (rk28/rk83) — ceiling + aspect fit |
| 320x240 exact | Often **320x180** or **312x240** depending on source DAR |

## Quoted request shape (daemon-equivalent)

```
GET /video/:/transcode/universal/start.mp4
  ?hasMDE=1
  &path=/library/metadata/<KEY>
  &mediaIndex=0&partIndex=0
  &protocol=http
  &fastSeek=1
  &directPlay=0
  &directStream=0
  &subtitleSize=100&audioBoost=100&location=lan&copyts=1
  &session=<sid>
  &videoQuality=<40|60|70>
  &videoResolution=<320x240|640x480|624x480|1280x720>
  &maxVideoBitrate=<1000|2000|2500|3100>
  &videoCodec=h264&audioCodec=aac
  &videoProfile=baseline&videoLevel=30
  &X-Plex-Token=REDACTED
```

Headers (required on this PMS):  
`X-Plex-Client-Identifier`, `Product`, `Version`, `Platform`, `Device`, `Device-Name`,  
`Client-Profile-Name: MiSTerPlex`, `Session-Identifier`.

Decision twin: same query on `/video/:/transcode/universal/decision` (Accept: application/xml).

## Measured exchanges (lab docker PMS :32400)

| Case | decision HTTP | start HTTP | Delivered (ffprobe) |
|------|---------------|------------|---------------------|
| rk3 320x240 q40 br1000 | 200 `decision=transcode` width=320 height=180 | 200 | **320×180** CB L31 no-B 24fps |
| rk6 640x480 q60 br2500 | 200 `decision=transcode` 640×360 | 200 | **640×360** CB |
| rk23 624x480 q60 br2000 | 200 624×480 | 200 | **624×480** CB |
| rk28 640x480 q60 br2500 | 200 640×480 | 200 (earlier bare) | **640×480** CB |
| rk28 1280x720 q70 br3100 | 200 960×720 | 200 | **960×720** CB |
| rk83 1280x720 q70 br3100 | 200 960×720 | 200 | **960×720** CB |
| rk9 bare start 640x480 (no prior decision) | — | **400** body 89 HTML | — |
| rk6 bare start 640x480 | — | **400** | — |

**Conclusion:** Controlling knobs that work are  
`videoResolution` (ceiling), `maxVideoBitrate`, `videoQuality`, `protocol=http`,  
`directPlay=0`, `directStream=0`, plus identity headers; **pair decision→start** for reliable non-240 tiers.  
Exact coded height is **not** pin-able via `videoResolution` alone.

Scrubbed URL files: `req_*.url`, probes: `ffprobe_*.txt`, decision snips: `resp_*_decision.snip.txt`.

## Profile table (code)

`host/libmisterplex/stream_target_profile.hpp` — data rows only:

| id | DECODE | PMS videoResolution | BR | Q | transport | I420@24 MiB/s | budget |
|----|--------|---------------------|----|---|-----------|---------------|--------|
| **240p-spi** | 320×240 | 320x240 | 1000 | 40 | spi_f1 | **2.637** | 5.5 |
| **480p-ddr** | 624×480 | 624x480 | 2000 | 60 | ddr_bulk | **10.283** | 80 |
| **720p-ddr** | 1280×720 | 1280x720 | 3100 | 70 | ddr_bulk | **31.641** | 80 |

SPI budget **5.5 MiB/s** = parent-measured F1 ceiling.  
480p/720p on `spi_f1` → typed `geometry_present_disagree` (startup **rc=2**).

Conf:

- `STREAM_TARGET_PROFILE=240p-spi|480p-ddr|720p-ddr`  
- `PRESENT_PATH=spi_f1|ddr_bulk` (default spi_f1 for product F1 push)

## Startup log (greppable)

```
misterplexd: STREAM_TARGET where=startup ok=1 err=ok profile=240p-spi
  decode=320x240 pms_videoResolution=320x240 maxVideoBitrate=1000 videoQuality=40
  protocol=http directPlay=0 directStream=0
  present_required=spi_f1 present_available=spi_f1
  payload_MiB_s=2.637 budget_MiB_s=5.500 fits=1 reason=ok
```

Refuse (480p DECODE + SPI):

```
misterplexd: STREAM_TARGET where=startup ok=0 err=geometry_present_disagree profile=480p-ddr
  ... present_required=ddr_bulk present_available=spi_f1 payload_MiB_s=10.283 budget_MiB_s=5.500 fits=0
misterplexd: FATAL stream target refuse err=geometry_present_disagree ...
true rc=2
```

## Tests

```
./build/test_stream_target_profile; echo "true rc=$?"   # expect 0
```

NEG (must fail naive impls): 624×480 on SPI, 480p-spi name, 1080p, 1920×1080.

## Parent device check (you run)

1. Deploy daemon with `STREAM_TARGET_PROFILE=240p-spi` (or DECODE=320x240 + PRESENT_PATH=spi_f1).  
2. Confirm log contains `STREAM_TARGET` with `fits=1`.  
3. Play a non-pilot item; expect pfps>0.  
4. Conf with DECODE=624x480 and PRESENT_PATH=spi_f1 must **exit 2** before play (no silent pfps=0).  
5. When DDR bulk is real: `PRESENT_PATH=ddr_bulk` + `STREAM_TARGET_PROFILE=480p-ddr`.
