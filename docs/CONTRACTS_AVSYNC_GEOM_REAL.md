# Fixture contracts for w-avsync + w-geom (host-built, parent casts)

**PMS:** `http://192.168.1.24:32400` · section **2** · “MiSTerPlex Tests” only  
**Ignore:** SHIELD `192.168.1.122`, remote `plex.nevertrustaf.art`  
**Device:** parent only. Agent does not cast/ssh.  
**Encoder contract (all rows):** H.264 **Constrained Baseline**, `has_b_frames=0`, **AAC 48 kHz**, glass ID `G n=DDDDDD c=C` on every frame.

PMS library metadata is a **claim** (B4). **True coded geometry = host ffprobe** below.

---

## CONTRACT 1 — lipsync markers (w-avsync)

### Why not the old black AVSync clips
Measured body mean on `AVSync Glass 480p 600s`: **body_mean≈0, frac_body_Y&lt;10 = 1.0**.  
Unsuitable for picture verdicts; md5 freeze tests are invalid on black.

### Marker design (agree with w-avsync instrument)

| parameter | value | notes |
|-----------|-------|-------|
| period | **2.000 s** | disambiguates easily vs grabber jitter |
| visual | full-white **body** flash, `FLASH_FRAMES=2` (~83 ms @24p), **below** ID band (y≥ bar_y1) | ID band never whitened |
| audio | **1 kHz** sine, **50 ms**, **1 ms** linear attack, peak ~0.85 FS, mixed over real BBB audio | ALSA `hw:0,0` path |
| designed offset 0 | beep onset = flash time | instrument GREEN expect |
| designed offset **+100 ms** | beep **lags** video by 100 ms | instrument **RED** expect |
| glass ID | every frame | freeze/rate from pixels, not md5 |

### Primary twins (real content — NOT black)

| media filename | measured WxH | rate | dur_s | n_frames | designed_offset_ms | **host-measured lag median** | body_mean | frac&lt;10 |
|----------------|--------------|------|------:|---------:|-------------------:|-----------------------------:|----------:|--------:|
| `MiSTerPlex Real BBB GlassAV 624x480 24fps 600s (2026).mp4` | **624×480** | **24/1** | 600 | 14400 | 0 | **0.0 ms** | 123.6 | 0.00 |
| `… 600s audioPlus100ms (2026).mp4` | **624×480** | **24/1** | 600 | 14400 | **+100** | **100.0 ms** | 123.6 | 0.00 |

Both: profile=Constrained Baseline, B=0, aac/48000 (ffprobe true rc=0).

### Width ≠ 624 lipsync twins (same markers)

| media filename | measured | dur | designed | host lag med | body_mean |
|----------------|----------|----:|---------:|-------------:|----------:|
| Real BBB GlassAV **640×480** 180s | 640×480 24/1 n=4320 | 180 | 0 | **0.0** | 146.2 |
| … 640×480 180s **audioPlus100ms** | 640×480 24/1 | 180 | +100 | **100.0** | 146.2 |
| Real BBB GlassAV **720×480** 180s | 720×480 24/1 n=4320 | 180 | 0 | **0.0** | 146.2 |
| … 720×480 180s **audioPlus100ms** | 720×480 24/1 | 180 | +100 | **100.0** | 146.2 |
| Real BBB GlassAV **426×240** 180s | 426×240 24/1 n=4320 | 180 | 0 | **0.0** | 145.7 |
| … 426×240 180s **audioPlus100ms** | 426×240 24/1 | 180 | +100 | **100.0** | 145.7 |
| Real BBB GlassAV **624×352** 180s | 624×352 24/1 n=4320 | 180 | 0 | **0.0** | 144.1 |
| … 624×352 180s **audioPlus100ms** | 624×352 24/1 | 180 | +100 | **100.0** | 144.1 |

### w-avsync procedure (parent)
1. Cast **audioPlus100ms** twin → expect cross-corr peak ≈ **+100 ms** (RED proves instrument).  
2. Cast **offset 0** twin → expect ≈ **0 + device bias**.  
3. Do **not** use `av_drift_ms` (circular Hold setpoint — UNSCORED).  
4. Prefer HDMI ALSA `hw:0,0` + `/dev/video0` flash detect.

Generator: `scripts/gen_real_bbb_avsync_soak.py --audio-delay-ms 0|100 --period 2.0`

---

## CONTRACT 2 — width ≠ 624 (w-geom / B6)

Bank-exact **624×480** is favourable. Live delivery also saw **624×350** (vertical pad only) and **426×240**.  
**Width ≠ 624** is the discriminating axis (bank store `449280 = 624×720`).

### A) Synthetic DeliveryGeom (glass ID, black body — geometry/rate only)

| media | measured | rate | bank_fit | note |
|-------|----------|------|----------|------|
| DeliveryGeom **640×480** 24/1 & 30/1 90s | 640×480 | 24/1, 30/1 | adversarial | stride / PresentedMistake width |
| DeliveryGeom **720×480** 24/1 & 30/1 90s | 720×480 | 24/1, 30/1 | adversarial | NTSC DV width |
| DeliveryGeom **426×240** 24/1 & 30/1 90s | 426×240 | 24/1, 30/1 | adversarial | **observed live** width |
| DeliveryGeom **624×352** 24/1 & 30/1 90s | 624×352 | 24/1, 30/1 | adversarial | completeness / chroma neighbor of 350 |
| DeliveryGeom **624×480** 24/1 & 30/1 90s | 624×480 | 24/1, 30/1 | **favourable** | control |
| DeliveryGeom **624×350** 24/1 & 30/1 90s | 624×350 | 24/1, 30/1 | adversarial | observed height; **not** width stress |

