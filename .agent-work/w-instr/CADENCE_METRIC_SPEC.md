# Cadence metric specification (w-instr) — parent re-task 2026-08-01

## Quoted implementation (ideal_ms / p_ge50)

`host/libmisterplex/publish_swap_delta_ledger.hpp`:

```
// ideal_ms = 1000/src_fps is the *mean publish* target
if (iv_ms > 50.0) ++ge50;
s.p_ge50 = double(ge50) / double(iv_n);
// T2: if sigma_ms >= mean_ms → p_ge50_tag=UNSCORED_SIGMA_GE_MEAN
hold_d = round(iv_ms / T_vsync);  // p_hold_d1/d2/d3/d_ge4
```

Legacy names `p_d0/p_d1/p_dge2` = **Δframes_done** fractions (alias line says so).

## Push-back on parent analysis

| Claim | Verdict | Why |
|-------|---------|-----|
| ideal 41.667 never a single 60 Hz quantum | **Agree** for *display* holds | Display holds are k×16.667 ms |
| perfect 3:2 ⇒ ~50% publish iv at 50 ms ⇒ p_ge50 high | **Disagree** | Publish can be metronome 41.67 while *async* display does 2,3,2,3. p_ge50 measures publish iv>50, not “3-hold fraction” |
| p_d1=3.4% means 1-refresh holds | **Disagree as stated** | `p_delta1` is Δfd==1. Hitch metric is **`p_hold_d1`**. On vsync-packed RBF Δfd≈hold; on swap-counter RBF it does not |
| mean≈ideal while judder | **Agree** | Instrument emits `mean_vs_cadence_note` and scores hold_d |
| skip=NO_ZERO + p_d1=0.03 | **Inconsistent with tip** | skip requires p_delta1≥0.5; re-check log vs binary |

## Cadence verdicts

| verdict | meaning |
|---------|---------|
| HITCHY_D1 | p_hold_d1≥0.02 — user-visible hitch class |
| CADENCE_32_CLEAN | alt 2,3 with high cad_alt_frac |
| CADENCE_METRONOME_OK | mean~ideal, low sigma, no d1 — steady publish (not display 3:2 proof) |
| CADENCE_IRREGULAR | 2/3 mix, low alternation, sigma elevated |
| UNSCORED_SIGMA_GE_MEAN | p_ge50 not a score |

## Gates (true rc)

```
./build/test_publish_swap_delta_ledger; echo "true rc=$?"   # 0
python3 tools/publish_cadence_score.py --self-test; echo "true rc=$?"  # 0
```

