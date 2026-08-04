// TB: store width elaborator at 480p + 720p; negative undersize probes at 720p.
module ddr_i420_store_width_check_tb_top (
	// 480p product-shaped
	output wire [31:0] p480_frame,
	output wire [15:0] p480_chroma_w,
	output wire [15:0] p480_chroma_h,
	output wire [15:0] p480_y_qw,
	output wire        p480_ok,
	output wire        p480_dual,
	// 720p ABI pack
	output wire [31:0] p720_frame,
	output wire [31:0] p720_u_off,
	output wire [31:0] p720_v_off,
	output wire [15:0] p720_chroma_w,
	output wire [15:0] p720_chroma_h,
	output wire [15:0] p720_y_qw,
	output wire [15:0] p720_c_qw,
	output wire [15:0] p720_y_w_bits,
	output wire [15:0] p720_y_qw_aw,
	output wire [15:0] p720_banks_win,
	output wire [31:0] p720_max_y_line_qw,
	output wire [31:0] p720_doorbell,
	output wire        p720_ok,
	output wire        p720_dual,
	output wire        p720_triple,
	output wire        p720_stride_ge_3x,
	output wire        p720_frame_ge_3x,
	// NEGATIVE probes at 720p (must be 0)
	output wire        neg_u16_frame_ok,
	output wire        neg_u16_y_ok,
	output wire        neg_u7_yqw_ok,
	output wire        neg_ref480_fits,
	// NEGATIVE: 720p coded on 480p FRAME_W/H bit widths only — still ok if CODED set;
	// true RED: 720p frame on 480p bank stride via naive_ref480_fits
	output wire [31:0] neg_ladder_stride_vs_abi
);
	ddr_i420_store_width_check #(
		.FRAME_W(640), .FRAME_H(480),
		.CODED_W(624), .CODED_H(480),
		.BANK_STRIDE_BYTES(524288),
		.PHYS_BASE(32'h3000_0000)
	) u480 (
		.x_w_bits(), .y_w_bits(), .coded_x_w_bits(), .coded_y_w_bits(),
		.y_line_qwords(p480_y_qw), .c_line_qwords(),
		.y_qw_aw_bits(), .c_qw_aw_bits(),
		.chroma_w(p480_chroma_w), .chroma_h(p480_chroma_h),
		.y_plane_bytes(), .u_plane_offset(), .v_plane_offset(),
		.frame_bytes(p480_frame), .bank_stride_bytes(),
		.bank1_base(), .doorbell_phys(),
		.max_y_line_qword_off(), .max_c_line_qword_off(),
		.last_payload_byte_off(), .banks_in_reserved_window(),
		.dual_bank_fits_window(p480_dual), .triple_bank_fits_window(),
		.bank_stride_ge_3x_ref480(), .frame_ge_3x_ref480(),
		.addr29_covers_bank1_end(), .plane_off_fits_u32(),
		.y_qw_aw_covers_line(), .c_qw_aw_covers_line(),
		.y_w_covers_height(), .x_w_covers_width(),
		.store_widths_ok(p480_ok),
		.naive_u16_frame_ok(), .naive_u16_y_plane_ok(),
		.naive_u7_y_line_qw_ok(), .naive_ref480_stride_fits()
	);

	ddr_i420_store_width_check #(
		.FRAME_W(1280), .FRAME_H(720),
		.CODED_W(1280), .CODED_H(720),
		.BANK_STRIDE_BYTES(32'h0018_0000),
		.PHYS_BASE(32'h3018_0000)
	) u720 (
		.x_w_bits(), .y_w_bits(p720_y_w_bits), .coded_x_w_bits(), .coded_y_w_bits(),
		.y_line_qwords(p720_y_qw), .c_line_qwords(p720_c_qw),
		.y_qw_aw_bits(p720_y_qw_aw), .c_qw_aw_bits(),
		.chroma_w(p720_chroma_w), .chroma_h(p720_chroma_h),
		.y_plane_bytes(), .u_plane_offset(p720_u_off), .v_plane_offset(p720_v_off),
		.frame_bytes(p720_frame), .bank_stride_bytes(),
		.bank1_base(), .doorbell_phys(p720_doorbell),
		.max_y_line_qword_off(p720_max_y_line_qw), .max_c_line_qword_off(),
		.last_payload_byte_off(), .banks_in_reserved_window(p720_banks_win),
		.dual_bank_fits_window(p720_dual), .triple_bank_fits_window(p720_triple),
		.bank_stride_ge_3x_ref480(p720_stride_ge_3x),
		.frame_ge_3x_ref480(p720_frame_ge_3x),
		.addr29_covers_bank1_end(), .plane_off_fits_u32(),
		.y_qw_aw_covers_line(), .c_qw_aw_covers_line(),
		.y_w_covers_height(), .x_w_covers_width(),
		.store_widths_ok(p720_ok),
		.naive_u16_frame_ok(neg_u16_frame_ok),
		.naive_u16_y_plane_ok(neg_u16_y_ok),
		.naive_u7_y_line_qw_ok(neg_u7_yqw_ok),
		.naive_ref480_stride_fits(neg_ref480_fits)
	);

	// Plex.sv dead ladder at FRAME 1280x720 yields 0x200000, ABI wants 0x180000.
	// Expose the mismatch constant for the C++ TB (not a DUT output of u720).
	assign neg_ladder_stride_vs_abi = 32'h0020_0000 - 32'h0018_0000;
endmodule
