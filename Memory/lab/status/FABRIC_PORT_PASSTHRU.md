# fabric_copy_* clk_ddr passthrough (2026-08-13)

**PORT_OK (source-only).** **FABRIC_PASS=NO.** Soft-skip ≠ PASS.
**PORT_OK ≠ FABRIC_PASS ≠ BUILD_OK ≠ T7 ≠ pfps.**
Live RBF **`ebfe4a12`** still has fstore nets **undriven / tied 0**.
Needs parent exclusive + **NEW** RBF. **No Quartus this card.**

## What landed (lessons worktree)

`emu.fabric_copy_*` hierarchical refs removed from `ddr_frame_store.sv`.
clk_ddr ports only (no clk_pix sample, no `copy_done_level`, no
`u_content_window`, PLXP stays **`0x3047F138`**):

- `ddr_frame_store`: `input fabric_copy_visible`, `input [31:0] fabric_copy_token`
  under `FABRIC_DIRECT_READER`. Gate unchanged:
  `fabric_allows_swap = visible && (copy_token == db_token)`.
- `present_core`: same two inputs under `DDR_FRAME_STORE` +
  `FABRIC_DIRECT_READER`. Wired to `fstore`. No `always @(posedge clk)`.
- `Plex.sv` `present`: `.fabric_copy_visible(fabric_copy_visible)` /
  `.fabric_copy_token(fabric_copy_token)`. `u_fdirect` + `(*keep*)` wires
  unchanged.

Needle: `tests/unit/test_rtl_invariants.sh` fails if `emu.fabric_copy_`
returns in `ddr_frame_store.sv`.

## Live silicon

Lab **`ebfe4a12`**. 13881 FABRIC=1 left alive. fd=0 until a **new** RBF
actually drives the ports. Warning 10030 still describes **this** bitstream.

## Do not

- Treat PORT_OK as swap / T7 / pfps. Do **not** FIT this tick.
- Bounce / kill 13881. No compact. No W-flag-off. No poke.
- Sample copy-done on clk_pix. No RGB565. P4 stay TODO.

## Evidence

`/tmp/misterplex-agent-W-port-rtl.txt`
`/tmp/misterplex-agent-W-swap-rca2.txt`
`Memory/lab/status/FABRIC_HIER_UNDDRIVEN.md`
