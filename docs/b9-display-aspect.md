# B9 — Display aspect under runtime DE

## Rule (ship)

**Display aspect ratio (DAR) is published by the daemon from PMS metadata via PLXG.
The fabric does not infer DAR from coded width/height.**

Reason (parent library survey + PMS measurements):

| Delivered coded | Storage AR | Intended DAR | Infer-from-coded? |
|-----------------|-----------:|--------------|-------------------|
| 624×480 | 1.30 | often 16:9 anamorphic or 4:3 | **ambiguous** |
| 720×480 | 1.50 | NTSC DVD 16:9 or 4:3 anamorphic | **unsound** |
| 624×352 | 1.77 | 16:9 | accidental OK |
| 960×540 | 1.78 | 16:9 | accidental OK |
| 320×240 | 1.33 | 4:3 | accidental OK |

`720×480` is the existence proof that storage AR ≠ display AR.

## Menu → pins (`plex_video_ar`)

| `status[122:121]` | Name | `VIDEO_ARX:ARY` |
|------------------:|------|-----------------|
| 0 | Original | **host DAR** if `dar_valid`, else legacy **4:3** |
| 1 | Full Screen | **0:0** (framework fill) |
| 2 | ARC1 | 1:0 |
| 3 | ARC2 | 2:0 |

Legacy Original without host DAR is the **user-visible defect** for 16:9 true-DE
content (960×540 presents as 4:3). RED twin `RED_16_9_AS_4_3` locks that.

## PLXG field proposal (parent arbitrates — w-mem owns headers)

Do **not** reuse `q0[47:34]` — w-mem B4 **epoch** owns those bits.

**Proposed trailing qword `q5` (optional beat after atomic q0..q4):**

| bits | field |
|------|--------|
| `[11:0]` | `dar_x` (e.g. 16) |
| `[27:16]` | `dar_y` (e.g. 9) |
| `[32]` | `dar_valid` |

- 5-qword body (geom) stays lockstep with w-mem.
- Daemon (w-path) resolves DAR via `pms_delivery_geom.hpp` / Stream@pixelAspectRatio
  / Media@aspectRatio and writes q5 after body commit (or parent folds into 6-qword).
- Fabric `present_geom_latch` already latches q5 → `dar_*` → `plex_video_ar`.

## Ownership

| Piece | Owner |
|-------|--------|
| `plex_video_ar.sv`, Plex pin mux, pin TB | **w-scaler** (this lane) |
| PLXG header / poller / epoch | **w-mem** |
| PMS DAR → daemon publish | **w-path** |
| Arbitration of q5 vs 6-qword | **parent** |

## Evidence

```bash
tests/unit/test_plex_ar_pins_rtl_sim.sh; echo "true rc=$?"
```

Expect greens: ORIG+DAR→16:9, FULL→0:0, ARC1→1:0, modes differ.
Expect RED: `RED_16_9_AS_4_3` rc=1 with pins 4:3.
