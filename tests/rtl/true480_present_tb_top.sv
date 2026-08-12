`default_nettype none

module true480_present_tb (
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	output wire        ce_pix,
	output wire        hblank,
	output wire        vblank,
	output wire [7:0]  r,
	output wire [7:0]  g,
	output wire [7:0]  b,
	output wire        has_frame,
	output wire [15:0] underrun_count,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire [7:0]  DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire        DDRAM_WE,
	output wire        obs_frame_start,
	output wire [9:0]  obs_hc,
	output wire [9:0]  obs_vc,
	output wire [9:0]  obs_py,
	output wire        obs_in_content,
	output wire [9:0]  obs_store_x,
	output wire [8:0]  obs_store_y,
	output wire        obs_visible_now,
	output wire [9:0]  obs_src_x_now,
	output wire [8:0]  obs_src_y_now,
	output wire        obs_visible_pipe,
	output wire        obs_y_hit,
	output wire        obs_c_hit,
	output wire        obs_miss,
	output wire        hook_scan_valid,
	output wire        hook_visible,
	output wire [9:0]  hook_output_x,
	output wire [8:0]  hook_output_y,
	output wire [9:0]  hook_store_x,
	output wire [8:0]  hook_store_y,
	output wire [9:0]  hook_src_x,
	output wire [8:0]  hook_src_y,
	output wire        hook_y_hit,
	output wire        hook_c_hit,
	output wire        hook_miss,
	output wire        hook_soft_c_fallback
);
	wire fs_wr_ready;
	wire sdram_sel;
	wire [26:1] sdram_addr;
	wire [15:0] sdram_din;
	wire sdram_wr;
	wire sdram_rd;
	wire [1:0] sdram_bs;
	wire sdram_refresh;
	wire DDRAM_CLK;
	wire [7:0] DDRAM_BE;
	wire [15:0] ddr_frames_done;
	wire ddr_doorbell_ok;
	wire hsync, vsync;
	wire [15:0] audio_l, audio_r;
	wire [31:0] stat_display_index, stat_content_index, stat_wr_count;
	wire stat_advance, stat_has_audio, stat_audio_underrun, stat_swap_pending;
	wire [7:0] stat_frame_sdram_state;

	present_core #(
		.FRAME_W(640),
		.FRAME_H(480),
		.FRAME_STRIDE(640),
		.FRAME_LINE_COUNT(8)
	) dut (
		.clk(clk),
		.clk_sdram(clk),
		.clk_audio(clk),
		.clk_pix(clk),
		.reset(reset),
		.pal(1'b0),
		.scandouble(1'b1),
		.content_fps(8'd24),
		.display_hz(8'd60),
		.pattern(2'd0),
		.audio_en(1'b0),
		.use_frame_store(1'b0),
		.content_w(11'd618),
		.content_h(11'd480),
		.fs_wr_en(1'b0),
		.fs_wr_pixel(16'd0),
		.fs_wr_reset(1'b0),
		.fs_swap(1'b0),
		.fs_wr_ready(fs_wr_ready),
		.sdram_dout(16'd0),
		.sdram_ready(1'b0),
		.sdram_sel(sdram_sel),
		.sdram_addr(sdram_addr),
		.sdram_din(sdram_din),
		.sdram_wr(sdram_wr),
		.sdram_rd(sdram_rd),
		.sdram_bs(sdram_bs),
		.sdram_refresh(sdram_refresh),
		.ddr_start_req(1'b0),
		.ddr_bank_sel(1'b0),
		.ddr_status_osd(16'd0),
		.ddr_input_cmd_valid(1'b0),
		.ddr_input_cmd(8'd0),
		.ddr_sdram_test_state(4'd0),
		.ddr_sdram_size_code(4'd0),
		.ddr_sdram_error_count(16'd0),
		.clk_ddr(clk_ddr),
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
		.ddr_frames_done(ddr_frames_done),
		.ddr_doorbell_ok(ddr_doorbell_ok),
		.af_wr_en(1'b0),
		.af_wr_data(32'd0),
		.af_wr_flush(1'b0),
		.ce_pix(ce_pix),
		.HBlank(hblank),
		.HSync(hsync),
		.VBlank(vblank),
		.VSync(vsync),
		.r(r),
		.g(g),
		.b(b),
		.audio_l(audio_l),
		.audio_r(audio_r),
		.stat_display_index(stat_display_index),
		.stat_content_index(stat_content_index),
		.stat_advance(stat_advance),
		.stat_has_frame(has_frame),
		.stat_wr_count(stat_wr_count),
		.stat_has_audio(stat_has_audio),
		.stat_audio_underrun(stat_audio_underrun),
		.stat_swap_pending(stat_swap_pending),
		.stat_frame_underruns(underrun_count),
		.stat_frame_sdram_state(stat_frame_sdram_state)
	);

	assign obs_frame_start = dut.fstart;
	assign obs_hc = dut.hc;
	assign obs_vc = dut.vc;
	assign obs_py = dut.py;
	assign obs_in_content = dut.in_content;
	assign obs_store_x = dut.store_x;
	assign obs_store_y = dut.store_y;
	assign obs_visible_now = dut.fstore.rd_visible;
	assign obs_src_x_now = dut.fstore.src_x;
	assign obs_src_y_now = dut.fstore.src_y;
	assign obs_visible_pipe = dut.fstore.rd_visible_d;
	assign obs_y_hit = dut.fstore.y_hit_r;
	assign obs_c_hit = dut.fstore.c_hit_r;
	assign obs_miss = dut.fstore.miss_d;
`ifdef TRUE480_TEST_HOOKS
	assign hook_scan_valid = dut.true480_scan_valid;
	assign hook_visible = dut.true480_visible;
	assign hook_output_x = dut.true480_output_x;
	assign hook_output_y = dut.true480_output_y;
	assign hook_store_x = dut.true480_store_x;
	assign hook_store_y = dut.true480_store_y;
	assign hook_src_x = dut.true480_src_x;
	assign hook_src_y = dut.true480_src_y;
	assign hook_y_hit = dut.true480_y_hit;
	assign hook_c_hit = dut.true480_c_hit;
	assign hook_miss = dut.true480_miss;
	assign hook_soft_c_fallback = dut.true480_soft_c_fallback;
`else
	assign hook_scan_valid = 1'b0;
	assign hook_visible = 1'b0;
	assign hook_output_x = 10'd0;
	assign hook_output_y = 9'd0;
	assign hook_store_x = 10'd0;
	assign hook_store_y = 9'd0;
	assign hook_src_x = 10'd0;
	assign hook_src_y = 9'd0;
	assign hook_y_hit = 1'b0;
	assign hook_c_hit = 1'b0;
	assign hook_miss = 1'b0;
	assign hook_soft_c_fallback = 1'b0;
`endif
endmodule

`default_nettype wire
