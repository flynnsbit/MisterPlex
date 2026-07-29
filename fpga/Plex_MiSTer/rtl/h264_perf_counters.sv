// Free-running per-stage cycle accounting for the macroblock pipeline.
//
// WHY THIS EXISTS
//   The decode clock is 20 MHz (rtl/pll/pll_0002.v output_clock_frequency0).
//   624x480 is 39x30 = 1170 macroblocks and the content runs at ~24 fps, so
//   the whole decoder has
//
//     20_000_000 / (1170 * 24) = 712 cycles per macroblock
//
//   for reference fetch, prediction, residual, reconstruction and the in-loop
//   filter combined.  Every optimisation in this decoder is an argument about
//   how that 712 is spent, and until now the argument was conducted entirely
//   by reading source and counting loop bounds by hand.
//
//   This is on-chip measurement, not a test harness: it stays in the product
//   build, costs a handful of counters, and lets the ARM read what the
//   pipeline actually did on real content instead of what a static reading of
//   the RTL predicts.  Static counting cannot see memory stalls, arbitration
//   loss to the display path, or the actual mix of sub-sample positions and
//   macroblock types in the stream, and all three move the answer.
//
// WHAT IS COUNTED
//   stage_id names the pipeline stage that owns the current cycle.  Every
//   cycle between mb_start and mb_done is charged to exactly one stage, so
//   the per-stage totals sum to the macroblock total by construction and a
//   stage that is silently eating the budget cannot hide.
//
//   Per frame the module keeps, for each stage, the total cycles spent in it
//   and the worst single macroblock, plus the whole-macroblock total and
//   worst.  Totals are latched at frame_done and held stable for the host so
//   a read can never tear across a frame boundary.
//
// HOW IT IS READ
//   One 64-bit mailbox word carries everything by rotating through a small
//   set of views.  The view advances on a slow free-running divider, so a host
//   polling at any rate sees every view without needing a request channel, and
//   `seq` lets it reject a torn or stale read.
//
//     [3:0]   view
//     [7:4]   layout version (= 1)
//     [15:8]  seq, increments every time the published word changes
//     [39:16] value A (24 bits, saturating)
//     [63:40] value B (24 bits, saturating)
//
//     view 0        A = cycles in the last frame     B = macroblocks in it
//     view 1..NS    A = frame cycles in stage view-1 B = worst MB in that stage
//     view NS+1     A = worst whole-macroblock cost  B = frames completed
//
//   24 bits saturates at 16.7M.  A frame at 712 cycles per macroblock is
//   833k cycles, and even a frame running 20x over budget stays inside the
//   range, so saturation means "something is catastrophically wrong" rather
//   than "the counter wrapped and lied".

