# p720-scope-arm — Host/ARM scoping for 720p (no device, no Quartus)

| Field | Value |
|---|---|
| **TS_UTC** | 2026-07-30T17:09:39Z (v1) · CPU v2 17:14Z · **scale separation v3 17:25Z** |
| **SOURCE_SHA** | worktree `w-arm-p720-scope` (see git log) |
| **Lane** | host/ARM only — **no** ssh/deploy/Quartus/RBF |
| **480p gate** | **ARM-side PASS** — `docs/evidence/p480-audio-20260730T165053Z/` |
| **Headroom** | `docs/evidence/p480-headroom-20260730T170938Z/` (MiSTer tax + vf threads) |

---

## 0. LEAD — scale is the bill, not H.264 decode (v3)

### 0.1 What stands / what is retracted

| Prior claim | Status |
|---|---|
| mplex-only “sub-linear” 11.4→25.5 | **RETRACTED** (v2) |
| Totals 22.2→89.8 ~linear in **coded output** pixels | **Arithmetic correct for those totals** |
| Linear totals → 720p24 ≈ **276%** > 200% → “impossible” | **METHOD INVALIDATED for product verdict** if most of the 480p bill is **scale**, not decode |
| ffmpeg already multi-threaded; more `-threads` won’t 3× | **STANDS** |
| vf ~50% / h264 ~6% of ffmpeg @480p | **STANDS** (headroom + soak JSON) |

**Parent correction (quoted evidence):** `headroom_play480.json` / analysis — ffmpeg 69.1% = **`vf#0:0` ~50%** + h264 ~6% + mux ~6%.

### 0.2 Requested PMS profile vs library source geometry

**Requested (480p soak log, product STREAM=0 path):**

```text
resolved PMS universal 480p 624x480  bitrate=2000  transcode=1
.../video/:/transcode/universal/start.mp4?...&videoResolution=624x480&maxVideoBitrate=2000
  &videoCodec=h264&videoProfile=baseline&videoLevel=30...
```

**Filter graph always constructed** (`media_player.cpp` ~1954–1972), even when coded==display:

```text
fps=24/1,scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2
```

- No `sws_flags=` / `flags=fast_bilinear|neighbor|bicubic`.
- `-pix_fmt yuv420p` + `-f rawvideo` (format convert may still run inside scale).
- **No** `-threads`.

**Library source for the soak clip** (`docs/evidence/p480-verify-20260730T163848Z/11b_recent.xml`):

```xml
title="Sync 24000 Long Blip" ... 
<Media ... width="320" height="240" ... videoResolution="sd" ... videoFrameRate="24p"
  file=".../sync_24000_long_blip.mp4" />
```

**Actual ffmpeg input WxH (bitstream after PMS):** **NOT measured in-session.**  
`-loglevel error` suppresses stream dump; no `ffprobe` artifact in evidence.  
**Rule 0:** only proven facts are **source file 320×240** and **request target 624×480**.

### 0.3 What `vf#0:0` is doing (code)

| Stage | Role |
|---|---|
| `fps=N/D` | CFR gate to content rate |
| `scale=W:H:force_original_aspect_ratio=decrease` | **resample** to fit box (default swscale = bicubic-class) |
| `pad=W:H:...` | letterbox/pillar into coded bank |
| `-pix_fmt yuv420p` | ensure I420 for rawvideo pipe |

When `display != coded` (true `plex480p` crop path), scale goes to **display** then pad into **coded** with crop offsets. Soak harness used **identity 624×480** (`decode=coded=display=624x480`), so the else-branch full coded scale+center pad ran.

**There is no path that omits scale** when dimensions already match input.

### 0.4 Why 240p vf is tiny and 480p vf is ~50% (evidence-bound inference)

| Tier | target scale | source library | vf (soak / headroom) | h264 |
|---|---|---|---:|---:|
| 240p | 320×240 | **320×240** | **~2.3%** (of ~13.8 ff) | small |
| 480p | 624×480 | **320×240** | **~50%** | **~6%** |

