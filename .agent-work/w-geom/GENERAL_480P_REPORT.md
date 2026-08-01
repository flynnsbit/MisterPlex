# General 480p residual (B6) — settled host side + device WIDTH card

**Branch:** `w-geom-lane` (also pushed `w-avsync-hdmi-measure`)  
**Worktree:** `/home/flynnsbit/Projects/MisterPlex-wt-geom`  
**ARM-only. No RBF. Parent owns device.**

## Record corrections

1. B1 desync sign: N=2 TREK ⇒ S≈**224640** (624×240), **not** 460800 (640×480).
   Helper: `producerBytesFromCounterCopies(reader,N)`.
2. B2: product path already `-loglevel info` (`media_player.cpp` STREAM spawn).
   Parent 2417-2418 cite was stale. Gate: `test_b2_b5_source_wiring.sh`.
3. B4: `deliveryGeometryVerifiedFromBasis` ≡ **only** `"measured"`.
4. B5: arm teardown calls `rawPipeByteAligned` + `rawPipeDesynced` + `PIPE_DESYNC=1`.
5. FOAR on exact bank is PQ defect (624→475); tip uses crop+pad for unverified exact.

## B6 WIDTH policy (tip)

| delivery | reason / class |
|----------|----------------|
| exact 624×480 claim, unverified | `force_exact_crop_pad_unverified` |
| 640×480 / 720×480 | `crop_pad_no_v_scale_hfit` |
| 624×350/352, 426×240, 320×240 | `scale_pad_crop` (+FOAR) |

## Host gates (absolute make; true rc direct)

| gate | true rc |
|------|---------|
| test_ffmpeg_vf | 0 |
| test_yuv420p_chroma_480p | 0 |
| test_force_scale_ffmpeg_out.sh | 0 (18 pass incl crop_pad WIDTH) |
| test_b2_b5_source_wiring.sh | 0; RED loglevel→error rc=1 |

## Device — parent only

See `B6_WIDTH_FIXTURE_CONTRACT.md`. Need w-asset480 playable **640×480** and **720×480**
(plus existing 624×352 / 426×240 tier). Look-for: MEASURED_DELIVERY, vf reason, single
counter N=1, no magenta/wrap, teardown pipe_align ok.
