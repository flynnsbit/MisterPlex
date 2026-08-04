// present_content_window — NN content→DE store address map (fabric scaler V1).
//
// Purpose: evacuate ARM swscale/pad. Maps DE beam (hc, py) → store read coords.
//   win_enable=0 → legacy full-bank FRAME_W×FRAME_H (bit-compatible 480p path)
//   win_enable=1 → stretch content_w×content_h at (content_x0,content_y0) across DE
//
// TIMING (720p clk_pix ~29.7 MHz) — ranked pixel-path combo (see pipe report):
//   #1 Scale 32b/11b divide into sx_r/sy_r — multi-cycle iterative, mailbox rate
//   #2 X: hc(11)*sx(20) → Q16 → +x0 → clamp last_x   (ce_pix)
//   #3 Y: py clamp → *sy → +y0 → clamp last_y          (ce_pix)
// PIPE_DEPTH (1..3) splits #2/#3. Default 2. Math unchanged; latency = PIPE_DEPTH
// ce_pix regs. pipe_latency_ce exports that for MP_STORE_LAT / consumers.
//
// past_last_row is BEAM-TIMED (combo on py) — not delayed with store pipe (G-VID1).
// Quartus 17.0: no SV-2012 default port values.

`default_nettype none

module present_content_window #(
	parameter int FRAME_W = 640,
	parameter int FRAME_H = 480,
	parameter int STORE_W = 1280,
	parameter int STORE_H = 720,
	parameter int H_DE_DEFAULT = 529,
	parameter int V_DE_DEFAULT = 480,
	// Pixel-path ce_pix register stages:
	//   1: mul+add+clamp combo → 1 reg  (original latency / bit-phase)
	//   2: mul → reg → add+clamp → reg  (default; shortens ce_pix depth)
	//   3: mul → reg → add → reg → clamp → reg
	parameter int PIPE_DEPTH = 2,
	// TB-only: when 1 with PIPE_DEPTH>=2, final stage uses live depth-1 math
	// (deliberately unbalanced). Equivalence vs PIPE_DEPTH=1 MUST fail.
	parameter bit FAULT_DROP_PIPE_BALANCE = 1'b0
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,

	input  wire [10:0] hc,
	input  wire [10:0] py,
	input  wire        in_content,

	input  wire        win_enable,
	input  wire [10:0] content_w,
	input  wire [10:0] content_h,
	input  wire [10:0] content_x0,
	input  wire [10:0] content_y0,
	input  wire [10:0] h_de,
	input  wire [10:0] v_de,

	output reg  [$clog2(STORE_W)-1:0] store_x,
	output reg  [$clog2(STORE_H)-1:0] store_y,
	output reg         de_r,
	output wire        past_last_row,
	output wire [3:0]  pipe_latency_ce
`ifdef PRESENT_WINDOW_BILINEAR
	,
	output reg  [$clog2(STORE_W)-1:0] store_x1,
	output reg  [$clog2(STORE_H)-1:0] store_y1,
	output reg  [7:0]  frac_x,
	output reg  [7:0]  frac_y
