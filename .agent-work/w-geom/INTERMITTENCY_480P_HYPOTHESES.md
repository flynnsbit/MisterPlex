# 480p intermittency — source hypotheses + parent discriminators

**SHA context:** w-geom-lane tip at commit of this file.  
**Device:** parent only. Agent did not run casts.

---

## Closed on tip (independent verify — quoted)

### 2000 kbps floor — GONE as hard fail; heuristic default remains

`arm/misterplexd/plex_resolve.cpp` `validateWeakLadder` (tip): **no**  
`if (maxVideoBitrateKbps < 2000) return fail(...)`.  
Comment at ~338: floors are NOT decoder contracts.

**Still hard decoder contracts** (same function):
- `h264Profile == "baseline"`
- `h264Level <= 30`
- codecs h264/aac, positive bitrate/quality, coded size ≤ DDR max

**2000 remains** `kPlex480pWeakBitrateKbps` default + `recommendedMinVideoBitrateKbps`  
→ **quality/link heuristic**, not FPGA profile/level contract.  
Fix shape: advisory WARN + honoured `WEAK_BITRATE` (shipped).

### B4 — already measured-only

`yuv420p_chroma_health.hpp:134-137`:
```cpp
return std::string(deliveryBasis) == "measured";
```
`library_media` / `transcode_request` rejected (unit + comment).  
`main.cpp` sets `deliveryBasis = "library_media"` but  
`deliveryGeometryVerifiedFromBasis` → false → `delivery_verified=0` at play.

### B5 — already on product teardown (parent brief stale)

`media_player.cpp` teardown:
- `rawPipeByteAligned(totalBytes, frameBytes)` → `PIPE_BYTE_MISALIGN` / `total_mod_frame=0`
- `rawPipeDesynced(prod, reader, frameIndex)` → `PIPE_DESYNC=1`
Uses **runtime `frameBytes`**, not a bare `449280` literal (same value on 624×480 bank).

**This turn:** also emit `pipe_total_mod=` on 1 Hz `media:` and  
`SESSION_COLLAPSE_LEDGER` at teardown for collapsed-vs-healthy greps.

---

## Intermittency — what parent already killed (do not re-run)

Consumer back-pressure, TCP rcv window, PMS capacity (speed 19.8×), `-re`,  
raw link ceiling vs lone curl. **Accepted.**

Collapsed still shows **`supply_ratio=0.72`** (STARVED-class) with climbing drops —  
arrival of media seconds lags wall. That is **supply under-run**, not geom pipe walk  
(unless ledger shows otherwise).

---

## Hypotheses testable from logs (no new mechanism asserted)

| ID | Hypothesis | Source basis | Discriminator (collapsed vs healthy) |
|----|------------|--------------|--------------------------------------|
| **H-geom** | Sessions differ in delivered WxH or `identity_skip` / vf path | vfPlan freezes at play; MEASURED later; mid-stream change cannot rebuild vf (`MEASURED_DELIVERY mid-stream`) | `measured_delivery`, `identity_skip`, `arm_rescale`, `vf_reason`, `producer_bytes` equal across runs? |
| **H-desync** | Silent raw-pipe phase walk | B5: identity_skip && prod≠reader; remainder often 0 while walking | `desync_risk`, `phase_desync`, `pipe_total_mod`, teardown `PIPE_DESYNC` / `byte_align` |
| **H-supply** | Intermittent under-arrival (second limiter / PMS serve mode) | `supply_ratio=audio_s/wall_s`; parent 0.72 vs ~1.0 | `supply_class` STARVED vs OK; ratio trajectory first 30s vs whole soak |
| **H-start** | Startup transient only (late first frames) | buffering → playing; audio hold until first video | Early window `supply_ratio` / drops_delta bad, then recovers — vs whole-soak STARVED |
| **H-pacer** | Pacer elects Drop under clock stress while supply OK | `drops` only on `!present` path | `supply_class=OK` but drops climb — **would kill H-supply** |
| **H-ref** | refFrames/decode latency past threshold | not directly in daemon; PMS session XML | Parent: compare `/transcode/sessions` refFrames + speed when collapsed vs healthy |

**Pre-register (publish misses after N≥6 paired casts):**

| Prediction | Kill if |
|------------|---------|
| H-geom primary | All runs same `measured_delivery` + `identity_skip` + `vf_reason` |
| H-desync primary | All runs `desync_risk=0` `pipe_total_mod=0` `byte_align=1` no PIPE_DESYNC |
| H-supply primary | Collapsed `supply_class=STARVED` and healthy `OK`/`MARGINAL` with matching geom |
| H-start primary | Collapsed only bad in wall_s&lt;30; healthy after |
| H-pacer primary | Collapsed `supply_class=OK` with climbing drops |

**From source, default prior after parent exclusions:** H-supply (arrival)  
most consistent with `supply_ratio=0.72` + starved readers; **not proven**.  
H-geom is the one geometry can kill in one greppable ledger line.

---

## Parent cast/capture protocol (exact)

Deploy daemon built from this tip (parent owns deploy). Conf unchanged from  
user 480p daily (or lab DECODE=624x480). Same rk=9, same core.

```sh
LOG=/media/fat/misterplex_v2/misterplexd.log
# clear or mark epoch so lines belong to THIS cast
echo "=== CAST_MARK $(date -Is) ===" >> "$LOG"

# Cast rk=9; soak ≥120s wall (collapsed sample was ~245s — prefer ≥180s)
# During soak optional: one sample of PMS session (parent path):
#   curl -sS .../transcode/sessions | tee /tmp/pms_sess_CASTID.xml

# After stop/EOF:
grep -E 'CAST_MARK|GEOM requested_pms=|MEASURED_DELIVERY |media: .*supply_class=|SESSION_COLLAPSE_LEDGER|PIPE_DESYNC|PIPE_BYTE_MISALIGN|LADDER_STEPDOWN' \
  "$LOG" | tail -200
echo "true rc=$?"
```

**Per-cast extract (collapsed vs healthy):**

```sh
# Replace CASTID / time window as needed
awk '/CAST_MARK/{m=$0} /SESSION_COLLAPSE_LEDGER/{print m; print}' "$LOG" | tail -20
echo "true rc=$?"
```

**PRE_REG readings to fill:**

```
cast_id=
measured_delivery=
identity_skip=
arm_rescale=
vf_reason=
producer_bytes=
reader_bytes=
supply_class_p50=   # from media: lines wall_s>=10
supply_ratio_min=
drops_end=
pfps_p50=
PIPE_DESYNC present? y/n
byte_align=
```

Repeat **N≥6**. If H-geom fields identical and only supply_ratio/drops differ →  
geometry lane cannot own root cause; hand H-supply to w-cpu-1 second-limiter.

---

## What this tip adds for the ledger

On every 1 Hz `media:` line:
- `identity_skip=` `arm_rescale=` `vf_reason=`
- `producer_bytes=` `reader_bytes=` `pipe_total_mod=`
- existing `measured_delivery=` `supply_ratio=` `supply_class=`

At teardown:
- `media: SESSION_COLLAPSE_LEDGER …` (full discriminator set)
- existing B5 `pipe_align` / `PIPE_DESYNC` / `MEASURED_DELIVERY_FINAL`
