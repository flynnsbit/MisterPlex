# Identity-scale skip + sws_flags — pre-registration (host lane)

**SOURCE_SHA (host commit):** `d81db7f8` (`git rev-parse HEAD` at measure may advance)  
**Date (host work):** 2026-07-30  
**Lane:** w-arm (no device access)  
**Shipping default:** unchanged — `FFMPEG_SCALE=always`, empty `FFMPEG_SWS_FLAGS`, 240p default tier, `kPlex480pWeakBitrateKbps=2000` untouched.

## What landed (host-only)

| Piece | Path |
|---|---|
| Pure filter builder | `host/libmisterplex/ffmpeg_vf.hpp` |
| Player wiring + `media: vf_plan ...` log | `arm/misterplexd/media_player.cpp` |
| Conf | `FFMPEG_SCALE`, `FFMPEG_SWS_FLAGS`, `FFMPEG_SCALE_ASSUME_MATCH` in `main.cpp` |
| Unit | `tests/unit/test_ffmpeg_vf.cpp` |
| Freeze | `tests/unit/test_rtl_invariants.py` pins builder + crop pad string |

### Conf contract (opt-in; default = today)

| Key | Default | Meaning |
|---|---|---|
| `FFMPEG_SCALE` | `always` | Unconditional scale+pad (shipping) |
| `FFMPEG_SCALE=skip_identity` | — | Omit scale+pad only when source WxH == coded **or** `FFMPEG_SCALE_ASSUME_MATCH=1` |
| `FFMPEG_SCALE=off` | — | Never scale+pad (lab only) |
| `FFMPEG_SWS_FLAGS` | empty | No `:flags=` → ffmpeg default algo |
| `FFMPEG_SWS_FLAGS=fast_bilinear` | — | Inserts `:flags=fast_bilinear` on scale when scale is emitted |
| `FFMPEG_SCALE_ASSUME_MATCH` | `0` | With `skip_identity`, trust PMS ladder delivered coded WxH without probe |

**Pixel format** stays on `-pix_fmt` (rawvideo), not inside scale. Format conversion is not a resize.

**480p crop note:** product geometry is coded 624 / display 618. Identity skip on a 624×480 source omits the 624→618→624 swscale round-trip and relies on present-path `clearYuv420pCropPadding` for pad blacking. That is a **quality A/B**, not proven equivalent.

## Evidence used for predictions (quoted)

Live 480p post-GDM (parent / w-device A/B harness):

| tier | mplex %onecpu | ffmpeg %onecpu | total |
|---|---:|---:|---:|
| 240p | 8.5 | 13.8 | 22.3 |
| 480p | 20.8 | 69.0 | 89.8 |

w-device ffmpeg thread split @480p (sum ≈ process):

| component | %onecpu |
|---|---:|
| scale/filter `vf#0:0` | ~50 |
| mux | ~6 |
| H.264 decode | ~6 |

FEED archive full-stack (prior host lane): decode_null ~21.56 + scale ~2.95 + pipe ~5.26 + present ~10.41 → **40.19 ms/f**; 24 fps margin **+1.48 ms**.

## Pre-registered predictions (before w-device measures)

Baseline arm = **current shipping** (`FFMPEG_SCALE=always`, empty flags) on the same clip/offset/window as the 480p harness row above.

### P1 — `FFMPEG_SCALE=off` @480p when PMS already delivers ~624×480

| metric | predict | band |
|---|---|---|
| ffmpeg `vf#0:0` %onecpu | **≤ 5** (near gone) | 0–8 |
| ffmpeg process %onecpu | **~19** (69 − ~50) | 14–28 |
| total (mplex+ffmpeg) %onecpu | **~40** (89.8 − ~50) | 32–50 |
| wall ms/frame attributable to scale stage | **recover most of ~2.95 ms** FEED scale bucket; full vf wall may drop more if identity swscale was heavier on-device than FEED archive | 1.5–8 ms/f |
| 24 fps FEED-style margin | **moves from +1.48 toward ≥ +4 ms** if scale wall recovers ≥2.5 ms | direction: looser |
| 25 fps PAL viability | **becomes plausible** (was −0.19 ms) if ≥1 ms recovered on critical path | pass if margin ≥ 0 with sticky present |

**Miss condition:** vf#0:0 still ≥20 %onecpu with `scale_applied=0` in log → scale was not the dominant cost or PMS is not delivering tier size (graph still has other filters / wrong path).

### P2 — `FFMPEG_SCALE=skip_identity` + `FFMPEG_SCALE_ASSUME_MATCH=1` @480p

Same order of magnitude as P1 **if** log shows `identity_skip=1` and `reason=identity_skip_crop_pad_clear`.  
If log shows `scale_applied=1` under assume_match → **implementation bug** (host miss).

### P3 — `FFMPEG_SCALE=always` + `FFMPEG_SWS_FLAGS=fast_bilinear` @480p (scale still on)

| metric | predict | band |
|---|---|---|
| ffmpeg %onecpu vs always/default | **−5 to −15** absolute (not −50) | small vs P1 |
| image quality | **softer / more alias on edges** vs default sws | visual A/B required |
| Default algo must not change when flags empty | log `sws_flags=(default)` and vf **without** `:flags=` | binary |

**Do not ship fast_bilinear as default** from this work — quality trade needs user/parent decision after numbers.

### P4 — 240p control (`always` vs `off`/`skip_identity+assume`)

| metric | predict |
|---|---|
| ffmpeg savings | **much smaller than 480p** (13.8% total ffmpeg; vf share unknown, likely <<50pp) |
| If 240p vf is already cheap | total delta **≤ 5 %onecpu** |

### P5 — 720p projection (informational only; product store still rejects 720p)

If P1 recovers ~50pp @480p and remaining is ~linear in pixels without scale:

- Prior fail path: ~277 %onecpu with scale (above 200% ceiling).
- **Predict with scale skipped and PMS-native 720p:** **~70–120 %onecpu** (w-720arm band) — still a projection, not a measurement.
- Bus: 22.1 ms @60 MiB/s still **not the blocker** at 24 fps; store geometry remains hard gate.

## What is NOT claimed

- No claim that identity skip is visually identical to 618-pad path.
- No bitrate floor change.
- No 240p default change.
- No on-device measurement in this lane.

## w-device recipe (device lane owns execution)

See `W_DEVICE_RECIPE.md` in this directory.