PMS limitations use **upperBound** on width/height (`plex_resolve.cpp` `plexClientProfileExtra`). With client profile name `MiSTerPlex`, Profile-Extra is **not** sent (server XML profile). URL still carries `videoResolution=624x480`.

**PMS commonly does not upscale** below-cap sources — it keeps ≤ requested size.  
**Pre-registered (not yet measured):**

| ID | Prediction | Settled by |
|---|---|---|
| **S1** | Live universal **video stream is 320×240** (or ≤320) at 480p tier on this clip | ffprobe on start.mp4 URL during play |
| **S2** | If S1 HIT → ARM **upscales 320→624** and that **is** the ~50% vf bill | compare S1 + vf |
| **S3** | If S1 MISS (input already 624×480) → identity/near-identity scale still costs ~50% (generic sws path) | same probe |
| **S4** | Omitting scale+pad when in_w/h == coded (and pix_fmt already yuv420p) recovers **most of ~50%** at 480p on this clip if S1 HIT | A/B harness |
| **S5** | `sws_flags=fast_bilinear` or `neighbor` cuts vf by ≥2× if scale must remain | A/B harness |

**Honest status:** S1 is the single highest-value measurement. Without it, “PMS already delivers 624×480” is **unknown**. Source XML + vf discontinuity **strongly motivates S1=HIT**, but is **not** a substitute for stream probe.

### 0.5 Pre-registered savings (before any device A/B)

| Lever | Expected save @480p on blip clip | Risk |
|---|---|---|
| **(a)** PMS delivers true target **or** ARM skips scale when in==out | **~40–50 %onecpu** if S1 HIT and scale dropped; **unknown** if S1 MISS | must still pad/crop for pillar geometry when display≠coded |
| **(b)** `scale=WxH:flags=fast_bilinear` (or neighbor) | **~2–4× vf reduction** if geometry change remains (class-A9 folklore; **unmeasured here**) | quality on CRT/HDMI |
| Force PMS **upscale** to tier (server pays) | moves cost off dual-A9; ARM decode grows with delivered MBs | server load; need profile that **targets** size not only upperBound |
| Lower bitrate | helps h264 (~6%) **marginally**; not vf | — |

### 0.6 720p projection — **decode + scale + push + daemon separated**

Anchors @480p24 (180s): mplex **20.8**, ffmpeg **69.0** (vf **~50.4**, h264 **~5.8**, mux **~5.9**, other_ff **~6.9**).  
px ratio 720/480 coded = **3.0769**.  
**All 720p rows are extrapolations, not measurements.**

#### Scenario A — same as today: PMS keeps ~320 source, ARM scales to tier

| Term | 480p meas. | →720p24 method | Proj. % |
|---|---:|---|---:|
| h264 decode | 5.8 | ~same delivered MBs if still 320 | **~6** |
| vf scale | 50.4 | × (921600/299520) out-linear upscale | **~155** |
| mux rawvideo | 5.9 | ×3.08 (bytes out) | **~18** |
| other ffmpeg | 6.9 | flat-ish | **~7** |
| mplex (incl push) | 20.8 | ×3.08 bytes (upper) | **~64** |
| **stream total** | 89.8 | | **~250** |

**Still fails hard** if we keep ARM upscale-to-720p from SD source.

#### Scenario B — PMS delivers true tier geometry; scale eliminated or ~identity cheap

| Term | Method | Proj. % @720p24 |
|---|---|---:|
| h264 | 5.8 × 3.08 (MBs ~linear in coded area of **delivered** stream) | **~18** |
| vf | residual fps + optional cheap flags / skip | **~2–5** |
| mux | ×1.5–3.08 (bytes; partial if pipe-bound) | **~9–18** |
| other ff | ~7 | **~7** |
| mplex | push ms 8.5→~29 (×3.4) on copy path; not full ×3.08 on whole daemon | **~35–70** |
| **stream total** | | **~70–120** |

