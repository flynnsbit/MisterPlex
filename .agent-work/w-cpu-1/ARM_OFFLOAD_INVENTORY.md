# ARM → fabric offload inventory (w-cpu)

**Lead (what just finished):** MiSTer Main idle ~100% is **stock `poll(...,0)`** except Menu∧FB
(`timeout=25`); not Plex DDR. Prefer **Plex-scoped poll timeout=5** over default SUSPEND.
Soak CPU sampler stamps RBF+daemon md5 + `decode_src`. B2 geometry loglevel work **dropped**
(live already has `measured_delivery`). 240p pays ARM scale; 480p `identity_skip` — daemon
flat @ 449280 B/bank both tiers.

**This doc:** ranked ARM work units for FPGA/BRAM/DDR offload.  
**Tags:** `measured` = parent or archived on-device with method; `caller-supplied` = conf/argv;
`ESTIMATED` = model from source/ms buckets — **not** a live %.  
**Baseline (parent, measured, 240p DDR, exe-resolved):** MiSTer **83.0** (idle **100.0**),
ffmpeg **62.9** → **38.5** `fast_bilinear`, misterplexd **18.8**.  
**Artifact pair for that table:** parent-owned (quote with RBF+daemon when citing).  
**Headroom ban:** never `200 − accounted`. Main is elastic. Prefer H1=ffmpeg+daemon and
schedstat runq wait.

**Fit budget (caller-supplied from parent):** ALM 23585/41910, **M10K 465/553 (88 free)**,
DSP 44/112. Binding = M10K. `decode_stub` reclaim target ~9217 ALM + 268 M10K (w-fit-1).

---

## Ranked inventory (highest product value first)

| # | Work unit | Who burns it | %onecpu / cost | Offloadable? | Fabric/BRAM/DDR cost | Blocker today |
|---|-----------|--------------|----------------|--------------|----------------------|---------------|
| **1** | **MiSTer Main busy-poll** (`poll` timeout=0) | `/media/fat/MiSTer` | **83–100 idle, 76–87 play** `measured` (parent). Elastic scavenger | **Not fabric** — Main userspace | **0** FPGA | Stock Main; lab `timeout=5` patch unshipped; SUSPEND default OFF |
| **2** | **H.264 decode (ffmpeg)** | ffmpeg | Live 240p **38.5–62.9** `measured`; 480p **64.2** `measured`. FEED decode_null **21.56 ms/f wall** @624×480 `measured` (archived W-FEED; asset must ASSET_OK) → **ESTIMATED ~50 %onecpu** if that wall were exclusive @24 fps (`ms/f × fps / 10`) | **Yes — hard** (bitstream → fabric decoder) | **Large**: CABAC/residual/IDCT/recon — **M10K heavy**; needs `decode_stub` reclaim first (w-fit-1 → ~356 free M10K class) | Phase-3 decode roadmap; no product decoder presents yet (`Plex.sv` decode_stub cannot present product pixels) |
| **3** | **Scale/pad (ffmpeg swscale)** | ffmpeg | **CONTESTED — see §A**. 240p: full upscale 320×240→~618×480+pad `arm_rescale=1` `caller-supplied` path. 480p native: `identity_skip=1` → **~0 scale**. Parent cliff: `fast_bilinear` **−24.9 %onecpu (−39%)** vs default `measured`. FEED **native** scale delta only **2.95 ms/f wall** `measured` | **Yes — w-geom fabric scaler** (do not design here) | Line/store buffers in M10K/BRAM; w-geom owns sizing | Synthesis-fixed store **624×480** forces upscale when delivery is 240p; horizontal unique-col timing also constrained (`clk_sys` 20 MHz class) |
| **4** | **DDR frame push** (memcpy + dcache clean + doorbell) | misterplexd | FEED product present **10.41 ms/f wall / 4.92 ms/f CPU** `measured` (archived). Microbench copy ~7.2 ms/f wall `measured`. Live daemon total **18.8–25.6** `measured` includes pace+overlay+misc — **DDR slice ESTIMATED ~5–12 %onecpu** of daemon, not all 18.8 | **Partial:** (a) native geom → **115200 B** vs **449280** `measured from source` (`624*480*3/2`); (b) fabric DMA/ring ARM-append-only | (a) **0** extra if store matches delivery; (b) DMA engine + descriptors — some ALM, little M10K if using HPS DMA/FPGA master to existing DDR | (a) blocked on store/geom product path; (b) no ring DMA product |
| **5** | **Pipe drain / read rawvideo** | misterplexd + ffmpeg write side | FEED pipe delta **5.26 ms/f wall** `measured` (archived) | **Yes with in-fabric decode** (no ARM raw pipe) or shared-mem ring | Coupled to #2 | Same as decode offload |
| **6** | **A/V pacing** (`av_clock.hpp` sleep/lead) | misterplexd | Wall-dominated sleeps; CPU **ESTIMATED ≪ 2 %onecpu** (pacing_wait is mostly sleep). Live daemon **18.8** is not mostly pacer CPU | **Yes — fabric frame timer on vsync** could gate presentation | Small: vsync edge → bank swap already in `ddr_frame_store`; ARM would only fill banks | Product still ARM-paced publish; swapping only on vsync already fabric (`ddr_frame_store`) — **pace-offload is control-plane**, not pixel path |
| **7** | **Overlay compositing into content buffer** | misterplexd | `overlay_cpu_us_p` in PROFILE logs when enabled — live % **NO-DATA** this turn (no parent overlay soak quoted). **ESTIMATED** low–moderate bursts when dirty | **Yes — fabric OSD plane** | Line buffer / alpha blend; **synergy w-osd-hires** (fixes low-res overlay + offload) | Today ARM blends into 624×480 buffer before DDR push |
| **8** | **Idle screen paint** | misterplexd | Idle-only; parent idle daemon **1.0–1.6** `measured` includes more than paint | **Yes** but **low value** | Small ROM/BRAM pattern or static DDR frame | Only when not playing |
| **9** | **Already fabric — EXCLUDE from offload backlog** | — | — | Done | — | **YUV→RGB BT.601** in present path; **audio ingest/FIFO** on core — do not re-count |

