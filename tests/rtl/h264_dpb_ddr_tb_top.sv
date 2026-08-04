// TB top for DPB DDR path + nb cache + area budget + burst NEG.
`default_nettype none

module h264_dpb_ddr_tb_top (
	input  wire clk,
	input  wire reset,

	// area budget 720p / ref=1
	output wire [31:0] bytes_per_ref_frame,
	output wire [31:0] bytes_dpb1_total,
	output wire [31:0] onchip_window_bytes,
	output wire [31:0] onchip_nb_bytes,
	output wire [31:0] onchip_ddr_path_bytes,
	output wire        full_frame_onchip_illegal,
	output wire [31:0] m10k_lower_bound_full_dpb,

	// backend product-default (local 1-cy)
	input  wire        loc_we,
	input  wire [31:0] loc_waddr,
	input  wire [7:0]  loc_wdata,
	input  wire        loc_rd,
	input  wire [31:0] loc_raddr,
	output wire        loc_rvalid,
	output wire [7:0]  loc_rdata,
	output wire [31:0] loc_bank0,
	output wire [31:0] loc_bank1,
	output wire [31:0] loc_onchip_bytes,

	// backend DDR multi-cy
	input  wire        ddr_we,
	input  wire [31:0] ddr_waddr,
	input  wire [7:0]  ddr_wdata,
	input  wire        ddr_rd,
	input  wire [31:0] ddr_raddr,
	output wire        ddr_rvalid,
	output wire [7:0]  ddr_rdata,
	output wire [31:0] ddr_bank0,
	output wire [31:0] ddr_bank1,
	output wire [31:0] ddr_onchip_bytes,

	// nb cache
	input  wire        nb_sample_valid,
	input  wire [7:0]  nb_mb_x,
	input  wire [7:0]  nb_mb_y,
	input  wire [1:0]  nb_plane,
	input  wire [7:0]  nb_sample_idx,
	input  wire [7:0]  nb_sample,
	input  wire        nb_mb_row_done,
	input  wire [15:0] nb_top_x,
	output wire [7:0]  nb_top_y_sample,
	output wire        nb_top_y_valid,
	input  wire [3:0]  nb_left_row,
	output wire [7:0]  nb_left_y_sample,
	output wire        nb_left_y_valid,
	output wire        nb_have_left,
	output wire        nb_have_top,
	output wire [31:0] nb_onchip_total,
	input  wire [7:0]  nb_left_mb_x,
	output wire        nb_left_ok,

	// line fetch good
	input  wire        lf_start,
	input  wire [31:0] lf_base,
	input  wire [4:0]  lf_nbytes,
	output wire        lf_ddr_rd,
	output wire [31:0] lf_ddr_raddr,
	input  wire [63:0] lf_ddr_rdata,
	input  wire        lf_ddr_rvalid,
	output wire        lf_done,
	output wire [7:0]  lf_out0,
	output wire [7:0]  lf_out1,
	output wire [7:0]  lf_out2,
	output wire [7:0]  lf_out3,
	output wire [7:0]  lf_out4,
	output wire [7:0]  lf_out5,
	output wire [7:0]  lf_out6,
	output wire [7:0]  lf_out7,
	output wire [5:0]  lf_count,

	// line fetch FAULT (NEG)
	input  wire        lf_f_start,
	input  wire [31:0] lf_f_base,
	input  wire [4:0]  lf_f_nbytes,
	output wire        lf_f_ddr_rd,
	output wire [31:0] lf_f_ddr_raddr,
	input  wire [63:0] lf_f_ddr_rdata,
	input  wire        lf_f_ddr_rvalid,
	output wire        lf_f_done,
	output wire [7:0]  lf_f_out0,
	output wire [7:0]  lf_f_out1,
	output wire [7:0]  lf_f_out2,
	output wire [7:0]  lf_f_out3,
	output wire [7:0]  lf_f_out4,
	output wire [7:0]  lf_f_out5,
	output wire [7:0]  lf_f_out6,
	output wire [7:0]  lf_f_out7,
	output wire [5:0]  lf_f_count
);
	h264_dpb_area_budget #(.FRAME_W(1280), .FRAME_H(720), .NUM_REF(1)) u_budget (
		.bytes_per_ref_frame(bytes_per_ref_frame),
		.bytes_dpb1_total(bytes_dpb1_total),
		.onchip_window_bytes(onchip_window_bytes),
		.onchip_nb_bytes(onchip_nb_bytes),
		.onchip_ddr_path_bytes(onchip_ddr_path_bytes),
		.full_frame_onchip_illegal(full_frame_onchip_illegal),
		.m10k_lower_bound_full_dpb(m10k_lower_bound_full_dpb)
	);

	h264_dpb_ddr_backend #(
		.FRAME_W(64), .FRAME_H(32), .ENABLE_DPB_DDR(1'b0), .DDR_RD_LATENCY(1)
	) u_local (
		.clk(clk), .reset(reset),
		.mem_we(loc_we), .mem_waddr(loc_waddr), .mem_wdata(loc_wdata),
		.mem_rd(loc_rd), .mem_raddr(loc_raddr),
		.mem_rvalid(loc_rvalid), .mem_rdata(loc_rdata),
		.bank0_base(loc_bank0), .bank1_base(loc_bank1),
		.frame_bytes(), .dual_bank_bytes(),
		.onchip_storage_bytes(loc_onchip_bytes)
	);

	h264_dpb_ddr_backend #(
		.FRAME_W(64), .FRAME_H(32), .ENABLE_DPB_DDR(1'b1), .DDR_RD_LATENCY(4)
	) u_ddr (
		.clk(clk), .reset(reset),
		.mem_we(ddr_we), .mem_waddr(ddr_waddr), .mem_wdata(ddr_wdata),
		.mem_rd(ddr_rd), .mem_raddr(ddr_raddr),
		.mem_rvalid(ddr_rvalid), .mem_rdata(ddr_rdata),
		.bank0_base(ddr_bank0), .bank1_base(ddr_bank1),
		.frame_bytes(), .dual_bank_bytes(),
		.onchip_storage_bytes(ddr_onchip_bytes)
	);

	h264_dpb_nb_cache #(.FRAME_W(64), .FRAME_H(32)) u_nb (
		.clk(clk), .reset(reset),
		.sample_valid(nb_sample_valid),
		.mb_x(nb_mb_x), .mb_y(nb_mb_y),
		.plane(nb_plane), .sample_idx(nb_sample_idx), .sample(nb_sample),
		.mb_row_done(nb_mb_row_done),
		.top_x(nb_top_x), .top_y_sample(nb_top_y_sample), .top_y_valid(nb_top_y_valid),
		.left_row(nb_left_row), .left_y_sample(nb_left_y_sample), .left_y_valid(nb_left_y_valid),
		.have_left_o(nb_have_left), .have_top_o(nb_have_top),
		.onchip_bytes_y(), .onchip_bytes_total(nb_onchip_total)
	);

	h264_dpb_nb_left_ok u_left_ok (
		.mb_x(nb_left_mb_x),
		.cache_have_left(nb_have_left),
		.left_ok(nb_left_ok)
	);

	wire [7:0] lf_b [0:15];
	wire [7:0] lf_fb [0:15];

	h264_dpb_ddr_line_fetch #(.FAULT_SINGLE_BEAT(1'b0)) u_lf (
		.clk(clk), .reset(reset),
		.start(lf_start), .line_base(lf_base), .nbytes(lf_nbytes),
		.ddr_rd(lf_ddr_rd), .ddr_raddr(lf_ddr_raddr),
		.ddr_rdata(lf_ddr_rdata), .ddr_rvalid(lf_ddr_rvalid),
		.done(lf_done), .out_b(lf_b), .out_count(lf_count)
	);
	assign lf_out0 = lf_b[0];
	assign lf_out1 = lf_b[1];
	assign lf_out2 = lf_b[2];
	assign lf_out3 = lf_b[3];
	assign lf_out4 = lf_b[4];
	assign lf_out5 = lf_b[5];
	assign lf_out6 = lf_b[6];
	assign lf_out7 = lf_b[7];

	h264_dpb_ddr_line_fetch #(.FAULT_SINGLE_BEAT(1'b1)) u_lf_fault (
		.clk(clk), .reset(reset),
		.start(lf_f_start), .line_base(lf_f_base), .nbytes(lf_f_nbytes),
		.ddr_rd(lf_f_ddr_rd), .ddr_raddr(lf_f_ddr_raddr),
		.ddr_rdata(lf_f_ddr_rdata), .ddr_rvalid(lf_f_ddr_rvalid),
		.done(lf_f_done), .out_b(lf_fb), .out_count(lf_f_count)
	);
	assign lf_f_out0 = lf_fb[0];
	assign lf_f_out1 = lf_fb[1];
	assign lf_f_out2 = lf_fb[2];
	assign lf_f_out3 = lf_fb[3];
	assign lf_f_out4 = lf_fb[4];
	assign lf_f_out5 = lf_fb[5];
	assign lf_f_out6 = lf_fb[6];
	assign lf_f_out7 = lf_fb[7];
endmodule

`default_nettype wire
