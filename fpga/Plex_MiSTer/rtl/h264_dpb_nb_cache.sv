// h264_dpb_nb_cache.sv — on-chip MB neighbourhood working set (not a full DPB).
//
// Holds only what intra/deblock/MC neighbour paths need:
//   - top_y[FRAME_W]: last completed luma line above the current MB row
//   - left_y[16]: left column of the current MB (updated as samples commit)
//   - chroma halves for U/V
//
// Full reference frames live in external DDR (see h264_dpb_ddr_backend).
// Parameterised on FRAME_W/FRAME_H so 480p and 720p both elaborate.
//
// Product default: not wired into decode_stub; fabric decode opts in.
`default_nettype none

module h264_dpb_nb_cache #(
	parameter int FRAME_W = 624,
	parameter int FRAME_H = 480
)(
	input  wire        clk,
	input  wire        reset,

	// Commit one reconstructed sample into neighbourhood state
	input  wire        sample_valid,
	input  wire [7:0]  mb_x,
	input  wire [7:0]  mb_y,
	input  wire [1:0]  plane,       // 0=Y 1=U 2=V
	input  wire [7:0]  sample_idx,  // Y: {y[3:0],x[3:0]} ; C: {2'b0,y[2:0],x[2:0]}
	input  wire [7:0]  sample,

	// End of MB row: promote bottom line of this MB row into top_y strip
	input  wire        mb_row_done, // pulse when mb_x walks past last MB of row

	// Neighbour readout
	input  wire [15:0] top_x,       // absolute pixel x for top-line peek
	output reg  [7:0]  top_y_sample,
	output reg         top_y_valid,

	input  wire [3:0]  left_row,    // 0..15 within MB
	output reg  [7:0]  left_y_sample,
	output reg         left_y_valid,

	// Diagnostics / TB
	output wire        have_left_o,
	output wire        have_top_o,
	output wire [31:0] onchip_bytes_y,
	output wire [31:0] onchip_bytes_total
);
	localparam int C_W = FRAME_W / 2;

	// On-chip only — full-frame DPB is forbidden here.
	(* ramstyle = "no_rw_check, M10K" *) reg [7:0] top_y [0:FRAME_W-1];
	(* ramstyle = "no_rw_check, M10K" *) reg [7:0] top_u [0:C_W-1];
	(* ramstyle = "no_rw_check, M10K" *) reg [7:0] top_v [0:C_W-1];
	reg [7:0] left_y [0:15];
	reg [7:0] left_u [0:7];
	reg [7:0] left_v [0:7];

	// Bottom line of current MB row assembling into next top strip
	(* ramstyle = "no_rw_check, M10K" *) reg [7:0] rowbuf_y [0:FRAME_W-1];

	reg [7:0] cur_mb_y;
	reg       have_top_row; // false until first mb_row_done
	reg       have_left;    // false at mb_x==0 until samples written

	assign have_left_o = have_left;
	assign have_top_o  = have_top_row;
	assign onchip_bytes_y = FRAME_W + FRAME_W + 16; // top + rowbuf + left
	assign onchip_bytes_total = onchip_bytes_y + C_W + C_W + 8 + 8;

	wire [3:0] y_lx = sample_idx[3:0];
	wire [3:0] y_ly = sample_idx[7:4];
	wire [2:0] c_lx = sample_idx[2:0];
	wire [2:0] c_ly = sample_idx[5:3];
	wire [15:0] abs_x_y = {4'd0, mb_x, 4'd0} + {12'd0, y_lx};
	wire [15:0] abs_x_c = {5'd0, mb_x, 3'd0} + {13'd0, c_lx};

	always @(posedge clk) begin
		if (reset) begin
			cur_mb_y     <= 8'd0;
			have_top_row <= 1'b0;
			have_left    <= 1'b0;
			top_y_sample <= 8'd0;
			top_y_valid  <= 1'b0;
			left_y_sample<= 8'd0;
			left_y_valid <= 1'b0;
		end else begin
			// Default readout holds last
			top_y_valid  <= have_top_row && (top_x < FRAME_W[15:0]);
			if (have_top_row && (top_x < FRAME_W[15:0]))
				top_y_sample <= top_y[top_x[$clog2(FRAME_W)-1:0]];
			// Left valid only when mb has left neighbour (mb_x!=0) and filled
			left_y_valid  <= have_left;
			left_y_sample <= left_y[left_row];

			if (sample_valid) begin
				cur_mb_y <= mb_y;
				// Left column: rightmost samples of MB become left for next MB;
				// while decoding current MB, left_* holds previous MB's right edge.
				if (plane == 2'd0) begin
					// Track bottom line of MB into rowbuf (y_ly==15)
					if (y_ly == 4'd15 && abs_x_y < FRAME_W[15:0])
						rowbuf_y[abs_x_y[$clog2(FRAME_W)-1:0]] <= sample;
					// When finishing right edge of this MB, copy into left for next
					if (y_lx == 4'd15) begin
						left_y[y_ly] <= sample;
						// have_left becomes true for the *next* MB; for mb_x==0 start, clear
					end
				end else if (plane == 2'd1) begin
					if (c_lx == 3'd7)
						left_u[c_ly] <= sample;
					if (c_ly == 3'd7 && abs_x_c < C_W[15:0])
						top_u[abs_x_c[$clog2(C_W)-1:0]] <= sample;
				end else begin
					if (c_lx == 3'd7)
						left_v[c_ly] <= sample;
					if (c_ly == 3'd7 && abs_x_c < C_W[15:0])
						top_v[abs_x_c[$clog2(C_W)-1:0]] <= sample;
				end
			end

			// Starting a new MB at x==0 invalidates left column (row wrap / picture left edge)
			if (sample_valid && (mb_x == 8'd0) && (plane == 2'd0) && (sample_idx == 8'd0))
				have_left <= 1'b0;

			// After any right-edge Y sample of an MB with mb_x that implies next has left
			if (sample_valid && plane == 2'd0 && y_lx == 4'd15)
				have_left <= 1'b1; // next MB may use left — still gated by mb_x!=0 at reader

			if (mb_row_done) begin
				// Promote assembled bottom line → top_y for next MB row
				// (TB / host copies; synthesis uses generate loop unrolled carefully)
				have_top_row <= 1'b1;
				have_left    <= 1'b0;
			end
		end
	end

	// Explicit promote copy — separate always to keep tool happy on large FRAME_W
	integer pi;
	always @(posedge clk) begin
		if (!reset && mb_row_done) begin
			for (pi = 0; pi < FRAME_W; pi = pi + 1)
				top_y[pi] <= rowbuf_y[pi];
		end
	end

	// Reader-side gate: left only valid when request comes with mb_x!=0.
	// Exposed via left_y_valid already; TB must drive mb context. Additional
	// combinational helper for callers that pass absolute mb_x:
endmodule

// Combinational left-valid qualifier used by consumers / TB.
module h264_dpb_nb_left_ok (
	input  wire [7:0] mb_x,
	input  wire       cache_have_left,
	output wire       left_ok
);
	assign left_ok = (mb_x != 8'd0) && cache_have_left;
endmodule

`default_nettype wire