**Dual-A9 ceiling 200%.** Headroom report: during 480p play **MiSTer ≈ 75%**, machine_busy **174%**, idle_rem **~26%**.  
Even with stream **~100%**, machine can fit if MiSTer shares (~75+100=175 < 200).  
**If scale-fixed path lands in ~70–120% stream, 720p24 becomes plausible on CPU** — reverse of v2 “impossible.”

#### Scenario C — real 1080p library → PMS downscale to 720p (product case)

Not measured. Expected: server does heavy scale; ARM receives ~1280×720; same as B if ARM scale skipped. **Blip 320 source is the worst ARM-upscale case and must not be the only 720p proof clip.**

### 0.7 480p headroom if vf recoverable

| Metric | Today @480p | If vf ~50 → ~3 (scale skip) |
|---|---:|---:|
| ffmpeg | 69 | **~22** |
| stream (ff+mp) | ~90 | **~43** |
| machine_busy (headroom) | 174 | **~proj 127** (174 − 50) |
| idle_rem to 200 | 26 | **~proj 73** |

**480p looks expensive mostly because of avoidable scale work on SD source (if S1 HIT).** Fixing scale improves every tier.

### 0.8 Binding order (v3)

| Rank | Constraint | 720p24 |
|---:|---|---|
| **1a** | **ARM scale policy + actual input geometry** | **Open — may unlock or kill** |
| **1b** | **Stream total after scale fix** | Proj **~70–120%** if B; **~250%** if A |
| **1c** | **MiSTer always-on tax (~75–99%)** | Eats one core; must be in any machine budget |
| **2** | DDR ABI / remap | Hard block at `0x30000000` without remap — **still required for product** |
| **3** | DDR push ~29 ms / 42 ms | Marginal; measure after CPU path exists |
| **4** | FPGA decode | Unavailable for 720p now |

**Verdict v3:** Do **not** ship “720p impossible.”  
**v2 linear-total impossibility assumed scale cost scales with tier pixels forever.**  
**If S1 HIT and scale is skipped or moved to PMS, 720p24 host CPU is plausibly inside 200%** (extrapolation).  
**If S1 MISS and identity scale stays ~50%×3, still dead.**  
**Next gate is w-device measurement (§7), not an RBF.**

---

## 1. DDR frame-store contract

### 1.1 What 512 KiB is

Quoted from `host/libmisterplex/ddr_frame_layout.hpp`:

```text
constexpr uint32_t kDdrFramePhysBase = 0x30000000u;
constexpr uint32_t kDdrFrameStrideAlign = 0x40000u;          // 256 KiB
constexpr int kPlex480pYuv420pBytes = 449280;                // 624*480*3/2
constexpr uint32_t kPlex480pYuv420pBankStride = 0x00080000u; // 512 KiB
constexpr uint32_t kPlex480pYuv420pDoorbellPhys = 0x300FF000u;
```

`makeDdrFrameLayout` sets:

```text
out.bank_stride = alignUpU32(frameBytes, strideAlign);  // align to 256 KiB
out.doorbell_phys = physBase + out.bank_stride * 2u - 0x1000u;
out.map_bytes = out.bank_stride * 2u;
```

So **512 KiB is not a magical aperture size** — it is `alignUp(449280, 256 KiB) = 2 × 256 KiB`.  
Acceptance currently **caps** any resolution at that stride:

```text
return bankStride <= kPlex480pYuv420pBankStride;  // ddrFrameStoreAcceptsResolution
constexpr CodedWidth  kDdrFrameStoreMaxWidth {640};
constexpr CodedHeight kDdrFrameStoreMaxHeight{480};
```

RTL mirror: `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh`  
`DDR_FRAME_YUV420P_BANK_STRIDE = 32'h0008_0000`, doorbell `32'h300F_F000`.

