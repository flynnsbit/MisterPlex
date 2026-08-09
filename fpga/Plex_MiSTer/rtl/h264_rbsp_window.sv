// Slice RBSP byte store with a sliding read window.
//
// CONTRACT (registered M10K variant — 2-cycle read latency):
//
//   * Write side is append-only.  `wr_clear` starts a new NAL, `wr_en` appends
//     one EPB-stripped RBSP byte, `wr_end` marks the NAL complete.  Bytes past
//     DEPTH_BYTES are dropped and raise `overflow`.
//   * Read side presents WINDOW_BYTES consecutive RBSP bytes starting at
//     `window_base`.  `req_valid` moves the base to `req_offset`.
//   * LATENCY: 2 cycles from req_valid to stable window output.
//       cycle 0: req_valid + req_offset captured
//       cycle 1: M10K read address applied
//       cycle 2: window[0:WINDOW_BYTES-1] stable, window_valid asserts
//   * `window_valid` is HIGH when the window output corresponds to the last
//     completed request.  Consumers must gate CAVLC/bitparse on window_valid.
//   * Reads past `length` return 0.
//
// Storage: single M10K byte memory, read via WINDOW_BYTES simple dual-port
// inferred ports (one per output byte).  Each port addresses the full depth.

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
	output reg  [15:0] window_base,
	output wire [15:0] window_avail,
	output wire [15:0] length,
	output wire        complete,
	output wire        overflow,
	output reg         window_valid
);
	localparam int ADDR_W = (DEPTH_BYTES <= 1) ? 1 : $clog2(DEPTH_BYTES);
	localparam [15:0] DEPTH_W = 16'(DEPTH_BYTES);

	// ─── Storage: M10K byte RAM ────────────────────────────────────────
	(* ramstyle = "M10K,no_rw_check" *)
	reg [7:0] mem [0:DEPTH_BYTES-1];

	// ─── Write side ────────────────────────────────────────────────────
	reg [15:0] len_r;
	reg        complete_r;
	reg        overflow_r;

	wire wr_fits = (len_r < DEPTH_W);
	wire wr_take = wr_en && wr_fits;

	always @(posedge clk) begin
		if (reset) begin
			len_r      <= 16'd0;
			complete_r <= 1'b0;
			overflow_r <= 1'b0;
		end else if (wr_clear) begin
			len_r      <= 16'd0;
			complete_r <= 1'b0;
			overflow_r <= 1'b0;
		end else begin
			if (wr_take)
				len_r <= len_r + 16'd1;
			else if (wr_en)
				overflow_r <= 1'b1;
			if (wr_end)
				complete_r <= 1'b1;
		end
	end

	always @(posedge clk) begin
		if (wr_take)
			mem[len_r[ADDR_W-1:0]] <= wr_data;
	end

	// ─── Read side: 2-cycle pipeline ───────────────────────────────────
	// Stage 0 (req capture): latch base address
	reg [15:0] rd_base_s0;
	reg        rd_pending_s1;  // stage-1 active
	reg        rd_pending_s2;  // stage-2 active
	reg [15:0] rd_base_s1;    // for output registration

	always @(posedge clk) begin
		if (reset || wr_clear) begin
			rd_base_s0   <= 16'd0;
			rd_pending_s1 <= 1'b0;
			rd_pending_s2 <= 1'b0;
			window_valid <= 1'b0;
			window_base  <= 16'd0;
		end else begin
			// New request launches pipeline
			if (req_valid) begin
				rd_base_s0 <= (req_offset >= DEPTH_W)
					? (DEPTH_W - 16'(WINDOW_BYTES))
					: req_offset;
				rd_pending_s1 <= 1'b1;
				window_valid  <= 1'b0;
			end else begin
				rd_pending_s1 <= 1'b0;
			end

			// Stage 1→2 advance
			rd_pending_s2 <= rd_pending_s1;
			if (rd_pending_s1)
				rd_base_s1 <= rd_base_s0;

			// Stage 2: output valid
			if (rd_pending_s2) begin
				window_valid <= 1'b1;
				window_base  <= rd_base_s1;
			end
		end
	end

	// Stage 1: M10K read (address applied, data available next cycle)
	// Stage 2: register output from BRAM read data
	// We use generate to create WINDOW_BYTES read ports.  Each port reads
	// mem[base + k].  The M10K output register captures it in stage 2.
	genvar gk;
	generate
		for (gk = 0; gk < WINDOW_BYTES; gk = gk + 1) begin : g_rd
			reg [7:0] rd_data_s2;
			reg       rd_valid_s2;

			// byte_addr is combinational from rd_base_s0 (stable since cycle 0)
			wire [15:0] byte_addr = rd_base_s0 + 16'(gk);
			wire        in_range  = (byte_addr < len_r) && (byte_addr < DEPTH_W);

			// Stage 1→2: M10K read with combinational address, registered
			// output.  This is the canonical Quartus M10K inference pattern:
			//   always @(posedge clk) q <= mem[addr];
			always @(posedge clk) begin
				if (rd_pending_s1) begin
					rd_data_s2 <= mem[byte_addr[ADDR_W-1:0]];
					rd_valid_s2 <= in_range;
				end
			end

			// Output: latch into window on stage-2 completion
			always @(posedge clk) begin
				if (rd_pending_s2)
					window[gk] <= rd_valid_s2 ? rd_data_s2 : 8'd0;
			end
		end
	endgenerate

	// ─── Outputs ───────────────────────────────────────────────────────
	assign window_avail = (len_r > window_base) ? (len_r - window_base) : 16'd0;
	assign length       = len_r;
	assign complete     = complete_r;
	assign overflow     = overflow_r;
endmodule