---

## §A — Decode vs scale contradiction (gates programme justification)

### Two instruments, two geometries (do not blend)

| Instrument | Geometry | decode | scale | Note |
|------------|----------|--------|-------|------|
| **W-FEED ARM profile** `measured` archived | **624×480 native** H.264 | **21.56 ms/f wall** decode_null | **+2.95 ms/f wall** scale/pad/yuv delta | Scale is **small** when not upsizing |
| **Live parent CPU %** `measured` | **240p delivery** into **624×480 store** | folded into ffmpeg process | **arm_rescale=1** every frame | ffmpeg **38.5–62.9**; scale **not separately metered** in live % |
| Claim “~50 of 69 is scale at 480p” | — | — | — | **Not supported** by FEED at native 480p; at native, decode ≫ scale |

**Direction that is source-consistent:**  
- **Native 480p:** decode dominates ffmpeg; scale ≈ 0 if `identity_skip`.  
- **240p→480 store:** scale is **extra** inelastic work on top of lighter 240p decode — parent sub-linear 1.40× CPU for 3.90× pixels matches **decode growth without 4× scale**.  
- **`fast_bilinear` cliff (−39% ffmpeg)** `measured` is a **scale-path** optimisation when scale runs; it does not prove scale > decode at 480p native.

### ONE instrument to settle (parent runs — binding)

Same binary probe, **one wall clock**, three arms, **same clip family**, report both **child_cpu ms/f** and **%onecpu** (exe-resolved ffmpeg only). No fps scaling of %.

**PRE_REG (publish misses):**

| Arm | PRE_REG child_cpu ms/f order | PRE_REG ffmpeg %onecpu (24 fps soak) |
|-----|------------------------------|--------------------------------------|
| A `decode_null` 624×480 | highest of three if content-limited | mid |
| B `decode+scale` 320×240→624×480 `fast_bilinear` | **A_decode_240 + scale_up** — scale delta **≫ 3 ms/f** (unlike native 2.95) | **highest** |
| C `decode+identity` 624×480 skip scale | ≈ A | ≈ A (±5 %onecpu) |

**Kill criteria:**  
- If B scale delta (B−decode_only_240) **< 5 ms/f child** → “scale dominates 240p” **dead**.  
- If C − A **> 10 ms/f child** → identity path broken / hidden scale.  
- If live % and ms/f **disagree on ranking A/B/C** → instrument bug (publish, don’t average).

