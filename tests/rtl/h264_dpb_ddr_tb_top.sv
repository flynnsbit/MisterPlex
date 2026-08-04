// TB top for DDR-resident DPB units (slot_mgr, byte bridge, ref win cache).
`default_nettype none

module h264_dpb_ddr_tb_top (
	input  wire        clk,
	input  wire        reset,

	// --- slot mgr ---
	input  wire        sm_idr,
	input  wire        sm_frame_done,
	input  wire [15:0] sm_frame_num,
	output wire        sm_ref_ready,
	output wire [2:0]  sm_ref_count,
	output wire [2:0]  sm_current_slot,
	output wire [31:0] sm_current_base,
	output wire [31:0] sm_ref_base0,
	output wire [31:0] sm_ref_base1,
	output wire [31:0] sm_ref_base2,
	output wire [31:0] sm_ref_base3,
	output wire        sm_alloc_error,
	output wire        sm_evict_pulse,

	// --- byte bridge ---
	input  wire        br_mem_we,
	input  wire [31:0] br_mem_waddr,
	input  wire [7:0]  br_mem_wdata,
	input  wire        br_mem_rd,
	input  wire [31:0] br_mem_raddr,
	output wire [7:0]  br_mem_rdata,
	output wire        br_mem_rvalid,
	output wire        br_ddr_want,
	input  wire        br_ddr_busy,
	output wire [7:0]  br_ddr_burstcnt,
	output wire [28:0] br_ddr_addr,
	input  wire [63:0] br_ddr_dout,
	input  wire        br_ddr_dout_ready,
	output wire        br_ddr_rd,
	output wire [63:0] br_ddr_din,
	output wire [7:0]  br_ddr_be,
	output wire        br_ddr_we,

	// --- ref win cache ---
	input  wire        wc_ref_ready,
	input  wire [31:0] wc_reference_base,
	input  wire        wc_fetch_start,
	input  wire [7:0]  wc_fetch_mb_x,
	input  wire [7:0]  wc_fetch_mb_y,
	input  wire [2:0]  wc_fetch_part_mode,
	input  wire [1:0]  wc_fetch_part_idx,
	input  wire signed [15:0] wc_fetch_mv_x,
	input  wire signed [15:0] wc_fetch_mv_y,
	output wire        wc_fetch_busy,
	output wire        wc_fetch_done,
	output wire        wc_fetch_error_no_ref,
	output wire        wc_luma_window_valid,
	output wire [8:0]  wc_luma_window_idx,
	output wire [7:0]  wc_luma_window_sample,
	output wire        wc_chroma_u_window_valid,
	output wire        wc_chroma_v_window_valid,
	output wire [6:0]  wc_chroma_window_idx,
	output wire [7:0]  wc_chroma_window_sample,
	output wire        wc_ddr_want,
	input  wire        wc_ddr_busy,
	output wire [7:0]  wc_ddr_burstcnt,
	output wire [28:0] wc_ddr_addr,
	input  wire [63:0] wc_ddr_dout,
	input  wire        wc_ddr_dout_ready,
	output wire        wc_ddr_rd
);
	h264_dpb_slot_mgr #(
		.NUM_SLOTS(5),
		.DPB_PHYS_BASE(32'h3080_0000),
		.DPB_SLOT_STRIDE(32'h0018_0000)
	) u_sm (
		.clk(clk),
		.reset(reset),
		.idr_start(sm_idr),
		.frame_done(sm_frame_done),
		.frame_num(sm_frame_num),
		.ref_ready(sm_ref_ready),
		.ref_count(sm_ref_count),
		.current_slot(sm_current_slot),
		.current_base(sm_current_base),
		.ref_base0(sm_ref_base0),
		.ref_base1(sm_ref_base1),
		.ref_base2(sm_ref_base2),
		.ref_base3(sm_ref_base3),
		.alloc_error(sm_alloc_error),
		.evict_pulse(sm_evict_pulse)
	);

	h264_dpb_ddr_byte_bridge u_br (
		.clk(clk),
		.reset(reset),
		.mem_we(br_mem_we),
		.mem_waddr(br_mem_waddr),
		.mem_wdata(br_mem_wdata),
		.mem_rd(br_mem_rd),
		.mem_raddr(br_mem_raddr),
		.mem_rdata(br_mem_rdata),
		.mem_rvalid(br_mem_rvalid),
		.ddr_want(br_ddr_want),
		.ddr_busy(br_ddr_busy),
		.ddr_burstcnt(br_ddr_burstcnt),
		.ddr_addr(br_ddr_addr),
		.ddr_dout(br_ddr_dout),
		.ddr_dout_ready(br_ddr_dout_ready),
		.ddr_rd(br_ddr_rd),
		.ddr_din(br_ddr_din),
		.ddr_be(br_ddr_be),
		.ddr_we(br_ddr_we)
	);

	// Small geometry for cache TB speed (64x64 I420).
	h264_dpb_ref_win_cache #(
		.FRAME_W(64),
		.FRAME_H(64)
	) u_wc (
		.clk(clk),
		.reset(reset),
		.ref_ready(wc_ref_ready),
		.reference_base(wc_reference_base),
		.fetch_start(wc_fetch_start),
		.fetch_mb_x(wc_fetch_mb_x),
		.fetch_mb_y(wc_fetch_mb_y),
		.fetch_part_mode(wc_fetch_part_mode),
		.fetch_part_idx(wc_fetch_part_idx),
		.fetch_mv_x_qpel(wc_fetch_mv_x),
		.fetch_mv_y_qpel(wc_fetch_mv_y),
		.fetch_busy(wc_fetch_busy),
		.fetch_done(wc_fetch_done),
		.fetch_error_no_ref(wc_fetch_error_no_ref),
		.luma_frac_x(),
		.luma_frac_y(),
		.chroma_frac_x(),
		.chroma_frac_y(),
		.luma_origin_x(),
		.luma_origin_y(),
		.chroma_origin_x(),
		.chroma_origin_y(),
		.luma_window_valid(wc_luma_window_valid),
		.luma_window_idx(wc_luma_window_idx),
		.luma_window_sample(wc_luma_window_sample),
		.chroma_u_window_valid(wc_chroma_u_window_valid),
		.chroma_v_window_valid(wc_chroma_v_window_valid),
		.chroma_window_idx(wc_chroma_window_idx),
		.chroma_window_sample(wc_chroma_window_sample),
		.ddr_want(wc_ddr_want),
		.ddr_busy(wc_ddr_busy),
		.ddr_burstcnt(wc_ddr_burstcnt),
		.ddr_addr(wc_ddr_addr),
		.ddr_dout(wc_ddr_dout),
		.ddr_dout_ready(wc_ddr_dout_ready),
		.ddr_rd(wc_ddr_rd)
	);
endmodule

`default_nettype wire
