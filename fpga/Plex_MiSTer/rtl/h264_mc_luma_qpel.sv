// Resource-shared quarter-sample luma interpolator (ITU-T H.264 8.4.2.2.1).
//
// AREA IS THE HARD CONSTRAINT
//   The previous revisions of this engine took the 21x21 reference window in
//   as a flat `input [7:0] ref_win [0:440]` port array and indexed it with
//   runtime row/column values.  Every such index is a 441:1 byte multiplexer
//   in fabric, and each output lane needed 33 of them (five 6-tap groups plus
//   three direct integer samples).  That, not the taps, is what produced an
//   89,888 ALUT block: the filter arithmetic is shift-add and nearly free,
//   the window random-access port is not.
//
//   This version therefore obeys two rules:
//     1. The window lives in RAM, addressed one sample per cycle, never in
//        registers with a runtime index.
//     2. There is exactly ONE 6-tap datapath in the whole module.  It is
//        time-multiplexed across the horizontal pass and all three vertical
//        passes.  A 6-deep shift register slides along the walk, so each new
//        output needs only one new sample out of memory.
//   Memory is spent to buy logic, which is the trade the device budget wants:
//   M10K occupancy was 52% while logic utilisation was 248%.
//
// SCHEDULE (cycles; latency is negotiable, area is not)
//   full-pel  (fx=0,fy=0)        259
//   fx!=0, fy=0                  444 + 259
//   fx=0,  fy!=0                 339 + 259
//   worst (fx=3, centre sample)  444 + 3*339 + 259 = 1720
//
// GEOMETRY
//   The window is the 21x21 POST-deblock reference region the DPB fetch
//   produced, raster order, already edge-clamped by h264_luma_ref_tap_addr so
//   motion vectors pointing outside the picture replicate the border sample.
//   The integer sample for output (x,y) is window[(y+2)*21 + (x+2)].
//
// SEPARABILITY AND THE DOUBLE-ROUNDING TRAP
//   b1(r,x) is the raw horizontal 6-tap at FULL precision, not rounded:
//     b1 = W[r][x] - 5W[r][x+1] + 20W[r][x+2] + 20W[r][x+3] - 5W[r][x+4] + W[r][x+5]
//   The half sample b is Clip1((b1 + 16) >> 5), but the centre sample j is a
//   vertical 6-tap over the *unrounded* b1 values followed by one single
//   (j1 + 512) >> 10.  hbram therefore stores b1 unrounded at 16 bits signed
//   (range -2550..10710); the >>5 rounding for b happens only on the way out,
//   in the combine pass.  Rounding into hbram would be the classic
//   conformance bug.

