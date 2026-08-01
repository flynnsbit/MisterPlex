# Cadence metric specification (w-instr) — DEFECT 1–3

## PRIMARY defect (replaces p_ge50 as hitch score)

```
p_one_refresh_hold = hold_d1 / hold_n
hold_d = round(publish_iv_ms / T_vsync)
p_one_refresh_hold_der = round(publish_iv_ms/T_vsync)==1
```

At 24 fps on 60 Hz, d=1 is unambiguously wrong (expected 2 or 3).

## p_ge50 — forensic only

```
if (iv_ms > 50.0) ++ge50;
s.p_ge50 = ge50 / iv_n;
// scoreable only if sigma_ms < mean_ms; else UNSCORED_SIGMA_GE_MEAN
// role: ARM lateness forensics — NOT judder / NOT 3-refresh hold fraction
```

`ideal_ms = 1000/src_fps` is mean publish target, not a 60 Hz quantum.

## Δframes_done vs hold (do not conflate)

| Name | Derivation |
|------|------------|
| p_delta0 / p_d0 | frac(Δframes_done==0) |
| p_delta1 / p_d1 | frac(Δframes_done==1) — **NOT** one-refresh hold |
| p_one_refresh_hold / p_d1_hold | round(iv/T)==1 |

## Vsync provenance (DEFECT 2)

- Default: `vsync_tag=DEFAULT_ASSUMED` 60 Hz → all hold_d **CONDITIONAL**
- Measured: `tools/measure_refresh_hz.py` → `MISTERPLEX_VSYNC_HZ` → `setVsyncHzMeasured`
- phase_tag when not measured: `ESTIMATE_OR_DEFAULT_vsync_hz_ALL_hold_d_CONDITIONAL`

## Cadence verdicts

| verdict | meaning |
|---------|---------|
| HITCHY_D1 | p_one_refresh_hold ≥ 0.02 |
| CADENCE_32_CLEAN | alt 2,3 high cad_alt_frac |
| CADENCE_METRONOME_OK | mean~ideal, low d1 — steady publish ≠ display 3:2 proof |
| CADENCE_IRREGULAR | 2/3 mix, low alternation |
| UNSCORED_SIGMA_GE_MEAN | p_ge50 not a score |

## ERROR 17

Never emit bare 23.976 as a measurement. Tags: measured | caller_supplied | DEFAULT_ASSUMED.

## Gates

```
./build/test_publish_swap_delta_ledger; echo "true rc=$?"
python3 tools/publish_cadence_score.py --self-test; echo "true rc=$?"
python3 tools/measure_refresh_hz.py --self-test; echo "true rc=$?"
```
