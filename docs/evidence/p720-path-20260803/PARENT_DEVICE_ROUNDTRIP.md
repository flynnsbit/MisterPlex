# Parent device round-trip kit — w-path (build-host only)

**Lane:** w-path · **Branch:** `w-path-720p` · **Worktree:**  
`/home/flynnsbit/Projects/MisterPlex-wt-path`  
**Status:** artefacts built/self-tested on host; **parent owns all device runs**  
(MiSTer powered down at authoring time).

Ship stance (unchanged): **640×360@30 honest · 960×540@24 detail · 960×540@30 UNSCORED**.

---

## 1) Per-frame timing harness (`:3219` work cost)

### What it measures

| Field | Definition |
|-------|------------|
| `work_us` | `pipe_read_wall + pixel_pad + ddr_present_total` |
| **Excluded** | A/V Hold / pacing sleep (deadline cost, not paced interval) |
| Stats | `n`, `mean_ms`, **`p50_ms`**, **`p95_ms`**, **`p99_ms`**, `max_ms`, `min_ms`, `sd_ms`, `p99_minus_mean_ms` |

Log line (session end and every 300 frames / present_profile tick):

```text
media: frame_cost tag=session_end n=… mean_ms=… p50_ms=… p95_ms=… p99_ms=… max_ms=… …
       unit=work_us_excl_pacing
```

### Overhead bound

| Path | Cost |
|------|------|
| `note()` | O(1) store into 8192-sample ring — **no alloc, no sort, no log** |
| Stamps | `steady_clock` (VDSO on Linux A9) once around read, once around pixel, DDR total already taken by publish |
| Dump | sort of ≤8192 samples **off hot path** only |
| Full `PRESENT_PROFILE` | heavier (CPU micros, per-syscall); **not required** for percentiles |

Design target: instrument ≪ 0.05 ms/frame when `FRAME_COST_LEDGER=1` alone.  
Do **not** enable full `PRESENT_PROFILE` for the p99 soak if you want minimal perturbation — ledger alone is enough.

### Conf (device `/media/fat/misterplex/misterplex.conf`)

```ini
# Required for harness
FRAME_COST_LEDGER=1
# Optional means breakdown (heavier):
# PRESENT_PROFILE=1

# Tier under test (pick one play session per tier)
DECODE=960x540
# DECODE=640x360
OSD_CONTROL=off
WEAK_BITRATE=2000
# 540 detail cadence:
# WEAK_MAX_FRAME_RATE=24
# 360 motion / unscored 540@30: leave max FR unset or 30 Extra
```

### Parent soak commands (device — you run)

After deploy (section 3), start one cast/play per tier ≥300 frames (~12 s @24, ~10 s @30), then:

```bash
ssh root@$MISTER_HOST 'grep -E "frame_cost |present_profile |MEASURED_DELIVERY|GENUINE_540_FAIL|GENUINE_360_FAIL|DECODE adopted|GEOM requested" \
  /media/fat/misterplex/misterplexd.log | tail -80'
```

**Record for each tier** (`540@24`, `360@30`, `540@30` unscored):  
p50 / p95 / p99 / max / mean / n from `tag=session_end`, plus run-to-run CV across ≥3 plays.

**Budget reference:** 24 fps → 41.67 ms; 30 fps → 33.33 ms.  
Verdict stays **UNSCORED** for 540@30 until device p99 is in hand — host mean noise was CV 4.56%.

### Host self-test

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-path
make -j"$(nproc)" build/test_frame_cost_ledger
./build/test_frame_cost_ledger; echo "true rc=$?"
```

---

## 2) Geometry + rate proof (one command per rung)

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-path
# Token file mode 0600; never commit; never argv-echo
# printf '%s' "$TOK" > "$HOME/.config/misterplex/plex.token" && chmod 600 ...

export PLEX_BASE="http://127.0.0.1:32400"   # or lab PMS
export PLEX_KEY="/library/metadata/2"      # HD 16:9
export PLEX_TOKEN_FILE="$HOME/.config/misterplex/plex.token"
export OUT_DIR="docs/evidence/p720-path-20260803/prove_ladder_host"

scripts/prove_ladder_delivery.sh 540       # expect 960x540 @ maxBR≥2000
scripts/prove_ladder_delivery.sh 360       # expect 640x360 @ maxBR≥1000
scripts/prove_ladder_delivery.sh 540-trap  # RED twin: maxBR=1500 → 720x404 trap
scripts/prove_ladder_delivery.sh all       # all three
# each ends with: true rc=0|1|77
```

| Rung | Request | maxBR | Expect (banner) | Exit |
|------|---------|------:|-----------------|------|
| `540` | 960×540 | 2000 | **960×540** | 0 match / 1 mismatch |
| `360` | 640×360 | 1000 | **640×360** | 0 / 1 |
| `540-trap` | 960×540 | 1500 | **≠960×540** (typ. 720×404) | 0 if trap fires |

