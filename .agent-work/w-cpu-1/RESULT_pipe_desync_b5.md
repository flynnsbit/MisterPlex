# B5 PIPE_DESYNC — RCA + classification fix

## Pre-register (2) — published

**Prediction before code read:** teardown/EOF partial; large `frames=` then final short read; ERROR severity wrong if only at EOF.

**Result:** **HIT on teardown-only.** Miss on mechanism: not a short-read residual. `producer_bytes` is **per-frame I420 size of MEASURED_DELIVERY (pre-vf input banner)**, not a final partial read.

## 1. Where / what (quoted)

**Emit site (sole `PIPE_DESYNC=1`):** `arm/misterplexd/media_player.cpp` teardown epilogue after the read loop + `killChildren()` — not mid-stream.

**Expression (pre-fix):**
```cpp
prodBytes = yuv420pFrameBytesWH(measuredDeliveryW_, measuredDeliveryH_); // INPUT banner
phaseDesync = rawPipeDesynced(prodBytes, frameBytes, frameIndex);
risk = sticky || pipeDesyncRisk(...) || phaseDesync || !byteAligned;
// if (risk) ERROR PIPE_DESYNC=1 ...
```

**`rawPipeDesynced`** (`host/libmisterplex/ffmpeg_vf.hpp`):
```cpp
if (producer == reader) return false;
return phase_offset != 0 || frame_index > 0;  // ANY mismatch + frames>0 ⇒ true
```

**`producer_bytes` meaning:** I420 bytes for measured **input** WxH from ffmpeg Stream banner (`MEASURED_DELIVERY`), **not** residual bytes, **not** last partial read. Reader is coded bank (624×480 → 449280).

Mid-stream only logs `PIPE_DESYNC_RISK` when `identity_skip && input≠reader` (correctly gated). Parent logs are `PIPE_DESYNC=1` (teardown form).

## 2. Teardown vs live

| Evidence | Meaning |
|---|---|
| Single call site after loop + killChildren | Always session-end |
| `frames=720/2739/7694/2391` | Stream ran many full frames first |
| Parent `byte_align=1` on all four | `totalBytes % 449280 == 0` — pipe filled complete reader frames |
| Short-read is terminal mid-session | Cannot be silent mid-stream partial |

**Verdict: teardown classification defect, not live magenta phase-walk.** Detection of real identity_skip mismatch remains.

## 3. Geometry reverse (I420 = w×h×3/2)

| producer_bytes | geometry (exact) |
|---:|---|
| 449280 | 624×480 (reader) |
| 115200 | **320×240** |
| 112320 | **312×240** |
| 86400 | **320×180** |
| 438048 | **624×468** |

These are typical **source/transcode input** sizes while the reader stays coded 624×480 under FORCE_SCALE / crop+pad.

## 4. Root cause

Teardown called `rawPipeDesynced(INPUT, reader, frames)`. Under product scale (`identity_skip=0`), the **pipe** carries post-vf frames (coded size); INPUT≠reader is **expected**. The mid-stream path already knew this (`pipeDesyncRisk` requires `identity_skip`); teardown did not.

So every non-624×480 source session that completed cleanly logged **ERROR hard telemetry trip (B5)** — trains operators to ignore ERROR.

## 5. Fix (detection not weakened)

`classifyPipeDesyncTeardown()`:

| class | hard ERROR? | when |
|---|---|---|
| `PHASE_LIVE` | yes | identity_skip + input≠reader, or MEASURED_OUTPUT≠reader, or sticky mid-stream risk |
| `BYTE_MISALIGN` | yes | totalBytes % reader ≠ 0 |
| `INPUT_NE_READER_SCALED` | **no** (info) | input≠reader, !identity_skip, pipe phase OK |
| `PHASE_NO_DATA` | no | scale path, no MEASURED_OUTPUT |
| `OK` | no | match |

Also store `measuredOutputW_/H_` from MEASURED_OUTPUT for pipe-phase under scale.

Host gate: parent fixtures 115200/86400/112320/438048 → `!hard_error` under scale; same 115200 + identity_skip → `PHASE_LIVE`.

## 6. Parent verify (after deploy of this daemon)

```sh
# After a cast of a non-624 source (e.g. 320x240) ends:
grep -E 'PIPE_DESYNC|MEASURED_DELIVERY_FINAL|MEASURED_OUTPUT|pipe_align' /path/to/daemon.log | tail -40
echo "true rc=$?"
# PRE-REGISTER:
#   expect class=INPUT_NE_READER_SCALED (info), ZERO "ERROR media: PIPE_DESYNC=1"
#   expect pipe_align ok; MEASURED_OUTPUT 624x480 when banner present
#   expect ERROR PIPE_DESYNC only if identity_skip=1 with mismatch or byte misalign
```

## 7. Not claimed

- Did not re-open PMS-supply (retired).
- Did not prove every historical trip had FORCE_SCALE on — product default is force; parent must confirm `identity_skip=` on companion FINAL lines if any ERROR remains.
