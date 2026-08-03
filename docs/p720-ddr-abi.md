# 720p DDR ABI + memory tiering (w-mem)

**Lane:** host/RTL contract + design — **no Quartus fit, no device.**  
**Sources of truth:** `host/libmisterplex/ddr_frame_layout.hpp`,  
`fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh`,  
`docs/evidence/p720-scope-arm-20260730T170939Z/REPORT.md`,  
`docs/evidence/p480/p480-bandwidth.md`.

---

## 1. Corrected 720p arithmetic (quoted constants)

From `ddr_frame_layout.hpp` / `.svh` product 480p and new 720p tier:

| Quantity | 480p (product) | 720p tier |
|---|---:|---:|
| Coded W×H | 624×480 (`kPlex480pCodedWidth/Height`) | 1280×720 |
| I420 bytes | **449280** (`kPlex480pYuv420pBytes`) | **1382400** (`0x151800`) |
| Y / chroma stride | 624 / 312 | **1280 / 640** |
| U / V offset | 299520 / 374400 | **921600 / 1152000** |
| `alignUp(bytes, 0x40000)` bank stride | **0x80000** | **0x180000** |
| Two-bank map | 0x100000 | **0x300000** (3 145 728) |
| Luma line bits | 624×8 | **1280×8 = 10240 = 1× M10K bit budget** |
| Pixel ratio vs 480p coded | 1.0× | **3.0769×** |
| Push @24 fps (decimal MB/s) | 10.78 | **33.18** |
| Push @30 fps | 13.48 | **41.47** |

**Doorbell correction vs parent brief:**  
Geometry formula is `doorbell = phys_base + 2*bank_stride - 0x1000`.  
At product `phys_base=0x30000000` that is **`0x302FF000`**, not `≥0x30300000`.  
Map *ends* at `0x30300000`. Parent lower-bound was off by one page.

**Naive enlarge at `0x30000000` is ABI-dead** (ARM scope §1.4): bank0 payload  
`0x30000000..0x30151800` overwrites bitstream ring `0x30100000` and PLXB `0x30140000`.

---

## 2. Compatibility choice: **parallel opt-in tier (not silent remap)**

| Choice | Why |
|--------|-----|
| **Keep product 480p constants frozen** | Shipping RBF wires `DDR_FRAME_*` 480p into `present_core`. Silent change → `sendDdrFrame` PLXD stall class (88509163). |
| **Add `DDR_FRAME_720P_*` / `kPlex720p*`** | Host+RTL lockstep; daemon opts in only after PLXG handshake with matching RBF. |
| **Option-C phys base `0x30180000`** | Clears bitstream ring + legacy 0x3007F page from bank payloads. |

### Before / after table

| Field | 480p product (unchanged) | 720p tier (new) |
|-------|--------------------------|-----------------|
| `phys_base` | `0x30000000` | **`0x30180000`** |
| `bank_stride` | `0x00080000` | **`0x00180000`** |
| `map_bytes` | `0x00100000` | **`0x00300000`** |
| bank0 | `0x30000000` | **`0x30180000`** |
| bank1 | `0x30080000` | **`0x30300000`** |
| `doorbell_phys` | `0x300FF000` | **`0x3047F000`** |
| PLXD (doorbell+0x128) | `0x300FF128` | **`0x3047F128`** |
| PLXG (doorbell+0x130) | reserved | **`0x3047F130`** |
| coded/display/presented | 624 / 618 / 640 ×480 | **1280 / 1280 / 1280 ×720** |
| HPS mmap length | `map_bytes` (1 MiB) | **`map_bytes` (3 MiB)** |

Migration rule: core advertises tier via PLXG enable+coded size; daemon  
`setDdrFrameLayout` remaps only when PLXG ACK matches. Mismatch → refuse publish  
(never ring foreign doorbell).

---

## 3. Variable-geometry register / mailbox contract (coord w-scaler)

Shipping silicon: geometry is **synthesis-fixed** (`ddr_frame_layout_params.svh` →  
`ddr_frame_store` parameters). w-scaler fabric content window is the runtime path  
for *content* WxH inside a bank; bank stride/doorbell still need a programmed tier.

### PLXG (doorbell-relative `+0x130`, magic `PLXG` = `0x504C5847`)

| Bits (hi word) | Field |
|----------------|-------|
| [11:0] | `coded_w` |
| [23:12] | `coded_h` |
| [24] | `enable` (0 = use synthesis product geometry) |
| [25] | `native_push` (1 = bank payload is tight content I420 @ origin; fabric window scales) |
| [31:26] | reserved 0 |
| lo word | magic `PLXG` |

**Content window** (w-scaler): separate or extended words for  
`content_w/h`, `content_x0/y0`, `win_enable` — already modeled in  
`tests/unit/test_fabric_content_window_math.cpp`. PLXG `native_push` is the  
ARM-side twin: when set, `frame_bytes` for memcpy is  
`yuv420pFrameBytes(content_w,content_h)` not full canvas.

