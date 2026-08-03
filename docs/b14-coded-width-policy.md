# B14 coded-width policy (w-mem)

**Owner:** w-mem · **Guard:** `ddr_frame_store.sv` `rt_raw_aligned`
(`rt_coded_w[3:0]==0`) · sticky `geom_reject_now` → PLXF `0xE2`.

## Measured defect (parent library survey N=142)

Every source width is `%16==0` **except**:

| Geometry | Count | `w % 16` | Raw B14 |
|----------|------:|---------:|---------|
| 426×240  | 4 (2.8%) | 10 | **reject** |

Guard is **correct**. Without a host policy these four titles hard-reject
(`geom_enable_eff=0`) → black / hollow on capture — looks like a content bug.

## Decision (recorded)

**PAD storage, keep display.**

| Field | 426×240 example |
|-------|----------------:|
| `display_w` / content window | **426** (true source) |
| `coded_w` / y_stride | **432** = `align16(426)` |
| `chroma_stride` | **216** |
| `crop_right` | **6** (implied: coded − display) |
| `crop_left` / `crop_top` | 0 |
| payload I420 | **155,520 B** (still legacy map) |

### Rejected alternatives

| Option | Why not |
|--------|---------|
| Crop 426→416 | Loses 10 columns; changes SAR/AR vs source |
| Accept reject + reason code only | 2.8% library black-screen by design |
| Weaken B14 to `%8` | chroma fetch is `coded_w>>4` qwords; 8-align alone shears (968 trap) |

## Implementation

- Helper: `makeDdrNativePaddedLayout` / `ddrAlignCodedWidth16` (`plxg_record.hpp`)
- Wired: `makeDdrFabricOwnedPresentPlan` auto-pads before PLXG / plane layout
- RTL guard: **unchanged** — unaligned storage still loud-rejects
- Test: `test_ddr_720p_abi` `B14_PAD_426_POLICY`

## ARM push note

Publish bytes = **padded** storage I420. Writer must right-pad each Y/U/V line
(black / 0x80 chroma) when source rows are 426-wide; tight 426 payload without
pad is a host bug (would desync plane bases), not an RTL exception.

## DPB decoupling (parent measure)

DPB is at **source** resolution; 720p present bank does **not** inflate DPB.
Dominant class 624×480 DPB1 ≈ 449 KB separate from Option-C present
1,382,400 B/frame. Do not reserve dual 720p DPB headroom for present ABI.
