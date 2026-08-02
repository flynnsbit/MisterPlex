# PARENT CARD — JOB1 provenance (ERROR 17) + JOB2 B7 colour

Branch: `w-instr-provenance`
SHA: 20254b4fea346c8aaad9de4119a4b0420ec83cb8

## JOB 1 — provenance labelling (ERROR 17 permanent fix)

### Guarantees
- Default `src_fps=24.000` **never** 23.976 (assert + FORBIDDEN_FPS_LOOKALIKES).
- Every printed rate field is tagged: `measured` | `caller_supplied` | `caller_supplied_measured` | `DEFAULT_ASSUMED`.
- Ratio/endpoint/plateau gates **only** when `fps_authoritative=1` (both sides caller/measured/container).
- Assumed fps → `rate=RATE_UNSCORED`, `expected=[UNSCORED_fps_not_authoritative]`.
- VERDICT line always includes `rate=… src_fps=…[tag] cap_fps=…[tag] fps_authoritative=0|1`.
- `ERROR17_GUARD rate_not_authoritative` vs `rate_authoritative` — never the old unconditional note that fired even on measured runs (that was itself an ERROR 17 footgun).
- `--strict-fps` → `REFUSE_DEFAULT_ASSUMED rc=77` when fps assumed; hard fails never decay to 77.

### RBG (direct rc) — unstated vs measured is unmistakable
Synthetic healthy counters (same sequence):

| mode | rate | fps_authoritative | VERDICT line distinctive tags | rc |
|------|------|-------------------|-------------------------------|-----|
| unstated defaults | RATE_UNSCORED | 0 | `src_fps=24 [DEFAULT_ASSUMED]` + `ERROR17_GUARD rate_not_authoritative` + `rate_NOT_AUTHORITATIVE_do_not_cite_as_measured` | 0 motion-only |
| supplied measured | RATE_OK | 1 | `src_fps=24 [caller_supplied_measured] cap_fps=30 [measured]` + `ERROR17_GUARD rate_authoritative` + `rate_AUTHORITATIVE` | 0 |
| assumed + `--strict-fps` | RATE_UNSCORED | 0 | `REFUSE_DEFAULT_ASSUMED` | **77** |

```bash
# assumed (do NOT treat as rate-validated)
python3 tools/hdmi_motion_instrument.py --counters-csv PATH
# measured
python3 tools/hdmi_motion_instrument.py --counters-csv PATH \
  --source-fps 24.0 --source-fps-src caller_supplied_measured \
  --capture-fps 30.0 --capture-fps-src measured
# refuse if assumed
python3 tools/hdmi_motion_instrument.py DIR --strict-fps
```

Artifacts: `.agent-work/w-instr/job12_rbg/synth_assumed.txt` vs `synth_measured.txt`.

## JOB 2 — B7 colour hole closed (not green-only)

| class | label | evidence | true rc |
|-------|-------|----------|---------|
| green cast | GREEN (+CHROMA) | `files/device-evidence/le3_c5382bee_broken.png` | **2** COLOR_FAIL |
| magenta | MAGENTA | cap480a f018–021 | **3** STRUCTURE_FAIL (structure wins; color still MAGENTA) |
| greyscale | GREYSCALE | synthetic self-test + cap480a full count | COLOR_FAIL |
| blue | BLUE | synthetic self-test | COLOR_FAIL |
| UV swap | UV_SWAP | synthetic self-test | COLOR_FAIL |
| good control | COLOR_OK | `DDR_PLAYBACK_CORRECT_…png` | **77** UNSCORED (no counter; not a pass) |
| clean idle | COLOR_OK | `plxd_fix_c5382bee_CLEAN_idle.png` | **77** UNSCORED (correct — no counter) |
| good burst | COLOR_OK | `/tmp/cap480b` | **0** MOTION_OK |

Single archive frames score via `score_burst` (`color_need=min(3,n)`). `--one` still dumps per-frame.

```bash
python3 tools/hdmi_motion_instrument.py files/device-evidence/le3_c5382bee_broken.png --warmup-skip 0 --min-reads 1
echo "true rc=$?"   # 2
python3 tools/hdmi_motion_instrument.py files/device-evidence/plxd_fix_c5382bee_CLEAN_idle.png --warmup-skip 0 --min-reads 1
echo "true rc=$?"   # 77 COLOR_OK
python3 tools/hdmi_motion_instrument.py --self-test; echo "true rc=$?"  # 0
```

## Standing constraints preserved
- rc=77 never a pass (idle/clean controls stay 77).
- Warmup + uniform frames discarded.
- md5/luma not used as health.
- Fail never decays to 77.
