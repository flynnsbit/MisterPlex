# Audit: A/V conclusions that rest on OLD-argv instrument data

**Date:** 2026-08-01  
**Lane:** w-avsync  
**Trigger:** Parent A/B — OLD ffmpeg (no wallclock/copyts) vs NEW (wallclock both + copyts + start_at_zero).  
**OLD bimodality ~117 ms = INSTRUMENT ARTIFACT. Retracted as device defect.**

## Capture-config fingerprints (do not pool)

| Pool | Fingerprint / argv class | Between-run median range (measured) |
|------|--------------------------|-------------------------------------|
| OLD (`/tmp/ab/old_*.json`, n=6) | pre-wallclock dual-input | **135.33 ms** (H-QUANT REJECTED vs T=33.33) |
| NEW (`/tmp/sixfield/av*.json` + `/tmp/ab/new_*.json`, n=16) | wallclock+copyts class | **25.00 ms** (H-QUANT SUPPORTED, T=33.00) |

Source: `tools/analyze_avsync_residual.py` run 2026-08-01, artifacts  
`.agent-work/w-avsync/residual_{old,new}_pool.txt`.

## Suspect absolute / cluster claims in-repo

Anything quoting these as **device** facts is OLD-argv-contaminated unless re-measured under NEW fingerprint:

| Claim class | Example locations | Status |
|-------------|-------------------|--------|
| Cluster A ≈ −314 / B ≈ −197, sep ≈ 117 ms | `docs/MILESTONE_AVSYNC_SEEK.md` cluster tables, hold A/B, MrAudio boundary “117 ms defect” | **RETRACT device cause.** Keep as historical OLD-argv observation only. |
| SESSION-LATCHED device defect (3-capture spread 3.33 ms) | same milestone SESSION-LATCHED section; instrument LIMITATIONS banner still saying DEVICE | **RETRACT device.** Within-session stability can still be true under a *broken* aligner if HDMI audio continuity is held fixed (parent Q4 confound). Do not cite as device proof. |
| Absolute medians −168, −196, −288, −318, … as lipsync | milestone first-light, H-DROP tables, HOLE1 “117 ms of adelay” framed against OLD HDMI | Absolutes always `raw_uncalibrated`; **OLD-era numbers must not be compared to NEW** (~−117 mean). ~90 ms step parent-noted. |
| “av_drift blind to 117 ms real offset” as proof of 117 ms device error | milestone av_drift section | **av_drift still is not lipsync** (servo/setpoint) — that source claim stands. The **117 ms external gap** it was compared to was instrument. Rephrase: blind to true HDMI offset differences *when those exist*; OLD gap was not device. |
| Hold/H-RING/H-DROP “not the 117 ms cause” | hold falsification tables | Still valid as **“does not track OLD-argv clusters”**; moot as device RCA. |
| FPGA path “vs 117 ms clusters” | `.agent-work/w-geom/fpga-av-path-117ms.md`, handoff P-RPTR 22483 B | Predictions targeted a **non-device** separation. Analyzer tools remain useful for residual; retarget to NEW 25 ms / quant floor. |

## Still valid (not OLD-cluster-dependent)

- Sign convention: `offset_ms = t_audio − t_video`; negative = audio LEADS (`tools/avsync_measure_hdmi.py`).
- Absolute median without known-zero cal = `raw_uncalibrated`.
- `av_drift_ms` is not a lip-sync meter (code: frameIndex vs audible clock / lead deadband).
- Host adelay authority proofs (unit tests) — filter path, not HDMI absolute.
- Soft-skip 77 ≠ pass; ERROR-17 DEFAULT_ASSUMED labelling.
- **NEW residual:** between-run range 25.00 ms ≤ frame quant T=33.00 ms; `flash_onset_n_interp=0/712` → instrument floor ~33 ms.

## Docs action

Milestone banner (this commit): retract device 117 ms; point at residual analyzer + floor statement.  
Do not mass-delete history; mark sections **HISTORICAL / OLD-argv**.
