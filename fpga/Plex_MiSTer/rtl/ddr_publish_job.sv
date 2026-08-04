// ddr_publish_job — geom-bound publication job for fabric/PL330 copy path.
//
// Binds ddr_i420_bank_geom bank ABI to a single-bank destination address and
// frame length that a fabric DDR→DDR mover (ddr_frame_dma) or HPS PL330 can
// consume. Does NOT perform the copy and does NOT ring the doorbell (w-mem).
//
// Preferred strategic path remains dyn-base direct reader (ddr_frame_base_mux):
// zero mover traffic. This module is for the secondary source→bank path when
// the decode buffer is not already in a presentable bank.
//
// M10K: 0 (wires/params only). Control: no memory arrays.
// Default parameters = product 480p; pass 720p pack for L4.

module ddr_publish_job #(
	parameter int CODED_W = 624,
	parameter int CODED_H = 480,
	parameter [31:0] PHYS_BASE = 32'h3000_0000,
	parameter int BANK_STRIDE_BYTES = 524288,
	parameter [31:0] DOORBELL_PHYS = 32'h0
)(
	input  wire        bank_sel,       // 0 → bank0, 1 → bank1
	input  wire [31:0] src_phys,       // HPS source (staging / decode out)
	output wire [31:0] dst_bank_phys,  // selected bank base
	output wire [31:0] frame_bytes,    // I420 payload length
	output wire [31:0] doorbell_phys,
	output wire        job_legal,      // frame fits bank + doorbell ABI ok
	output wire        src_aligned     // src 8-byte aligned (DMA requirement)
);
	wire [31:0] y_plane_bytes;
	wire [31:0] u_off, v_off;
	wire [31:0] fb;
	wire [15:0] y_stride, c_stride, y_qw, c_qw;
	wire [31:0] b0, b1, db;
	wire fits, db_ok, banks_ok, pillar_ok, chroma_ok;

	ddr_i420_bank_geom #(
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.DISPLAY_W(CODED_W),
		.DISPLAY_H(CODED_H),
		.PRESENTED_W(CODED_W),
		.PRESENTED_H(CODED_H),
		.CROP_LEFT(0),
		.CROP_TOP(0),
		.PILLAR_LEFT(0),
		.PILLAR_RIGHT(0),
		.PHYS_BASE(PHYS_BASE),
		.BANK_STRIDE_BYTES(BANK_STRIDE_BYTES),
		.DOORBELL_PHYS(DOORBELL_PHYS)
	) u_geom (
		.y_plane_bytes(y_plane_bytes),
		.u_plane_offset(u_off),
		.v_plane_offset(v_off),
		.frame_bytes(fb),
		.y_stride_bytes(y_stride),
		.chroma_stride_bytes(c_stride),
		.y_line_qwords(y_qw),
		.c_line_qwords(c_qw),
		.bank0_base(b0),
		.bank1_base(b1),
		.doorbell_phys(db),
		.frame_fits_bank(fits),
		.doorbell_eq_derived(db_ok),
		.banks_below_doorbell(banks_ok),
		.pillar_math_ok(pillar_ok),
		.chroma_even_ok(chroma_ok)
	);

	assign frame_bytes   = fb;
	assign dst_bank_phys = bank_sel ? b1 : b0;
	assign doorbell_phys = db;
	assign job_legal     = fits && db_ok && banks_ok && chroma_ok;
	assign src_aligned   = (src_phys[2:0] == 3'b000);
endmodule
