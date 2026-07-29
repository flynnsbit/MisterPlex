// TB top: h264_dpb_ddr with BRAM_REF luma plane.
`default_nettype none
module h264_dpb_bram_ref_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        idr_start,
	input  wire        frame_done_req,
	output wire        frame_done_ack,
	output wire        swap_busy,
	output wire        ref_ready,
	output wire [31:0] current_base,
	output wire [31:0] reference_base,
	input  wire        rec_wr_en,
	input  wire [31:0] rec_wr_addr,
	input  wire  [7:0] rec_wr_data,
	output wire        rec_wr_full,
	input  wire        ref_rd_en,
	input  wire [31:0] ref_rd_addr,
	output wire        ref_rd_stall,
	output wire  [7:0] ref_rd_data,
	output wire        ref_rd_valid,
	input  wire        ddr_busy,
	output wire  [7:0] ddr_burstcnt,
	output wire [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output wire        ddr_rd,
	output wire [63:0] ddr_din,
	output wire  [7:0] ddr_be,
	output wire        ddr_we,
	output wire        ddr_req
);
	// Tiny frame for fast BRAM fill: 32x16 Y = 512 B; chroma 16x8*2 = 256 B; stride 768.
	// +define+BRAM_REF_FALLBACK builds the pure-DDR path (BRAM_REF=0).
	h264_dpb_ddr #(
		.FRAME_W(32),
		.FRAME_H(16),
		.DDR_BASE(32'h3040_0000),
		.BANK_STRIDE(768),
		.WR_FIFO_DEPTH(16),
		.REG_RESPONSE(1'b1),
`ifdef BRAM_REF_FALLBACK
		.BRAM_REF(1'b0),
`else
		.BRAM_REF(1'b1),
`endif
		.BRAM_LUMA_ONLY(1'b1)
	) u_dut (
		.clk(clk),
		.reset(reset),
		.idr_start(idr_start),
		.frame_done_req(frame_done_req),
		.frame_done_ack(frame_done_ack),
		.swap_busy(swap_busy),
		.ref_ready(ref_ready),
		.current_base(current_base),
		.reference_base(reference_base),
		.rec_wr_en(rec_wr_en),
		.rec_wr_addr(rec_wr_addr),
		.rec_wr_data(rec_wr_data),
		.rec_wr_full(rec_wr_full),
		.ref_rd_en(ref_rd_en),
		.ref_rd_addr(ref_rd_addr),
		.ref_rd_stall(ref_rd_stall),
		.ref_rd_data(ref_rd_data),
		.ref_rd_valid(ref_rd_valid),
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
endmodule
