// h264_i16_dc_hadamard_serial — butterflies combo + ONE scale lane/cycle.
//
// Combo hadamard used 16 parallel *(qmul) → ~32 DSP. Serial keeps butterflies
// combinational (add/sub only) and writes 16 scaled outputs over 16 cycles.
// Scale is shift-add (mf0∈{10,11,13,14,16,18}) — 0 DSP, same 16-cy latency.

`default_nettype none

module h264_i16_dc_hadamard_serial (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]  qp,
	output reg         busy,
	output reg         done,
	output reg signed [15:0] dc_out [0:15]
);
	function automatic [3:0] zz;
		input [3:0] i;
		begin
			case (i)
			4'd0: zz = 4'd0; 4'd1: zz = 4'd1; 4'd2: zz = 4'd4; 4'd3: zz = 4'd8;
			4'd4: zz = 4'd5; 4'd5: zz = 4'd2; 4'd6: zz = 4'd3; 4'd7: zz = 4'd6;
			4'd8: zz = 4'd9; 4'd9: zz = 4'd12; 4'd10: zz = 4'd13; 4'd11: zz = 4'd10;
			4'd12: zz = 4'd7; 4'd13: zz = 4'd11; 4'd14: zz = 4'd14; default: zz = 4'd15;
			endcase
		end
	endfunction

	function automatic [3:0] transpose4;
		input [3:0] z;
		transpose4 = {z[1:0], z[3:2]};
	endfunction

	function automatic [4:0] mf0;
		input [2:0] qmod;
		begin
			case (qmod)
			3'd0: mf0 = 5'd10;
			3'd1: mf0 = 5'd11;
			3'd2: mf0 = 5'd13;
			3'd3: mf0 = 5'd14;
			3'd4: mf0 = 5'd16;
			default: mf0 = 5'd18;
			endcase
		end
	endfunction

	// QP/6 tables — kill vendor %/ divide IP (same as w-area dequant).
	function automatic [2:0] qp_mod6;
		input [5:0] q;
		begin
			case (q)
			6'd0, 6'd6, 6'd12, 6'd18, 6'd24, 6'd30, 6'd36, 6'd42, 6'd48: qp_mod6 = 3'd0;
			6'd1, 6'd7, 6'd13, 6'd19, 6'd25, 6'd31, 6'd37, 6'd43, 6'd49: qp_mod6 = 3'd1;
			6'd2, 6'd8, 6'd14, 6'd20, 6'd26, 6'd32, 6'd38, 6'd44, 6'd50: qp_mod6 = 3'd2;
			6'd3, 6'd9, 6'd15, 6'd21, 6'd27, 6'd33, 6'd39, 6'd45, 6'd51: qp_mod6 = 3'd3;
			6'd4, 6'd10, 6'd16, 6'd22, 6'd28, 6'd34, 6'd40, 6'd46:       qp_mod6 = 3'd4;
			default:                                                     qp_mod6 = 3'd5;
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
			default:                                   qp_div6 = 4'd8;
			endcase
		end
	endfunction

	// z * mf0 via shift-add. mf0 ∈ {10,11,13,14,16,18}.
	// Host/RTL: qmul = (mf0*16)<<(qdiv+2) = mf0<<(qdiv+6);
	//           dc = (z*qmul + 128) >> 8
	// Equiv: ((z*mf0)<<(qdiv+6) + 128) >> 8
	function automatic signed [63:0] mul_mf0;
		input signed [31:0] z;
		input [4:0] n;
		reg signed [63:0] x;
		begin
			x = {{32{z[31]}}, z};
			case (n)
			5'd10: mul_mf0 = (x <<< 3) + (x <<< 1);                 // 8+2
			5'd11: mul_mf0 = (x <<< 3) + (x <<< 1) + x;             // 8+2+1
			5'd13: mul_mf0 = (x <<< 3) + (x <<< 2) + x;             // 8+4+1
			5'd14: mul_mf0 = (x <<< 3) + (x <<< 2) + (x <<< 1);     // 8+4+2
			5'd16: mul_mf0 = (x <<< 4);                             // 16
			default: mul_mf0 = (x <<< 4) + (x <<< 1);               // 18 = 16+2
			endcase
		end
	endfunction

	reg signed [15:0] c_r [0:15];
	reg [5:0] qp_r;
	reg [4:0] k;
	integer i;

	// Butterflies from captured coeffs (combo, 0 DSP)
	reg signed [31:0] input_cm [0:15];
	reg signed [31:0] temp [0:15];
	reg signed [31:0] pre_scale [0:15];
	integer t, z0, z1, z2, z3, zi, tr;

	always @(*) begin
		for (i = 0; i < 16; i = i + 1)
			input_cm[i] = 32'sd0;
		for (i = 0; i < 16; i = i + 1) begin
			zi = zz(i[3:0]);
			tr = transpose4(zi[3:0]);
			input_cm[tr] = c_r[i];
		end
		for (i = 0; i < 4; i = i + 1) begin
			z0 = input_cm[4*i+0] + input_cm[4*i+1];
			z1 = input_cm[4*i+0] - input_cm[4*i+1];
			z2 = input_cm[4*i+2] - input_cm[4*i+3];
			z3 = input_cm[4*i+2] + input_cm[4*i+3];
			temp[4*i+0] = z0 + z3;
			temp[4*i+1] = z0 - z3;
			temp[4*i+2] = z1 - z2;
			temp[4*i+3] = z1 + z2;
		end
		for (i = 0; i < 4; i = i + 1) begin
			z0 = temp[4*0+i] + temp[4*2+i];
			z1 = temp[4*0+i] - temp[4*2+i];
			z2 = temp[4*1+i] - temp[4*3+i];
			z3 = temp[4*1+i] + temp[4*3+i];
			pre_scale[i*4+0] = (z0 + z3);
			pre_scale[i*4+1] = (z1 + z2);
			pre_scale[i*4+2] = (z1 - z2);
			pre_scale[i*4+3] = (z0 - z3);
		end
	end

	wire [2:0] qmod = qp_mod6(qp_r);
	wire [3:0] qdiv = qp_div6(qp_r);
	wire [4:0] na   = mf0(qmod);
	// Single scale lane — shift-add, 0 DSP (was 1 DSP mult)
	wire signed [63:0] prod_na     = mul_mf0(pre_scale[k[3:0]], na);
	wire signed [63:0] scaled_full = prod_na <<< (qdiv + 4'd6);
	wire signed [31:0] dc_lane     = (scaled_full + 64'sd128) >>> 8;

	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			busy <= 1'b0;
			k <= 5'd0;
			qp_r <= 6'd0;
			for (i = 0; i < 16; i = i + 1) begin
				c_r[i] <= 16'sd0;
				dc_out[i] <= 16'sd0;
			end
		end else if (start && !busy) begin
			busy <= 1'b1;
			k <= 5'd0;
			qp_r <= qp;
			for (i = 0; i < 16; i = i + 1)
				c_r[i] <= coeff[i];
		end else if (busy) begin
			if (k == 5'd16) begin
				// cycle after last write: dc_out[] stable
				busy <= 1'b0;
				done <= 1'b1;
				k <= 5'd0;
			end else begin
				dc_out[k[3:0]] <= dc_lane[15:0];
				k <= k + 5'd1;
			end
		end
	end
endmodule

`default_nettype wire
