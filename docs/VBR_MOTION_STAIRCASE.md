# VBR motion staircase (path starvation discriminator)

**Hypothesis:** VBR spikes on high-motion toward maxVideoBitrate=2000 starve a path
whose **sustained** capability is ~84 KB/s median ≈ **670 kbit/s** (parent corrected;
long-window ~107 KB/s mean retracted).

**Segment length:** 20.0 s — LOW (even idx) then HIGH (odd), repeating.
**Duration:** 360.0 s @ **24/1**. Glass ID every frame (`draw_id_band`, no enable=).

## Transitions + measured per-segment video bitrate (bank stair)

| idx | kind | t0_s | t1_s | meas_v_kbit_s |
|----:|------|-----:|-----:|--------------:|
| 0 | **LOW** | 0.0 | 20.0 | **120.82** |
| 1 | **HIGH** | 20.0 | 40.0 | **2163.1** |
| 2 | **LOW** | 40.0 | 60.0 | **119.61** |
| 3 | **HIGH** | 60.0 | 80.0 | **2160.96** |
| 4 | **LOW** | 80.0 | 100.0 | **119.53** |
| 5 | **HIGH** | 100.0 | 120.0 | **2168.68** |
| 6 | **LOW** | 120.0 | 140.0 | **120.19** |
| 7 | **HIGH** | 140.0 | 160.0 | **2144.21** |
| 8 | **LOW** | 160.0 | 180.0 | **119.83** |
| 9 | **HIGH** | 180.0 | 200.0 | **2156.53** |
| 10 | **LOW** | 200.0 | 220.0 | **120.03** |
| 11 | **HIGH** | 220.0 | 240.0 | **2160.29** |
| 12 | **LOW** | 240.0 | 260.0 | **119.46** |
| 13 | **HIGH** | 260.0 | 280.0 | **2158.83** |
| 14 | **LOW** | 280.0 | 300.0 | **119.99** |
| 15 | **HIGH** | 300.0 | 320.0 | **2164.43** |
| 16 | **LOW** | 320.0 | 340.0 | **119.47** |
| 17 | **HIGH** | 340.0 | 360.0 | **2105.13** |

**Segment means (measured):** LOW≈**119.9** kbit/s  HIGH≈**2153.6** kbit/s
File mean_v≈**1136.7** → CBR mean target **1137 kbit/s** (true minrate=maxrate).

HIGH segments (~2150 kbit/s) **far above** path 670; LOW (~120) **far below**.

## PRE-REGISTER (one cast per clip)

| clip | supply_ratio | pfps | drops trend |
|------|--------------|------|-------------|
| **stair VBR** | LOW ≈0.95–1.0; HIGH dip if starved | LOW≈23–24; HIGH dip | flat on LOW; **climb locked to HIGH t0** |
| **cbrMean 1137k** | may be stressed (1137>670) but **steady** | may dip | climb **not** locked to HIGH t0 if VBR-cause |
| **cbrLow 400k** | ≈0.97–1.0 entire run | ≈23.5–24 | **flat forever** |
| stair VBR 640×480 | same pattern as bank if bitrate-cause | same | same |

**Confirm VBR hypothesis:** stair shows HIGH-transition-locked stress AND cbrMean does not share that lock (even if cbrMean is globally worse).
**Kill hypothesis:** no HIGH lock on stair, or cbrLow also collapses.

## Measured clips