**Handshake (required to avoid bank desync):**

1. ARM writes PLXG (enable=1, coded 1280×720) while playback stopped.  
2. FPGA latches on vsync idle; echoes coded size in PLXS diagnostic or PLXG readback.  
3. ARM remaps `/dev/mem` to Option-C window; only then `sendDdrFrame` with 720p plan.  
4. Teardown: enable=0 → both sides revert to product 480p layout before next play.

---

## 4. Memory tiering (“use all the memory”)

Board facts: Cyclone V M10K, **one** SDRAM stick (do not enable dual-SDRAM QSF),  
1 GiB DDR3 shared HPS/FPGA. Fit note (RBF `8fdf440f`): M10K 465/553 blocks,  
~2.66 Mbit free bits if deep/wide consolidated; 88 free blocks vanish under many  
shallow RAMs (`docs/linebuf-repack-and-qpel-scope.md`).

| Tier | What belongs here | 720p24 BW | 720p30 BW | Notes |
|------|-------------------|----------:|----------:|-------|
| **M10K** | Line buffers only (Y/U/V ping-pong). 1280 B luma = **exactly 1 M10K bit-width budget** per deep bank if repacked | Scanout line traffic local | same | Today 48 shallow arrays waste blocks (16% bit eff.). Repack to 3 deep SDPs before growing LINE_COUNT. |
| **SDRAM (single stick)** | Prefetch / spill / memtest path already via PLXM; optional **second-line staging** so DDR3 fabric read can run ahead of scanout | Design target: absorb **one** 720p chroma plane spill ~0.44 MB/f if DDR3 wait spikes | same | Do **not** put primary present banks in SDRAM — HPS writer path is DDR window. Single stick only. |
| **DDR3 (HPS window)** | Double-bank I420 present store + doorbell page + bitstream ring | ARM push **33.2 MB/s** + fabric readback | **41.5 MB/s** push | Primary path. |

### Does 33.2 MB/s push + fabric readback fit?

| Term | 720p24 | 720p30 | Evidence |
|------|-------:|-------:|----------|
| ARM→DDR write | 33.2 MB/s | 41.5 MB/s | bytes×fps |
| Pure copy ms @ 59.521 MiB/s | **22.15 ms** | 22.15 ms | p480-bandwidth archive |
| vs frame budget | 53% of 41.7 ms | 66% of 33.3 ms | bus alone OK |
| Fabric read (if full-frame every 60 Hz refresh) | +82.9 MB/s | +82.9 MB/s | 1382400×60 — **upper bound**; actual reader is line-timed DE, not free-run full dump |
| Combined upper bound | ~116 MB/s | ~124 MB/s | ≪ HPS DDR3 peak class (~GB/s); **not** the limiter on paper |

**Plain verdict:** Bus **does not** block 720p24; 720p30 copy is tight but under budget as pure fill.  
**CPU decode/scale** remains the open binding constraint (ARM scope v3).  
**Unknown:** large-copy efficiency at 1.38 MB (only 449280 B measured) — settle with  
`tools/ddr_write_bench` at 1382400 on device (parent-owned).

---

## 5. fab-dma — **zero ARM per-pixel at 720p24** (hard gate)

### Parent hardware 2026-08-02 (real 720p content — supersedes synthetic blip)

| Measure | ms/f | Source |
|---------|-----:|--------|
| 1280×720 @4000k decode-only, default threads | **41.073** | parent device verdict |
| 24 fps budget | **41.667** | 1000/24 |
| Residual after decode | **0.594 (1.4%)** | budget − decode |
| 624×480 @1800k decode-only | 15.969 | same harness |
| FEED non-decode @480p (present+pipe+scale) | **18.628** | 10.411+5.263+2.954 |

**Invalidates:** any plan that leaves ARM memcpy of 720p I420 (~22.15 ms @59.521 MiB/s)
or scaled non-decode (~3× memory-bound → tens of ms). Ship gate is
`ddr720p24ShipAcceptsZeroArmPerPixel` — `arm_push_bytes==0`.

**Choice:** FPGA-written Option-C banks (`makeDdrFpgaWrittenBankPlan`) over
ARM tight-write fabric-owned present. Fabric-owned ARM write remains a **bridge**
for 480p evacuation only — not 720p24 ship.

## 5b. Fabric-owned present (480p bridge / intermediate)

**Choice (mandate):** Prefer fabric scale + black-pad + placement over ARM canvas
pad. At 720p24 this is **necessary but not sufficient** — pixel push must also leave ARM.

