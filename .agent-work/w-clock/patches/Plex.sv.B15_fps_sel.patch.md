# PATCH for w-osd (Plex.sv owner) — B15 product wiring

**Do not whole-file copy Plex.sv.** Apply this surgically.

## Goal
`content_fps` must be driven by `plex_content_fps_sel` from **`plxg_*`** nets
(w-mem producer names). Delete bare `wire [7:0] content_fps = 8'd24`.

## Canonical snippet (w-clock tree already has this)

```systemverilog
// B15 + ABI #2 — q5 cadence. w-mem drives plxg_* after B16 promote.
// FAULT_B15_FPS_HARDWIRE_24: red twin only.
`ifdef FAULT_B15_FPS_HARDWIRE_24
wire [7:0] content_fps = 8'd24;
`else
wire        plxg_fps_valid   = 1'b0; // REPLACE with w-mem latch output
wire [7:0]  plxg_content_fps = 8'd0; // REPLACE with w-mem latch output
wire [7:0]  content_fps;
plex_content_fps_sel u_content_fps_sel (
	.fps_valid(plxg_fps_valid),
	.content_fps_q5(plxg_content_fps),
	.content_fps_eff(content_fps)
);
`endif
```

Wire `present.content_fps(content_fps)`.

## present_core new ports (defaults OK if unconnected)
- win_*/geom_*/geom_live_seq/geom_live_valid/q5_reserved_reject
- stat_geom_hold_black, stat_geom_hollow

## Gate
`tests/unit/test_b15_product_fps_wiring.sh`
