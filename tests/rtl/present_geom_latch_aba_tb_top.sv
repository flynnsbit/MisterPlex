// B4: present_geom_latch epoch/session ABA.
// Product: epoch!=0 required; (epoch,seq) pair must change.
// B16: commit stages; frame_boundary promotes (TB pulses boundary after commit).
// FAULT: PRESENT_GEOM_LATCH_FAULT_NO_EPOCH → seq-only (pre-B4 ABA).
`timescale 1ns/1ps
`default_nettype none
module present_geom_latch_aba_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        wr_en,
	input  wire [2:0]  wr_idx,
	input  wire [63:0] wr_data,
	input  wire        commit,
	input  wire        frame_boundary,
	output wire        live_valid,
	output wire [15:0] live_seq,
	output wire [13:0] live_epoch,
	output wire        geom_enable,
	output wire        pending_valid
);
	present_geom_latch u (
		.clk(clk), .reset(reset),
		.wr_en(wr_en), .wr_idx(wr_idx), .wr_data(wr_data), .commit(commit),
		.frame_boundary(frame_boundary),
		.win_enable(), .geom_enable(geom_enable),
		.content_w(), .content_h(), .content_x0(), .content_y0(),
		.h_de(), .v_de(), .coded_w(), .coded_h(),
		.y_stride(), .chroma_stride(), .display_w(), .display_h(),
		.present_x(), .present_y(), .crop_left(), .crop_top(),
		.dar_x(), .dar_y(), .content_fps(), .dar_valid(), .fps_valid(),
		.live_valid(live_valid), .live_seq(live_seq), .live_epoch(live_epoch),
		.pending_valid(pending_valid), .promote_pulse(), .q5_reserved_reject()
	);
endmodule
`default_nettype wire
