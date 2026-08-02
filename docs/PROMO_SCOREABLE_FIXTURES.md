# Promo “scoreable” fixtures — closes S5 + B6 residual

**Problem these solve:** the entire promotion soak package was synthetic black
(mean luma ~3–7). That is cheapest decode load (S5), bank-exact 624×480 only
(B6 residual), and **broke freeze instruments** (ERROR 13: identical md5 on black).

**These fixtures are hostile to bad instruments:** every frame has structure,
colour, a glass ID counter, and A/V markers.

## Properties (every file, every frame)

| property | value | evidence |
|----------|-------|----------|
| Content | Real BBB loop + black-lift (≥40) + scrolling checker + diagonal ticker | generator `composite_body` |
| Glass ID | `G n=DDDDDD c=C` + Grey bars **every frame**, **no `enable=` guard** | `draw_id_band` last in loop |
| Colour patches | R/G/B/Y/C/M + W/K/N18 at contract fractions | `docs/colour_patch_contract.md` v1 |
| A/V markers | white body flash 2 frames + 1 kHz / 50 ms beep, period **2.000 s** | designed offset 0 (or +100 twin) |
| Codec | H.264 **Constrained Baseline**, `has_b_frames=0` | ffprobe |
| Audio | **AAC 48 kHz** stereo (BBB + beep mix) | ffprobe |
| Frame rate | **`24/1` only** — in filename `24fps` and measured `r_frame_rate` | never 24000/1001 |
| Duration | **600 s (10 min)** | n_frames=14400 @24/1 |

## Measured table (host ffprobe — not PMS tags)

| media filename | measured WxH | r_frame_rate | nb_frames | dur_s | profile | B | audio | size_MB | bank_fit | host_patches |
|----------------|--------------|--------------|----------:|------:|---------|---|-------|--------:|----------|--------------|
| `MiSTerPlex PromoScoreable 624x352 24fps 600s (2026).mp4` | **624×352** | **24/1** | 14400 | 600 | CB | 0 | aac/48k | ~175 | adversarial | OK |
| `MiSTerPlex PromoScoreable 640x480 24fps 600s (2026).mp4` | **640×480** | **24/1** | 14400 | 600 | CB | 0 | aac/48k | ~197 | adversarial | OK |
| `MiSTerPlex PromoScoreable 720x480 24fps 600s (2026).mp4` | **720×480** | **24/1** | 14400 | 600 | CB | 0 | aac/48k | ~218 | adversarial | OK |
| `MiSTerPlex PromoScoreable 720x404 24fps 600s (2026).mp4` | **720×404** | **24/1** | 14400 | 600 | CB | 0 | aac/48k | ~197 | adversarial | OK |
| `MiSTerPlex PromoScoreable 1440x1080 24fps 600s (2026).mp4` | **1440×1080** | **24/1** | 14400 | 600 | CB | 0 | aac/48k | ~439 | adversarial | OK |
| `MiSTerPlex PromoScoreable 624x480 24fps 600s (2026).mp4` | **624×480** | **24/1** | 14400 | 600 | CB | 0 | aac/48k | ~197 | **favourable** control | OK |
| `… 624x480 24fps 600s audioPlus100ms (2026).mp4` | **624×480** | **24/1** | 14400 | 600 | CB | 0 | aac/48k | ~197 | favourable | OK |

Probe JSON: `docs/promo_scoreable_probe.json` · per-file `*.meta.json` includes **exact patch pixel boxes**.

## Who uses what

| lane | cast | why |
|------|------|-----|
| **w-geom / B6** | any **adversarial** row (prefer 640/720/1440) | FORCE_SCALE on width≠624; 720×404 awkward height |
| **w-instr colour** | any; pin `colour_patch_contract_version=1` | known-hue ROI asserts (not green-dominance) |
| **w-avsync** | 624×480 **0** then **audioPlus100ms** | flash↔beep; RED first on +100 |
| **soak / S5** | any 600 s row | real detail + 10 min; freeze via glass `n` only |
| **Do not** | old black AVSync / DeliveryGeom for picture or freeze-md5 | ERROR 13 class |

## Freeze test (only valid method)

Read glass ID `n` from pixels (bars primary, text secondary).  
**Monotonic increase ⇒ motion.** Identical md5 on these files is still possible on rare frames — **md5 is never the freeze oracle.**

## Colour patches (w-instr agreement)

Contract: `docs/colour_patch_contract.md`  
Host-decoded inner ROI (example 720×480 @ t=0.5 s): R≈(253,0,0), G≈(0,255,0), B≈(0,0,254), … all asserts passed post-H.264.

Sample **inner 50%** of each patch AABB from `meta.json → colour_patches_px[].inner`.

## A/V markers (w-avsync agreement)

| param | value |
|-------|-------|
| period | 2.000 s |
| flash | full-white **body** (y ≥ id_bottom), 2 frames @24p |
| beep | 1 kHz, 50 ms, 1 ms attack, ~0.85 FS over BBB audio |
| offset 0 | GREEN expect |
| offset +100 ms | RED expect (bank twin only in this set) |

## Generator

```bash
SRC=.agent-work/fixtures-real/bbb_720p_src.mp4

python3 scripts/gen_promo_scoreable_fixture.py \
  --src "$SRC" \
  --out assets/avsync/promo_scoreable_720x480_24_600s.mp4 \
  --width 720 --height 480 --duration 600 \
  --period 2.0 --audio-delay-ms 0 --vbitrate 2800k \
  --copy-media
```

Ladder scripted in agent logs; geometries: 624×352, 640×480, 720×480, 720×404, 1440×1080, 624×480 ±0/+100.

**ID every frame:** `draw_id_band(rgb, n, geom)` is called unconditionally after body composite — same “no enable= guard” property as `gen_avsync_blip.py:75`.

## PMS ingest (parent only — section 2)

Media already at `~/plex/media/movies/MiSTerPlex PromoScoreable *`.

```bash
# Token from lab file — never commit/print
export TOK=...

ls -1 ~/plex/media/movies/MiSTerPlex\ PromoScoreable*

curl -sS -o /dev/null -w 'refresh_http=%{http_code}\n' \
  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
echo "refresh true rc=$?"

curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" \
  -o /tmp/pms_s2.xml
echo "all true rc=$?"

python3 - <<'PY'
import xml.etree.ElementTree as ET
root = ET.parse("/tmp/pms_s2.xml").getroot()
for v in sorted(root.findall(".//Video"), key=lambda e: int(e.get("ratingKey", 0))):
    t = v.get("title") or ""
    if "PromoScoreable" in t:
        print(f"rk={v.get('ratingKey')} dur_ms={v.get('duration')} | {t}")
PY
```

PMS width/height tags are **claims** — trust ffprobe / `docs/promo_scoreable_probe.json`.  
Prefer **Direct Play**. ratingKeys appear only after your refresh.

## Branch

`w-asset480-manifest` — generator + docs committed; MP4s gitignored (on PMS mount only).
