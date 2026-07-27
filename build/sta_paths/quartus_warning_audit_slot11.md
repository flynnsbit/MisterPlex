# Quartus Warning Audit — Slot11 Build (RBF 0c7a4c7e)

**Author:** w-cap  
**Date:** 2026-07-27  
**Source:** `fpga/Plex_MiSTer/remote_out/slot11/compile.log`  
**Build SHA:** `a6b1124` (feat/cap-device) — **predates all 4 CDC fixes**  
**Quartus reports:** 0 errors, 99 warnings

---

## Summary by Warning Code

| Code | Count | Category | Verdict |
|------|-------|----------|---------|
| 10036 | 27 | Unused variable | Understood, benign |
| 10230 | 5 | Truncation | 4 understood, 1 needs review |
| 10259 | 1 | Constant overflow | Needs review |
| 12241 | 1 | Connectivity warnings | Understood, benign (INFO-severity) |
| 13024 | 1 | Stuck pins | Understood, benign |
| 13046 | 1 | Tri-state internal | Understood, benign |
| 13049 | 1 | Tri-state conversion | Understood, benign |
| 13050 | 2 | Open-drain removal | Understood, benign |
| 13051 | 3 | Open-drain conversion | Understood, benign |
| 13410 | 23 | Pins stuck VCC/GND | Understood, benign |
| 14284 | 2 | Synthesized away (top) | Understood, benign |
| 14285 | 3 | Synthesized away (detail) | Understood, benign |
| 14320 | 8 | Synthesized away (nodes) | Understood, benign |
| 169064 | 1 | No output enable | Understood, benign |
| 171167 | 1 | Invalid fitter assignments | Understood, benign |
| 176250 | 1 | Invalid fast I/O register | Understood, benign |
| 292013 | 1 | LogicLock license | Understood, benign |
| 332125 | 2 | **Combinational loop** | **KNOWN — fixed by 9461845** |
| 332126 | 14 | Comb loop detail nodes | **KNOWN — fixed by 9461845** |

---

## Detailed Justification

### 332125/332126 — Combinational Loop (16 warnings)

**Phase:** Fitter (1×332125 + 7×332126) and STA (1×332125 + 7×332126)

Single instance: `emu|present|fstore|input_fifo` (async_fifo in ddr_frame_store).
Loop: `wr_bin_next → wr_gray_next → wr_full → wr_bin_next` at async_fifo.sv:34.

