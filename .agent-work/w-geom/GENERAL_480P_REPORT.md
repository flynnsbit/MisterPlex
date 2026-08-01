# General 480p residual (B6 real residual) — w-geom

## Record corrections (parent-mandated)

1. **`0x80808080` bank-0 probe RETRACTED** — `fillYuv420pStudioBlack` sets U/V=128 before content;
   top-left is pad. Cannot verify write. FORCE_SCALE is the real fix; studio-black is hygiene.
2. **B1 desync sign** — N=2 TREK counters ⇒ S≈449280/2=**224640** (624×240 I420).
   640×480=460800 **REJECTED** as N=2 model (`test_yuv420p_chroma_480p` GREEN_DESYNC).
   FLASH L/R wrap ⇒ horizontal component (not pure 624-wide vertical stack alone).

## Q1 — FORCE_SCALE guarantees (source + measured host ffmpeg)

Product path (`media_player.cpp`): DDR YUV + `ddrYuvForceScale_` default ON maps
`SkipIdentity`→`Always` via `ffmpegScaleModeForDdrYuvPresent`.

vf construction (`ffmpeg_vf.hpp` `buildScalePadCropped`):
```
scale=618:480:force_original_aspect_ratio=decrease,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black
```
- **decrease** preserves aspect (letter/pillar), never stretch
- **pad=624:480** pins OUTPUT coded bank
- I420 OUTPUT bytes **always 449280** for every even/odd source tested

Host ffmpeg gate (`test_force_scale_ffmpeg_out.sh`) **measured** bytes==1347840 for N=3:
624x480, 624x352, 640x480, 720x480, 704x396, 1440x1080, 320x240, **625x481 odd**, 618x480.
RED twins without pad: 640/352/720 emit ≠449280/frame.

**Break case under FORCE_SCALE=1:** NOT-FOUND for size mismatch → magenta.
Remaining risks: force OFF + identity_skip; mid-stream if scale graph dies; CPU (parent domain).

## Q2 — Mid-stream resolution change

- Play-time guard (`main.cpp` GEOM) runs **once**; vf plan fixed in `threadMain` before spawn.
- Stderr pump sets `MID_STREAM_CHANGE=1` on second distinct INPUT geometry; cannot rebuild vf.
- Under FORCE_SCALE Always, scale+pad stays in graph for the session — OUTPUT stays coded **if**
  decoder continues feeding the graph. identity_skip cannot recover mid-stream.
- Gate: FORCE_SCALE table asserts mid-stream source still `scale_applied` (mode Always).

## Q3 — B4

`deliveryGeometryVerifiedFromBasis` accepts **only** `"measured"`.
`library_media` / `transcode_request` → false (quoted `yuv420p_chroma_health.hpp:127-134`).
Play-time GEOM stays `delivery_verified=0`. After MEASURED_DELIVERY: flag atomic true and
logs `delivery_verified=1 delivery_basis=measured` on MEASURED_* and 1 Hz media line.

## Gates (true rc direct)

| gate | true rc |
|------|---------|
| test_ffmpeg_vf | 0 |
| test_yuv420p_chroma_480p | 0 |
| test_force_scale_ffmpeg_out.sh | 0 |
| unit rollcall | 0 |
| make arm-plexd | 0 |

**ARM-ONLY — no RBF.** Parent deploy + cast non-bank titles (624x352 scope, 720x480 DVD).
d54f347ae438f09cac8bf67c20399ce6  build/arm/misterplexd
