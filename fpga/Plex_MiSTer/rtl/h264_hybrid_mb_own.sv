// P3-3l5 hybrid MB ownership classifier (product handoff contract).
//
// Documented product rule (docs/phase3-3l-idct.md §3.3l-5):
//   - STREAM may skip host F1 only when FPGA recon_ok
//   - host fallback on CABAC / fail
//   - recon_ok sticky means full I-slice done (telemetry sketch)
//
// Honest MB-level boundary (intra green / inter red as of P3-3l4):
//   FPGA owns only capability-backed MB classes. Unsupported MBs assert
//   host_required + reason; they must never be silently painted as product-ok.
//
// Capability knobs default to today's proven surface and grow without
// redefining the contract as sv-mvd / sv-resadd / sv-ref / sv-traverse land:
//   CAP_INTRA_*  default 1  (native-I420 intra green)
//   CAP_INTER_*  default 0  (inter still product-red)
//   CAP_CABAC    default 0
//   CAP_IPCM     default 0
//
// OWN codes (own_code[2:0]):
//   0 FPGA_INTRA   — FPGA reconstructs this MB for product composite
//   1 HOST_INTER   — inter MB; ARM/host must supply pixels
//   2 HOST_CABAC   — entropy_cabac sticky; whole picture host
//   3 HOST_IPCM    — I_PCM unsupported on FPGA path
//   4 HOST_UNSUP   — unknown / illegal mb_type
//   5 HOST_FAIL    — explicit fail_mb / recon fail from upstream
//   6 HOST_SLICE   — non-I slice with no per-MB FPGA capability yet
//   7 RESERVED
//
// product_mb_ok = fpga_owned && !host_required
// Frame-level product_recon_ok (elsewhere) may assert only when every MB is
// product_mb_ok and reconstruction completed — never on mixed/host frames.

