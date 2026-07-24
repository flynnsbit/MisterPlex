# P3-WIDE RCA — HBlank@320 / DE / HDMI pillar

**Status:** eyes-on **FAIL** on last-confirmed lab RBF `6db3a4d8` (2026-07-24).  
**RCA:** **FINALIZED** (W-rca → **W-rca6**).  
**Reports:** `/tmp/misterplex-agent-W-wide.txt`, `/tmp/misterplex-agent-W-wide2.txt`, `/tmp/misterplex-agent-W-rca.txt`…**`/tmp/misterplex-agent-W-rca6.txt`**  
**RTL claim:** `edcf536` — `H_BLANK_S = H_CONTENT` (320) in `colorbars.sv` (HSync still Template 544/590).  
**New RBF:** `aa146c17` (full `aa146c17031536620039e04dceb23b68`) — Q-3l1 **BUILD_OK** 11:45:24; **collected** locally; **deploy H-owned** → WIDE retest = **W-wide3 post-deploy** (do not thrash).

## Symptom

HDMI UVC 800×600 captures with `force_bars=1` / Pattern=Bars show active content only on the **left ~60.4%** of the frame (x≈2–484), solid black on the right.

That ratio is **exactly** \(320/529 \approx 0.6049\): content painted for `hc < 320` inside a **Template DE of 529**.

## Timing (what the RTL is supposed to do)

| Parameter | Value | Role |
|-----------|------:|------|
| `H_CONTENT` | 320 | Paint / frame_store width |
| `H_LAST` | 637 | Line total 638 clocks |
| `H_BLANK_S` (pre-fix) | 529 | Template DE width |
| `H_BLANK_S` (edcf536 / HEAD / **aa146c17**) | 320 | DE = content (full-width after scale) |
| `H_SYNC_S` .. `H_SYNC_E` (edcf536 / aa146c17) | 544 .. 590 | Template-late HSync (**224-clock** blank after DE@320) |
| Dirty WIP (uncommitted, post–Q-3l1 map) | HSync 336 .. 384 | Short FP after DE; level `HBlank <= (hc >= 320)` |

`VGA_DE = ~(HBlank | VBlank)` (`Plex.sv`). ascal measures DE and scales to HDMI. Default AR 4:3 matches 320×240.

Bars use `bar = px[8:6]` → 64-px slices; only bars 0–4 (W/Y/C/G/M) fit in 0..319.

## Why the pillar remains

Lab bar **edges** land at capture x ≈ \(hc \times 800/529\) for `hc ∈ {0,64,128,192,256,320}` → ends at **x≈484**, then black. That is black **inside DE**, not an ascal letterbox outside content.

| If bitstream had… | Expected HDMI |
|-------------------|---------------|
| HBlank@529 + paint `hc<320` | ~60.4% span, 5 bars + black right ← **observed on `6db3a4d8`** |
| HBlank@320 + paint fills DE | ≥~95% span, 5 bars across full width |

So either:

1. **Most likely (H1):** deployed `6db3a4d8` still **behaves as HBlank@529** (non-absorb / need forced re-synth on next RBF), or  
2. **Secondary (H2):** HBlank@320 is live but Template-late HSync@544 / long porch confuses geometry — exact 320/529 fingerprint fits H1 better than pure H2, but dirty WIP already targets H2 for the follow-up rebuild.

`present_core` only forwards colorbars blanking; `mycore.v` (still HBlank@529) is not on the present path.

### Q-3l1 interaction (do not edit mid-fit)

| Artifact | Time (CDT) | colorbars state |
|----------|------------|-----------------|
| Q-3l1 Analysis map | ~11:34 | **edcf536 / state B** (HBlank@320, HSync@544) |
| Dirty WIP write | ~11:41 | **state C** (HSync@336/384 + level HBlank) |
| Smart recompile on resume | skipped Analysis | 3l1 RBF = **state B**, not C |
| BUILD_OK | 11:45:24 | RBF **aa146c17** produced + collected |

Leave `fpga/Plex_MiSTer/` alone while fitter runs. After BUILD_OK, eyes-on the new RBF first; only then commit/rebuild state C if still pillar.

## Post-fit full-width fix (handoff)

Executable protocol: **`/tmp/misterplex-agent-W-rca6.txt`** (finalize; also W-rca4/W-rca5).  
Next eyes-on worker after H deploy+FBAR of **aa146c17**: **W-wide3**.

| Step | Action | Pass gate |
|-----:|--------|-----------|
| 0 | Q-3l1 **BUILD_OK** + collect RBF → `releases/` | md5 **aa146c17…** ≠ `6db3a4d8` ✅ local |
| 1 | **One** `DEPLOY_LOAD=menu` (**H owns**) | remote md5 match; CORENAME=Plex |
| 2 | **FBAR** `test_fbar_fast` | EXIT=0 |
| 3 | Residual hard `res_dc=-24` `res_csum=20` | both match |
| 4 | **WIDE eyes-on** bars force=1 NTSC 60 (warm HDMI UVC) | span ≥ ~95%, not `PILLAR_320_of_529` |
| 5 | Branch PASS → mark DONE; FAIL ~60.5% → Fix-1 state C sole rebuild; unlock → Fix-2 paint-full-DE@529 | honest status |
| 6 | Park bars force=1 NTSC 60 | no `load_core` thrash |

**W-rca6 note:** do **not** retest WIDE on old RBF while H is deploying. Post-deploy retest is **required** (W-wide3).

**3l1 WIDE content:** state B only. Dirty state C (HSync 336..384) is follow-up Commit E if re-eyes still fail.

### Knobs (after fit only)

1. **Preferred:** Keep `H_BLANK_S = 320`. After 3l1 RBF: FBAR then re-eyes. If still pillar, force clean rebuild with explicit `10'd320` and/or **state C** HSync (336/384) + level HBlank.  
2. **Fallback:** Keep HBlank@529 for Template porch/HSync; **paint the full DE** (stretch bars across `hc` 0..528). Full-width bars without touching blanking; frame_store stays 320 until a later width change.  
3. **Only if lock fails after (1):** Adjust `H_SYNC_S/E` (keep pulse width ~48); leave `H_LAST=637` unless FPS is re-characterized.

Do not touch O[9] force-bars mux for WIDE alone.

## FBAR risk

| Change | Risk to FBAR |
|--------|----------------|
| HBlank@320 only | Low–med — means rise as black DE vanishes; re-run `test_fbar_fast` |
| HSync → 336 (state C) | Med — lock risk; black screen = High until HSync fixed |
| Unlock / black screen from timing | **High** — fix HSync/porch before shipping |
| Paint-full-DE @ HBlank@529 | Low — timing unchanged |
| force_bars / pattern mux edits | **High** — out of scope |

Always: one deploy → **FBAR green** → WIDE span check → park bars force=1 NTSC 60.

## Pass criteria

- `force_bars=1` bars NTSC 60: active span **≥ ~95%** of capture width; not `PILLAR_320_of_529`.  
- FBAR still EXIT=0 on same RBF.  
- Optional: true VGA/CRT eyes-on (HDMI is a proxy; see [crt-lcd-lab-checklist.md](crt-lcd-lab-checklist.md)).
