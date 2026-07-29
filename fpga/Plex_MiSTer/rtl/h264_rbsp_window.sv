// Slice RBSP byte store with a registered sliding read window.
//
// =============================================================================
// CONTRACT — every RBSP consumer must honor this (do NOT assume combo reads)
// =============================================================================
//
// Write side (append-only, capture phase):
//   * wr_clear  — start a new NAL; drops length/complete/overflow and kills ready
//   * wr_en     — append one EPB-stripped RBSP byte while length < DEPTH_BYTES
//   * wr_end    — mark NAL complete (sticky until next wr_clear)
//   * Bytes past DEPTH_BYTES are dropped and raise overflow (never wrap).
//   * Writes are accepted only while the fill FSM is IDLE (product path fully
//     captures a VCL NAL before any consumer requests a window, so this does
//     not stall capture).
//
// Read side (parse phase) — MULTI-CYCLE, registered shadow:
//   * Storage is a single M10K byte RAM (DEPTH_BYTES).  The visible window is a
//     WINDOW_BYTES-deep registered shadow refilled from that RAM.
//   * req_valid + req_offset requests window_base := clamp(req_offset).
//     - If already ready at that base: window_ready stays 1 (0-cycle hit).
//     - Else: window_ready drops 0 and a refill starts.
//   * Refill latency: WINDOW_BYTES + 2 cycles after an accepted miss request
//     (1 cycle BRAM address latency + WINDOW_BYTES registered captures + settle).
//   * window[0:WINDOW_BYTES-1] and window_base are stable while window_ready=1
//     and no new miss request is accepted.
//   * window_avail = max(0, length - window_base).  Bytes past length read as 0.
//   * Consumers MUST sample rbsp_byte / window only when window_ready=1 and
//     window_base covers the absolute byte they intend to read.
//   * Consumers MUST NOT assume same-cycle response to req_valid.
//
// Consumers (single shared instance in stream_path as core_rbsp):
//   * h264_i_mb_feed     — syntax bit-reader + sole CAVLC residual walk (owns
//                          window while feed_busy).  Arms ST_*_ARM until
//                          win_ok (ready && base==req). Exports p_residual_*.
//   * h264_decode_core   — product FEED_PROVIDES_P_RESIDUAL=1: stubs dual CAVLC
//                          (u_product_p16_residual0). Legacy=0 uses sticky
//                          rbsp_res_pending_r + residual_window_ok on this window.
//   * stream_path mux    — feed_busy ? feed_req : core_req  (one requester).
//   * slice_hdr_parser   — separate local M10K MAXB capture; NOT this window.
//
// Area intent: M10K store + WINDOW_BYTES regs.  Ban 64-lane combo bank rotate
// (prior combo/MLAB shape: DEPTH=16384, WINDOW=64 → BANK_ROWS=256, 64 async
// banks + 64×64 barrel mux ≈ 87k ALMs own).
// =============================================================================

