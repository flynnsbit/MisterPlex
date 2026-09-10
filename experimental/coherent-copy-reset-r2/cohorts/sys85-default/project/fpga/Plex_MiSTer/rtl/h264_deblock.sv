// H.264 Baseline in-loop deblocking building blocks.
// Product RTL only: test scaffolding belongs under tests/rtl.
//
// The scheduler consumes these blocks per 4-sample edge segment, in normative
// order: vertical edges left-to-right, then horizontal edges top-to-bottom.

`default_nettype none

module h264_deblock_bs (
	input  wire        disable_all,
	input  wire        slice_boundary_blocked,
	input  wire        mb_boundary,
	input  wire        p_intra,
	input  wire        q_intra,
	input  wire        p_nonzero,
	input  wire        q_nonzero,
	input  wire [1:0]  p_ref,
	input  wire [1:0]  q_ref,
	input  wire signed [11:0] p_mvx,
	input  wire signed [11:0] p_mvy,
	input  wire signed [11:0] q_mvx,
	input  wire signed [11:0] q_mvy,
	output reg  [2:0]  bs,
	output wire        unsupported_ref
);
	wire signed [12:0] mvx_diff = $signed({p_mvx[11], p_mvx}) - $signed({q_mvx[11], q_mvx});
	wire signed [12:0] mvy_diff = $signed({p_mvy[11], p_mvy}) - $signed({q_mvy[11], q_mvy});
	wire [12:0] abs_mvx = mvx_diff[12] ? (~mvx_diff + 13'd1) : mvx_diff;
	wire [12:0] abs_mvy = mvy_diff[12] ? (~mvy_diff + 13'd1) : mvy_diff;

	assign unsupported_ref = !disable_all && !slice_boundary_blocked &&
		!p_intra && !q_intra && ((p_ref > 2'd1) || (q_ref > 2'd1));

	always @* begin
		if (disable_all || slice_boundary_blocked || unsupported_ref) begin
			bs = 3'd0;
		end else if (p_intra || q_intra) begin
			bs = mb_boundary ? 3'd4 : 3'd3;
		end else if (p_nonzero || q_nonzero) begin
			bs = 3'd2;
		end else if ((p_ref != q_ref) || (abs_mvx >= 13'd4) || (abs_mvy >= 13'd4)) begin
			bs = 3'd1;
		end else begin
			bs = 3'd0;
		end
	end
endmodule

// Map EACH side's chroma QP before averaging. Averaging luma QPs and
// then applying the nonlinear chroma map gives a different threshold.
module h264_deblock_qp (
	input wire is_chroma,
	input wire [5:0] qp_p, qp_q,
	input wire signed [4:0] chroma_qp_index_offset,
	output wire [5:0] qp_avg
);
	function automatic [5:0] chroma_qp(input [5:0] qp, input signed [4:0] offset);
		reg signed [7:0] idx;
		begin
			// Full port range is [-16,78], before clipping.
			idx = $signed({2'b00,qp}) + $signed({{3{offset[4]}},offset});
			if (idx < 0) idx = 0;
			if (idx > 51) idx = 51;
			case (idx)
			30: chroma_qp=29; 31: chroma_qp=30;
			32: chroma_qp=31; 33: chroma_qp=32; 34: chroma_qp=32;
			35: chroma_qp=33; 36: chroma_qp=34; 37: chroma_qp=34;
			38: chroma_qp=35; 39: chroma_qp=35; 40: chroma_qp=36;
			41: chroma_qp=36; 42: chroma_qp=37; 43: chroma_qp=37; 44: chroma_qp=37;
			45: chroma_qp=38; 46: chroma_qp=38; 47: chroma_qp=38;
			48: chroma_qp=39; 49: chroma_qp=39; 50: chroma_qp=39; 51: chroma_qp=39;
			default: chroma_qp=idx[5:0];
			endcase
		end
	endfunction
	wire [5:0] p = is_chroma ? chroma_qp(qp_p, chroma_qp_index_offset) : qp_p;
	wire [5:0] q = is_chroma ? chroma_qp(qp_q, chroma_qp_index_offset) : qp_q;
	wire [6:0] sum = {1'b0,p}+{1'b0,q}+7'd1;
	assign qp_avg = sum[6:1];
endmodule

module h264_deblock_thresholds (
	input  wire [5:0]        qp_avg,
	// These are actual offsets (2 * slice_*_offset_div2), not syntax div2.
	input  wire signed [4:0] slice_alpha_c0_offset,
	input  wire signed [4:0] slice_beta_offset,
	input  wire [2:0]        bs,
	output wire [7:0]        alpha,
	output wire [7:0]        beta,
	output wire [5:0]        index_a,
	output wire [5:0]        index_b,
	output reg  [5:0]        tc0
);
	function automatic [5:0] clip_index;
		input signed [7:0] v;
		begin
			if (v < 8'sd0) clip_index = 6'd0;
			else if (v > 8'sd51) clip_index = 6'd51;
			else clip_index = v[5:0];
		end
	endfunction

	function automatic [7:0] alpha_lut;
		input [5:0] idx;
		begin
			case (idx)
			6'd16: alpha_lut = 8'd4;   6'd17: alpha_lut = 8'd4;   6'd18: alpha_lut = 8'd5;   6'd19: alpha_lut = 8'd6;
			6'd20: alpha_lut = 8'd7;   6'd21: alpha_lut = 8'd8;   6'd22: alpha_lut = 8'd9;   6'd23: alpha_lut = 8'd10;
			6'd24: alpha_lut = 8'd12;  6'd25: alpha_lut = 8'd13;  6'd26: alpha_lut = 8'd15;  6'd27: alpha_lut = 8'd17;
			6'd28: alpha_lut = 8'd20;  6'd29: alpha_lut = 8'd22;  6'd30: alpha_lut = 8'd25;  6'd31: alpha_lut = 8'd28;
			6'd32: alpha_lut = 8'd32;  6'd33: alpha_lut = 8'd36;  6'd34: alpha_lut = 8'd40;  6'd35: alpha_lut = 8'd45;
			6'd36: alpha_lut = 8'd50;  6'd37: alpha_lut = 8'd56;  6'd38: alpha_lut = 8'd63;  6'd39: alpha_lut = 8'd71;
			6'd40: alpha_lut = 8'd80;  6'd41: alpha_lut = 8'd90;  6'd42: alpha_lut = 8'd101; 6'd43: alpha_lut = 8'd113;
			6'd44: alpha_lut = 8'd127; 6'd45: alpha_lut = 8'd144; 6'd46: alpha_lut = 8'd162; 6'd47: alpha_lut = 8'd182;
			6'd48: alpha_lut = 8'd203; 6'd49: alpha_lut = 8'd226; 6'd50: alpha_lut = 8'd255; 6'd51: alpha_lut = 8'd255;
			default: alpha_lut = 8'd0;
			endcase
		end
	endfunction

	function automatic [7:0] beta_lut;
		input [5:0] idx;
		begin
			case (idx)
			6'd16: beta_lut = 8'd2;  6'd17: beta_lut = 8'd2;  6'd18: beta_lut = 8'd2;  6'd19: beta_lut = 8'd3;
			6'd20: beta_lut = 8'd3;  6'd21: beta_lut = 8'd3;  6'd22: beta_lut = 8'd3;  6'd23: beta_lut = 8'd4;
			6'd24: beta_lut = 8'd4;  6'd25: beta_lut = 8'd4;  6'd26: beta_lut = 8'd6;  6'd27: beta_lut = 8'd6;
			6'd28: beta_lut = 8'd7;  6'd29: beta_lut = 8'd7;  6'd30: beta_lut = 8'd8;  6'd31: beta_lut = 8'd8;
			6'd32: beta_lut = 8'd9;  6'd33: beta_lut = 8'd9;  6'd34: beta_lut = 8'd10; 6'd35: beta_lut = 8'd10;
			6'd36: beta_lut = 8'd11; 6'd37: beta_lut = 8'd11; 6'd38: beta_lut = 8'd12; 6'd39: beta_lut = 8'd12;
			6'd40: beta_lut = 8'd13; 6'd41: beta_lut = 8'd13; 6'd42: beta_lut = 8'd14; 6'd43: beta_lut = 8'd14;
			6'd44: beta_lut = 8'd15; 6'd45: beta_lut = 8'd15; 6'd46: beta_lut = 8'd16; 6'd47: beta_lut = 8'd16;
			6'd48: beta_lut = 8'd17; 6'd49: beta_lut = 8'd17; 6'd50: beta_lut = 8'd18; 6'd51: beta_lut = 8'd18;
			default: beta_lut = 8'd0;
			endcase
		end
	endfunction

	assign index_a = clip_index($signed({2'b00, qp_avg}) + {{3{slice_alpha_c0_offset[4]}}, slice_alpha_c0_offset});
	assign index_b = clip_index($signed({2'b00, qp_avg}) + {{3{slice_beta_offset[4]}}, slice_beta_offset});
	assign alpha = alpha_lut(index_a);
	assign beta = beta_lut(index_b);

	always @* begin
		case ({index_a, bs})
		9'o201: tc0 = 6'd0;  9'o202: tc0 = 6'd0;  9'o203: tc0 = 6'd0;
		9'o211: tc0 = 6'd0;  9'o212: tc0 = 6'd0;  9'o213: tc0 = 6'd1;
		9'o221: tc0 = 6'd0;  9'o222: tc0 = 6'd0;  9'o223: tc0 = 6'd1;
		9'o231: tc0 = 6'd0;  9'o232: tc0 = 6'd0;  9'o233: tc0 = 6'd1;
		9'o241: tc0 = 6'd0;  9'o242: tc0 = 6'd0;  9'o243: tc0 = 6'd1;
		9'o251: tc0 = 6'd0;  9'o252: tc0 = 6'd1;  9'o253: tc0 = 6'd1;
		9'o261: tc0 = 6'd0;  9'o262: tc0 = 6'd1;  9'o263: tc0 = 6'd1;
		9'o271: tc0 = 6'd1;  9'o272: tc0 = 6'd1;  9'o273: tc0 = 6'd1;
		9'o301: tc0 = 6'd1;  9'o302: tc0 = 6'd1;  9'o303: tc0 = 6'd1;
		9'o311: tc0 = 6'd1;  9'o312: tc0 = 6'd1;  9'o313: tc0 = 6'd1;
		9'o321: tc0 = 6'd1;  9'o322: tc0 = 6'd1;  9'o323: tc0 = 6'd1;
		9'o331: tc0 = 6'd1;  9'o332: tc0 = 6'd1;  9'o333: tc0 = 6'd2;
		9'o341: tc0 = 6'd1;  9'o342: tc0 = 6'd1;  9'o343: tc0 = 6'd2;
		9'o351: tc0 = 6'd1;  9'o352: tc0 = 6'd1;  9'o353: tc0 = 6'd2;
		9'o361: tc0 = 6'd1;  9'o362: tc0 = 6'd1;  9'o363: tc0 = 6'd2;
		9'o371: tc0 = 6'd1;  9'o372: tc0 = 6'd2;  9'o373: tc0 = 6'd3;
		9'o401: tc0 = 6'd1;  9'o402: tc0 = 6'd2;  9'o403: tc0 = 6'd3;
		9'o411: tc0 = 6'd2;  9'o412: tc0 = 6'd2;  9'o413: tc0 = 6'd3;
		9'o421: tc0 = 6'd2;  9'o422: tc0 = 6'd2;  9'o423: tc0 = 6'd4;
		9'o431: tc0 = 6'd2;  9'o432: tc0 = 6'd3;  9'o433: tc0 = 6'd4;
		9'o441: tc0 = 6'd2;  9'o442: tc0 = 6'd3;  9'o443: tc0 = 6'd4;
		9'o451: tc0 = 6'd3;  9'o452: tc0 = 6'd3;  9'o453: tc0 = 6'd5;
		9'o461: tc0 = 6'd3;  9'o462: tc0 = 6'd4;  9'o463: tc0 = 6'd6;
		9'o471: tc0 = 6'd3;  9'o472: tc0 = 6'd4;  9'o473: tc0 = 6'd6;
		9'o501: tc0 = 6'd4;  9'o502: tc0 = 6'd5;  9'o503: tc0 = 6'd7;
		9'o511: tc0 = 6'd4;  9'o512: tc0 = 6'd5;  9'o513: tc0 = 6'd8;
		9'o521: tc0 = 6'd4;  9'o522: tc0 = 6'd6;  9'o523: tc0 = 6'd9;
		9'o531: tc0 = 6'd5;  9'o532: tc0 = 6'd7;  9'o533: tc0 = 6'd10;
		9'o541: tc0 = 6'd6;  9'o542: tc0 = 6'd8;  9'o543: tc0 = 6'd11;
		9'o551: tc0 = 6'd6;  9'o552: tc0 = 6'd8;  9'o553: tc0 = 6'd13;
		9'o561: tc0 = 6'd7;  9'o562: tc0 = 6'd10; 9'o563: tc0 = 6'd14;
		9'o571: tc0 = 6'd8;  9'o572: tc0 = 6'd11; 9'o573: tc0 = 6'd16;
		9'o601: tc0 = 6'd9;  9'o602: tc0 = 6'd12; 9'o603: tc0 = 6'd18;
		9'o611: tc0 = 6'd10; 9'o612: tc0 = 6'd13; 9'o613: tc0 = 6'd20;
		9'o621: tc0 = 6'd11; 9'o622: tc0 = 6'd15; 9'o623: tc0 = 6'd23;
		9'o631: tc0 = 6'd13; 9'o632: tc0 = 6'd17; 9'o633: tc0 = 6'd25;
		default: tc0 = 6'd0;
		endcase
	end
endmodule

module h264_deblock_edge (
	input  wire              is_chroma,
	input  wire [2:0]        bs,
	input  wire [5:0]        qp_avg,
	input  wire signed [4:0] slice_alpha_c0_offset,
	input  wire signed [4:0] slice_beta_offset,
	input  wire [7:0]        p3_in [0:3],
	input  wire [7:0]        p2_in [0:3],
	input  wire [7:0]        p1_in [0:3],
	input  wire [7:0]        p0_in [0:3],
	input  wire [7:0]        q0_in [0:3],
	input  wire [7:0]        q1_in [0:3],
	input  wire [7:0]        q2_in [0:3],
	input  wire [7:0]        q3_in [0:3],
	output reg  [7:0]        p2_out [0:3],
	output reg  [7:0]        p1_out [0:3],
	output reg  [7:0]        p0_out [0:3],
	output reg  [7:0]        q0_out [0:3],
	output reg  [7:0]        q1_out [0:3],
	output reg  [7:0]        q2_out [0:3],
	output wire [7:0]        alpha_dbg,
	output wire [7:0]        beta_dbg,
	output wire [5:0]        tc0_dbg
);
	wire [5:0] index_a_unused, index_b_unused;
	h264_deblock_thresholds u_thr (
		.qp_avg(qp_avg),
		.slice_alpha_c0_offset(slice_alpha_c0_offset),
		.slice_beta_offset(slice_beta_offset),
		.bs(bs),
		.alpha(alpha_dbg),
		.beta(beta_dbg),
		.index_a(index_a_unused),
		.index_b(index_b_unused),
		.tc0(tc0_dbg)
	);

	function automatic [7:0] clip8;
		input signed [13:0] v;
		begin
			if (v < 14'sd0) clip8 = 8'd0;
			else if (v > 14'sd255) clip8 = 8'd255;
			else clip8 = v[7:0];
		end
	endfunction

	function automatic signed [13:0] clip_signed;
		input signed [13:0] lo;
		input signed [13:0] hi;
		input signed [13:0] v;
		begin
			if (v < lo) clip_signed = lo;
			else if (v > hi) clip_signed = hi;
			else clip_signed = v;
		end
	endfunction

	function automatic [8:0] absdiff8;
		input [7:0] a;
		input [7:0] b;
		begin
			absdiff8 = (a >= b) ? ({1'b0, a} - {1'b0, b}) : ({1'b0, b} - {1'b0, a});
		end
	endfunction

	integer i;
	reg filter_ok;
	reg ap;
	reg aq;
	reg strong_extra;
	reg signed [13:0] tc;
	reg signed [13:0] delta;
	reg signed [13:0] adj;
	reg signed [13:0] p0s, p1s, p2s, p3s, q0s, q1s, q2s, q3s;

	always @* begin
		for (i = 0; i < 4; i = i + 1) begin
			p2_out[i] = p2_in[i];
			p1_out[i] = p1_in[i];
			p0_out[i] = p0_in[i];
			q0_out[i] = q0_in[i];
			q1_out[i] = q1_in[i];
			q2_out[i] = q2_in[i];

			p0s = {6'b000000, p0_in[i]}; p1s = {6'b000000, p1_in[i]}; p2s = {6'b000000, p2_in[i]}; p3s = {6'b000000, p3_in[i]};
			q0s = {6'b000000, q0_in[i]}; q1s = {6'b000000, q1_in[i]}; q2s = {6'b000000, q2_in[i]}; q3s = {6'b000000, q3_in[i]};
			tc = 14'sd0;
			delta = 14'sd0;
			adj = 14'sd0;
			filter_ok = (bs != 3'd0) && (absdiff8(p0_in[i], q0_in[i]) < {1'b0, alpha_dbg}) &&
			            (absdiff8(p1_in[i], p0_in[i]) < {1'b0, beta_dbg}) &&
			            (absdiff8(q1_in[i], q0_in[i]) < {1'b0, beta_dbg});
			ap = absdiff8(p2_in[i], p0_in[i]) < {1'b0, beta_dbg};
			aq = absdiff8(q2_in[i], q0_in[i]) < {1'b0, beta_dbg};
			strong_extra = absdiff8(p0_in[i], q0_in[i]) < {1'b0, (alpha_dbg >> 2) + 8'd2};

			if (filter_ok && bs == 3'd4) begin
				if (is_chroma) begin
					p0_out[i] = clip8((p1s <<< 1) + p0s + q1s + 14'sd2 >>> 2);
					q0_out[i] = clip8((q1s <<< 1) + q0s + p1s + 14'sd2 >>> 2);
				end else if (strong_extra) begin
					if (ap) begin
						p0_out[i] = clip8(p2s + (p1s <<< 1) + (p0s <<< 1) + (q0s <<< 1) + q1s + 14'sd4 >>> 3);
						p1_out[i] = clip8(p2s + p1s + p0s + q0s + 14'sd2 >>> 2);
						p2_out[i] = clip8((p3s <<< 1) + 3 * p2s + p1s + p0s + q0s + 14'sd4 >>> 3);
					end else begin
						p0_out[i] = clip8((p1s <<< 1) + p0s + q1s + 14'sd2 >>> 2);
					end
					if (aq) begin
						q0_out[i] = clip8(p1s + (p0s <<< 1) + (q0s <<< 1) + (q1s <<< 1) + q2s + 14'sd4 >>> 3);
						q1_out[i] = clip8(p0s + q0s + q1s + q2s + 14'sd2 >>> 2);
						q2_out[i] = clip8(p0s + q0s + q1s + 3 * q2s + (q3s <<< 1) + 14'sd4 >>> 3);
					end else begin
						q0_out[i] = clip8((q1s <<< 1) + q0s + p1s + 14'sd2 >>> 2);
					end
				end else begin
					p0_out[i] = clip8((p1s <<< 1) + p0s + q1s + 14'sd2 >>> 2);
					q0_out[i] = clip8((q1s <<< 1) + q0s + p1s + 14'sd2 >>> 2);
				end
			end else if (filter_ok) begin
				tc = is_chroma ? $signed({8'd0, tc0_dbg}) + 14'sd1 :
				     $signed({8'd0, tc0_dbg}) + (ap ? 14'sd1 : 14'sd0) + (aq ? 14'sd1 : 14'sd0);
				delta = clip_signed(-tc, tc, (((q0s - p0s) <<< 2) + (p1s - q1s) + 14'sd4) >>> 3);
				p0_out[i] = clip8(p0s + delta);
				q0_out[i] = clip8(q0s - delta);
				if (!is_chroma && ap) begin
					adj = clip_signed(-$signed({8'd0, tc0_dbg}), $signed({8'd0, tc0_dbg}),
					                  (p2s + ((p0s + q0s + 14'sd1) >>> 1) - (p1s <<< 1)) >>> 1);
					p1_out[i] = clip8(p1s + adj);
				end
				if (!is_chroma && aq) begin
					adj = clip_signed(-$signed({8'd0, tc0_dbg}), $signed({8'd0, tc0_dbg}),
					                  (q2s + ((p0s + q0s + 14'sd1) >>> 1) - (q1s <<< 1)) >>> 1);
					q1_out[i] = clip8(q1s + adj);
				end
			end
		end
	end
endmodule


// The caller supplies registered thresholds. An accepted start owns all
// samples until done: decisions/raw adjustments, clipping/strong averages,
// then final pixel updates are separate register boundaries.
module h264_deblock_samples_pipe (
	input wire clk, reset, start,
	output wire busy,
	output reg done,
	input wire is_chroma,
	input wire [2:0] bs,
	input wire [7:0] alpha, beta,
	input wire [5:0] tc0,
	input wire [7:0] p3_in [0:3], p2_in [0:3], p1_in [0:3], p0_in [0:3],
	input wire [7:0] q0_in [0:3], q1_in [0:3], q2_in [0:3], q3_in [0:3],
	output reg [7:0] p2_out [0:3], p1_out [0:3], p0_out [0:3],
	output reg [7:0] q0_out [0:3], q1_out [0:3], q2_out [0:3]
);
	localparam [1:0] IDLE=0, CLIP=1, APPLY=2;
	reg [1:0] state;
	assign busy = state != IDLE;
	reg chroma_r, strong_r;
	reg [5:0] tc0_r;
	reg [3:0] enabled_r, ap_r, aq_r, strong_p_r, strong_q_r;
	reg [6:0] tc_r [0:3];
	reg signed [8:0] delta_raw_r [0:3], adj_p_raw_r [0:3], adj_q_raw_r [0:3];
	reg signed [8:0] delta_r [0:3], adj_p_r [0:3], adj_q_r [0:3];
	reg [7:0] p3_r [0:3], p2_r [0:3], p1_r [0:3], p0_r [0:3];
	reg [7:0] q0_r [0:3], q1_r [0:3], q2_r [0:3], q3_r [0:3];
	reg [7:0] sp2_r [0:3], sp1_r [0:3], sp0_r [0:3];
	reg [7:0] sq0_r [0:3], sq1_r [0:3], sq2_r [0:3];

	function automatic [8:0] absdiff8(input [7:0] a, input [7:0] b);
		absdiff8 = a >= b ? {1'b0,a}-{1'b0,b} : {1'b0,b}-{1'b0,a};
	endfunction
	function automatic signed [8:0] bound_delta(input signed [8:0] v, input [6:0] limit);
		reg signed [8:0] bound;
		begin
			bound = $signed({2'b00,limit});
			if (v < -bound) bound_delta = -bound;
			else if (v > bound) bound_delta = bound;
			else bound_delta = v;
		end
	endfunction
	function automatic [7:0] clip8(input signed [11:0] v);
		if (v < 12'sd0) clip8=0;
		else if (v > 12'sd255) clip8=255;
		else clip8=v[7:0];
	endfunction

	wire [3:0] ap, aq, strong_extra;
	genvar lane;
	generate for (lane=0;lane<4;lane=lane+1) begin : g_decisions
		assign ap[lane] = absdiff8(p2_in[lane],p0_in[lane]) < {1'b0,beta};
		assign aq[lane] = absdiff8(q2_in[lane],q0_in[lane]) < {1'b0,beta};
		assign strong_extra[lane] =
			absdiff8(p0_in[lane],q0_in[lane]) < {1'b0,(alpha >> 2)+8'd2};
	end endgenerate

	// Raw delta is [-1271,1279] before >>3; adjustments are [-510,510]
	// before >>1. Strong positive sums including rounding are <=2044.
	reg signed [11:0] p0s,p1s,p2s,p3s,q0s,q1s,q2s,q3s;
	integer i;
	always @(posedge clk) begin
		done <= 0;
		if (reset) begin
			state <= IDLE;
			for (i=0;i<4;i=i+1) begin
				p2_out[i]<=0; p1_out[i]<=0; p0_out[i]<=0;
				q0_out[i]<=0; q1_out[i]<=0; q2_out[i]<=0;
			end
		end else case (state)
		IDLE: if (start) begin
			chroma_r<=is_chroma; strong_r<=bs==4; tc0_r<=tc0;
			for (i=0;i<4;i=i+1) begin
				p3_r[i]<=p3_in[i]; p2_r[i]<=p2_in[i]; p1_r[i]<=p1_in[i]; p0_r[i]<=p0_in[i];
				q0_r[i]<=q0_in[i]; q1_r[i]<=q1_in[i]; q2_r[i]<=q2_in[i]; q3_r[i]<=q3_in[i];
				p0s=$signed({4'd0,p0_in[i]}); p1s=$signed({4'd0,p1_in[i]});
				p2s=$signed({4'd0,p2_in[i]});
				q0s=$signed({4'd0,q0_in[i]}); q1s=$signed({4'd0,q1_in[i]});
				q2s=$signed({4'd0,q2_in[i]});
				enabled_r[i] <= bs!=0 && absdiff8(p0_in[i],q0_in[i]) < {1'b0,alpha} &&
					absdiff8(p1_in[i],p0_in[i]) < {1'b0,beta} &&
					absdiff8(q1_in[i],q0_in[i]) < {1'b0,beta};
				ap_r[i]<=ap[i]; aq_r[i]<=aq[i];
				strong_p_r[i]<=!is_chroma && strong_extra[i] && ap[i];
				strong_q_r[i]<=!is_chroma && strong_extra[i] && aq[i];
				tc_r[i] <= {1'b0,tc0} + (is_chroma ? 7'd1 :
					(ap[i] ? 7'd1 : 7'd0)+(aq[i] ? 7'd1 : 7'd0));
				delta_raw_r[i] <= 9'((((q0s-p0s) <<< 2)+(p1s-q1s)+12'sd4) >>> 3);
				adj_p_raw_r[i] <= 9'((p2s+((p0s+q0s+12'sd1) >>> 1)-(p1s <<< 1)) >>> 1);
				adj_q_raw_r[i] <= 9'((q2s+((p0s+q0s+12'sd1) >>> 1)-(q1s <<< 1)) >>> 1);
			end
			state<=CLIP;
		end
		CLIP: begin
			for (i=0;i<4;i=i+1) begin
				delta_r[i]<=bound_delta(delta_raw_r[i],tc_r[i]);
				adj_p_r[i]<=bound_delta(adj_p_raw_r[i],{1'b0,tc0_r});
				adj_q_r[i]<=bound_delta(adj_q_raw_r[i],{1'b0,tc0_r});
				p0s=$signed({4'd0,p0_r[i]}); p1s=$signed({4'd0,p1_r[i]});
				p2s=$signed({4'd0,p2_r[i]}); p3s=$signed({4'd0,p3_r[i]});
				q0s=$signed({4'd0,q0_r[i]}); q1s=$signed({4'd0,q1_r[i]});
				q2s=$signed({4'd0,q2_r[i]}); q3s=$signed({4'd0,q3_r[i]});
				sp2_r[i]<=p2_r[i]; sp1_r[i]<=p1_r[i];
				sq1_r[i]<=q1_r[i]; sq2_r[i]<=q2_r[i];
				sp0_r[i]<=8'(((p1s <<< 1)+(p0s+q1s+12'sd2)) >>> 2);
				sq0_r[i]<=8'(((q1s <<< 1)+(q0s+p1s+12'sd2)) >>> 2);
				if (strong_p_r[i]) begin
					sp0_r[i]<=8'(((p2s+q1s)+((p1s+p0s) <<< 1)+((q0s <<< 1)+12'sd4)) >>> 3);
					sp1_r[i]<=8'(((p2s+p1s)+(p0s+q0s+12'sd2)) >>> 2);
					sp2_r[i]<=8'((((p3s+p2s) <<< 1)+(p2s+p1s)+(p0s+q0s+12'sd4)) >>> 3);
				end
				if (strong_q_r[i]) begin
					sq0_r[i]<=8'(((p1s+q2s)+((q1s+q0s) <<< 1)+((p0s <<< 1)+12'sd4)) >>> 3);
					sq1_r[i]<=8'(((q2s+q1s)+(p0s+q0s+12'sd2)) >>> 2);
					sq2_r[i]<=8'((((q3s+q2s) <<< 1)+(q2s+q1s)+(p0s+q0s+12'sd4)) >>> 3);
				end
			end
			state<=APPLY;
		end
		APPLY: begin
			for (i=0;i<4;i=i+1) begin
				p2_out[i]<=p2_r[i]; p1_out[i]<=p1_r[i]; p0_out[i]<=p0_r[i];
				q0_out[i]<=q0_r[i]; q1_out[i]<=q1_r[i]; q2_out[i]<=q2_r[i];
				if (enabled_r[i] && strong_r) begin
					p2_out[i]<=sp2_r[i]; p1_out[i]<=sp1_r[i]; p0_out[i]<=sp0_r[i];
					q0_out[i]<=sq0_r[i]; q1_out[i]<=sq1_r[i]; q2_out[i]<=sq2_r[i];
				end else if (enabled_r[i]) begin
					p0_out[i]<=clip8($signed({4'd0,p0_r[i]})+12'(delta_r[i]));
					q0_out[i]<=clip8($signed({4'd0,q0_r[i]})-12'(delta_r[i]));
					if (!chroma_r && ap_r[i])
						p1_out[i]<=clip8($signed({4'd0,p1_r[i]})+12'(adj_p_r[i]));
					if (!chroma_r && aq_r[i])
						q1_out[i]<=clip8($signed({4'd0,q1_r[i]})+12'(adj_q_r[i]));
				end
			end
			done<=1; state<=IDLE;
		end
		default: state<=IDLE;
		endcase
	end
endmodule


module h264_deblock_edge_pipe (
	input  wire              clk,
	input  wire              reset,
	input  wire              valid_i,
	input  wire              is_chroma,
	input  wire [2:0]        bs,
	input  wire [5:0]        qp_avg,
	input  wire signed [4:0] slice_alpha_c0_offset,
	input  wire signed [4:0] slice_beta_offset,
	input  wire [7:0]        p3_in [0:3],
	input  wire [7:0]        p2_in [0:3],
	input  wire [7:0]        p1_in [0:3],
	input  wire [7:0]        p0_in [0:3],
	input  wire [7:0]        q0_in [0:3],
	input  wire [7:0]        q1_in [0:3],
	input  wire [7:0]        q2_in [0:3],
	input  wire [7:0]        q3_in [0:3],
	output reg               valid_o,
	output reg  [7:0]        p2_out [0:3],
	output reg  [7:0]        p1_out [0:3],
	output reg  [7:0]        p0_out [0:3],
	output reg  [7:0]        q0_out [0:3],
	output reg  [7:0]        q1_out [0:3],
	output reg  [7:0]        q2_out [0:3]
);
	reg              valid_s1;
	reg              is_chroma_r;
	reg [2:0]        bs_r;
	reg [5:0]        qp_avg_r;
	reg signed [4:0] alpha_off_r;
	reg signed [4:0] beta_off_r;
	reg [7:0]        p3_r [0:3];
	reg [7:0]        p2_r [0:3];
	reg [7:0]        p1_r [0:3];
	reg [7:0]        p0_r [0:3];
	reg [7:0]        q0_r [0:3];
	reg [7:0]        q1_r [0:3];
	reg [7:0]        q2_r [0:3];
	reg [7:0]        q3_r [0:3];

	wire [7:0] edge_p2 [0:3];
	wire [7:0] edge_p1 [0:3];
	wire [7:0] edge_p0 [0:3];
	wire [7:0] edge_q0 [0:3];
	wire [7:0] edge_q1 [0:3];
	wire [7:0] edge_q2 [0:3];
	wire [7:0] alpha_unused;
	wire [7:0] beta_unused;
	wire [5:0] tc0_unused;

	h264_deblock_edge u_edge (
		.is_chroma(is_chroma_r),
		.bs(bs_r),
		.qp_avg(qp_avg_r),
		.slice_alpha_c0_offset(alpha_off_r),
		.slice_beta_offset(beta_off_r),
		.p3_in(p3_r), .p2_in(p2_r), .p1_in(p1_r), .p0_in(p0_r),
		.q0_in(q0_r), .q1_in(q1_r), .q2_in(q2_r), .q3_in(q3_r),
		.p2_out(edge_p2), .p1_out(edge_p1), .p0_out(edge_p0),
		.q0_out(edge_q0), .q1_out(edge_q1), .q2_out(edge_q2),
		.alpha_dbg(alpha_unused), .beta_dbg(beta_unused), .tc0_dbg(tc0_unused)
	);

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			valid_s1 <= 1'b0;
			valid_o  <= 1'b0;
			is_chroma_r <= 1'b0;
			bs_r <= 3'd0;
			qp_avg_r <= 6'd0;
			alpha_off_r <= 5'sd0;
			beta_off_r <= 5'sd0;
			for (i = 0; i < 4; i = i + 1) begin
				p3_r[i] <= 8'd0; p2_r[i] <= 8'd0; p1_r[i] <= 8'd0; p0_r[i] <= 8'd0;
				q0_r[i] <= 8'd0; q1_r[i] <= 8'd0; q2_r[i] <= 8'd0; q3_r[i] <= 8'd0;
				p2_out[i] <= 8'd0; p1_out[i] <= 8'd0; p0_out[i] <= 8'd0;
				q0_out[i] <= 8'd0; q1_out[i] <= 8'd0; q2_out[i] <= 8'd0;
			end
		end else begin
			valid_s1 <= valid_i;
			valid_o <= valid_s1;
			is_chroma_r <= is_chroma;
			bs_r <= bs;
			qp_avg_r <= qp_avg;
			alpha_off_r <= slice_alpha_c0_offset;
			beta_off_r <= slice_beta_offset;
			for (i = 0; i < 4; i = i + 1) begin
				p3_r[i] <= p3_in[i]; p2_r[i] <= p2_in[i]; p1_r[i] <= p1_in[i]; p0_r[i] <= p0_in[i];
				q0_r[i] <= q0_in[i]; q1_r[i] <= q1_in[i]; q2_r[i] <= q2_in[i]; q3_r[i] <= q3_in[i];
				p2_out[i] <= edge_p2[i]; p1_out[i] <= edge_p1[i]; p0_out[i] <= edge_p0[i];
				q0_out[i] <= edge_q0[i]; q1_out[i] <= edge_q1[i]; q2_out[i] <= edge_q2[i];
			end
		end
	end
endmodule

`default_nettype wire
