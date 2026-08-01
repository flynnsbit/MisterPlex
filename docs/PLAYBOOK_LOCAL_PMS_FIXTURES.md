> **Canonical inventory:** [`docs/FIXTURE_MANIFEST.md`](FIXTURE_MANIFEST.md) (measured rates, luma hazards, bank_fit).

# Playbook — A/V sync & soak fixtures (local PMS only)

**PMS:** `http://192.168.1.24:32400` library section **2**  
**Ignore:** `192.168.1.122` (SHIELD), `plex.nevertrustaf.art`  
**Token:** `$TOK` (lab file only — never commit)  
**Device:** parent only. Agent does not ssh/cast.

## Do not use

| thing | why (name + derivation) |
|-------|-------------------------|
| PLXD `frames_done` | **vsync counter** on RBF `c5382bee`, not bank swaps — freeze can look healthy |
| PLXD `presents` / `drops` | ARM call/supply, not glass |
| PLXD `unaccounted` | `residual` printed twice (`media_player.cpp`) — not independent |
| Cast `disc_nyquist_*.mp4` for 240-vs-480 | H.264 kills ceiling; **vertical B2 already glass-proven** via w-instr even/odd DDR card |
| PMS `videoFrameRate` alone | always ffprobe the file (`r_frame_rate`) |
| Untrimmed soak series | startup/teardown bias; prior `p_ge50` class scores **UNSCORED** until re-measured trimmed |

**Device fact for marker design:** only **even** store rows reach glass today (parent 5/5 even/odd card). A/V fixtures use body y≥88 + even_row_paint ID.

## RatingKeys (section 2, measured after index)

| rk | title | use |
|----|-------|-----|
| **TBD** | **Bank480 FullBleed VRes AV 624×480 24fps 1200s** | **PRIMARY** unambiguous SAR=1:1 DAR=13:10 full-bleed + V-res instruments + A/V @2s |
| **TBD** | **Real BBB GlassAV 624×480 24fps 1200s** | real-content soak (full pixel fill; scan if missing) |
| **TBD** | Real BBB GlassAV 624×352 / 640×480 / 720×480 / 1440×1080 **90s** | geometry ladder (FORCE_SCALE / awkward sizes) |
| **23** | AudioID Glass 480p 24fps **60s** | quick A/V + checksum audio packets |
| **24** | AudioID … **audioPlus100ms** | instrument RED (expect ~+100 ms) |
| **22** | AudioID Glass 480p 24fps **1800s** | long FSK soak (synthetic body) |
| **20** | AVSync Glass 480p 24fps **600s** | flash↔beep offset 0 (synthetic) |
| **21** | AVSync Glass … **audioPlus100ms** | flash↔beep +100 ms |
| **13** | Glass OCRProof 480p 24fps **600s** | glass frame-ID / drops (synthetic) |

Media paths (pre-scan): `~/plex/media/movies/MiSTerPlex Real BBB GlassAV * (2026).mp4`  
Generator: `scripts/gen_real_bbb_avsync_soak.py` · report: `.agent-work/w-asset480/REPORT.md`

If rk missing, re-copy from `assets/avsync/` → `~/plex/media/movies/` and:

```bash
curl -sS "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
curl -sS "http://192.168.1.24:32400/library/sections/2/all?X-Plex-Token=$TOK" | rg "AudioID|AVSync|OCRProof"
```

Cast by **ratingKey** with your companion path to the MiSTer. Prefer Direct Play.

## Recommended runs

1. **Instrument RED/GREEN (w-avsync):** cast **24** (or **21**), expect offset ≈ +100 ms; then **23**/**20**, expect ≈ 0 (plus device bias you measure).  
2. **Long soak:** cast **22** (1800 s). **Mandatory trim:** drop first **30 s** and last **30 s** before stats (startup/teardown). Sample ARM CPU% concurrently (user requirement).  
3. **Glass drops only:** cast **13**; decode `G n=DDDDDD c=C` / bars — not PLXD drops.

## ffprobe every asset before trusting it

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,nb_frames,duration,profile,has_b_frames \
  -of default=noprint_wrappers=1 FILE
# expect: 624x480, r_frame_rate=24/1, profile=Constrained Baseline, has_b_frames=0
```

## Trimmed duration — minimum for stable estimates

Markers every **2.000 s**. After excluding head+tail **30 s** each:

| goal | math | minimum wall duration |
|------|------|------------------------|
| A/V offset median, ~≥100 pairs after trim | pairs ≈ (T−60)/2 ≥ 100 → T−60 ≥ 200 | **T ≥ 260 s** → use **rk20/21 (600 s)** |
| Drop rate SE ≲ 0.001 at p≈0.007 | n_frames ≳ p(1−p)/SE² ≈ 7000 → 7000/24 ≈ 292 s content + 60 s trim | **T ≥ 360 s** → use **rk13/20 (600 s)** |
| Clock drift 10 ppm as ≥18 ms cumulative | drift_ms = ppm×T×0.001 → 10×T×0.001 ≥ 18 → T ≥ 1800 | **T = 1800 s (rk22)** |

**Do not score untrimmed series** (rd-review / prior false result).  
**Ship defaults:** 600 s (offset + drops), **1800 s** (drift soak).

## Lock numbers to expect (file, not device)

See `docs/AV_LOCK_UNCERTAINTY.md`: post-AAC median error **≈ 0.15 ms** vs design 0 / +100. Device adds unknown bias — that is the measurement.

## Real-content non-bank ladder (indexed)

| rk | geometry | dur | title |
|----|----------|-----|-------|
| **29** | 624×352 | 90s | Real BBB GlassAV |
| **31** | 640×480 | 90s | Real BBB GlassAV |
| **32** | 720×480 | 90s | Real BBB GlassAV |
| **28** | 1440×1080 | 90s | Real BBB GlassAV |
| **30** | 624×480 | 1200s | Real BBB GlassAV (bank-sized long soak) |
| **18** | 624×352 | 360s | Real BBB GlassID |
| **19** | 720×480 | 596.5s | Real BBB GlassID (full BBB) |

All measured CB, no-B, 24/1, AAC 48k (host ffprobe). Not bank-matched except rk30.

## Rowcount 475 vs 480
Media on disk: `MiSTerPlex Rowcount Vernier 624x480 24fps 120s` — **scan for rk**. See `docs/rowcount_475_vs_480_power.md`.