`default_nettype none

module h264_rbsp_window #(
	parameter int DEPTH_BYTES  = 4096,
	parameter int WINDOW_BYTES = 64
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        wr_clear,
	input  wire        wr_en,
	input  wire [7:0]  wr_data,
	input  wire        wr_end,

	input  wire        req_valid,
	input  wire [15:0] req_offset,

	output reg  [7:0]  window [0:WINDOW_BYTES-1],
	output wire [15:0] window_base,
	output wire [15:0] window_avail,
	output wire [15:0] length,
	output wire        complete,
	output wire        overflow,
	// 1 when window[] is valid for window_base (see CONTRACT header).
	output wire        window_ready
);
	localparam int AW = (DEPTH_BYTES <= 2) ? 1 : $clog2(DEPTH_BYTES);
	localparam int IW = (WINDOW_BYTES <= 2) ? 1 : $clog2(WINDOW_BYTES);
	localparam [15:0] DEPTH_W = 16'(DEPTH_BYTES);
	localparam [IW:0] WIN_N = (IW+1)'(WINDOW_BYTES);

	(* ramstyle = "M10K,no_rw_check" *)
	reg [7:0] mem [0:DEPTH_BYTES-1];

	reg [15:0] len_r;
	reg        complete_r;
	reg        overflow_r;
	reg [15:0] base_r;
	reg        ready_r;

	// Fill FSM: IDLE -> WAIT (BRAM latency) -> SHIFT x WINDOW_BYTES
	localparam [1:0] F_IDLE = 2'd0, F_WAIT = 2'd1, F_SHIFT = 2'd2;
	reg [1:0]    f_st;
	reg [IW:0]   f_idx;
	reg [15:0]   fill_base;
	reg [AW-1:0] rd_addr_r;
	reg [7:0]    rd_q;

	wire [15:0] req_base_clamped =
		(req_offset >= DEPTH_W) ? (DEPTH_W - 16'(WINDOW_BYTES)) : req_offset;

	// Hit: already presenting the requested base.
	wire req_hit = req_valid && ready_r && (req_base_clamped == base_r) && (f_st == F_IDLE);
	// Miss: need a refill (or restart to a new base mid-fill).
	wire req_miss = req_valid && !req_hit &&
		((f_st == F_IDLE) || (req_base_clamped != fill_base));

	wire wr_fits = (len_r < DEPTH_W);
	// Product path: capture completes before parse requests.  Never write during fill.
	wire wr_take = wr_en && wr_fits && (f_st == F_IDLE) && !req_miss;

	integer wi;

	always @(posedge clk) begin
		// Registered M10K read data (1-cycle latency from rd_addr_r).
		rd_q <= mem[rd_addr_r];

		if (reset) begin
			len_r      <= 16'd0;
			complete_r <= 1'b0;
			overflow_r <= 1'b0;
			base_r     <= 16'd0;
			ready_r    <= 1'b0;
			f_st       <= F_IDLE;
			f_idx      <= '0;
			fill_base  <= 16'd0;
			rd_addr_r  <= '0;
			for (wi = 0; wi < WINDOW_BYTES; wi = wi + 1)
				window[wi] <= 8'd0;
		end else if (wr_clear) begin
			len_r      <= 16'd0;
			complete_r <= 1'b0;
			overflow_r <= 1'b0;
			base_r     <= 16'd0;
			ready_r    <= 1'b0;
			f_st       <= F_IDLE;
			f_idx      <= '0;
			fill_base  <= 16'd0;
			for (wi = 0; wi < WINDOW_BYTES; wi = wi + 1)
				window[wi] <= 8'd0;
		end else begin
			if (wr_take) begin
				mem[len_r[AW-1:0]] <= wr_data;
				len_r <= len_r + 16'd1;
			end else if (wr_en && (f_st == F_IDLE) && !req_miss && !wr_fits) begin
				overflow_r <= 1'b1;
			end
			if (wr_end)
				complete_r <= 1'b1;

			// Accept a new fill target.
			if (req_miss) begin
				base_r     <= req_base_clamped;
				fill_base  <= req_base_clamped;
				rd_addr_r  <= req_base_clamped[AW-1:0];
				f_idx      <= '0;
				ready_r    <= 1'b0;
				f_st       <= F_WAIT;
			end else begin
				case (f_st)
				F_IDLE: begin
					// ready_r sticky until miss
				end
				F_WAIT: begin
					// rd_q will hold mem[fill_base] next cycle; prefetch +1.
					rd_addr_r <= (fill_base + 16'd1);
					f_st      <= F_SHIFT;
				end
				F_SHIFT: begin
					// rd_q holds mem[fill_base + f_idx]
					if ((fill_base + { {(16-IW-1){1'b0}}, f_idx }) < len_r)
						window[f_idx[IW-1:0]] <= rd_q;
					else
						window[f_idx[IW-1:0]] <= 8'd0;

					if (f_idx + 1'b1 >= WIN_N) begin
						f_st    <= F_IDLE;
						f_idx   <= '0;
						ready_r <= 1'b1;
					end else begin
						// Issue address for byte after the one currently in flight.
						rd_addr_r <= (fill_base + { {(16-IW-1){1'b0}}, f_idx } + 16'd2);
						f_idx     <= f_idx + 1'b1;
					end
				end
				default: f_st <= F_IDLE;
				endcase
			end
		end
	end

	assign window_base  = base_r;
	assign window_avail = (len_r > base_r) ? (len_r - base_r) : 16'd0;
	assign length       = len_r;
	assign complete     = complete_r;
	assign overflow     = overflow_r;
	assign window_ready = ready_r && (f_st == F_IDLE);
endmodule

`default_nettype wire
