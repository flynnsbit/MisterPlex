# B6 residual settle — source quotes (w-geom)

## B2 — delivered geometry always logged

Product STREAM=0 spawn (`media_player.cpp` ~3129-3135):
```
// -loglevel error SUPPRESSES the Stream banner → delivery_verified stays 0.
args.push_back("-loglevel");
args.push_back("info"); // DO NOT change to error — breaks delivered_geom
```
Stderr pump parses `Stream #… WxH` → `MEASURED_DELIVERY … src=ffmpeg_banner … tag=measured`.
Probe/demux/audio-only helpers stay `-loglevel error` (no geometry contract).

Parent line cites 2417-2418 are **stale**; product path is info.

## B4 — only measured qualifies

`yuv420p_chroma_health.hpp`:
```
inline bool deliveryGeometryVerifiedFromBasis(const char* deliveryBasis) {
    … return std::string(deliveryBasis) == "measured";
}
```
Unit: library_media / transcode_request → false; measured → true.

## B5 — teardown hard telemetry

`media_player.cpp` after killChildren:
- `rawPipeByteAligned(totalBytes, frameBytes)` → ERROR PIPE_BYTE_MISALIGN or pipe_align ok
- `rawPipeDesynced(prodBytes, frameBytes, frameIndex)` when measured WxH known
- `ERROR media: PIPE_DESYNC=1 … tag=measured — hard telemetry trip (B5)`

Not unit-only: **arm/** calls both.

## B1 — desync sign

N legible counters in one reader raster ⇒ `producerBytesFromCounterCopies(449280,N)`.
N=2 ⇒ **224640** (624×240), **not** 460800 (640×480).

## B6 WIDTH policy (tip)

| delivery | vf class |
|----------|----------|
| claim exact 624×480 unverified | force_exact_crop_pad_unverified |
| 640/720×480 | crop_pad_no_v_scale_hfit |
| 624×350/352, 426×240, 320×240 | scale_pad_crop (+ FOAR) |
