# RESULT — device-local 480p drops: within-run present_window instrument

**Lane:** w-cpu  
**Branch:** `w-cpu-suspend-silicon-pin`  
**Binary md5:** `a6241730d36d4d935131ae7634feaec7` (`build/arm/misterplexd`)  
**Status:** INSTRUMENT READY — not a drop fix. Parent must capture 1 Hz lines on a degraded run.  
**Live device:** leave `ea643e99` until parent chooses to deploy this tip.

---

## 1. What the parent degraded run already implies (quoted math, no guess)

Parent session end:
```
frames=5011 vfps=20.0 pfps=18.6 audio_s=209.1 wall_s=249.8
drops=356 supply_ratio = 209.1/249.8 = 0.837  fps=24/1
```

| Observable | Source meaning (code) | This session |
|---|---|---|
| `frames` / `vfps` | fully assembled raw frames / wall | 20.0 vs 24 → production short |
| `presentCount` / `pfps` | counted presents after pacer | 18.6 < vfps → present loss after assemble |
| `drops` | **only** `avDecide` → `AvAction::Drop` (`media_player.cpp` drop path; `av_clock.hpp`) | 356 deliberate skips |
| `supply_ratio` | audio PCM seconds / wall; audio pump paces same ffmpeg as video | 0.837 |

### Can stalled reader AND starved decoder both produce supply=0.837?

**Yes — both map to SHARED_FFMPEG_THROTTLE** (`present_window.hpp` `supplyRatioImplies`):

```text
if (supply_ratio < 0.95 && prod < 0.95) return "SHARED_FFMPEG_THROTTLE";
// prod = vfps/content_fps = 20/24 ≈ 0.833 ≈ supply 0.837
```

Quoted path coupling:
- Video reader and audio pump share one ffmpeg process (`media_player` audioPump + rawvideo pipe).
- Slow video consume (decode/scale CPU **or** DDR publish backpressure into the pipe) stalls ffmpeg → audio pump also advances slowly → `supply_ratio < 1` **and** `vfps < content_fps`.
- **Pure pacer-only** at full decode would keep reading ~24 fps while dropping presents → expect `supply_ratio ≈ 1` and `vfps ≈ 24`, `pfps` low. **That does not match 0.837 / vfps 20.**

So parent data already **falsifies pure H-PACER-only at full rate**. It does **not** yet split H-READ vs H-DDR vs decode-CPU inside SHARED_FFMPEG_THROTTLE — that is why 1 Hz windows exist.

`pfps (18.6) < vfps (20.0)` with drops=356 is still real: after frames are assembled, pacer Drop + any present failures widen the gap. Window `d_drops` vs `ddr_*` vs `read_sleep` separates that.

---

## 2. Where time can go after a decoded frame (source map)

| Stage | Code | Observable when PRESENT_PROFILE=1 |
|---|---|---|
| Pipe fill / EAGAIN sleep | raw read loop in `media_player.cpp` | `read_sleep_us_f`, `read_eagain_f`, class **H-READ** |
| A/V Hold (video ahead) | `avDecide` → Hold → 2 ms sleep | `d_holds`, `pacing_wait_us_f`, **H-HOLD** |
| A/V Drop (video behind > dropMs) | `avDecide` → Drop; `maxDropRun` | `d_drops`, **H-PACER** |
| Overlay / FB / pixel | `presentCleanFrame` | legacy path (in ddr split secondary) |
| DDR publish | `publishDdrFrame` → `sendDdrFrame` (memcpy, cache clean, PLXD bank wait, doorbell, prep/post wait) | `ddr_total_us_p`, `ddr_copy_us_p`, `ddr_prep_wait_us_p`, `ddr_plxd_poll_us_p`, **H-DDR** |

Off by default: `PRESENT_PROFILE` conf / env → `presentProfile_`. When false, profile branches are not taken (no 1 Hz emit; hold counter only under profile).

---

## 3. Instrument shipped (this commit)

- `host/libmisterplex/present_window.hpp` — classifier + line format + supply_ratio helper  
- `tests/unit/test_present_window.cpp` + Makefile + rollcall  
- `media_player.cpp` — each ~1 s media log tick emits:
  ```
  media: present_window wall_s=… class=H-* d_frames=… d_presented=… d_drops=… d_holds=…
         cum_drops=… av_drift_ms=… read_sleep_us_f=… read_wall_us_f=… read_eagain_f=…
         pacing_wait_us_f=… ddr_total_us_p=… ddr_copy_us_p=… ddr_prep_wait_us_p=…
         ddr_plxd_poll_us_p=… wall_us=…
  ```
  plus a short `present_profile_ddr_split` line when presents > 0.

