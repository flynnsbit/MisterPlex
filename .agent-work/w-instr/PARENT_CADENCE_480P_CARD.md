# Parent card — 480p cadence / hitch (DEFECT 1–3 fixed)

**Branch:** `w-avsync-hdmi-measure`
**Agent does not touch the device.** Capture `true rc=$?` **directly**, never through a pipe.
`rc=77` / UNSCORED is **never** a pass. Never pool termination classes.

---

## DEFECT 1 — metric re-spec (binding)

| Field | Derivation (printed with name) | Role |
|-------|--------------------------------|------|
| **`p_one_refresh_hold`** | `round(publish_iv_ms / T_vsync) == 1` | **PRIMARY defect** — one-refresh hold hitch |
| `p_hold_d2` / `p_hold_d3` | same round(), bins 2 and 3 | OK for 24@60 |
| `p_hold_d_ge4` | round ≥ 4 | TOO_LONG |
| `cad_alt_frac` | frac consecutive (2,3) pairs that alternate | pattern regularity |
| `cadence_verdict` | HITCHY_D1 / CADENCE_32_CLEAN / … | pattern class |
| `p_delta1` / `p_d1` | `frac(Δframes_done == 1)` | **NOT** hold length |
| `p_ge50` | `frac(publish_iv_ms > 50)` | **FORENSIC ONLY** — not a defect score |
| `mean_ms` | mean(publish_iv_ms) | rate only; **≠ smooth cadence** |

**Your p_d1≈0.0335 hitch claim:** after this daemon, read **`PRIMARY p_one_refresh_hold=`**, not `p_d1`.
`p_d1` remains Δframes_done; alias line says `p_d1_der=delta_fd_eq1_NOT_one_refresh_hold`.

**Push-back retained:** perfect *display* 3:2 never sits on 41.667 as a single quantum — agree.
`ideal_ms=1000/src_fps` is mean **publish** target. A metronome publisher at 41.667 can still show `CADENCE_METRONOME_OK` while glass holds 2/3; that is **not** `CADENCE_32_CLEAN` (needs alternating ~33.3/50.0 publish iv).

---

## DEFECT 2 — measure refresh (not ESTIMATE)

```bash
fuser -v /dev/video0; echo "true rc=$?"

python3 tools/measure_refresh_hz.py --device /dev/video0 --frames 90 --warmup 15
echo "true rc=$?"
# MEASURED → refresh_hz=… tag=measured
# DEVICE_BUSY → rc=2 (never 0 Hz)
# empty → rc=77 NO_DATA (never zero)

export MISTERPLEX_VSYNC_HZ=<refresh_hz from tool>
export MISTERPLEX_SRC_FPS=24   # only if you measured/know asset rate
# restart daemon so play() reads env
```

Without env: `vsync_hz_tag=DEFAULT_ASSUMED` and
`phase_tag=ESTIMATE_OR_DEFAULT_vsync_hz_ALL_hold_d_CONDITIONAL`.
Offline: `--require-measured-vsync` → rc=77 until `--vsync-hz`.

---

## DEFECT 3 / ERROR 17 — no bare fps “measurement”

- Ledger: `src_fps=… src_fps_tag=…` + `ideal_ms_der=1000/src_fps`.
- `hdmi_motion_instrument.py`: default **24.0**; assert rejects 23.976 lookalike.
- Standing rule: every field name carries derivation in the same breath.

---

## Sigma gate (never pool)

| Session | sigma vs mean | p_ge50 |
|---------|---------------|--------|
| clean natural-EOF sigma=10.5 mean=41.7 | scoreable forensic | tag=measured |
| stop_or_seek sigma=65 > mean | **UNSCORED_SIGMA_GE_MEAN** | not a score |

```bash
python3 tools/publish_cadence_score.py daemon.log --phase session_end
echo "true rc=$?"
```

---

## PRE-REGISTER (before device run)

| Metric | Clean 24@60 | Hitchy (~user bug) | High-sigma |
|--------|-------------|--------------------|------------|
| p_one_refresh_hold | < 0.01 | ≥ 0.02 (~0.033 → ~1/s) | still report if hold_n≥50 |
| cadence_verdict | CADENCE_32_CLEAN or METRONOME_OK | **HITCHY_D1** | — |
| p_ge50 | forensic if sigma≪mean | forensic | **UNSCORED_SIGMA_GE_MEAN** |
| mean_ms ~ ideal | yes | **may still be yes** | misleading |

**Prediction (clean 30 s RK6-class, sigma=10.5):** PRIMARY = `p_one_refresh_hold`. User judder class → ≥0.02, `HITCHY_D1`, scorer rc=2.
`p_ge50~0.14` forensic only — **not** the hitch answer.

**Falsifier:** `p_one_refresh_hold < 0.01` and glass hold hist clean → hitch claim fails here.

---

## Host gates (agent-verified this commit)

```bash
./build/test_publish_swap_delta_ledger; echo "true rc=$?"   # 0
./build/test_publish_interval_ledger; echo "true rc=$?"     # 0
./build/test_cadence_swap_path; echo "true rc=$?"           # 0
python3 tools/publish_cadence_score.py --self-test; echo "true rc=$?"  # 0
python3 tools/measure_refresh_hz.py --self-test; echo "true rc=$?"     # 0
```

## Deploy daemon (parent)

```bash
make arm-plexd; echo "true rc=$?"
# deploy misterplexd only — core 78eff44e live; do not thrash RBF
```

## Device score after natural-EOF

```bash
grep -E 'publish_swap_delta |cadence_vsync|PRIMARY' misterplexd.log | tail -20
python3 tools/publish_cadence_score.py daemon.log --phase session_end \
  --vsync-hz "$MISTERPLEX_VSYNC_HZ"
echo "true rc=$?"
# HITCHY → 2; OK → 0; missing/sigma/vsync → 77
```
