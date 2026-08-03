# B9 — Display aspect under runtime DE

## Rule (ship)

**Display aspect ratio (DAR) is published by the daemon from PMS metadata via PLXG q5.
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
Cadence is the same defect class: fabric cannot infer fps from DE either.

## Menu → pins (`plex_video_ar`)

| `status[122:121]` | Name | `VIDEO_ARX:ARY` |
|------------------:|------|-----------------|
| 0 | Original | **host DAR** if `dar_valid`, else legacy **4:3** |
| 1 | Full Screen | **0:0** (framework fill — stretches under runtime DE) |
| 2 | ARC1 | 1:0 |
| 3 | ARC2 | 2:0 |

Legacy Original without host DAR is the **user-visible defect** for 16:9 true-DE
content (960×540 presents as 4:3). RED twin `RED_16_9_AS_4_3` locks that.

## PLXG q5 — parent ABI arbitration #2 (frozen)

Record grows **q0–q4 → q0–q5**: doorbell **`0x800..0x82F`**, q5 at **`+0x828`**.

| bits | field |
|------|--------|
| `[11:0]` | `dar_x` (0 = unspecified) |
| `[23:12]` | `dar_y` (0 = unspecified) |
| `[31:24]` | `content_fps` integer (0 = unspecified) |
| `[32]` | `dar_valid` |
| `[33]` | `fps_valid` |
| `[63:34]` | **RESERVED = 0** — receiver rejects non-zero (whole promote) |

Do **not** reuse `q0[47:34]` — w-mem B4 **epoch** owns those bits.

### Ownership

| Piece | Owner |
|-------|--------|
| Headers, poller, B16 frame-boundary atomicity, `test_ddr_720p_abi` @0x828 | **w-mem** |
| PMS DAR + measured fps → daemon publish (`dar_valid`/`fps_valid`=0 if unknown) | **w-path** |
| `plex_video_ar`, pin TB, latch **DAR consume** bit layout | **w-scaler** |
| `content_fps` → `V_TOTAL` (B15); never hardcode 30 | **w-clock** |

## Evidence

```bash
tests/unit/test_plex_ar_pins_rtl_sim.sh; echo "true rc=$?"
tests/unit/test_present_geom_latch_rtl_sim.sh; echo "true rc=$?"
```

Expect greens: ORIG+DAR→16:9, FULL→0:0, ARC1→1:0; q5 official pack → dar 16:9 + fps 30.
Expect RED: `RED_16_9_AS_4_3` rc=1 pins 4:3; q5 reserved nonzero rejected; old dar_y@[27:16] mis-decode.