`present_core.sv` wires those params into `ddr_frame_store` (CODED 624, bank stride 512 KiB, doorbell 0x300FF000).  
`Plex.qsf` also sets `FRAME_W=640` / `FRAME_H=480` (presented scanout max for current RBF).

### 1.2 Physical map (what is claimed today)

| Region | Phys | Role | Source |
|---|---|---|---|
| Frame bank 0 | `0x30000000` | I420 payload start | `kDdrFramePhysBase` |
| 240p bank1 | `0x30040000` | stride 256 KiB | layout math |
| Fixed mailbox page | `0x3007F000`… | PLXK/PLXS/PLXI/PLXM/PLXF/DIAG/PLXD | `mailbox_abi_spec.hpp` |
| 480p bank1 | `0x30080000` | stride 512 KiB | layout math |
| 480p doorbell (geom) | `0x300FF000` | PLXK geometry-derived | `kPlex480pYuv420pDoorbellPhys` |
| Bitstream ring data | `0x30100000` | 256 KiB ring | `ddr_bitstream_ring.hpp` `kDataPhys` |
| Bitstream CTRL PLXB | `0x30140000` | ring control | `mailbox_abi::kPlxbAddr` |

Two-bank map window size:

| Tier | frame_bytes | bank_stride | map_bytes | doorbell |
|---|---:|---:|---:|---|
| 320×240 | 115200 | 0x40000 (256 KiB) | 0x80000 (512 KiB) | 0x3007F000 |
| 624×480 | 449280 | 0x80000 (512 KiB) | 0x100000 (1 MiB) | 0x300FF000 |
| **1280×720** | **1382400** | **0x180000 (1.5 MiB)** | **0x300000 (3 MiB)** | **0x302FF000** |

Default ARM map construct: `fpga_spi.hpp` `ddrLayout_ = makeDdrFrameLayout(320, 240)`; runtime `setDdrFrameLayout` remaps `map_bytes`.

### 1.3 ABI tension (doorbell-relative vs fixed mailboxes)

Host comment (`ddr_frame_layout.hpp`):

```text
// Fixed mailbox control page (NOT geometry-derived; live silicon ABI):
//   PLXS 0x3007F100, PLXF 0x3007F118, PLXD 0x3007F128 — do not "unify" with doorbell.
```

RTL (`ddr_frame_store.sv` parameters):

```text
DOORBELL_PHYS = PHYS_BASE + (2 * HPS_BANK_STRIDE_BYTES) - 0x1000
MAILBOX_PHYS  = DOORBELL_PHYS + 0x100   // PLXS etc. follow doorbell
```

| Mode | Doorbell | RTL-derived PLXS | ARM fixed PLXS (`mailbox_abi_spec`) |
|---|---|---|---|
| 240p | 0x3007F000 | 0x3007F100 | 0x3007F100 — **match** |
| 480p | 0x300FF000 | 0x300FF100 | 0x3007F100 — **diverge** |

ARM `readBankRelease` / `readFrameStoreStatus` / `readOsdMailbox` use **fixed** `0x3007Fxxx` offsets into the frame mmap.  
**Implication for 720p:** any map redesign must pick one ABI family and update **both** RTL and ARM together. Not settled by this lane; flag as FPGA+host co-design.

Also: `Plex.sv` has a separate step-function `HPS_BANK_STRIDE_BYTES` (256K/1M/2M/4M) used outside `present_core`; live `ddr_frame_store` instance uses **params.svh 512 KiB**, not that step function. 720p must not reintroduce a host/RTL stride split.

### 1.4 Can two 1.32 MiB banks fit? — **the critical answer**

**DRAM capacity (DE10-Nano ~1 GiB) is not the measured limiter.**  
Under the **current address ABI**, naive 720p at `phys_base=0x30000000` is **dead**:

