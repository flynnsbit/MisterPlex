# Delivery-geometry fixture matrix

**Purpose:** cover geometries PMS actually delivers under `upperBounds`,
not only bank-exact 624×480. Live session observed **624×480**, **624×350**,
**426×240**. `DDR_YUV_FORCE_SCALE=1` must be scored on adversarial sizes.

**Contract:** H.264 Constrained Baseline, `has_b_frames=0`, AAC 48 kHz,
glass frame ID every frame (`G n=DDDDDD c=C`). Rates are **24/1** and **30/1**
only (never assume 24000/1001 — ERROR 17).

**Default duration:** 90 s (geometry probe). Generator:
`scripts/gen_delivery_geometry_matrix.py`.

## Measured table (ffprobe — not intent)

| media filename | role | bank_fit | measured WxH | r_frame_rate | avg | nb_frames | profile | B | audio | dur_s | size_MB | spec_ok |
|----------------|------|----------|--------------|--------------|-----|-----------|---------|---|-------|------:|--------:|---------|
| `MiSTerPlex DeliveryGeom 624x350 24fps 90s (2026).mp4` | observed_delivery_624x350 | adversarial | **624×350** | **24/1** | 24/1 | 2160 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 3.78 | YES |
| `MiSTerPlex DeliveryGeom 624x350 30fps 90s (2026).mp4` | observed_delivery_624x350 | adversarial | **624×350** | **30/1** | 30/1 | 2700 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 4.44 | YES |
| `MiSTerPlex DeliveryGeom 426x240 24fps 90s (2026).mp4` | observed_delivery_426x240 | adversarial | **426×240** | **24/1** | 24/1 | 2160 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 2.82 | YES |
| `MiSTerPlex DeliveryGeom 426x240 30fps 90s (2026).mp4` | observed_delivery_426x240 | adversarial | **426×240** | **30/1** | 30/1 | 2700 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 3.34 | YES |
| `MiSTerPlex DeliveryGeom 624x480 24fps 90s (2026).mp4` | bank_exact_control | favourable | **624×480** | **24/1** | 24/1 | 2160 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 3.74 | YES |
| `MiSTerPlex DeliveryGeom 624x480 30fps 90s (2026).mp4` | bank_exact_control | favourable | **624×480** | **30/1** | 30/1 | 2700 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 4.67 | YES |
| `MiSTerPlex DeliveryGeom 640x480 24fps 90s (2026).mp4` | width_640_stride | adversarial | **640×480** | **24/1** | 24/1 | 2160 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 3.92 | YES |
| `MiSTerPlex DeliveryGeom 640x480 30fps 90s (2026).mp4` | width_640_stride | adversarial | **640×480** | **30/1** | 30/1 | 2700 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 4.90 | YES |
| `MiSTerPlex DeliveryGeom 720x480 24fps 90s (2026).mp4` | ntsc_dv_width | adversarial | **720×480** | **24/1** | 24/1 | 2160 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 4.08 | YES |
| `MiSTerPlex DeliveryGeom 720x480 30fps 90s (2026).mp4` | ntsc_dv_width | adversarial | **720×480** | **30/1** | 30/1 | 2700 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 5.08 | YES |
| `MiSTerPlex DeliveryGeom 624x352 24fps 90s (2026).mp4` | chroma_neighbor_of_350 | adversarial | **624×352** | **24/1** | 24/1 | 2160 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 3.77 | YES |
| `MiSTerPlex DeliveryGeom 624x352 30fps 90s (2026).mp4` | chroma_neighbor_of_350 | adversarial | **624×352** | **30/1** | 30/1 | 2700 | Constrained Baseline | 0 | aac/48000 | 90.000000 | 4.43 | YES |

## bank_fit legend

| value | meaning |
|-------|---------|
| favourable | coded **624×480** — exact DDR bank; easiest 480p path |
| adversarial | any other coded size — forces ARM scale/pad/crop |

### Why 624×352 sits next to 624×350

I420 chroma height is `H/2`. A bug that mis-aligns chroma plane base
by one luma row (or mishandles odd/near-odd active heights after pad)
can pass on one neighbor and fail on the other. **350 vs 352 is the
discriminator pair** for that class; both are adversarial vs the bank.

## Reproduce

```bash
python3 scripts/gen_delivery_geometry_matrix.py --duration 90 --copy-media
# or one cell:
python3 scripts/gen_delivery_geometry_matrix.py --only 624x350@24/1 --copy-media
```

## Local PMS ingest (parent runs — section 2 only)

Media root on host: `~/plex/media/movies/` (container `/data/movies`).
Server: `http://192.168.1.24:32400` · library **MiSTerPlex Tests** · section **2**.
Token: `$TOK` from lab file — **never commit or print**.

```bash
# 1) ensure files are present (generator --copy-media does this)
ls -1 ~/plex/media/movies/MiSTerPlex\ DeliveryGeom*

# 2) refresh section 2
curl -sS -o /dev/null -w 'refresh_http=%{http_code}\n' \
  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
echo "refresh true rc=$?"

# 3) enumerate until DeliveryGeom rows appear (poll ~5–30s)
curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" \
  > .agent-work/w-asset480/pms_after_delivery_geom.xml
echo "all true rc=$?"
python3 - <<'PY'
import xml.etree.ElementTree as ET
root = ET.parse('.agent-work/w-asset480/pms_after_delivery_geom.xml').getroot()
for v in sorted(root.findall('.//Video'), key=lambda e: int(e.get('ratingKey',0))):
    t = v.get('title') or ''
    if 'DeliveryGeom' in t or 'delivery_geom' in t.lower():
        print(f"rk={v.get('ratingKey')} dur_ms={v.get('duration')} | {t}")
PY
```

Cast by **ratingKey** after index. Prefer Direct Play so coded size == delivered
size (otherwise PMS may transcode and defeat the geometry probe).

## Related

- Full library inventory: `docs/FIXTURE_MANIFEST.md`
- Glass ID contract: `docs/glass_frame_id_contract.md`
- Playbook: `docs/PLAYBOOK_LOCAL_PMS_FIXTURES.md`
