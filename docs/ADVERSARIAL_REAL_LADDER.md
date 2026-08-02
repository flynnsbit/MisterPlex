# Adversarial real-content ladder (MILESTONE 4 / link / FORCE_SCALE)

**Problem:** promotion package used synthetic bank-exact soaks; prior
Real BBB library files are real picture but **~2.1–2.9 Mbit/s total** —
above the measured device path (**~107 KB/s ≈ 856 kbit/s**). Collapse
vs healthy on rk=9 confounds geometry, refs, bitrate, complexity.

**Master (glass ID already burned):** `/home/flynnsbit/plex/media/movies/MiSTerPlex Real BBB GlassAV 624x480 24fps 1200s (2026).mp4`

## Link assumption (parent-measured)

| quantity | value |
|----------|------:|
| path rate | ~107 KB/s ≈ **856 kbit/s** |
| audio pin | AAC 48 kHz **48 kbit/s** mono |
| healthy video budget | **≲ 700–750 kbit/s** |

## PRE-REGISTER (device cast — parent runs)

Single-run confirm/miss. If link is root cause:

| band | total bitrate | expected pfps | drops | supply_ratio |
|------|--------------:|---------------|-------|--------------|
| healthy | ≤ ~600 kbit/s | ≈23.5–24.0 | low | ≈0.97–1.00 |
| edge | ~600–850 | dip or unstable | moderate | ≈0.85–0.99 |
| collapse | ≥ ~900 | <<24 (e.g. ~13) | high | ≈0.7–0.9 diverging |

- **Geom arms @ 500k ref1:** all **healthy and mutually similar** if bitrate
  dominates; if 624x352/640/720/704 diverge from bank → FORCE_SCALE/geometry.
- **ref3 @ 500k:** healthy like ref1 if refs not causal; worse → refs load.
- **br_1800:** **collapse** (like rk=9 class). **br_400/500:** healthy.
- **long 900s @ 500k:** sustained healthy; no late cliff.

Publish misses.

## Fixed contract (all clips)

- Real BBB-derived full-frame picture + burned glass ID (from master)
- fps **24/1** (measured)
- H.264 **Constrained Baseline**, **level ≤ 3.0**, **B=0**
- AAC **48 kHz**, **48 kbit/s** mono (pinned)
- CBR-ish `-b:v = -maxrate`, bufsize 2×

## Measured table

| title | axis | W×H | fps | tgt_v | meas_v | total_k | refs | prof/L/B | nb | dur | bank | prereg | spec |
|-------|------|-----|-----|------:|-------:|--------:|-----:|----------|---:|----:|------|--------|------|
| `MiSTerPlex AdvReal 624x480 24fps 500kbit ref1 900s (2026).mp4` | long_soak_500_ref1 | **624×480** | **24/1** | 500 | **495.8** | **548.6** | **1** | Constrained Baseline/L30/B0 | 21600 | 900.000000 | favourable | healthy | YES |
| `MiSTerPlex AdvReal 624x480 24fps 500kbit ref1 300s (2026).mp4` | geom_bank_624x480 | **624×480** | **24/1** | 500 | **496.9** | **549.8** | **1** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | favourable | healthy | YES |
| `MiSTerPlex AdvReal 624x352 24fps 500kbit ref1 300s (2026).mp4` | geom_624x352 | **624×352** | **24/1** | 500 | **498.3** | **551.2** | **1** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | adversarial | healthy | YES |
| `MiSTerPlex AdvReal 640x480 24fps 500kbit ref1 300s (2026).mp4` | geom_640x480 | **640×480** | **24/1** | 500 | **496.7** | **549.6** | **1** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | adversarial | healthy | YES |
| `MiSTerPlex AdvReal 720x480 24fps 500kbit ref1 300s (2026).mp4` | geom_720x480 | **720×480** | **24/1** | 500 | **496.7** | **549.5** | **1** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | adversarial | healthy | YES |
| `MiSTerPlex AdvReal 704x396 24fps 500kbit ref1 300s (2026).mp4` | geom_704x396 | **704×396** | **24/1** | 500 | **497.8** | **550.6** | **1** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | adversarial | healthy | YES |
| `MiSTerPlex AdvReal 624x480 24fps 500kbit ref3 300s (2026).mp4` | refs_ref3_500 | **624×480** | **24/1** | 500 | **495.4** | **548.2** | **3** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | favourable | healthy | YES |
| `MiSTerPlex AdvReal 624x480 24fps 400kbit ref1 300s (2026).mp4` | br_400 | **624×480** | **24/1** | 400 | **397.3** | **450.1** | **1** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | favourable | healthy | YES |
| `MiSTerPlex AdvReal 624x480 24fps 800kbit ref1 300s (2026).mp4` | br_800 | **624×480** | **24/1** | 800 | **795.5** | **848.4** | **1** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | favourable | edge | YES |
| `MiSTerPlex AdvReal 624x480 24fps 1200kbit ref1 300s (2026).mp4` | br_1200 | **624×480** | **24/1** | 1200 | **1194.0** | **1246.9** | **1** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | favourable | collapse_risk | YES |
| `MiSTerPlex AdvReal 624x480 24fps 1800kbit ref1 300s (2026).mp4` | br_1800 | **624×480** | **24/1** | 1800 | **1790.3** | **1843.1** | **1** | Constrained Baseline/L30/B0 | 7200 | 300.000000 | favourable | collapse_risk | YES |

### Per-clip device prereg detail

