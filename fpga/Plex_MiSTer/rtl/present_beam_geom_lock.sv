// present_beam_geom_lock — B20 beam/DE must track *applied* store geometry.
//
// rd-duck cross-lane hole: present_geom_latch promotes PLXG at VSync; beam/window
// was free-running from live content_w/h/h_de. ddr_frame_store applies app_* only
// at (swap_pending && pending_ready) bank swap. If prep misses that boundary,
// next raster used NEW DE map while store kept OLD bank/app pitch.
//
// Product: under live PLXG seq!=0, window/DE dims come from store app_beam_*
// (snapshotted at doorbell, applied with bank). FAULT_B20_BEAM_FREE_RUN uses live.
//
// OWNER: w-mem (handshake with store app_*).

`default_nettype none

module present_beam_geom_lock (
	input  wire        live_valid,
	input  wire [15:0] live_seq,
	// Free-running latch/mux (promote-time).
	input  wire [10:0] live_cw,
	input  wire [10:0] live_ch,
	input  wire [10:0] live_hde,
	input  wire [10:0] live_vde,
	// Applied store beam snapshot (bank-coupled).
	input  wire [10:0] app_cw,
	input  wire [10:0] app_ch,
	input  wire [10:0] app_hde,
	input  wire [10:0] app_vde,
	output wire        use_app,
	output wire [10:0] out_cw,
	output wire [10:0] out_ch,
	output wire [10:0] out_hde,
	output wire [10:0] out_vde
);
`ifdef FAULT_B20_BEAM_FREE_RUN
	// RED twin: beam follows latch promote immediately (REPRO NEW DE / OLD app).
	assign use_app = 1'b0;
`else
	// Live programmed geometry (nonzero seq) → lock beam to applied store.
	assign use_app = live_valid && (live_seq != 16'd0);
`endif
	assign out_cw  = use_app ? app_cw  : live_cw;
	assign out_ch  = use_app ? app_ch  : live_ch;
	assign out_hde = use_app ? app_hde : live_hde;
	assign out_vde = use_app ? app_vde : live_vde;
endmodule

`default_nettype wire