`default_nettype none

module h264_mc_luma_qpel (
	input  wire        clk,
	input  wire        reset,

	// Reference window streaming write port.  441 samples, raster order,
	// index = row*21 + col.  Written while the engine is idle, straight from
	// the DPB fetch, so no 441-register staging array is needed anywhere.
	input  wire        win_wr,
	input  wire [8:0]  win_addr,
	input  wire [7:0]  win_data,

	input  wire        start,
	input  wire [1:0]  frac_x,
	input  wire [1:0]  frac_y,

	output reg         busy,
	output reg         done,

	// Prediction read port: 16x16, index=y*16+x. SYNC (+1 M10K).
	// Consumer decode_core drives idx early; captures on HOLD/WRITE into pred_q.
	input  wire [7:0]  pred_rd_idx,
	output wire [7:0]  pred_rd_data,

	// First 16 samples of the block kept in registers, for the legacy
	// observability path in decode_stub which taps them in parallel.
	output reg  [7:0]  pred_head [0:15]
);
	// ------------------------------------------------------------------
	// Storage.  Everything a pass touches is memory, addressed serially.
	// ------------------------------------------------------------------
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] winram [0:511];
	reg [7:0] winq;

	// Unrounded horizontal 6-tap plane: 21 window rows x 16 output columns.
	(* ramstyle = "M10K, no_rw_check" *) reg signed [15:0] hbram [0:511];
	reg signed [15:0] hbq;

	// Rounded vertical half samples over the 16x16 output grid.
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] shram [0:255]; // h, window column x+2
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] smram [0:255]; // m, window column x+3
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] sjram [0:255]; // j, centre sample
	reg [7:0] shq, smq, sjq;

	// Consumer: decode_core p16_pred_q pipeline (HOLD/WRITE capture). Sync
	// read +1 is absorbed there (addr driven one cycle early). Was MLAB.
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] predram [0:255];
	reg [7:0] pred_rd_data_r;
	assign pred_rd_data = pred_rd_data_r;

	// ------------------------------------------------------------------
	// The single shared 6-tap datapath.
	// ------------------------------------------------------------------
	reg signed [15:0] sr [0:5];

	// (1,-5,20,20,-5,1) written as shift-adds, so no DSP block is consumed
	// and the whole engine stays in fabric.  This also relieves the 130% DSP
	// pressure the fit reported.
	function automatic signed [23:0] tap6(
		input signed [23:0] a0, input signed [23:0] a1, input signed [23:0] a2,
		input signed [23:0] a3, input signed [23:0] a4, input signed [23:0] a5);
		begin
			tap6 = a0 + a5
			     - ((a1 <<< 2) + a1)
			     - ((a4 <<< 2) + a4)
			     + ((a2 <<< 4) + (a2 <<< 2))
			     + ((a3 <<< 4) + (a3 <<< 2));
		end
	endfunction

	wire signed [23:0] tapo = tap6(sr[0], sr[1], sr[2], sr[3], sr[4], sr[5]);

	function automatic [7:0] clip1(input signed [23:0] v);
		begin
			if (v < 0)             clip1 = 8'd0;
			else if (v > 24'sd255) clip1 = 8'd255;
			else                   clip1 = v[7:0];
		end
	endfunction

	function automatic [7:0] avg2(input [7:0] a, input [7:0] b);
		begin
			avg2 = 8'((({1'b0, a} + {1'b0, b} + 9'd1) >> 1));
		end
	endfunction

	// ------------------------------------------------------------------
	// Control
	// ------------------------------------------------------------------
	localparam [2:0] S_IDLE = 3'd0;
	localparam [2:0] S_H    = 3'd1; // horizontal pass -> hbram
	localparam [2:0] S_V    = 3'd2; // vertical pass   -> shram/smram/sjram
	localparam [2:0] S_C    = 3'd3; // combine         -> predram
	localparam [2:0] S_DONE = 3'd4;

	reg [2:0] state;
	reg [1:0] fx_r, fy_r;
	reg [1:0] vsel;          // 0 = h column, 1 = m column, 2 = centre j
	reg       use_j_r;

	// Walk counters: ao is the outer index, ai the inner index.
	reg [4:0] ao, ai;
	reg [7:0] ccnt;
	reg       a_run;

	wire use_j    = (frac_x == 2'd2 && frac_y != 2'd0) ||
	                (frac_y == 2'd2 && frac_x != 2'd0);
	wire full_pel = (frac_x == 2'd0) && (frac_y == 2'd0);

	// use_j implies frac_x != 0, so the horizontal pass covers the centre
	// sample's source plane as well as the b/s half samples.
	wire need_sh = (fy_r != 2'd0);
	wire need_sm = (fx_r == 2'd3) && (fy_r != 2'd0);
	wire need_sj = use_j_r;

	// Pick the next vertical sub-pass that is actually required, or 3 when
	// none are left and the combine pass should run.
	function automatic [1:0] next_vsel(input [1:0] from);
		begin
			if      (from <= 2'd0 && need_sh) next_vsel = 2'd0;
			else if (from <= 2'd1 && need_sm) next_vsel = 2'd1;
			else if (from <= 2'd2 && need_sj) next_vsel = 2'd2;
			else                              next_vsel = 2'd3;
		end
	endfunction

	// ------------------------------------------------------------------
	// Address generation, combinational into the synchronous RAM reads.
	//   S_H: ao = window row 0..20,   ai = window column 0..20
	//   S_V: ao = output column 0..15, ai = window row 0..20
	//   S_C: ccnt = y*16 + x
	// ------------------------------------------------------------------
	wire [3:0] cy = ccnt[7:4];
	wire [3:0] cx = ccnt[3:0];

	// Row strides are constant multiplies by 21.  Written as a shift-add so
	// no DSP block can be inferred for address generation either; the fit was
	// at 130% DSP as well as 248% logic.
	function automatic [8:0] m21(input [4:0] r);
		begin
			m21 = 9'((9'(r) << 4) + (9'(r) << 2) + 9'(r));
		end
	endfunction

	// The one integer sample the position needs: pG for G/a/d, pH for c,
	// pM for n.  No position reads two of them, so one window port suffices.
	reg [8:0] cwin_a;
	always @* begin
		case ({fy_r, fx_r})
		4'b0011: cwin_a = 9'(m21(5'(cy) + 5'd2) + 9'(cx) + 9'd3); // pH
		4'b1100: cwin_a = 9'(m21(5'(cy) + 5'd3) + 9'(cx) + 9'd2); // pM
		default: cwin_a = 9'(m21(5'(cy) + 5'd2) + 9'(cx) + 9'd2); // pG
		endcase
	end

	// b comes from window row y+2; s (used by p, q, r) from window row y+3.
	wire [8:0] chb_a = (fy_r == 2'd3) ? 9'(((9'(cy) + 9'd3) << 4) + 9'(cx))
	                                  : 9'(((9'(cy) + 9'd2) << 4) + 9'(cx));

	reg [8:0] win_ra;
	always @* begin
		case (state)
		S_H:     win_ra = 9'(m21(ao) + 9'(ai));
		S_V:     win_ra = (vsel == 2'd1) ? 9'(m21(ai) + 9'(ao) + 9'd3)
		                                 : 9'(m21(ai) + 9'(ao) + 9'd2);
		default: win_ra = cwin_a;
		endcase
	end

	wire [8:0] hb_ra = (state == S_V) ? 9'((9'(ai) << 4) + 9'(ao)) : chb_a;
	wire [7:0] sv_ra = 8'((8'(cy) << 4) + 8'(cx));

	// ------------------------------------------------------------------
	// Pipeline.  p1 describes the sample standing on winq/hbq this cycle;
	// p2 describes the tap6 result standing on tapo this cycle.
	// ------------------------------------------------------------------
	reg       p1_v, p2_v;
	reg [4:0] p1_o, p1_i, p2_o, p2_i;
	reg       c1_v;
	reg [7:0] c1_idx;

	wire       hb_we = (state == S_H) && p2_v;
	wire [8:0] hb_wa = 9'((9'(p2_o) << 4) + 9'(p2_i) - 9'd5);

	wire       v_we  = (state == S_V) && p2_v;
	wire [7:0] v_wa  = 8'((8'(p2_i - 5'd5) << 4) + 8'(p2_o));
	wire [7:0] v_wd  = (vsel == 2'd2) ? clip1((tapo + 24'sd512) >>> 10)
	                                  : clip1((tapo + 24'sd16)  >>> 5);

	// ------------------------------------------------------------------
	// Combine pass
	// ------------------------------------------------------------------
	wire [7:0] pI = winq;
	wire [7:0] sB = clip1(($signed({{8{hbq[15]}}, hbq}) + 24'sd16) >>> 5);
	wire [7:0] sH = shq;
	wire [7:0] sM = smq;
	wire [7:0] sJ = sjq;

	reg [7:0] cq;
	always @* begin
		case ({fy_r, fx_r})
		4'b0000: cq = pI;             // G
		4'b0001: cq = avg2(pI, sB);   // a
		4'b0010: cq = sB;             // b
		4'b0011: cq = avg2(sB, pI);   // c   (pI is pH here)
		4'b0100: cq = avg2(pI, sH);   // d
		4'b0101: cq = avg2(sB, sH);   // e
		4'b0110: cq = avg2(sB, sJ);   // f
		4'b0111: cq = avg2(sB, sM);   // g
		4'b1000: cq = sH;             // h
		4'b1001: cq = avg2(sH, sJ);   // i
		4'b1010: cq = sJ;             // j
		4'b1011: cq = avg2(sJ, sM);   // k
		4'b1100: cq = avg2(pI, sH);   // n   (pI is pM here)
		4'b1101: cq = avg2(sH, sB);   // p   (sB is s here)
		4'b1110: cq = avg2(sJ, sB);   // q
		default: cq = avg2(sM, sB);   // r
		endcase
	end

	// ------------------------------------------------------------------
	// Memories
	// ------------------------------------------------------------------
	always @(posedge clk) begin
		if (win_wr) winram[win_addr] <= win_data;
		winq <= winram[win_ra];
	end

	always @(posedge clk) begin
		if (hb_we) hbram[hb_wa] <= tapo[15:0];
		hbq <= hbram[hb_ra];
	end

	always @(posedge clk) begin
		if (v_we && vsel == 2'd0) shram[v_wa] <= v_wd;
		shq <= shram[sv_ra];
	end
	always @(posedge clk) begin
		if (v_we && vsel == 2'd1) smram[v_wa] <= v_wd;
		smq <= smram[sv_ra];
	end
	always @(posedge clk) begin
		if (v_we && vsel == 2'd2) sjram[v_wa] <= v_wd;
		sjq <= sjram[sv_ra];
	end

	always @(posedge clk) begin
		if (c1_v) predram[c1_idx] <= cq;
		pred_rd_data_r <= predram[pred_rd_idx];
	end

	// ------------------------------------------------------------------
	// Sequencer
	// ------------------------------------------------------------------
	integer i;
	always @(posedge clk) begin
		if (reset) begin
			state   <= S_IDLE;
			busy    <= 1'b0;
			done    <= 1'b0;
			a_run   <= 1'b0;
			p1_v    <= 1'b0;
			p2_v    <= 1'b0;
			c1_v    <= 1'b0;
			ao      <= 5'd0;
			ai      <= 5'd0;
			ccnt    <= 8'd0;
			vsel    <= 2'd0;
			fx_r    <= 2'd0;
			fy_r    <= 2'd0;
			use_j_r <= 1'b0;
			for (i = 0; i < 6; i = i + 1) sr[i] <= 16'sd0;
			for (i = 0; i < 16; i = i + 1) pred_head[i] <= 8'd0;
		end else begin
			done <= 1'b0;
			p1_v <= 1'b0;
			p2_v <= p1_v;
			p2_o <= p1_o;
			p2_i <= p1_i;
			c1_v <= 1'b0;

			if (c1_v && c1_idx < 8'd16) pred_head[c1_idx[3:0]] <= cq;

			// The shift register slides one sample per delivered read.  At a
			// row or column boundary its first five pushes still carry the
			// tail of the previous walk, which is why emission only starts
			// at inner index 5: by then all six taps belong to this walk.
			if (p1_v) begin
				sr[0] <= sr[1];
				sr[1] <= sr[2];
				sr[2] <= sr[3];
				sr[3] <= sr[4];
				sr[4] <= sr[5];
				sr[5] <= (state == S_V && vsel == 2'd2) ? hbq
				                                        : $signed({8'd0, winq});
			end

			case (state)
			S_IDLE: begin
				if (start) begin
					fx_r    <= frac_x;
					fy_r    <= frac_y;
					use_j_r <= use_j;
					busy    <= 1'b1;
					ao      <= 5'd0;
					ai      <= 5'd0;
					ccnt    <= 8'd0;
					vsel    <= 2'd0;
					a_run   <= 1'b1;
					// frac_x == 0 means no horizontal plane is needed, and it
					// also means the centre sample is never read, so the only
					// possible vertical sub-pass is the h column.
					state   <= full_pel ? S_C : ((frac_x != 2'd0) ? S_H : S_V);
				end
			end

			S_H: begin
				if (a_run) begin
					p1_v <= 1'b1;
					p1_o <= ao;
					p1_i <= ai;
					if (ai == 5'd20) begin
						ai <= 5'd0;
						if (ao == 5'd20) a_run <= 1'b0;
						else             ao    <= ao + 5'd1;
					end else begin
						ai <= ai + 5'd1;
					end
				end
				// Inner indices 0..4 only prime the shift register.
				if (p1_v && p1_i < 5'd5) p2_v <= 1'b0;
				if (!a_run && !p1_v && !p2_v) begin
					ao    <= 5'd0;
					ai    <= 5'd0;
					vsel  <= next_vsel(2'd0);
					a_run <= 1'b1;
					if (next_vsel(2'd0) == 2'd3) begin
						ccnt  <= 8'd0;
						state <= S_C;
					end else begin
						state <= S_V;
					end
				end
			end

			S_V: begin
				if (a_run) begin
					p1_v <= 1'b1;
					p1_o <= ao;
					p1_i <= ai;
					if (ai == 5'd20) begin
						ai <= 5'd0;
						if (ao == 5'd15) a_run <= 1'b0;
						else             ao    <= ao + 5'd1;
					end else begin
						ai <= ai + 5'd1;
					end
				end
				if (p1_v && p1_i < 5'd5) p2_v <= 1'b0;
				if (!a_run && !p1_v && !p2_v) begin
					ao    <= 5'd0;
					ai    <= 5'd0;
					vsel  <= next_vsel(vsel + 2'd1);
					a_run <= 1'b1;
					if (next_vsel(vsel + 2'd1) == 2'd3) begin
						ccnt  <= 8'd0;
						state <= S_C;
					end
				end
			end

			S_C: begin
				if (a_run) begin
					c1_idx <= ccnt;
					c1_v   <= 1'b1;
					if (ccnt == 8'd255) a_run <= 1'b0;
					else                ccnt  <= ccnt + 8'd1;
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
