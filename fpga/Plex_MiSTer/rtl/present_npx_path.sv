// Multi-pixel → single-pixel present bridge (P1 architecture).
//
// THROUGHPUT (rd-duck / w-clock confirmed):
//   Old design serialised PPC lanes on clk_sys *before* the FIFO (1 + PPC sys
//   cycles/group) → peak Mpix/s = F_sys * PPC/(1+PPC).
//   At F_sys=20 MHz, PPC=2: 20*2/3 = **13.33 Mpix/s** << 29.7 needed for
//   CEA 720p24. clk_pix alone could not fix that — producer starved the FIFO.
//
//   This revision crosses **whole groups** on the async_fifo (1 write/group on
//   clk_sys when in_ready). Peak groups/s = F_sys → peak Mpix/s = F_sys*PPC
//   (40 Mpix/s @20/PPC2 ≥ 29.7). Unpack to 1 px/clk on clk_pix.
//
// INCLUDE_SYNC=1 packs {vs,hs,vb,hb,lane_valid,r,g,b} per group.
// Default INCLUDE_SYNC=0: {lane_valid,r,g,b}.
//
// rd_underrun: **real** — pulses when clk_pix has started streaming and cannot
// emit a pixel this cycle (empty mid-stream). Never hard-tied 0.
//
// Product default: NOT instantiated (PRESENT_MULTI_PIXEL undefined).
// CDC: only async_fifo gray pointers cross clk_sys ↔ clk_pix.

