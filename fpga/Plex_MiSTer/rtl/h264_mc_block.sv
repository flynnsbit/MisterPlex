// Sequential inter prediction block: one macroblock partition's worth of
// motion-compensated luma and chroma prediction.
//
// Drop-in replacement for the combinational h264_inter_mc_part, with a
// start/done handshake instead of a pure function of its inputs.  The luma and
// chroma engines run concurrently and both are lane-parallel, so the block
// completes when the slower of the two retires:
//
//   luma    full-pel 17, no centre sample 65, centre sample 105 cycles
//   chroma  full-pel  9, otherwise 17 cycles
//
// Luma is no longer unconditionally the longer of the two: a vector with
// mv[1:0] == 0 but mv[2] set is integer luma and fractional chroma, so the
// completion is a real join over both engines rather than an assumption that
// chroma always finishes first.
//
// Inputs are the reference windows the DDR DPB fetch produced: 21x21 luma
// (16 samples plus the 5 columns and rows of 6-tap support the interpolator
// needs on each axis) and 9x9 for each chroma plane (8 samples plus the one
// extra the bilinear needs).  Every tap in those windows was clamped to the
// picture bounds during address generation, so motion vectors that point
// outside the picture replicate the edge sample instead of reading garbage or
// walking off the end of the DDR frame bank.
//
// part_w/part_h mask the prediction down to the partition actually being
// predicted.  The engines always compute the full 16x16 / 8x8 because the
// reference window is fetched at the partition origin either way; the mask is
// what stops a smaller partition writing over its neighbours.
//
// These are POST-deblocking reference samples.  Intra prediction neighbour
// taps are the separate PRE-deblocking path and do not pass through here.

`default_nettype none

module h264_mc_block (
	input  wire        clk,
	input  wire        reset,

	input  wire        start,
	output wire        busy,
	output wire        done,

	input  wire [7:0]  luma_ref_win [0:440],
	input  wire [7:0]  chroma_u_ref_win [0:80],
	input  wire [7:0]  chroma_v_ref_win [0:80],
	input  wire [1:0]  luma_frac_x,
	input  wire [1:0]  luma_frac_y,
	input  wire [2:0]  chroma_frac_x,
	input  wire [2:0]  chroma_frac_y,
	input  wire [4:0]  part_w,
	input  wire [4:0]  part_h,

	output wire [7:0]  pred_y [0:255],
	output wire        pred_y_valid [0:255],
	output wire [7:0]  pred_u [0:63],
	output wire        pred_u_valid [0:63],
	output wire [7:0]  pred_v [0:63],
	output wire        pred_v_valid [0:63]
);
	wire luma_busy, luma_done;
	wire chroma_busy, chroma_done;

	wire [7:0] luma_pred [0:255];
	wire [7:0] chroma_u_pred [0:63];
	wire [7:0] chroma_v_pred [0:63];

	h264_mc_luma_qpel u_luma (
		.clk(clk),
		.reset(reset),
		.start(start),
		.ref_win(luma_ref_win),
		.frac_x(luma_frac_x),
		.frac_y(luma_frac_y),
		.busy(luma_busy),
		.done(luma_done),
		.pred(luma_pred)
	);

	h264_mc_chroma_epel u_chroma (
		.clk(clk),
		.reset(reset),
		.start(start),
		.ref_u(chroma_u_ref_win),
		.ref_v(chroma_v_ref_win),
		.frac_x(chroma_frac_x),
		.frac_y(chroma_frac_y),
		.busy(chroma_busy),
		.done(chroma_done),
		.pred_u(chroma_u_pred),
		.pred_v(chroma_v_pred)
	);

	// Join: hold whichever engine finishes first until the other one does.
	reg luma_ret, chroma_ret;
	reg done_r;
	always @(posedge clk) begin
		if (reset) begin
			luma_ret   <= 1'b0;
			chroma_ret <= 1'b0;
			done_r     <= 1'b0;
		end else begin
			done_r <= 1'b0;
			if (start) begin
				luma_ret   <= 1'b0;
				chroma_ret <= 1'b0;
			end else begin
				if (luma_done)   luma_ret   <= 1'b1;
				if (chroma_done) chroma_ret <= 1'b1;
				if ((luma_ret || luma_done) && (chroma_ret || chroma_done)
				    && !(luma_ret && chroma_ret)) begin
					done_r <= 1'b1;
				end
			end
		end
	end

	assign busy = luma_busy || chroma_busy;
	assign done = done_r;

	wire [4:0] chroma_w = {1'b0, part_w[4:1]};
	wire [4:0] chroma_h = {1'b0, part_h[4:1]};

	genvar gi;
	generate
		for (gi = 0; gi < 256; gi = gi + 1) begin : gen_y
			localparam int LX = gi % 16;
			localparam int LY = gi / 16;
			assign pred_y[gi] = luma_pred[gi];
			assign pred_y_valid[gi] = (LX[4:0] < part_w) && (LY[4:0] < part_h);
		end
		for (gi = 0; gi < 64; gi = gi + 1) begin : gen_c
			localparam int CX = gi % 8;
			localparam int CY = gi / 8;
			assign pred_u[gi] = chroma_u_pred[gi];
			assign pred_v[gi] = chroma_v_pred[gi];
			assign pred_u_valid[gi] = (CX[4:0] < chroma_w) && (CY[4:0] < chroma_h);
			assign pred_v_valid[gi] = (CX[4:0] < chroma_w) && (CY[4:0] < chroma_h);
		end
	endgenerate
endmodule

`default_nettype wire
