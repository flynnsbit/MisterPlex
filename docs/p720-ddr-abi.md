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

## 5. fab-dma — native-geometry push

| Mode | Bytes/frame | @59.521 MiB/s | Save vs canvas |
|------|------------:|--------------:|---------------:|
| Product canvas 624×480 | 449280 | 7.20 ms | — |
| Native 320×240 into fabric window | **115200** | **1.85 ms** | **74.4%** bytes / ~5.3 ms |
| Native 624×480 into 720p canvas | 449280 | 7.20 ms | 67.5% vs 1382400 |
| Native 1280×720 | 1382400 | 22.15 ms | 0% |

**Implemented (host):** `makeDdrNativePushPlan`, `copyYuv420pNativeOrigin`,  
`ddrPushMsAtRate`, PLXG encode/decode.  
**Not implemented (needs RBF + daemon wire):** fabric `native_push` consume,  
PL330 DMA descriptor path (design only: DMA moves same bytes — saves CPU  
cycles, not bus volume; product hotspot is often scale not memcpy).

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
| `/dev/mem` 3 MiB map at `0x30180000` legal on live image | Parent: parse `/proc/iomem` + trial map |
| Copy rate at 1382400 B (not scaled from 449280) | Parent: `ddr_write_bench --len 1382400` |
| Fabric full-frame read BW vs line-timed DE | Sim or ILA on `ddram_frame_rd` issue rate @720p |
| CPU headroom with PMS-delivered 720p (no ARM upscale) | Parent soak + `ffprobe` real stream WxH |
