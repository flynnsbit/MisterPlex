# DP-Control asset + Decode-load ladder

**Parent 2026-08-02:** CBR bitrate ladder retired as session-level instrument.
PMS transcoder argv on rk36 showed `-maxrate 1527k` on a 397k source because
**our** `maxVideoBitrate` floor forced universal — **w-cpu-1 owns that fix**.
This lane does **not** change `plex_resolve.cpp:338-339`.

Assets still matter: once Part Direct-Play is possible, we need (1) a control
that is unambiguously acceptance-legal and (2) a ladder whose axis is **decode
work**, not source kbit (PMS rewrote every prior ladder’s delivered bits).

---

## 1. Acceptance ladder → encode parameter map

Quoted `validateWeakLadder` / product profiles (`plex_resolve.cpp` ≈326–342 and
`plexTranscodeProfiles` 480p row):

| # | Code constraint | DP-Control encode | Measured |
|---|-----------------|-------------------|----------|
| A | `videoCodec must be h264` | `-c:v libx264` | `codec_name=h264` |
| B | `audioCodec must be aac` | `-c:a aac` | `a_codec=aac` |
| C | `h264Profile must be baseline` | `-profile:v baseline` + `cabac=0` | **Constrained Baseline** |
| D | `h264Level must not exceed 3.0` (`>30` fails) | `-level:v 3.0` / `level=30` | **level=30** |
| E | 480p coded size in bank | `624x480` + `setsar=1/1` | **624×480**, SAR 1:1 |
| F | DDR max WxH (not exceeded) | same 624×480 | under max |
| G | *Universal-only* `maxVideoBitrateKbps >= 2000` for 480p | **N/A on Part DP** | floor is request-side (w-cpu-1); source video **~393 kbit** deliberately **below** path 1.15 Mbit |
| H | `videoQuality` / bitrate positive on weak ladder | N/A on Part | — |
| I | Decoder contract (product, not validateWeakLadder): **no B-frames** | `-bf 0` `bframes=0` | **has_b_frames=0** |
| J | Decoder contract: **CAVLC** (STREAM recon) | `cabac=0` `no-cabac=1` | SPS entropy 0 / CB |
| K | AAC 48 kHz stereo | `-ar 48000 -ac 2 -b:a 128k` | 48000 / 2 |
| L | Rate exact | `-r 24` `fps=24` | **r_frame_rate=24/1** |

**Profile/level as independent blockers (verified, not assumed):**

- Client `X-Plex-Client-Profile-Extra` / MiSTerPlex profile still advertise
  `video.profile=baseline` and `video.level` upperBound **30** for *universal*
  targets. That does **not** apply when `preferDirectH264` takes **Part**.
- Part path only requires metadata `videoCodec` H.264-like
  (`mediaVideoIsH264`) + Part key (`plex_resolve.cpp` directH264 branch).
- Therefore: **High/Main sources can still Part-DP** if preferDirect is on —
  but STREAM=1 host recon may sticky-skip CABAC / mishandle B-frames.
- DP-Control stays **Constrained Baseline L3.0 no-B ref1** so it is legal for
  **both** STREAM=0 FFmpeg DP and STREAM=1 recon.

**Remaining non-asset blockers for `transcoded=0` (parent/device):**

1. `PREFER_DIRECT_H264=1` **or** `STREAM=1` (otherwise always universal).
2. w-cpu-1 floor fix if any path still hits universal with inflated maxrate.
3. GEOM must quote `transcode=0` — host Part eligibility ≠ daemon chose Part.

Host eligibility (no device):

```bash
TOK=$(cat /tmp/local_tok.txt) ./scripts/prove_directplay_host.sh <rk_dp_control>
```

---

## 2. DP-Control asset (measured)

| field | value |
|-------|-------|
| **ratingKey** | **111** |
| title | `MiSTerPlex DP-Control 624x480 24fps 400kbit ref1 300s (2026).mp4` |
| coded | **624×480** SAR **1:1** |
| fps | **24/1** |
| profile / level | **Constrained Baseline** / **30** |
| B / refs | **0** / **1** |
| video kbit (ffprobe) | **~392.9** |
| audio | aac / 48000 / 2 |
| duration | **300 s** |
| content | Real BBB GlassAV head (same master as AdvReal) |
| generator | `scripts/gen_decode_load_ladder.py` |