`endif
);

	// synthesis translate_off
	initial begin
		if (PIPE_DEPTH < 1 || PIPE_DEPTH > 3)
			$error("present_content_window: PIPE_DEPTH must be 1..3 (got %0d)", PIPE_DEPTH);
	end
	// synthesis translate_on

	localparam int STORE_X_W = $clog2(STORE_W);
	localparam int STORE_Y_W = $clog2(STORE_H);
	localparam int STORE_X_SCALE = (FRAME_W * 39647) / 320;
	localparam int STORE_Y_SCALE = (FRAME_H * 65536) / V_DE_DEFAULT;
	localparam [15:0] FRAME_LAST_X_16 = 16'(FRAME_W - 1);
	localparam [15:0] FRAME_LAST_Y_16 = 16'(FRAME_H - 1);
	localparam [15:0] STORE_LAST_X_16 = 16'(STORE_W - 1);
	localparam [15:0] STORE_LAST_Y_16 = 16'(STORE_H - 1);
	// 32 restoring steps → full integer quotient; take [19:0] like 20'(div).
	localparam int DIV_STEPS = 32;

	assign pipe_latency_ce = 4'(PIPE_DEPTH);

	// ----- effective geometry -----
	wire [10:0] h_de_raw = (h_de == 11'd0) ? 11'(H_DE_DEFAULT) : h_de;
	wire [10:0] v_de_raw = (v_de == 11'd0) ? 11'(V_DE_DEFAULT) : v_de;
	wire [10:0] h_de_eff = (h_de_raw == 11'd0) ? 11'd1 : h_de_raw;
	wire [10:0] v_de_eff = (v_de_raw == 11'd0) ? 11'd1 : v_de_raw;

	wire [10:0] cw_raw = win_enable ? content_w : 11'(FRAME_W);
	wire [10:0] ch_raw = win_enable ? content_h : 11'(FRAME_H);
	wire [10:0] cw_eff = (cw_raw == 11'd0) ? 11'd1 : cw_raw;
	wire [10:0] ch_eff = (ch_raw == 11'd0) ? 11'd1 : ch_raw;
	wire [10:0] x0_eff = win_enable ? content_x0 : 11'd0;
	wire [10:0] y0_eff = win_enable ? content_y0 : 11'd0;

	wire [10:0] cw_m1 = (cw_eff <= 11'd1) ? 11'd0 : (cw_eff - 11'd1);
	wire [10:0] ch_m1 = (ch_eff <= 11'd1) ? 11'd0 : (ch_eff - 11'd1);
	wire [10:0] hd_m1 = (h_de_eff <= 11'd1) ? 11'd1 : (h_de_eff - 11'd1);
	wire [10:0] vd_m1 = (v_de_eff <= 11'd1) ? 11'd1 : (v_de_eff - 11'd1);

	// ceil((c-1)<<16 / (d-1)) = ((c-1)<<16 + (d-1) - 1) / (d-1)
	wire [31:0] sx_num_ceil = ({21'd0, cw_m1} << 16) + {21'd0, hd_m1} - 32'd1;
	wire [31:0] sy_num_ceil = ({21'd0, ch_m1} << 16) + {21'd0, vd_m1} - 32'd1;
	wire [31:0] sx_num_floor = ({21'd0, cw_m1} << 16);
	wire [31:0] sy_num_floor = ({21'd0, ch_m1} << 16);

	wire [19:0] sx_leg = 20'(STORE_X_SCALE);
	wire [19:0] sy_leg = 20'(STORE_Y_SCALE);

	wire [15:0] last_x_span = {5'd0, cw_eff} - 16'd1;
	wire [15:0] last_y_span = {5'd0, ch_eff} - 16'd1;
	wire [15:0] last_x_abs  = {5'd0, x0_eff} + last_x_span;
	wire [15:0] last_y_abs  = {5'd0, y0_eff} + last_y_span;
	wire [15:0] last_x_lim =
		(last_x_abs > STORE_LAST_X_16) ? STORE_LAST_X_16 : last_x_abs;
	wire [15:0] last_y_lim =
		(last_y_abs > STORE_LAST_Y_16) ? STORE_LAST_Y_16 : last_y_abs;

	// ----- fault inject (sim) -----
`ifdef PRESENT_WINDOW_FAULT_IDENTITY_SCALE
	localparam bit FAULT_IDENTITY = 1'b1;
`else
	localparam bit FAULT_IDENTITY = 1'b0;
`endif
`ifdef PRESENT_WINDOW_FAULT_FLOOR_SCALE
	localparam bit FAULT_FLOOR = 1'b1;
`else
	localparam bit FAULT_FLOOR = 1'b0;
`endif
`ifdef PRESENT_WINDOW_FAULT_DROP_PIPE_BALANCE
	localparam bit FAULT_DROP_PIPE = 1'b1;