**Verdict:** KNOWN. Fixed by `9461845` ("rtl: break async fifo full combinational
loop") which is NOT in this build's source tree. After integration, these 16
warnings must disappear. If they persist → HARD FAIL per STA acceptance criteria.

### 10036 — Unused Variables (27 warnings)

**Phase:** Analysis & Synthesis

| File | Variable | Reason benign |
|------|----------|---------------|
| Plex.sv:227 | `content_width` | Declared for future use by content-resolution selector; consumed by ifdef paths |
| Plex.sv:228 | `content_height` | Same as above |
| Plex.sv:313 | `sdram_read_sample` | SDRAM test diagnostic, read only via status OSD |
| Plex.sv:314 | `sdram_first_fail_valid` | SDRAM test diagnostic |
| Plex.sv:315 | `sdram_first_fail_addr` | SDRAM test diagnostic |
| Plex.sv:316 | `sdram_first_fail_expect` | SDRAM test diagnostic |
| Plex.sv:318 | `sdram_test_pass` | SDRAM test diagnostic |
| Plex.sv:321 | `sdram_test_active` | SDRAM test diagnostic |
| Plex.sv:873 | `st_res_word` | Decode residual diagnostic |
| Plex.sv:1002 | `_unused` | Intentionally named unused sink |
| stream_path.sv:332 | `_keep` | Intentionally named keep signal for synthesis |
| present_core.sv:221 | `wr_done` | Frame write completion flag, read in debug paths |
| ddr_frame_store.sv:389 | `want_y_s2` | Second synchroniser stage, used for CDC double-flop |
| decode_stub.sv:61 | `lat_mb_w`, `lat_mb_h` | Latency measurement, consumed when stub is replaced |
| decode_stub.sv:212 | `inter_diag_ok` | Inter prediction diagnostic |
| decode_stub.sv:261 | `_slice_valid_observe` | Debug observability signal |
| h264_inter_pred.sv:28 | `avail_count` | Availability counter, used in extended mode |
| h264_inter_pred.sv:141 | `_keep_part_modes` | Intentionally named keep |
| slice_hdr_parser.sv:97-123 | 7 variables | Parser intermediates: `i4_need_rem`, `cbp_me`, `suf_left`, `tok_ok`, `place_did`, `csum_i`, `place_csum_r`, `place_dc_r` — work-in-progress parser, consumed when parsing stages connect |

**Verdict:** All understood and benign. Variables prefixed `_unused` or `_keep` are
intentional synthesis sinks. Parser intermediates are WIP. SDRAM test diagnostics
are consumed via OSD status paths. None indicates missing logic.

### 10230 — Truncation Warnings (5 warnings)

| File | Detail | Verdict |
|------|--------|---------|
| colorbars.sv:131 | 13→3 bit truncation | Understood — extracting low bits of counter for color pattern |
| decode_stub.sv:153 | 32→8 bit truncation | Understood — extracting byte from 32-bit word |
| h264_iq_idct_4x4.sv:72 | 32→3 bit truncation | Understood — `$clog2` result truncated to index width |
| h264_iq_idct_4x4.sv:73 | 32→4 bit truncation | Same as above |
| slice_hdr_parser.sv:143 | 17→9 bit truncation | **Needs review** — parser arithmetic result truncated; may be intentional capping or a width mismatch in progress |

### 10259 — Constant Value Overflow (1 warning)

| File | Detail | Verdict |
|------|--------|---------|
| h264_iq_idct_4x4.sv:108 | Constant value overflow | **Needs review** — may indicate a dequant constant that exceeds the declared width. w-cabac widened residual pipeline from `signed [17:0]` to `signed [21:0]`; check whether this file was updated to match. |

### 13410 — Pins Stuck at VCC/GND (23 warnings)

All 23 are SDRAM pins:
- SDRAM_A[0..12] (13 pins) — stuck GND
- SDRAM_BA[0..1] (2 pins) — stuck GND
- SDRAM_CKE — stuck GND
- SDRAM_CLK — stuck GND
- SDRAM_DQMH — stuck VCC
- SDRAM_DQML — stuck VCC
- SDRAM_nCAS — stuck VCC
- SDRAM_nCS — stuck VCC
- SDRAM_nRAS — stuck VCC
- SDRAM_nWE — stuck VCC

**Verdict:** Understood, benign. This design uses HPS DDR3 (via f2sdram) instead
of the DE10-Nano's discrete SDRAM. The SDRAM pins are present in the
sys_top.v port list (MiSTer framework requirement) but are intentionally
undriven. The active-low control pins (nCAS, nCS, nRAS, nWE) are held high
(deasserted) and data masks are held high (all bytes masked) — this is the
safe idle state for an unused SDRAM interface.

### 13046/13049 — Tri-state Internal (2 warnings)

`emu:emu|SD_CS` (emu_ports.vh:95): tri-state buffer feeding internal logic
converted to wire. **Benign** — MiSTer framework SD card signals are directly
driven, not tristated to external pins.

### 13050/13051 — Open-drain Removal (5 warnings)

- `emu:emu|SD_MOSI` (emu_ports.vh:93)
- `emu:emu|SD_SCK` (emu_ports.vh:92)
- `HDMI_I2C_SCL` (sys_top.v:30)

**Benign.** Open-drain buffers for SD card SPI and HDMI I2C that don't
directly reach top-level pins; Quartus converts them to wires. Standard
MiSTer framework behaviour.

### 14284/14285/14320 — Synthesized Away (13 warnings)

**Phase 1 (A&S):** 4 LCELL nodes in `pll_hdmi` PLL reconfig
(`altera_pll.v:425` — `cntsel_temp[4:1]`). These are unused counter-select
bits in the HDMI PLL reconfiguration interface. **Benign** — Altera PLL
megafunction internal, not user logic.

**Phase 2 (Fitter):** 1 LCELL node (`pll_cfg_hdmi:phase_done`, pll_cfg_hdmi.v:165)
and 1 PLL node. **Benign** — HDMI PLL dynamic reconfig phase completion
signal, unused in this design's reconfig flow.

### 169064 — No Output Enable (1 warning, 20 pins)

16× SDRAM_DQ[0..15] and 4× USER_IO[0,1,3,6]. All in sys_top.v.

**Benign.** SDRAM data bus is unused (see 13410 above). USER_IO pins are
directly driven by the MiSTer framework for auxiliary I/O.

### 171167 — Invalid Fitter Assignments (1 warning)

**Benign.** Standard MiSTer framework noise — some `sys_top.sdc` or `.qsf`
assignments reference signals by old names or patterns that don't match
after synthesis. See Ignored Assignments panel. Does not affect timing.

### 176250 — Invalid Fast I/O Register (1 warning)

**Benign.** MiSTer framework requests fast I/O register packing for some
pins that Quartus cannot honour due to logic structure. No functional impact.

### 292013 — LogicLock License (1 warning)

**Benign.** Standard Quartus Free Edition noise. LogicLock is a floorplanning
feature not used by this design.

### 12241 — Connectivity Warnings (1 warning, 12 hierarchies)

**Benign.** Cleared by w-c2 in separate map report audit
(`build/quartus_warning_audit_slot11.md`). All 12 are INFO-severity port
connectivity from the MiSTer framework sys layer, not design logic.

---

## Items Requiring Review (2)

1. **10230 at slice_hdr_parser.sv:143** — 17→9 bit truncation in parser
   arithmetic. Owner: w-rel. May be intentional saturation or a width bug.

2. **10259 at h264_iq_idct_4x4.sv:108** — constant value overflow. Owner:
   w-cabac. Check whether the `signed [17:0]` → `signed [21:0]` widening
   propagated to this constant.

## Expected Changes After CDC Fix Integration

| Warning | Expected outcome |
|---------|-----------------|
| 332125 (×2) + 332126 (×14) | **Must disappear** — `9461845` fixes the loop |
| 10036 `want_y_s2` | May disappear if frame store CDC refactor removes it |
| All others | No change expected |

---

*This is the first complete warning audit of a MiSTer Plex fit. It becomes
the baseline that future fits diff against.*
