// Intra 16x16 luma DC: inv-quant + Hadamard (ITU 8.5.10).
// Bit-exact to host cavlc::invQuantHadamardDc4x4 / FFmpeg ff_h264_luma_dc_dequant_idct.
// One shared multiplier; registered butterflies, product and scale retirement.
// All 16 outputs retire before done. Do not sat9 dc_out.

`default_nettype none

module h264_i16_dc_hadamard (
	input  wire               clk,
	input  wire               reset,
	input  wire               start,
	input  wire signed [15:0] coeff_scan [0:15],
	input  wire [5:0]         qp,
	output reg  signed [31:0] dc_out [0:15],
	output reg                done
);
	function automatic [3:0] zz_i;
		input integer i;
		begin
			case (i)
			0: zz_i=4'd0;  1: zz_i=4'd1;  2: zz_i=4'd4;  3: zz_i=4'd8;
			4: zz_i=4'd5;  5: zz_i=4'd2;  6: zz_i=4'd3;  7: zz_i=4'd6;
			8: zz_i=4'd9;  9: zz_i=4'd12; 10: zz_i=4'd13; 11: zz_i=4'd10;
			12: zz_i=4'd7; 13: zz_i=4'd11; 14: zz_i=4'd14; default: zz_i=4'd15;
			endcase
		end
	endfunction

	function automatic [3:0] transpose_z;
		input [3:0] z;
		transpose_z = {z[1:0], z[3:2]};
	endfunction

	function automatic integer mf0_of;
		input [5:0] q;
		begin
			case (q % 6)
			0: mf0_of = 10;
			1: mf0_of = 11;
			2: mf0_of = 13;
			3: mf0_of = 14;
			4: mf0_of = 16;
			default: mf0_of = 18;
			endcase
		end
	endfunction

	integer i, t;
	integer z0, z1, z2, z3;
	reg signed [5:0] factor;
	reg signed [15:0] input_t [0:15];
	reg signed [17:0] temp [0:15];
	reg signed [17:0] row_r [0:15];
	reg signed [19:0] zmul [0:15];
	reg signed [19:0] transform_r [0:15];
	reg [3:0] qp_shift;
	wire signed [25:0] product = transform_r[mi] * factor;
	reg signed [25:0] product_r;
	reg signed [35:0] scaled_r;
	wire signed [35:0] rounded = (scaled_r + 36'sd2) >>> 2;
	reg product_valid, scaled_valid;
	reg [3:0] product_index, scaled_index;
	reg columns_pending, issued_all;
	reg        busy;
	reg [3:0]  mi;

	always @* begin
		for (i = 0; i < 16; i = i + 1)
			input_t[i] = 16'sd0;
		for (i = 0; i < 16; i = i + 1) begin
			t = transpose_z(zz_i(i));
			input_t[t] = coeff_scan[i];
		end

		for (i = 0; i < 4; i = i + 1) begin
			z0 = input_t[4*i+0] + input_t[4*i+1];
			z1 = input_t[4*i+0] - input_t[4*i+1];
			z2 = input_t[4*i+2] - input_t[4*i+3];
			z3 = input_t[4*i+2] + input_t[4*i+3];
			temp[4*i+0] = z0 + z3;
			temp[4*i+1] = z0 - z3;
			temp[4*i+2] = z1 - z2;
			temp[4*i+3] = z1 + z2;
		end

		for (i = 0; i < 4; i = i + 1) begin
			z0 = row_r[0+i] + row_r[8+i];
			z1 = row_r[0+i] - row_r[8+i];
			z2 = row_r[4+i] - row_r[12+i];
			z3 = row_r[4+i] + row_r[12+i];
			zmul[i*4+0] = z0 + z3;
			zmul[i*4+1] = z1 + z2;
			zmul[i*4+2] = z1 - z2;
			zmul[i*4+3] = z0 - z3;
		end
	end

	always @(posedge clk) begin
		done <= 1'b0;
		product_valid <= 1'b0;
		scaled_valid <= product_valid;
		if (reset) begin
			busy <= 1'b0;
			mi   <= 4'd0;
			columns_pending <= 1'b0;
			issued_all <= 1'b0;
			product_valid <= 1'b0;
			scaled_valid <= 1'b0;
		end else if (start && !busy) begin
			busy <= 1'b1;
			mi   <= 4'd0;
			columns_pending <= 1'b1;
			issued_all <= 1'b0;
			factor <= 6'(mf0_of(qp));
			qp_shift <= 4'(qp / 6);
			// Four signed16 inputs fit signed18; the full transform fits
			// signed20. Keep the original 26/36/32-bit dequant arithmetic.
			for (integer j=0;j<16;j=j+1) row_r[j] <= temp[j];
		end else if (busy) begin
			if (columns_pending) begin
				for (integer j=0;j<16;j=j+1) transform_r[j] <= zmul[j];
				columns_pending <= 1'b0;
			end else if (!issued_all) begin
				product_r <= product;
				product_index <= mi;
				product_valid <= 1'b1;
				if (mi == 4'd15) issued_all <= 1'b1;
				else mi <= mi + 4'd1;
			end
			if (product_valid) begin
				scaled_r <= 36'(product_r) <<< qp_shift;
				scaled_index <= product_index;
			end
			if (scaled_valid) begin
				dc_out[scaled_index] <= rounded[31:0];
				if (scaled_index == 4'd15) begin
					busy <= 1'b0;
					done <= 1'b1;
				end
			end
		end
	end
endmodule

`default_nettype wire
