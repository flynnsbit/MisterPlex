//============================================================================
//  h264_recon — Phase 1 4x4 residual reconstruct
//  CAVLC s16 → h264_coeff_sat9 → dequant4x4 → idct4x4 → recon4x4
//  1-cycle start/done handshake. H264 Expert owns the final sat rule.
//  Copyright (C) 2026 MiSTerPlex contributors
//  GPL-2.0-or-later
//============================================================================

module h264_recon (
	input  wire               clk,
	input  wire               reset,
	input  wire               start,
	input  wire signed [15:0] cavlc_coeff [0:15],
	input  wire [5:0]         qp,
	input  wire [4:0]         max_coeff,
	input  wire [7:0]         pred [0:15],
	output wire signed [8:0]  sat_coeff [0:15],
	output reg  [7:0]         recon [0:15],
	output reg  [7:0]         recon_sig,
	output reg                done,
	output reg                ok
);

	// Explicit sat/cut 16→9 into dequant (saturate to signed 9, do not
	// silently truncate). H264 Expert owns the final sat rule.
	wire signed [17:0] dequant [0:15];
	wire signed [17:0] residual [0:15];
	wire [7:0]         recon_px [0:15];

	h264_coeff_sat9 u_sat9 (
		.cavlc_coeff(cavlc_coeff),
		.residual_coeff(sat_coeff)
	);

	h264_dequant4x4 u_dequant (
		.coeff(sat_coeff),
		.qp(qp),
		.max_coeff(max_coeff),
		.dequant(dequant)
	);

	h264_idct4x4 u_idct (
		.dequant(dequant),
		.residual(residual)
	);

	h264_recon4x4 u_recon (
		.pred(pred),
		.residual(residual),
		.recon(recon_px)
	);

	// XOR of Y[0:15] — same fold as decode_stub golden recon_sig (0x3b path).
	wire [7:0] recon_sig_comb = recon_px[0]  ^ recon_px[1]  ^ recon_px[2]  ^ recon_px[3] ^
	                            recon_px[4]  ^ recon_px[5]  ^ recon_px[6]  ^ recon_px[7] ^
	                            recon_px[8]  ^ recon_px[9]  ^ recon_px[10] ^ recon_px[11] ^
	                            recon_px[12] ^ recon_px[13] ^ recon_px[14] ^ recon_px[15];

	integer i;
	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			ok        <= 1'b0;
			done      <= 1'b0;
			recon_sig <= 8'd0;
			for (i = 0; i < 16; i = i + 1)
				recon[i] <= 8'd0;
		end else if (start) begin
			for (i = 0; i < 16; i = i + 1)
				recon[i] <= recon_px[i];
			recon_sig <= recon_sig_comb;
			done      <= 1'b1;
			ok        <= 1'b1;
		end
	end

endmodule
