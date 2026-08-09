// Slice RBSP byte store + sliding window (true dual-port M10K).
//
// ALM history:
//   overnight3 combo banks+rotate  ~63704 map ALMs
//   overnight4 word-fill scatter   ~49671 map ALMs (RAM not inferred; DEPTH=16k
//                                   became ALM regs)
//
// Contract for M10K inference (Quartus 17):
//   * Single write port: mem[waddr] <= wdata on wr
//   * Single registered read port: q <= mem[raddr] every cycle
//   * No reset of mem contents
//   * No read-under-write in same expression as window scatter
//
// Window fill: one byte/cycle from registered q into window[idx].
// LATENCY: WINDOW_BYTES + 2 cycles after req_valid.

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
	output reg  [15:0] window_base,
	output wire [15:0] window_avail,
	output wire [15:0] length,
	output wire        complete,
	output wire        overflow,
	output reg         window_valid
);
	localparam int ADDR_W = (DEPTH_BYTES <= 1) ? 1 : $clog2(DEPTH_BYTES);
	localparam int IDX_W  = (WINDOW_BYTES <= 1) ? 1 : $clog2(WINDOW_BYTES);
	localparam [15:0] DEPTH_W = 16'(DEPTH_BYTES);

	// -------------------------------------------------------------------------
	// Append-only byte RAM (simple dual-port M10K)
	// -------------------------------------------------------------------------
	(* ramstyle = "M10K,no_rw_check" *)
	reg [7:0] mem [0:DEPTH_BYTES-1];

	reg [15:0] len_r;
	reg        complete_r;
	reg        overflow_r;

	wire wr_fits = (len_r < DEPTH_W);
	wire wr_take = wr_en && wr_fits && !wr_clear && !reset;

	// Write port (no mem reset — required for M10K)
	always @(posedge clk) begin
		if (wr_take)
			mem[len_r[ADDR_W-1:0]] <= wr_data;
	end

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

	// Registered read port — always active (Quartus-friendly)
	reg [ADDR_W-1:0] rd_addr_r;
	reg [7:0]        mem_q;
	always @(posedge clk) begin
		mem_q <= mem[rd_addr_r];
	end

	// -------------------------------------------------------------------------
	// Window fill FSM
	// -------------------------------------------------------------------------
	localparam logic [1:0] ST_IDLE  = 2'd0;
	localparam logic [1:0] ST_ISSUE = 2'd1; // present address
	localparam logic [1:0] ST_CAPT  = 2'd2; // capture mem_q into window[idx]
	localparam logic [1:0] ST_DONE  = 2'd3;

	reg [1:0]       st_r;
	reg [15:0]      base_r;
	reg [IDX_W-1:0] idx_r;
	reg             rd_ok_r;

	wire [15:0] req_base_clamped =
		(req_offset >= DEPTH_W) ? (DEPTH_W - 16'(WINDOW_BYTES)) : req_offset;

	integer bi;
	always @(posedge clk) begin
		if (reset || wr_clear) begin
			st_r         <= ST_IDLE;
			base_r       <= 16'd0;
			idx_r        <= '0;
			rd_addr_r    <= '0;
			rd_ok_r      <= 1'b0;
			window_valid <= 1'b0;
			window_base  <= 16'd0;
			for (bi = 0; bi < WINDOW_BYTES; bi = bi + 1)
				window[bi] <= 8'd0;
		end else begin
			case (st_r)
			ST_IDLE: begin
				if (req_valid) begin
					base_r       <= req_base_clamped;
					idx_r        <= '0;
					rd_addr_r    <= req_base_clamped[ADDR_W-1:0];
					rd_ok_r      <= (req_base_clamped < len_r);
					window_valid <= 1'b0;
					st_r         <= ST_ISSUE;
				end
			end
			ST_ISSUE: begin
				// mem_q will hold mem[rd_addr_r] next cycle
				st_r <= ST_CAPT;
			end
			ST_CAPT: begin
				window[idx_r] <= rd_ok_r ? mem_q : 8'd0;
				if (idx_r == IDX_W'(WINDOW_BYTES - 1)) begin
					window_valid <= 1'b1;
					window_base  <= base_r;
					st_r         <= ST_DONE;
				end else begin
					idx_r     <= idx_r + 1'b1;
					rd_addr_r <= (base_r + 16'(idx_r) + 16'd1);
					rd_ok_r   <= ((base_r + 16'(idx_r) + 16'd1) < len_r);
					st_r      <= ST_ISSUE;
				end
			end
			ST_DONE: begin
				// Hold window_valid until next request
				if (req_valid) begin
					base_r       <= req_base_clamped;
					idx_r        <= '0;
					rd_addr_r    <= req_base_clamped[ADDR_W-1:0];
					rd_ok_r      <= (req_base_clamped < len_r);
					window_valid <= 1'b0;
					st_r         <= ST_ISSUE;
				end
			end
			default: st_r <= ST_IDLE;
			endcase
		end
	end

	assign window_avail = (len_r > window_base) ? (len_r - window_base) : 16'd0;
	assign length       = len_r;
	assign complete     = complete_r;
	assign overflow     = overflow_r;
endmodule

`default_nettype wire
