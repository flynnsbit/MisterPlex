# integ/fab-720p-planes — readiness (NO FIT)

Base: `w-nostub-reclaim` @ `78717396` (PRODUCT_NO_STUB=1, glass-proven d1b24e0c)
Branch: `integ/fab-720p-planes`
Worktree: `/home/flynnsbit/Projects/MisterPlex-wt-integ-720p`

## Static gates (true rc, not through pipe)

| Command | true rc |
|---------|---------|
| `make define-parity` | **0** |
| `make quartus-sv-subset` | **0** |
| `make verilator-elab` | **0** |
| `make unit` | **0** |
| `tests/unit/test_product_no_stub_dark_silicon.sh` | **0** |
| `python3 tests/unit/test_rtl_invariants.py` | **0** |
| `python3 scripts/rtl_lint.py` | **0** |

**FIT: NOT STARTED — waiting parent grant.**

## Default-OFF / d1b24e0c identity claims (source)

- `PRODUCT_NO_STUB=1` active in Plex.qsf (nostub proven default)
- `PRESENT_MULTI_PIXEL` QSF **commented OFF**; present_core hooks under `ifdef` only
- `FABRIC_DDR_WRITER` QSF **commented OFF**; writer RTL in files.qip but **not instantiated**
- PLXG latch: `plxg_wr_en=0`, `plxg_commit=0` → win_enable/geom_enable stay 0 at reset
- PRODUCT_V_480 hardwire retained (scaler tip had re-enabled scandouble — **reverted**)
- plex_chrome: `idle_en=0` (new ports); existing BOOT_DEMO/cfg_enable **unchanged** from nostub sys_top
- Chrome loader / pace_seq / fabric_ddr_* : in qip, **not** wired into product path

## Merged (committed lint-clean lane RTL)

| Lane | Taken |
|------|--------|
| w-scaler | present_content_window, present_geom_latch, runtime-geom ddr_frame_store, present_core win/geom ports |
| w-clock | present_beam_ppc, yuv_bt601_npx (ifdef OFF) |
| w-mem | fabric_ddr_writer/path, i420_pattern_src, luma_linebuf, Option-C layout headers |
| w-osd | plex_chrome idle plane ports + loader/host_if/pace modules (idle OFF) |

## Skipped (in-flight / dirty)

- w-clock `present_npx_path.sv` full top wiring
- w-mem arbiter3 / attach of writer as 3rd master
- w-osd dirty sys_top chrome DDR poller wiring
- w-scaler qword-export TBs not in snap

## PARENT ARBITRATION REQUIRED

1. **Mailbox +0x130 collision:** w-scaler/w-mem claimed **PLXG @ +0x130**; w-osd claimed **PLXC @ +0x130**.  
   Integration provisional map (NOT final ABI):
   - PLXC +0x130, PLXO +0x138, list +0x140 (chrome RTL defaults)
   - PLXG **+0x2C0** (after 48×8B list) in mailbox_abi_spec + ddr_frame_layout.hpp  
   **Parent must pick final offsets.**

2. **H-count ownership:** colorbars still owns product `hc`; content_window maps free-running hc; beam_ppc is ifdef-off and unconnected. No silent choice of N-pixel owner.

3. **Chrome vs N-pixel:** plex_chrome remains **1 px/clk on clk_hdmi** post-ascal. Multi-pixel present does not fan into chrome. Documented in plex_chrome.sv header.

4. **fabric_ddr_writer ↔ arbiter:** writer needs 3rd DDR master; not in committed set — left uninstantiated.

5. **Default-OFF finding:** scaler tip dropped PRODUCT_V_480 (would re-enable scandouble). Restored for glass parity.

## Unknown / not proven

- Bit-identical RBF to d1b24e0c: **unknown until fit+md5** (static only).
- Runtime PLXG/PLXC DDR pollers: not wired; enable path untested on device.
- Host tests needing lab PMS baseline: GATE_SKIP critical (env), not a code fail.

## No fit

Do not start Quartus until parent grants slot.
