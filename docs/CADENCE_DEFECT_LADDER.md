# Cadence / judder defect ladder (w-instr ground truth)

**Symptom channel:** presentation-interval judder (holds / IFI), **not** lipsync.
Lipsync fixtures are blind to constant-offset irregular cadence.

**Design duration:** 300 s @ **24/1** (control). drop_K shortens by K/24 s.

## Per-frame identity (no enable= guard)

- Glass ID `G n=DDDDDD c=C` + Grey bars every frame (`draw_id_band`)
- Moving yellow block + 12-bit tick row + checker (MAD-distinct neighbours)
- Black-lift ≥ 48 — not ERROR 13 black; not ERROR 8 noise-only motion

## Anti-beat

Content identity period = **1/24 s**. No independent marker period.
24.000:30.000 = **4:5** commensurate → healthy capture holds **{1,2}** 
(w-instr `glass_motion_beat_ifi`). Injected **dups** add long-hold / ~83 ms IFI mass.

## Measured ladder

| media | tier | mode | n_dups (GT) | n_drops (GT) | measured WxH | rate | nb_frames | dur_s | CB/B/aac | spec |
|-------|------|------|------------:|-------------:|--------------|------|----------:|------:|----------|------|
| `MiSTerPlex Cadence 624x480 24fps control_d0 300s (2026).mp4` | bank480 | control_d0 | **0** | **0** | **624×480** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 624x480 24fps dup1 300s (2026).mp4` | bank480 | dup1 | **1** | **0** | **624×480** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 624x480 24fps dup5 300s (2026).mp4` | bank480 | dup5 | **5** | **0** | **624×480** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 624x480 24fps dup20 300s (2026).mp4` | bank480 | dup20 | **20** | **0** | **624×480** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 624x480 24fps drop1 300s (2026).mp4` | bank480 | drop1 | **0** | **1** | **624×480** | **24/1** | 7199 | 299.958333 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 624x480 24fps drop5 300s (2026).mp4` | bank480 | drop5 | **0** | **5** | **624×480** | **24/1** | 7195 | 299.791667 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 624x480 24fps drop20 299s (2026).mp4` | bank480 | drop20 | **0** | **20** | **624×480** | **24/1** | 7180 | 299.166667 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 624x480 24fps periodic_hold_every24 300s (2026).mp4` | bank480 | periodic_hold_every24 | **299** | **0** | **624×480** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 320x240 24fps control_d0 300s (2026).mp4` | p240 | control_d0 | **0** | **0** | **320×240** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 320x240 24fps dup1 300s (2026).mp4` | p240 | dup1 | **1** | **0** | **320×240** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 320x240 24fps dup5 300s (2026).mp4` | p240 | dup5 | **5** | **0** | **320×240** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 320x240 24fps dup20 300s (2026).mp4` | p240 | dup20 | **20** | **0** | **320×240** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 320x240 24fps drop1 300s (2026).mp4` | p240 | drop1 | **0** | **1** | **320×240** | **24/1** | 7199 | 299.958333 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 320x240 24fps drop5 300s (2026).mp4` | p240 | drop5 | **0** | **5** | **320×240** | **24/1** | 7195 | 299.791667 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 320x240 24fps drop20 299s (2026).mp4` | p240 | drop20 | **0** | **20** | **320×240** | **24/1** | 7180 | 299.166667 | Constrained Baseline/b=0/aac | YES |
| `MiSTerPlex Cadence 320x240 24fps periodic_hold_every24 300s (2026).mp4` | p240 | periodic_hold_every24 | **299** | **0** | **320×240** | **24/1** | 7200 | 300.000000 | Constrained Baseline/b=0/aac | YES |

## Ground-truth semantics

| mode | what is injected | w-instr expectation |
|------|------------------|---------------------|
| control d0 | nothing | healthy hold mass only |
| dup_K | K single-frame holds at recorded slots | recover **K** extra long holds / elevated ≥83 ms IFI |
| drop_K | K omitted source indices (shorter file) | n_frames=N-K; id jumps; MAD still steps each frame |
| periodic_hold_every24 | hold on every 24th slot | n_dups≈duration; strong bimodal IFI |

**Red-before-green:** score `dup20` or `periodic_hold_every24` **before** control. An instrument that never detects known-N cannot report absence on device.

## Host instrument floor (non-device)

Directory from `--host-floor-dir` (default agent emit):
`.agent-work/cadence-floor/cadence_24.000_control_300s.mp4`

See `README_PARENT_FLOOR.txt` there for mpv + ffmpeg capture commands.

## PMS ingest (parent — section 2 only)

```bash
ls -1 ~/plex/media/movies/MiSTerPlex\ Cadence*
curl -sS -o /dev/null -w 'refresh_http=%{http_code}\n' \
  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
echo "refresh true rc=$?"
curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" -o /tmp/pms_s2.xml
echo "all true rc=$?"
python3 - <<'PY'
import xml.etree.ElementTree as ET
root=ET.parse('/tmp/pms_s2.xml').getroot()
for v in sorted(root.findall('.//Video'), key=lambda e:int(e.get('ratingKey',0))):
    t=v.get('title') or ''
    if 'Cadence' in t:
        print(f"rk={v.get('ratingKey')} dur_ms={v.get('duration')} | {t}")
PY
```

ratingKeys: **after your refresh only**. Prefer Direct Play.
PMS geometry tags are claims — trust ffprobe / this table.

## Reproduce

```bash
python3 scripts/gen_cadence_defect_ladder.py --duration 300 --copy-media \
  --host-floor-dir .agent-work/cadence-floor
```

Generator: `scripts/gen_cadence_defect_ladder.py`  
Consumer: `tools/glass_motion_judder.py` (w-instr)  
Probe JSON: `docs/cadence_defect_ladder_probe.json`
