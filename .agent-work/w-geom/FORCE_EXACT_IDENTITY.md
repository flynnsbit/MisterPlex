# FORCE_SCALE exact geometry — parent handoff (hazard revision)

**Lane:** w-geom  
**Branch:** `w-avsync-hdmi-measure`  
**Scope:** ARM-only. No RBF. No device by agent.

## Summary (≤10 lines)

1. Parent hazard **accepted**: Always+unverified must not `identity_skip` (every fresh play is unverified).  
2. Product hot path: Always + exact claim + unverified → **`force_exact_crop_pad_unverified`**.  
3. True identity only when **verified** (`force_exact_identity_crop_clear`).  
4. FOAR V-resample eliminated on exact claim; mismatch still scale+pad (MILESTONE 4).  
5. Plan-time `source_w/h` = PMS claim (`main.cpp:955-976`), not measurement.  
6. clearYuv blanks cols 618–623 of a full-width buffer; those cols are outside DISPLAY_W (not on glass).  
7. Gates: RED `true rc=1` / GREEN `true rc=0`.  
8. ARM md5 **`05e8055e66d26bc17700a9f65bb889e5`**.  
9. Crop+pad pins OUTPUT when input ≥ crop box; smaller fails loud (better than silent desync).  
10. Content-window RTL still secondary.

## Why not identity on unverified (parent was right)

| Fact | Citation |
|------|----------|
| Plan-time source is claim | `main.cpp:955-976` `setFfmpegScaleSourceSize(expectW,expectH)` from `transcode_request` / `library_media` |
| delivery_verified=0 at plan | `main.cpp:971-976` — banner not yet available |
| Plan frozen for session | `media_player.cpp` MEASURED_DELIVERY mid-stream cannot rebuild vf |
| identity_skip + wrong size = phase walk | `pipeDesyncRisk` / MILESTONE 4 |

## clearYuv vs 6 columns of picture

`clearYuv420pCropPadding` (`media_player.cpp:196-234`) with `crop_right=6` (`ddr_frame_layout.hpp` kPlex480pCropRight) memsets Y/U/V columns `width-right .. width-1` to studio black.

- **crop+pad path (product):** ffmpeg already emits black pad in cols 618–623; clearYuv is redundant.  
- **true identity path (verified only):** ffmpeg emits full 624-wide picture; clearYuv **does** blank 6 columns of decoded image data.  
- **On glass:** present uses DISPLAY_W=618; those 6 columns are outside the active display window either way. So user-visible picture is not missing 6 columns of *content that would have been shown* — the product contract is display 618 inside coded 624.

## Parent verify

```text
identity_skip=0 arm_rescale=0 reason=force_exact_crop_pad_unverified
vf contains crop=618:480 and pad=624:480
vf MUST NOT contain force_original_aspect_ratio=decrease or scale=618:480
```

## Host gates

```
test_ffmpeg_vf                 true rc=0
test_geom_frame_cost           true rc=0
test_yuv420p_chroma_480p       true rc=0
test_glass_loss_death_points   true rc=0
RED (FOAR mutation)            true rc=1
GREEN restore                  true rc=0
```

Logs: `.agent-work/w-geom/RED_force_crop_pad.log`, `GREEN_force_crop_pad.log`.