```sh
# PARENT — settle decode vs scale (device). Adjust paths to your ffmpeg + samples.
# Requires: sample_624x480.mp4 and sample_320x240.mp4 (or one asset + -s/-vf only).
# Method: TIMEFORMAT; /usr/bin/time -v if present; else built-in time.
# Capture: cmd; echo "true rc=$?"

FF=/media/fat/misterplex_v2/bin/ffmpeg   # live root — parent confirms
OUT=/media/fat/misterplex_v2/offload_split
mkdir -p "$OUT"
N=300   # frames

# --- Arm A: decode_null 624x480 (no scale) ---
/usr/bin/time -f 'arm=A wall_s=%e child_user_s=%U child_sys_s=%S' \
  "$FF" -hide_banner -loglevel error -t 00:00:12.5 -i "$OUT/../samples/624x480.mp4" \
  -an -frames:v $N -f null - 2>"$OUT/A.err"
echo "true rc=$?"

# --- Arm B: decode 320x240 + scale/pad to 624x480 fast_bilinear ---
/usr/bin/time -f 'arm=B wall_s=%e child_user_s=%U child_sys_s=%S' \
  "$FF" -hide_banner -loglevel error -t 00:00:12.5 -i "$OUT/../samples/320x240.mp4" \
  -an -vf "fps=24/1,scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=624:480" \
  -frames:v $N -f null - 2>"$OUT/B.err"
echo "true rc=$?"

# --- Arm C: decode 624x480 identity (explicit scale=iw:ih skip if you use nullsink only) ---
/usr/bin/time -f 'arm=C wall_s=%e child_user_s=%U child_sys_s=%S' \
  "$FF" -hide_banner -loglevel error -t 00:00:12.5 -i "$OUT/../samples/624x480.mp4" \
  -an -vf "fps=24/1" -frames:v $N -f null - 2>"$OUT/C.err"
echo "true rc=$?"

# Score (parent):
# child_ms_f = 1000*(user+sys)/N
# Also optional: parallel arm_cpu_soak.sh during each arm for ffmpeg %onecpu
# Stamp: RBF md5 + daemon md5 even if daemon idle (artifact pair rule)
```

If `/usr/bin/time` missing on busybox, use the in-tree FEED probe if present:

```sh
# Prefer existing harness if on device (name may vary — parent locates):
ls /media/fat/misterplex_v2/bin/ /media/fat/misterplex/ 2>/dev/null | head
# Host-side reference only (NOT device evidence): scripts or tools that wrap ffmpeg_cpu_probe
```

**Until this lands:** justify fabric scaler (w-geom) primarily on **240p path elimination + glass geometry**, not on “scale is 50% of 480p ffmpeg.” Justify fabric **decode** on FEED **21.56 ms/f** @ native 480p.

---

## §B — Quantified savings (so fit value is judgeable)

### B1. Fabric scaler (w-geom) — predicted ARM saving

| Scenario | Scale work today | Predicted ffmpeg Δ if fabric does scale | Tag |
|----------|------------------|----------------------------------------|-----|
| 240p delivery, store 624×480 | ARM swscale every frame | **ESTIMATED reclaim of most of (ffmpeg_240p − decode_only_240p)** after §A; order-of parent cliff width **~20–40 %onecpu** when scale was hot | ESTIMATED until §A |
| 480p identity | already skip | **~0** additional | measured path identity_skip |
| Daemon | still pushes 449280 B | **unchanged** unless geom native | source |

**Fit value:** high for **240p users + overlay quality**; **do not** sell as recovering half of 480p ffmpeg until §A PASS.

### B2. DDR push — two independent savings

| Lever | Bytes/frame | ESTIMATED CPU | FPGA cost | Blocker |
|-------|-------------|---------------|-----------|---------|
| Native store = delivery (e.g. 320×240 bank) | **115200** vs **449280** (−74%) `source` | copy/flush **ESTIMATED ×0.26** of present-copy bucket | geom RTL (w-geom) | product still 624×480 coded store |
| ARM append-only + fabric/HPS DMA | ARM writes once to uncached/coherent ring | drop second memcpy+clean **ESTIMATED ~half of present CPU bucket** | DMA + ready/valid | not designed |
| Both | min bytes + DMA | stack | M10K/ALM | sequencing after scaler/decoder |

