// B5: present_beam_content_de + present_content_window + ddr_frame_store.
// Default: product-like LEGACY svh params (624/640) — must NOT claim 960 accept.
// +define+BEAM_DDR_TB_LOCAL_960: compile-time 960×540 store (NOT product svh).
`default_nettype none
`include "ddr_frame_layout_params.svh"

module present_beam_ddr_store_tb (
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire        geom_enable,
	input  wire [10:0] rt_coded_w,
	input  wire [10:0] rt_coded_h,
	input  wire [11:0] rt_y_stride,
	input  wire [10:0] rt_chroma_stride,
	input  wire [10:0] rt_display_w,
	input  wire [10:0] rt_display_h,
	input  wire [10:0] rt_present_x,
	input  wire [10:0] rt_present_y,
	input  wire [10:0] rt_crop_left,
	input  wire [10:0] rt_crop_top,
	input  wire        start_req,
	input  wire        bank_sel,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire [7:0]  DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire        DDRAM_WE,
	output wire        frame_start,
	output wire        de_out,
	output wire [10:0] hc,
	output wire [10:0] vc,
	output wire [10:0] store_x,
	output wire [10:0] store_y,
	output wire        rd_active_w,
	output wire [7:0]  rd_r,
	output wire [7:0]  rd_g,
	output wire [7:0]  rd_b,
	output wire        has_frame,
	output wire        swap_pending,
	output wire [15:0] underrun_count,
	output wire [15:0] frames_done,
	output wire        doorbell_ok,
	output wire [7:0]  debug_state,
	output wire [15:0] svh_coded_w,
	output wire [15:0] svh_coded_h,
	output wire [15:0] svh_presented_w,
	output wire [15:0] svh_presented_h,
	output wire [15:0] store_param_w,
	output wire [15:0] store_param_h,
	output wire [15:0] store_param_coded_w,
	output wire [15:0] store_param_coded_h,
	output wire [15:0] store_param_disp_w,
	output wire [15:0] store_param_disp_h,
	output wire [15:0] store_param_pres_x,
	output wire [15:0] store_param_pres_y
);
	localparam int P_H_DE = 960;
	localparam int P_V_ACT = 540;
	localparam int P_H_TOT = 1182;
	localparam int P_V_TOT = 564;

`ifdef BEAM_DDR_TB_LOCAL_960
	// TB-local experimental 960 bank — NOT ddr_frame_layout_params.svh product.
	localparam int ST_FW = 960;
	localparam int ST_FH = 540;
	localparam int ST_CW = 960;
	localparam int ST_CH = 540;
	localparam int ST_DW = 960;
	localparam int ST_DH = 540;
	localparam int ST_PX = 0;
	localparam int ST_PY = 0;
	localparam int ST_CL = 0;
	localparam int ST_CT = 0;
	// 960×540 I420 = 777600 B > product 0x80000 bank — TB uses 1 MiB stride.
	localparam int ST_BANK = 32'h0010_0000;
	localparam [31:0] ST_DOORBELL = 32'h3000_0000 + (2 * ST_BANK) - 32'h1000; // 0x301FF000
`else
	// present_core product-like: QSF FRAME may be 960 but store still svh-coded.
	localparam int ST_FW = 640;
	localparam int ST_FH = 480;
	localparam int ST_CW = DDR_FRAME_CODED_WIDTH;
	localparam int ST_CH = DDR_FRAME_CODED_HEIGHT;
	localparam int ST_DW = DDR_FRAME_DISPLAY_WIDTH;
	localparam int ST_DH = DDR_FRAME_DISPLAY_HEIGHT;
	localparam int ST_PX = DDR_FRAME_PILLARBOX_LEFT;
	localparam int ST_PY = 0;
	localparam int ST_CL = DDR_FRAME_CROP_LEFT;
	localparam int ST_CT = DDR_FRAME_CROP_TOP;
	localparam int ST_BANK = DDR_FRAME_YUV420P_BANK_STRIDE;
	localparam [31:0] ST_DOORBELL = DDR_FRAME_YUV420P_DOORBELL_PHYS;
