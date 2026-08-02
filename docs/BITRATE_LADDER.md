# Bitrate / refFrames / geometry ladder (link ceiling)

**Purpose:** isolate the variables confounded in rk=9 vs rk=27 so the
parent can measure the MiSTer link ceiling as a **curve**.

Parent measured link (direct download, no transcode): **1.56 Mbit/s**.

## PRE-REGISTER (before device measure)

| claim | prediction |
|-------|------------|
| collapse threshold (video kbit/s) | **between 1400 and 1800** |
| rationale | link 1560 kbit/s − audio≈48 − mux ≈ **~1450–1500** video headroom |
| shape | **sharp cliff** once sustained demand > link (buffer underrun), not smooth A/V drift |
| 400/700/1000 | healthy (desync_risk=0, glass n advances) |
| 1400 | edge / intermittent |
| 1800+ | collapse (stalls / drops / freeze-looking holds) |
| ref1 vs ref3 @ 700 | **no** material difference if bitrate is the cause |
| 624x480 vs 624x352 @ 700 | **no** material difference if bitrate is the cause |

Publish miss if wrong — valued here.

## Fixed axes (all clips unless noted)

- fps **24/1** (not 24000/1001) — measured per row
- H.264 **Constrained Baseline**, **level 3.0**, **B=0**
- AAC **48 kHz**, **48 kbit/s** mono (pinned; not an axis)
- Duration **≥ 600 s**
- Glass ID every frame: `G n=DDDDDD c=C` + Grey bars (`draw_id_band`, no enable=)
- Full-bleed moving body (not mean-luma-black)
- Encode: CBR-ish `-b:v=maxrate`, `bufsize=2×`

## Measured table

| file | axis | W×H | fps | target_v | meas_v_k | meas_total_k | refs SPS | profile/level | B | aac_k | nb | dur | spec |
|------|------|-----|-----|---------:|---------:|-------------:|---------:|---------------|---|------:|---:|----:|------|
| `MiSTerPlex BitrateLadder 624x480 24fps 400kbit ref1 600s (2026).mp4` | bitrate_sweep_400 | **624×480** | **24/1** | 400 | **400.0** | **452.5** | **1** | Constrained Baseline/L30 | 0 | 48.4 | 14400 | 600.000000 | YES |
| `MiSTerPlex BitrateLadder 624x480 24fps 700kbit ref1 600s (2026).mp4` | bitrate_sweep_700 | **624×480** | **24/1** | 700 | **699.7** | **752.1** | **1** | Constrained Baseline/L30 | 0 | 48.4 | 14400 | 600.000000 | YES |
| `MiSTerPlex BitrateLadder 624x480 24fps 1000kbit ref1 600s (2026).mp4` | bitrate_sweep_1000 | **624×480** | **24/1** | 1000 | **999.4** | **1051.9** | **1** | Constrained Baseline/L30 | 0 | 48.4 | 14400 | 600.000000 | YES |
| `MiSTerPlex BitrateLadder 624x480 24fps 1400kbit ref1 600s (2026).mp4` | bitrate_sweep_1400 | **624×480** | **24/1** | 1400 | **1399.9** | **1452.3** | **1** | Constrained Baseline/L30 | 0 | 48.4 | 14400 | 600.000000 | YES |
| `MiSTerPlex BitrateLadder 624x480 24fps 1800kbit ref1 600s (2026).mp4` | bitrate_sweep_1800 | **624×480** | **24/1** | 1800 | **1798.1** | **1850.5** | **1** | Constrained Baseline/L30 | 0 | 48.4 | 14400 | 600.000000 | YES |
| `MiSTerPlex BitrateLadder 624x480 24fps 2200kbit ref1 600s (2026).mp4` | bitrate_sweep_2200 | **624×480** | **24/1** | 2200 | **2198.1** | **2250.5** | **1** | Constrained Baseline/L30 | 0 | 48.4 | 14400 | 600.000000 | YES |
| `MiSTerPlex BitrateLadder 624x480 24fps 2600kbit ref1 600s (2026).mp4` | bitrate_sweep_2600 | **624×480** | **24/1** | 2600 | **2599.0** | **2651.4** | **1** | Constrained Baseline/L30 | 0 | 48.4 | 14400 | 600.000000 | YES |
| `MiSTerPlex BitrateLadder 624x480 24fps 700kbit ref3 600s (2026).mp4` | ref_pair_ref3 | **624×480** | **24/1** | 700 | **681.9** | **734.4** | **3** | Constrained Baseline/L30 | 0 | 48.4 | 14400 | 600.000000 | YES |
| `MiSTerPlex BitrateLadder 624x352 24fps 700kbit ref1 600s (2026).mp4` | geom_pair_624x352 | **624×352** | **24/1** | 700 | **700.5** | **752.9** | **1** | Constrained Baseline/L30 | 0 | 48.4 | 14400 | 600.000000 | YES |

## Parent PMS ingest (section 2 only — you run)

```bash
ls -1 /home/flynnsbit/plex/media/movies/MiSTerPlex\ BitrateLadder*
curl -sS -o /dev/null -w 'refresh_http=%{http_code}\n' \
  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
echo "refresh true rc=$?"
# enumerate ratingKeys after scan:
curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" -o /tmp/pms_s2.xml
echo "all true rc=$?"
python3 - <<'PY'
import xml.etree.ElementTree as ET
root=ET.parse('/tmp/pms_s2.xml').getroot()
for v in sorted(root.findall('.//Video'), key=lambda e:int(e.get('ratingKey',0))):
    t=v.get('title') or ''
    if 'BitrateLadder' in t or 'Bitrate' in t:
        print(f"rk={v.get('ratingKey')} dur_ms={v.get('duration')} | {t}")
PY
```

PMS geometry/bitrate tags are **claims** — trust ffprobe / this table.
Prefer Direct Play. Agent does not cast or touch 192.168.1.183.

## Reproduce

```bash
python3 scripts/gen_bitrate_ladder.py --duration 600 --copy-media
```

Generator: `scripts/gen_bitrate_ladder.py`
Probe JSON: `docs/bitrate_ladder_probe.json`

