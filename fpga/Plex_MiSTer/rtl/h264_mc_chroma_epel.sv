// Resource-shared eighth-sample chroma interpolator (ITU-T H.264 8.4.2.2.2).
//
// In 4:2:0 a chroma sample spans two luma samples, so a motion vector in
// quarter-luma-sample units is already in eighth-chroma-sample units: the
// fractional parts are mvx & 7 and mvy & 7 and the integer chroma offset is
// mvx >>> 3 / mvy >>> 3.  Both are produced by the DPB fetch, which also
// edge-clamps every tap, so a vector pointing outside the picture replicates
// the border sample rather than reading garbage.
//
//   predC = ((8-xFrac)(8-yFrac)A + xFrac(8-yFrac)B
//          + (8-xFrac)yFrac C + xFrac*yFrac*D + 32) >> 6
//
// AREA
//   The previous revision took the two 9x9 windows in as `input [7:0]
//   ref_u [0:80]` port arrays and indexed them at runtime from four lanes, so
//   every lane cost eight 81:1 byte multiplexers on top of its arithmetic.
//   Here the windows live in RAM and the bilinear is factored into two
//   separable passes that each read ONE sample per cycle:
//
//     pass H:  t[r][x] = (8-xF)*W[r][x] + xF*W[r][x+1]        r=0..8, x=0..7
//     pass V:  p[y][x] = ((8-yF)*t[y][x] + yF*t[y+1][x] + 32) >> 6
//
//   which is algebraically identical to the four-term product form, and there
//   is no intermediate rounding: t is kept at full precision (0..2040, 12
//   bits) and the single +32 >> 6 happens once, in the vertical pass.
//
//   A 2-deep shift register slides along each walk so the second operand is
//   always the previous cycle's sample -- one memory read per output.  The
//   weight multiplies are 8x3 and are written as shift-adds so they cannot
//   infer DSP blocks; the fit was at 130% DSP.
//
// SCHEDULE
//   pass H  9*9 + 2 = 83 cycles, skipped when xFrac == 0 and yFrac == 0
//   pass V  8*9 + 2 = 74 cycles
//   combine 64 + 1  = 65 cycles
//   worst case 222, full-pel 66.
//
// The samples read here are POST-deblocking reference samples out of the DPB.
// Intra prediction neighbour taps are a separate, PRE-deblocking path and
// never enter this module.