| Collision | Address | 720p bank0 payload `0x30000000..0x30151800` |
|---|---|---|
| Fixed mailbox page | 0x3007F000–0x3007F128 | **OVERWRITTEN** by memcpy of bank0 |
| Bitstream ring data | 0x30100000 | **OVERWRITTEN** |
| Bitstream PLXB CTRL | 0x30140000 | **OVERWRITTEN** |

Proof sketch (bytes):

- Max I420 **before** mailbox page: `0x3007F000 - 0x30000000 = 520192` B → max ≈ 480×720, **not** 1280×720.
- 720p frame_bytes `1382400 > 520192`.
- Bitstream ring starts at `0x30100000`; 720p bank0 ends at `0x30151800` → covers ring.

**Remap options (host-visible; all need FPGA co-change — not authorised here):**

| Option | Base | map end (host 1.5 MiB stride) | Avoids 0x3007F / 0x3010–0x3014? |
|---|---|---|---|
| A. Keep base, enlarge only | 0x30000000 | 0x30300000 | **NO** — stomps both |
| B. Base after 480p map | 0x30080000 | 0x30380000 | mbox OK; **still stomps bitstream** |
| C. Base after bitstream | **0x30180000** | **0x30480000** | **YES** (mbox + ring clear of payloads) |
| D. Move ring + mbox + frames (full remap) | TBD | TBD | possible; largest ABI break |

**Verdict on aperture:**  
- **Not** “DDR is too small for 2×1.32 MiB.”  
- **Yes hard-blocked** on **current** `0x30000000` ABI without a **memory-map redesign** (new `phys_base` and/or moved mailboxes/ring) plus matching RBF.  
- With option C-class remap, **two banks + doorbell page ≈ 3 MiB** is a small slice of HPS DDR; **physical room is plausible**, but **unmeasured** on device (no `/proc/iomem` / reserved-region probe this lane).

---

## 2. DDR push throughput

### 2.1 Evidence used

| Source | What it measured | Numbers |
|---|---|---|
| `docs/evidence/p480-verify-20260730T163848Z/REPORT.md` | Live product `frame_tx` on real 24 fps media | 240p ~**4** ms; 480p **8–11** ms |
| `docs/evidence/p480/p480-bandwidth.md` | Device archive pure bank fill 624×480 | O_SYNC **7.378** ms (**58.1 MiB/s**); no-sync **7.199** ms (**59.5 MiB/s**) |
| `fpga_spi.cpp` `sendDdrFrame` | Product path | `memcpy(ddrMap_+bankOff, payload, len)` + barrier + doorbell; default `O_SYNC` |

SPI 194–220 ms comment is **retired RGB565 F1**, not product DDR (`p480-bandwidth` P1 HIT).

### 2.2 Pre-registered 720p projection (method stated)

**Method A — scale pure-copy archive rate (59.5 MiB/s no-sync row):**

| Tier | Bytes | Copy ms @ 59.5 MiB/s | Copy-only fps cap |
|---|---:|---:|---:|
| 320×240 | 115200 | 1.85 | ~541 |
| 624×480 | 449280 | 7.20 (matches archive) | ~139 |
| **1280×720** | **1382400** | **22.15** | **~45** |

**Method B — scale live product `frame_tx` mid (9.5 ms @ 480p ⇒ ~45.1 MB/s effective including prep/doorbell):**

| Tier | Projected frame_tx | vs 24 fps budget 41.67 ms | vs 30 fps 33.33 ms |
|---|---:|---|---|
| 720p | **1382400/449280 × 9.5 ≈ 29.2 ms** | **~70% of budget** | **~88% — tight** |

**Method C — scale archive product total 10.41 ms:** → **≈ 32.0 ms** @ 720p.

### 2.3 Bandwidth-bound vs per-transaction?

| Path | Bound type | Evidence |
|---|---|---|
| SPI `sendFileTx` | Bandwidth ~0.8 MB/s | chunk sweep flat 8–128 KiB |
| DDR `memcpy` fill | **Byte-volume / bus** ~58–60 MiB/s | 480p archive; scales ~linear with bytes |
| Fixed overhead | PLXD poll / `usleep(1500)` fallback / doorbell / optional post-wait | does **not** scale with pixels; dominates only at small frames |

