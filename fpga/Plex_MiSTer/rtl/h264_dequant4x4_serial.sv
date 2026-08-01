// h264_dequant4x4_serial — one multiplier, 16 cycles (DSP crash-diet).
//
// Replaces combinational h264_dequant4x4 which built BOTH max16 and max15
// dequant_one() farms in parallel (map: ~52 DSP on dequant child alone).
// Bit-exact with host / combo dequant when FAULT_FORCE_ZERO=0.
//
// FAULT_FORCE_ZERO: leave dequant=0 after "done" (RED twin — proves serial IQ
// is load-bearing without restoring the parallel mul farm).

`default_nettype none

module h264_dequant4x4_serial #(
	parameter bit FAULT_FORCE_ZERO = 1'b0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]  qp,
	input  wire [4:0]  max_coeff,
	output reg         busy,
	output reg         done,
	output reg signed [28:0] dequant [0:15]
);
	function automatic [4:0] zigzag;
		input [4:0] k;
		begin
			case (k)
			5'd0:  zigzag = 5'd0;
			5'd1:  zigzag = 5'd1;
			5'd2:  zigzag = 5'd4;
			5'd3:  zigzag = 5'd8;
			5'd4:  zigzag = 5'd5;
			5'd5:  zigzag = 5'd2;
			5'd6:  zigzag = 5'd3;
			5'd7:  zigzag = 5'd6;
			5'd8:  zigzag = 5'd9;
			5'd9:  zigzag = 5'd12;
			5'd10: zigzag = 5'd13;
			5'd11: zigzag = 5'd10;
			5'd12: zigzag = 5'd7;
			5'd13: zigzag = 5'd11;
			5'd14: zigzag = 5'd14;
			default: zigzag = 5'd15;
			endcase
		end
	endfunction

	function automatic [4:0] norm_adjust;
		input [2:0] qmod;
		input [1:0] mi;
		begin
			case ({qmod, mi})
			5'd0:  norm_adjust = 5'd10; 5'd1:  norm_adjust = 5'd13; 5'd2:  norm_adjust = 5'd16;
			5'd4:  norm_adjust = 5'd11; 5'd5:  norm_adjust = 5'd14; 5'd6:  norm_adjust = 5'd18;
			5'd8:  norm_adjust = 5'd13; 5'd9:  norm_adjust = 5'd16; 5'd10: norm_adjust = 5'd20;
			5'd12: norm_adjust = 5'd14; 5'd13: norm_adjust = 5'd18; 5'd14: norm_adjust = 5'd23;
			5'd16: norm_adjust = 5'd16; 5'd17: norm_adjust = 5'd20; 5'd18: norm_adjust = 5'd25;
			5'd20: norm_adjust = 5'd18; 5'd21: norm_adjust = 5'd23; default: norm_adjust = 5'd29;
			endcase
		end
	endfunction

	// QP/6 without vendor divide IP (same tables as combo h264_dequant4x4 / w-area).
	function automatic [2:0] qp_mod6;
		input [5:0] q;
		begin
			case (q)
			6'd0, 6'd6, 6'd12, 6'd18, 6'd24, 6'd30, 6'd36, 6'd42, 6'd48: qp_mod6 = 3'd0;
			6'd1, 6'd7, 6'd13, 6'd19, 6'd25, 6'd31, 6'd37, 6'd43, 6'd49: qp_mod6 = 3'd1;
			6'd2, 6'd8, 6'd14, 6'd20, 6'd26, 6'd32, 6'd38, 6'd44, 6'd50: qp_mod6 = 3'd2;
			6'd3, 6'd9, 6'd15, 6'd21, 6'd27, 6'd33, 6'd39, 6'd45, 6'd51: qp_mod6 = 3'd3;
			6'd4, 6'd10, 6'd16, 6'd22, 6'd28, 6'd34, 6'd40, 6'd46:       qp_mod6 = 3'd4;
			default:                                                     qp_mod6 = 3'd5; // 5,11,...,47
			endcase
		end
	endfunction

	function automatic [3:0] qp_div6;
		input [5:0] q;
		begin
			case (q)
			6'd0,  6'd1,  6'd2,  6'd3,  6'd4,  6'd5:  qp_div6 = 4'd0;
			6'd6,  6'd7,  6'd8,  6'd9,  6'd10, 6'd11: qp_div6 = 4'd1;
			6'd12, 6'd13, 6'd14, 6'd15, 6'd16, 6'd17: qp_div6 = 4'd2;
			6'd18, 6'd19, 6'd20, 6'd21, 6'd22, 6'd23: qp_div6 = 4'd3;
			6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29: qp_div6 = 4'd4;
			6'd30, 6'd31, 6'd32, 6'd33, 6'd34, 6'd35: qp_div6 = 4'd5;
			6'd36, 6'd37, 6'd38, 6'd39, 6'd40, 6'd41: qp_div6 = 4'd6;
			6'd42, 6'd43, 6'd44, 6'd45, 6'd46, 6'd47: qp_div6 = 4'd7;
			default:                                   qp_div6 = 4'd8; // 48..51
			endcase
		end
	endfunction

	// c * norm_adjust via shift-add (same as combo; serial still 16 cycles, 0 DSP mult).
	function automatic signed [31:0] mul_norm_adjust;
		input signed [15:0] c;
		input [4:0] n;
		reg signed [31:0] x;
		begin
			x = {{16{c[15]}}, c};
			case (n)
			5'd10: mul_norm_adjust = (x <<< 3) + (x <<< 1);
			5'd11: mul_norm_adjust = (x <<< 3) + (x <<< 1) + x;
			5'd13: mul_norm_adjust = (x <<< 3) + (x <<< 2) + x;
			5'd14: mul_norm_adjust = (x <<< 3) + (x <<< 2) + (x <<< 1);
			5'd16: mul_norm_adjust = (x <<< 4);
			5'd18: mul_norm_adjust = (x <<< 4) + (x <<< 1);
			5'd20: mul_norm_adjust = (x <<< 4) + (x <<< 2);
			5'd23: mul_norm_adjust = (x <<< 4) + (x <<< 2) + (x <<< 1) + x;
			5'd25: mul_norm_adjust = (x <<< 4) + (x <<< 3) + x;
			default: mul_norm_adjust = (x <<< 4) + (x <<< 3) + (x <<< 2) + x;
			endcase
		end
	endfunction

	// Single-lane dequant_one (same arithmetic as combo h264_dequant4x4 / w-area).
	function automatic signed [28:0] dequant_one;
		input signed [15:0] c;
		input [5:0] q;
		input [4:0] scan;
		input       skip_dc;
		reg [4:0] z;
		reg [1:0] mi;
		reg [2:0] qmod;
		reg [3:0] qdiv;
		reg [4:0] na;
		reg signed [31:0] prod;
		reg signed [31:0] v;
		begin
			if (skip_dc)
				z = zigzag(scan + 5'd1);
			else
				z = zigzag(scan);
			if (((z[1:0] & 2'b01) + (z[3:2] & 2'b01)) == 2'd0)
				mi = 2'd0;
			else if (((z[1:0] & 2'b01) + (z[3:2] & 2'b01)) == 2'd1)
				mi = 2'd1;
			else
				mi = 2'd2;
			qmod = qp_mod6(q);
			qdiv = qp_div6(q);
			na = norm_adjust(qmod, mi);
			prod = mul_norm_adjust(c, na);
			v = ((prod <<< (qdiv + 4'd6)) + 32'sd32) >>> 6;
			dequant_one = v[28:0];
		end
	endfunction

	reg signed [15:0] c_r [0:15];
	reg [5:0]  qp_r;
	reg [4:0]  max_r;
	reg [4:0]  k; // 0..15 scan index
	reg        skip_dc_r;
	integer    ii;

	wire [4:0] dest_zz = skip_dc_r ? zigzag(k + 5'd1) : zigzag(k);
	wire       active  = busy && (k < max_r);
	wire signed [28:0] lane = active ? dequant_one(c_r[k[3:0]], qp_r, k, skip_dc_r) : 29'sd0;

	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			busy <= 1'b0;
			k <= 5'd0;
			qp_r <= 6'd0;
			max_r <= 5'd0;
			skip_dc_r <= 1'b0;
			for (ii = 0; ii < 16; ii = ii + 1) begin
				c_r[ii] <= 16'sd0;
				dequant[ii] <= 29'sd0;
			end
		end else if (start && !busy) begin
			busy <= 1'b1;
			k <= 5'd0;
			qp_r <= qp;
			max_r <= max_coeff;
			skip_dc_r <= (max_coeff == 5'd15);
			for (ii = 0; ii < 16; ii = ii + 1) begin
				c_r[ii] <= coeff[ii];
				dequant[ii] <= 29'sd0; // max15 DC spatial stays 0
			end
		end else if (busy) begin
			if (FAULT_FORCE_ZERO) begin
				// RED: claim done with zeros (no IQ)
				busy <= 1'b0;
				done <= 1'b1;
			end else if (k >= max_r || k >= 5'd16) begin
				// All scans written prior cycle; dequant[] stable now.
				busy <= 1'b0;
				done <= 1'b1;
			end else begin
				dequant[dest_zz[3:0]] <= lane;
				k <= k + 5'd1;
				// done on following cycle after last write (NBA-safe)
			end
		end
	end
endmodule

`default_nettype wire
