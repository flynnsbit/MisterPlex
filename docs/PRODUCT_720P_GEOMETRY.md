# Product 720p geometry switch (w-nostub)

## Contract (product silicon)

| Field | Value |
|---|---|
| coded / display / presented | **1280×720** identity |
| crop / pillar | **0** |
| I420 frame | 1_382_400 B |
| Y / U / V offsets | 0 / 921_600 / 1_152_000 |
| Y / C strides | 1280 / 640 B |
| bank stride | **0x180000** (1.5 MiB) |
| doorbell | **0x302FF000** @ phys `0x30000000` |
| QSF | `FRAME_W=1280` `FRAME_H=720` + `PRODUCT_NO_STUB=1` |

SSOT: `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh` ↔
`host/libmisterplex/ddr_frame_layout.hpp` (`kPlex720p*`,
`productDdrFrameStoreGeometry()`). Gated by `make define-parity` and
`tests/unit/test_product_720p_geometry_static.py`.

Legacy **480p pillarbox** (624/618/640) remains as `kPlex480p*` /
`plex480pDdrFrameGeometry()` helpers — not product silicon.

## M10K PREREG (no fit this lane)

Post-strip free M10K (parent-confirmed `nostub-poststrip1`): **356** (553−197).

Linebuf delta vs 480p (ESTIMATE, not measured):

| band | Δ M10K | remain free |
|---|---|---|
| ideal bits (32 M10K worth of line storage) | 16..32 | ≥324 |
| shallow-pack HI (historical 480p fstore ~96 blocks → ~192..197 @ 2× width) | ~96..101 | ≥255 |

**PREREG_ALM_delta = UNMEASURED** until the next fit of the reconciled tree.
Control for M10K_bytes=1280: one M10K = 10240 bits = 1280 bytes = one 8-bit luma line (HIT).

## Gaps (honest)

1. **Template `H_DE=529`** in `present_core` / `colorbars` — cannot expose 1280 unique
   columns. Full native 720p raster is **w-clock** timing work.
2. At 20 MHz / 60 Hz / 524 lines, max H_total = **636** ≪ 1280 — clock/timing class change required.
3. Fabric publication copy is **w-mem** (not this lane).
4. No fit until reconcile; live device may still run pre-720p RBF.

## Grep audit (product `fpga/Plex_MiSTer/rtl`, post-change)

Run: `rg -n '\b640\b|\b480\b|\b624\b|\b1280\b|\b720\b' fpga/Plex_MiSTer/rtl --glob '*.sv' --glob '*.svh'`

Residual 640/480/624 hits are either chroma half-width (640), comments, or
non-product H.264 diagnostic modules (not in shipping qip path for product).