`else
	localparam bit FAULT_DROP_PIPE = FAULT_DROP_PIPE_BALANCE;
`endif

	// ----- scale multi-cycle divider + geometry regs -----
	reg        win_r;
	reg [10:0] cw_r, ch_r, x0p_r, y0p_r, hd_r, vd_r;
	reg [31:0] sx_num_r, sy_num_r;
	reg [10:0] sx_den_r, sy_den_r;

	reg        div_busy;
	reg        div_is_y;
	reg [5:0]  div_cnt;
	reg [31:0] div_dend;   // shifting numerator / working dividend
	reg [31:0] div_rem;
	reg [31:0] div_quot;
	reg [10:0] div_den;
	reg [19:0] sx_r, sy_r;
	reg [15:0] x0_r, y0_r, last_x_r, last_y_r;
	reg [10:0] v_de_r;

	wire geom_change =
		(win_enable != win_r) ||
		(cw_eff != cw_r) || (ch_eff != ch_r) ||
		(x0_eff != x0p_r) || (y0_eff != y0p_r) ||
		(h_de_eff != hd_r) || (v_de_eff != vd_r);

	// Restoring-divider combinational step (one bit); registered in always.
	wire [31:0] div_rem_shift  = {div_rem[30:0], div_dend[31]};
	wire [31:0] div_dend_next  = {div_dend[30:0], 1'b0};
	wire        div_ge         = (div_rem_shift >= {21'd0, div_den});
	wire [31:0] div_rem_next   = div_ge ? (div_rem_shift - {21'd0, div_den})
	                                    : div_rem_shift;
	wire [31:0] div_quot_next  = {div_quot[30:0], div_ge};

	always @(posedge clk) begin
		if (reset) begin
			win_r     <= 1'b0;
			cw_r      <= 11'(FRAME_W);
			ch_r      <= 11'(FRAME_H);
			x0p_r     <= 11'd0;
			y0p_r     <= 11'd0;
			hd_r      <= 11'(H_DE_DEFAULT);
			vd_r      <= 11'(V_DE_DEFAULT);
			sx_num_r  <= 32'd0;
			sy_num_r  <= 32'd0;
			sx_den_r  <= 11'd1;
			sy_den_r  <= 11'd1;
			div_busy  <= 1'b0;
			div_is_y  <= 1'b0;
			div_cnt   <= 6'd0;
			div_dend  <= 32'd0;
			div_rem   <= 32'd0;
			div_quot  <= 32'd0;
			div_den   <= 11'd1;
			sx_r      <= 20'(STORE_X_SCALE);
			sy_r      <= 20'(STORE_Y_SCALE);
			x0_r      <= 16'd0;
			y0_r      <= 16'd0;
			last_x_r  <= FRAME_LAST_X_16;
			last_y_r  <= FRAME_LAST_Y_16;
			v_de_r    <= 11'(V_DE_DEFAULT);
		end else begin
			// Cheap sideband tracks geometry every clk (not on mul path).
			x0_r     <= {5'd0, x0_eff};
			y0_r     <= {5'd0, y0_eff};
			last_x_r <= win_enable ? last_x_lim : FRAME_LAST_X_16;
			last_y_r <= win_enable ? last_y_lim : FRAME_LAST_Y_16;
			v_de_r   <= v_de_eff;

			if (geom_change && !div_busy) begin
				win_r  <= win_enable;
				cw_r   <= cw_eff;
				ch_r   <= ch_eff;
				x0p_r  <= x0_eff;
				y0p_r  <= y0_eff;
				hd_r   <= h_de_eff;
				vd_r   <= v_de_eff;
				sx_num_r <= FAULT_FLOOR ? sx_num_floor : sx_num_ceil;
				sy_num_r <= FAULT_FLOOR ? sy_num_floor : sy_num_ceil;
				sx_den_r <= hd_m1;
				sy_den_r <= vd_m1;

				if (!win_enable) begin
					sx_r <= sx_leg;
					sy_r <= sy_leg;
				end else if (FAULT_IDENTITY) begin
					sx_r <= 20'd65536;
					sy_r <= 20'd65536;
				end else begin
					div_busy <= 1'b1;
					div_is_y <= 1'b0;
					div_cnt  <= 6'(DIV_STEPS);
					div_dend <= FAULT_FLOOR ? sx_num_floor : sx_num_ceil;
					div_den  <= hd_m1;
					div_rem  <= 32'd0;
					div_quot <= 32'd0;
				end
			end else if (div_busy) begin
				// Restoring divider: one quotient bit / clk (off ce_pix pixel path).
				div_rem  <= div_rem_next;
				div_dend <= div_dend_next;
				div_quot <= div_quot_next;
				if (div_cnt == 6'd1) begin
					if (!div_is_y) begin
						sx_r     <= div_quot_next[19:0];
						div_is_y <= 1'b1;
						div_cnt  <= 6'(DIV_STEPS);
						div_dend <= sy_num_r;
						div_den  <= sy_den_r;
						div_rem  <= 32'd0;
						div_quot <= 32'd0;
					end else begin
						sy_r     <= div_quot_next[19:0];
						div_busy <= 1'b0;
						div_cnt  <= 6'd0;
					end
				end else begin
					div_cnt <= div_cnt - 6'd1;
				end
			end
		end
	end

	// ----- pixel path -----
	wire past_last_row_c = (py >= v_de_r);
	assign past_last_row = past_last_row_c;
	wire [10:0] v_last = (v_de_r == 11'd0) ? 11'd0 : (v_de_r - 11'd1);
	wire [10:0] py_clamped = past_last_row_c ? v_last : py;

	// Live mul (stage A input)
	wire [31:0] xprod_live = {21'd0, hc} * {12'd0, sx_r};
	wire [31:0] yprod_live = {21'd0, py_clamped} * {12'd0, sy_r};

	// PIPE_DEPTH==1 full combo (original)
	wire [16:0] xsum_live = {1'b0, x0_r} + {1'b0, xprod_live[31:16]};
	wire [16:0] ysum_live = {1'b0, y0_r} + {1'b0, yprod_live[31:16]};
	wire [15:0] sx_live =
		(xsum_live > {1'b0, last_x_r}) ? last_x_r : xsum_live[15:0];
	wire [15:0] sy_live =
		(ysum_live > {1'b0, last_y_r}) ? last_y_r : ysum_live[15:0];

	// Stage-1 regs
	reg [31:0] xprod_s1, yprod_s1;
	reg [15:0] x0_s1, y0_s1, last_x_s1, last_y_s1;
	reg        de_s1;
	// Stage-2 regs (PIPE_DEPTH==3)
	reg [15:0] xsum_s2, ysum_s2, last_x_s2, last_y_s2;
	reg        de_s2;
`ifdef PRESENT_WINDOW_BILINEAR
	reg [7:0]  frx_s1, fry_s1, frx_s2, fry_s2;
`endif

	wire [16:0] xsum_s1 = {1'b0, x0_s1} + {1'b0, xprod_s1[31:16]};
	wire [16:0] ysum_s1 = {1'b0, y0_s1} + {1'b0, yprod_s1[31:16]};

	wire [16:0] xsum_c = (PIPE_DEPTH >= 3) ? {1'b0, xsum_s2} : xsum_s1;
	wire [16:0] ysum_c = (PIPE_DEPTH >= 3) ? {1'b0, ysum_s2} : ysum_s1;
	wire [15:0] last_x_c = (PIPE_DEPTH >= 3) ? last_x_s2 : last_x_s1;
	wire [15:0] last_y_c = (PIPE_DEPTH >= 3) ? last_y_s2 : last_y_s1;
	wire [15:0] sx_pipe =
		(xsum_c > {1'b0, last_x_c}) ? last_x_c : xsum_c[15:0];
	wire [15:0] sy_pipe =
		(ysum_c > {1'b0, last_y_c}) ? last_y_c : ysum_c[15:0];
	wire de_pipe = (PIPE_DEPTH >= 3) ? de_s2 : de_s1;

`ifdef PRESENT_WINDOW_BILINEAR
	wire [16:0] x1s = {1'b0, sx_pipe} + 17'd1;
	wire [16:0] y1s = {1'b0, sy_pipe} + 17'd1;
	wire atx = ({1'b0, sx_pipe} >= {1'b0, last_x_c});
	wire aty = ({1'b0, sy_pipe} >= {1'b0, last_y_c});
	wire [15:0] sx1_pipe = atx ? sx_pipe :
		((x1s > {1'b0, last_x_c}) ? last_x_c : x1s[15:0]);
	wire [15:0] sy1_pipe = aty ? sy_pipe :
		((y1s > {1'b0, last_y_c}) ? last_y_c : y1s[15:0]);
	wire [7:0] frx_src = (PIPE_DEPTH >= 3) ? frx_s2 :
		((PIPE_DEPTH == 1) ? xprod_live[15:8] : xprod_s1[15:8]);
	wire [7:0] fry_src = (PIPE_DEPTH >= 3) ? fry_s2 :
		((PIPE_DEPTH == 1) ? yprod_live[15:8] : yprod_s1[15:8]);
	wire [7:0] frx_pipe = atx ? 8'd0 : frx_src;
	wire [7:0] fry_pipe = aty ? 8'd0 : fry_src;

	wire [16:0] x1l = {1'b0, sx_live} + 17'd1;
	wire [16:0] y1l = {1'b0, sy_live} + 17'd1;
	wire atxl = ({1'b0, sx_live} >= {1'b0, last_x_r});
	wire atyl = ({1'b0, sy_live} >= {1'b0, last_y_r});
	wire [15:0] sx1_live = atxl ? sx_live :
		((x1l > {1'b0, last_x_r}) ? last_x_r : x1l[15:0]);
	wire [15:0] sy1_live = atyl ? sy_live :
		((y1l > {1'b0, last_y_r}) ? last_y_r : y1l[15:0]);
	wire [7:0] frx_live = atxl ? 8'd0 : xprod_live[15:8];
	wire [7:0] fry_live = atyl ? 8'd0 : yprod_live[15:8];
`endif

	always @(posedge clk) begin
		if (reset) begin
			store_x   <= '0;
			store_y   <= '0;
			de_r      <= 1'b0;
			xprod_s1  <= 32'd0;
			yprod_s1  <= 32'd0;
			x0_s1     <= 16'd0;
			y0_s1     <= 16'd0;
			last_x_s1 <= 16'd0;
			last_y_s1 <= 16'd0;
			de_s1     <= 1'b0;
			xsum_s2   <= 16'd0;
			ysum_s2   <= 16'd0;
			last_x_s2 <= 16'd0;
			last_y_s2 <= 16'd0;
			de_s2     <= 1'b0;
`ifdef PRESENT_WINDOW_BILINEAR
			store_x1  <= '0;
			store_y1  <= '0;
			frac_x    <= 8'd0;
			frac_y    <= 8'd0;
			frx_s1    <= 8'd0;
			fry_s1    <= 8'd0;
			frx_s2    <= 8'd0;
			fry_s2    <= 8'd0;
`endif
		end else if (ce_pix) begin
			if (PIPE_DEPTH == 1) begin
				de_r    <= in_content;
				store_x <= sx_live[STORE_X_W-1:0];
				store_y <= sy_live[STORE_Y_W-1:0];
`ifdef PRESENT_WINDOW_BILINEAR
				store_x1 <= sx1_live[STORE_X_W-1:0];
				store_y1 <= sy1_live[STORE_Y_W-1:0];
				frac_x   <= frx_live;
				frac_y   <= fry_live;
`endif
			end else begin
				// Stage 1: register products (break mul from add/clamp)
				xprod_s1  <= xprod_live;
				yprod_s1  <= yprod_live;
				x0_s1     <= x0_r;
				y0_s1     <= y0_r;
				last_x_s1 <= last_x_r;
				last_y_s1 <= last_y_r;
				de_s1     <= in_content;
`ifdef PRESENT_WINDOW_BILINEAR
				frx_s1    <= xprod_live[15:8];
				fry_s1    <= yprod_live[15:8];
`endif
				if (PIPE_DEPTH >= 3) begin
					xsum_s2   <= xsum_s1[15:0];
					ysum_s2   <= ysum_s1[15:0];
					last_x_s2 <= last_x_s1;
					last_y_s2 <= last_y_s1;
					de_s2     <= de_s1;
`ifdef PRESENT_WINDOW_BILINEAR
					frx_s2    <= frx_s1;
					fry_s2    <= fry_s1;
`endif
					de_r    <= de_s2;
					store_x <= sx_pipe[STORE_X_W-1:0];
					store_y <= sy_pipe[STORE_Y_W-1:0];
`ifdef PRESENT_WINDOW_BILINEAR
					store_x1 <= sx1_pipe[STORE_X_W-1:0];
					store_y1 <= sy1_pipe[STORE_Y_W-1:0];
					frac_x   <= frx_pipe;
					frac_y   <= fry_pipe;
`endif
				end else if (FAULT_DROP_PIPE) begin
					// NEG control: output uses live (depth-1) math while
					// claiming PIPE_DEPTH=2 — desynchronises vs balanced pipe.
					de_r    <= in_content;
					store_x <= sx_live[STORE_X_W-1:0];
					store_y <= sy_live[STORE_Y_W-1:0];
`ifdef PRESENT_WINDOW_BILINEAR
					store_x1 <= sx1_live[STORE_X_W-1:0];
					store_y1 <= sy1_live[STORE_Y_W-1:0];
					frac_x   <= frx_live;
					frac_y   <= fry_live;
`endif
				end else begin
					// PIPE_DEPTH==2 balanced: clamp(s1) → out
					de_r    <= de_pipe;
					store_x <= sx_pipe[STORE_X_W-1:0];
					store_y <= sy_pipe[STORE_Y_W-1:0];
`ifdef PRESENT_WINDOW_BILINEAR
					store_x1 <= sx1_pipe[STORE_X_W-1:0];
					store_y1 <= sy1_pipe[STORE_Y_W-1:0];
					frac_x   <= frx_pipe;
					frac_y   <= fry_pipe;
`endif
				end
			end
		end
	end

endmodule

`default_nettype wire