`default_nettype none

module h264_hybrid_mb_own #(
	parameter bit CAP_INTRA_I4   = 1'b1,
	parameter bit CAP_INTRA_I16  = 1'b1,
	parameter bit CAP_IPCM       = 1'b0,
	parameter bit CAP_INTER_PSKIP = 1'b0,
	parameter bit CAP_INTER_P16  = 1'b0,
	parameter bit CAP_INTER_PART = 1'b0, // 16x8/8x16/8x8/sub
	parameter bit CAP_CABAC      = 1'b0
) (
	// Slice / picture context
	input  wire        slice_is_i,
	input  wire        entropy_cabac,
	input  wire        fail_mb,          // upstream sticky fail for this MB
	// MB classification (I-slice mb_type 0..25, or P-slice via flags)
	input  wire        mb_valid,
	input  wire [7:0]  mb_type,          // I: 0=I_NxN, 1-24=I16, 25=IPCM; P raw when is_p_slice
	input  wire        is_p_slice_mb,    // 1 = classify as P-slice MB
	input  wire        p_skipped,        // P_Skip
	input  wire        p_is_intra,       // intra-in-P (mb_type 5..30 on P)
	input  wire        p_is_inter,       // any inter P mode
	input  wire        p_uses_sub_mb,    // 8x8 / sub-partitions
	input  wire [2:0]  p_part_mode,      // from h264_p_mb_type_decode
	input  wire        p_unsupported,    // p-slice mode decoder unsupported

	output wire        fpga_owned,
	output wire        host_required,
	output wire        product_mb_ok,
	output wire [2:0]  own_code,
	output wire [3:0]  own_reason
);
	localparam [2:0] OWN_FPGA_INTRA = 3'd0;
	localparam [2:0] OWN_HOST_INTER = 3'd1;
	localparam [2:0] OWN_HOST_CABAC = 3'd2;
	localparam [2:0] OWN_HOST_IPCM  = 3'd3;
	localparam [2:0] OWN_HOST_UNSUP = 3'd4;
	localparam [2:0] OWN_HOST_FAIL  = 3'd5;
	localparam [2:0] OWN_HOST_SLICE = 3'd6;

	localparam [3:0] RSN_OK_I4      = 4'd0;
	localparam [3:0] RSN_OK_I16     = 4'd1;
	localparam [3:0] RSN_OK_INTER   = 4'd2; // future when CAP_INTER_* grows
	localparam [3:0] RSN_CABAC      = 4'd3;
	localparam [3:0] RSN_IPCM       = 4'd4;
	localparam [3:0] RSN_INTER      = 4'd5;
	localparam [3:0] RSN_UNSUP_TYPE = 4'd6;
	localparam [3:0] RSN_FAIL       = 4'd7;
	localparam [3:0] RSN_P_SLICE    = 4'd8;
	localparam [3:0] RSN_INVALID    = 4'd9;
	localparam [3:0] RSN_NO_CAP_I4  = 4'd10;
	localparam [3:0] RSN_NO_CAP_I16 = 4'd11;

	localparam [2:0] PART_P16x16 = 3'd0;
	localparam [2:0] PART_P16x8  = 3'd1;
	localparam [2:0] PART_P8x16  = 3'd2;
	localparam [2:0] PART_P8x8   = 3'd3;
	localparam [2:0] PART_SUB    = 3'd4;

	reg        r_fpga;
	reg        r_host;
	reg [2:0]  r_code;
	reg [3:0]  r_reason;

	wire is_i_nxn  = (mb_type == 8'd0);
	wire is_i16x16 = (mb_type >= 8'd1) && (mb_type <= 8'd24);
	wire is_ipcm   = (mb_type == 8'd25);

	wire inter_cap =
		(p_skipped && CAP_INTER_PSKIP) ||
		(!p_skipped && p_is_inter && !p_uses_sub_mb &&
		 (p_part_mode == PART_P16x16) && CAP_INTER_P16) ||
		(!p_skipped && p_is_inter &&
		 ((p_part_mode == PART_P16x8) || (p_part_mode == PART_P8x16) ||
		  (p_part_mode == PART_P8x8) || (p_part_mode == PART_SUB) || p_uses_sub_mb) &&
		 CAP_INTER_PART);

	always @* begin
		r_fpga   = 1'b0;
		r_host   = 1'b1;
		r_code   = OWN_HOST_UNSUP;
		r_reason = RSN_INVALID;

		if (!mb_valid) begin
			r_fpga   = 1'b0;
			r_host   = 1'b1;
			r_code   = OWN_HOST_UNSUP;
			r_reason = RSN_INVALID;
		end else if (fail_mb) begin
			r_fpga   = 1'b0;
			r_host   = 1'b1;
			r_code   = OWN_HOST_FAIL;
			r_reason = RSN_FAIL;
		end else if (entropy_cabac && !CAP_CABAC) begin
			// CABAC: whole picture is host (doc: host fallback on CABAC).
			r_fpga   = 1'b0;
			r_host   = 1'b1;
			r_code   = OWN_HOST_CABAC;
			r_reason = RSN_CABAC;
		end else if (is_p_slice_mb) begin
			if (p_unsupported) begin
				r_fpga   = 1'b0;
				r_host   = 1'b1;
				r_code   = OWN_HOST_UNSUP;
				r_reason = RSN_UNSUP_TYPE;
			end else if (p_is_intra) begin
				// Intra-in-P: treat like I MB using mb_type offset if provided;
				// without a mapped I type, require host unless generic intra cap.
				if (CAP_INTRA_I4 || CAP_INTRA_I16) begin
					r_fpga   = 1'b1;
					r_host   = 1'b0;
					r_code   = OWN_FPGA_INTRA;
					r_reason = RSN_OK_I4;
				end else begin
					r_fpga   = 1'b0;
					r_host   = 1'b1;
					r_code   = OWN_HOST_SLICE;
					r_reason = RSN_NO_CAP_I4;
				end
			end else if (p_is_inter || p_skipped) begin
				if (inter_cap) begin
					r_fpga   = 1'b1;
					r_host   = 1'b0;
					r_code   = OWN_FPGA_INTRA; // reuse "fpga owned" code 0 with inter reason
					r_reason = RSN_OK_INTER;
				end else begin
					r_fpga   = 1'b0;
					r_host   = 1'b1;
					r_code   = OWN_HOST_INTER;
					r_reason = RSN_INTER;
				end
			end else begin
				// P-slice MB not classified → host, never silent FPGA paint
				r_fpga   = 1'b0;
				r_host   = 1'b1;
				r_code   = OWN_HOST_SLICE;
				r_reason = RSN_P_SLICE;
			end
		end else begin
			// I-slice MB
			if (is_i_nxn) begin
				if (CAP_INTRA_I4) begin
					r_fpga   = 1'b1;
					r_host   = 1'b0;
					r_code   = OWN_FPGA_INTRA;
					r_reason = RSN_OK_I4;
				end else begin
					r_fpga   = 1'b0;
					r_host   = 1'b1;
					r_code   = OWN_HOST_UNSUP;
					r_reason = RSN_NO_CAP_I4;
				end
			end else if (is_i16x16) begin
				if (CAP_INTRA_I16) begin
					r_fpga   = 1'b1;
					r_host   = 1'b0;
					r_code   = OWN_FPGA_INTRA;
					r_reason = RSN_OK_I16;
				end else begin
					r_fpga   = 1'b0;
					r_host   = 1'b1;
					r_code   = OWN_HOST_UNSUP;
					r_reason = RSN_NO_CAP_I16;
				end
			end else if (is_ipcm) begin
				if (CAP_IPCM) begin
					r_fpga   = 1'b1;
					r_host   = 1'b0;
					r_code   = OWN_FPGA_INTRA;
					r_reason = RSN_OK_I4;
				end else begin
					r_fpga   = 1'b0;
					r_host   = 1'b1;
					r_code   = OWN_HOST_IPCM;
					r_reason = RSN_IPCM;
				end
			end else if (slice_is_i) begin
				r_fpga   = 1'b0;
				r_host   = 1'b1;
				r_code   = OWN_HOST_UNSUP;
				r_reason = RSN_UNSUP_TYPE;
			end else begin
				// Non-I picture without p_slice_mb marking → fail closed to host
				r_fpga   = 1'b0;
				r_host   = 1'b1;
				r_code   = OWN_HOST_SLICE;
				r_reason = RSN_P_SLICE;
			end
		end
	end

	assign fpga_owned    = r_fpga;
	assign host_required = r_host;
	assign product_mb_ok = r_fpga && !r_host;
	assign own_code      = r_code;
	assign own_reason    = r_reason;
endmodule

`default_nettype wire