`ddrMemSync`: archive showed O_SYNC vs plain **~2.5%** delta; **cacheflush nearly doubles** cost. Default product keeps `DDR_MEM_SYNC=1`, flush off — flipping sync is **not** a free 720p win per archive.

### 2.4 Throughput verdict

| Claim | Status |
|---|---|
| 720p **killed** by push bandwidth alone at 24 fps? | **No** (projection) — ~23 ms copy / ~29–32 ms product vs 41.7 ms |
| 720p **comfortable**? | **No** — **marginal**; little room for decode+PLXD wait+jitter |
| 30 fps 720p? | **Likely fails** product path without faster push or lower overhead |
| Needs hardware measure? | **YES** — see §6 |

Honest label: **plausibly deliverable at 24 fps on push alone; not proven; not comfortable.**

---

## 3. ARM CPU projection — **see §0 (v3 scale separation)**

| Generation | Error | Use |
|---|---|---|
| v1 | mplex-only sub-linear | **discard** |
| v2 | linear totals → 276% “impossible” | **arithmetic OK; product method wrong if scale≠decode** |
| **v3** | decode vs scale vs push separated; source 320×240 | **current** |

H.264 ladder note: 1280×720 = **3600 MBs/frame** needs **Level 3.1** (level 3.0 max 1620 MBs).

---

## 4. Ladder / profile / OSD (three-tier restructure)

### 4.1 Current two-way branches (must become tables/switch)

| Site | Today | 720p need |
|---|---|---|
| `osd_menu.hpp` `contentResolutionFromOsdWord` | `O[4]==1` → 480p else 240p | 2-bit select (see O[5]) |
| `contentResolutionFromCodedSize` | `w/h >= 624/480` → 480p | ordered tiers 720 → 480 → 240 |
| `weakBitrateKbpsForCodedSize` | 480 floor 2000; mid 1500; else 1000 | add 720p floor (candidate **4000–6000** kbps — **unproven**) |
| `plex_resolve.cpp` `plexTranscodeProfiles()` | `{"240p",…},{"480p",…}` | third `{"720p", "1280x720", …, level 31}` |
| `validateWeakLadder` | rejects `> 640×480`; 480p bitrate ≥ 2000 | accept 1280×720 when lab-enabled; level ≤ 31; bitrate floor |
| `Plex.sv` CONF_STR | `O[4],Content resolution,320x240,640x480` | three labels; **config version bump** (v7→v8) |
| `O[5]` | **reserved** (`osd_menu.hpp`) | natural second bit for 2-bit tier |

### 4.2 Suggested tier table (design only — **not implemented**)

| OSD `O[5:4]` | name | coded (PMS/decode) | presented (scanout claim) | weak kbps (start) | h264 level |
|---|---|---|---|---:|---:|
| 00 | 240p | 320×240 | 320×240 | 1000 | 30 |
| 01 | 480p | **624×480** | **640×480** | 2000 | 30 |
| 10 | 720p | **1280×720** | **1280×720** (HDMI) | TBD lab | **31** |
| 11 | reserved | — | — | — | — |

Shipping default remains **00 / 320×240**.

---

## 5. Coded-vs-presented trap

### 5.1 480p lesson (do not repeat)

| Role | Size | Notes |
|---|---|---|
| coded | **624×480** | DDR + H.264 + FFmpeg raw stride |
| display | 618×480 | right crop 6 |
| presented | **640×480** | 11+11 pillar; OSD label historically “640x480” |
| fault class | 640×480 as DECODE | `CodedSizeParseStatus::PresentedMistake` |

### 5.2 720p geometry recommendation

| Check | 1280 | 720 |
|---|---|---|
| MB align (/16) | **80** (exact) | **45** (exact) |
| Even (YUV) | yes | yes |
| 16:9 | yes | yes |

