# p720-scope-arm — Host/ARM scoping for 720p (no device, no Quartus)

| Field | Value |
|---|---|
| **TS_UTC** | 2026-07-30T17:09:39Z |
| **SOURCE_SHA** | `92b8278c219aacc1d01e96b0b18343bd77190b9f` |
| **Branch** | `w-arm-p720-scope` |
| **Lane** | host/ARM only — **no** ssh/deploy/Quartus/RBF |
| **Gate** | 720p product work remains gated on 480p A/V soak PASS (not claimed here) |

## Pre-registered predictions (before measurement / layout math)

| ID | Prediction | Result |
|---|---|---|
| P1 | `kPlex480pYuv420pBankStride` is 512 KiB from `alignUp(449280, 0x40000)` | **HIT** — quoted below |
| P2 | Two 1.32 MiB banks **cannot** land at `phys_base=0x30000000` without stomping fixed mailboxes and/or bitstream ring | **HIT** — layout math |
| P3 | Pure DDR fill @ archived ~59 MiB/s → 720p copy ≈ 23–24 ms | **HIT** (extrapolation from archive; not new device measure) |
| P4 | Product `frame_tx` @ 24 fps is comfortable (<25 ms) | **MISS** — projection 29–34 ms vs 41.7 ms budget → **marginal** |
| P5 | CPU power-law projection lands under 40% onecpu | **MISS** — projection ≈ **50%** (affine ≈ 65%; linear-from-480p ≈ 78%) |
| P6 | 1280×720 is MB-aligned; coded can equal presented (no 640-for-624 repeat) | **HIT** |

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

## 3. ARM decode CPU projection (**extrapolation, not measurement**)

### 3.1 Measured anchors (p480-verify, real media, ~15 s)

| Tier | coded px | PLAY_P_ONECPU | ratio vs 240p px | ratio vs 240p CPU |
|---|---:|---:|---:|---:|
| 240p | 76800 | **11.4%** | 1.00× | 1.00× |
| 480p | 299520 | **25.5%** | **3.90×** | **2.24×** |
| 720p | 921600 | ? | **12.00×** / **3.08× vs 480p** | ? |

Observed: **sub-linear** in pixels (3.9× px → 2.24× CPU).

### 3.2 Methods

| Method | Formula | 720p %onecpu |
|---|---|---:|
| Power law through two points | \(e=\ln(25.5/11.4)/\ln(3.9)\approx 0.592\); \(c\cdot px^{e}\) | **≈ 49.6%** |
| Affine `a + b·px` fit | solve two points | **≈ 64.9%** |
| Linear scale from 480p only | `25.5 × (921600/299520)` | **≈ 78.5%** |

**Preferred stated projection:** power-law **~50% of one A9 core** decode+present path share, with **uncertainty band ~50–80%** until measured.  
Dual-A9: one core at 50–80% leaves the sibling for GDM/companion/audio — **plausible if GDM stays fixed** (idle storm was the prior killer). **Not** a measurement.

H.264 ladder today forces **Baseline level 3.0** (`plex_resolve` / profiles).  
1280×720 = **3600 macroblocks/frame**; Level 3.0 max frame size is **1620 MBs** → **Level 3.1 required** (3600 MBs). Host ladder must raise `h264Level` for a 720p tier (PMS will otherwise refuse or downscale unpredictably).

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

## 6. What `w-device` must measure before commit

**Pre-register device predictions (for the device lane to hit/miss):**

| ID | Prediction |
|---|---|
| D1 | Pure DDR fill 1280×720 O_SYNC ∈ **20–26 ms** (~53–66 MiB/s) |
| D2 | Product `ddr_copy_us` scales within 10% of byte ratio vs 624×480 |
| D3 | Product `lastPushMs` @ 720p on 24 fps media ∈ **28–36 ms** |
| D4 | PLAY_P_ONECPU @ 720p ∈ **45–75%** |
| D5 | mmap 3 MiB at `0x30180000` succeeds; write does not corrupt PLXB at `0x30140000` (readback probe) |
| D6 | Current base `0x30000000` 720p write **does** corrupt PLXS/PLXB (negative control) |

**Exact recipes (device lane owns hardware):**

```bash
# A) Pure fill both tiers (existing bench path)
WIDTH=624 HEIGHT=480 GEOMETRY=plex480p LOOPS=1000 ./scripts/run_c2_ddr_bench.sh
# After lab binary knows 1280x720 layout (not shipped default):
WIDTH=1280 HEIGHT=720 LOOPS=1000 ./scripts/run_c2_ddr_bench.sh   # expect fail or collision on stock ABI

# B) Aperture probe (read-only + careful write of non-product region)
#  - parse /proc/iomem for 0x30000000 vicinity
#  - mmap proposed bases; verify PLXB magic at 0x30140000 before/after bank0 paint

# C) Product present_profile (only after experimental daemon+RBF map)
#  capture: ddr_copy_us_p, ddr_total_us_p, ddr_plxd_used_x100_p, f1ms/lastPushMs,
#           PLAY_P_ONECPU, pfps, drops, av_drift_ms, SOURCE_SHA, RBF md5
```

**Do not** treat soft-skip 77 / UNSCORED as PASS.

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

## 8. Verdict

| Question | Answer |
|---|---|
| Is 720p feasible **host-side alone** on current ABI? | **NO** — bank0 payload collides fixed mailboxes + bitstream ring |
| Is 720p killed by **physical DRAM size**? | **No evidence it is** — 2×1.5 MiB banks are small; **address map** is the wall |
| Is push bandwidth a hard kill at 24 fps? | **No (projection)** — marginal ~29–32 ms of ~42 ms |
| Is CPU a hard kill? | **Unknown** — extrapolate ~50% (band 50–80%) onecpu; measure required |
| FPGA/RBF required? | **YES** — geometry, stride, base, mailbox ABI, CONF_STR, scanout |
| Ship 720p now? | **NO** — gated on 480p soak + map redesign + device measures |
| Honest overall | **Feasible only after memory-map co-design; throughput/CPU look marginal-but-plausible at 24 fps, not free** |

### One-line decision aid

> **Do not schedule a 720p tier implement until (1) 480p soak PASS, (2) parent accepts a new DDR map (e.g. frame base ≥ `0x30180000` or equivalent), (3) w-device publishes D1–D4 numbers. Host ladder/OSD work is straightforward once those land; the aperture collision is the showstopper under today’s contract.**

---

## Artifacts

| Path | Role |
|---|---|
| this file | scoping report |
| `docs/evidence/p480-verify-20260730T163848Z/REPORT.md` | live 240/480 CPU + frame_tx |
| `docs/evidence/p480/p480-bandwidth.md` | DDR fill MiB/s archive |
| `host/libmisterplex/ddr_frame_layout.hpp` | contract |
| `host/libmisterplex/mailbox_abi_spec.hpp` | fixed mailbox page |
| `host/libmisterplex/ddr_bitstream_ring.hpp` | ring at 0x30100000 |

**No host default changed. No tier implemented. No device access.**
