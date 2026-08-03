// Multi-pixel → single-pixel present bridge (P1 architecture).
//
// clk_sys domain accepts up to PX_PER_CLK RGB lanes per beat (fabric parallel
// work). Serialises valid lanes into async_fifo. clk_pix domain drains one
// RGB sample per cycle for MiSTer CE_PIXEL / ascal (1 px per CLK_VIDEO tick).
//
// INCLUDE_SYNC=1 packs {vs,hs,vb,hb,r,g,b} so blanking/sync are pixel-aligned
// on clk_pix (required when clk_pix != clk_sys). Default 0 keeps legacy 24-bit
// RGB-only FIFO (same-clock bring-up / existing TBs).
//
// Product default: NOT instantiated (PRESENT_MULTI_PIXEL undefined).
// CDC: only async_fifo gray pointers cross clk_sys ↔ clk_pix.

module present_npx_path #(
	parameter int PX_PER_CLK   = 4,
	parameter int FIFO_AW      = 6,  // depth 64 words
	parameter bit INCLUDE_SYNC = 1'b0
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
	// Per-group sync sample (sys domain). Replicated onto each expanded lane
	// when INCLUDE_SYNC=1. Defaults keep legacy TBs (RGB-only) compiling.
	input  wire                 in_hblank = 1'b0,
	input  wire                 in_hsync  = 1'b0,
	input  wire                 in_vblank = 1'b0,
	input  wire                 in_vsync  = 1'b0,
	// Backpressure: 1 when a new group can be accepted this cycle.
	output wire                 in_ready,

	// 1 px/clk output (clk_pix)
	output reg                  out_ce,
	output reg  [7:0]           out_r,
	output reg  [7:0]           out_g,
	output reg  [7:0]           out_b,
	output reg                  out_hblank,
	output reg                  out_hsync,
	output reg                  out_vblank,
	output reg                  out_vsync,

	output wire                 wr_full,
	output wire                 wr_almost_full,
	output reg                  rd_underrun,
	output wire                 rd_empty
);
	localparam int RGB_W  = 24;
	localparam int SYNC_W = 4;
	localparam int W      = INCLUDE_SYNC ? (RGB_W + SYNC_W) : RGB_W;

	reg             wr_en;
	reg  [W-1:0]    wr_data;
	wire            fifo_full;
	wire            fifo_almost;
	wire            fifo_empty;
	wire [W-1:0]    rd_data;
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

	reg                     hold_busy;
	assign in_ready = !reset_sys && !hold_busy && !fifo_almost;
	reg  [PX_PER_CLK*8-1:0] hold_r, hold_g, hold_b;
	reg  [PX_PER_CLK-1:0]   hold_valid;
	reg                     hold_hb, hold_hs, hold_vb, hold_vs;
	localparam int LANE_W = (PX_PER_CLK <= 1) ? 1 : $clog2(PX_PER_CLK);
	localparam logic [LANE_W-1:0] LANE_LAST = LANE_W'(PX_PER_CLK - 1);
	reg  [LANE_W-1:0]       lane_idx;

	wire [7:0] lane_r = hold_r[lane_idx*8 +: 8];
	wire [7:0] lane_g = hold_g[lane_idx*8 +: 8];
	wire [7:0] lane_b = hold_b[lane_idx*8 +: 8];
	wire       lane_v = hold_valid[lane_idx];

	wire [RGB_W-1:0] rgb_word = {lane_r, lane_g, lane_b};
	wire [SYNC_W-1:0] sync_word = {hold_vs, hold_hs, hold_vb, hold_hb};

	always @(posedge clk_sys) begin
		if (reset_sys) begin
			hold_busy  <= 1'b0;
			hold_r     <= '0;
			hold_g     <= '0;
			hold_b     <= '0;
			hold_valid <= '0;
			hold_hb    <= 1'b1;
			hold_hs    <= 1'b0;
			hold_vb    <= 1'b1;
			hold_vs    <= 1'b0;
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
					hold_hb    <= in_hblank;
					hold_hs    <= in_hsync;
					hold_vb    <= in_vblank;
					hold_vs    <= in_vsync;
					lane_idx   <= '0;
					hold_busy  <= |in_lane_valid;
				end
			end else begin
				if (lane_v) begin
					if (!fifo_full) begin
						wr_en <= 1'b1;
						if (INCLUDE_SYNC)
							wr_data <= {sync_word, rgb_word};
						else
							wr_data <= rgb_word;
						if (lane_idx == LANE_LAST) begin
							hold_busy <= 1'b0;
							lane_idx  <= '0;
						end else begin
							lane_idx <= lane_idx + 1'b1;
						end
					end
				end else begin
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

	assign rd_en = !reset_pix && !fifo_empty;

	wire [7:0] rd_r = INCLUDE_SYNC ? rd_data[23:16] : rd_data[23:16];
	wire [7:0] rd_g = INCLUDE_SYNC ? rd_data[15:8]  : rd_data[15:8];
	wire [7:0] rd_b = INCLUDE_SYNC ? rd_data[7:0]   : rd_data[7:0];
	// When INCLUDE_SYNC: data = {vs,hs,vb,hb, r,g,b} → [27:24] sync, [23:0] rgb
	wire rd_hb = INCLUDE_SYNC ? rd_data[24] : 1'b0;
	wire rd_vb = INCLUDE_SYNC ? rd_data[25] : 1'b0;
	wire rd_hs = INCLUDE_SYNC ? rd_data[26] : 1'b0;
	wire rd_vs = INCLUDE_SYNC ? rd_data[27] : 1'b0;

	always @(posedge clk_pix) begin
		if (reset_pix) begin
			out_ce     <= 1'b0;
			out_r      <= 8'd0;
			out_g      <= 8'd0;
			out_b      <= 8'd0;
			out_hblank <= 1'b1;
			out_hsync  <= 1'b0;
			out_vblank <= 1'b1;
			out_vsync  <= 1'b0;
			rd_underrun <= 1'b0;
		end else if (rd_en) begin
			out_ce     <= 1'b1;
			out_r      <= rd_r;
			out_g      <= rd_g;
			out_b      <= rd_b;
			out_hblank <= rd_hb;
			out_vblank <= rd_vb;
			out_hsync  <= rd_hs;
			out_vsync  <= rd_vs;
			rd_underrun <= 1'b0;
		end else begin
			out_ce     <= 1'b0;
			// Hold last sync during underrun gaps so HS/VS do not glitch low-Z;
			// RGB goes black (same-clock path used hold for DE gaps).
			out_r      <= 8'd0;
			out_g      <= 8'd0;
			out_b      <= 8'd0;
			rd_underrun <= 1'b0;
		end
	end
endmodule
