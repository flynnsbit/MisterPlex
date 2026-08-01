# DEFECT 1 fix + DEFECT 2 decode-deficit notes (w-cpu)

## ERROR 17
**Discarded.** Fixtures are 24.000; no product work on false fps=24/1 vs 23.976.

## DEFECT 1 — FIXED (source)

**Bug:** `vfps`/`pfps` used `std::to_string(...).substr(0, 4)` → both 23.9694 and 23.9111 print `"23.9"`.  
Over 360 s that is a **±36 frame** ambiguity. Unusable as evidence.

**Fix (`media_player.cpp`):**
- `fmtFpsRate` → `snprintf %.4f` (resolves parent’s two rates: `23.9694` vs `23.9111`)
- `fmtSec3` for `audio_s` / `wall_s` (was substr 5)
- **`wall_ms=`** exact integer session wall (SoT with `frames=` / `presents=` already on the line via ledger fragment)

**Gate:** `tests/unit/test_media_fps_precision.sh`  
**Rule:** soak math uses **integer** `frames` / `presents` / `wall_ms`; rates are derived display only.

## DEFECT 2 — OPEN (decode-side deficit; do not conflate)

| Ledger | Parent measure | Notes |
|---|---|---|
| **Decode / produce** | expected 8640 @ 24×360s; **frames=8629**; deficit **11** (0.127%) | frames/24 ≈ 359.54 s ≈ audio_s 359.6 — wall vs content, not A/V split |
| **Presentation / glass** | **1.54%** (22 pixel skips / 1429) | Separate cause class; larger |

**Do not** explain glass loss with the 11-frame decode deficit or vice versa.

**Cause of the 11:** **unknown** from source alone. Candidates to measure (not findings):

1. Session wall_ms includes pre-roll / hold before first frame (origin arming) → content shorter than wall  
2. Early stop / EOF before full 360 wall seconds of *content*  
3. ffmpeg under-production (schedstat wait — separate C2 card)  
4. Stream start after t=0  

**Settling check (parent, read log integers only):**

```sh
# From last media: line of a 360s soak (after deploy with wall_ms=):
# expected_frames = floor(wall_ms * fps_num / (fps_den * 1000))  or  wall_s * 24 for 24/1
# decode_deficit  = expected_frames - frames
# present_gap     = frames - presents - drops   (ledger residual; not glass)
# glass loss      = external instrument only
grep 'media:.*frames=' "$LOG" | tail -n 3
echo "true rc=$?"
```

**PRE_REG:** if `wall_ms` origin includes ~458 ms before first frame (11/24), deficit is **startup origin**, not steady under-production.  
If deficit accumulates linearly over the soak → steady under-production.

## Headroom
Never quote `166.4/200⇒33.6`. Use inelastic ffmpeg+daemon and/or `schedstat` wait_frac / fixed-work tools already in `tools/`.