**Recommended coded size: `1280×720` identity** — coded = display = presented for HDMI 16:9.  
**Do not** invent a “1264×720 coded / 1280 presented” parallel to 624/640 unless PMS or crop evidence forces it (none on host today).

VGA/CRT “downscale + letterbox” is a **scanout/scaler** problem (`video_mode`, present letterbox), **not** a second coded width. Keep one coded frame; let MiSTer scaler / present path letterbox to 4:3 panels.

Add `PresentedMistake`-class guard only if a distinct presented size is introduced later (e.g. 1280×720 presented vs some other coded). For identity 720p, the 640-style footgun is: treating a **downscaled VGA mode** as decode size — guard in adopt path when that appears.

`ddrFrameStoreAcceptsResolution` must gain a lab 720p path **after** map redesign; today it hard-rejects on max 640×480 and 512 KiB stride.

---

## 6. What `w-device` must measure (priority order)

### 6.1 HIGHEST PRIORITY — live input geometry (settles S1)

**Do not start 720p hardware work until S1 is HIT or MISS.**

During **480p** play of `/library/metadata/12` (Sync 24000 Long Blip), while ffmpeg is up:

```bash
# 1) Grab the live universal URL from misterplexd log (videoResolution=624x480)
# 2) Probe the *transcode output* ffmpeg is reading (same headers/token as daemon):
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,codec_name,pix_fmt,avg_frame_rate \
  -of csv=p=0 \
  -headers "X-Plex-Token: <token>
" \
  "<same start.mp4 URL misterplexd uses>"
# Capture: true rc, stdout width/height. Also optional:
# ffmpeg -hide_banner -i URL -t 1 -f null - 2>&1 | tee probe_ff.txt
# Look for "Stream #0:0" Video: ... WxH
```

| ID | Pre-register | HIT means |
|---|---|---|
| **S1** | width×height is **320×240** (or ≤352×288) | PMS did **not** upscale; ARM scale=624:480 **is the upscale** |
| **S1b** | width×height is **624×480** | PMS delivered target; vf cost is identity/near-identity sws |

Also dump PMS decision if available:

```bash
# decision endpoint (same session) — look for videoResolution / width in XML
curl -sS -H "X-Plex-Token: $TOKEN" \
  "$PMS/video/:/transcode/universal/decision?<same query as start.mp4>" \
  | tee decision_480p.xml
```

### 6.2 Scale A/B (after S1 known) — recover 480p headroom

**Pre-register:**

| ID | Prediction |
|---|---|
| S4 | On blip@480p, vf-omit (or `scale=flags=neighbor` no-op path) cuts ffmpeg by **≥35 %onecpu** if S1 HIT |
| S5 | `scale=624:480:flags=fast_bilinear` cuts vf by **≥2×** vs default if geometry change remains |
| S6 | 480p stream total drops toward **~40–50%** if scale skipped (S1 HIT) |

Recipe sketch (device owns edit/deploy of **lab-only** daemon flag; **do not change shipping default**):

```bash
# Baseline: existing headroom_sample.py window @480p → headroom_play480.json
# Lab A: MISTERPLEX_VF=fps_only (or conf) — fps=N/D only, no scale/pad
#        ONLY valid when probe proves in_w/h == out; else frames wrong size → hard fail
# Lab B: append :flags=fast_bilinear to scale=
# Compare ffmpeg % and top vf threads; capture SOURCE_SHA, true rc.
```

### 6.3 DDR (still required before product 720p; secondary to S1)

| ID | Prediction |
|---|---|
| D1 | Pure DDR fill 1280×720 O_SYNC ∈ **20–26 ms** |
| D2 | Product `lastPushMs` @720p24 ∈ **28–36 ms** |
| D5 | mmap 3 MiB at `0x30180000` OK; PLXB `0x30140000` intact after bank0 paint |
| D6 | Base `0x30000000` 720p write **corrupts** mbox/ring (negative control) |

