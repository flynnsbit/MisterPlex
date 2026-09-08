// Full-slice residual block order for Constrained Baseline (I/P, 4:2:0, no 8x8).
// One "advance" per *coded* CAVLC block. Uncoded luma 8x8s are skipped here so
// mb_ctrl never waits on blk_valid==0.
//
// blk_id: 0..15 luma 4x4 (decoder scan), 16 luma DC (I_16x16),
//         17 Cb DC, 18 Cr DC, 19..22 Cb AC, 23..26 Cr AC.
// coeff_token_table: 4 = chroma DC only; 7 = use neighbouring luma/AC nC.

`default_nettype none

module h264_residual_seq (
	input  wire        start_mb,     // after mb_type / CBP / mb_qp_delta
	input  wire        advance,      // pulse after one CAVLC block finishes
	input  wire        is_i16,
	input  wire [3:0]  cbp_luma,     // 4 8x8 flags (I16: 0 or 15 from mb_type)
	input  wire [1:0]  cbp_chroma,   // 0=none 1=DC 2=DC+AC
	input  wire        clk,
	input  wire        reset,

	output reg         blk_valid,
	output reg         mb_res_done,
	output reg  [4:0]  blk_id,
	output reg  [4:0]  max_coeff,    // 16 / 15 / 4
	output reg         chroma_dc,    // 1 → coeff_token_table must be 4
	output reg  [2:0]  coeff_token_table, // 4 or 7 (7 = compute from nC)
	output reg  [1:0]  blk_x,        // 4x4 x in 16x16 (luma) or 8x8 (chroma)
	output reg  [1:0]  blk_y,
	output reg         is_chroma,
	output reg         chr_cb        // 1=Cb 0=Cr when is_chroma
);
	// ITU Fig 6-10 / 7.4.5 decoder 4x4 order
	function automatic [3:0] luma_ord;
		input [3:0] i;
		begin
			luma_ord = i;
		end
	endfunction

	function automatic [1:0] lx; input [3:0] b; lx = {b[2], b[0]}; endfunction
	function automatic [1:0] ly; input [3:0] b; ly = {b[3], b[1]}; endfunction
	function automatic luma_coded;
		input [3:0] b;
		input [3:0] cbp;
		begin
			luma_coded = cbp[{b[3], b[2]}];
		end
	endfunction

	function automatic [4:0] next_luma_i;
		input [4:0] from;
		input [3:0] cbp;
		integer k;
		reg found;
		begin
			next_luma_i = 5'd16;
			found = 1'b0;
			for (k = 0; k < 16; k = k + 1) begin
				if (!found && (k >= from) && luma_coded(luma_ord(k[3:0]), cbp)) begin
					next_luma_i = k[4:0];
					found = 1'b1;
				end
			end
		end
	endfunction

	localparam [2:0] S_IDLE=3'd0, S_LDC=3'd1, S_LY=3'd2, S_CDC=3'd3, S_CAC=3'd4, S_DONE=3'd5;
	reg [2:0] st;
	reg [4:0] i;
	reg       lat_i16;
	reg [3:0] lat_cbp_l;
	reg [1:0] lat_cbp_c;

	task automatic present_ldc;
		begin
			// I16 DC uses the luma neighbours at block (0,0), not nC=0.
			blk_valid <= 1'b1; mb_res_done <= 1'b0;
			blk_id <= 5'd16; max_coeff <= 5'd16;
			chroma_dc <= 1'b0; coeff_token_table <= 3'd7;
			blk_x <= 2'd0; blk_y <= 2'd0;
			is_chroma <= 1'b0; chr_cb <= 1'b0;
		end
	endtask

	task automatic present_ly;
		input [4:0] ii;
		reg [3:0] b;
		begin
			b = luma_ord(ii[3:0]);
			blk_valid <= 1'b1; mb_res_done <= 1'b0;
			blk_id <= {1'b0, b};
			max_coeff <= lat_i16 ? 5'd15 : 5'd16;
			chroma_dc <= 1'b0; coeff_token_table <= 3'd7;
			blk_x <= lx(b); blk_y <= ly(b);
			is_chroma <= 1'b0; chr_cb <= 1'b0;
		end
	endtask

	task automatic present_cdc;
		input [0:0] ii;
		begin
			blk_valid <= 1'b1; mb_res_done <= 1'b0;
			blk_id <= 5'd17 + {4'd0, ii};
			max_coeff <= 5'd4;
			chroma_dc <= 1'b1; coeff_token_table <= 3'd4;
			blk_x <= 2'd0; blk_y <= 2'd0;
			is_chroma <= 1'b1; chr_cb <= ~ii;
		end
	endtask

	task automatic present_cac;
		input [4:0] ii;
		begin
			// i 0..3 Cb, 4..7 Cr; 2x2: x=i[0] y=i[1]
			blk_valid <= 1'b1; mb_res_done <= 1'b0;
			blk_id <= 5'd19 + ii;
			max_coeff <= 5'd15;
			chroma_dc <= 1'b0; coeff_token_table <= 3'd7;
			blk_x <= {1'b0, ii[0]};
			blk_y <= {1'b0, ii[1]};
			is_chroma <= 1'b1;
			chr_cb <= (ii < 5'd4);
		end
	endtask

	task automatic go_done;
		begin
			st <= S_DONE;
			blk_valid <= 1'b0;
			mb_res_done <= 1'b1;
			chroma_dc <= 1'b0; coeff_token_table <= 3'd7;
			is_chroma <= 1'b0; chr_cb <= 1'b0;
		end
	endtask

	always @(posedge clk) begin
		if (reset) begin
			st <= S_IDLE; i <= 5'd0;
			lat_i16 <= 1'b0; lat_cbp_l <= 4'd0; lat_cbp_c <= 2'd0;
			blk_valid <= 1'b0; mb_res_done <= 1'b0;
			blk_id <= 5'd0; max_coeff <= 5'd16;
			chroma_dc <= 1'b0; coeff_token_table <= 3'd7;
			blk_x <= 2'd0; blk_y <= 2'd0;
			is_chroma <= 1'b0; chr_cb <= 1'b0;
		end else if (start_mb) begin
			mb_res_done <= 1'b0;
			blk_valid <= 1'b0;
			i <= 5'd0;
			lat_i16   <= is_i16;
			lat_cbp_l <= cbp_luma;
			lat_cbp_c <= cbp_chroma;
			if (is_i16) st <= S_LDC;
			else        st <= S_LY;
		end else if (advance) begin
			blk_valid <= 1'b0;
			case (st)
			S_LDC: begin
				// After LDC: CBP=0 → DONE (no luma AC, no chroma). Do not present_ly.
				i <= 5'd0;
				if (lat_cbp_l == 4'd0 && lat_cbp_c == 2'd0)
					go_done();
				else if (lat_cbp_l == 4'd0)
					st <= S_CDC;
				else
					st <= S_LY;
			end
			S_LY: begin
				i <= i + 5'd1;
				if (i >= 5'd15) begin
					i <= 5'd0;
					st <= (lat_cbp_c == 2'd0) ? S_DONE : S_CDC;
				end
			end
			S_CDC: begin
				if (i[0]) begin
					i <= 5'd0;
					st <= (lat_cbp_c == 2'd2) ? S_CAC : S_DONE;
				end else
					i <= i + 5'd1;
			end
			S_CAC: begin
				if (i >= 5'd7) st <= S_DONE;
				else           i <= i + 5'd1;
			end
			default: st <= S_DONE;
			endcase
		end else begin
			case (st)
			S_LDC: present_ldc();
			S_LY: begin
				if (next_luma_i(i, lat_cbp_l) < 5'd16) begin
					i <= next_luma_i(i, lat_cbp_l);
					present_ly(next_luma_i(i, lat_cbp_l));
				end else if (lat_cbp_c == 2'd0)
					go_done();
				else begin
					i <= 5'd0;
					st <= S_CDC;
					blk_valid <= 1'b0;
				end
			end
			S_CDC: present_cdc(i[0]);
			S_CAC: present_cac(i);
			S_DONE: begin
				blk_valid <= 1'b0;
				mb_res_done <= 1'b1;
			end
			default: blk_valid <= 1'b0;
			endcase
		end
	end
endmodule

`default_nettype wire
