// TB wrapper: product 480p + 720p pack + negative 720p-on-480p-stride.
module ddr_i420_bank_geom_tb_top (
	// 480p product defaults
	output wire [31:0] p480_frame_bytes,
	output wire [31:0] p480_u_off,
	output wire [31:0] p480_v_off,
	output wire [31:0] p480_doorbell,
	output wire        p480_fits,
	output wire        p480_doorbell_ok,
	output wire        p480_banks_ok,
	output wire        p480_pillar_ok,
	output wire        p480_chroma_ok,
	output wire [15:0] p480_y_qw,
	output wire [15:0] p480_c_qw,
	// 720p w-mem ABI pack
	output wire [31:0] p720_frame_bytes,
	output wire [31:0] p720_u_off,
	output wire [31:0] p720_v_off,
	output wire [31:0] p720_doorbell,
	output wire        p720_fits,
	output wire        p720_doorbell_ok,
	output wire        p720_banks_ok,
	output wire        p720_pillar_ok,
	output wire [15:0] p720_y_qw,
	output wire [15:0] p720_c_qw,
	// NEGATIVE: 720p payload forced onto 480p bank stride (must NOT fit)
	output wire        neg_720_on_480_fits,
	output wire [31:0] neg_720_on_480_frame
);
	ddr_i420_bank_geom #(
		.CODED_W(624), .CODED_H(480),
		.DISPLAY_W(618), .DISPLAY_H(480),
		.PRESENTED_W(640), .PRESENTED_H(480),
		.CROP_LEFT(0), .CROP_TOP(0),
		.PILLAR_LEFT(11), .PILLAR_RIGHT(11),
		.PHYS_BASE(32'h3000_0000),
		.BANK_STRIDE_BYTES(32'h0008_0000),
		.DOORBELL_PHYS(32'h300F_F000)
	) u_480 (
		.y_plane_bytes(), .u_plane_offset(p480_u_off), .v_plane_offset(p480_v_off),
		.frame_bytes(p480_frame_bytes), .y_stride_bytes(), .chroma_stride_bytes(),
		.y_line_qwords(p480_y_qw), .c_line_qwords(p480_c_qw),
		.bank0_base(), .bank1_base(), .doorbell_phys(p480_doorbell),
		.frame_fits_bank(p480_fits), .doorbell_eq_derived(p480_doorbell_ok),
		.banks_below_doorbell(p480_banks_ok), .pillar_math_ok(p480_pillar_ok),
		.chroma_even_ok(p480_chroma_ok)
	);

	ddr_i420_bank_geom #(
		.CODED_W(1280), .CODED_H(720),
		.DISPLAY_W(1280), .DISPLAY_H(720),
		.PRESENTED_W(1280), .PRESENTED_H(720),
		.CROP_LEFT(0), .CROP_TOP(0),
		.PILLAR_LEFT(0), .PILLAR_RIGHT(0),
		.PHYS_BASE(32'h3018_0000),
		.BANK_STRIDE_BYTES(32'h0018_0000),
		.DOORBELL_PHYS(32'h3047_F000)
	) u_720 (
		.y_plane_bytes(), .u_plane_offset(p720_u_off), .v_plane_offset(p720_v_off),
		.frame_bytes(p720_frame_bytes), .y_stride_bytes(), .chroma_stride_bytes(),
		.y_line_qwords(p720_y_qw), .c_line_qwords(p720_c_qw),
		.bank0_base(), .bank1_base(), .doorbell_phys(p720_doorbell),
		.frame_fits_bank(p720_fits), .doorbell_eq_derived(p720_doorbell_ok),
		.banks_below_doorbell(p720_banks_ok), .pillar_math_ok(p720_pillar_ok),
		.chroma_even_ok()
	);

	// NEGATIVE: real 720p coded size on product 480p stride — naive "just set W/H"
	// without retargeting bank stride must fail frame_fits_bank.
	ddr_i420_bank_geom #(
		.CODED_W(1280), .CODED_H(720),
		.DISPLAY_W(1280), .DISPLAY_H(720),
		.PRESENTED_W(1280), .PRESENTED_H(720),
		.PILLAR_LEFT(0), .PILLAR_RIGHT(0),
		.PHYS_BASE(32'h3000_0000),
		.BANK_STRIDE_BYTES(32'h0008_0000), // product 480p stride — too small
		.DOORBELL_PHYS(32'h0)
	) u_neg (
		.y_plane_bytes(), .u_plane_offset(), .v_plane_offset(),
		.frame_bytes(neg_720_on_480_frame), .y_stride_bytes(), .chroma_stride_bytes(),
		.y_line_qwords(), .c_line_qwords(),
		.bank0_base(), .bank1_base(), .doorbell_phys(),
		.frame_fits_bank(neg_720_on_480_fits), .doorbell_eq_derived(),
		.banks_below_doorbell(), .pillar_math_ok(), .chroma_even_ok()
	);
endmodule
