# P3-WIDE RCA — HBlank@320 / DE / HDMI pillar

**Status:** eyes-on **FAIL** on lab RBF `6db3a4d8` (2026-07-24).  
**Reports:** `/tmp/misterplex-agent-W-wide.txt`, `/tmp/misterplex-agent-W-rca.txt`  
**RTL claim:** `edcf536` — `H_BLANK_S = H_CONTENT` (320) in `colorbars.sv`.

## Symptom

HDMI UVC 800×600 captures with `force_bars=1` / Pattern=Bars show active content only on the **left ~60.4%** of the frame (x≈2–484), solid black on the right.

That ratio is **exactly** \(320/529 \approx 0.6049\): content painted for `hc < 320` inside a **Template DE of 529**.

## Timing (what the RTL is supposed to do)

| Parameter | Value | Role |
|-----------|------:|------|
| `H_CONTENT` | 320 | Paint / frame_store width |
| `H_LAST` | 637 | Line total 638 clocks |
| `H_BLANK_S` (pre-fix) | 529 | Template DE width |
| `H_BLANK_S` (edcf536) | 320 | DE = content (full-width after scale) |
| `H_SYNC_S` .. `H_SYNC_E` | 544 .. 590 | HSync pulse (leave for lock) |

`VGA_DE = ~(HBlank | VBlank)` (`Plex.sv`). ascal measures DE and scales to HDMI. Default AR 4:3 matches 320×240.

Bars use `bar = px[8:6]` → 64-px slices; only bars 0–4 (W/Y/C/G/M) fit in 0..319.

## Why the pillar remains

Lab bar **edges** land at capture x ≈ \(hc \times 800/529\) for `hc ∈ {0,64,128,192,256,320}` → ends at **x≈484**, then black. That is black **inside DE**, not an ascal letterbox outside content.

| If bitstream had… | Expected HDMI |
|-------------------|---------------|
| HBlank@529 + paint `hc<320` | ~60.4% span, 5 bars + black right ← **observed** |
| HBlank@320 + paint fills DE | ≥~95% span, 5 bars across full width |

So either:

1. **Most likely:** deployed `6db3a4d8` still **behaves as HBlank@529** (non-absorb / need forced re-synth), or  
2. **Unlikely for this fingerprint:** HBlank@320 is live but some other path recreates a 320/529 active field (long front porch 320→544 does **not** by itself produce this exact pillar).

`present_core` only forwards colorbars blanking; `mycore.v` (still HBlank@529) is not on the present path.

## Knobs after Q-3l1 fit (do not edit during live fit)

1. **Preferred:** Keep `H_BLANK_S = 320` (`H_CONTENT`). After 3l1 RBF: FBAR then re-eyes. If still pillar, force a clean rebuild with an explicit `10'd320` and fix the stale file header that still says HBlank@529.  
2. **Fallback:** Keep HBlank@529 for Template porch/HSync; **paint the full DE** (stretch bars across `hc` 0..528). Full-width bars without touching blanking; frame_store stays 320 until a later width change.  
3. **Only if lock fails after (1):** Move `H_SYNC_S/E` earlier (keep pulse width); leave `H_LAST=637` unless FPS is re-characterized.

Do not touch O[9] force-bars mux for WIDE alone.

## FBAR risk

| Change | Risk to FBAR |
|--------|----------------|
| HBlank@320 only | Low–med — means rise as black DE vanishes; re-run `test_fbar_fast` |
| Unlock / black screen from timing | **High** — fix HSync/porch before shipping |
| Paint-full-DE @ HBlank@529 | Low — timing unchanged |
| force_bars / pattern mux edits | **High** — out of scope |

Always: one deploy → **FBAR green** → WIDE span check → park bars force=1 NTSC 60.

## Pass criteria

- `force_bars=1` bars NTSC 60: active span **≥ ~95%** of capture width; not `PILLAR_320_of_529`.  
- FBAR still EXIT=0 on same RBF.  
- Optional: true VGA/CRT eyes-on (HDMI is a proxy; see [crt-lcd-lab-checklist.md](crt-lcd-lab-checklist.md)).
