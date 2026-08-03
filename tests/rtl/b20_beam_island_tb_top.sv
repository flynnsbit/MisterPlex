// b20_beam_island_tb_top — rd-duck integrated B20 NBA lag / island class.
//
// Instantiates REAL present_beam_content_de (runtime DE @ v_wrap) plus the
// present_core hold/feed-forward policy. Does NOT use the blind beam_de_hold
// TB that levels rt_de_apply high before v_wrap without app-shadow timing.
//
// Timing under test (matches present_core ↔ store):
//   beam raises frame_start via NBA at v_wrap; observers see it next clk (hc=1).
//   Store/app promote on that delayed frame_start.
//   If beam latched OLD DE at v_wrap and hold clears at hc=1 → island frame
//   (NEW app 320 inside OLD beam 624 DE).
//
// PRODUCT: pend feed-forward when swap_armed at v_wrap, AND/OR beam_ack hold
// until applied seq is ACKed after swap settles.
// FAULT_B20_NO_BEAM_FEEDFORWARD + FAULT_B20_NO_BEAM_HOLD → island_fault.
`timescale 1ns / 1ps
`default_nettype none

module b20_beam_island_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        swap_pending,
	input  wire        pending_ready,
	input  wire        pend_valid,
	input  wire [10:0] pend_hde,
	input  wire [10:0] pend_vde,
	input  wire [15:0] pend_seq,
	input  wire [10:0] app_hde_in,
	input  wire [10:0] app_vde_in,
	input  wire [15:0] applied_seq_in,
	input  wire        swap_applied_pulse_in,
	output wire [10:0] hde_act,
	output wire [10:0] hc,
	output wire [10:0] vc,
	output wire        frame_start,
	output wire        b20_beam_hold,
	output wire        b20_hold,
	output wire        island_fault,
	output wire        swap_armed_o
);

	wire ce_pix, hb, hs, vb, vs;
	wire [10:0] htot_act, vact_act, vtot_act;

	wire swap_armed = swap_pending && pending_ready && pend_valid;
	assign swap_armed_o = swap_armed;

`ifdef FAULT_B20_NO_BEAM_FEEDFORWARD
	wire [10:0] beam_hde = app_hde_in;
	wire [10:0] beam_vde = app_vde_in;
	wire        beam_apply = 1'b1;
`else
	wire [10:0] beam_hde = swap_armed ? pend_hde : app_hde_in;
	wire [10:0] beam_vde = swap_armed ? pend_vde : app_vde_in;
	wire        beam_apply = swap_armed || !swap_pending;
`endif
	wire [10:0] beam_htot = (beam_hde != 11'd0) ? (beam_hde + 11'd32) : 11'd656;

	present_beam_content_de #(
		.H_DE(624), .V_ACTIVE(48),
		.H_TOTAL(656), .V_TOTAL(56),
		.H_SYNC_S(624 + 8), .H_SYNC_E(624 + 16),
		.V_SYNC_S(48 + 2), .V_SYNC_E(48 + 4)
	) u_beam (
		.clk(clk),
		.reset(reset),
		.use_rt_vtotal(1'b0),
		.rt_vtotal(11'd0),
		.use_rt_geom(1'b1),
		.rt_h_de(beam_hde),
		.rt_h_total(beam_htot),
		.rt_v_active(beam_vde),
		.rt_de_apply(beam_apply),
		.ce_pix(ce_pix),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.frame_start(frame_start),
		.hc_out(hc),
		.vc_out(vc),
		.vtot_active(vtot_act),
		.hde_active(hde_act),
		.htot_active(htot_act),
		.vact_active(vact_act)
	);

	reg [15:0] beam_ack_seq;
	reg        beam_ack_pending;
	always @(posedge clk) begin
		if (reset) begin
			beam_ack_seq <= 16'd0;
			beam_ack_pending <= 1'b0;
		end else begin
			if (swap_applied_pulse_in)
				beam_ack_pending <= 1'b1;
			if (frame_start && beam_ack_pending && !swap_applied_pulse_in) begin
				beam_ack_seq <= applied_seq_in;
				beam_ack_pending <= 1'b0;
			end
		end
	end

`ifdef FAULT_B20_NO_BEAM_HOLD
	assign b20_beam_hold = 1'b0;
`else
	assign b20_beam_hold = beam_ack_pending ||
		(applied_seq_in != 16'd0 && beam_ack_seq != applied_seq_in);
`endif

	assign b20_hold = b20_beam_hold;

	wire app_np1 = (applied_seq_in == 16'd17) && (app_hde_in == 11'd320);
	wire beam_old = (hde_act == 11'd624);
	wire active = ~hb & ~vb;
	assign island_fault = app_np1 && beam_old && !b20_hold && active;

endmodule
`default_nettype wire
