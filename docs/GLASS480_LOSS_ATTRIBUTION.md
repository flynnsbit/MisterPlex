# 480p glass frame loss — supply vs post-present split

**Parent hard result (pixel-verified):** 22 adjacent-capture +2 events / 1429 source
frames = **1.54%** display-side skips (~1 / 2.71 s). Grabber-drop killed via 24/30
advance ratio. Same window daemon: `frames−presents−drops=0`, `publish_misses=0`,
lifetime `drops=8` ⇒ **≥14 skips invisible** to every prior counter.

**Survivors after residual=0:** PRE-`frameIndex` supply **or** POST-present scanout.
This doc is the decision-complete runbook after supply instrumentation landed.

**Agent does not touch the device.** Parent deploys, captures, scores.
Fixtures for this RCA are **`frameRate=24.000`** — never assume 23.976.

---

## What residual alone cannot do

```
unaccounted = frames - presents - drops     # integer, resolution = 1 frame
```

| Residual cell | Blind to |
|---------------|----------|
| `unaccounted = 0` | frames **never produced** (never enter `frames`) |
| | **post-present** scanout (present already counted) |

`publish_misses=0` kills DDR publish as the primary story for the ≥14 invisible skips.

---

## New instrumentation (must be in the deployed binary)

| Field / line | Meaning | tag |
|--------------|---------|-----|
| `ffmpeg_out_frames=` on 1 Hz media line | last ffmpeg `-stats` `frame=N` | measured or **NO-DATA** |
| `media: supply_bucket ...` @ 1 Hz | Δframes/presents/drops/pm/unaccounted, `expected_frames`, `supply_gap`, `d_ffmpeg_out` | measured / derived |
| `media: supply_ledger ...` at teardown | `total_bytes % frame_bytes`, `frames_from_bytes` vs `frame_index`, `identity_ok` | measured |
| `ERROR SUPPLY_PIPE_IDENTITY_FAIL` | bytes≠frameIndex identity | measured |
| play path ffmpeg argv | `-stats -loglevel info` (not `-nostats` / error-only) | — |
| stderr pump | splits on **`\r` and `\n`** (ffmpeg stats use CR) | — |

Header math: `host/libmisterplex/supply_bucket.hpp` (unit: `test_supply_bucket`).

### CAN distinguish

| Stage id | Evidence |
|----------|----------|
| **PRE_FFMPEG_SUPPLY** | `d_ffmpeg_out` short vs wall×fps; `d_frames ≈ d_ffmpeg_out`; host residual flat |
| **PIPE_READ_SHORT** | `d_ffmpeg_out − d_frames ≥ HIT`; or `SUPPLY_PIPE_IDENTITY_FAIL` / `PIPE_*` |
| **PRE_FRAMEINDEX_SUPPLY** | wall `supply_gap ≥ HIT`, host flat, **ffmpeg_out NO-DATA** (cannot split decode vs pipe) |
| **POST_PRESENT_SCANOUT** | `supply_gap ≤ FLAT`, host flat, (ff gap ≤ FLAT if known), glass holes ≥ MIN |
| **HOST_MID / HOST_MID_PUBLISH** | `unaccounted` / `publish_misses` growth ≈ glass |

### CANNOT distinguish (say so — do not claim)

- Inside **POST_PRESENT**: DDR bank select vs RTL scanout vs HDMI PHY / grabber path beyond parent’s ratio kill.
- Which PMS/transcode stage inside **PRE_FFMPEG** without PMS-side counters.
- A single whole-session average of `supply_gap` at 1.54% over minutes — use **1 Hz buckets**.

---

## Thresholds (must resolve ~15–22 holes)

| Name | Value | Role |
|------|------:|------|
| `HOST_GAP_FLAT` / `SUPPLY_GAP_FLAT` | **2** | ≤2 **cannot** explain 15–22 glass holes |
| `HOST_GAP_HIT` / `SUPPLY_GAP_HIT` | **10** | ≥10 **can** carry the signal |
| `PAIR_TOL` | **5** | \|gap − glass_holes\| |
| `GLASS_LOSS_MIN` | **3** | below → do not attribute |
| `MIN_STEADY_S` | **60** | after T0=10 s |

**Resolution proof:** counters are integers (1 frame). FLAT≤2 and HIT≥10 leave
**(3..9)=AMBIGUOUS** — never collapsed into 0 or 15. Self-tests lock this:

```bash
make "$(pwd)/build/test_supply_bucket" && ./build/test_supply_bucket; echo "true rc=$?"
python3 tools/analyze_glass480_stage.py --self-test; echo "true rc=$?"
```

---

## Parent soak commands (after deploy of supply binary)

