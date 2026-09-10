// Exact six-bit QP decoding, including rejected QPs 52..63.
// Module-local functions: this header is intentionally included per module.
function automatic [3:0] h264_qp_div6(input [5:0] q);
	case (q)
	0,1,2,3,4,5: h264_qp_div6=0;
	6,7,8,9,10,11: h264_qp_div6=1;
	12,13,14,15,16,17: h264_qp_div6=2;
	18,19,20,21,22,23: h264_qp_div6=3;
	24,25,26,27,28,29: h264_qp_div6=4;
	30,31,32,33,34,35: h264_qp_div6=5;
	36,37,38,39,40,41: h264_qp_div6=6;
	42,43,44,45,46,47: h264_qp_div6=7;
	48,49,50,51,52,53: h264_qp_div6=8;
	54,55,56,57,58,59: h264_qp_div6=9;
	default: h264_qp_div6=10;
	endcase
endfunction

function automatic [2:0] h264_qp_mod6(input [5:0] q);
	case (q)
	0,6,12,18,24,30,36,42,48,54,60: h264_qp_mod6=0;
	1,7,13,19,25,31,37,43,49,55,61: h264_qp_mod6=1;
	2,8,14,20,26,32,38,44,50,56,62: h264_qp_mod6=2;
	3,9,15,21,27,33,39,45,51,57,63: h264_qp_mod6=3;
	4,10,16,22,28,34,40,46,52,58: h264_qp_mod6=4;
	default: h264_qp_mod6=5;
	endcase
endfunction
