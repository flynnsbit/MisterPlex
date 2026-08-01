# Glass 0.70% loss — G1–G4 (w-geom)

Branch tip at write: see commit. No device. Source + host gates only.  
Parent measurement: **4/568 = 0.704%** missing source indices at HDMI on 480p, steady state, drops flat.

Load-bearing prior: `861ae49c` — identical DDR canvas **449280 B** both tiers.

---

## G1 — Predicted 240-tier loss rate (PRE-REGISTERED)

### Model
Canvas/byte count are **tier-identical** (`ddrFrameGeometryForFpgaPresent` ignores DECODE).  
If glass loss were **geometry/byte-accounting**, 240p loss rate would match 480p.  
If loss is **decode/CPU headroom**, 240p should be **measurably lower**.

Host product FORCE_SCALE total CPU (x86, `test_force_scale_sws_cost`, tag=measured):  
`RATIO_624_over_320 = 1.325` (624 total > 320 total; decode-dominated).  
Device prior: ~166/200 %onecpu at 240p → ~34 points headroom. Nonlinear near ceiling: a 32% relative ffmpeg cost increase can move from “rare stall” to “~1/6 s miss” without linear scaling of loss rate.

### Prediction (falsifiable)

| ID | Metric | Predicted band | PASS | FAIL (kills branch) |
|---|---|---|---|---|
| **P240** | Steady-state glass loss rate @240p, same fixture class, same 90 s window method (capture period < source period), **after startup** (exclude first ~8 s) | **0.00% – 0.20%** | measured ≤ 0.20% (≤ ~1 miss / 568) | measured ≥ **0.40%** → **decode-cost NOT cause**; look tier-common (bank-select / never-produced) |
| **P480_reconfirm** | 480p glass loss same method | **0.40% – 1.20%** | within band | outside → method/fixture changed |
| **P_ratio** | loss_480 / max(loss_240, 0.05%) | **≥ 2.0** if decode-cost | ratio ≥ 2 | ratio ∈ [0.7, 1.3] → **tier-independent** |

**Point estimate (not a band):** 240p **≈ 0.00–0.10%** (0–1 frames / 90 s @24.000).  
**If 240p loss ≡ 480p (~0.70%):** eliminate decode-cost branch **entirely** — geometry already eliminated by identical canvas; next is bank-select / ffmpeg never-emit / scanout.

**Do not assume 23.976.** T_src = 1000/24 = **41.666… ms** (`frameRate="24.000"`).

---

## G2 — Byte accounting end-to-end

### What the pipe does (quoted)

- Reader always fills **exactly** `frameBytes = rawVideoFrameBytes(Yuv420p, coded_w, coded_h)` = **449280** (`media_player.cpp:3166-3169`, `3714-3807`).
- `got < frameBytes` → `rawVideoTerminalSignal(..., shortRead=true)` → **always true** (`av_clock.hpp:643-645`) → **break session** with log `media: short read got=…` (`3814-3827`). **Not** a mid-stream silent discard.
- EOF remainder: session end logs `pipe_align ok` iff `totalBytes % frameBytes == 0` (`4148-4168`). **arm/ DOES call** `rawPipeDesynced` at teardown (`4152-4154`) — parent claim “only unit test” is **false for EOF**; it is still **not** a per-frame mid-stream check.
- Under product FORCE_SCALE Always, vf pads to **624×480** → producer_bytes == reader_bytes → `rawPipeDesynced` false (`ffmpeg_vf.hpp:179-185`, gate D3).

### Verdict on “partial-frame discarded → missing HDMI index”

| Claim | Status |
|---|---|
| Mid-stream short read continues as garbage/skip | **ELIMINATED** — shortRead is terminal (D1 `true rc=0`) |
| Long-run non-integer multiple of 449280 without shortRead log | **ELIMINATED** if `pipe_align ok` at end; if `PIPE_BYTE_MISALIGN` log present, opposite |
| Sparse 0.7% holes from phase desync (producer≠reader) | **ELIMINATED on FORCE_SCALE=1 product path** (D3); would also **shear** continuously, not 4 discrete IDs with intact neighbors |
| End-of-session one short frame | Possible at EOF only; not 4 interior indices 2491…2892 |

**Parent command (byte proof on the 90 s soak log):**
```bash
grep -E 'PIPE_BYTE_MISALIGN|pipe_align ok|short read|PIPE_DESYNC|MEASURED_DELIVERY' DAEMON.log
# PRE-REGISTER:
#   B1: expect exactly one "pipe_align ok" with total_mod_frame=0, shortRead=0
#   B2: expect ZERO "PIPE_BYTE_MISALIGN" and ZERO "PIPE_DESYNC=1"
#   B3: MEASURED_DELIVERY* bytes path consistent with 624x480 (449280)
# FAIL B1/B2 → reopen byte-accounting; PASS → mechanism eliminated for that session
```

---

## G3 — Where a decoded frame dies without `drops++`

`frameIndex` increments **only after** a full `frameBytes` read (`3865`), **before** present decision.

### Death points after `frameIndex++` that do **not** increment `drops`

| # | Site | Code | Counted as | Glass effect |
|---|---|---|---|---|
| **M1** | `presentCleanFrame` → `publishDdrFrame` / `sendDdrFrame` returns false | `media_player.cpp:3485-3515` (publish_miss log); `fpga_spi.cpp:1442-1479` bank-select Drop | **`publish_misses++`**, residual++ | Prior bank holds → **missing source index** at HDMI (repeat then jump) |
| **M1a** | PLXD bank-select: `swap_pending` / `no_free` / `free_eq_disp_stale` / `await_display_ack` until **50 ms** then Drop | `ddr_bank_release_select.hpp:66-80`; `kPlxdPollMaxIters=50` (`fpga_spi.cpp:1364`) | same M1 | 50 ms > T_src 41.67 ms @24.000 → **can drop one frame per stall** without pacedrop |
| **M1b** | Other sendDdrFrame false: plan mismatch, cache clean, kick fail | `fpga_spi.cpp:1323+` | M1 | same |
| **M2** | `stop_` / `paused_` during hold loop breaks without Drop | `3957-3958` | neither drops nor present (frameIndex already ++) | residual++; **not** publish_miss unless present attempted |
| **M3** | Overlay path `presentCleanFrame(..., countPresent=false)` | `3686-3687` | no counters | N/A for playback identity |

