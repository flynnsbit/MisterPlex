# w-geom Q1–Q4 — source answers (no device)

**Worktree:** `/home/flynnsbit/Projects/MisterPlex-wt-geom`  
**Branch:** `w-geom-lane`  
**Rule 0:** quoted source / measured host gates only. Parent owns device.

---

## Q1 — `measured=624x350` from library 624×352

### 1) Where does 350 come from?

**Our request is not 350.** 480p tier advertises / requests **624×480**:

- `osd_menu.hpp` `contentResolutionFor480p()` → label `plex480pCodedResolutionLabel()` = **`"624x480"`** (static_assert locked to 624/480).
- `plex_resolve.cpp` `buildUniversalTranscodeUrl` emits  
  `&videoResolution=` + `weak.videoResolution` (that label).
- Same file `plexClientProfileExtra` adds PMS upperBound  
  `video.width=624` and `video.height=480` when W/H parse.

**What we log as `measured=` / `decode=` geometry pair:**

- `measuredDeliveryW_/H_` are set **only** from ffmpeg stderr **Input** Stream banners via  
  `parseFfmpegGeometryLine` (`ffmpeg_vf.hpp`) in `media_player.cpp` stderr pump  
  (`MEASURED_DELIVERY delivered_geom=… src=ffmpeg_banner`).
- Comment in that block is explicit: **not** library metadata, **not** PMS sessions,  
  **not** the requested `videoResolution=`.

**350 is therefore the coded size of the H.264 elementary stream ffmpeg opened**  
(PMS transcoder output), not a height we compute in ARM.

**Why 350 vs disk 352?** No ARM path writes 350. Arithmetic that matches delivery:

```
624 × 9 / 16 = 351.0
even-floor for YUV = 350
```

So a **square-pixel 16:9 fit at max width 624** lands on **350** even when the  
library asset is tagged **624×352** (often 2.35-ish SAR / different DAR).  
That is a **PMS/transcode** choice, not our pad/scale math.

**Settled from source:** request = 624×480; measured = ffmpeg banner of delivery.  
**Derived (not PMS-quoted):** 350 ↔ 16:9@624.  
**Unknown without parent capture:** exact PMS `videoStream` DAR/SAR on rk=9 —  
check: one cast log line `MEASURED_DELIVERY delivered_geom=624x350` next to  
PMS Media `width/height/aspectRatio` for that part.

### 2) Bytes/frame under FORCE_SCALE — constant 449280?

**Yes for product OUTPUT.** Reader always consumes coded bank:

`yuv420pFrameBytesWH(624,480) = 449280`.

Producer raw sizes if identity were used:

| geom | I420 bytes |
|------|------------|
| 624×350 | 327600 |
| 624×352 | 329472 |
| 624×480 | 449280 |

Product path with `DDR_YUV_FORCE_SCALE` → Always: **scale and/or crop+pad** so  
`identity_skip=0` on unverified / mismatch; OUTPUT pin proven host-side:

```
tests/unit/test_force_scale_ffmpeg_out.sh
PASS g_624x350 src=624x350 bytes=1347840 want=1347840   # 3×449280
PASS g_scope_235 src=624x352 …
SUMMARY pass=18 fail=0 frame_bytes=449280
true rc=0
```

Construction gate also requires V-mismatch 624×350 → `scale_applied && !identity_skip`.

### 3) What does `desync_risk=0` detect?

`pipeDesyncRisk(prod, reader, identity_skip)` (`ffmpeg_vf.hpp`):

- false if either size 0 or `prod == reader`
- else **`return identity_skip` only**

So risk=1 **only** when play-time plan is identity **and** measured input bytes ≠ reader.  
With FORCE_SCALE Always, 624×350 → scale → `identity_skip=0` → **desync_risk=0 by design**  
even though producer *input* is 327600. That is correct: vf pins OUTPUT; it is **not**  
a pipe phase-walk. It does **not** mean “350 is MB-aligned” or “PMS matched request”.

---

## Q2 — B5 non-silent mismatch

**Parent brief that “only the unit test calls rawPipe*” is STALE vs this tip.**

`media_player.cpp` teardown (after `errThr.join`):