Full table: `docs/DELIVERY_GEOMETRY_MATRIX.md`.  
**visual_verdict=HAZARD** (black body) — use for delivery geometry + glass ID, not picture quality.

### B) Real BBB GlassAV width ladder (preferred for fabric stress)

Use Contract 1 width rows (180s) + existing:

| media | measured | dur | real content |
|-------|----------|----:|--------------|
| Real BBB GlassAV **640×480** 180s (±0/+100) | 640×480 24/1 | 180 | YES |
| Real BBB GlassAV **720×480** 180s (±0/+100) | 720×480 24/1 | 180 | YES |
| Real BBB GlassAV **426×240** 180s (±0/+100) | 426×240 24/1 | 180 | YES |
| Real BBB GlassAV **624×352** 180s (±0/+100) | 624×352 24/1 | 180 | YES |
| Real BBB GlassAV 640/720 90s (older) | same geoms | 90 | YES |

---

## CONTRACT 3 — real full-frame long soak (S5)

| media | measured | rate | dur_s | n_frames | body_mean | purpose |
|-------|----------|------|------:|---------:|----------:|---------|
| **Real BBB GlassAV 624×480 24fps 1200s** | 624×480 | 24/1 | **1200** | 28800 | ~154 | **primary long real soak** (20 min) |
| Real BBB GlassAV 624×480 24fps 600s | 624×480 | 24/1 | 600 | 14400 | ~124 | lipsync GREEN + medium soak |
| Real BBB GlassID 720×480 (rk19 class) | 720×480 | 24/1 | ~596 | — | real | long non-bank real |
| Real BBB GlassID 624×352 360s | 624×352 | 24/1 | 360 | — | real | medium non-bank |

**Do not** use 30 s RK6 for multi-window soaks — EOF races empty samples.

Markers on 1200s/600s GlassAV: period 2.0 s, designed offset 0 (1200s); 600s has 0 and +100 twins.

---

## Place + index (parent runs)

Media already copied to `~/plex/media/movies/` (docker `/data/movies`).

```bash
export TOK=$(cat /path/to/local_tok.txt)   # never commit

ls -1 ~/plex/media/movies/MiSTerPlex\ Real\ BBB\ GlassAV* \
      ~/plex/media/movies/MiSTerPlex\ DeliveryGeom*

curl -sS -o /dev/null -w 'refresh_http=%{http_code}\n' \
  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
echo "refresh true rc=$?"

# poll until new titles appear
curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" \
  -o /tmp/pms_s2.xml
echo "all true rc=$?"
python3 - <<'PY'
import xml.etree.ElementTree as ET
root = ET.parse("/tmp/pms_s2.xml").getroot()
keys = ("GlassAV", "DeliveryGeom", "audioPlus100")
for v in sorted(root.findall(".//Video"), key=lambda e: int(e.get("ratingKey", 0))):
    t = v.get("title") or ""
    if any(k in t for k in keys):
        print(f"rk={v.get('ratingKey')} dur_ms={v.get('duration')} | {t}")
PY
```

**ratingKeys:** assigned only after your refresh — report back into the thread.  
Cast by **ratingKey**, prefer **Direct Play** so coded size is what the daemon measures.

---

## Reproduce

```bash
SRC=.agent-work/fixtures-real/bbb_720p_src.mp4   # or lab BBB path

# C1 bank twins
python3 scripts/gen_real_bbb_avsync_soak.py --src "$SRC" \
  --out assets/avsync/real_bbb_glass_av_624x480_24_600s.mp4 \
  --width 624 --height 480 --duration 600 --period 2 --audio-delay-ms 0
python3 scripts/gen_real_bbb_avsync_soak.py --src "$SRC" \
  --out assets/avsync/real_bbb_glass_av_624x480_24_600s_audioPlus100ms.mp4 \
  --width 624 --height 480 --duration 600 --period 2 --audio-delay-ms 100

# C2 synthetic width matrix (already generated)
python3 scripts/gen_delivery_geometry_matrix.py --duration 90 --copy-media
```

Host probe evidence: `.agent-work/w-asset480/contract123_probe.json`

---

## Do not use for these contracts

| asset class | why |
|-------------|-----|
| AVSync/AudioID **Glass** synthetic black | body black — C1 picture + freeze invalid |
| RK6 30 s Test 480p | too short; EOF races multi-window soaks |
| `av_drift_ms` PLXD field | circular Hold setpoint (UNSCORED) |
| Disc Nyquist cast for tier | void for 240-vs-480 |
| PMS width/height tags alone | claims, not measurements |

## Superseding promo set
For S5/B6/colour/freeze, prefer **PromoScoreable** [`docs/PROMO_SCOREABLE_FIXTURES.md`](PROMO_SCOREABLE_FIXTURES.md) over black AVSync and short GlassAV 90s rows.
