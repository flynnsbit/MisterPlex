// Slice RBSP byte store with a sliding read window.
//
// CONTRACT (this is the buffer contract the decode core and every RBSP consumer
// must agree on; h264_cavlc_residual_block reads a MAX_BYTES slice of it):
//
//   * Write side is append-only.  `wr_clear` starts a new NAL, `wr_en` appends
//     one EPB-stripped RBSP byte, `wr_end` marks the NAL complete.  Bytes past
//     DEPTH_BYTES are dropped and raise `overflow` — they are never silently
//     wrapped over live data, because a wrap would corrupt an offset that the
//     decoder already committed to.
//   * Read side presents WINDOW_BYTES consecutive RBSP bytes starting at
//     `window_base`.  `req_valid` moves the base to `req_offset`.  The window is
//     COMBINATIONAL: the consumer sees the new bytes in the same cycle it
//     requests them, so no ready/valid handshake is needed and no consumer has
//     to be redesigned around window-fill latency.
//   * Reads past `length` return 0.  A consumer must use `window_avail` (bytes
//     really present from the base onward) to know how much of the window is
//     real; it is NOT allowed to infer this from the byte values.
//
// The window is served from DEPTH_BYTES/WINDOW_BYTES-deep byte banks, one bank
// per window lane, so an arbitrary unaligned base costs a barrel rotate rather
// than WINDOW_BYTES read ports on one memory.

// MERGE NOTE (63ec795): multi-cycle M10K window is base default; this lane
// currently uses combo window with window_ready=1 for feed/core bit-sync
// (area rewrite of window previously desynced parse at MB2).
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

	output wire [7:0]  window [0:WINDOW_BYTES-1],
	output wire [15:0] window_base,
	output wire [15:0] window_avail,
	output wire [15:0] length,
	output wire        complete,
	output wire        overflow,
	// Compat with multi-cycle consumers: combo window is always ready.
	output wire        window_ready
);
	assign window_ready = 1'b1;
	localparam int LANE_W    = $clog2(WINDOW_BYTES);
	localparam int BANK_ROWS = (DEPTH_BYTES + WINDOW_BYTES - 1) / WINDOW_BYTES;
	localparam int ROW_W     = (BANK_ROWS <= 1) ? 1 : $clog2(BANK_ROWS);
	localparam [15:0] DEPTH_W = 16'(DEPTH_BYTES);

	// Distributed (MLAB) banks: asynchronous read is what makes the window
	// combinational.  One bank per window lane.
	(* ramstyle = "MLAB,no_rw_check" *)
	reg [7:0] bank [0:WINDOW_BYTES-1][0:BANK_ROWS-1];

	reg [15:0] len_r;
	reg        complete_r;
	reg        overflow_r;
	reg [15:0] base_r;

	wire [LANE_W-1:0] wr_lane = len_r[LANE_W-1:0];
	wire [15:0]       wr_row_full = len_r >> LANE_W;
	wire [ROW_W-1:0]  wr_row = wr_row_full[ROW_W-1:0];
	wire              wr_fits = (len_r < DEPTH_W);
	wire              wr_take = wr_en && wr_fits;

	always @(posedge clk) begin
		if (reset) begin
			len_r <= 16'd0;
			complete_r <= 1'b0;
			overflow_r <= 1'b0;
			base_r <= 16'd0;
		end else begin
			if (wr_clear) begin
				len_r <= 16'd0;
				complete_r <= 1'b0;
				overflow_r <= 1'b0;
				base_r <= 16'd0;
			end else begin
				if (wr_take)
					len_r <= len_r + 16'd1;
				else if (wr_en)
					overflow_r <= 1'b1;
				if (wr_end)
					complete_r <= 1'b1;
			end

			if (req_valid)
				base_r <= (req_offset >= DEPTH_W) ? (DEPTH_W - 16'(WINDOW_BYTES))
				                                  : req_offset;
		end
	end

	always @(posedge clk) begin
		if (wr_take)
			bank[wr_lane][wr_row] <= wr_data;
	end

	// Lane k always holds the byte whose address is congruent to k modulo
	// WINDOW_BYTES, so for a base whose low bits are non-zero the lanes below
	// the base offset must come from the NEXT row.
	wire [LANE_W-1:0] base_lane = base_r[LANE_W-1:0];
	wire [15:0]       base_row_full = base_r >> LANE_W;

	wire [WINDOW_BYTES*8-1:0] lane_flat;

	genvar gk;
	generate
		for (gk = 0; gk < WINDOW_BYTES; gk = gk + 1) begin : g_lane
			wire [15:0] lane_row_full =
				base_row_full + ((gk[LANE_W-1:0] < base_lane) ? 16'd1 : 16'd0);
			wire        lane_row_ok = (lane_row_full < 16'(BANK_ROWS));
			wire [ROW_W-1:0] lane_row = lane_row_full[ROW_W-1:0];
			// Absolute RBSP address this lane is serving, used to zero-fill the
			// tail of a NAL that is shorter than the window.
			wire [15:0] lane_addr = (lane_row_full << LANE_W) | 16'(gk);
			assign lane_flat[gk*8 +: 8] =
				(lane_row_ok && (lane_addr < len_r)) ? bank[gk][lane_row] : 8'd0;
		end

		// Rotate the lane vector so window[0] is the byte at window_base.
		for (gk = 0; gk < WINDOW_BYTES; gk = gk + 1) begin : g_window
			wire [LANE_W-1:0] sel = base_lane + gk[LANE_W-1:0];
			assign window[gk] = lane_flat[{{(32-LANE_W){1'b0}}, sel} * 8 +: 8];
		end
	endgenerate

	assign window_base  = base_r;
	assign window_avail = (len_r > base_r) ? (len_r - base_r) : 16'd0;
	assign length       = len_r;
	assign complete     = complete_r;
	assign overflow     = overflow_r;
endmodule
