// h264_iq_idct_seq — sequential 4x4 inverse scaling + inverse transform.
//
// AREA NOTE.  This is a bit-exact, area-optimised replacement for the pair
//   h264_dequant4x4_flex  (8.5.12.1 scaling with inverse zig-zag)
//   h264_idct4x4          (8.5.12.2 transform)
// when they are driven one 4x4 block at a time.  The combinational pair costs
// ~4,500 ALUTs and 16 DSP blocks because it scales all 16 coefficients in
// parallel (16 multipliers, 16 48-bit barrel shifters, 16 saturators) and then
// spends 48 32-bit adders on a fully unrolled 2-D butterfly.  A macroblock
// walk only ever presents one block at a time, so all of that width is idle
// 15 cycles out of 16.
//
// This version spends 20 cycles and reuses:
//   * ONE 16x5 scaler, written as explicit shifted partial products so it
//     never infers a DSP block (the design is over the DSP budget), and
//     narrowed from 48 to 32 bits by folding the LevelScale x16 and the
//     >>6 rounding into a >>2.
//   * ONE 4-point butterfly, shared by the row pass and the column pass.
//   * A 16-deep rotate-by-one shift register for the transpose.  Rotating by
//     one every cycle and inserting a finished row at words 12..15 every 4th
//     cycle lands the rows in raster order after exactly 16 cycles, so words
//     0..11 are pure shift registers with no select logic at all.  The column
//     pass then keeps rotating and taps the fixed indices 0/4/8/12, which is
//     column j on cycle j.  No address decode, no multiplexers.
//
// Equivalences relied on (both exact for signed values):
//   (c*na*16 << qdiv) + 32) >>> 6  ==  ((c*na << qdiv) + 2) >>> 2
//   sum of 5 shifted copies of c   ==  c * na   for na < 32
`default_nettype none

module h264_iq_idct_seq (
	input  wire               clk,
	input  wire               reset,
	input  wire               start,
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]         qp,
	input  wire [4:0]         max_coeff,
	input  wire               skip_dc,
	input  wire               dc_override,
	input  wire signed [28:0] dc_value,
	output wire signed [28:0] residual [0:15],
	output reg                done
);
	function automatic [4:0] norm_adjust;
		input [2:0] qmod_i;
		input [1:0] mi;
		begin
			case ({qmod_i, mi})
			5'd0:  norm_adjust = 5'd10; 5'd1:  norm_adjust = 5'd13; 5'd2:  norm_adjust = 5'd16;
			5'd4:  norm_adjust = 5'd11; 5'd5:  norm_adjust = 5'd14; 5'd6:  norm_adjust = 5'd18;
			5'd8:  norm_adjust = 5'd13; 5'd9:  norm_adjust = 5'd16; 5'd10: norm_adjust = 5'd20;
			5'd12: norm_adjust = 5'd14; 5'd13: norm_adjust = 5'd18; 5'd14: norm_adjust = 5'd23;
			5'd16: norm_adjust = 5'd16; 5'd17: norm_adjust = 5'd20; 5'd18: norm_adjust = 5'd25;
			5'd20: norm_adjust = 5'd18; 5'd21: norm_adjust = 5'd23; default: norm_adjust = 5'd29;
			endcase
		end
	endfunction

	function automatic [3:0] scan_of_raster;
		input [3:0] r;
		begin
			case (r)
			4'd0:  scan_of_raster = 4'd0;  4'd1:  scan_of_raster = 4'd1;
			4'd2:  scan_of_raster = 4'd5;  4'd3:  scan_of_raster = 4'd6;
			4'd4:  scan_of_raster = 4'd2;  4'd5:  scan_of_raster = 4'd4;
			4'd6:  scan_of_raster = 4'd7;  4'd7:  scan_of_raster = 4'd12;
			4'd8:  scan_of_raster = 4'd3;  4'd9:  scan_of_raster = 4'd8;
			4'd10: scan_of_raster = 4'd11; 4'd11: scan_of_raster = 4'd13;
			4'd12: scan_of_raster = 4'd9;  4'd13: scan_of_raster = 4'd10;
			4'd14: scan_of_raster = 4'd14; default: scan_of_raster = 4'd15;
			endcase
		end
	endfunction

	function automatic signed [28:0] sat29;
		input signed [31:0] v;
		begin
			if (v > 32'sd268435455)       sat29 = 29'sd268435455;
			else if (v < -32'sd268435456) sat29 = ~29'sd268435455;
			else                          sat29 = v[28:0];
		end
	endfunction

	localparam [1:0] ST_IDLE = 2'd0, ST_SCALE = 2'd1, ST_COL = 2'd2, ST_DONE = 2'd3;

	reg [1:0] st;
	reg [3:0] cnt;

	// ── one shared scaler ────────────────────────────────────────────────
	wire [5:0] qmod6 = qp % 6;
	wire [5:0] qdiv6 = qp / 6;
	wire [2:0] qmod = qmod6[2:0];
	wire [3:0] qdiv = qdiv6[3:0];

	wire [3:0] r     = cnt;
	// mi counts odd raster coordinates: bit0 is the column LSB, bit2 the row LSB.
	wire [1:0] mi    = {1'b0, r[0]} + {1'b0, r[2]};
	wire [4:0] scan5 = {1'b0, scan_of_raster(r)};
	wire [4:0] arr5  = skip_dc ? (scan5 - 5'd1) : scan5;
	wire in_range    = skip_dc ? ((scan5 != 5'd0) && ((scan5 - 5'd1) < max_coeff))
	                           : (scan5 < max_coeff);

	wire signed [15:0] cval = in_range ? coeff[arr5[3:0]] : 16'sd0;
	wire [4:0]         na   = norm_adjust(qmod, mi);

	// c * na as five shifted partial products: no multiplier, no DSP block.
	wire signed [21:0] cs  = {{6{cval[15]}}, cval};
	wire signed [21:0] pp0 = na[0] ? cs           : 22'sd0;
	wire signed [21:0] pp1 = na[1] ? (cs <<< 1)   : 22'sd0;
	wire signed [21:0] pp2 = na[2] ? (cs <<< 2)   : 22'sd0;
	wire signed [21:0] pp3 = na[3] ? (cs <<< 3)   : 22'sd0;
	wire signed [21:0] pp4 = na[4] ? (cs <<< 4)   : 22'sd0;
	wire signed [21:0] mul = pp0 + pp1 + pp2 + pp3 + pp4;

	wire signed [31:0] prod    = $signed({{10{mul[21]}}, mul}) <<< qdiv;
	wire signed [28:0] scaled  = sat29((prod + 32'sd2) >>> 2);
	wire signed [28:0] dq_val  = (r == 4'd0) ? (dc_override ? dc_value
	                                                        : (skip_dc ? 29'sd0 : scaled))
	                                         : scaled;
	// The IDCT rounding constant belongs to raster position 0 only.
	wire signed [31:0] b_in = $signed({{3{dq_val[28]}}, dq_val}) +
	                          ((r == 4'd0) ? 32'sd32 : 32'sd0);

	// ── one shared 4-point butterfly ─────────────────────────────────────
	reg  signed [31:0] rb0, rb1, rb2;
	reg  signed [31:0] a [0:15];

	wire row_push = (st == ST_SCALE) && (cnt[1:0] == 2'd3);

	wire signed [31:0] f0 = row_push ? rb0 : a[0];
	wire signed [31:0] f1 = row_push ? rb1 : a[4];
	wire signed [31:0] f2 = row_push ? rb2 : a[8];
	wire signed [31:0] f3 = row_push ? b_in : a[12];

	wire signed [31:0] z0 = f0 + f2;
	wire signed [31:0] z1 = f0 - f2;
	wire signed [31:0] z2 = (f1 >>> 1) - f3;
	wire signed [31:0] z3 = f1 + (f3 >>> 1);

	wire signed [31:0] o0 = z0 + z3;
	wire signed [31:0] o1 = z1 + z2;
	wire signed [31:0] o2 = z1 - z2;
	wire signed [31:0] o3 = z0 - z3;

	// ── transpose / output rotators ──────────────────────────────────────
	reg signed [28:0] o [0:15];

	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_out
			assign residual[gi] = o[gi];
		end
	endgenerate

	integer k;
	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			st  <= ST_IDLE;
			cnt <= 4'd0;
			rb0 <= 32'sd0; rb1 <= 32'sd0; rb2 <= 32'sd0;
			for (k = 0; k < 16; k = k + 1) begin
				a[k] <= 32'sd0;
				o[k] <= 29'sd0;
			end
		end else begin
			case (st)
				ST_IDLE: if (start) begin
					cnt <= 4'd0;
					st  <= ST_SCALE;
				end

				ST_SCALE: begin
					rb0 <= rb1;
					rb1 <= rb2;
					rb2 <= b_in;
					cnt <= cnt + 4'd1;
					if (cnt == 4'd15) begin
						cnt <= 4'd0;
						st  <= ST_COL;
					end
				end

				ST_COL: begin
					cnt <= cnt + 4'd1;
					if (cnt == 4'd3) begin
						cnt <= 4'd0;
						st  <= ST_DONE;
					end
				end

				default: begin
					done <= 1'b1;
					st   <= ST_IDLE;
				end
			endcase

			// Rotate left by one every cycle of both passes.  Words 12..15
			// take a finished row on every 4th scale cycle; that alignment
			// is what makes words 0..11 plain shift registers.
			if (st == ST_SCALE || st == ST_COL) begin
				for (k = 0; k < 12; k = k + 1)
					a[k] <= a[k+1];
				if (row_push) begin
					a[12] <= o0;
					a[13] <= o1;
					a[14] <= o2;
					a[15] <= o3;
				end else begin
					a[12] <= a[13];
					a[13] <= a[14];
					a[14] <= a[15];
					a[15] <= a[0];
				end
			end

			// Column results are inserted at 3/7/11/15 and rotate into raster
			// order after exactly four cycles.
			if (st == ST_COL) begin
				for (k = 0; k < 16; k = k + 1) begin
					if (k == 3)       o[k] <= sat29(o0 >>> 6);
					else if (k == 7)  o[k] <= sat29(o1 >>> 6);
					else if (k == 11) o[k] <= sat29(o2 >>> 6);
					else if (k == 15) o[k] <= sat29(o3 >>> 6);
					else              o[k] <= o[k+1];
				end
			end
		end
	end
endmodule

`default_nettype wire
