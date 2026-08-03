// Multi-pixel → single-pixel present bridge (P1 architecture).
//
// clk_sys domain accepts up to PX_PER_CLK RGB lanes per beat (fabric parallel
// work). Serialises valid lanes into async_fifo. clk_pix domain drains one
// RGB sample per cycle for MiSTer CE_PIXEL / ascal (1 px per CLK_VIDEO tick).
//
// Product default: NOT instantiated (PRESENT_MULTI_PIXEL undefined).
// See MULTI_PIXEL_PRESENT_DESIGN.md §3 P1 and parent correction: modules
// alone ≠ scanout done until top-level wiring + pix clock exist.
//
// CDC: only async_fifo gray pointers cross clk_sys ↔ clk_pix. Do not bare-wire
// multi-bit RGB across domains.

module present_npx_path #(
	parameter int PX_PER_CLK = 4,
	parameter int FIFO_AW    = 6   // depth 64 RGB words
)(
	input  wire                 clk_sys,
	input  wire                 reset_sys,
	input  wire                 clk_pix,
	input  wire                 reset_pix,

	// N-wide input (clk_sys)
	input  wire                 in_valid,
	input  wire [PX_PER_CLK*8-1:0] in_r,
	input  wire [PX_PER_CLK*8-1:0] in_g,
	input  wire [PX_PER_CLK*8-1:0] in_b,
	input  wire [PX_PER_CLK-1:0]   in_lane_valid,
	// Backpressure: 1 when a new group can be accepted this cycle.
	// Same-clock bring-up: throttle beam with in_ready so fill rate ≤ drain.
	output wire                 in_ready,

	// 1 px/clk output (clk_pix) — CE_PIXEL-class
	output reg                  out_ce,
	output reg  [7:0]           out_r,
	output reg  [7:0]           out_g,
	output reg  [7:0]           out_b,

	output wire                 wr_full,
	output wire                 wr_almost_full,
	output reg                  rd_underrun,
	output wire                 rd_empty
);
	// Pack one RGB888 word per FIFO entry.
	localparam int W = 24;

	reg             wr_en;
	reg  [W-1:0]    wr_data;
	wire            fifo_full;
	wire            fifo_almost;
	wire            fifo_empty;
	wire [W-1:0]    rd_data;
	// Combo pop: async_fifo treats rd_en as same-cycle consume against FWFT
	// rd_valid. A registered rd_en would present each word for two cycles
	// (see beat-conservation TB: wr=32 rd=64 with registered request).
	wire            rd_en;

	async_fifo #(
		.WIDTH(W),
		.AW(FIFO_AW)
	) u_pix_fifo (
		.wr_clk(clk_sys),
		.wr_reset(reset_sys),
		.wr_en(wr_en),
		.wr_data(wr_data),
		.wr_full(fifo_full),
		.wr_almost_full(fifo_almost),
		.rd_clk(clk_pix),
		.rd_reset(reset_pix),
		.rd_en(rd_en),
		.rd_data(rd_data),
		.rd_empty(fifo_empty)
	);

	assign wr_full = fifo_full;
	assign wr_almost_full = fifo_almost;
	assign rd_empty = fifo_empty;

	// --- clk_sys: expand N lanes → up to N sequential FIFO writes ------------
	// Simple multi-cycle expander: when in_valid pulses, latch the group and
	// emit one write per cycle for each valid lane (LSB lane first).
	reg                     hold_busy;
	// Accept only when expander idle and FIFO has room for a full group.
	assign in_ready = !reset_sys && !hold_busy && !fifo_almost;
	reg  [PX_PER_CLK*8-1:0] hold_r, hold_g, hold_b;
	reg  [PX_PER_CLK-1:0]   hold_valid;
	// lane_idx only needs to index 0..PX_PER_CLK-1
	localparam int LANE_W = (PX_PER_CLK <= 1) ? 1 : $clog2(PX_PER_CLK);
	localparam logic [LANE_W-1:0] LANE_LAST = LANE_W'(PX_PER_CLK - 1);
	reg  [LANE_W-1:0]       lane_idx;

	wire [7:0] lane_r = hold_r[lane_idx*8 +: 8];
	wire [7:0] lane_g = hold_g[lane_idx*8 +: 8];
	wire [7:0] lane_b = hold_b[lane_idx*8 +: 8];
	wire       lane_v = hold_valid[lane_idx];

	always @(posedge clk_sys) begin
		if (reset_sys) begin
			hold_busy  <= 1'b0;
			hold_r     <= '0;
			hold_g     <= '0;
			hold_b     <= '0;
			hold_valid <= '0;
			lane_idx   <= '0;
			wr_en      <= 1'b0;
			wr_data    <= '0;
		end else begin
			wr_en <= 1'b0;
			if (!hold_busy) begin
				if (in_valid) begin
					hold_r     <= in_r;
					hold_g     <= in_g;
					hold_b     <= in_b;
					hold_valid <= in_lane_valid;
					lane_idx   <= '0;
					hold_busy  <= |in_lane_valid;
				end
			end else begin
				// Emit current lane if valid and FIFO accepts.
				if (lane_v) begin
					if (!fifo_full) begin
						wr_en   <= 1'b1;
						wr_data <= {lane_r, lane_g, lane_b};
						if (lane_idx == LANE_LAST) begin
							hold_busy <= 1'b0;
							lane_idx  <= '0;
						end else begin
							lane_idx <= lane_idx + 1'b1;
						end
					end
					// else stall expander until FIFO has room
				end else begin
					// skip invalid lane
					if (lane_idx == LANE_LAST) begin
						hold_busy <= 1'b0;
						lane_idx  <= '0;
					end else begin
						lane_idx <= lane_idx + 1'b1;
					end
				end
			end
		end
	end

	// --- clk_pix: drain 1 px/clk when data available -------------------------
	// FWFT: rd_data is valid when !rd_empty. Combo rd_en pops one word per
	// cycle; registered out_* captures the pre-NBA FWFT word (one CE per px).
	assign rd_en = !reset_pix && !fifo_empty;

	always @(posedge clk_pix) begin
		if (reset_pix) begin
			out_ce      <= 1'b0;
			out_r       <= 8'd0;
			out_g       <= 8'd0;
			out_b       <= 8'd0;
			rd_underrun <= 1'b0;
		end else if (rd_en) begin
			out_ce      <= 1'b1;
			out_r       <= rd_data[23:16];
			out_g       <= rd_data[15:8];
			out_b       <= rd_data[7:0];
			rd_underrun <= 1'b0;
		end else begin
			out_ce      <= 1'b0;
			out_r       <= 8'd0;
			out_g       <= 8'd0;
			out_b       <= 8'd0;
			rd_underrun <= 1'b0;
		end
	end
endmodule