`default_nettype none

module h264_mc_chroma_epel (
	input  wire        clk,
	input  wire        reset,

	// 9x9 window streaming write port, index = row*9 + col, one write port
	// shared by both planes because the DPB fetch delivers U and V on
	// separate valid strobes with a common index.
	input  wire        win_u_wr,
	input  wire        win_v_wr,
	input  wire [6:0]  win_addr,
	input  wire [7:0]  win_data,

	input  wire        start,
	input  wire [2:0]  frac_x,
	input  wire [2:0]  frac_y,

	output reg         busy,
	output reg         done,

	// Prediction read port: 8x8 samples per plane, index = y*8 + x.
	input  wire [5:0]  pred_rd_idx,
	output wire [7:0]  pred_u_rd_data,
	output wire [7:0]  pred_v_rd_data
);
	localparam [2:0] S_IDLE = 3'd0;
	localparam [2:0] S_H    = 3'd1;
	localparam [2:0] S_V    = 3'd2;
	localparam [2:0] S_C    = 3'd3;
	localparam [2:0] S_DONE = 3'd4;

	reg [2:0] state;
	wire state_is_v = (state == S_V);

	// ------------------------------------------------------------------
	// Storage
	// ------------------------------------------------------------------
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0]  uwin [0:127];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0]  vwin [0:127];
	reg [7:0] uwq, vwq;

	// Horizontally interpolated plane at full precision, 9 rows x 8 columns.
	(* ramstyle = "M10K, no_rw_check" *) reg [11:0] utmp [0:127];
	(* ramstyle = "M10K, no_rw_check" *) reg [11:0] vtmp [0:127];
	reg [11:0] utq, vtq;

	(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] upred [0:63];
	(* ramstyle = "MLAB, no_rw_check" *) reg [7:0] vpred [0:63];
	assign pred_u_rd_data = upred[pred_rd_idx];
	assign pred_v_rd_data = vpred[pred_rd_idx];

	// ------------------------------------------------------------------
	// Weighted sum datapath, shared by both passes and both planes.
	//   out = a*(8-f) + b*f   with f in 0..7
	// Written as a shift-add over the three bits of f so no DSP is inferred.
	// ------------------------------------------------------------------
	reg [2:0] fx_r, fy_r;
	wire [2:0] fsel = (state_is_v) ? fy_r : fx_r;
	wire [3:0] fbar = 4'd8 - {1'b0, fsel};

	function automatic [15:0] wmul(input [11:0] v, input [3:0] w);
		begin
			wmul = ({4'd0, v} & {16{w[0]}})
			     + (({4'd0, v} << 1) & {16{w[1]}})
			     + (({4'd0, v} << 2) & {16{w[2]}})
			     + (({4'd0, v} << 3) & {16{w[3]}});
		end
	endfunction

	// ------------------------------------------------------------------
	// Control
	// ------------------------------------------------------------------
	reg [3:0] ao, ai;
	reg [5:0] ccnt;
	reg       a_run;

	// 2-deep sliding operand pair.  sa is the older sample (A or C), sb the
	// newer one (B or D).
	reg [11:0] u_sa, u_sb, v_sa, v_sb;

	wire [15:0] u_mix = wmul(u_sa, fbar) + wmul(u_sb, {1'b0, fsel});
	wire [15:0] v_mix = wmul(v_sa, fbar) + wmul(v_sb, {1'b0, fsel});

	// ------------------------------------------------------------------
	// Addressing
	//   S_H: ao = window row 0..8, ai = window column 0..8
	//   S_V: ao = output column 0..7, ai = window row 0..8
	//   S_C: ccnt = y*8 + x
	// ------------------------------------------------------------------
	// Row stride is a constant multiply by 9, written as a shift-add so no
	// DSP block can be inferred for address generation.
	function automatic [6:0] m9(input [3:0] r);
		begin
			m9 = 7'((7'(r) << 3) + 7'(r));
		end
	endfunction

	wire [2:0] cy = ccnt[5:3];
	wire [2:0] cx = ccnt[2:0];

	// With both fractions zero the block is a straight window copy, so the
	// combine pass reads the integer sample directly out of the window.
	wire [6:0] win_ra = (state == S_H) ? 7'(m9(ao) + 7'(ai))
	                                   : 7'(m9({1'b0, cy}) + 7'(cx));
	wire [6:0] tmp_ra = (state == S_V) ? 7'((7'(ai) << 3) + 7'(ao))
	                                   : 7'((7'(cy) << 3) + 7'(cx));

	// ------------------------------------------------------------------
	// Pipeline: p1 describes the sample on uwq/vwq/utq/vtq this cycle,
	// p2 describes the mix standing on u_mix/v_mix this cycle.
	// ------------------------------------------------------------------
	reg       p1_v, p2_v;
	reg [3:0] p1_o, p1_i, p2_o, p2_i;
	reg       c1_v;
	reg [5:0] c1_idx;
	reg       full_r;

	// Horizontal pass writes t[row p2_o][column p2_i - 1].
	wire       h_we = (state == S_H) && p2_v;
	wire [6:0] h_wa = 7'((7'(p2_o) << 3) + 7'(p2_i) - 7'd1);

	// Vertical pass retires output row p2_i - 1, column p2_o.
	wire       v_we = (state == S_V) && p2_v;
	wire [5:0] v_wa = 6'((6'(p2_i - 4'd1) << 3) + 6'(p2_o));
	wire [7:0] v_wdu = 8'((u_mix + 16'd32) >> 6);
	wire [7:0] v_wdv = 8'((v_mix + 16'd32) >> 6);

	// ------------------------------------------------------------------
	// Memories
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (win_u_wr) uwin[win_addr] <= win_data;
		uwq <= uwin[win_ra];
	end
	always @(posedge clk) begin
		if (win_v_wr) vwin[win_addr] <= win_data;
		vwq <= vwin[win_ra];
	end

	always @(posedge clk) begin
		if (h_we) utmp[h_wa] <= u_mix[11:0];
		utq <= utmp[tmp_ra];
	end
	always @(posedge clk) begin
		if (h_we) vtmp[h_wa] <= v_mix[11:0];
		vtq <= vtmp[tmp_ra];
	end

	always @(posedge clk) begin
		if (v_we)      upred[v_wa]  <= v_wdu;
		else if (c1_v) upred[c1_idx] <= uwq;
	end
	always @(posedge clk) begin
		if (v_we)      vpred[v_wa]  <= v_wdv;
		else if (c1_v) vpred[c1_idx] <= vwq;
	end

	// ------------------------------------------------------------------
	// Sequencer
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (reset) begin
			state  <= S_IDLE;
			busy   <= 1'b0;
			done   <= 1'b0;
			a_run  <= 1'b0;
			p1_v   <= 1'b0;
			p2_v   <= 1'b0;
			c1_v   <= 1'b0;
			ao     <= 4'd0;
			ai     <= 4'd0;
			ccnt   <= 6'd0;
			fx_r   <= 3'd0;
			fy_r   <= 3'd0;
			full_r <= 1'b0;
			u_sa   <= 12'd0; u_sb <= 12'd0;
			v_sa   <= 12'd0; v_sb <= 12'd0;
		end else begin
			done <= 1'b0;
			p1_v <= 1'b0;
			p2_v <= p1_v;
			p2_o <= p1_o;
			p2_i <= p1_i;
			c1_v <= 1'b0;

			// One new sample per cycle; the operand it pairs with is the one
			// delivered on the previous cycle.  The first sample of a row or
			// column only primes the pair, which is why emission starts at
			// inner index 1.
			if (p1_v) begin
				u_sa <= u_sb;
				v_sa <= v_sb;
				if (state == S_V) begin
					u_sb <= utq;
					v_sb <= vtq;
				end else begin
					u_sb <= {4'd0, uwq};
					v_sb <= {4'd0, vwq};
				end
			end

			case (state)
			S_IDLE: begin
				if (start) begin
					fx_r   <= frac_x;
					fy_r   <= frac_y;
					full_r <= (frac_x == 3'd0) && (frac_y == 3'd0);
					busy   <= 1'b1;
					ao     <= 4'd0;
					ai     <= 4'd0;
					ccnt   <= 6'd0;
					a_run  <= 1'b1;
					state  <= ((frac_x == 3'd0) && (frac_y == 3'd0)) ? S_C : S_H;
				end
			end

			S_H: begin
				if (a_run) begin
					p1_v <= 1'b1;
					p1_o <= ao;
					p1_i <= ai;
					if (ai == 4'd8) begin
						ai <= 4'd0;
						if (ao == 4'd8) a_run <= 1'b0;
						else            ao    <= ao + 4'd1;
					end else begin
						ai <= ai + 4'd1;
					end
				end
				if (p1_v && p1_i == 4'd0) p2_v <= 1'b0;
				if (!a_run && !p1_v && !p2_v) begin
					ao    <= 4'd0;
					ai    <= 4'd0;
					a_run <= 1'b1;
					state <= S_V;
				end
			end

			S_V: begin
				if (a_run) begin
					p1_v <= 1'b1;
					p1_o <= ao;
					p1_i <= ai;
					if (ai == 4'd8) begin
						ai <= 4'd0;
						if (ao == 4'd7) a_run <= 1'b0;
						else            ao    <= ao + 4'd1;
					end else begin
						ai <= ai + 4'd1;
					end
				end
				if (p1_v && p1_i == 4'd0) p2_v <= 1'b0;
				if (!a_run && !p1_v && !p2_v) state <= S_DONE;
			end

			// Only reached for integer motion, where prediction is a copy of
			// the window's integer samples.
			S_C: begin
				if (a_run) begin
					c1_idx <= ccnt;
					c1_v   <= 1'b1;
					if (ccnt == 6'd63) a_run <= 1'b0;
					else               ccnt  <= ccnt + 6'd1;
				end
				if (!a_run && !c1_v) state <= S_DONE;
			end

			S_DONE: begin
				busy  <= 1'b0;
				done  <= 1'b1;
				state <= S_IDLE;
			end

			default: state <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
