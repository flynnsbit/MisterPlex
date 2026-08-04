# Doorbell SSOT (Cut B — land/cut-b-doorbell)

**Branch:** `land/cut-b-doorbell`  
**Base:** `origin/integ/720p-compose` @ `970889df` + merge `origin/main`  
**Gate:** `make define-parity` → **rc=0**

## Chosen mapping (intentional; not a naive name collision)

Two distinct 720p DDR maps share coded geometry (1280×720 I420, bank stride
`0x00180000`) but **must not share host symbol names** for doorbell PHYS.

| Role | Host SSOT | RTL SSOT | phys_base | doorbell |
|------|-----------|----------|-----------|----------|
| **Product silicon** (`productDdrFrameStoreGeometry`) | `kPlex720pYuv420pDoorbellPhys` | `DDR_FRAME_YUV420P_DOORBELL_PHYS` | `kDdrFramePhysBase` **0x30000000** | **0x302FF000** |
| **Option-C dual-header** (PL330 / `ddr_frame_abi_select` 720p tier) | `kPlex720pOptionCDoorbellPhys` | `DDR_FRAME_720P_YUV420P_DOORBELL_PHYS` | `kPlex720pPhysBase` **0x30180000** | **0x3047F000** |

### Why this mapping

Naive merge paired product host name `kPlex720pYuv420pDoorbellPhys` (main:
`0x302FF000`) to dual-header RTL `DDR_FRAME_720P_YUV420P_DOORBELL_PHYS`
(`0x3047F000`) → **VALUE-DIFF**, `make define-parity` rc≠0.

**Fix (Cut B):**

1. Prefer **product** path as product SSOT: doorbell **0x302FF000** at base
   **0x30000000** (`productDdrFrameStoreGeometry` / `ddrFrameLayoutMatchesProductSilicon`).
2. Dual-header Option-C keeps **0x30180000** / **0x3047F000** under **distinct**
   names: `kPlex720pOptionCDoorbellPhys` ↔ `DDR_FRAME_720P_*`.
3. `scripts/check_define_parity.py`:
   - `DDR_LAYOUT_PAIRS`: `kPlex720pYuv420pDoorbellPhys` → `DDR_FRAME_YUV420P_DOORBELL_PHYS`
   - `DDR_LAYOUT_PAIRS_720P`: `kPlex720pOptionCDoorbellPhys` → `DDR_FRAME_720P_YUV420P_DOORBELL_PHYS`

### Derived product mailboxes (doorbell-relative)

Product doorbell `0x302FF000`:

| Mailbox | Offset | PHYS |
|---------|--------|------|
| PLXS | +0x100 | 0x302FF100 |
| PLXF | +0x118 | 0x302FF118 |
| PLXD | +0x128 | 0x302FF128 |

### Explicit non-goals on this branch

- No product wire enable for publish.
- No FIT_GO / no Quartus fit / no device.
- Integ compose QSF remains FRAME 1280×720 + MULTI/PPC/PLL/FABRIC_FRAME_DMA
  (fit candidate); L4 stays default-off.

### Source anchors

- `host/libmisterplex/ddr_frame_layout.hpp` — product + Option-C constants
- `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh` — dual-header RTL
- `scripts/check_define_parity.py` — host↔RTL pairs
- Unit pins: `tests/unit/test_ddr_bank_mailbox_phys.cpp`,
  `tests/unit/test_product_720p_geometry_static.py`,
  `tests/unit/test_rtl_invariants.py` (OptionC pair already listed)
