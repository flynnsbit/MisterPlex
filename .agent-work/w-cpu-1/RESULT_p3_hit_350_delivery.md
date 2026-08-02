# P3 HIT follow-up — 624x350 delivery vs collapse (w-cpu)

## Parent P3 result (accepted)
| clip | source | vfps | pfps | drops | drift |
|---|---|---|---|---|---|
| rk=27 FullBleed | 624x480 == bank | 23.8 | 23.7 | 7 FLAT | −36 healthy |
| rk=9 BBB | 624x352 lib / **350 measured** | ~13 | ~8 | climbing | +positive |

Falsified: content complexity; "any arm_rescale=1 fatal" (rk=27 also scale_pad).

## Q1 — non-MB height vs reader bytes (SOURCE)
`host/libmisterplex/ffmpeg_vf.hpp` FORCE_SCALE Always + short src:
- `scale=618:480:FOAR=decrease` then `pad=624:480`
- Output pins **624×480**; `yuv420pFrameBytesWH(624,480)=449280`
- FOAR model (same file): h=350→out_h **346**; h=352→**348**; h=480→**475**
- `350%16=14` not MB-aligned; `352%16=0` is. Still even → valid I420 bytes `yuv420pFrameBytesWH(624,350)=327600`
- `pipeDesyncRisk`: true only if `identity_skip && sizes differ` → scale path **desync_risk=0 expected** even with 350 input
- Gate: `tests/unit/test_ffmpeg_vf.cpp` GREEN_OUTPUT_PIN + FOAR heights

**desync_risk on rk=9:** unknown on device until parent greps; host expects 0 on scale_pad path.

## Q2 — 350 ↔ collapse correlation
Tool: `tools/correlate_delivery_height_collapse.sh` (busybox).
PRE_REG: short {350,352} → COLLAPSE; 480 → HEALTHY. Host synthetic HIT+MISS gates green.
Parent must run on live log for device RESULT.

## Q3 — scale cost (HOST only — PRE_REG MISS)
Host sws microbench (not device): 350 FOAR ~1.28× crop, **not** 2× cliff.
480 FOAR can be **heavier** than 350 FOAR → **do not claim sws cost as collapse root**.
Device PRESENT_PROFILE still open.

## Parent commands (copy these paths)
Worktree tools root:
`/home/flynnsbit/Projects/MisterPlex/.worktrees/w-cpu-fps-measure/tools/`

**Order:**
1. Correlate retained log (no restart):
```sh
WT=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-cpu-fps-measure
L=/media/fat/misterplex_v2/misterplexd.log
sh "$WT/tools/correlate_delivery_height_collapse.sh" "$L"; echo "true rc=$?"
```
2. Live rk=9 collapse — budget + pipe (no PRESENT_PROFILE restart):
```sh
WT=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-cpu-fps-measure
L=/media/fat/misterplex_v2/misterplexd.log
sh "$WT/tools/present_loop_budget_from_log.sh" "$L"; echo "true rc=$?"
WINDOWS=10 WINDOW_S=2 sh "$WT/tools/pipe_backpressure_sample.sh"; echo "true rc=$?"
```
3. Prove OUTPUT size on rk=9:
```sh
grep -E 'MEASURED_OUTPUT|measured_delivery=|desync_risk=|GEOM ' /media/fat/misterplex_v2/misterplexd.log | tail -40; echo "true rc=$?"
```
4. Optional PRESENT_PROFILE=1 — **needs conf edit + daemon restart** (startup-only). Do not enable unless (1–3) leave mechanism open.

## PRE_REG outcomes
| id | predict | hit/miss |
|---|---|---|
| P3 geom | rk=27 healthy | **HIT** (parent glass) |
| Q3 host sws | 350 FOAR ≥2× crop | **MISS** (~1.28×; 480 FOAR can exceed) |
| Q2 log | all 350 collapse, all 480 healthy | pending parent |