Host gates (this tree):
```
test_present_window: OK  true rc=0
test_main_session_suspend: OK  true rc=0
test_main_guard: OK  true rc=0
test_ffmpeg_stderr: OK  true rc=0
UNIT_ROLLCALL_OK
make arm-plexd true rc=0
md5 a6241730d36d4d935131ae7634feaec7
strings: present_window, H-READ, H-DDR, H-PACER, PRESENT_PROFILE
```

---

## 4. PRE-REGISTRATION (before parent runs)

Degraded window signatures (1 s wall ≈ 1e6 µs). Publish miss if class disagrees with numbers.

| class | PRE_REG look | Implies next action |
|---|---|---|
| **H-READ** | `read_sleep_us` / wall ≥ 0.25 and > ddr | pipe empty / ffmpeg slow produce (decode+scale) |
| **H-DDR** | `ddr_total_us` / wall ≥ 0.25 | publish path; inspect `ddr_copy` vs `prep_wait` vs `plxd_poll` |
| **H-PACER** | `d_drops/d_frames` ≥ 0.05, waits low | clock policy / drift; alone cannot explain supply 0.837 |
| **H-HOLD** | `pacing_wait_us` / wall ≥ 0.25 | video ahead of audio clock |
| **H-BALANCED** | no bucket ≥ thr | multi-factor; use ddr_split + read_wall |

**Session-level PRE_REG for a bad rk36-class run (if event hits):**
- Majority of seconds while `cum_drops` rising: **H-READ** or **H-DDR** (not H-PACER-only).
- `d_frames` per second clusters near ~20 not 24 during drop storms.
- When healthy (supply_iv≈0.999): class **H-BALANCED** or mild **H-HOLD**, `d_drops≈0`.

**Miss rule:** if class is H-PACER while `read_wall_us_f` ≈ frame period and `ddr_total` small and supply still 0.84 → classifier thresholds wrong; report and retune from data (do not invent mechanism).

---

## 5. Parent commands (host does NOT touch device)

### A. Deploy tip (optional — daily driver; only when ready)

Stage + atomic replace using parent’s existing verified recipe (md5 `a6241730…` before/after).  
Restore path: prior known-good `ea643e99` backup.

Conf for capture only (restore after):
```
PRESENT_PROFILE=1
SUSPEND_MAIN_DURING_PLAY=0   # keep baseline unless intentionally testing suspend
```
Do **not** leave PRESENT_PROFILE=1 as user default after the capture.

### B. Capture one long cast (rk36-class 624x480; ≥3–4 min so intermittent ~25% can appear)

After stop, pull log and classify distribution (parent machine):
```bash
# On device log file path parent already uses; example filter:
grep 'present_window' /path/to/misterplexd.log | tee present_window_rk36.txt
grep 'present_profile_ddr_split' /path/to/misterplexd.log | tee present_ddr_split_rk36.txt
grep 'media: frames=' /path/to/misterplexd.log | tail -5

# Class histogram (host):
awk '/present_window/ {
  for(i=1;i<=NF;i++) if($i ~ /^class=/) { c=$i; sub("class=","",c); h[c]++ }
} END { for (k in h) print h[k], k }' present_window_rk36.txt | sort -nr

# Correlate drop storms: windows with d_drops>0
awk '/present_window/ && /d_drops=[1-9]/' present_window_rk36.txt | head -40
```

Capture session totals (same as before): last `media: frames=` line → supply_ratio, vfps, pfps, drops.

### C. Safety restore
```
PRESENT_PROFILE=0   # or remove key
# conf md5 byte-identical to pre-test backup
# daemon back to ea643e99 if tip not kept
```

### D. What to paste back to w-cpu
1. Full class histogram  
2. 20–40 `present_window` lines from a high-`d_drops` region  
3. Matching `present_profile_ddr_split` lines  
4. Session end `media: frames=` line  
5. `true rc=$?` of deploy/md5 checks  

---

## 6. Secondary (still open): ce727a43 zero-frame RCA

- Proven: tip stderr pump `if (!g.ok) continue` can swallow fatals after banners (`ffmpeg_stderr.hpp` + `test_ffmpeg_stderr`).  
- **Exact** zero-frame fatal line for `ce727a43`: still **unknown** without a tip-class binary that logs Diagnostics. Do not redeploy `ce727a43` to daily driver.

---

## 7. Explicit non-claims

- Does **not** fix 480p drops.  
- Does **not** ship LINK_CAP / bitrate floor as drop cure (parked).  
- Does **not** assert H-READ vs H-DDR until parent histogram exists.