**Pre-reg once DP proven:** `supply_iv ≥ 0.95`, pfps 23.5–24.5, drops low,
`measured=624x480`, `transcode=0`. If still `transcode=1` after floor+preferDirect
→ publish miss with resolve line (not an encode miss).

---

## 3. Decode-load ladder (fixed 624×480 @ 24/1, target **800 kbit** video)

**Axis is not bitrate.** All BBB rungs share the same master slice length and
CBR ~800k so wire bits are comparable under DP; tools/density change.

| rk | key | axis | profile | B | refs (SPS) | cabac | deblock | content | product_legal | pre-reg supply_iv | pre-reg pfps |
|---:|-----|------|---------|---|------------|-------|---------|---------|---------------|-------------------|--------------|
| **115** | cb_ref1_cavlc | baseline | CB | 0 | **1** | 0 | 1:0:0 | BBB | **YES** | ≥0.95 if DP/path ok | 23.5–24.5 |
| **116** | cb_ref3_cavlc | refs | CB | 0 | **3** | 0 | 1:0:0 | BBB | YES | may dip vs ref1 if DPB/MC | if healthy 23.5–24.5 |
| **117** | cb_ref5_cavlc | refs | CB | 0 | **5** | 0 | 1:0:0 | BBB | YES | ≤ ref3 if refs dominate | worse than ref1 if MC-bound |
| **119** | main_bf2_cavlc | bframes | Main | **2** | **≥2 (meas 4)** | 0 | 1:0:0 | BBB | **NO** | FFmpeg: vs baseline; recon UNSCORED | FFmpeg ~24 |
| **118** | high_cabac_ref1 | entropy | High | 0 | 1 | **1** | 1:0:0 | BBB | **NO** | FFmpeg ~baseline; recon skip risk | recon UNSCORED if CABAC |
| **112** | cb_deblock_off | deblock | CB | 0 | 1 | 0 | **0:0:0** | BBB | YES | ≥ baseline if filter was costly | ≥ baseline |
| **113** | cb_deblock_strong | deblock | CB | 0 | 1 | 0 | **1:-3:-3** | BBB | YES | ≤ deblock_off if filter-bound | ≤ deblock_off |
| **114** | cb_noise_dense | mb_density | CB | 0 | 1 | 0 | 1:0:0 | **noise** | YES | worst product-legal if residual-bound | most likely &lt;24 if decode-bound |

PMS `frameRate=None`, `videoFrameRate=24p` — asset truth **24/1**.

Titles: `MiSTerPlex DecLoad <key> 624x480 24fps 800k 180s (2026).mp4`  
Duration **180 s** each (within-run correlation is the instrument; n=1 session
is enough to feed w-instr, not to A/B session means).

### How to run (parent)

1. Deploy daemon with Part DP path live (`PREFER_DIRECT_H264=1` and/or floor fix).
2. Cast **product_legal** rungs only for FPGA/STREAM recon claims.
3. Cast Main/High only on **STREAM=0 FFmpeg** if measuring software decode cost.
4. Score **within-run** (w-instr), not session-mean A/B.
5. Host sampler beside each cast; `tc_max` must be 0 for DP claims.

### Discrimination

| if… | then… |
|-----|--------|
| ref1 healthy, ref3/ref5 degrade | DPB/MC / refFrames cost |
| deblock_strong ≪ deblock_off | in-loop filter cost |
| noise ≪ BBB ref1 at same kbit | residual/MB density |
| high_cabac fails only on STREAM=1 | entropy path / recon |
| main_bf2 fails only on STREAM=1 | B-frame / reorder |
| all product_legal healthy under DP | decode-tool hypothesis weak at 800k/624x480 |

---

## 4. Generator / refresh

```bash
python3 scripts/gen_decode_load_ladder.py --duration 180 --dp-duration 300 --copy-media
echo "gen true rc=$?"
TOK=$(cat /tmp/local_tok.txt)
curl -sS -o /dev/null -w 'refresh_http=%{http_code}\n' \
  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
echo "refresh true rc=$?"
```

Probe JSON: `docs/decode_load_ladder_probe.json`