### Death **before** `frameIndex` (daemon residual **blind**)

| # | Site | Effect |
|---|---|---|
| **F1** | ffmpeg `fps=N/D` filter drops/dupe before raw pipe | Source counter never on pipe; glass miss vs asset; **unaccounted=0** |
| **F2** | ffmpeg cannot keep real-time → fewer output frames | same as F1 |
| **F3** | shortRead terminal | ends session; log present |

### Pacer path (increments `drops` — parent said steady drops flat ⇒ not this for the 4)

| # | Site | Code |
|---|---|---|
| **P1** | `avDecide` → `AvAction::Drop` | `3986-4014`; default `maxDropRun=1`, `dropMs=80` |

### Discriminator table (parent 90 s soak)

| Mechanism | `drops` Δ steady | `publish_misses` | `unaccounted` | glass miss vs source |
|---|---|---|---|---|
| Pacer Drop | = glass miss | 0 | 0 | yes |
| Bank-select / publish fail (**M1**) | 0 | = glass miss | = glass miss | yes |
| ffmpeg never emitted (**F1/F2**) | 0 | 0 | 0 | yes |
| Byte desync | usually catastrophic | varies | maybe misalign log | continuous garbage, not sparse |

Parent’s **drops flat + sparse missing indices** ⇒ **P1 eliminated for those 4**.  
Remaining: **M1** (daemon-visible) vs **F1/F2** (daemon-blind).

New observability (this commit): **every** publish miss logs  
`media: publish_miss wall_s=… publish_misses=… residual=… err=… tag=measured`  
so parent can pair wall_s with missing indices 2491/2539/2740/2892.

---

## G4 — Pre-registered PASS/FAIL bands (90 s steady soak)

Assume ~24.000 fps, steady window ~90 s after t0≥8 s ≈ **2160** source frames if full rate; parent’s 568 may be OCR-visible subset — **scale bands to observed N**.

Let `N` = number of distinct source counters expected in window; `L` = glass missing count; `rate=L/N`.

### On 480p session (reconfirm + daemon)

| ID | Signal | PASS band | FAIL / meaning |
|---|---|---|---|
| **U480** | `unaccounted` (= residual) at end of window from 1 Hz / session end | **{0} or {L}** only | other values → third death class |
| **M480** | `publish_misses` Δ in window | **PASS-M1:** `publish_misses == L` (±0) and `unaccounted == L` and dropsΔ==0 → **bank-select/publish** | **PASS-F:** miss==0 and unaccounted==0 and L>0 → **ffmpeg never-emitted** |
| **D480** | drops Δ steady | **0** for the L misses (already parent) | if dropsΔ==L → pacer (contradicts prior) |
| **A480** | `pipe_align ok` | required | MISALIGN reopens G2 |

### On 240p session (G1)

| ID | Signal | PASS (decode-cost lives) | FAIL decode-cost |
|---|---|---|---|
| **L240** | glass rate | **0.00%–0.20%** | **≥0.40%** |
| **U240/M240** | unaccounted / publish_misses | follow same M1 vs F table at lower L | tier-common M1 if miss rate ≈480p |

### Numeric example for N=568

| | Predicted |
|---|---|
| 480p L | 2–7 (reconfirm 4) |
| 480p unaccounted if M1 | **4** (or =L) |
| 480p publish_misses if M1 | **4** |
| 480p unaccounted if F1 | **0** |
| 240p L | **0–1** (rate ≤0.20%) |
| 240p L if tier-common | **3–5** (~0.70%) |

### Parent commands

```bash
# After deploy daemon with publish_miss wall_s log:
# 1) 480p 90s glass ledger (existing) + daemon log
grep -E 'publish_miss wall_s=|A/V resync drop|pipe_align|PIPE_|session end|frames=' LOG

# PRE-REGISTER before open:
#   If 4 glass misses and 4x "publish_miss wall_s=" with err containing bank-select/STALL
#      → M1 CONFIRMED; geometry/byte-accounting CLOSED
#   If 4 glass misses and publish_misses=0 unaccounted=0 pipe_align ok
#      → F1/F2 (ffmpeg never produced); geometry CLOSED; next is decode/fps filter CPU
#   If pipe_align fails
#      → G2 REOPEN (I was wrong)

# 2) 240p same fixture method — score L240 against 0.00–0.20% band
```

---

## Gates (host)

| Gate | rc |
|---|---|
| `test_glass_loss_death_points` | **0** D1–D6 |
| `test_geom_frame_cost` | **0** (prior) |
| unit-rollcall | **0** after Makefile wires |

## Misses published

1. Prior H1 on scale-only ranking inverted on totals (already in 861ae49c report).  
2. Parent “rawPipeDesynced only unit test” — **corrected**: EOF path in arm calls it; still not mid-frame.  
3. If parent finds publish_misses=0 with glass L=4, my leaning toward M1 as “largest remaining daemon-visible” is a **miss** → F1 wins.

## ARM change

`media_player.cpp`: log **every** `publish_miss` with `wall_s`, `residual`, `err=` (was every 30th summary only). No RBF. No FORCE_SCALE change.
