# Product 720p L4 composition (reconcile base)

**Base:** `reconcile/main-2026-08-04`  
**Lane:** w-nostub compose — host ↔ RTL contract for the opt-in L4 path.  
**Does not** force default product to 720p. Default remains 480p pillarbox.

## Dual geometry (do not collapse)

| Tier | When | Coded | Presented | Phys base | Doorbell | Bank stride |
|------|------|-------|-----------|-----------|----------|-------------|
| 480p product | QSF default | 624×480 | 640×480 | `0x30000000` | `0x300FF000` | `0x80000` |
| L4 720p | `PLEX_PRESENT_720P_L4` + FRAME 1280×720 | 1280×720 identity | 1280×720 | `0x30180000` | `0x3047F000` | `0x180000` |

SSOT headers:

- RTL: `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh` — `DDR_FRAME_*` + `DDR_FRAME_720P_*`
- Host: `host/libmisterplex/ddr_frame_layout.hpp` — `kPlex480p*` + `kPlex720p*`
- Parity: `scripts/check_define_parity.py` — `DDR_LAYOUT_PAIRS` + `DDR_LAYOUT_720P_PAIRS`

## What composes

1. **RTL** (`present_core.sv` under `PLEX_PRESENT_720P_L4`):  
   `FS_*` ← `DDR_FRAME_720P_*` into `ddr_frame_store` (coded/display/crop/pillar/phys/bank/doorbell).
2. **Host API** (this land):
   - `plex720pDdrFrameGeometry()` / `plex720pDdrFrameStoreLayout()`
   - `ddrFrameLayoutMatchesL4Silicon()`
   - `productDdrFrameStoreGeometry()` / `productDdrFrameStoreLayout()` switch on  
     `-DMISTERPLEX_PRODUCT_720P_L4=1` (must match the L4 RBF recipe)
3. **Default host** (no L4 define): still 480p silicon — shipping path unchanged.

## Enable recipe (fitgate candidate — not default QSF)

```tcl
# Comment out FRAME_W=640 / FRAME_H=480, then:
set_global_assignment -name VERILOG_MACRO "PLEX_PRESENT_720P_L4=1"
set_global_assignment -name VERILOG_MACRO "FABRIC_NATIVE_720P_GEOM=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=1280"
set_global_assignment -name VERILOG_MACRO "FRAME_H=720"
```

Host daemon rebuild for that RBF:

```bash
CXXFLAGS+='-DMISTERPLEX_PRODUCT_720P_L4=1'
```

Without the host define, ARM still publishes 480p banks at `0x30000000` while fabric reads 720p at `0x30180000` — black/shear, not “almost 720p”.

## Refresh honesty (false-PASS trap)

L4 beam totals H=1312 V=762 DE 1280×720:

| clk_sys | fps_eff = clk / (H·V) |
|---------|------------------------|
| 24 MHz (w-clock target) | **24.006 Hz** |
| 20 MHz (today product PLL) | **~16.16 Hz** |

HDMI stills cannot tell 16 Hz from 24 Hz. Geometry-only success ≠ refresh PASS. w-clock owns the pixel/sys clock move.

## Cost (compose land)

| Item | M10K | ALM | Class |
|------|------|-----|-------|
| Host layout / parity / API | 0 | 0 | measured (headers only) |
| Completing 720p SSOT plane/qword params | 0 | 0 | constants; RTL already derived planes from CODED_W×H |
| Full L4 stack fit (linebufs + timing + DMA) | **UNKNOWN** (fit) | **UNKNOWN** | needs w-fitgate integrated fit |

No Quartus in this lane.

### M10K linebuf model — layout stated (parent M10K-width correction)

**Do not use “1280 B = 1 M10K” for this product path.** That premise assumed a legal
byte-wide (or packed 40-bit) *pixel* line. Handbook (Cyclone V): M10K depths are
powers of two; max width **40** bits; **1K×8 = 1024 B** at byte width, not 1280.
Naive 8-bit 1280-px line → **2 M10K** (1K×8 + partial). Packed 256×40 can hit 1280 B
in one block but forces **5-px granularity**.

**What this core actually builds** (control: `ddr_frame_store.sv` + fit fixture):

```text
line_buf_ram #(.WIDTH(Y_LINE_QWORDS), .DATA_W(64))  // depth in *qwords*, 64-bit port
Y_LINE_QWORDS = CODED_W/8;  C_LINE_QWORDS = CODED_W/16;
LINE_SLOTS = 2 * LINE_COUNT  // default LINE_COUNT=8 → 16 slots × (Y+U+V)
```

| Quantity | Value | Control |
|----------|------:|---------|
| Ideal bits @624 coded | 159 744 | `16×(78+2×39)×64` |
| Measured `ddr_frame_store` M10K | **96** | `tests/fixtures/decode_stub_fit_hierarchy_480p.json` entity row |
| Measured block bits | 159 744 | same fixture (matches ideal 624) |
| Bits / M10K used | **1 664** | 159744/96 — **16.25% of 10 240** (shallow pack) |
| Free after strip (budget total) | **356** | parent post-strip fit 197 used; **unaffected** by line layout |

**720p present linebuf ESTIMATE** (same 64b qword architecture; **not** a new fit):

| Model | M10K @1280 | Δ vs measured 96 | Notes |
|-------|----------:|-----------------:|-------|
| Bit-scale from measure | ceil(327680×96/159744)=**197** | **+101** | preserves measured shallow packing |
| Instance-width double | 96×2=**192** | **+96** | depths ~2× (78→160, 39→80) |
| Ideal bits/10240 only | 32 | +16 | **REJECT** — ignores measured packing |
| Naive 8-bit “2 M10K/luma line” | n/a here | — | **different port width**; not our `DATA_W=64` |

Gate output (executed): `python3 tests/unit/test_720p_present_m10k_budget_static.py` →
`est_720=[192..197]`, `margin_with_reclaim=255`, `margin_no_reclaim=-13` (true rc=0).

Against **356 free**: Δ≈96–101 **fits on estimate**, with large residual — but ALM/timing
and non-linebuf L4 M10K remain **UNKNOWN until fitgate fit**. Geometry-only still ≠
refresh PASS @20 MHz (~16.16 Hz).

## Gates

```bash
make define-parity
python3 tests/unit/test_present_720p_l4_compose_static.py
$(CXX) ... -o build/test_720p_l4_host_layout tests/unit/test_720p_l4_host_layout.cpp && ./build/test_720p_l4_host_layout
```

Negative cases: 480p doorbell/phys on 720p tier → VALUE-DIFF; 480p product layout must not `MatchesL4Silicon`.

## Fitgate interface contract (handoff)

When enabling L4, fabric expects:

- Writer phys `kPlex720pPhysBase = 0x30180000`
- Bank stride `0x180000`, doorbell `0x3047F000`
- I420 planes Y@0 U@921600 V@1152000, luma pitch 1280, chroma 640
- `FRAME_W/H=1280/720` or elab `$error` in `present_core`

Do **not** land origin PR #13 hard-default 720p onto reconcile; that overwrote 480p `DDR_FRAME_*` and used a different doorbell map.