module present_npx_path #(
	parameter int PX_PER_CLK   = 4,
	parameter int FIFO_AW      = 6,  // depth 64 *groups*
	parameter bit INCLUDE_SYNC = 1'b0
)(
	input  wire                 clk_sys,
	input  wire                 reset_sys,
	input  wire                 clk_pix,
	input  wire                 reset_pix,

	input  wire                 in_valid,
	input  wire [PX_PER_CLK*8-1:0] in_r,
	input  wire [PX_PER_CLK*8-1:0] in_g,
	input  wire [PX_PER_CLK*8-1:0] in_b,
	input  wire [PX_PER_CLK-1:0]   in_lane_valid,
	input  wire                 in_hblank = 1'b0,
	input  wire                 in_hsync  = 1'b0,
	input  wire                 in_vblank = 1'b0,
	input  wire                 in_vsync  = 1'b0,
	output wire                 in_ready,

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
	localparam int LANE_W = (PX_PER_CLK <= 1) ? 1 : $clog2(PX_PER_CLK);
	localparam int RGB_N  = PX_PER_CLK * 8;
	localparam int SYNC_W = 4;
	localparam int W = (INCLUDE_SYNC ? SYNC_W : 0) + PX_PER_CLK + 3 * RGB_N;

	reg             wr_en;
	reg  [W-1:0]    wr_data;
	wire            fifo_full;
	wire            fifo_almost;
	wire            fifo_empty;
	wire [W-1:0]    rd_data;
	reg             rd_en;

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
	assign in_ready = !reset_sys && !fifo_almost;

	always @(posedge clk_sys) begin
		if (reset_sys) begin
			wr_en   <= 1'b0;
			wr_data <= '0;
		end else begin
			wr_en <= 1'b0;
			if (in_valid && in_ready) begin
				wr_en <= 1'b1;
				// pack: { [vs,hs,vb,hb], lane_valid, r, g, b }
				if (INCLUDE_SYNC)
					wr_data <= {in_vsync, in_hsync, in_vblank, in_hblank,
						in_lane_valid, in_r, in_g, in_b};
				else
					wr_data <= {in_lane_valid, in_r, in_g, in_b};
			end
		end
	end

	reg                     hold_busy;
	reg  [LANE_W-1:0]       lane_idx;
	reg  [RGB_N-1:0]        hold_r, hold_g, hold_b;
	reg  [PX_PER_CLK-1:0]   hold_lv;
	reg                     hold_hb, hold_hs, hold_vb, hold_vs;
	reg                     stream_seen;

	wire [7:0] lane_r = hold_r[lane_idx*8 +: 8];
	wire [7:0] lane_g = hold_g[lane_idx*8 +: 8];
	wire [7:0] lane_b = hold_b[lane_idx*8 +: 8];
	wire       lane_v = hold_lv[lane_idx];

	wire [RGB_N-1:0] pop_b  = rd_data[RGB_N-1:0];
	wire [RGB_N-1:0] pop_g  = rd_data[2*RGB_N-1:RGB_N];
	wire [RGB_N-1:0] pop_r  = rd_data[3*RGB_N-1:2*RGB_N];
	wire [PX_PER_CLK-1:0] pop_lv = rd_data[3*RGB_N+PX_PER_CLK-1:3*RGB_N];
	wire pop_hb = INCLUDE_SYNC ? rd_data[3*RGB_N+PX_PER_CLK+0] : 1'b0;
	wire pop_vb = INCLUDE_SYNC ? rd_data[3*RGB_N+PX_PER_CLK+1] : 1'b0;
	wire pop_hs = INCLUDE_SYNC ? rd_data[3*RGB_N+PX_PER_CLK+2] : 1'b0;
	wire pop_vs = INCLUDE_SYNC ? rd_data[3*RGB_N+PX_PER_CLK+3] : 1'b0;

	localparam logic [LANE_W-1:0] LANE_LAST = LANE_W'(PX_PER_CLK - 1);

	always @(posedge clk_pix) begin
		if (reset_pix) begin
			out_ce      <= 1'b0;
			out_r       <= 8'd0;
			out_g       <= 8'd0;
			out_b       <= 8'd0;
			out_hblank  <= 1'b1;
			out_hsync   <= 1'b0;
			out_vblank  <= 1'b1;
			out_vsync   <= 1'b0;
			rd_underrun <= 1'b0;
			hold_busy   <= 1'b0;
			lane_idx    <= '0;
			hold_r      <= '0;
			hold_g      <= '0;
			hold_b      <= '0;
			hold_lv     <= '0;
			hold_hb     <= 1'b1;
			hold_hs     <= 1'b0;
			hold_vb     <= 1'b1;
			hold_vs     <= 1'b0;
			stream_seen <= 1'b0;
			rd_en       <= 1'b0;
		end else begin
			rd_en       <= 1'b0;
			out_ce      <= 1'b0;
			rd_underrun <= 1'b0;

			if (hold_busy) begin
				if (lane_v) begin
					out_ce      <= 1'b1;
					out_r       <= lane_r;
					out_g       <= lane_g;
					out_b       <= lane_b;
					out_hblank  <= hold_hb;
					out_vblank  <= hold_vb;
					out_hsync   <= hold_hs;
					out_vsync   <= hold_vs;
					stream_seen <= 1'b1;
				end else begin
					out_r <= 8'd0;
					out_g <= 8'd0;
					out_b <= 8'd0;
				end
				if (lane_idx == LANE_LAST) begin
					hold_busy <= 1'b0;
					lane_idx  <= '0;
				end else begin
					lane_idx <= lane_idx + 1'b1;
				end
			end else if (!fifo_empty) begin
				rd_en    <= 1'b1;
				hold_r   <= pop_r;
				hold_g   <= pop_g;
				hold_b   <= pop_b;
				hold_lv  <= pop_lv;
				hold_hb  <= pop_hb;
				hold_hs  <= pop_hs;
				hold_vb  <= pop_vb;
				hold_vs  <= pop_vs;
				if (PX_PER_CLK > 1) begin
					lane_idx  <= LANE_W'(1);
					hold_busy <= 1'b1;
				end else begin
					lane_idx  <= '0;
					hold_busy <= 1'b0;
				end
				if (pop_lv[0]) begin
					out_ce      <= 1'b1;
					out_r       <= pop_r[7:0];
					out_g       <= pop_g[7:0];
					out_b       <= pop_b[7:0];
					out_hblank  <= pop_hb;
					out_vblank  <= pop_vb;
					out_hsync   <= pop_hs;
					out_vsync   <= pop_vs;
					stream_seen <= 1'b1;
				end
			end else begin
				out_r <= 8'd0;
				out_g <= 8'd0;
				out_b <= 8'd0;
				if (stream_seen)
					rd_underrun <= 1'b1;
			end
		end
	end
endmodule