- `rawPipeByteAligned(totalBytes, frameBytes)` → ERROR `PIPE_BYTE_MISALIGN` if false  
- `rawPipeDesynced(prodBytes, frameBytes, frameIndex)` from measured W×H  
- `pipeDesyncRisk` + phase + !aligned → `PIPE_DESYNC=1` ERROR path  
- success path logs `pipe_align ok … total_mod_frame=0`

Wiring gate:

```
bash tests/unit/test_b2_b5_source_wiring.sh
… PASS B5_byte_align / B5_phase_desync / B5_pipe_desync_log …
true rc=0
```

**No further code required for the cheap permanent fix** — already shipped.  
Mid-stream short-read still only at EOF (`media_player` read loop); B5 catches  
session-level misalign + identity mismatch. Live `PIPE_DESYNC` trip triage → **w-cpu-1**.

---

## Q3 — B1 wrong-sign desync model — SETTLED

Historical “producer = 640×480 = 460800” **cannot** place two full counters in one  
449280 reader raster (0.975 frames/raster).

Discriminator in source (`producerBytesFromCounterCopies`):

```
N legible copies ⇒ S ≈ reader_bytes / N
N=2 ⇒ S = 224640 = 624×240 I420 exactly
N=4 ⇒ 112320
```

640×480 is **larger** than the reader → wrong packing class.  
Horizontal wrap on glass ⇒ producer width ≠ 624 (pure 624-wide roll has no H component;  
`449280 = 624×720` exactly).

Unit gate `test_yuv420p_chroma_480p.cpp` prints  
`GREEN_DESYNC coded=449280 s624x240=224640 s640x480=… (640 NOT N=2)`.

**Fix (FORCE_SCALE / pin) is validated by measurement; explanation is now aligned.**

---

## Q4 — Fabric scaler ARM saving — ONE instrument / ONE window

**Gate:** `tests/unit/test_fabric_scaler_delta.sh`  
**Window:** N=120, same host, three arms:

| Arm | Path | Result (this host run) |
|-----|------|-------------------------|
| D240 | 320×240 decode → null | cpu_ms_f=**0.5698** |
| S240 | 320×240 + product scale/pad fast_bilinear | cpu_ms_f=**1.1737**, bytes pin OK |
| I624 | 624×480 crop+pad only | cpu_ms_f=**1.0217**, bytes pin OK |

```
DELTA_SCALE_cpu_ms_f = S240 − D240 = 0.6039   tag=measured (host x86)
FABRIC_SCALER_HOST_SAVE_est_pctonecpu_at_24fps ≈ 1.45  ESTIMATED_from_host_ms
true rc=0
```

**Interpretation (honest):**

- This is the **scale work unit** fabric would remove on the **240→618/624** path  
  (`arm_rescale=1`), measured as child CPU delta on **host**, not DE10 A9.
- Host save is **small (~0.6 ms/f)**. Do **not** request a Quartus fit from this alone.
- Archived **A9** FEED (native 624 path, not 240 upscale):  
  `decode_null` 21.562 ms/f wall, **+scale delta 2.954 ms/f**  
  (`docs/evidence/p480/p720-bus-and-bitrate-margin.md`).  
  That is the only A9 scale delta on record; it is **native**, not 320→618.
- Live “~50 of 69 %onecpu is scale” remains **CONTESTED** vs FEED; this host gate  
  **does not** support scale-dominates on x86 and **does not** settle A9 240 upscale %.

**Parent binding command (device — not run by w-geom):** same three arms with  
on-board ffmpeg + `/usr/bin/time -f`, N≥300, report `child_user+sys ms/f` and  
`DELTA_SCALE`. Fit request only if A9 delta justifies M10K/ALM (inventory still  
lists Main poll + decode ahead of scale).

---

## Gates re-run this turn (true rc direct)

| Gate | true rc |
|------|---------|
| `test_b2_b5_source_wiring.sh` | 0 |
| `test_force_scale_ffmpeg_out.sh` (incl. g_624x350) | 0 |
| `test_force_scale_sws_cost.sh` | 0 |
| `test_fabric_scaler_delta.sh` | 0 |

---

## Out of lane (do not fold)

- User bitrate/link 1.56 vs 2000 kbps floor — parent RCA, not geom.  
- Judder IFI histogram — w-instr.  
- PIPE_DESYNC four trips triage — w-cpu-1.  
- M2 publish jitter — ERROR 21 retracted; no defect established.
