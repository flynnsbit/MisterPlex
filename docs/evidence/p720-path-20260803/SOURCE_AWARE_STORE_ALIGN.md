# Source-aware PMS request + fabric store alignment (w-path)

**Date:** 2026-08-04  
**Branch:** `w-path-720p`  
**Parent ask:** request source geometry (clamped to max box, W snap-16 / H even) so deliveries pass w-mem `rt_raw_ok`.

## Cross-lane defect (parent × w-mem)

Fixed ladder `640×360` on majority library class **624×480** (72/142 = 51%):

| request | delivered | w%16 | store |
|---------|-----------|------|-------|
| 640×360 | **468×360** | **4** | **REJECT** (`rt_raw_ok=0`) |

ARM budget for 360@30 was PASS; fabric deliverability was FAIL. Budget ≠ deliverability.

## w-mem reject path (quoted, no RTL edit)

From `MisterPlex-wt-mem/.../ddr_frame_store.sv`:

```systemverilog
// coded_w must be 16-aligned: chroma fetch is coded_w>>4 qwords (= w/2 bytes).
wire rt_raw_aligned = (rt_coded_w[3:0] == 4'd0) && !rt_coded_h[0] && ...;
wire rt_raw_ok = rt_raw_nonzero && rt_raw_in_range && rt_raw_aligned;
wire geom_enable_eff = geom_enable & rt_raw_ok;
// Loud reject (parent PMS AR-fit): geom requested but raw fails → sticky fault.
// Without this, !geom_enable_eff silently reloads LEGACY 624×480 and scans a
// host native buffer as the wrong pitch (shear). Prefer black + PLXF 0xE2.
wire geom_reject_now = geom_enable & ~rt_raw_ok;
```

**Today when store rejects:**

1. `geom_enable_eff=0` → effective dims reload **parameter legacy** `CODED_W/H` (still a picture path).
2. **Loud reject (`geom_reject_r` + black + PLXF `0xE2`) is in the w-mem worktree only — unmerged.** Product tree may still silent-legacy until that merge lands. Coordinate: path must not emit unaligned coded_w; do not claim loud-reject is live product.

`LEG_BANK_USABLE_BYTES = 0x7F000 = 520192`.

| geometry | I420 bytes | legacy fit | spare |
|----------|------------|------------|-------|
| 624×480 | 449280 | YES | 70912 |
| 320×240 | 115200 | YES | — |
| 720×480 | **518400** | YES | **1792** (99.66%) |
| 960×540 | 777600 | NO | needs Option-C |

**720×480 flag for w-mem:** 1792 B spare with zero stride pad. Any y_stride > coded_w overflows legacy usable. Confirm stride==width on product path before shipping 720×480 banks.

## PMS rule (unchanged)

Ceiling fit-box, never upscale, AR-preserve into min(source, request). Identity request of source avoids AR-fit that manufactures bad widths.

## Implementation

| piece | role |
|-------|------|
| `selectSourceAwarePmsRequest` in `pms_delivery_geom.hpp` | clamp source→max box; W↓16; H even |
| `resolvePlayTarget` | after media WxH, rewrite `weakEff.videoResolution`; fill `request/store*` |
| `main.cpp` doPlay | `setDecodeSize(store)`; log `SOURCE_AWARE` |
| `prove_ladder_delivery.sh` | hard `FABRIC_ALIGN` fail; `source-aware` + `align-check` rungs |
| `test_resolve` | red/green for 624, 426, 468 NEG, 720 spare |

## Measured prove (host PMS)

### source-aware majority

```
PLEX_KEY=/library/metadata/36  request 624x480 → delivered 624x480  w%16=0  PASS
scripts/prove_ladder_delivery.sh source-aware → FAILS=0
```

### align-check survey classes

| class | request | delivered | aligned | note |
|-------|---------|-----------|---------|------|
| 624×480 | 624×480 | 624×480 | YES | majority |
| 320×240 | 320×240 | 320×240 | YES | |
| 640×480 | 640×480 | 640×480 | YES | |
| 704×396 | 704×396 | 704×396 | YES | |
| 426 native | 426×240 | 426×240 | **NO** w%16=10 | red twin |
| 426 →416 | 416×240 | **416×234** | YES | **use this** |
| 426 →432 | 432×240 | 426×240 | **NO** | PMS no upscale |
| bad 360 AR-fit | 640×360 | 468×360 | **NO** | control FAIL |

`align-check` **FAILS=0** after policy: 416 expected deliv 416×234; 432 expected reject.

### 426×240 rule (measured, not reasoned)

- **Do not** request 426 (unaligned) or 432 (ignored → 426).
- **Do** request floor-16 **416×240** → PMS delivers **416×234** (aligned).
- Daemon `selectSourceAwarePmsRequest(426,240,…)` → request/store **416×240**.

## Decode budget re-derive (deliverable geometries)

**Machine class:** the 21.562 / 10.411 / 5.263 stack is **DE10-Nano dual-A9** (W-FEED ARM profile archive), **not** the x86 build machine. Always publish the decomposition with the total.

Device @624×480 (ms/f): decode_null **21.562** + scale **2.954** + pipe **5.263** + parent_copy **2.309** + present/DDR **10.411** = **40.190**.
- decode+pipe+present = **37.236**
- fabric owns present → decode+pipe = **26.825** → @30 margin **6.51 ms**

| geometry | pixels | scale vs 624×480 | est. work ms/f (identity, no scale) | @24 (41.7) | @30 (33.3) |
|----------|--------|------------------|--------------------------------------|------------|------------|
| 624×480 (51%) | 299520 | 1.00× | ~37.2 (dec+pipe+pres) | **PASS** margin ~4.5 | **FAIL** mean (device p99 pending) |
| 320×240 | 76800 | 0.26× | ~10–12 (linear rough) | PASS | PASS |
| 720×480 | 345600 | 1.15× | ~42–43 | **borderline** | FAIL |
| 960×540 | 518400 | 1.73× | prior ~33.6 work | PASS@24 detail | UNSCORED@30 |
| 416×234 (426 class) | ~97k | 0.33× | small | PASS | PASS |

**Ship ladder (fabric-valid):**

1. **Source-aware identity** for library (majority 624×480@24 honest).
2. **960×540@24** only when source ≥ that box (3.5% library).
3. **Withdraw fixed 640×360 as default ship rung** for 624×480 class — fabric reject.
4. 540@30 remains UNSCORED pending device p99.

## Residual gaps (named, not closed)

- `DELIVERED_GEOM_NOT_PROPAGATED` — measured banner still does not retarget PLXG/bank mid-session.
- 720×480 1792 B spare — w-mem must confirm stride policy.
- Host pad if PMS ever ignores floor-snap on other odd widths — only 426 class proven so far.

## Parent commands

```bash
# unit
make $PWD/build/test_resolve && ./build/test_resolve

# live PMS (token file mode-0600)
PLEX_BASE=… PLEX_KEY=/library/metadata/2 PLEX_TOKEN_FILE=… \
  scripts/prove_ladder_delivery.sh source-aware
PLEX_BASE=… PLEX_TOKEN_FILE=… scripts/prove_ladder_delivery.sh align-check
```

No device touch this turn (powered down; hardware parent-only).