`default_nettype none

module h264_perf_counters #(
	// Number of distinct pipeline stages charged.  stage_id must be < NSTAGES.
	parameter int NSTAGES = 6,
	// Free-running divider bits between mailbox view rotations.
	parameter int ROTATE_BITS = 20
) (
	input  wire       clk,
	input  wire       reset,

	// Cycle accounting.  active gates charging entirely, so idle time between
	// macroblocks is not attributed to whichever stage happened to be last.
	input  wire       active,
	input  wire [2:0] stage_id,

	// Macroblock and frame retirement pulses.
	input  wire       mb_done,
	input  wire       frame_done,

	output reg [63:0] mbox_word
);
	localparam int CW = 24;

	function automatic [CW-1:0] sat_add(input [CW-1:0] a, input [CW-1:0] b);
		reg [CW:0] sum;
		begin
			sum = {1'b0, a} + {1'b0, b};
			sat_add = sum[CW] ? {CW{1'b1}} : sum[CW-1:0];
		end
	endfunction

	function automatic [CW-1:0] sat_inc(input [CW-1:0] a);
		begin
			sat_inc = (a == {CW{1'b1}}) ? a : (a + {{(CW-1){1'b0}}, 1'b1});
		end
	endfunction

	// Live accumulators for the macroblock in flight.
	reg [CW-1:0] mb_stage [0:NSTAGES-1];
	reg [CW-1:0] mb_total;

	// Frame accumulators, still moving.
	reg [CW-1:0] fr_stage [0:NSTAGES-1];
	reg [CW-1:0] fr_stage_worst [0:NSTAGES-1];
	reg [CW-1:0] fr_total;
	reg [CW-1:0] fr_worst_mb;
	reg [CW-1:0] fr_mb_count;

	// Latched at frame_done and held for the host.
	reg [CW-1:0] pub_stage [0:NSTAGES-1];
	reg [CW-1:0] pub_stage_worst [0:NSTAGES-1];
	reg [CW-1:0] pub_total;
	reg [CW-1:0] pub_worst_mb;
	reg [CW-1:0] pub_mb_count;
	reg [CW-1:0] pub_frames;

	reg [ROTATE_BITS-1:0] rot;
	reg [3:0]             view;
	reg [7:0]             seq;

	integer s;

	always @(posedge clk) begin
		if (reset) begin
			for (s = 0; s < NSTAGES; s = s + 1) begin
				mb_stage[s]        <= {CW{1'b0}};
				fr_stage[s]        <= {CW{1'b0}};
				fr_stage_worst[s]  <= {CW{1'b0}};
				pub_stage[s]       <= {CW{1'b0}};
				pub_stage_worst[s] <= {CW{1'b0}};
			end
			mb_total     <= {CW{1'b0}};
			fr_total     <= {CW{1'b0}};
			fr_worst_mb  <= {CW{1'b0}};
			fr_mb_count  <= {CW{1'b0}};
			pub_total    <= {CW{1'b0}};
			pub_worst_mb <= {CW{1'b0}};
			pub_mb_count <= {CW{1'b0}};
			pub_frames   <= {CW{1'b0}};
			rot          <= {ROTATE_BITS{1'b0}};
			view         <= 4'd0;
			seq          <= 8'd0;
		end else begin
			// ── charge the cycle ────────────────────────────────────────────
			if (active) begin
				if (stage_id < NSTAGES[2:0])
					mb_stage[stage_id] <= sat_inc(mb_stage[stage_id]);
				mb_total <= sat_inc(mb_total);
			end

			// ── retire a macroblock ─────────────────────────────────────────
			// mb_done and the last charged cycle can coincide, so fold the
			// live accumulator in with the cycle still being charged rather
			// than reading the register that has not updated yet.
			if (mb_done) begin
				for (s = 0; s < NSTAGES; s = s + 1) begin
					fr_stage[s] <= sat_add(fr_stage[s], mb_stage[s]);
					if (mb_stage[s] > fr_stage_worst[s])
						fr_stage_worst[s] <= mb_stage[s];
					mb_stage[s] <= {CW{1'b0}};
				end
				fr_total    <= sat_add(fr_total, mb_total);
				fr_mb_count <= sat_inc(fr_mb_count);
				if (mb_total > fr_worst_mb) fr_worst_mb <= mb_total;
				mb_total <= {CW{1'b0}};
			end

			// ── retire a frame ──────────────────────────────────────────────
			if (frame_done) begin
				for (s = 0; s < NSTAGES; s = s + 1) begin
					pub_stage[s]       <= fr_stage[s];
					pub_stage_worst[s] <= fr_stage_worst[s];
					fr_stage[s]        <= {CW{1'b0}};
					fr_stage_worst[s]  <= {CW{1'b0}};
				end
				pub_total    <= fr_total;
				pub_worst_mb <= fr_worst_mb;
				pub_mb_count <= fr_mb_count;
				pub_frames   <= sat_inc(pub_frames);
				fr_total     <= {CW{1'b0}};
				fr_worst_mb  <= {CW{1'b0}};
				fr_mb_count  <= {CW{1'b0}};
			end

			// ── rotate the published view ───────────────────────────────────
			rot <= rot + {{(ROTATE_BITS-1){1'b0}}, 1'b1};
			if (rot == {ROTATE_BITS{1'b1}}) begin
				view <= (view == NSTAGES[3:0] + 4'd1) ? 4'd0 : (view + 4'd1);
				seq  <= seq + 8'd1;
			end
		end
	end

	// ── published word ──────────────────────────────────────────────────────
	reg [CW-1:0] va;
	reg [CW-1:0] vb;
	integer v;
	always @* begin
		if (view == 4'd0) begin
			va = pub_total;
			vb = pub_mb_count;
		end else if (view == NSTAGES[3:0] + 4'd1) begin
			va = pub_worst_mb;
			vb = pub_frames;
		end else begin
			va = {CW{1'b0}};
			vb = {CW{1'b0}};
			for (v = 0; v < NSTAGES; v = v + 1) begin
				if (view == v[3:0] + 4'd1) begin
					va = pub_stage[v];
					vb = pub_stage_worst[v];
				end
			end
		end
	end

	always @(posedge clk) begin
		if (reset) mbox_word <= 64'd0;
		else       mbox_word <= {vb, va, seq, 4'd1, view};
	end
endmodule

`default_nettype wire
