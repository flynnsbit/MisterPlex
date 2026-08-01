# w-instr report — cadence DEFECT 1–3 (2026-08-01)

**Branch:** `w-avsync-hdmi-measure`  
**SHA:** `59e78748`  
**Device:** not touched (parent owns hardware)

## Fixes

1. **PRIMARY = `p_one_refresh_hold`** = `round(publish_iv_ms/T_vsync)==1`  
   - `p_ge50` demoted: `p_ge50_der=…_FORENSIC_NOT_DEFECT`  
   - `p_d1` / `p_delta1` = Δframes_done only; alias `NOT_one_refresh_hold`
2. **Measured vsync:** `tools/measure_refresh_hz.py` + `MISTERPLEX_VSYNC_HZ` → daemon `setVsyncHzMeasured`  
   - default loud: `phase_tag=ESTIMATE_OR_DEFAULT_vsync_hz_ALL_hold_d_CONDITIONAL`
3. **ERROR 17:** no bare 23.976; every fps field tagged; motion instrument assert
4. **Sigma gate** on cadence **and** p_ge50 when `sigma_ms >= mean_ms` → `UNSCORED_SIGMA_GE_MEAN`  
5. **No session pool:** scorer `--phase session_end|mid|stop_or_seek`

## Host evidence (true rc direct)

| Command | true rc |
|---------|---------|
| `./build/test_publish_swap_delta_ledger` | 0 |
| `./build/test_publish_interval_ledger` | 0 |
| `./build/test_cadence_swap_path` | 0 |
| `python3 tools/publish_cadence_score.py --self-test` | 0 |
| `python3 tools/measure_refresh_hz.py --self-test` | 0 |
| fixture clean hitch p_one=0.0335 | **2** HITCHY |
| fixture sigma>=mean | **77** UNSCORED |

## Parent commands

See `.agent-work/w-instr/PARENT_CADENCE_480P_CARD.md`

```bash
make arm-plexd; echo "true rc=$?"
# measure refresh, set env, deploy daemon only
python3 tools/measure_refresh_hz.py --device /dev/video0 --frames 90 --warmup 15; echo "true rc=$?"
export MISTERPLEX_VSYNC_HZ=<hz>
# natural-EOF 480p play → pull log
python3 tools/publish_cadence_score.py daemon.log --phase session_end --vsync-hz "$MISTERPLEX_VSYNC_HZ"
echo "true rc=$?"
```

## Push-back (cited)

- Agree: display holds are k×16.67 ms; 41.667 is not a quantum.  
- Disagree: `p_d1` in old logs is Δfd not hold — use `PRIMARY p_one_refresh_hold` after deploy.  
- Agree: mean≈ideal can coexist with judder — instrument prints `mean_vs_cadence_note`.
