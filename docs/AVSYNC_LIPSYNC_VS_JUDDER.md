# Lipsync wander ≠ motion judder ≠ frame drops

> **ERROR 21 retraction:** pair_run2/3 residual 10.9 vs 14.4 are **not distinguishable** (parent p≈0.14). No device lipsync defect from those windows. W2 “too coarse” criticism **withdrawn**. Need **instrument floor** (`docs/AVSYNC_INSTRUMENT_FLOOR.md`) before any device A/V claim. Beat T_cap=33ms × mark=2s → **66 s** phase beat.


## Binding scope (do not stretch)

| User complaint | Channel | Instrument | What it can prove |
|----------------|---------|------------|-------------------|
| Audio off / lips wrong | **A/V phase** | `avsync_measure_hdmi.py` flash↔beep offset residual | Detrended lipsync wander (ms); Δ+100 validation |
| Picture stutters / “not 480p smooth” | **Motion judder** | **Not** the lipsync tool | Needs motion/content cadence, not beep phase |
| Frames dropped | **Frame completeness** | `glass_template_skip.py` / burned-in counter OCR | Per-frame counter holes; **not** 2 s marker gaps alone |

**Do not** treat residual_rms or WANDER as proof of drops.  
**Do not** treat nominal vfps as proof of lipsync.  
Parent already showed WANDER at vfps=23.9, drops_delta=0 — lipsync residual is a **different** defect class from underproduction.

## What inter-flash intervals add

Flash onsets every ~2.000 s give a **marker presentation cadence** histogram (p50/p95/p99/max).

- Multi-second gaps → missed markers / long freezes / stream glitches (**visible** here).
- Single-frame drop (1/24 s) between markers → **invisible** at 2 s period.
- A 50 ms lipsync residual **need not** appear as an interval outlier (phase slip without period error).

Existing live artifacts already show the split:

| window | residual_rms | interval outliers vs 2 s |
|--------|-------------:|--------------------------|
| live20 (mild wander) | 13.5 | **0** |
| live20b (heavy) | 35.8 | **2** (3.5 s, 5.2 s) |
| live21b (heavy) | 46.4 | **2** (2.75 s, 3.08 s) |

Heavy lipsync wander **sometimes co-occurs** with marker gaps; mild WANDER can occur **without** them. That is decisive when present; absence of outliers does **not** clear judder/drops.

## Pair-run SNR honesty (parent pair_run2 STABLE vs pair_run3 WANDER)

Quoted from parent logs (measured):

| | STABLE (run2) | WANDER (run3) |
|--|-----:|-----:|
| residual_rms_ms | **10.857** | **14.398** |
| excess_wander_rms_ms | 5.208 | 10.796 |
| detrended_max_abs_ms | 22.70 | **50.80** |
| sigma_ms (offset) | 10.86 | 15.93 |
| se_median_ms | 2.53 | 3.65 |
| wander_rms_tol_ms | 12.440 (=√(9.526²+8²)) | same |
| quant_rms_ms | 9.526 | 9.526 |
| n | 29 | 30 |

### Quant floor / SNR

- Irreducible instrument floor on flash timing: **quant = T/√12 ≈ 9.53 ms** @ ~30 Hz capture.
- Gate: residual > √(quant² + 8²) = **12.44 ms** (excess budget 8 ms DEFAULT_ASSUMED).
- STABLE residual **10.86** sits **~1.3 ms under** tol; WANDER **14.40** sits **~2.0 ms over** tol.
- Excess over quant: STABLE 5.2 ms vs WANDER 10.8 ms → WANDER has ~2× excess power, but both are **near the floor**.
- **SNR of residual vs quant:** residual/quant = 1.14 (STABLE) vs 1.51 (WANDER). Not a high-SNR separation.

### Are A and B distinguishable?

- **Binary class gate:** yes by construction — one ≤12.440, one >12.440 (timing_class differs).
- **Statistical residual variance (need series):** one summary RMS per window is weak. Prefer F-test on detrended residual **series** (`avsync_glass_cadence.py --timeseries A --compare-timeseries B`).
- **Median offset SE:** se 2.5–3.6 ms; |Δmedian| ~14.5 ms between run2/run3 medians (−128.4 vs −142.9) is ~3–4 SE if independent — but absolute median is **raw_uncalibrated** and not the wander claim.
- **detrended_max 22.7 vs 50.8:** large tail difference; more credible than RMS alone that something intermittent hit run3.
- **Honest interim:** the WANDER label is **gate-true** near the quant floor; calling the session “intermittent defect rate” from **n=2 windows** is **not** justified. Need **N≥6** scored windows for a rate. If F-test on residual series is non-significant, **retract intermittent framing** and treat residual 10–14 ms as **same noise band** with a brittle threshold.

### Recalibrated W2 (replace residual>25)

Parent W2 used residual>25; real effect was **14.4 vs tol 12.44**. New pre-reg:

- **W2′:** `timing_class=WANDER` ∧ `vfps_p50≥23.5` ∧ `drops_delta=0` → `WANDER_WITHOUT_COLLAPSE` (already parent HIT).
- **W2″:** score on **excess_wander_rms_ms** and **detrended_max_abs_ms**, not raw residual alone.
- Do **not** use residual>25 as the production threshold.

## Frame-drop instrument (gap acknowledgment)

To answer “frames being dropped” at 24 fps:

```text
# Parent: directory of HDMI PNGs + pts + templates — NOT lipsync soak
python3 tools/glass_template_skip.py CAP_DIR --templates T.pkl --pts pts.csv \
  --source-fps 24 --capture-fps 60 --refresh-hz 60
```

That is **w-instr / glass** territory. This lane keeps lipsync + marker cadence only.

## Two-roots

`ea255e04` fixed avsync wait/epoch/stamp. `avsync_pair_daemon_hdmi.sh` DAEMON_LOG_REMOTE default is **w-lint** (repo-wide). Do not fork a second audit.
