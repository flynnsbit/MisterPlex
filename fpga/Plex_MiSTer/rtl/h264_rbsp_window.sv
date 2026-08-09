// Slice RBSP byte store + sliding window (ALM-safe, byte-serial fill).
//
// overnight3: combo banks ~63704 ALMs. overnight4: word fill + dynamic
// window[idx] still ~49671 ALMs. This version writes exactly one window
// entry per cycle via a plain counter — cheap regs + one M10K read port.
//
// LATENCY: WINDOW_BYTES cycles after req_valid (64 for default).

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

	(* ramstyle = "M10K" *)
	reg [7:0] mem [0:DEPTH_BYTES-1];

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
			if (wr_take) begin
				mem[len_r[ADDR_W-1:0]] <= wr_data;
				len_r <= len_r + 16'd1;
			end else if (wr_en) begin
				overflow_r <= 1'b1;
			end
			if (wr_end)
				complete_r <= 1'b1;
		end
	end

	reg               fill_active_r;
	reg [15:0]        base_r;
	reg [IDX_W-1:0]   idx_r;
	// Registered read address for M10K inference (addr then data).
	reg [ADDR_W-1:0]  rd_addr_r;
	reg               rd_ok_r;
	reg               rd_issue_r; // 1 = address presented last cycle; capture now

	wire [15:0] req_base_clamped =
		(req_offset >= DEPTH_W) ? (DEPTH_W - 16'(WINDOW_BYTES)) : req_offset;

	integer bi;
	always @(posedge clk) begin
		if (reset || wr_clear) begin
			fill_active_r <= 1'b0;
			base_r        <= 16'd0;
			idx_r         <= '0;
			rd_addr_r     <= '0;
			rd_ok_r       <= 1'b0;
			rd_issue_r    <= 1'b0;
			window_valid  <= 1'b0;
			window_base   <= 16'd0;
			for (bi = 0; bi < WINDOW_BYTES; bi = bi + 1)
				window[bi] <= 8'd0;
		end else if (req_valid) begin
			fill_active_r <= 1'b1;
			base_r        <= req_base_clamped;
			idx_r         <= '0;
			rd_addr_r     <= req_base_clamped[ADDR_W-1:0];
			rd_ok_r       <= (req_base_clamped < len_r);
			rd_issue_r    <= 1'b1;
			window_valid  <= 1'b0;
		end else if (fill_active_r) begin
			if (rd_issue_r) begin
				// Capture registered M10K read into window[idx]
				window[idx_r] <= rd_ok_r ? mem[rd_addr_r] : 8'd0;
				if (idx_r == IDX_W'(WINDOW_BYTES - 1)) begin
					fill_active_r <= 1'b0;
					rd_issue_r    <= 1'b0;
					window_valid  <= 1'b1;
					window_base   <= base_r;
					idx_r         <= '0;
				end else begin
					// Advance index and present next address this cycle
					idx_r      <= idx_r + 1'b1;
					rd_addr_r  <= (base_r + 16'(idx_r) + 16'd1);
					rd_ok_r    <= ((base_r + 16'(idx_r) + 16'd1) < len_r);
					rd_issue_r <= 1'b1;
				end
			end
		end
	end

	assign window_avail = (len_r > window_base) ? (len_r - window_base) : 16'd0;
	assign length       = len_r;
	assign complete     = complete_r;
	assign overflow     = overflow_r;
endmodule

`default_nettype wire