```bash
# 1) Confirm binary emits supply fields (first 30s of play is enough)
rg -n "ffmpeg_out_frames=|supply_bucket|supply_ledger|SUPPLY_PIPE|MEASURED_DELIVERY" DAEMON.log | head
# FAIL instrument if every media line has ffmpeg_out_frames=NO-DATA after wall_s>15
# (stats CR parse broken or -stats missing) — that is NO-DATA, not POST.

# 2) Per-second ledger (1.54% ≈ 0.37 skip/s — resolvable per bucket)
rg "supply_bucket" DAEMON.log | awk '
  { for(i=1;i<=NF;i++) if($i~/^supply_gap=/) g=$i; if($i~/^d_frames=/) f=$i;
    if($i~/^d_ffmpeg_out=/) e=$i; if($i~/^wall_s=/) w=$i; }
  { print w, f, e, g }'

# 3) Stage decision (glass_holes = parent OCR ABSENT count in same window)
python3 tools/analyze_glass480_stage.py \
  --log DAEMON.log --glass-holes N \
  --fps-num 24 --fps-den 1 --t0-s 10
echo "true rc=$?"   # 0=decided 2=AMBIGUOUS 77=NO-DATA — 77 is never PASS
```

### Pre-register (≥90 s, skip first 10 s, one `session_epoch`)

| Field | PASS band (steady) | FAIL |
|-------|--------------------|------|
| `session_epoch` | **one** | change mid-window |
| `PIPE_*` / `SUPPLY_PIPE_IDENTITY_FAIL` | **absent** | any → PIPE |
| `ffmpeg_out_frames` | numeric after warm-up | stuck NO-DATA after 15 s |
| `Δdrops` (wall≥10) | **≤2** (lifetime may be 8) | ≥10 unexplained in window |
| `Δpublish_misses` | **0** | ≥10 → HOST_MID_PUBLISH |
| `host_gap` / `d_unaccounted` sum | **≤2** | ≥10 → HOST_MID |
| `sum supply_gap` over steady | see stage table | — |
| `av_servo_setpoint_ms` | **−lead** | mismatch |
| `av_servo_margin_ms` | **∈ [0, 80]** | sustained <0 |
| `av_drift_ms` | near −lead | **servo only — not lipsync** |

### Falsifiers (the point of the soak)

- Claimed **POST_PRESENT**, but `sum supply_gap ≥ 10` ≈ glass → **FALSIFIED** (PRE supply).
- Claimed **PRE_FFMPEG**, but `d_ffmpeg_out ≈ expected` and `d_frames ≈ d_ffmpeg_out` with glass≥10 → **FALSIFIED** (POST or other).
- Claimed **PIPE_READ_SHORT**, but `identity_ok=1` and `d_frames ≈ d_ffmpeg_out` → **FALSIFIED**.
- Claimed **DDR publish**, `publish_misses_delta≤2` while glass≥10 → **FALSIFIED**.
- glass≥10 and `AMBIGUOUS` → **incomplete**, not PASS.

**Model under test after parent 22-skip result:** residual=0 + pm=0 leaves PRE vs POST.
Instrumentation does **not** pre-declare which; the soak decides.

---

## D2 — A5 falsifier (setpoint tracking, **not** lipsync)

```text
MISTERPLEX_AV_PRESENT_LEAD_MS=<int>   # env override; conf file not written
```

Startup must show `AV_PRESENT_LEAD_MS=env:20` (or `env:40`) and conf-not-modified banner.

```bash
CONF=/media/fat/misterplex/misterplex.conf
cp -a "$CONF" "/media/fat/misterplex/misterplex.conf.bak_lead_$(date +%Y%m%d%H%M%S)"
MISTERPLEX_AV_PRESENT_LEAD_MS=40 ./misterplexd ...   # arm A ≥70 s
MISTERPLEX_AV_PRESENT_LEAD_MS=20 ./misterplexd ...   # arm B; conf bytes identical
# restore only if something wrote conf:
# cp -a "$BACKUP" "$CONF" && cmp -s "$BACKUP" "$CONF" && echo RESTORE_OK
```

| Check | PASS | FAIL |
|-------|------|------|
| setpoint A/B | **−40** / **−20** | else |
| median av_drift B−A | **∈ [+12, +28] ms** | outside |
| conf cmp | **identical** | any diff |
| lipsync from this | **forbidden** | claiming lipsync OK |

PASS proves the metric **tracks the setpoint**. Grabber remains lipsync GT.

---
## Reference

- `host/libmisterplex/supply_bucket.hpp`, `frame_ledger.hpp`, `av_clock.hpp`
- `arm/misterplexd/media_player.cpp` — stats parse, 1 Hz bucket, teardown ledger
- `tools/analyze_glass480_stage.py`
- Poison guard for retracted sep constant: `63b98803`
