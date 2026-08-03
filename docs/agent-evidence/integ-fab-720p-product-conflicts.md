# Integration merge conflicts — integ/fab-720p-product
Base: main 77e1e78d2920c9217da2d75a898cea11406fe13a
Order: w-mem-720p-abi → w-clock-bump → w-scaler-window → w-osd-fabric-plane → w-path-720p

## Merge `w-mem-720p-abi` (90517fa2)
- result: CLEAN

## Merge `w-clock-bump` (df0dbb09)
- result: CONFLICT
  - unresolved: `fpga/Plex_MiSTer/Plex.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/ddr_frame_store.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/line_buf_ram.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/present_beam_content_de.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/present_core.sv`
  - unresolved: `host/libmisterplex/input_mailbox.hpp`
  - unresolved: `tests/unit/test_present_store_scale_math.cpp`
  - unresolved: `tests/unit/test_rtl_invariants.py`
## Merge `w-scaler-window` (3c872e8e)
- result: CONFLICT
  - unresolved: `fpga/Plex_MiSTer/Plex.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/ddr_frame_store.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/line_buf_ram.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/present_beam_content_de.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/present_core.sv`
  - unresolved: `host/libmisterplex/input_mailbox.hpp`
  - unresolved: `tests/unit/test_present_store_scale_math.cpp`
  - unresolved: `tests/unit/test_rtl_invariants.py`

### Resolution policy for `w-clock-bump` (integrator, not a silent pick)

| File | Choice | Why |
|------|--------|-----|
| `Plex.sv` | **mem (ours)** | geom_mux + win/geom ports; clock only had 10-bit ladder stubs |
| `present_core.sv` | **mem (ours)** | win_enable/geom_enable/content_window; clock is parallel npx architecture |
| `present_beam_content_de.sv` | **mem (ours)** | must match mem present_core instance ports |
| `ddr_frame_store.sv` | **mem (ours)** | EXPORT_QWORDS dual-port path; clock npx regs diverge |
| `line_buf_ram.sv` | **mem (ours)** | DUAL_RD param |
| `input_mailbox.hpp` | **UNION** | geomRejected (mem) + pixUnderrunSticky (clock) |
| `test_present_store_scale_math.cpp` | **mem (ours)** | matches mem present_core |
| `test_rtl_invariants.py` | **UNION** | accept mem OR clock clamp forms + keep NATIVE_V checks |

**DISAGREEMENT SURFACED (parent decide if wrong):** clock B13 runtime DE (`use_rt_geom`, npx multi-pixel path) is **not** in the tree after this merge step. Expectation: **w-scaler-window** already unions mem ports + clock runtime beam (`rt_h_de(content_w)`). That is the intended product shape — deferred one merge, not discarded.

**Not a lane fix:** no edits to clock-only semantics beyond taking mem files so the merge can complete; breakage from missing clock-only paths will show in lane tests after full stack merge.
## Merge `w-scaler-window` (3c872e8e)
- result: CONFLICT
  - unresolved: `Makefile`
  - unresolved: `fpga/Plex_MiSTer/Plex.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh`
  - unresolved: `fpga/Plex_MiSTer/rtl/ddr_frame_store.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/line_buf_ram.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/present_beam_content_de.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/present_content_window.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/present_core.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/present_geom_latch.sv`
  - unresolved: `fpga/Plex_MiSTer/rtl/present_video_timing_960.sv`
  - unresolved: `host/libmisterplex/ddr_frame_layout.hpp`
  - unresolved: `host/libmisterplex/mailbox_abi_spec.hpp`
  - unresolved: `tests/unit/test_ddr_720p_abi.cpp`
  - unresolved: `tests/unit/test_rtl_invariants.py`
  - unresolved: `tests/unit/test_unit_rollcall.py`

### Resolution policy for `w-scaler-window`

| File | Choice | Why |
|------|--------|-----|
| present stack RTL (`present_core`, beam, window, latch, timing, store, line_buf, Plex.sv, params) | **scaler (theirs)** | Scaler already unions mem win/geom + clock runtime DE (`rt_h_de(content_w)`) |
| `mailbox_abi_spec.hpp` / `ddr_frame_layout.hpp` | **scaler tip** | PLXG FIXED 0x800 + reachable include; same freeze as mem |
| `test_ddr_720p_abi.cpp` | **scaler** | fuller Option-C matrix + 0x800 checks |
| Makefile / invariants / rollcall | **scaler** | matches scaler product tests |

**Note:** scaler list depth may still be pre-osd MAX_CMDS; osd merge must re-assert 112 + freeze 0x800 without relocating PLXG.
