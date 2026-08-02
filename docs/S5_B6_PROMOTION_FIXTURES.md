# S5 / B6 promotion fixtures (real content + non-bank geometry)

Host-side only. Parent casts; agents do not touch the MiSTer.

## Why these exist

| Gap | What was wrong | What these close |
|-----|----------------|------------------|
| **S5** | Promotion package had **zero** long real-content soak frames with glass ID on a **non-bank** geometry (bank 624×480 1200s rk30 alone is the favourable case) | **rk141 / rk140**: 720×480 RealGlass BBB **1200 s** @ **24/1** and **24000/1001** |
| **B6** | 480p milestone only proven at coded-bank 624×480 | Ladder **624×352, 640×480, 720×480, 704×396** @ both rates (rk132–139) |

## Encoder contract (every arm)

- H.264 **Constrained Baseline**, `level=30`, **`has_b_frames=0`**, `cabac=0`, `ref=1`
- AAC LC **48 kHz** stereo + 1 kHz beep @ period **2.000 s** (flash on body below ID band)
- Glass ID every frame: `G n=DDDDDD c=C` + Grey bars (`tools/glass_frame_id.draw_id_band`)
- Plate also burns `fps=24/1` or `fps=24000/1001` (ERROR 17 guard)
- Generator: `scripts/gen_real_bbb_avsync_soak.py` + batch `scripts/gen_s5_b6_promotion_fixtures.py`
- Source: `.agent-work/fixtures-real/bbb_720p_src.mp4` (measured 640×360 @ 24/1, looped)

## Rate truth (do not trust PMS `videoFrameRate` alone)

PMS reports **`videoFrameRate=24p` for both** 24/1 and 24000/1001 arms.  
**Asset truth is ffprobe `r_frame_rate` / `avg_frame_rate`**, and the burned-in `fps=` tag / filename (`24fps` vs `23976fps`).

| Label in filename | ffprobe rational | approx |
|-------------------|------------------|--------|
| `24fps` | **24/1** | 24.000 |
| `23976fps` | **24000/1001** | 23.976023… |

## Manifest (local PMS §2, machineIdentifier `bf36a3ad8d4f6810ab3f69ec9f1adb22a7a9dc8a`)

Cast pattern (parent only):

```text
address=192.168.1.24 port=32400
machineIdentifier=bf36a3ad8d4f6810ab3f69ec9f1adb22a7a9dc8a
KEY=/library/metadata/<rk>
```

### S5 — long real soaks (non-bank 720×480)

| rk | filename | WxH | r_frame_rate | dur_s | profile | has_b | v_bitrate (ffprobe) | PMS bitrate kbps | nb_frames |
|----|----------|-----|--------------|-------|---------|-------|---------------------|------------------|-----------|
| **141** | `MiSTerPlex S5 RealGlass 720x480 24fps 1200s (2026).mp4` | 720×480 | **24/1** | 1200.000 | Constrained Baseline L3.0 | 0 | 2458685 | 2626 | 28800 |
| **140** | `MiSTerPlex S5 RealGlass 720x480 23976fps 1200s (2026).mp4` | 720×480 | **24000/1001** | 1200.000 | Constrained Baseline L3.0 | 0 | 2458838 | 2626 | 28771 |

### B6 — non-bank geometry ladder @ 24/1 (300 s)

| rk | filename | WxH | r_frame_rate | dur_s | v_bitrate | PMS kbps | nb_frames |
|----|----------|-----|--------------|-------|-----------|----------|-----------|
| **133** | `… B6 RealGlass 624x352 24fps 300s (2026).mp4` | 624×352 | 24/1 | 300.000 | 1984274 | 2151 | 7200 |
| **135** | `… B6 RealGlass 640x480 24fps 300s (2026).mp4` | 640×480 | 24/1 | 300.000 | 1974855 | 2142 | 7200 |
| **139** | `… B6 RealGlass 720x480 24fps 300s (2026).mp4` | 720×480 | 24/1 | 300.000 | 1977281 | 2144 | 7200 |
| **137** | `… B6 RealGlass 704x396 24fps 300s (2026).mp4` | 704×396 | 24/1 | 300.000 | 1982764 | 2150 | 7200 |

