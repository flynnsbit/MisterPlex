# FORCE_SCALE exact identity (FOAR no-op) — parent handoff

**Lane:** w-geom  
**Branch:** `w-avsync-hdmi-measure`  
**HEAD (pre-commit working tree):** see git after commit  
**Scope:** ARM-only. No RBF. No device by agent.

## Summary (≤10 lines)

1. Live `9ce2c2d1` FOAR on exact 624×480 under FORCE_SCALE is the product waste path.  
2. Tip: Always + source==coded → **true identity** (`force_exact_identity_crop_clear*`).  
3. FORCE_SCALE kept: non-exact/unknown still scale+pad to 449280.  
4. force=0 SkipIdentity + unverified still crop_pad (no identity_skip).  
5. clearYuv always strips 618-display pad cols on YUV present.  
6. Gates: RED rc=1, GREEN rc=0 (`test_ffmpeg_vf`).  
7. ARM md5 **`7a7854f4005c1766a5016c7f0fa62071`**.  
8. Content-window RTL still secondary (30 fps / 320 bytes).  
9. FOAR ~475 subsumed when identity fires (no V resample).  
10. Justify 30 fps headroom, not “out of budget at 24”.

## Parent verify (device — parent only)

```bash
# deploy tip daemon only (parent owns deploy)
# After cast of exact 624x480 asset (library/metadata/27 or equivalent):
# Expect GEOM:
#   arm_rescale=0 identity_skip=1
#   reason=force_exact_identity_crop_clear  OR  force_exact_identity_crop_clear_unverified
#   vf=fps=… or (none) — MUST NOT contain force_original_aspect_ratio=decrease
#   MUST NOT contain scale=618:480
```

## Host gates (agent-run)

```
build/test_ffmpeg_vf                 true rc=0
build/test_geom_frame_cost           true rc=0
build/test_yuv420p_chroma_480p       true rc=0
build/test_glass_loss_death_points   true rc=0
RED mutation (exact identity disabled + bank-h off)  true rc=1
```

Logs: `.agent-work/w-geom/RED_force_exact_identity.log`, `GREEN_force_exact_identity.log`.

## Why identity failed before

`ffmpegScaleModeForDdrYuvPresent(SkipIdentity, force=true)` → **Always**.  
Always historically always emitted scale+pad. Exact 624 never hit SkipIdentity’s verified identity branch.  
display=618 came from `kPlex480pDisplayWidth` / crop_right=6, so hasCrop forced FOAR decrease → out_h=475.

## What FORCE_SCALE still protects

Mismatched delivery (e.g. 1920×1080, 320×240, 624×350) still Always-scales into coded bank so reader_bytes=449280 (MILESTONE 4). Exact WxH match is the only no-op under Always.
