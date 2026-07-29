// Sequential inter prediction block: one macroblock partition's worth of
// motion-compensated luma and chroma prediction.
//
// STREAMING INTERFACE, NOT PORT ARRAYS
//   This module used to take the reference windows in as flat port arrays
//   (`input [7:0] luma_ref_win [0:440]` and two 81-entry chroma arrays) and
//   hand back 256+64+64 prediction samples the same way.  Both ends of that
//   are extremely expensive in fabric: the producer has to hold 603 bytes in
//   registers, and every runtime index into them is a several-hundred-to-one
//   multiplexer.  The fit reported 89,888 combinational ALUTs for the luma
//   interpolator alone, 54% of the entire design and more than the whole
//   device budget, and essentially all of it was window multiplexing.
//
//   The windows now stream in one sample per cycle on a write port that maps
//   directly onto what the DPB fetch already emits (valid + index + sample),
//   and the predictions come back out through a read port.  Nothing holds a
//   window in registers anywhere in the design any more.
//
//   Inside, each engine has exactly one filter datapath, time-multiplexed
//   over the block, with its working planes in M10K.  Memory occupancy was
//   52% while logic was 248%, so trading cycles and memory for logic is the
//   trade the device wants.
//
// The luma and chroma engines still run concurrently and the block completes
// when the slower of the two retires.  Luma is not unconditionally the longer
// one: a vector with mv[1:0] == 0 but mv[2] set is integer luma and
// fractional chroma, so completion is a real join over both engines.
//
// Window geometry is unchanged: 21x21 luma (16 samples plus the 5 columns and
// rows of 6-tap support on each axis) and 9x9 per chroma plane (8 samples plus
// the one extra the bilinear needs).  Every tap in those windows was clamped
// to the picture bounds during address generation, so motion vectors that
// point outside the picture replicate the edge sample instead of reading
// garbage or walking off the end of the DDR frame bank.
//
// part_w/part_h mask the prediction down to the partition actually being
// predicted.  The engines always compute the full 16x16 / 8x8 because the
// reference window is fetched at the partition origin either way; the mask is
// what stops a smaller partition writing over its neighbours.  It is now
// applied combinationally on the read port instead of being stored.
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

	// Reference window streaming write ports, driven straight from the DPB
	// fetch's window valid/index/sample outputs.
	input  wire        luma_win_wr,
	input  wire [8:0]  luma_win_addr,
	input  wire [7:0]  luma_win_data,
	input  wire        chroma_u_win_wr,
	input  wire        chroma_v_win_wr,
	input  wire [6:0]  chroma_win_addr,
	input  wire [7:0]  chroma_win_data,

	input  wire [1:0]  luma_frac_x,
	input  wire [1:0]  luma_frac_y,
	input  wire [2:0]  chroma_frac_x,
	input  wire [2:0]  chroma_frac_y,
	input  wire [4:0]  part_w,
	input  wire [4:0]  part_h,

	// Prediction read ports.
	input  wire [7:0]  pred_y_rd_idx,
	output wire [7:0]  pred_y_rd_data,
	output wire        pred_y_rd_in_part,
	input  wire [5:0]  pred_c_rd_idx,
	output wire [7:0]  pred_u_rd_data,
	output wire [7:0]  pred_v_rd_data,
	output wire        pred_c_rd_in_part,

	// First 16 luma samples in registers, for the legacy parallel tap in
	// decode_stub's recon observability path.
	output wire [7:0]  pred_y_head [0:15]
);
	wire luma_busy, luma_done;
	wire chroma_busy, chroma_done;

	h264_mc_luma_qpel u_luma (
		.clk(clk),
		.reset(reset),
		.win_wr(luma_win_wr),
		.win_addr(luma_win_addr),
		.win_data(luma_win_data),
		.start(start),
		.frac_x(luma_frac_x),
		.frac_y(luma_frac_y),
		.busy(luma_busy),
		.done(luma_done),
		.pred_rd_idx(pred_y_rd_idx),
		.pred_rd_data(pred_y_rd_data),
		.pred_head(pred_y_head)
	);

	h264_mc_chroma_epel u_chroma (
		.clk(clk),
		.reset(reset),
		.win_u_wr(chroma_u_win_wr),
		.win_v_wr(chroma_v_win_wr),
		.win_addr(chroma_win_addr),
		.win_data(chroma_win_data),
		.start(start),
		.frac_x(chroma_frac_x),
		.frac_y(chroma_frac_y),
		.busy(chroma_busy),
		.done(chroma_done),
		.pred_rd_idx(pred_c_rd_idx),
		.pred_u_rd_data(pred_u_rd_data),
		.pred_v_rd_data(pred_v_rd_data)
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

	// Partition masking on the read port: no storage, just a compare against
	// the index being read.
	assign pred_y_rd_in_part = ({1'b0, pred_y_rd_idx[3:0]} < part_w) &&
	                           ({1'b0, pred_y_rd_idx[7:4]} < part_h);
	assign pred_c_rd_in_part = ({2'b0, pred_c_rd_idx[2:0]} < chroma_w) &&
	                           ({2'b0, pred_c_rd_idx[5:3]} < chroma_h);
endmodule

`default_nettype wire
