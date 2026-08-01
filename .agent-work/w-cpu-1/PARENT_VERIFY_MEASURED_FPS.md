# Parent verify — MEASURED_FPS + supply_gap refuse (w-cpu)

Deploy daemon from branch `w-cpu-fps-measure` (arm build). Cast known-rate asset.

## Expect (24.000 PMS asset, after banner)

```
media: MEASURED_FPS fps=24/1 src=ffmpeg_banner token=fps tag=measured
media: supply_bucket ... fps=24/1 fps_src=measured gap_score=scored ...
```

Not: `fps_src=caller_supplied` beside `tag=measured` with silent gap vs 24 when banner differs.

## Expect (if force unknown fps / no setContentFps before banner)

Until MEASURED_FPS: `supply_gap=NO-DATA gap_score=refused_assumed_unverified fps_src=DEFAULT_ASSUMED`

## 30 fps decisive (margin + fps force)

Cast a genuine 30 fps (or 25) library item. Capture 5× supply_bucket + MEASURED_FPS + vf line.

Pre-register:
- MEASURED_FPS shows 30/1 (or 30000/1001)
- If caller still 24: FPS_MISMATCH + gap_score=refused_caller_vs_measured
- d_frames ~30/s if vf does not decimate; if vf still `fps=24/1`, d_frames~24 and judder risk

```bash
# after deploy + cast, on device (parent):
log=/media/fat/misterplex/misterplexd.log   # or actual path
grep -E 'MEASURED_FPS|FPS_MISMATCH|supply_bucket|content fps' "$log" | tail -40
echo "true rc=$?"
```