Evidence: `ffmpeg_banner=…` + `RESULT … delivered_banner=WxH` under `OUT_DIR/<tag>/`.  
Daemon on-device equivalent greps: `MEASURED_DELIVERY … src=ffmpeg_banner`, `GENUINE_540_FAIL`.

---

## 3) Deploy artefacts and order

**Rule:** one menu bounce max; never thrash `load_core`.  
`DEPLOY_LOAD=none` (RBF copy only) or `menu` (preferred reload). Parent only.

### Order

1. **RBF** (if new fit) — copy only, then **one** menu deploy if load needed  
2. **Daemon** — stop → install → single start → **live md5 verify**  
3. Confirm conf (`DECODE`, `OSD_CONTROL=off`, `FRAME_COST_LEDGER=1`)  
4. Play / soak → greps above  

```bash
# --- host build ---
cd /home/flynnsbit/Projects/MisterPlex-wt-path
git rev-parse HEAD
make arm-plexd
ls -l build/arm/misterplexd
md5sum build/arm/misterplexd | tee build/arm/misterplexd.md5

# --- RBF (parent; example) ---
# DEPLOY_LOAD=none ./scripts/deploy_plex_core.sh
# or one menu: DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh

# --- daemon (parent) ---
./scripts/deploy_misterplexd.sh build/arm/misterplexd
# optional pin:
# DEPLOY_EXPECT_MD5=$(cut -d' ' -f1 build/arm/misterplexd.md5) \
#   ./scripts/deploy_misterplexd.sh build/arm/misterplexd
```

### Prove the **running** binary (not disk-only)

Deploy script already requires **disk md5 == host** and **`/proc/PID/exe` md5 == host** and `n_daemon==1`.  
Additionally:

```bash
ssh root@$MISTER_HOST '/media/fat/misterplex/bin/misterplexd --version'
# expect: misterplexd git_rev=<sha-like>

ssh root@$MISTER_HOST 'md5sum $(readlink -f /proc/$(pidof misterplexd)/exe)'
# must match host build/arm/misterplexd.md5
```

### Correct startup log (daemon fine)

```text
misterplexd: PRESENT_PROFILE=0 FRAME_COST_LEDGER=1
misterplexd: … DDR_YUV_FORCE_SCALE=1 …
media: DECODE adopted … 960x540 …   # or 640x360
… GEOM requested_pms=960x540 …
media: MEASURED_DELIVERY delivered_geom=960x540 … src=ffmpeg_banner …
# NOT: GENUINE_540_FAIL / GENUINE_360_FAIL
# After play: media: frame_cost tag=session_end …
```

| Symptom | Read as |
|---------|---------|
| No `misterplexd:` lines after deploy | daemon never started |
| `DECODE adopted` wrong tier / OSD overrides | conf / `OSD_CONTROL` |
| `GENUINE_540_FAIL` 720×404 | bitrate knee — raise `WEAK_BITRATE` ≥2000 |
| `MEASURED_DELIVERY` OK, black/wrong glass | fabric / RBF path (not daemon) |
| `frame_cost` absent | conf missing `FRAME_COST_LEDGER=1` or no successful DDR present |

### Conf snippet for paired 540 PLAYING test

```ini
DECODE=960x540
OSD_CONTROL=off
WEAK_BITRATE=2000
WEAK_MAX_FRAME_RATE=24
FRAME_COST_LEDGER=1
PRESENT=fpga
STREAM=0
```

360 motion: `DECODE=640x360`, `WEAK_BITRATE=1000`, no 24 cap.

---

## 4) Geometry contract (w-mem / w-scaler)

| Tier | ARM publish | I420 B/frame | Notes |
|------|-------------|-------------:|-------|
| 960×540 | storage identity | 777600 | SPS MB 544 cropped by ffmpeg; do not bank 783360 |
| 640×360 | storage identity | 345600 | exact-2× path on glass |
| 1280×720 | storage identity | 1382400 | DDR ABI must hold; fabric path separate |

**Do not change** `ddrFrameGeometryForFpgaPresent` in this lane without parent — w-path owns authoritative FFmpeg-side geometry after merge collision.

---

## 5) Files added this card

| Path | Role |
|------|------|
| `host/libmisterplex/frame_cost_ledger.hpp` | ring + p50/p95/p99 |
| `arm/misterplexd/media_player.cpp` | note work_us on DDR present OK |
| `arm/misterplexd/main.cpp` | `FRAME_COST_LEDGER` conf |
| `tests/unit/test_frame_cost_ledger.cpp` | unit + NEG pacing label |
| `scripts/prove_ladder_delivery.sh` | host e2e geometry + trap |
| this doc | parent runbook |
