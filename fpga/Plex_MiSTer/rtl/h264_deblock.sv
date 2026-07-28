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

	assign unsupported_ref = (p_ref > 2'd1) || (q_ref > 2'd1);

	always @* begin
		if (disable_all || slice_boundary_blocked) begin
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

module h264_deblock_thresholds (
	input  wire [5:0]        qp_avg,
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
	reg [7:0] p0v, p1v, p2v, p3v, q0v, q1v, q2v, q3v;

	always @* begin
		for (i = 0; i < 4; i = i + 1) begin
			p2_out[i] = p2_in[i];
			p1_out[i] = p1_in[i];
			p0_out[i] = p0_in[i];
			q0_out[i] = q0_in[i];
			q1_out[i] = q1_in[i];
			q2_out[i] = q2_in[i];

			p0v = p0_in[i]; p1v = p1_in[i]; p2v = p2_in[i]; p3v = p3_in[i];
			q0v = q0_in[i]; q1v = q1_in[i]; q2v = q2_in[i]; q3v = q3_in[i];
			p0s = {6'b000000, p0v}; p1s = {6'b000000, p1v}; p2s = {6'b000000, p2v}; p3s = {6'b000000, p3v};
			q0s = {6'b000000, q0v}; q1s = {6'b000000, q1v}; q2s = {6'b000000, q2v}; q3s = {6'b000000, q3v};
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

module h264_deblock_writeback_ctrl #(
	parameter int MB_COUNT = 1170,
	parameter int FRAME_SLOT_W = 2,
	parameter int SAMPLES_PER_MB = 384,
	parameter int MB_AW = (MB_COUNT <= 1) ? 1 : $clog2(MB_COUNT)
) (
	input  wire                   clk,
	input  wire                   reset,
	input  wire                   idr_frame_start,
	input  wire                   filtered_sample_valid,
	input  wire                   filtered_mb_valid,
	input  wire [MB_AW-1:0]       filtered_mb_addr,
	input  wire                   filtered_mb_is_ref,
	input  wire                   filtered_frame_done,
	input  wire [FRAME_SLOT_W-1:0] frame_slot_i,
	input  wire                   frame_boundary,
	output reg                    wb_valid,
	output reg  [MB_AW-1:0]       wb_mb_addr,
	output reg                    wb_is_ref,
	output reg                    dpb_invalidate_refs,
	output reg                    ref_ready_pulse,
	output reg  [FRAME_SLOT_W-1:0] ref_ready_slot,
	output reg                    commit_order_error
);
	localparam int SAMPLE_COUNT_W = $clog2(SAMPLES_PER_MB + 1);
	localparam [SAMPLE_COUNT_W-1:0] SAMPLES_PER_MB_COUNT = SAMPLES_PER_MB[SAMPLE_COUNT_W-1:0];

	reg                    ref_pending;
	reg [FRAME_SLOT_W-1:0] ref_pending_slot;
	reg [SAMPLE_COUNT_W-1:0] sample_count;
	wire samples_complete = (sample_count == SAMPLES_PER_MB_COUNT);
`ifdef H264_DEBLOCK_FAULT_MB_COMMIT_EARLY
	wire commit_now = filtered_mb_valid;
`else
	wire commit_now = filtered_mb_valid && samples_complete;
`endif

	always @(posedge clk) begin
		if (reset) begin
			wb_valid <= 1'b0;
			wb_mb_addr <= '0;
			wb_is_ref <= 1'b0;
			dpb_invalidate_refs <= 1'b0;
			ref_ready_pulse <= 1'b0;
			ref_ready_slot <= '0;
			ref_pending <= 1'b0;
			ref_pending_slot <= '0;
			sample_count <= '0;
			commit_order_error <= 1'b0;
		end else begin
			wb_valid <= commit_now;
			wb_mb_addr <= filtered_mb_addr;
			wb_is_ref <= filtered_mb_is_ref;
			dpb_invalidate_refs <= idr_frame_start;
			commit_order_error <= filtered_mb_valid && !samples_complete;
`ifdef H264_DEBLOCK_FAULT_REF_READY_EARLY
			ref_ready_pulse <= filtered_mb_valid && filtered_frame_done && filtered_mb_is_ref;
			ref_ready_slot <= frame_slot_i;
