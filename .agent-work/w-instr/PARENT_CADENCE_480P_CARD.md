# Parent card — 480p cadence / hitch (publish_swap_delta)

**Agent does not touch the device.** Capture `true rc=$?` **directly**.

## Analysis push-back (read first)

Quoted from `host/libmisterplex/publish_swap_delta_ledger.hpp`:

1. **`ideal_ms = 1000/src_fps` (default 41.667)** is the **mean publish** target, not a display quantum. On 60 Hz, *display* holds are multiples of ~16.667 ms (2 or 3 for 24@60). Your analysis that a perfect 3:2 never lands on 41.667 as a *single interval* is **correct for display holds**.

2. **`p_ge50` is `count(iv_ms > 50) / n` on publish intervals** — it is **not** “fraction of legitimate 3-refresh holds”. A clean ARM publisher can sit near 41.667 with low sigma while the **async** display path still does 2,3,2,3. Penalising 50 ms publish gaps is about **ARM lateness**, not scoring 3:2. **Partially agree:** `p_ge50` is a bad *judder* metric; **disagree** that perfect 3:2 would put ~50% of *publish* intervals at 50 ms (publish can be steady 41.7 while display holds alternate).

3. **`p_d1` / `p_delta1` = fraction of pairs with Δframes_done==1**, not “held one refresh”. Alias line now states this. Hitch metric is **`p_hold_d1`** = `round(iv_ms/T_vsync)==1`.

4. Your session with `p_d1≈0.03`, `p_dge2≈0.96`, and `skip_verdict=NO_ZERO_REFRESH_SKIP` is **inconsistent with tip code** (skip requires `p_delta1>=0.5`). Either log was paraphrased or an older binary. After this deploy, expect `fd_semantics` + `skip_verdict=UNSCORED` when `p_delta1<0.5`.

5. **`mean_ms≈ideal` while judder exists** — **agree**. Instrument now emits `mean_vs_cadence_note=...` and scores **hold_d + cad_alt_frac**.

6. **`phase_tag` / `vsync_tag=DEFAULT_ASSUMED` (60 Hz)** — all hold_d depend on it. Measure via glass 60 fps capture pts modal Δ, or lab meter; then we can add `setVsyncHzMeasured` from conf/env later. Check: modal of HDMI pts intervals at 60-cap should be ~16.67 ms.

## PRE-REGISTER (before you run)

| Metric | Clean 24@60 | Hitchy (user bug class) | High-sigma session |
|--------|-------------|-------------------------|---------------------|
| p_hold_d1 | < 0.01 | ≥ 0.02 (~1/s if ~0.03) | ignore cadence if n low |
| cad_alt_frac | ≥ 0.85 | any | — |
| cadence_verdict | CADENCE_32_CLEAN | HITCHY_D1 | — |
| p_ge50 | scoreable only if sigma < mean | scoreable if sigma < mean | **UNSCORED_SIGMA_GE_MEAN** |
| mean_ms | ~41.67 | may still be ~41.67 | misleading |
| frames/presents/drops | close | close | — |

**Prediction for your clean 30 s RK6-class session (sigma=10.5 < mean):**  
`p_ge50` remains scoreable (~0.14 → ARM_LATE_OR_BIMODAL) **and** `p_hold_d1` is the hitch metric to watch. If user judder is 1-refresh holds, expect `cadence_verdict=HITCHY_D1`.

**Prediction for stop_or_seek (sigma=65 > mean):**  
`interval_verdict=UNSCORED_SIGMA_GE_MEAN`, `p_ge50_scoreable=0` — do not publish 14.8% as a score.

## Deploy (host)

```bash
cd /path/to/MisterPlex
make -j"$(nproc)" build/test_publish_swap_delta_ledger
./build/test_publish_swap_delta_ledger; echo "true rc=$?"
# expect OK, rc=0

make arm-plexd; echo "true rc=$?"
# deploy daemon only (parent): scripts/deploy_misterplexd.sh
# core 78eff44e already live — do not thrash RBF
```

## Device run (short RK6 ~30 s OK; long fixture later)

```bash
# natural EOF one play of 480p 24fps asset; do NOT pool with seek/stop session
# pull log after session_end
grep publish_swap_delta /path/to/misterplexd.log | tail -5
```

Host score:

```bash
python3 tools/publish_cadence_score.py daemon.log; echo "true rc=$?"
# HITCHY_D1 → 2; CLEAN → 0; sigma gate → 77
```

Glass cross-check (primary display hold, independent of ARM):

```bash
# 720p60 capture of same play if overlay counter present
python3 tools/glass_hold_skip.py CAP --templates T.pkl --pts pts.csv \
  --source-fps 24 --capture-fps 60 --refresh-hz 60 --force-mode 720
echo "true rc=$?"
```

## Measure vsync (optional, upgrades DEFAULT_ASSUMED)

```bash
# 60 fps grabber burst; modal pts Δ → measured refresh
ffprobe -v error -select_streams v -show_entries frame=pts_time -of csv=p=0 cap.mkv
# parent computes modal Δ; if ~0.01667 report measured_hz=1/modal
```

## Do not pool sessions

Clean natural-EOF and stop_or_seek are separate artifacts. High-sigma never updates a p_ge50 claim.

