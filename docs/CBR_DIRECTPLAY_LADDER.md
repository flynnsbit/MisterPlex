# CBR Direct-Play ladder (path ceiling dose-response)

**Path (parent greedy-pull, playback stopped):** goodput **1.153 Mbit/s**
sustained 60 s; capacity p95 1.292 Mbit/s. Prior ~670 kbit figure was the
**pacer**, not the link — retracted for sizing.

**Design:** identical content; CBR-only axis; sources already satisfy
`plex_resolve` h264/baseline/level≤3.0/aac so **Part Direct-Play is eligible**.
DP is **not automatic**: default STREAM=0 always universal (`transcoded=1`).
Set **`PREFER_DIRECT_H264=1`** (or STREAM=1) on deployed daemon — see
`docs/CBR_DP_DIRECTPLAY_PROOF.md`. Parent must quote `transcode=0` or **VOID**.

**Status note (parent 2026-08-02):** AdvReal transcoded sweep showed **no stable
bitrate knee** (intermittent). Link hypothesis not confirmed under universal;
re-run only under verified DP.

## supply_ratio (what to record)

```
supply_ratio = audio_s / wall_s
audio_s = audioBytes / (48000 * 4)   // media_player.cpp PCM seconds
wall_s  = wall_ms / 1000.0
```
Primary per-rung metric. 120 s playback enough.

## Parent pre-registration (on record before device)

| rung v | expected supply_ratio |
|-------:|----------------------|
| 400k | ≥ 0.95 |
| 800k | ≥ 0.95 |
| **1200k** | **0.90–1.00 knee** |
| 1600k | ≈ 0.72 |
| 2000k | ≈ 0.58 |

All five ≥ 0.95 ⇒ bitrate/VBR account **dead** (publish miss).

## Measured clips

| title | W×H | fps | tgt_v | meas_v | total_k | refs | CB/L/B | aac | bank | prereg_sr | spec |
|-------|-----|-----|------:|-------:|--------:|-----:|--------|-----|------|-----------|------|
| `MiSTerPlex CBR-DP 624x480 24fps 400kbit 180s (2026).mp4` | **624×480** | **24/1** | 400 | **400.4** | **532.4** | **1** | Constrained Baseline/L30/B0 | 128k/2ch | favourable | ≥ 0.95 | YES |
| `MiSTerPlex CBR-DP 624x480 24fps 800kbit 180s (2026).mp4` | **624×480** | **24/1** | 800 | **800.8** | **932.7** | **1** | Constrained Baseline/L30/B0 | 128k/2ch | favourable | ≥ 0.95 | YES |
| `MiSTerPlex CBR-DP 624x480 24fps 1200kbit 180s (2026).mp4` | **624×480** | **24/1** | 1200 | **1201.1** | **1333.0** | **1** | Constrained Baseline/L30/B0 | 128k/2ch | favourable | 0.90–1.00 knee | YES |
| `MiSTerPlex CBR-DP 624x480 24fps 1600kbit 180s (2026).mp4` | **624×480** | **24/1** | 1600 | **1603.2** | **1735.1** | **1** | Constrained Baseline/L30/B0 | 128k/2ch | favourable | ≈ 0.72 | YES |
| `MiSTerPlex CBR-DP 624x480 24fps 2000kbit 180s (2026).mp4` | **624×480** | **24/1** | 2000 | **2005.3** | **2137.2** | **1** | Constrained Baseline/L30/B0 | 128k/2ch | favourable | ≈ 0.58 | YES |
| `MiSTerPlex CBR-DP 640x480 24fps 1200kbit 180s (2026).mp4` | **640×480** | **24/1** | 1200 | **1201.2** | **1333.2** | **1** | Constrained Baseline/L30/B0 | 128k/2ch | adversarial | 0.90–1.00 knee | YES |

## PMS ingest

```bash
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
    if 'CBR-DP' in t or 'CBR DP' in t:
        print(f"rk={v.get('ratingKey')} dur_ms={v.get('duration')} frameRate={v.get('frameRate')} | {t}")
PY
```

Quote PMS `frameRate` when present; asset truth is ffprobe **24/1**.
Direct-play verification is **parent-only** (device GEOM `transcoded=0`).

## Second deliverable (already shipped)

Within-session VBR staircase: `docs/VBR_MOTION_STAIRCASE.md` (rk≈101–104).

```bash
python3 scripts/gen_cbr_directplay_ladder.py --duration 180 --copy-media
```

