// Slice RBSP byte store with a sliding read window (area rewrite).
//
// Single M10K byte RAM + registered WINDOW_BYTES snapshot.
// req_valid starts a WINDOW_BYTES-cycle refill; window_ready is low while
// filling.  Combo 64-lane barrel rotates of the old banked design cost ~33k
// ALUTs — this keeps the window in regs and the store in M10K.

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
	output wire        window_ready
);
	localparam int AW = (DEPTH_BYTES <= 2) ? 1 : $clog2(DEPTH_BYTES);
	localparam [15:0] DEPTH_W = 16'(DEPTH_BYTES);
	localparam int IW = (WINDOW_BYTES <= 2) ? 1 : $clog2(WINDOW_BYTES);

	(* ramstyle = "M10K,no_rw_check" *)
	reg [7:0] mem [0:DEPTH_BYTES-1];

	reg [15:0] len_r;
	reg        complete_r;
	reg        overflow_r;
	reg [15:0] base_r;

	// Fill FSM: IDLE -> ISSUE (addr) -> CAPTURE (data->window) x WINDOW
	localparam [1:0] F_IDLE = 2'd0, F_ISSUE = 2'd1, F_CAP = 2'd2;
	reg [1:0]  f_st;
	reg [IW:0] f_idx;       // 0..WINDOW_BYTES
	reg [15:0] f_addr;
	reg [AW-1:0] rd_addr_r;
	reg [7:0]  rd_data_r;

	wire wr_fits = (len_r < DEPTH_W);
	// Allow writes whenever not in the middle of a same-port conflict: M10K
	// simple dual-port style — we only write in IDLE or when not capturing
	// the same address.  Prefer never write during fill for simplicity.
	wire wr_take = wr_en && wr_fits && (f_st == F_IDLE) && !req_valid;

	wire [15:0] req_base_clamped =
		(req_offset >= DEPTH_W) ? (DEPTH_W - 16'(WINDOW_BYTES)) : req_offset;

	integer wi;

	always @(posedge clk) begin
		if (reset) begin
			len_r <= 16'd0;
			complete_r <= 1'b0;
			overflow_r <= 1'b0;
			base_r <= 16'd0;
			f_st <= F_IDLE;
			f_idx <= '0;
			f_addr <= 16'd0;
			rd_addr_r <= '0;
			rd_data_r <= 8'd0;
			for (wi = 0; wi < WINDOW_BYTES; wi = wi + 1)
				window[wi] <= 8'd0;
		end else begin
			// Default: keep M10K read registered
			rd_data_r <= mem[rd_addr_r];

			if (wr_clear) begin
				len_r <= 16'd0;
				complete_r <= 1'b0;
				overflow_r <= 1'b0;
				base_r <= 16'd0;
				f_st <= F_IDLE;
				f_idx <= '0;
				for (wi = 0; wi < WINDOW_BYTES; wi = wi + 1)
					window[wi] <= 8'd0;
			end else begin
				if (wr_take) begin
					mem[len_r[AW-1:0]] <= wr_data;
					len_r <= len_r + 16'd1;
				end else if (wr_en && (f_st == F_IDLE) && !req_valid && !wr_fits) begin
					overflow_r <= 1'b1;
				end
				if (wr_end)
					complete_r <= 1'b1;

				case (f_st)
				F_IDLE: begin
					if (req_valid) begin
						base_r <= req_base_clamped;
						f_addr <= req_base_clamped;
						f_idx <= '0;
						rd_addr_r <= req_base_clamped[AW-1:0];
						f_st <= F_ISSUE;
					end
				end
				F_ISSUE: begin
					// rd_data_r will hold mem[rd_addr_r] next cycle
					f_st <= F_CAP;
				end
				F_CAP: begin
					if (f_addr < len_r)
						window[f_idx[IW-1:0]] <= rd_data_r;
					else
						window[f_idx[IW-1:0]] <= 8'd0;

					if (f_idx + 1'b1 >= (IW+1)'(WINDOW_BYTES)) begin
						f_st <= F_IDLE;
						f_idx <= '0;
					end else begin
						f_idx <= f_idx + 1'b1;
						f_addr <= f_addr + 16'd1;
						rd_addr_r <= (f_addr + 16'd1);
						f_st <= F_ISSUE;
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
	assign window_ready = (f_st == F_IDLE) && !req_valid;
endmodule

`default_nettype wire