`publishDdrFrame` path (quoted): `memcpy(ddrMap_+bankOff, payload, len)` + optional `cleanDcacheRange` + doorbell — `fpga_spi.cpp`.

### B3. SUSPEND_MAIN_DURING_PLAY — residual risk + recommendation

**Measured (parent, historical lineage):** dual-busy **68.1% → 22.4% (−45.7)**; drops 3→0; av-lock held; 4‑min soak 18.9%; kill−9 → `RESUME_MAIN` verified; HDMI/DDR present OK while Main `T`.

**On product HEAD today:** **no session conf** `SUSPEND_MAIN_DURING_PLAY` — only SPI micro-SIGSTOP + `resumeStrandedMain()` watchdog (`fpga_spi.cpp`). Re-port required to ship the soaked behaviour.

| Residual risk | Severity | Mitigation |
|---------------|----------|------------|
| F12/OSD/`MiSTer_cmd`/`load_core`/gamepad→Main **dead** while `T` | **UX / ops** | Default **OFF**; document; Plex stop via **:3005** still works |
| Main left `T` after daemon kill−9 | **Brick class** | Parent verified supervisor CONT; keep `resumeStrandedMain` on startup + crash paths |
| Watchdog CONT during intentional session stop | **Logic bug** | Session hold must **suppress** stranded-resume while play-suspend asserted |
| Core switch / menu bounce while suspended | **Stuck core** | CONT before any `load_core` / deploy script |
| Daily-driver surprise | **High** | Never default ON without explicit user conf + on-screen notice |
| Not an FPGA offload | — | Still valid “get work off ARM” per user direction |

**Recommendation:**  
1. **Ship posture:** keep **default OFF**. Offer **opt-in conf** only after re-port to HEAD with watchdog hold + atexit CONT + deploy scripts CONT-first.  
2. **Parallel preferred:** lab **Main `poll` timeout=5** (F12 lives) — measure § PRE_REG before any default.  
3. **Do not** block fabric programme on SUSPEND; it is the **largest near-term reclaim** with **zero M10K**.

---

## §C — Programme aim order (evidence-weighted)

1. **Main duty-cycle or opt-in SUSPEND** — 0 M10K, up to ~1 core elastic → real runq relief `measured` path exists for SUSPEND.  
2. **§A settle decode vs scale** — one instrument (commands above).  
3. **w-geom fabric scaler + store honesty** — ARM save on 240p path; glass row ceiling fix synergy; **ESTIMATED** ffmpeg reclaim pending §A.  
4. **w-fit-1 `decode_stub` reclaim** — unlock M10K for real decode.  
5. **Fabric decode (phase 3)** — attacks FEED **21.56 ms/f** `measured` class work.  
6. **DDR DMA / native bytes** — after geom stable.  
7. **w-osd-hires plane** — overlay offload + user-visible fix; flag synergy, don’t design.  
8. **Vsync frame-timer control** — small; after pixels leave ARM.  
9. **Idle paint** — last.

---

## §D — Parent CPU stamp during any soak (required)

```sh
RBF_PATH=/media/fat/_Utility/Plex.rbf \
LOG=/media/fat/misterplex_v2/misterplexd.log \
sh /media/fat/misterplex_v2/arm_cpu_soak.sh 30
echo "true rc=$?"
```

Absence = **NO-DATA**. Never `200−accounted` as headroom.

---

## §E — Rule 0 line

| Claim | Tag |
|-------|-----|
| Main poll timeout=0 except Menu∧FB | source-proved |
| Parent baseline table 83/62.9/18.8 | measured (parent) |
| FEED 21.56 / 2.95 / 10.41 ms/f | measured archived; expire if ASSET not OK |
| Scale dominates 480p native ffmpeg | **not established** — contested; run §A |
| SUSPEND −45.7 | measured (parent historical) |
| Fabric scaler %onecpu save | **ESTIMATED** until §A |
| 449280 both tiers | source (`624*480*3/2`) |


**SUPERSEDED for ranking:** use `ARM_OFFLOAD_INVENTORY_WALL_MS.md` (wall ms/f only; %onecpu not mixed).
