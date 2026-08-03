# H ownership agreement — w-clock ↔ w-scaler

**Status:** paper contract for merge / rd-duck audit.  
**Scaler refs (sibling, not merged):** `3d76945f` Y qword+1, `1bdfdb36` 720p READ proof,
`0704c70d` `FABRIC_NATIVE_720P_GEOM`.

## Who owns what

| Concern | Owner | Module / signal |
|---------|-------|-----------------|
| **Glass H/V counters, blanking, sync** | **w-clock** when `PRESENT_MULTI_PIXEL` | `present_beam_ppc` (`glass_x0`, `glass_y`, `lane_de`, H*/V*) |
| **Glass H/V when macro OFF** | product Template | `colorbars` `hc`/`vc`, **H_DE=529** (FBAR lock — do not move) |
| **Glass → store map (NN window)** | **w-scaler** | `present_content_window` (Template path / win_enable) |
| **CODED/stride/bank READ geom** | **w-scaler** | `ddr_frame_store` runtime geom / Option-C / `MAX_CODED_W=1280` |
| **Y qword+1 dual-port** | **shared API** | `line_buf_ram.rd_addr_b` / `y_q_hi` — both lanes implement same ports |
| **N-wide YUV extract + serializer** | **w-clock** | `yuv_bt601_npx`, `present_npx_path` |

## Assembled multi-pixel READ path (intended merge)

```
present_beam_ppc.glass_x0/y   // w-clock owns glass step (+PPC)
        │
        ▼
[optional] present_content_window with h_de=1280, identity or pillar map
        │  // w-scaler owns non-identity maps; must NOT keep H_DE=529 here
        ▼
ddr_frame_store.rd_x/y        // store pixel coords
        │
        ├─ y_rd_addr = src_x[>>3]
        └─ y_rd_addr_hi = y_rd_addr+1   // straddle safety net
        ▼
yuv_bt601_npx (PPC lanes) → present_npx_path → 1 px CE
```

**w-clock today (this branch):** identity clamp `glass → FRAME_*` (no content_window
instance under the ifdef). That is correct **only** when `FRAME`/`CODED`/`DISPLAY`
are programmed **1280×720** (native-**source** banks).  

**Product path (parent-measured) is 960×540 source → 1280×720 glass.** Identity is
**wrong** for that path: glass x≥960 / y≥540 clamp to last store pixel → smear, not
4/3 upscale. Guard: `MP_IDENTITY_FRAME_EQ_GLASS` + sim `$error` when FRAME≠glass.
**w-scaler must land glass→store** before MP+use_ext product fit. See
`SOURCE_VS_OUTPUT_GEOM_SWEEP.md`. If FRAME stays 640/480, clamp is even worse.

## Right-edge arithmetic (1280 active)

| Fact | Value | Consequence |
|------|------:|-------------|
| 1280 % 8 | **0** | Last luma sample is last byte of qword **159**; no partial Y qword |
| 1280 % 2 | **0** | PPC=2 last group `x0=1278` → samples 1278–1279, both qword 159 |
| 1280 % 4 | **0** | PPC=4 last group `x0=1276` → 1276–1279, all qword 159 |
| 1650 % 2 | **0** | H_TOTAL even — PPC=2 clean line wrap |
| 1650 % 4 | **2** | PPC=4 needs **short final blanking step of 2** — `present_beam_ppc` handles |

### Active-region Y straddle?

For beam contract **`glass_x0 % PPC == 0`** (true every step from 0 by construction):

- PPC∈{2,4} on 1280 DE: every lane group lies in **one** Y qword.
- **`y_qword_hi` is not required for aligned DE**; it remains the safety net for
  unaligned maps (scaler window that can emit non-multiple-of-PPC store X, or
  future pillar offsets).

### Disagreement class rd-duck is hunting

| Bad assumption | Symptom |
|----------------|---------|
| Scaler keeps mapping from **colorbars hc** with **H_DE=529** while beam emits 1280 sync | Wrong store X; pillars/shear; “720p timing” with 529 content |
| Beam and window **both** step H | Double-advance or stalled DE |
| Someone treats 1280 as odd / needs hi at x=1272 | Unnecessary hi read; if hi_valid forced at OOB → garbage last pixels |
| PPC=4 and H_TOTAL short step ignored | Line length drift, HSync wander |

**Resolution rule:** Under `PRESENT_MULTI_PIXEL` + `use_ext`, **only the beam**
drives glass H/V/sync. Scaler may map `glass_x0 → store_x` but must take
**beam coordinates and h_de=1280**, not Template 529 hc.

## Port-level agreement (dual-port)

Both trees:

```systemverilog
// line_buf_ram
.rd_addr_b(y_rd_addr_hi), .rd_data_b(y_q_hi[li])
// yuv / export
y_qword_hi, y_hi_valid  // w-clock consumer; w-scaler also exports rd_y_qword_hi
```

w-scaler export TB: `tests/rtl/ddr_frame_store_qword_export_tb_top.sv` (sibling).  
w-clock consumer: `ddr_frame_store` → `yuv_bt601_npx.y_qword_hi`.

## Escalate to parent if

- Merge wants content_window to keep H_DE=529 under multi-pixel use_ext.
- Scaler requires unaligned store X with PPC>1 without hi_valid plumbing.
- Two modules both drive `HBlank`/`HSync` in the same ifdef arm.
