// H.264 Intra_16x16 DC prediction (ITU-T H.264 clause 8.3.3.3) and
// Intra chroma DC prediction (clause 8.3.4.1), 8-bit / 4:2:0 Baseline.
//
// Neighbour samples MUST be PRE-deblocking reconstructed samples. The
// macroblock-level taps published by h264_intra_nb_ctx (mb_above / mb_left /
// mb_has_above / mb_has_left) satisfy that: its line buffer and left column
// are written from the recon feedback path before the deblock filter runs.
// Post-deblock samples belong to the DPB/MC path and must never be wired here.
//
// Rounding follows the spec literally, per availability case:
//   luma, both:   (sum32 + 16) >> 5
//   luma, top:    (sum16 +  8) >> 4
//   luma, left:   (sum16 +  8) >> 4
//   luma, none:   1 << (BitDepth - 1) = 128
// Chroma repeats the same shape per 4x4 sub-block with sums of 4/8 samples:
//   both:  (sum8 + 4) >> 3     single side: (sum4 + 2) >> 2     none: 128
// The "+half then shift" form (not a truncating divide) is what keeps the
// reconstruction from drifting a DC step per macroblock.
//
// Interface: single-cycle synchronous. Assert `start` with the taps stable;
// `valid` and the prediction registers follow one clock later. `dc_value`
// mirrors the flat prediction so a consumer that only needs the scalar can
// ignore the 256-sample array.

