# w-clock STATUS

## Branch
`w-clock-bump` @ worktree MisterPlex-wt-clock

## rd-duck B15 adversarial — CLOSED (sim)

| Item | Evidence |
|------|----------|
| Honest raster naming (not unique banks) | `b15_cadence_framecount_tb` prints `not unique-bank claim` |
| Cadence Hz = core 24/30 not HDMI 60 | `present_core` `cadence_display_hz`; RED HDMI60 advances=3/5 |
| Film class `fps<=24` only; 25→V564 | GREEN `OK fps=25 -> TV class V=564`; advances 4/5 @25/30 |
| RED ignore fps_valid | 30 title → 4 film frames |
| present_core ↔ w-mem B16 | `PRESENT_CORE_MERGE_NOTE.md` — manual merge, not whole-file |

```
test_b15_cadence_framecount true rc=0
  GREEN raster24=4 /30=5 /25=5 adv30=5 adv25=4 unspecified→24
  RED IGNORE_FPS_VALID true rc=0
  RED CADENCE_HDMI60 advances=3 < raster=5 true rc=0
```

## Still open
- V705 STA UNKNOWN until parent fit (prereg medium @20; miss if Fmax_sys<20)
- plxg_fps_* staged 0 until w-mem q5+B16
- PLL 20/90 unapplied; no 25 MHz ship (stub Fmax 23.46)
- B2_NO_RASTER_GENERATOR fitgate re-scope (math pack deliberate)

## Do not
Quartus fit, device, invent 30 when fps_valid=0, whole-file present_core merge.