`endif

	assign svh_coded_w = 16'(DDR_FRAME_CODED_WIDTH);
	assign svh_coded_h = 16'(DDR_FRAME_CODED_HEIGHT);
	assign svh_presented_w = 16'(DDR_FRAME_PRESENTED_WIDTH);
	assign svh_presented_h = 16'(DDR_FRAME_PRESENTED_HEIGHT);
	assign store_param_w = 16'(ST_FW);
	assign store_param_h = 16'(ST_FH);
	assign store_param_coded_w = 16'(ST_CW);
	assign store_param_coded_h = 16'(ST_CH);
	assign store_param_disp_w = 16'(ST_DW);
	assign store_param_disp_h = 16'(ST_DH);
	assign store_param_pres_x = 16'(ST_PX);
	assign store_param_pres_y = 16'(ST_PY);

	wire ce_pix_i, hb, hs, vb, vs, fstart;
	wire [10:0] hc_i, vc_i, vtot_act_i;

	present_beam_content_de #(
		.H_DE(P_H_DE), .V_ACTIVE(P_V_ACT),
		.H_TOTAL(P_H_TOT), .V_TOTAL(P_V_TOT),
		.H_SYNC_S(P_H_DE + 32), .H_SYNC_E(P_H_DE + 32 + 64),
		.V_SYNC_S(P_V_ACT + 8), .V_SYNC_E(P_V_ACT + 8 + 6)
	) beam (
		.clk(clk), .reset(reset),
		.use_rt_vtotal(1'b0), .rt_vtotal(11'd0),
		.use_rt_geom(1'b0), .rt_h_de(11'd0), .rt_v_active(11'd0),
		.ce_pix(ce_pix_i),
		.HBlank(hb), .HSync(hs), .VBlank(vb), .VSync(vs),
		.frame_start(fstart),
		.hc_out(hc_i), .vc_out(vc_i), .vtot_active(vtot_act_i),
		.hde_active(), .vact_active()
	);

	wire [10:0] py = vc_i;
	wire in_content = (hc_i < 11'(P_H_DE)) && (py < 11'(P_V_ACT)) && ~hb && ~vb;

	wire [10:0] store_x_w, store_y_w;
	wire de_r, past_last_row;

	present_content_window #(
		.FRAME_W(960), .FRAME_H(540),
		.STORE_W(1280), .STORE_H(720),
		.H_DE_DEFAULT(P_H_DE), .V_DE_DEFAULT(P_V_ACT)
	) content_win (
		.clk(clk), .reset(reset), .ce_pix(ce_pix_i),
		.hc(hc_i), .py(py), .in_content(in_content),
		.win_enable(1'b1),
		.content_w(11'd960), .content_h(11'd540),
		.content_x0(11'd0), .content_y0(11'd0),
		.h_de(11'd960), .v_de(11'd540),
		.store_x(store_x_w), .store_y(store_y_w),
		.de_r(de_r), .past_last_row(past_last_row)
	);

	localparam int DE_LAG = 3;
	reg [DE_LAG-1:0] hb_sr;
	always @(posedge clk) begin
		if (reset) hb_sr <= {DE_LAG{1'b1}};
		else hb_sr <= {hb_sr[DE_LAG-2:0], hb};
	end
	wire hb_d = hb_sr[DE_LAG-1];
	wire vb_d = vb | past_last_row;
	wire de_out_w = ~hb_d & ~vb_d;
	wire rd_act = de_r;

	wire DDRAM_CLK;
	wire [7:0] DDRAM_BE;

	ddr_frame_store #(
		.FRAME_W(ST_FW),
		.FRAME_H(ST_FH),
		.FRAME_STRIDE(ST_FW),
		.CODED_W(ST_CW),
		.CODED_H(ST_CH),
		.DISPLAY_W(ST_DW),
		.DISPLAY_H(ST_DH),
		.CROP_LEFT(ST_CL),
		.CROP_TOP(ST_CT),
		.PRESENT_X(ST_PX),
		.PRESENT_Y(ST_PY),
		.MAX_CODED_W(1280),
		.MAX_CODED_H(720),
		.LINE_COUNT(32),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(ST_BANK),
		.DOORBELL_PHYS(ST_DOORBELL),
		.DDR_BURST_MAX(128),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1),
		.WANT_Y_LINE_ONLY(1'b1),
		.PENDING_READY_STICKY_PREP(1'b1),
		.PREP_SLOT_RECYCLE(1'b1)
	) store (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(store_x_w),
		.rd_y(store_y_w),
		.rd_active(rd_act),
		.rd_r(rd_r),
		.rd_g(rd_g),
		.rd_b(rd_b),
		.geom_enable(geom_enable),
		.rt_coded_w(rt_coded_w),
		.rt_coded_h(rt_coded_h),
		.rt_y_stride(rt_y_stride),
		.rt_chroma_stride(rt_chroma_stride),
		.rt_display_w(rt_display_w),
		.rt_display_h(rt_display_h),
		.rt_present_x(rt_present_x),
		.rt_present_y(rt_present_y),
		.rt_crop_left(rt_crop_left),
		.rt_crop_top(rt_crop_top),
		.start_req(start_req),
		.bank_sel(bank_sel),
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
		.vsync_pulse(fstart),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(underrun_count),
		.frames_done(frames_done),
		.doorbell_ok(doorbell_ok),
		.debug_state(debug_state)
	);

	assign frame_start = fstart;
	assign de_out = de_out_w;
	assign hc = hc_i;
	assign vc = vc_i;
	assign store_x = store_x_w;
	assign store_y = store_y_w;
	assign rd_active_w = rd_act;
endmodule
`default_nettype wire
