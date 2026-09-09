// Chroma AC nC neighbor pick (ITU 9.2.1). Include from mb_ctrl.
// Reuse h264_cavlc_nc_predictor — feed THESE TCs, not luma tc_left/tc_up.
// Chroma DC does not use this (coeff_token_table = 4).
//
// Widen the RAMs (current tc_chr_left[0:1] / tc_chr_up[0:39] are short):
//   reg [4:0] tc_chr_cur  [0:7];          // {cb, y, x}
//   reg [4:0] tc_chr_left [0:3];          // {cb, y}  = right column of left MB
//   reg [4:0] tc_chr_up   [0:MB_W*4-1];   // {mb_x, cb, x}; MB_W=80 (720p), 20 also works if you cap
//
// Uncoded chroma AC (cbp_c != 2, neighbor MB exists): store 0, valid=1.
// Missing left/up MB: leave valid=0; predictor yields nC=0 if both missing.

function automatic [2:0] h264_chr_cur_i;
	input cb;
	input [1:0] y;
	input [1:0] x;
	h264_chr_cur_i = {cb, y[0], x[0]};
endfunction

function automatic [1:0] h264_chr_left_i;
	input cb;
	input [1:0] y;
	h264_chr_left_i = {cb, y[0]};
endfunction

function automatic [9:0] h264_chr_up_i;
	input [7:0] mb_x;
	input cb;
	input [1:0] x;
	// mb_x * 4 + {cb, x}
	h264_chr_up_i = {mb_x, 2'b00} + {8'd0, cb, x[0]};
endfunction

// After chroma AC CAVLC (or zero-fill when cbp_c != 2):
//   tc_chr_cur[h264_chr_cur_i(cb,y,x)] <= tc;
//   if (x[0]) tc_chr_left[h264_chr_left_i(cb,y)] <= tc;
//   if (y[0]) tc_chr_up[h264_chr_up_i(mb_x,cb,x)] <= tc;
//
// Mux into u_nc when rseq_chr && !rseq_cdc:
//   nC_left = (x[0]==0) ? tc_chr_left[h264_chr_left_i(cb,y)]
//                       : tc_chr_cur[h264_chr_cur_i(cb,y,2'd0)];
//   nC_up   = (y[0]==0) ? tc_chr_up[h264_chr_up_i(mb_x,cb,x)]
//                       : tc_chr_cur[h264_chr_cur_i(cb,2'd0,x)];
// luma path unchanged. Same left_mb / up_mb availability as luma (MB grid).
