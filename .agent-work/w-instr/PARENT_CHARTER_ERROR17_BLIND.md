# w-instr — charter response (ERROR 17 + blind-counter + B7)

Branch: `w-instr-provenance`  
Do not touch device. true rc captured directly.

## Already verified (kept, no regression)

| check | evidence |
|---|---|
| Severity ladder STRUCTURE 3 > COLOR 2 > FREEZE 1 > OK 0 > UNSCORED 77 | cap480a STRUCTURE_FAIL rc=3; measured fail never→77 |
| Rate + revisit | cap480b unique_ratio=0.8209 revisits=0 RATE_OK when fps authoritative |
| Warm-up discard | warmup_skipped=14 on 90-frame bursts |
| Low-contrast counter refuse | f_049 dY=17.0 → UNREADABLE; real overlay TREK24 n=312 (parent-viewed) |

## ERROR 17 — provenance labelling

Every emitted load-bearing value uses `value [tag]`:
- `measured` | `caller_supplied` | `caller_supplied_measured` | `DEFAULT_ASSUMED`
- `src_fps=24 [DEFAULT_ASSUMED]` when CLI omits fps → **rate=RATE_UNSCORED**, not RATE_OK
- `src_fps=24 [caller_supplied_measured]` with `--source-fps-src caller_supplied_measured`
- Default is **24.0**, never 23.976 (assert + FORBIDDEN_FPS_LOOKALIKES)

```
python3 tools/hdmi_motion_instrument.py /tmp/cap480b --warmup-skip 15
→ rate=RATE_UNSCORED src_fps=24 [DEFAULT_ASSUMED] fps_authoritative=0 VERDICT=MOTION_OK rc=0
```

## Blind-counter rule (rchar incident generalised)

`tools/instrument_blind_counter.py`:
- flat primary + secondary work (e.g. wchar) + process alive → **NO-DATA rc=77**, never DEFECT
- void stub `tools/pms_arrival_rate_sample.sh` exits 77 (rchar path banned)
- self-test: rchar=0/wchar advancing → NO-DATA; scorable low → DEFECT allowed

```
python3 tools/instrument_blind_counter.py --self-test; echo "true rc=$?"  # 0
sh tools/pms_arrival_rate_sample.sh; echo "true rc=$?"                 # 77
```

## B7 colour (not green-only)

`green_cast_metrics`: green + chroma spread (magenta/blue) + greyscale/chroma-constant + UV_SWAP.
cap480a: `color=GREEN+CHROMA+GREYSCALE_CAST_FAIL` under STRUCTURE_FAIL rc=3.

## Red-before-green (this charter run)

```
cap480b → VERDICT=MOTION_OK rc=0  revisits=0  unreadable_frac=0.1184 [measured]
cap480a → VERDICT=STRUCTURE_FAIL rc=3  vdup=15 wrap=8
--self-test → SELF_TEST_OK rc=0
```

## Commands

```bash
cd .worktrees/w-instr-provenance
python3 tools/hdmi_motion_instrument.py /tmp/cap480b --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured; echo "true rc=$?"
python3 tools/hdmi_motion_instrument.py /tmp/cap480a --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured; echo "true rc=$?"
python3 tools/hdmi_motion_instrument.py --self-test; echo "true rc=$?"
python3 tools/instrument_blind_counter.py --self-test; echo "true rc=$?"
```

## w-asset480 note

Counter outline/solid box on black+white still requested so flash frames stay OCR-able at source; instrument handles existing fixtures via low-contrast refuse.
