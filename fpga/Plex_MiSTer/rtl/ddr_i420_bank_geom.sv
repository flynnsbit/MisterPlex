// ddr_i420_bank_geom — elaborative I420 HPS bank geometry for present path.
//
// PATH A presentation (w-path). Default parameters match product 480p coded
// banks. Instantiate with the 720p pack (ddr_frame_layout_params.svh
// DDR_FRAME_720P_*) for L4; do not retarget product defaults here.
//
// M10K cost: 0 — no memory arrays, no linebufs (control: no ramstyle / deep
// reg[] storage; layout N/A). ALM: wires + compares only; post-fit UNVERIFIED.
// Against ~356 M10K free after PRODUCT_NO_STUB strip: spends 0 of that budget.
// Does NOT model present line_buf_ram cost (see docs/m10k-depth-width.md).
//
// Not a scanout beam generator (w-clock) and not present_core (w-osd). This is
// the bank ABI math present/store must agree with the ARM writer on.

module ddr_i420_bank_geom #(
	parameter int CODED_W = 624,
	parameter int CODED_H = 480,
	parameter int DISPLAY_W = 618,
	parameter int DISPLAY_H = 480,
	parameter int PRESENTED_W = 640,
	parameter int PRESENTED_H = 480,
	parameter int CROP_LEFT = 0,
	parameter int CROP_TOP = 0,
	parameter int PILLAR_LEFT = 11,
	parameter int PILLAR_RIGHT = 11,
	parameter [31:0] PHYS_BASE = 32'h3000_0000,
	parameter int BANK_STRIDE_BYTES = 32'h0008_0000,
	// 0 = derive doorbell = phys_base + 2*stride - 0x1000
	parameter [31:0] DOORBELL_PHYS = 32'h0
)(
	output wire [31:0] y_plane_bytes,
	output wire [31:0] u_plane_offset,
	output wire [31:0] v_plane_offset,
	output wire [31:0] frame_bytes,
	output wire [15:0] y_stride_bytes,
	output wire [15:0] chroma_stride_bytes,
	output wire [15:0] y_line_qwords,
	output wire [15:0] c_line_qwords,
	output wire [31:0] bank0_base,
	output wire [31:0] bank1_base,
	output wire [31:0] doorbell_phys,
	output wire        frame_fits_bank,      // 1 iff frame_bytes <= BANK_STRIDE
	output wire        doorbell_eq_derived,  // 1 iff doorbell matches ABI formula
	output wire        banks_below_doorbell, // payload ends before doorbell page
	output wire        pillar_math_ok,       // pillar+display == presented (H)
	output wire        chroma_even_ok        // CODED_W/H even (I420 legal)
);
	// I420 planar, coded stride = coded width (no extra pitch).
	localparam int Y_STRIDE_I = CODED_W;
	localparam int C_STRIDE_I = CODED_W / 2;
	localparam int Y_BYTES_I  = CODED_W * CODED_H;
	localparam int C_BYTES_I  = (CODED_W / 2) * (CODED_H / 2);
	localparam int FRAME_I    = Y_BYTES_I + 2 * C_BYTES_I; // == CODED_W*CODED_H*3/2
	localparam int U_OFF_I    = Y_BYTES_I;
	localparam int V_OFF_I    = Y_BYTES_I + C_BYTES_I;
	localparam int Y_QW_I     = CODED_W / 8;
	localparam int C_QW_I     = CODED_W / 16; // chroma plane width/8

	localparam [31:0] DOORBELL_DERIVED =
		PHYS_BASE + (2 * BANK_STRIDE_BYTES) - 32'h1000;
	localparam [31:0] DOORBELL_I =
		(DOORBELL_PHYS == 32'h0) ? DOORBELL_DERIVED : DOORBELL_PHYS;
	localparam [31:0] MAP_END = PHYS_BASE + (2 * BANK_STRIDE_BYTES);

	assign y_plane_bytes       = 32'(Y_BYTES_I);
	assign u_plane_offset      = 32'(U_OFF_I);
	assign v_plane_offset      = 32'(V_OFF_I);
	assign frame_bytes         = 32'(FRAME_I);
	assign y_stride_bytes      = 16'(Y_STRIDE_I);
	assign chroma_stride_bytes = 16'(C_STRIDE_I);
	assign y_line_qwords       = 16'(Y_QW_I);
	assign c_line_qwords       = 16'(C_QW_I);
	assign bank0_base          = PHYS_BASE;
	assign bank1_base          = PHYS_BASE + BANK_STRIDE_BYTES;
	assign doorbell_phys       = DOORBELL_I;

	assign frame_fits_bank = (FRAME_I <= BANK_STRIDE_BYTES);
	assign doorbell_eq_derived = (DOORBELL_I == DOORBELL_DERIVED);
	// Each bank payload must end at or before the doorbell page; doorbell is
	// the last 4 KiB of the two-bank map window when derived.
	assign banks_below_doorbell =
		(FRAME_I <= BANK_STRIDE_BYTES) &&
		(DOORBELL_I + 32'h1000 == MAP_END);

	// CROP_* reserved for reader window; pillar must tile presented width.
	assign pillar_math_ok =
		((PILLAR_LEFT + DISPLAY_W + PILLAR_RIGHT) == PRESENTED_W) &&
		(DISPLAY_H <= PRESENTED_H) &&
		((CROP_LEFT + DISPLAY_W) <= CODED_W) &&
		((CROP_TOP + DISPLAY_H) <= CODED_H);
	assign chroma_even_ok = (CODED_W[0] == 1'b0) && (CODED_H[0] == 1'b0);
endmodule