```bash
WIDTH=624 HEIGHT=480 GEOMETRY=plex480p LOOPS=1000 ./scripts/run_c2_ddr_bench.sh
# 720p bench only after lab layout exists — stock ABI should refuse/collide
```

**Soft-skip 77 / UNSCORED ≠ PASS.**

---

## 7. Host-side change list (when unblocked)

| Area | Change | Blocks on |
|---|---|---|
| Memory map | New `phys_base` (candidate `0x30180000`) or moved ring/mailboxes; update `mailbox_abi_spec`, ring, layout, RTL params | **RBF + ABI freeze** |
| `ddr_frame_layout.hpp` | 720p constants; raise max W/H; acceptance; geometry helper | map decision |
| `coded_size.hpp` | lab allow bit (like 480p); no presented-mistake for 1280×720 identity | policy |
| `osd_menu.hpp` / CONF_STR | 2-bit tier; bitrate; labels | config v bump + RBF |
| `plex_resolve.*` | profile row; validate; level 31; bitrate | PMS lab |
| `fpga_spi` | larger mmap already dynamic via `map_bytes`; ensure fixed mbox still in map **or** separate control-page mmap | map |
| Unit tests | geometry, adopt, ladder, RTL invariants | — |
| Default | **remain 320×240** | — |

**Not in host lane:** RTL `FRAME_W/H`, line-prefetch 16 for 720p30 (`display-resolution.md` model), letterbox-on-VGA, Quartus fit.

---

## 8. Verdict (v3 — scale separation)

| Question | Answer |
|---|---|
| **What binds first?** | **Unknown until S1** — either **avoidable ARM scale** (likely on SD blip) or true decode+push |
| Is H.264 decode the 480p cost? | **NO** — h264 ~**6%**; **vf ~50%** (measured) |
| Library source of soak clip | **320×240** (`11b_recent.xml`) vs request **624×480** |
| Live ffmpeg input WxH | **Not measured** — w-device §6.1 |
| 720p24 if ARM keeps upscaling SD | **FAIL** proj ~**250%** stream (Scenario A) |
| 720p24 if PMS delivers tier + scale skip | **Plausible** proj ~**70–120%** stream (Scenario B) — **extrapolation** |
| Machine budget | dual-A9 **200%**; MiSTer tax **~75% play / ~99% idle** (headroom) |
| DDR `0x30000000` | Still **hard block** without remap — required for product banks |
| Push @24 fps | Marginal ~29/42 ms — not first if scale fixed |
| FPGA decode | Not available for 720p |
| 480p gate | **PASS** (ARM) |
| Ship 720p now? | **NO** — need S1 + scale A/B + map co-design; default stays 240p |

### One-line decision aid

> **Do not ship “720p impossible.” Decode is ~6% at 480p; scale is ~50%. Source library is 320×240 while we always `scale=` to tier. Prove live input WxH (S1). If ARM is upscaling, fix PMS target or skip identity scale — 720p24 may fit; if identity scale is still 50%, it remains dead. DDR remap still required for product.**

---

## Artifacts

| Path | Role |
|---|---|
| this file | scoping report (v3) |
| `docs/evidence/p480-audio-20260730T165053Z/` | 180s totals 22.2 / 89.8 |
| `docs/evidence/p480-headroom-20260730T170938Z/` | vf threads + MiSTer tax |
| `docs/evidence/p480-verify-20260730T163848Z/11b_recent.xml` | source **320×240** |
| `docs/evidence/p480/p480-bandwidth.md` | DDR fill MiB/s archive |
| `host/libmisterplex/ddr_frame_layout.hpp` | contract |
| `host/libmisterplex/mailbox_abi_spec.hpp` | fixed mailbox page |
| `host/libmisterplex/ddr_bitstream_ring.hpp` | ring at 0x30100000 |

**No host default changed. No tier implemented. No device access.**
