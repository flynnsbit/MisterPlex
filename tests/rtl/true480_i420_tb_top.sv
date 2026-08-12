`default_nettype none

module true480_i420_tb #(
	parameter int GEOMETRY_FAULT = 0,
	parameter int STALE_DOORBELL_FALLBACK_POLLS = 4096
)(
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire [9:0]  rd_x,
	input  wire [8:0]  rd_y,
	input  wire        rd_active,
	input  wire        vsync_pulse,
	output wire [7:0]  rd_r,
	output wire [7:0]  rd_g,
	output wire [7:0]  rd_b,
	output wire        has_frame,
	output wire [15:0] underrun_count,
	output wire [15:0] frames_done,
	output wire        doorbell_ok,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire [7:0]  DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire        DDRAM_WE,
	output wire        obs_visible_now,
	output wire [9:0]  obs_src_x_now,
	output wire [8:0]  obs_src_y_now,
	output wire        obs_visible_pipe,
	output wire        obs_y_hit,
	output wire        obs_c_hit,
	output wire        obs_y_hit_now,
	output wire        obs_c_hit_now,
	output wire        obs_miss,
	output wire [7:0]  obs_y,
	output wire [7:0]  obs_u,
	output wire [7:0]  obs_v,
	output wire        obs_disp_bank,
	output wire        cfg_active_config,
	output wire [7:0]  cfg_y_fill_stride,
	output wire [31:0] cfg_stale_doorbell_fallback_polls
);
	localparam int PRESENT_X_P = (GEOMETRY_FAULT == 1) ? 10 : 11;
	localparam int CROP_LEFT_P = (GEOMETRY_FAULT == 2) ? 1 : 0;
	wire DDRAM_CLK;
	wire [7:0] DDRAM_BE;
	wire swap_pending;
	wire [7:0] debug_state;
`ifdef PLEX_PRESENT_TRUE_480P
	assign cfg_active_config = 1'b1;
	assign cfg_y_fill_stride = 8'd1;
`else
	assign cfg_active_config = 1'b0;
	assign cfg_y_fill_stride = 8'd0;
`endif
	assign cfg_stale_doorbell_fallback_polls =
	    32'(STALE_DOORBELL_FALLBACK_POLLS);

	ddr_frame_store #(
		.FRAME_W(640),
		.FRAME_H(480),
		.FRAME_STRIDE(640),
		.CODED_W(624),
		.CODED_H(480),
		.DISPLAY_W(618),
		.DISPLAY_H(480),
		.CROP_LEFT(CROP_LEFT_P),
		.CROP_TOP(0),
		.PRESENT_X(PRESENT_X_P),
		.PRESENT_Y(0),
		.LINE_COUNT(8),
`ifdef PLEX_PRESENT_TRUE_480P
		.Y_FILL_STRIDE(1),
`endif
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(32'h0008_0000),
		.DOORBELL_PHYS(32'h300f_f000),
		.STALE_DOORBELL_FALLBACK_POLLS(STALE_DOORBELL_FALLBACK_POLLS)
	) dut (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(rd_x),
		.rd_y(rd_y),
		.rd_active(rd_active),
		.rd_r(rd_r),
		.rd_g(rd_g),
		.rd_b(rd_b),
		.start_req(1'b0),
		.bank_sel(1'b0),
		.status_osd(16'd0),
		.input_cmd_valid(1'b0),
		.input_cmd(8'd0),
		.sdram_test_state(4'd0),
		.sdram_size_code(4'd0),
		.sdram_error_count(16'd0),
		.DDRAM_CLK(DDRAM_CLK),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),
		.vsync_pulse(vsync_pulse),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(underrun_count),
		.frames_done(frames_done),
		.doorbell_ok(doorbell_ok),
		.debug_state(debug_state)
	);

	assign obs_visible_now = dut.rd_visible;
	assign obs_src_x_now = dut.src_x;
	assign obs_src_y_now = dut.src_y;
	assign obs_visible_pipe = dut.rd_visible_d;
	assign obs_y_hit = dut.y_hit_r;
	assign obs_c_hit = dut.c_hit_r;
	assign obs_y_hit_now = dut.y_hit_now;
	assign obs_c_hit_now = dut.c_hit_now;
	assign obs_miss = dut.miss_d;
	assign obs_y = dut.y_pix;
	assign obs_u = dut.u_pix;
	assign obs_v = dut.v_pix;
	assign obs_disp_bank = dut.disp_bank;
endmodule

`default_nettype wire