module h264_intra16_dc (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [7:0]  above [0:15],   // p[x,-1], x = 0..15 (pre-deblock)
	input  wire [7:0]  left  [0:15],   // p[-1,y], y = 0..15 (pre-deblock)
	input  wire        has_above,
	input  wire        has_left,
	output reg         valid,
	output reg  [7:0]  dc_value,
	output reg  [7:0]  pred [0:255]    // raster order, pred[y*16 + x]
);
	localparam [7:0] DC_DEFAULT = 8'd128;  // 1 << (BitDepth_Y - 1)

	// Balanced adder trees: 3 levels per 8 samples instead of a 16-deep chain.
	wire [11:0] sum_above;
	wire [11:0] sum_left;

	function automatic [11:0] sum8;
		input [7:0] s0, s1, s2, s3, s4, s5, s6, s7;
		begin
			sum8 = ((({4'd0, s0} + {4'd0, s1}) + ({4'd0, s2} + {4'd0, s3}))
			     +  (({4'd0, s4} + {4'd0, s5}) + ({4'd0, s6} + {4'd0, s7})));
		end
	endfunction

	assign sum_above = sum8(above[0], above[1], above[2], above[3],
	                        above[4], above[5], above[6], above[7])
	                 + sum8(above[8], above[9], above[10], above[11],
	                        above[12], above[13], above[14], above[15]);
	assign sum_left  = sum8(left[0], left[1], left[2], left[3],
	                        left[4], left[5], left[6], left[7])
	                 + sum8(left[8], left[9], left[10], left[11],
	                        left[12], left[13], left[14], left[15]);

	// Clause 8.3.3.3 rounding, all four availability cases. Intermediates are
	// sized so the "+half" never wraps: 32*255 + 16 = 8176 needs 13 bits.
	wire [12:0] sum_both  = {1'b0, sum_above} + {1'b0, sum_left};
	wire [12:0] rnd_both  = sum_both + 13'd16;
	wire [12:0] rnd_above = {1'b0, sum_above} + 13'd8;
	wire [12:0] rnd_left  = {1'b0, sum_left}  + 13'd8;
	wire [7:0]  dc_both  = rnd_both[12:5];    // mean of 32 samples
	wire [7:0]  dc_above = rnd_above[11:4];   // mean of 16 top samples
	wire [7:0]  dc_left  = rnd_left[11:4];    // mean of 16 left samples

	wire [7:0] dc_next = (has_above && has_left) ? dc_both :
	                     has_above               ? dc_above :
	                     has_left                ? dc_left :
	                                               DC_DEFAULT;

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			valid    <= 1'b0;
			dc_value <= DC_DEFAULT;
			for (i = 0; i < 256; i = i + 1) pred[i] <= DC_DEFAULT;
		end else begin
			valid <= 1'b0;
			if (start) begin
				dc_value <= dc_next;
				for (i = 0; i < 256; i = i + 1) pred[i] <= dc_next;
				valid <= 1'b1;
			end
		end
	end
endmodule

// Intra chroma DC prediction for one 8x8 chroma plane (clause 8.3.4.1).
// The 8x8 block is predicted as four independent 4x4 sub-blocks; each uses the
// 4 neighbour samples directly above and/or directly left of that sub-block.
// Corner sub-blocks (top-right, bottom-left) prefer one side and only fall back
// to the other when their preferred side is unavailable -- that asymmetry is
// part of the spec, not an optimisation.
module h264_chroma8_dc (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [7:0]  above [0:7],    // p[x,-1], x = 0..7 (pre-deblock)
	input  wire [7:0]  left  [0:7],    // p[-1,y], y = 0..7 (pre-deblock)
	input  wire        has_above,
	input  wire        has_left,
	output reg         valid,
	output reg  [7:0]  dc_tl,
	output reg  [7:0]  dc_tr,
	output reg  [7:0]  dc_bl,
	output reg  [7:0]  dc_br,
	output reg  [7:0]  pred [0:63]     // raster order, pred[y*8 + x]
);
	localparam [7:0] DC_DEFAULT = 8'd128;  // 1 << (BitDepth_C - 1)

	function automatic [9:0] sum4;
		input [7:0] s0, s1, s2, s3;
		begin
			sum4 = ({2'd0, s0} + {2'd0, s1}) + ({2'd0, s2} + {2'd0, s3});
		end
	endfunction

	wire [9:0] sa_lo = sum4(above[0], above[1], above[2], above[3]);
	wire [9:0] sa_hi = sum4(above[4], above[5], above[6], above[7]);
	wire [9:0] sl_lo = sum4(left[0], left[1], left[2], left[3]);
	wire [9:0] sl_hi = sum4(left[4], left[5], left[6], left[7]);

	// Sub-block means: (sum8 + 4) >> 3 when both sides feed the sub-block,
	// (sum4 + 2) >> 2 when only one side does. Intermediates are 12 bits so the
	// two-sided sum (8*255 + 4 = 2044) cannot wrap.
	wire [11:0] rnd_a_lo = {2'd0, sa_lo} + 12'd2;
	wire [11:0] rnd_a_hi = {2'd0, sa_hi} + 12'd2;
	wire [11:0] rnd_l_lo = {2'd0, sl_lo} + 12'd2;
	wire [11:0] rnd_l_hi = {2'd0, sl_hi} + 12'd2;
	wire [11:0] rnd_mix_lo = ({2'd0, sa_lo} + {2'd0, sl_lo}) + 12'd4;
	wire [11:0] rnd_mix_hi = ({2'd0, sa_hi} + {2'd0, sl_hi}) + 12'd4;

	wire [7:0] dc_a_lo = rnd_a_lo[9:2];
	wire [7:0] dc_a_hi = rnd_a_hi[9:2];
	wire [7:0] dc_l_lo = rnd_l_lo[9:2];
	wire [7:0] dc_l_hi = rnd_l_hi[9:2];
	wire [7:0] dc_mix_lo = rnd_mix_lo[10:3];
	wire [7:0] dc_mix_hi = rnd_mix_hi[10:3];

	// Top-left (blk 0) and bottom-right (blk 3): average both sides.
	wire [7:0] dc_tl_next = (has_above && has_left) ? dc_mix_lo :
	                        has_above               ? dc_a_lo :
	                        has_left                ? dc_l_lo : DC_DEFAULT;
	wire [7:0] dc_br_next = (has_above && has_left) ? dc_mix_hi :
	                        has_above               ? dc_a_hi :
	                        has_left                ? dc_l_hi : DC_DEFAULT;
	// Top-right (blk 1): prefer the samples above it.
	wire [7:0] dc_tr_next = has_above ? dc_a_hi :
	                        has_left  ? dc_l_lo : DC_DEFAULT;
	// Bottom-left (blk 2): prefer the samples left of it.
	wire [7:0] dc_bl_next = has_left  ? dc_l_hi :
	                        has_above ? dc_a_lo : DC_DEFAULT;

	integer x, y, i;
	always @(posedge clk) begin
		if (reset) begin
			valid <= 1'b0;
			dc_tl <= DC_DEFAULT; dc_tr <= DC_DEFAULT;
			dc_bl <= DC_DEFAULT; dc_br <= DC_DEFAULT;
			for (i = 0; i < 64; i = i + 1) pred[i] <= DC_DEFAULT;
		end else begin
			valid <= 1'b0;
			if (start) begin
				dc_tl <= dc_tl_next; dc_tr <= dc_tr_next;
				dc_bl <= dc_bl_next; dc_br <= dc_br_next;
				for (y = 0; y < 8; y = y + 1)
					for (x = 0; x < 8; x = x + 1)
						pred[y * 8 + x] <= (y < 4)
						                 ? ((x < 4) ? dc_tl_next : dc_tr_next)
						                 : ((x < 4) ? dc_bl_next : dc_br_next);
				valid <= 1'b1;
			end
		end
	end
endmodule
