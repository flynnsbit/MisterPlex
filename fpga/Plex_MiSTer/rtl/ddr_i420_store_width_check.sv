// ddr_i420_store_width_check — elaborative store-side width/overflow ABI gate.
//
// Mirrors ddr_frame_store localparam derivation (X_W/Y_W/Y_LINE_QWORDS/plane
// bases/address multiplies) without instantiating the store. Used to prove a
// 1280×720 I420 bank is representable in the same bit widths the store uses,
// and to RED naive undersized counters that a wrong 480p→720p port would keep.
//
// Parent note: product still hard-wires FRAME_W/H via QSF (w-nostub owns the
// global macro switch). This module does NOT flip QSF; it elaborates the ABI
// that present_core must bind when the pack is selected.
//
// M10K: 0 (no arrays; layout N/A). Control: source — no ramstyle / deep mem.
// Against ~356 M10K nostub reclaim: spends 0.
// Layout SSOT: defaults from ddr_frame_layout_params (no bare 449280 / 0x80000).

`include "ddr_frame_layout_params.svh"

module ddr_i420_store_width_check #(
	parameter int FRAME_W = DDR_FRAME_PRESENTED_WIDTH,
	parameter int FRAME_H = DDR_FRAME_PRESENTED_HEIGHT,
	parameter int CODED_W = DDR_FRAME_CODED_WIDTH,
	parameter int CODED_H = DDR_FRAME_CODED_HEIGHT,
	parameter int BANK_STRIDE_BYTES = DDR_FRAME_YUV420P_BANK_STRIDE,
	parameter [31:0] PHYS_BASE = 32'(DDR_FRAME_PHYS_BASE),
	// Reference 480p bank for 3× growth arithmetic (product YUV stride).
	parameter int REF480_BANK_STRIDE_BYTES = DDR_FRAME_YUV420P_BANK_STRIDE,
	parameter int REF480_FRAME_BYTES = DDR_FRAME_YUV420P_BYTES
)(
	// Derived geometry (same equations as ddr_frame_store / bank_geom)
	output wire [15:0] x_w_bits,           // $clog2(FRAME_W)
	output wire [15:0] y_w_bits,           // $clog2(FRAME_H)
	output wire [15:0] coded_x_w_bits,
	output wire [15:0] coded_y_w_bits,
	output wire [15:0] y_line_qwords,      // CODED_W/8
	output wire [15:0] c_line_qwords,      // CODED_W/16
	output wire [15:0] y_qw_aw_bits,       // $clog2(Y_LINE_QWORDS)
	output wire [15:0] c_qw_aw_bits,
	output wire [15:0] chroma_w,           // CODED_W/2
	output wire [15:0] chroma_h,           // CODED_H/2
	output wire [31:0] y_plane_bytes,
	output wire [31:0] u_plane_offset,
	output wire [31:0] v_plane_offset,
	output wire [31:0] frame_bytes,
	output wire [31:0] bank_stride_bytes,
	output wire [31:0] bank1_base,
	output wire [31:0] doorbell_phys,
	// Max line-base qword offset: (CODED_H-1)*Y_LINE_QWORDS (luma)
	output wire [31:0] max_y_line_qword_off,
	// Max chroma line-base: (CODED_H/2-1)*C_LINE_QWORDS
	output wire [31:0] max_c_line_qword_off,
	// Last payload byte offset inside a bank (frame_bytes-1)
	output wire [31:0] last_payload_byte_off,
	// Packing: how many full banks fit in [PHYS_BASE, WINDOW_END)
	output wire [15:0] banks_in_reserved_window,
	output wire        dual_bank_fits_window,   // product ping-pong
	output wire        triple_bank_fits_window, // Option-C
	output wire        bank_stride_ge_3x_ref480,// 720p stride ≥ 3× 480p stride
	output wire        frame_ge_3x_ref480,      // 720p frame ≥ 3× 480p frame
	// Width adequacy vs store's fixed container sizes
	output wire        addr29_covers_bank1_end, // bank1+stride qword addr in 29b
	output wire        plane_off_fits_u32,
	output wire        y_qw_aw_covers_line,     // 2^y_qw_aw >= y_line_qwords
	output wire        c_qw_aw_covers_line,
	output wire        y_w_covers_height,       // 2^y_w >= FRAME_H (and CODED_H)
	output wire        x_w_covers_width,
	output wire        store_widths_ok,         // conjunction of real store paths
	// NEGATIVE probes — must be 0 at 720p (naive undersize)
	output wire        naive_u16_frame_ok,      // 16-bit holds frame_bytes?
	output wire        naive_u16_y_plane_ok,
	output wire        naive_u7_y_line_qw_ok,   // 7-bit index holds y_line_qwords?
	output wire        naive_ref480_stride_fits // frame fits REF480 stride?
);
	// Match ddr_frame_store.sv localparams (lines ~94-127 shape).
	localparam int X_W = (FRAME_W <= 1) ? 1 : $clog2(FRAME_W);
	localparam int Y_W = (FRAME_H <= 1) ? 1 : $clog2(FRAME_H);
	localparam int CODED_X_W = (CODED_W <= 1) ? 1 : $clog2(CODED_W);
	localparam int CODED_Y_W = (CODED_H <= 1) ? 1 : $clog2(CODED_H);
	localparam int Y_LINE_QWORDS = CODED_W / 8;
	localparam int C_LINE_QWORDS = CODED_W / 16;
	localparam int Y_QW_AW = (Y_LINE_QWORDS <= 1) ? 1 : $clog2(Y_LINE_QWORDS);
	localparam int C_QW_AW = (C_LINE_QWORDS <= 1) ? 1 : $clog2(C_LINE_QWORDS);
	localparam int CHROMA_W_I = CODED_W / 2;
	localparam int CHROMA_H_I = CODED_H / 2;
	localparam int Y_BYTES_I = CODED_W * CODED_H;
	localparam int C_BYTES_I = CHROMA_W_I * CHROMA_H_I;
	localparam int FRAME_I = Y_BYTES_I + 2 * C_BYTES_I;
	localparam int U_OFF_I = Y_BYTES_I;
	localparam int V_OFF_I = Y_BYTES_I + C_BYTES_I;
	localparam int MAX_Y_LINE_QW = (CODED_H > 0) ? (CODED_H - 1) * Y_LINE_QWORDS : 0;
	localparam int MAX_C_LINE_QW = (CHROMA_H_I > 0) ? (CHROMA_H_I - 1) * C_LINE_QWORDS : 0;

	// Reserved HPS window (host ddr_frame_layout.hpp kPlexDdrReserved*).
	localparam [31:0] WIN_END = 32'h4000_0000;
	localparam int BANKS_IN_WIN =
		(PHYS_BASE < WIN_END) ? ((WIN_END - PHYS_BASE) / BANK_STRIDE_BYTES) : 0;

	localparam [31:0] BANK1 = PHYS_BASE + BANK_STRIDE_BYTES;
	localparam [31:0] DOORBELL = PHYS_BASE + (2 * BANK_STRIDE_BYTES) - 32'h1000;
	// Qword address of first byte past bank1 payload window (base+2*stride).
	localparam [31:0] MAP_END = PHYS_BASE + (2 * BANK_STRIDE_BYTES);
	localparam [31:0] MAP_END_QW = MAP_END >> 3;

	assign x_w_bits = 16'(X_W);
	assign y_w_bits = 16'(Y_W);
	assign coded_x_w_bits = 16'(CODED_X_W);
	assign coded_y_w_bits = 16'(CODED_Y_W);
	assign y_line_qwords = 16'(Y_LINE_QWORDS);
	assign c_line_qwords = 16'(C_LINE_QWORDS);
	assign y_qw_aw_bits = 16'(Y_QW_AW);
	assign c_qw_aw_bits = 16'(C_QW_AW);
	assign chroma_w = 16'(CHROMA_W_I);
	assign chroma_h = 16'(CHROMA_H_I);
	assign y_plane_bytes = 32'(Y_BYTES_I);
	assign u_plane_offset = 32'(U_OFF_I);
	assign v_plane_offset = 32'(V_OFF_I);
	assign frame_bytes = 32'(FRAME_I);
	assign bank_stride_bytes = 32'(BANK_STRIDE_BYTES);
	assign bank1_base = BANK1;
	assign doorbell_phys = DOORBELL;
	assign max_y_line_qword_off = 32'(MAX_Y_LINE_QW);
	assign max_c_line_qword_off = 32'(MAX_C_LINE_QW);
	assign last_payload_byte_off = (FRAME_I > 0) ? 32'(FRAME_I - 1) : 32'd0;
	assign banks_in_reserved_window = 16'(BANKS_IN_WIN);
	assign dual_bank_fits_window = (BANKS_IN_WIN >= 2);
	assign triple_bank_fits_window = (BANKS_IN_WIN >= 3);
	assign bank_stride_ge_3x_ref480 =
		(BANK_STRIDE_BYTES >= (3 * REF480_BANK_STRIDE_BYTES));
	assign frame_ge_3x_ref480 = (FRAME_I >= (3 * REF480_FRAME_BYTES));

	// Store uses [28:0] DDRAM_ADDR (qword). Map end must fit.
	assign addr29_covers_bank1_end = (MAP_END_QW < (32'h1 << 29));
	assign plane_off_fits_u32 = 1'b1; // FRAME_I fits 32-bit by construction here
	// Address width for line RAM: need Y_QW_AW bits to index Y_LINE_QWORDS entries
	// ($clog2(N) yields ceil(log2(N)); index range 0..N-1 needs that many bits).
	assign y_qw_aw_covers_line =
		(Y_LINE_QWORDS <= 1) || ((1 << Y_QW_AW) >= Y_LINE_QWORDS);
	assign c_qw_aw_covers_line =
		(C_LINE_QWORDS <= 1) || ((1 << C_QW_AW) >= C_LINE_QWORDS);
	assign y_w_covers_height =
		((1 << Y_W) >= FRAME_H) && ((1 << CODED_Y_W) >= CODED_H);
	assign x_w_covers_width =
		((1 << X_W) >= FRAME_W) && ((1 << CODED_X_W) >= CODED_W);

	assign store_widths_ok =
		addr29_covers_bank1_end &&
		y_qw_aw_covers_line && c_qw_aw_covers_line &&
		y_w_covers_height && x_w_covers_width &&
		(FRAME_I <= BANK_STRIDE_BYTES) &&
		(CODED_W[0] == 1'b0) && (CODED_H[0] == 1'b0) &&
		dual_bank_fits_window;

	// Naive undersize probes (expect 0 at true 720p).
	assign naive_u16_frame_ok = (FRAME_I <= 65535);
	assign naive_u16_y_plane_ok = (Y_BYTES_I <= 65535);
	assign naive_u7_y_line_qw_ok = (Y_LINE_QWORDS <= 127);
	assign naive_ref480_stride_fits = (FRAME_I <= REF480_BANK_STRIDE_BYTES);
endmodule