| ARM job today | Fabric-owned path | ARM ms removed | How known |
|---------------|-------------------|----------------|-----------|
| ffmpeg `vf` scale/pad | **FabricScale** (w-scaler window) | **2.95 ms/f** | FEED archive scale bucket (`SCALE_SKIP_PREREG.md`) — **480p figure**; 720p scale wall **unknown** until parent remeasures |
| `packYuv420pCentered` | **FabricPlacement** PLXG x0/y0 | **unknown** | not separately profiled — settle with present_profile before/after |
| `clearYuv` crop black | **FabricBlackPad** | **unknown** (≤ strip 4320 B ≪ frame) | byte upper bound only |
| `memcpy` full canvas | tight `publish_bytes` only | **copy projection** | `(canvas−native) @ 59.521 MiB/s` from `p480-bandwidth.md` |
| decode + tight write | still ARM until FPGA decode | **0 removed** (remaining) | parent 1080p blip 32.4 ms/f is decode-bound evidence, not present |

### Quantified floors (host unit `test_ddr_720p_abi`)

| Scenario | ARM push B | copy ms @59.521 | copy ms removed | +FEED scale | **known_ms_removed_floor** |
|----------|-----------:|----------------:|----------------:|------------:|---------------------------:|
| 320×240 content, 480p canvas fabric-owned | 115200 | 1.846 | **5.353** | 2.95 | **≈8.30 ms/f** |
| 1280×720 content, 720p canvas fabric-owned | 1382400 | 22.149 | 0 | 2.95† | **≈2.95 ms/f** † |
| 624×480 content, 720p canvas fabric-owned | 449280 | 7.199 | **≈14.95** | 2.95 | **≈17.9 ms/f** |

† 2.95 is the **480p FEED** scale bucket. Claiming it at 720p would be a guess —
unit still adds it only as `scale_ms_removed_feed480` named field. Parent must
remeasure vf wall on real 720p to replace it.

**Not claimed:** full present 10.41 → 10.41−8.30 (fixed PLXD/doorbell do not
scale with pad bytes). Settle with `ddr_copy_us` vs `ddr_total_us` split on device.

**PL330 DMA:** design-only. Moves the same `publish_bytes` — frees CPU cycles,
not bus volume. Inferior to fabric-owned byte reduction; do not prioritize over
FabricScale/BlackPad.

**Implemented (host):** `makeDdrFabricOwnedPresentPlan`, `makeDdrFabricOwnedPublishPlan`,
`DdrArmPresentBudget`, PLXG geometry + content window + origin beats,
forbids-ARM helpers.  
**Not implemented:** RTL consume of PLXG, daemon path that skips ffmpeg scale_pad,
device wire.

---

## 6. What is product vs design-only

| Item | Status |
|------|--------|
| 480p constants unchanged | **product** |
| 720p constants in `.hpp` + `.svh` | **contract locked**; not wired into `present_core` |
| `makePlex720pDdrFrameLayout` / `ddrFrameLayoutMatches720pTier` | **host ready** |
| `ddrFrameStoreAccepts720pTier` | **host ready** (product `AcceptsResolution` still rejects 720p) |
| PLXG offset/magic | **reserved** in mailbox_abi + layout headers |
| `present_core` / `ddr_frame_store` runtime mux | **design** (needs fit slot — not this lane) |
| Device mmap/bench at 1.38 MB | **parent** |

---

## 7. Explicit unknowns

| Unknown | Check that settles it |
|---------|----------------------|
| `/dev/mem` Option-C map at `0x30180000` | **PARENT-VERIFIED 2026-08-02**: `memmap=513M$511M` reserves `0x1FF00000..0x40000000`; Option-C base/doorbell/end inside; `/proc/iomem` unclaimed. Headroom ≈251.5 MB. Triple-buffer map fits. |
| Copy rate at 1382400 B (not scaled from 449280) | Parent: `ddr_write_bench --len 1382400` |
| Fabric full-frame read BW vs line-timed DE | Sim or ILA on `ddram_frame_rd` issue rate @720p |
| CPU headroom with PMS-delivered 720p (no ARM upscale) | Parent soak + `ffprobe` real stream WxH |

## fabric_ddr_writer (RTL)

Module: `fpga/Plex_MiSTer/rtl/fabric_ddr_writer.sv`  
TB: `tests/unit/test_fabric_ddr_writer_verilator.sh`  
Iface: `docs/fabric-ddr-writer-iface.md`

- Parameterised geometry (480p and 720p are parameter sets).
- Fills I420 bank, drain fence, one doorbell (PLXK).
- Macro `FABRIC_DDR_WRITER` default **OFF** (commented in `Plex.qsf`).
- Burst arithmetic: 720p30 = 5.8% of clk_ddr@90MHz @ 8B/cycle; outstanding=1 closes
  if arbiter grant ≥ ~6%. Shared-bus grant is **unverified on device**.

## Parent 720p decode tier sweep (2026-08-02)

Real content, decode-only, both cores (ms/f): 1500k=32.427 (headroom 9.24),
2500k=36.845, 3500k=38.751, 4000k=41.073 (0.59). Candidate tier **1500 kbit**.
Tier saves up to 8.65 ms/f vs 4000k — **jitter margin only**. Full 720p ARM
memcpy still ~22.15 ms and fails `ddr720p24ArmCopyExceedsCandidateTierMargin`.
Ship gate remains `publish_bytes=0` / FPGA-written banks via `fabric_ddr_writer`.