| title | expected_pfps | expected_drops | expected_supply | note |
|-------|---------------|----------------|-----------------|------|
| `MiSTerPlex AdvReal 624x480 24fps 500kbit ref1 900s (2026).mp4` | ≈23.5–24.0 | low (<50/300s) | ≈0.97–1.00 | 15 min real soak under link — expect sustained healthy if 500k holds. |
| `MiSTerPlex AdvReal 624x480 24fps 500kbit ref1 300s (2026).mp4` | ≈23.5–24.0 | low (<50/300s) | ≈0.97–1.00 | If link-bound: match 500k bank arm. If FORCE_SCALE/ref fault: diverge. |
| `MiSTerPlex AdvReal 624x352 24fps 500kbit ref1 300s (2026).mp4` | ≈23.5–24.0 | low (<50/300s) | ≈0.97–1.00 | If link-bound: match 500k bank arm. If FORCE_SCALE/ref fault: diverge. |
| `MiSTerPlex AdvReal 640x480 24fps 500kbit ref1 300s (2026).mp4` | ≈23.5–24.0 | low (<50/300s) | ≈0.97–1.00 | If link-bound: match 500k bank arm. If FORCE_SCALE/ref fault: diverge. |
| `MiSTerPlex AdvReal 720x480 24fps 500kbit ref1 300s (2026).mp4` | ≈23.5–24.0 | low (<50/300s) | ≈0.97–1.00 | If link-bound: match 500k bank arm. If FORCE_SCALE/ref fault: diverge. |
| `MiSTerPlex AdvReal 704x396 24fps 500kbit ref1 300s (2026).mp4` | ≈23.5–24.0 | low (<50/300s) | ≈0.97–1.00 | If link-bound: match 500k bank arm. If FORCE_SCALE/ref fault: diverge. |
| `MiSTerPlex AdvReal 624x480 24fps 500kbit ref3 300s (2026).mp4` | ≈23.5–24.0 | low (<50/300s) | ≈0.97–1.00 | If link-bound: match 500k bank arm. If FORCE_SCALE/ref fault: diverge. |
| `MiSTerPlex AdvReal 624x480 24fps 400kbit ref1 300s (2026).mp4` | ≈23.5–24.0 | low (<50/300s) | ≈0.97–1.00 |  |
| `MiSTerPlex AdvReal 624x480 24fps 800kbit ref1 300s (2026).mp4` | ≈20–24 or dip | moderate | ≈0.85–0.99 |  |
| `MiSTerPlex AdvReal 624x480 24fps 1200kbit ref1 300s (2026).mp4` | <<24 (e.g. ~13) | high (hundreds+) | ≈0.7–0.9 diverging |  |
| `MiSTerPlex AdvReal 624x480 24fps 1800kbit ref1 300s (2026).mp4` | <<24 (e.g. ~13) | high (hundreds+) | ≈0.7–0.9 diverging |  |

## Parent PMS ingest (§2 only)

```bash
ls -1 /home/flynnsbit/plex/media/movies/MiSTerPlex\ AdvReal*
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
    if 'AdvReal' in t:
        print(f"rk={v.get('ratingKey')} dur_ms={v.get('duration')} br={v.get('bitrate')} fr={v.get('frameRate')} | {t}")
PY
```

PMS `frameRate`/`bitrate` are **claims** — trust ffprobe table above.
Prefer Direct Play. Agent does not touch the MiSTer.

## Reproduce

```bash
python3 scripts/gen_adversarial_real_ladder.py --copy-media \
  --master "/home/flynnsbit/plex/media/movies/MiSTerPlex Real BBB GlassAV 624x480 24fps 1200s (2026).mp4"
```

Generator: `scripts/gen_adversarial_real_ladder.py`
Probe: `docs/adversarial_real_ladder_probe.json`

## Related ladders

- Synthetic bitrate/ref/geom (no real picture): `docs/BITRATE_LADDER.md`
- Cadence/judder GT: `docs/CADENCE_DEFECT_LADDER.md`
- PromoScoreable (real but ~2.5 Mbit — **over link**): `docs/PROMO_SCOREABLE_FIXTURES.md`

## Indexed ratingKeys (section 2, measured after refresh)

| rk | title (PMS) |
|---:|--------------|
| **33** | MiSTerPlex AdvReal 624x352 24fps 500kbit ref1 300s (2026) |
| **34** | MiSTerPlex AdvReal 624x480 24fps 1200kbit ref1 300s (2026) |
| **35** | MiSTerPlex AdvReal 624x480 24fps 1800kbit ref1 300s (2026) |
| **36** | MiSTerPlex AdvReal 624x480 24fps 400kbit ref1 300s (2026) |
| **37** | MiSTerPlex AdvReal 624x480 24fps 500kbit ref1 300s (2026) |
| **38** | MiSTerPlex AdvReal 624x480 24fps 500kbit ref1 900s (2026) |
| **39** | MiSTerPlex AdvReal 624x480 24fps 500kbit ref3 300s (2026) |
| **40** | MiSTerPlex AdvReal 624x480 24fps 800kbit ref1 300s (2026) |
| **41** | MiSTerPlex AdvReal 640x480 24fps 500kbit ref1 300s (2026) |
| **42** | MiSTerPlex AdvReal 704x396 24fps 500kbit ref1 300s (2026) |
| **43** | MiSTerPlex AdvReal 720x480 24fps 500kbit ref1 300s (2026) |

PMS list endpoint returned `frameRate=None` on these rows at index time — **do not**
treat that as 0 or unknown asset rate. **Measured asset rate is 24/1** (ffprobe table).
