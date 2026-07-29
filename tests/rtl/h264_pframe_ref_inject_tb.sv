// Product-path P-frame TB: inject a known I420 reference into the DPB model
// (or optional h264_dpb_ddr BRAM_REF path), drive P_Skip / P16x16 through
// h264_decode_core, score writes against an ffmpeg golden P-frame.
//
// WHY INJECT: product deblock is bypassed, so our DPB is pre-deblock while
// ffmpeg's is post-deblock. Injecting ffmpeg's reconstructed reference makes
// any mismatch an inter-path defect, not an upstream IDR/deblock leak.
`default_nettype none

module h264_pframe_ref_inject_tb #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	// 1 = serve luma ref from h264_dpb_ddr BRAM after prefill+swap
	parameter bit USE_BRAM_DPB = 1'b0
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        slice_start,
	input  wire [15:0] first_mb_in_slice,
	input  wire        mb_type_valid,
	input  wire [4:0]  mb_type,
	input  wire        mb_skip,
	input  wire [15:0] mb_residual_bit_offset,
	input  wire [3:0]  cbp_luma,
	input  wire [1:0]  cbp_chroma,
	input  wire        p16_zero_mv_valid,
	input  wire [7:0]  p16_mb_x,
	input  wire [7:0]  p16_mb_y,
	input  wire        p16_mb_is_ref,
	input  wire [31:0] dpb_ref_base,
	input  wire [31:0] dpb_write_base,
	input  wire signed [15:0] p16_mv_x_qpel,
	input  wire signed [15:0] p16_mv_y_qpel,
	input  wire signed [15:0] p16_mvd_x_qpel,
	input  wire signed [15:0] p16_mvd_y_qpel,
	input  wire [1:0]  p16_ref_idx_l0,
	input  wire signed [15:0] p16_residual_y [0:255],
	input  wire signed [15:0] p16_residual_u [0:63],
	input  wire signed [15:0] p16_residual_v [0:63],
	input  wire [7:0]  rbsp_byte_in [0:63],
	input  wire [15:0] rbsp_window_base,

	// TB memory model (USE_BRAM_DPB=0) — byte RAM the C++ side pre-fills.
	input  wire        tb_mem_we,
	input  wire [31:0] tb_mem_waddr,
	input  wire [7:0]  tb_mem_wdata,
	input  wire [7:0]  tb_mem_rdata,
	input  wire        tb_mem_rvalid,
	input  wire        tb_mem_rstall,

	// Optional product DPB DDR/BRAM sideband
	input  wire        dpb_idr_start,
	input  wire        dpb_frame_done_req,
	output wire        dpb_frame_done_ack,
	output wire        dpb_ref_ready,
	output wire        dpb_swap_busy,
	input  wire        dpb_rec_wr_en,
	input  wire [31:0] dpb_rec_wr_addr,
	input  wire [7:0]  dpb_rec_wr_data,
	output wire        dpb_rec_wr_full,
	input  wire        ddr_busy,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output wire  [7:0] ddr_burstcnt,
	output wire [28:0] ddr_addr,
	output wire        ddr_rd,
	output wire [63:0] ddr_din,
	output wire  [7:0] ddr_be,
	output wire        ddr_we,
	output wire        ddr_req,

	output wire        dpb_rd_en,
	output wire [31:0] dpb_rd_addr,
	output wire        dpb_wr_en,
	output wire [31:0] dpb_wr_addr,
	output wire [7:0]  dpb_wr_data,
	output wire        frame_done,
	output wire [15:0] frame_mb_count,
	output wire [15:0] rbsp_request_offset,
	output wire        rbsp_request_valid,
	output wire        busy,
	output wire [7:0]  decode_state,
	output wire [15:0] current_mb_addr,
	output wire        error,
	output wire        dpb_rd_stall_o,
	output wire [7:0]  dpb_rd_data_o,
	output wire        dpb_rd_valid_o
);
	wire [3:0] intra4x4_modes [0:15];
	wire signed [15:0] luma4x4_coeff_zigzag [0:15];
	wire [7:0] recon_y [0:255];
	wire [7:0] recon_u [0:63];
	wire [7:0] recon_v [0:63];
	genvar zi;
	generate
		for (zi = 0; zi < 64; zi = zi + 1) begin : g0
			assign recon_u[zi] = 8'd0;
			assign recon_v[zi] = 8'd0;
		end
		for (zi = 0; zi < 16; zi = zi + 1) begin : g1
			assign intra4x4_modes[zi] = 4'd0;
			assign luma4x4_coeff_zigzag[zi] = 16'sd0;
		end
		for (zi = 0; zi < 256; zi = zi + 1) begin : g2
			assign recon_y[zi] = 8'd0;
		end
	endgenerate

	localparam [7:0] MB_W = 8'((FRAME_W + 15) / 16);
	localparam [7:0] MB_H = 8'((FRAME_H + 15) / 16);

	wire        core_rd_en;
	wire [31:0] core_rd_addr;
	wire        core_rd_stall;
	wire [7:0]  core_rd_data;
	wire        core_rd_valid;

	generate
		if (USE_BRAM_DPB) begin : g_bram
			h264_dpb_ddr #(
				.FRAME_W(FRAME_W),
				.FRAME_H(FRAME_H),
				.DDR_BASE(32'h3040_0000),
				.BANK_STRIDE(FRAME_W * FRAME_H + 2 * ((FRAME_W / 2) * (FRAME_H / 2))),
				.WR_FIFO_DEPTH(64),
				.REG_RESPONSE(1'b1),
				.BRAM_REF(1'b1),
				.BRAM_LUMA_ONLY(1'b1)
			) u_dpb (
				.clk(clk),
				.reset(reset),
				.idr_start(dpb_idr_start),
				.frame_done_req(dpb_frame_done_req),
				.frame_done_ack(dpb_frame_done_ack),
				.swap_busy(dpb_swap_busy),
				.ref_ready(dpb_ref_ready),
				.current_base(),
				.reference_base(),
				.rec_wr_en(dpb_rec_wr_en),
				.rec_wr_addr(dpb_rec_wr_addr),
				.rec_wr_data(dpb_rec_wr_data),
				.rec_wr_full(dpb_rec_wr_full),
				.ref_rd_en(core_rd_en),
				.ref_rd_addr(core_rd_addr),
				.ref_rd_stall(core_rd_stall),
				.ref_rd_data(core_rd_data),
				.ref_rd_valid(core_rd_valid),
				.ddr_busy(ddr_busy),
				.ddr_burstcnt(ddr_burstcnt),
				.ddr_addr(ddr_addr),
				.ddr_dout(ddr_dout),
				.ddr_dout_ready(ddr_dout_ready),
				.ddr_rd(ddr_rd),
				.ddr_din(ddr_din),
				.ddr_be(ddr_be),
				.ddr_we(ddr_we),
				.ddr_req(ddr_req)
			);
		end else begin : g_tbmem
			assign dpb_frame_done_ack = 1'b0;
			assign dpb_ref_ready = 1'b1;
			assign dpb_swap_busy = 1'b0;
			assign dpb_rec_wr_full = 1'b0;
			assign ddr_burstcnt = 8'd0;
			assign ddr_addr = 29'd0;
			assign ddr_rd = 1'b0;
			assign ddr_din = 64'd0;
			assign ddr_be = 8'd0;
			assign ddr_we = 1'b0;
			assign ddr_req = 1'b0;
			assign core_rd_stall = tb_mem_rstall;
			assign core_rd_data = tb_mem_rdata;
			assign core_rd_valid = tb_mem_rvalid;
		end
	endgenerate

	h264_decode_core #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H)
	) dut (
		.clk(clk),
		.reset(reset),
		.slice_start(slice_start),
		.slice_is_idr(1'b0),
		.slice_is_i(1'b0),
		.slice_qp_y(6'd26),
		.first_mb_in_slice(first_mb_in_slice),
		.mb_width(MB_W),
		.mb_height(MB_H),
		.pps_chroma_qp_index_offset(5'sd0),
		.rbsp_byte(rbsp_byte_in),
		.rbsp_window_base(rbsp_window_base),
		.rbsp_request_offset(rbsp_request_offset),
		.rbsp_request_valid(rbsp_request_valid),
		.mb_type_valid(mb_type_valid),
		.mb_type(mb_type),
		.mb_skip(mb_skip),
		.intra4x4_modes(intra4x4_modes),
		.intra16x16_mode(2'd0),
		.chroma_pred_mode(2'd0),
		.cbp_luma(cbp_luma),
		.cbp_chroma(cbp_chroma),
		.mb_qp_delta(6'sd0),
		.mb_residual_bit_offset(mb_residual_bit_offset),
		.luma4x4_valid(1'b0),
		.luma4x4_idx(4'd0),
		.luma4x4_qp(6'd26),
		.luma4x4_total_coeff(5'd0),
		.luma4x4_trailing_ones(2'd0),
		.luma4x4_coeff_zigzag(luma4x4_coeff_zigzag),
		.mv_x_qpel(p16_mv_x_qpel),
		.mv_y_qpel(p16_mv_y_qpel),
		.part_mode(3'd0),
		.part_idx(2'd0),
		.mvd_x_qpel(p16_mvd_x_qpel),
		.mvd_y_qpel(p16_mvd_y_qpel),
		.ref_idx_l0(p16_ref_idx_l0),
		.recon_mb_valid(1'b0),
		.recon_mb_x(8'd0),
		.recon_mb_y(8'd0),
		.recon_mb_is_ref(1'b0),
		.dpb_write_base(dpb_write_base),
		.recon_y(recon_y),
		.recon_u(recon_u),
		.recon_v(recon_v),
		.p16_zero_mv_valid(p16_zero_mv_valid),
		.p16_mb_x(p16_mb_x),
		.p16_mb_y(p16_mb_y),
		.p16_mb_is_ref(p16_mb_is_ref),
		.dpb_ref_base(dpb_ref_base),
		.p16_residual_y(p16_residual_y),
		.p16_residual_u(p16_residual_u),
		.p16_residual_v(p16_residual_v),
		.dpb_wr_en(dpb_wr_en),
		.dpb_wr_addr(dpb_wr_addr),
		.dpb_wr_data(dpb_wr_data),
		.dpb_rd_en(core_rd_en),
		.dpb_rd_addr(core_rd_addr),
		.dpb_rd_data(core_rd_data),
		.dpb_rd_valid(core_rd_valid),
		.dpb_rd_stall(core_rd_stall),
		.constrained_intra_pred_flag(1'b0),
		.num_ref_idx_l0_active(8'd1),
		.decode_enable(1'b1),
		.dpb_ref_swap(),
		.frame_done(frame_done),
		.frame_mb_count(frame_mb_count),
		.busy(busy),
		.decode_state(decode_state),
		.current_mb_addr(current_mb_addr),
		.error(error)
	);

	assign dpb_rd_en = core_rd_en;
	assign dpb_rd_addr = core_rd_addr;
	assign dpb_rd_stall_o = core_rd_stall;
	assign dpb_rd_data_o = core_rd_data;
	assign dpb_rd_valid_o = core_rd_valid;
endmodule

`default_nettype wire