| title | role | W×H | fps | mean_v_k | total_k | refs | profile/L/B | audio | spec |
|-------|------|-----|-----|---------:|--------:|-----:|-------------|-------|------|
| `MiSTerPlex VBRStair 624x480 24fps stairVBR_max2000 360s (2026).mp4` | staircase_vbr | **624×480** | **24/1** | 1136.7 | 1236.5 | **1** | Constrained Baseline/L30/B0 | aac@48000/2ch 95.7k | YES |
| `MiSTerPlex VBRStair 640x480 24fps stairVBR_max2000 360s (2026).mp4` | staircase_vbr_nonbank | **640×480** | **24/1** | 1136.4 | 1236.2 | **1** | Constrained Baseline/L30/B0 | aac@48000/2ch 95.7k | YES |
| `MiSTerPlex VBRStair 624x480 24fps cbrMean1137k 360s (2026).mp4` | cbr_mean | **624×480** | **24/1** | 1137.7 | 1237.6 | **1** | Constrained Baseline/L30/B0 | aac@48000/2ch 95.8k | YES |
| `MiSTerPlex VBRStair 624x480 24fps cbrLow400k 360s (2026).mp4` | cbr_low | **624×480** | **24/1** | 400.4 | 500.3 | **1** | Constrained Baseline/L30/B0 | aac@48000/2ch 95.8k | YES |

## Exact encode commands (reproducible)

Staircase VBR (representative):
```
ffmpeg -y -hide_banner -loglevel error -f rawvideo -pix_fmt rgb24 -s 624x480 -r 24 -i pipe:0 -i /home/flynnsbit/Projects/MisterPlex/.worktrees/w-asset480-manifest/assets/avsync/.work_vbr_stair_624x480_24_vbrmax2000_360s/a.wav -map 0:v:0 -map 1:a:0 -c:v libx264 -profile:v baseline -level:v 3.0 -bf 0 -x264-params cabac=0:ref=1:bframes=0:keyint=48:level=30:vbv-maxrate=2000:vbv-bufsize=4000 -pix_fmt yuv420p -crf 23 -maxrate 2000k -bufsize 4000k -r 24 -c:a aac -b:a 96k -ar 48000 -ac 2 -shortest -movflags +faststart /home/flynnsbit/Projects/MisterPlex/.worktrees/w-asset480-manifest/assets/avsync/vbr_stair_624x480_24_vbrmax2000_360s.mp4
```

CBR mean (true CBR):
```
ffmpeg -y -i vbr_stair_624x480_24_vbrmax2000_360s.mp4 -c:v libx264 -profile:v baseline -level:v 3.0 -bf 0 -x264-params cabac=0:ref=1:bframes=0:keyint=48:level=30:nal-hrd=cbr:force-cfr=1:vbv-maxrate=1137:vbv-bufsize=1137 -pix_fmt yuv420p -b:v 1137k -minrate 1137k -maxrate 1137k -bufsize 1137k -r 24 -c:a aac -b:a 96k -ar 48000 -ac 2 -movflags +faststart OUT
```

## Parent PMS (§2)

```bash
curl -sS -o /dev/null -w 'refresh_http=%{http_code}\n' \
  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
echo "refresh true rc=$?"
# list VBRStair ratingKeys + quote frameRate claim:
curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" -o /tmp/pms_s2.xml
echo "all true rc=$?"
python3 - <<'PY'
import xml.etree.ElementTree as ET
root=ET.parse('/tmp/pms_s2.xml').getroot()
for v in sorted(root.findall('.//Video'), key=lambda e:int(e.get('ratingKey',0))):
    t=v.get('title') or ''
    if 'VBRStair' in t:
        print(f"rk={v.get('ratingKey')} dur_ms={v.get('duration')} frameRate={v.get('frameRate')} | {t}")
PY
```

Asset truth: **ffprobe r_frame_rate=24/1**. Quote PMS frameRate when present; do not assume 23.976.

Generator: `scripts/gen_vbr_motion_staircase.py`

## Indexed ratingKeys (section 2)

| rk | PMS title | PMS frameRate claim |
|---:|-----------|---------------------|
| **101** | MiSTerPlex VBRStair 624x480 24fps cbrLow400k 360s (2026) | `None` |
| **102** | MiSTerPlex VBRStair 624x480 24fps cbrMean1137k 360s (2026) | `None` |
| **103** | MiSTerPlex VBRStair 624x480 24fps stairVBR Max2000 360s | `None` |
| **104** | MiSTerPlex VBRStair 640x480 24fps stairVBR Max2000 360s | `None` |

Asset ffprobe rate is **24/1** for all — quote PMS frameRate when non-null; never assume 23.976.
