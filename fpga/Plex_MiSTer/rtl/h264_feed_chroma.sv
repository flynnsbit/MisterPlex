module h264_chroma_qp (
	input  wire [5:0]        qp_y,
	input  wire signed [4:0] chroma_qp_index_offset,
	output wire [5:0]        qp_c
);
	wire signed [7:0] qpi_raw =
		$signed({1'b0, qp_y}) +
		$signed({{3{chroma_qp_index_offset[4]}}, chroma_qp_index_offset});
	wire [5:0] qpi = (qpi_raw < 0) ? 6'd0 :
	                 (qpi_raw > 8'sd51) ? 6'd51 : qpi_raw[5:0];
	reg [5:0] map_c;
	always @* begin
		case (qpi)
		6'd30: map_c = 6'd29;
		6'd31: map_c = 6'd30;
		6'd32: map_c = 6'd31;
		6'd33: map_c = 6'd32;
		6'd34: map_c = 6'd32;
		6'd35: map_c = 6'd33;
		6'd36: map_c = 6'd34;
		6'd37: map_c = 6'd34;
		6'd38: map_c = 6'd35;
		6'd39: map_c = 6'd35;
		6'd40: map_c = 6'd36;
		6'd41: map_c = 6'd36;
		6'd42: map_c = 6'd37;
		6'd43: map_c = 6'd37;
		6'd44: map_c = 6'd37;
		6'd45: map_c = 6'd38;
		6'd46: map_c = 6'd38;
		6'd47: map_c = 6'd38;
		6'd48: map_c = 6'd39;
		6'd49: map_c = 6'd39;
		6'd50: map_c = 6'd39;
		6'd51: map_c = 6'd39;
		default: map_c = qpi;
		endcase
	end
	assign qp_c = map_c;
endmodule

module h264_chroma_dc_hadamard_inv (
	input  wire signed [15:0] coeff [0:3],
	input  wire [5:0]         qp_c,
	output wire signed [28:0] dc [0:3]
);
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

	function automatic [2:0] cqp_mod6;
		input [5:0] q;
		begin
			case (q)
			6'd0,6'd6,6'd12,6'd18,6'd24,6'd30,6'd36,6'd42,6'd48: cqp_mod6 = 3'd0;
			6'd1,6'd7,6'd13,6'd19,6'd25,6'd31,6'd37,6'd43,6'd49: cqp_mod6 = 3'd1;
			6'd2,6'd8,6'd14,6'd20,6'd26,6'd32,6'd38,6'd44,6'd50: cqp_mod6 = 3'd2;
			6'd3,6'd9,6'd15,6'd21,6'd27,6'd33,6'd39,6'd45,6'd51: cqp_mod6 = 3'd3;
			6'd4,6'd10,6'd16,6'd22,6'd28,6'd34,6'd40,6'd46: cqp_mod6 = 3'd4;
			default: cqp_mod6 = 3'd5;
			endcase
		end
	endfunction

	function automatic [3:0] cqp_div6;
		input [5:0] q;
		begin
			case (q)
			6'd0,6'd1,6'd2,6'd3,6'd4,6'd5: cqp_div6 = 4'd0;
			6'd6,6'd7,6'd8,6'd9,6'd10,6'd11: cqp_div6 = 4'd1;
			6'd12,6'd13,6'd14,6'd15,6'd16,6'd17: cqp_div6 = 4'd2;
			6'd18,6'd19,6'd20,6'd21,6'd22,6'd23: cqp_div6 = 4'd3;
			6'd24,6'd25,6'd26,6'd27,6'd28,6'd29: cqp_div6 = 4'd4;
			6'd30,6'd31,6'd32,6'd33,6'd34,6'd35: cqp_div6 = 4'd5;
			6'd36,6'd37,6'd38,6'd39,6'd40,6'd41: cqp_div6 = 4'd6;
			6'd42,6'd43,6'd44,6'd45,6'd46,6'd47: cqp_div6 = 4'd7;
			default: cqp_div6 = 4'd8;
			endcase
		end
	endfunction

	function automatic signed [31:0] cmul_norm;
		input signed [31:0] x;
		input [4:0] na;
		begin
			case (na)
			5'd10: cmul_norm = (x <<< 3) + (x <<< 1);
			5'd11: cmul_norm = (x <<< 3) + (x <<< 1) + x;
			5'd13: cmul_norm = (x <<< 3) + (x <<< 2) + x;
			5'd14: cmul_norm = (x <<< 4) - (x <<< 1);
			5'd16: cmul_norm = (x <<< 4);
			default: cmul_norm = (x <<< 4) + (x <<< 1);
			endcase
		end
	endfunction

	function automatic signed [47:0] cshl;
		input signed [31:0] v;
		input [3:0] amt;
		begin
			case (amt)
			4'd0:  cshl = {{16{v[31]}}, v};
			4'd1:  cshl = {{15{v[31]}}, v, 1'b0};
			4'd2:  cshl = {{14{v[31]}}, v, 2'b0};
			4'd3:  cshl = {{13{v[31]}}, v, 3'b0};
			4'd4:  cshl = {{12{v[31]}}, v, 4'b0};
			4'd5:  cshl = {{11{v[31]}}, v, 5'b0};
			4'd6:  cshl = {{10{v[31]}}, v, 6'b0};
			4'd7:  cshl = {{9{v[31]}}, v, 7'b0};
			4'd8:  cshl = {{8{v[31]}}, v, 8'b0};
			4'd9:  cshl = {{7{v[31]}}, v, 9'b0};
			default: cshl = {{6{v[31]}}, v, 10'b0};
			endcase
		end
	endfunction

	wire signed [31:0] a0 = coeff[0];
	wire signed [31:0] b0 = coeff[1];
	wire signed [31:0] c0 = coeff[2];
	wire signed [31:0] d0 = coeff[3];
	wire signed [31:0] a = a0 + b0;
	wire signed [31:0] e = a0 - b0;
	wire signed [31:0] b = c0 - d0;
	wire signed [31:0] c = c0 + d0;
	wire [2:0] qmod = cqp_mod6(qp_c);
	wire [3:0] qdiv = cqp_div6(qp_c);
	wire [4:0] na0 = mf0(qmod);
	wire signed [31:0] b00 = cmul_norm(a + c, na0);
	wire signed [31:0] b01 = cmul_norm(e + b, na0);
	wire signed [31:0] b10 = cmul_norm(a - c, na0);
	wire signed [31:0] b11 = cmul_norm(e - b, na0);
	wire signed [47:0] p00 = cshl({b00[27:0], 4'b0}, qdiv + 4'd2);
	wire signed [47:0] p01 = cshl({b01[27:0], 4'b0}, qdiv + 4'd2);
	wire signed [47:0] p10 = cshl({b10[27:0], 4'b0}, qdiv + 4'd2);
	wire signed [47:0] p11 = cshl({b11[27:0], 4'b0}, qdiv + 4'd2);

	assign dc[0] = $signed(p00 >>> 7);
	assign dc[1] = $signed(p01 >>> 7);
	assign dc[2] = $signed(p10 >>> 7);
	assign dc[3] = $signed(p11 >>> 7);
endmodule
