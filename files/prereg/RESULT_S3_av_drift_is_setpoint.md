# RESULT — S3 CONFIRMED (parent device run)

**Date:** 2026-08-01 (parent)  
**Method:** conf `AV_PRESENT_LEAD_MS` ∈ {20,40,80}; banner verified; rk=6 480p24; ~55 s/arm; conf bak+`cmp` restore OK.

## Pre-register vs measured (medians)

| LEAD | P_MEDIAN (w-avsync) | measured median | in band? |
|-----:|--------------------:|----------------:|:--------:|
| 20 | [−22, −12] | **−6** | **MISS** (toward zero) |
| 40 | [−42, −28] | **−32** | YES |
| 80 | [−82, −60] | **−72** | YES |

## Stronger un-preregistered evidence (parent)

| LEAD | measured **min** |
|-----:|-----------------:|
| 20 | **−16** |
| 40 | **−40** |
| 80 | **−79** |

**`min ≈ −LEAD` on all three arms** — hard lower edge of the deadband, not a physical A/V floor.

## Falsifier

“Stuck in [−45,−15] for all LEAD” → **did not occur**.

## Verdict

`av_drift_ms` is a **setpoint/deadband readout**. Not lipsync GT.  
A/V sync project status: **UNSCORED** until HDMI flash↔beep scores.

## Published miss (w-avsync)

LEAD=20 median predicted [−22,−12], measured **−6**. Not explained post-hoc; recorded only.

## Replacement

`docs/AVSYNC_REPLACEMENT_METRIC.md` — HDMI `offset_ms` via MS2109 v4l2+ALSA.