### B6 — same ladder @ 24000/1001 (300 s)

| rk | filename | WxH | r_frame_rate | dur_s | v_bitrate | PMS kbps | nb_frames |
|----|----------|-----|--------------|-------|-----------|----------|-----------|
| **132** | `… B6 RealGlass 624x352 23976fps 300s (2026).mp4` | 624×352 | 24000/1001 | 300.008 | 1981660 | 2149 | 7193 |
| **134** | `… B6 RealGlass 640x480 23976fps 300s (2026).mp4` | 640×480 | 24000/1001 | 300.008 | 1973142 | 2140 | 7193 |
| **138** | `… B6 RealGlass 720x480 23976fps 300s (2026).mp4` | 720×480 | 24000/1001 | 300.008 | 1974641 | 2142 | 7193 |
| **136** | `… B6 RealGlass 704x396 23976fps 300s (2026).mp4` | 704×396 | 24000/1001 | 300.008 | 1980769 | 2148 | 7193 |

All arms: AAC 48 kHz stereo, glass bars host-verified (`decode_bars_from_rgb` OK, n≈240 at t=10 s on S5-24 and B6-704-23976).

## Cast KEY lines (copy-paste)

```text
# S5 long non-bank soaks
KEY=/library/metadata/141   # 720x480 24/1 1200s
KEY=/library/metadata/140   # 720x480 24000/1001 1200s

# B6 ladder 24/1
KEY=/library/metadata/133   # 624x352
KEY=/library/metadata/135   # 640x480
KEY=/library/metadata/139   # 720x480
KEY=/library/metadata/137   # 704x396

# B6 ladder 24000/1001
KEY=/library/metadata/132
KEY=/library/metadata/134
KEY=/library/metadata/138
KEY=/library/metadata/136
```

## Overlay / instrument config

- Counter text: `G n=DDDDDD c=C` (6 digits — covers 1200×24 = 28800 frames)
- Bars: Grey-coded n, even parity, START/STOP/LOCK (authoritative)
- Rate plate tag: `fps=24/1` or `fps=24000/1001`
- Flash + beep period: **2.000 s**; designed A/V offset **0.0 ms**
- Freeze test: monotonic glass `n`, **not** md5 (ERROR 8/13)

## Known non-matches / caveats (Rule 0)

1. **PMS `videoFrameRate=24p` for both rates** — do not use PMS alone to distinguish 23.976 vs 24.000; use filename / ffprobe / plate tag.
2. **23976 duration** is **300.008042 s** / **1200.000** container with `nb_frames=7193` or `28771` (exact frame quantisation of 24000/1001) — not a bug.
3. **Bank control still available**: existing rk30 / GlassAV 624×480 1200s — favourable geometry; S5 soaks are deliberately **720×480**.
4. Source is 640×360 BBB upscaled — high motion/detail relative to black fixtures; not a native 480p camera master.
5. Direct-play still depends on daemon `PREFER_DIRECT_H264` / STREAM and w-cpu-1 bitrate floor — these assets match CB/L3.0/bf=0/AAC; they do **not** by themselves force `transcoded=0`.

## Regenerating

```bash
python3 scripts/gen_s5_b6_promotion_fixtures.py \
  --src /home/flynnsbit/Projects/MisterPlex/.agent-work/fixtures-real/bbb_720p_src.mp4 \
  --out-dir .agent-work/s5b6_fixtures \
  --media-dir /home/flynnsbit/plex/media/movies
# then section 2 refresh + re-read ratingKeys
```

Batch evidence: `.agent-work/s5b6_fixtures/s5b6_batch_report.json`, `ffprobe_all.txt`, `pms_index.json`.
