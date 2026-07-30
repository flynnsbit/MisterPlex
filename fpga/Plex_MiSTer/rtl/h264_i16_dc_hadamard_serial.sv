// h264_i16_dc_hadamard_serial — butterflies combo + ONE scale mul/cycle.
//
// Combo hadamard used 16 parallel *(qmul) → ~32 DSP. Here butterflies stay
// combinational (add/sub only) and the 16 scaled outputs are written over
// 16 cycles with a single multiplier.

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

	wire [2:0] qmod = qp_r % 6;
	wire [3:0] qdiv = qp_r / 6;
	wire [31:0] qmul = ({27'd0, mf0(qmod)} * 32'd16) << (qdiv + 4'd2);
	// Single scale lane
	wire signed [63:0] scaled_full = $signed(pre_scale[k[3:0]]) * $signed({1'b0, qmul});
	wire signed [31:0] dc_lane = (scaled_full + 64'sd128) >>> 8;

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