`else
			ref_ready_pulse <= frame_boundary && ref_pending;
			ref_ready_slot <= ref_pending_slot;
`endif
			if (idr_frame_start)
				ref_pending <= 1'b0;
			if (commit_now && filtered_frame_done && filtered_mb_is_ref) begin
				ref_pending <= 1'b1;
				ref_pending_slot <= frame_slot_i;
			end
			if (frame_boundary && ref_pending)
				ref_pending <= 1'b0;
			if (idr_frame_start || commit_now || frame_boundary) begin
				sample_count <= '0;
			end else if (filtered_sample_valid && !samples_complete) begin
				sample_count <= sample_count + 1'b1;
			end
		end
	end
endmodule

// ════════════════════════════════════════════════════════════════════════
// Chroma QP mapping (Table 8-15).  Deblocking of chroma edges uses QPc,
// derived from QPy and pps_chroma_qp_index_offset.  Below qPI 30 the tables
// agree, so a gate that only exercises low QP cannot tell QPy from QPc.
// ════════════════════════════════════════════════════════════════════════
module h264_deblock_qpc (
	input  wire [5:0]        qp_y,
	input  wire signed [4:0] chroma_qp_index_offset,
	output wire [5:0]        qp_c
);
	wire signed [7:0] qpi_raw = $signed({2'b00, qp_y}) +
	                            {{3{chroma_qp_index_offset[4]}}, chroma_qp_index_offset};
	wire [5:0] qpi = (qpi_raw < 8'sd0)  ? 6'd0  :
	                 (qpi_raw > 8'sd51) ? 6'd51 : qpi_raw[5:0];

	function automatic [5:0] qpc_map;
		input [5:0] idx;
		begin
			case (idx)
			6'd30: qpc_map = 6'd29; 6'd31: qpc_map = 6'd30; 6'd32: qpc_map = 6'd31;
			6'd33: qpc_map = 6'd32; 6'd34: qpc_map = 6'd32; 6'd35: qpc_map = 6'd33;
			6'd36: qpc_map = 6'd34; 6'd37: qpc_map = 6'd34; 6'd38: qpc_map = 6'd35;
			6'd39: qpc_map = 6'd35; 6'd40: qpc_map = 6'd36; 6'd41: qpc_map = 6'd36;
			6'd42: qpc_map = 6'd37; 6'd43: qpc_map = 6'd37; 6'd44: qpc_map = 6'd37;
			6'd45: qpc_map = 6'd38; 6'd46: qpc_map = 6'd38; 6'd47: qpc_map = 6'd38;
			6'd48: qpc_map = 6'd39; 6'd49: qpc_map = 6'd39; 6'd50: qpc_map = 6'd39;
			6'd51: qpc_map = 6'd39;
			default: qpc_map = idx;
			endcase
		end
	endfunction

	assign qp_c = qpc_map(qpi);
endmodule

// ════════════════════════════════════════════════════════════════════════
// Macroblock in-loop deblocking filter (clause 8.7).
//
// This is the scheduler that was missing from the product decode lineage:
// h264_deblock_bs / h264_deblock_edge_pipe are per-edge-segment primitives
// and cannot filter a macroblock on their own.  This module walks one MB's
// edges in normative order and drives those primitives.
//
// Sample interface is a macroblock *neighbourhood*: the current MB plus the
// four sample columns of the left MB and the four sample rows of the top MB,
// because filtering an MB edge normatively rewrites p2/p1/p0 on the
// neighbour side.  The caller supplies the neighbourhood and writes back the
// filtered neighbourhood; the current-MB region is the POST-deblock MB.
//
//   luma   : 20x20, index = row*20 + col, row/col 0..3 are the neighbour
//            skirt, so sample (x,y) of the current MB is at (y+4)*20 + x + 4
//   chroma : 12x12, index = row*12 + col, same skirt convention
//
// Edge order per 8.7.1: all vertical edges left-to-right, then all
// horizontal edges top-to-bottom.  Luma edges are walked in 4-sample
// segments; chroma edges are walked in 2-sample half-segments because a
// 4:2:0 chroma segment straddles two co-located luma 4x4 blocks and bS is
// derived from luma.
// ════════════════════════════════════════════════════════════════════════
module h264_deblock_mb_filter (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	output reg         busy,
	output reg         done,

	// ── slice/PPS filter configuration ──
	input  wire [1:0]        disable_deblocking_filter_idc,
	input  wire signed [4:0] slice_alpha_c0_offset,
	input  wire signed [4:0] slice_beta_offset,
	input  wire signed [4:0] chroma_qp_index_offset,
	input  wire              left_mb_avail,
	input  wire              top_mb_avail,
	input  wire              left_mb_other_slice,
	input  wire              top_mb_other_slice,

	// ── current MB coding context ──
	input  wire         cur_intra,
	input  wire [5:0]   cur_qp_y,
	input  wire [15:0]  cur_nz,     // per 4x4 luma block, raster blky*4+blkx
	input  wire [191:0] cur_mvx,    // 16 x signed 12-bit, quarter-pel
	input  wire [191:0] cur_mvy,
	input  wire [31:0]  cur_ref,    // 16 x 2-bit ref_idx_l0

	// ── left neighbour MB coding context ──
	input  wire         left_intra,
	input  wire [5:0]   left_qp_y,
	input  wire [15:0]  left_nz,
	input  wire [191:0] left_mvx,
	input  wire [191:0] left_mvy,
	input  wire [31:0]  left_ref,

	// ── top neighbour MB coding context ──
	input  wire         top_intra,
	input  wire [5:0]   top_qp_y,
	input  wire [15:0]  top_nz,
	input  wire [191:0] top_mvx,
	input  wire [191:0] top_mvy,
	input  wire [31:0]  top_ref,

	// ── sample neighbourhood ──
	input  wire [7:0] nb_y_i [0:399],
	input  wire [7:0] nb_u_i [0:143],
	input  wire [7:0] nb_v_i [0:143],
	output wire [7:0] nb_y_o [0:399],
	output wire [7:0] nb_u_o [0:143],
	output wire [7:0] nb_v_o [0:143],

	// ── observability (non-vacuity evidence) ──
	output reg [15:0] luma_modified_samples,
	output reg [15:0] chroma_modified_samples,
	output reg [15:0] edge_segments_filtered,
	output reg [15:0] bs4_segments,
	output reg [5:0]  last_chroma_qp_avg,
	output reg        filter_pipe_error,
	output wire       unsupported_ref
);
	localparam int LUMA_DIM   = 20;
	localparam int CHROMA_DIM = 12;
	localparam int LUMA_N     = LUMA_DIM * LUMA_DIM;
	localparam int CHROMA_N   = CHROMA_DIM * CHROMA_DIM;

	localparam [1:0] ST_IDLE  = 2'd0;
	localparam [1:0] ST_ISSUE = 2'd1;
	localparam [1:0] ST_WAIT  = 2'd2;
	localparam [1:0] ST_CAP   = 2'd3;

	reg [1:0] state;
	reg [5:0] step;

	reg [7:0] buf_y [0:LUMA_N-1];
	reg [7:0] buf_u [0:CHROMA_N-1];
	reg [7:0] buf_v [0:CHROMA_N-1];

	genvar gi;
	generate
		for (gi = 0; gi < LUMA_N; gi = gi + 1) begin : gen_y_out
			assign nb_y_o[gi] = buf_y[gi];
		end
		for (gi = 0; gi < CHROMA_N; gi = gi + 1) begin : gen_c_out
			assign nb_u_o[gi] = buf_u[gi];
			assign nb_v_o[gi] = buf_v[gi];
		end
	endgenerate

	// ── step decode ──
	// eff_step exists so red-check builds can permute the normative edge
	// schedule without disturbing the counter that sequences the pipe.
`ifdef H264_DEBLOCK_MB_FAULT_HORIZ_FIRST
	wire [5:0] eff_step = step[5] ? {step[5:4], ~step[3], step[2:0]}
	                              : {step[5], ~step[4], step[3:0]};
`else
	wire [5:0] eff_step = step;
`endif
	wire       st_chroma  = eff_step[5];
	wire       st_is_v    = eff_step[4];          // chroma: U=0, V=1
	wire       horiz      = st_chroma ? eff_step[3] : eff_step[4];
	wire [1:0] luma_e     = eff_step[3:2];
	wire [1:0] luma_s     = eff_step[1:0];
	wire       chroma_e   = eff_step[2];
	wire [1:0] chroma_h   = eff_step[1:0];

	wire [1:0] edge_blk   = st_chroma ? (chroma_e ? 2'd2 : 2'd0) : luma_e;
	wire [1:0] along_blk  = st_chroma ? chroma_h : luma_s;

	wire [1:0] q_blkx = horiz ? along_blk : edge_blk;
	wire [1:0] q_blky = horiz ? edge_blk  : along_blk;
	wire       mb_boundary = (edge_blk == 2'd0);
	wire [1:0] p_blkx = horiz ? along_blk : (mb_boundary ? 2'd3 : (edge_blk - 2'd1));
	wire [1:0] p_blky = horiz ? (mb_boundary ? 2'd3 : (edge_blk - 2'd1)) : along_blk;

	wire [3:0] q_blk = {q_blky, q_blkx};
	wire [3:0] p_blk = {p_blky, p_blkx};

	wire use_left = mb_boundary && !horiz;
	wire use_top  = mb_boundary &&  horiz;

	wire         p_intra = use_left ? left_intra : use_top ? top_intra : cur_intra;
	wire [15:0]  p_nz_v  = use_left ? left_nz    : use_top ? top_nz    : cur_nz;
	wire [191:0] p_mvx_v = use_left ? left_mvx   : use_top ? top_mvx   : cur_mvx;
	wire [191:0] p_mvy_v = use_left ? left_mvy   : use_top ? top_mvy   : cur_mvy;
	wire [31:0]  p_ref_v = use_left ? left_ref   : use_top ? top_ref   : cur_ref;
	wire [5:0]   p_qp_y  = use_left ? left_qp_y  : use_top ? top_qp_y  : cur_qp_y;

	wire signed [11:0] p_mvx_sel = p_mvx_v[p_blk * 12 +: 12];
	wire signed [11:0] p_mvy_sel = p_mvy_v[p_blk * 12 +: 12];
	wire signed [11:0] q_mvx_sel = cur_mvx[q_blk * 12 +: 12];
	wire signed [11:0] q_mvy_sel = cur_mvy[q_blk * 12 +: 12];
	wire [1:0] p_ref_sel = p_ref_v[p_blk * 2 +: 2];
	wire [1:0] q_ref_sel = cur_ref[q_blk * 2 +: 2];
	wire p_nz_sel = p_nz_v[p_blk];
	wire q_nz_sel = cur_nz[q_blk];

	wire edge_unavailable = (use_left && !left_mb_avail) || (use_top && !top_mb_avail);
`ifdef H264_DEBLOCK_MB_FAULT_DROP_CHROMA
	wire fault_edge_off = st_chroma;
`elsif H264_DEBLOCK_MB_FAULT_MB_EDGE_ONLY
	wire fault_edge_off = !mb_boundary;
`else
	wire fault_edge_off = 1'b0;
`endif
	wire edge_disable_all = (disable_deblocking_filter_idc == 2'd1) || edge_unavailable ||
	                        fault_edge_off;
	wire edge_slice_blocked = (disable_deblocking_filter_idc == 2'd2) &&
	                          ((use_left && left_mb_other_slice) || (use_top && top_mb_other_slice));

	wire [2:0] step_bs;
	h264_deblock_bs u_step_bs (
		.disable_all(edge_disable_all),
		.slice_boundary_blocked(edge_slice_blocked),
		.mb_boundary(mb_boundary),
		.p_intra(p_intra),
		.q_intra(cur_intra),
		.p_nonzero(p_nz_sel),
		.q_nonzero(q_nz_sel),
		.p_ref(p_ref_sel),
		.q_ref(q_ref_sel),
		.p_mvx(p_mvx_sel),
		.p_mvy(p_mvy_sel),
		.q_mvx(q_mvx_sel),
		.q_mvy(q_mvy_sel),
		.bs(step_bs),
		.unsupported_ref(unsupported_ref)
	);

	wire [5:0] p_qp_c;
	wire [5:0] q_qp_c;
	h264_deblock_qpc u_qpc_p (
		.qp_y(p_qp_y),
		.chroma_qp_index_offset(chroma_qp_index_offset),
		.qp_c(p_qp_c)
	);
	h264_deblock_qpc u_qpc_q (
		.qp_y(cur_qp_y),
		.chroma_qp_index_offset(chroma_qp_index_offset),
		.qp_c(q_qp_c)
	);
	wire [6:0] qp_sum_y = {1'b0, p_qp_y} + {1'b0, cur_qp_y} + 7'd1;
	wire [6:0] qp_sum_c = {1'b0, p_qp_c} + {1'b0, q_qp_c}   + 7'd1;
`ifdef H264_DEBLOCK_MB_FAULT_QPY_FOR_QPC
	wire [5:0] step_qp_avg = qp_sum_y[6:1];
`else
	wire [5:0] step_qp_avg = st_chroma ? qp_sum_c[6:1] : qp_sum_y[6:1];
`endif

	// ── neighbourhood addressing for the current step ──
	// flat index of tap t, lane i = base + i*lane_stride + t*tap_stride
	wire [31:0] chroma_edge_off = chroma_e ? 32'd4 : 32'd0;
	wire [31:0] luma_s32   = {30'd0, luma_s};
	wire [31:0] luma_e32   = {30'd0, luma_e};
	wire [31:0] chroma_h32 = {30'd0, chroma_h};
	wire [31:0] luma_base_v = (32'd4 + 32'd4 * luma_s32) * LUMA_DIM + 32'd4 * luma_e32;
	wire [31:0] luma_base_h = (32'd4 * luma_e32) * LUMA_DIM + 32'd4 + 32'd4 * luma_s32;
	wire [31:0] chr_base_v  = (32'd4 + 32'd2 * chroma_h32) * CHROMA_DIM + chroma_edge_off;
	wire [31:0] chr_base_h  = chroma_edge_off * CHROMA_DIM + 32'd4 + 32'd2 * chroma_h32;

	wire [31:0] step_base = st_chroma ? (horiz ? chr_base_h : chr_base_v)
	                                  : (horiz ? luma_base_h : luma_base_v);
	wire [31:0] step_lane_stride = st_chroma ? (horiz ? 32'd1 : 32'd12)
	                                         : (horiz ? 32'd1 : 32'd20);
	wire [31:0] step_tap_stride  = st_chroma ? (horiz ? 32'd12 : 32'd1)
	                                         : (horiz ? 32'd20 : 32'd1);
	wire [31:0] step_lanes = st_chroma ? 32'd2 : 32'd4;

	// ── tap fetch ──
	reg [7:0] tap_p3 [0:3];
	reg [7:0] tap_p2 [0:3];
	reg [7:0] tap_p1 [0:3];
	reg [7:0] tap_p0 [0:3];
	reg [7:0] tap_q0 [0:3];
	reg [7:0] tap_q1 [0:3];
	reg [7:0] tap_q2 [0:3];
	reg [7:0] tap_q3 [0:3];

	integer li;
	integer lane_idx;
	always @* begin
		for (li = 0; li < 4; li = li + 1) begin
			lane_idx = step_base + li * step_lane_stride;
			if (st_chroma && li >= 2) lane_idx = step_base;
			if (!st_chroma) begin
				tap_p3[li] = buf_y[lane_idx + 0 * step_tap_stride];
				tap_p2[li] = buf_y[lane_idx + 1 * step_tap_stride];
				tap_p1[li] = buf_y[lane_idx + 2 * step_tap_stride];
				tap_p0[li] = buf_y[lane_idx + 3 * step_tap_stride];
				tap_q0[li] = buf_y[lane_idx + 4 * step_tap_stride];
				tap_q1[li] = buf_y[lane_idx + 5 * step_tap_stride];
				tap_q2[li] = buf_y[lane_idx + 6 * step_tap_stride];
				tap_q3[li] = buf_y[lane_idx + 7 * step_tap_stride];
			end else if (!st_is_v) begin
				tap_p3[li] = buf_u[lane_idx + 0 * step_tap_stride];
				tap_p2[li] = buf_u[lane_idx + 1 * step_tap_stride];
				tap_p1[li] = buf_u[lane_idx + 2 * step_tap_stride];
				tap_p0[li] = buf_u[lane_idx + 3 * step_tap_stride];
				tap_q0[li] = buf_u[lane_idx + 4 * step_tap_stride];
				tap_q1[li] = buf_u[lane_idx + 5 * step_tap_stride];
				tap_q2[li] = buf_u[lane_idx + 6 * step_tap_stride];
				tap_q3[li] = buf_u[lane_idx + 7 * step_tap_stride];
			end else begin
				tap_p3[li] = buf_v[lane_idx + 0 * step_tap_stride];
				tap_p2[li] = buf_v[lane_idx + 1 * step_tap_stride];
				tap_p1[li] = buf_v[lane_idx + 2 * step_tap_stride];
				tap_p0[li] = buf_v[lane_idx + 3 * step_tap_stride];
				tap_q0[li] = buf_v[lane_idx + 4 * step_tap_stride];
				tap_q1[li] = buf_v[lane_idx + 5 * step_tap_stride];
				tap_q2[li] = buf_v[lane_idx + 6 * step_tap_stride];
				tap_q3[li] = buf_v[lane_idx + 7 * step_tap_stride];
			end
		end
	end

	wire       pipe_valid_o;
	wire [7:0] pipe_p2 [0:3];
	wire [7:0] pipe_p1 [0:3];
	wire [7:0] pipe_p0 [0:3];
	wire [7:0] pipe_q0 [0:3];
	wire [7:0] pipe_q1 [0:3];
	wire [7:0] pipe_q2 [0:3];

	h264_deblock_edge_pipe u_mb_edge_pipe (
		.clk(clk),
		.reset(reset),
		.valid_i(state == ST_ISSUE),
		.is_chroma(st_chroma),
		.bs(step_bs),
		.qp_avg(step_qp_avg),
		.slice_alpha_c0_offset(slice_alpha_c0_offset),
		.slice_beta_offset(slice_beta_offset),
		.p3_in(tap_p3), .p2_in(tap_p2), .p1_in(tap_p1), .p0_in(tap_p0),
		.q0_in(tap_q0), .q1_in(tap_q1), .q2_in(tap_q2), .q3_in(tap_q3),
		.valid_o(pipe_valid_o),
		.p2_out(pipe_p2), .p1_out(pipe_p1), .p0_out(pipe_p0),
		.q0_out(pipe_q0), .q1_out(pipe_q1), .q2_out(pipe_q2)
	);

	// The pipe latches its inputs one cycle after valid_i, so the taps that
	// were presented during ST_ISSUE must be held stable until capture.  The
	// step counter therefore only advances in ST_CAP.
	integer i;
	integer idx;
	integer wlane;
	reg [15:0] luma_mod_acc;
	reg [15:0] chroma_mod_acc;

	always @(posedge clk) begin
		if (reset) begin
			state <= ST_IDLE;
			step <= 6'd0;
			busy <= 1'b0;
			done <= 1'b0;
			filter_pipe_error <= 1'b0;
			luma_modified_samples <= 16'd0;
			chroma_modified_samples <= 16'd0;
			edge_segments_filtered <= 16'd0;
			bs4_segments <= 16'd0;
			last_chroma_qp_avg <= 6'd0;
			for (i = 0; i < LUMA_N; i = i + 1) buf_y[i] <= 8'd0;
			for (i = 0; i < CHROMA_N; i = i + 1) begin
				buf_u[i] <= 8'd0;
				buf_v[i] <= 8'd0;
			end
		end else begin
			done <= 1'b0;
			case (state)
			ST_IDLE: begin
				busy <= 1'b0;
				if (start) begin
					for (i = 0; i < LUMA_N; i = i + 1) buf_y[i] <= nb_y_i[i];
					for (i = 0; i < CHROMA_N; i = i + 1) begin
						buf_u[i] <= nb_u_i[i];
						buf_v[i] <= nb_v_i[i];
					end
					step <= 6'd0;
					busy <= 1'b1;
					luma_modified_samples <= 16'd0;
					chroma_modified_samples <= 16'd0;
					edge_segments_filtered <= 16'd0;
					bs4_segments <= 16'd0;
					state <= ST_ISSUE;
				end
			end
			ST_ISSUE: begin
				state <= ST_WAIT;
			end
			ST_WAIT: begin
				state <= ST_CAP;
			end
			ST_CAP: begin
				if (!pipe_valid_o) begin
					filter_pipe_error <= 1'b1;
				end
				if (step_bs != 3'd0) begin
					edge_segments_filtered <= edge_segments_filtered + 16'd1;
					if (step_bs == 3'd4) bs4_segments <= bs4_segments + 16'd1;
				end
				if (st_chroma) last_chroma_qp_avg <= step_qp_avg;
				luma_mod_acc = luma_modified_samples;
				chroma_mod_acc = chroma_modified_samples;
				for (wlane = 0; wlane < 4; wlane = wlane + 1) begin
					if (wlane < $signed(step_lanes)) begin
						idx = step_base + wlane * step_lane_stride;
						if (!st_chroma) begin
							if (buf_y[idx + 1 * step_tap_stride] != pipe_p2[wlane]) luma_mod_acc = luma_mod_acc + 16'd1;
							if (buf_y[idx + 2 * step_tap_stride] != pipe_p1[wlane]) luma_mod_acc = luma_mod_acc + 16'd1;
							if (buf_y[idx + 3 * step_tap_stride] != pipe_p0[wlane]) luma_mod_acc = luma_mod_acc + 16'd1;
							if (buf_y[idx + 4 * step_tap_stride] != pipe_q0[wlane]) luma_mod_acc = luma_mod_acc + 16'd1;
							if (buf_y[idx + 5 * step_tap_stride] != pipe_q1[wlane]) luma_mod_acc = luma_mod_acc + 16'd1;
							if (buf_y[idx + 6 * step_tap_stride] != pipe_q2[wlane]) luma_mod_acc = luma_mod_acc + 16'd1;
							buf_y[idx + 1 * step_tap_stride] <= pipe_p2[wlane];
							buf_y[idx + 2 * step_tap_stride] <= pipe_p1[wlane];
							buf_y[idx + 3 * step_tap_stride] <= pipe_p0[wlane];
							buf_y[idx + 4 * step_tap_stride] <= pipe_q0[wlane];
							buf_y[idx + 5 * step_tap_stride] <= pipe_q1[wlane];
							buf_y[idx + 6 * step_tap_stride] <= pipe_q2[wlane];
						end else if (!st_is_v) begin
							if (buf_u[idx + 3 * step_tap_stride] != pipe_p0[wlane]) chroma_mod_acc = chroma_mod_acc + 16'd1;
							if (buf_u[idx + 4 * step_tap_stride] != pipe_q0[wlane]) chroma_mod_acc = chroma_mod_acc + 16'd1;
							buf_u[idx + 3 * step_tap_stride] <= pipe_p0[wlane];
							buf_u[idx + 4 * step_tap_stride] <= pipe_q0[wlane];
						end else begin
							if (buf_v[idx + 3 * step_tap_stride] != pipe_p0[wlane]) chroma_mod_acc = chroma_mod_acc + 16'd1;
							if (buf_v[idx + 4 * step_tap_stride] != pipe_q0[wlane]) chroma_mod_acc = chroma_mod_acc + 16'd1;
							buf_v[idx + 3 * step_tap_stride] <= pipe_p0[wlane];
							buf_v[idx + 4 * step_tap_stride] <= pipe_q0[wlane];
						end
					end
				end
				luma_modified_samples <= luma_mod_acc;
				chroma_modified_samples <= chroma_mod_acc;
				if (step == 6'd63) begin
					done <= 1'b1;
					busy <= 1'b0;
					state <= ST_IDLE;
				end else begin
					step <= step + 6'd1;
					state <= ST_ISSUE;
				end
			end
			default: state <= ST_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
