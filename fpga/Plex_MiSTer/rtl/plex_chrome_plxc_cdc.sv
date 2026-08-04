// plex_chrome_plxc_cdc — clk_sys → clk_hdmi PLXC host beat bridge
//
// rd-duck combined-path blocker: sys_top used rising-edge detect
//   plxc_ext_we_d2 & ~plxc_ext_we_d3
// on a multi-cycle host_we burst from plex_chrome_ddr_loader (S_PUSH_LIST /
// S_PUSH_CTRL asserts we=1 every consecutive clk_sys cycle). That collapses
// the whole burst to ONE clk_hdmi pulse; later list words + ctrl are dropped.
// Same-clock loader/host_if TBs cannot see this.
//
// Fix: small async FIFO. Every wr_clk cycle with wr_en=1 && !wr_full enqueues.
// rd_clk dequeues one beat per cycle (rd_we pulse) with coherent multi-bit data.
// Depth is power-of-two; gray-coded pointers.
// Backpressure: wr_full → loader host_ready=0. Loader host_we is COMB valid;
// advance only on valid&&ready same edge as wr_en&&!wr_full. Registered we +
// advance-on-ready drops the fill-last-slot beat (rd-duck on 96e4a50d).
//
// Reset (rd-duck CDC silicon boundary):
//   Canonical async-assert / sync-deassert:
//     1) 2-FF synchronizer: always @(posedge clk or posedge raw_rst)
//        — raw_rst ASYNC-asserts the chain; deassert walks out on local clk.
//     2) Pointer / data FFs: always @(posedge clk or posedge local_rst_sync)
//        if (local_rst_sync) clear;
//        — async clear pin is local_rst_sync ONLY, never raw_rst.
//   Using raw_rst on pointer async pins leaves raw deassertion asynchronous
//   at those pins (recovery/removal risk) even if the body also checks
//   *_rst_sync. Sync-only `if (rst)` inside always @(posedge clk) never
//   samples when clk_hdmi is frozen through RESET — that was the prior
//   stopped-clock drain bug. With the canonical form, frozen rd_clk still
//   async-clears via local_rst_sync rising with raw; deassert waits for
//   post-resume edges.
//
// FAULT_EDGE_DETECT: compile the broken edge path for the red twin TB only.

`timescale 1ns / 1ps
`default_nettype none

module plex_chrome_plxc_cdc #(
	// >= MAX_CMDS+1 (112 list + ctrl). hdmi>sys drains, but depth covers gray lag / brief stalls.
	// M10K LB: DEPTH×72b @128 → width>40 needs ≥2 blocks (256×40+256×40). Not bit-ceil 1.
	// Physical blocks unmeasured (no fit). See plex_chrome.sv M10K header.
	parameter int DEPTH = 128  // power of 2, >= 4
) (
	input  wire        wr_clk,
	input  wire        wr_rst,
	input  wire        wr_en,
	input  wire [7:0]  wr_addr,
	input  wire [63:0] wr_data,
	output wire        wr_full,
	output wire        wr_almost_full,

	input  wire        rd_clk,
	input  wire        rd_rst,
	output reg         rd_we,
	output reg  [7:0]  rd_addr,
	output reg  [63:0] rd_data,
	output wire        rd_empty
);
	localparam int AW = $clog2(DEPTH);

	reg [71:0] mem [0:DEPTH-1];

	// --- write pointer (binary + gray) ---
	reg [AW:0] wr_ptr_bin, wr_ptr_gray;
	reg [AW:0] rd_ptr_gray_w1, rd_ptr_gray_w2;

	// --- read pointer ---
	reg [AW:0] rd_ptr_bin, rd_ptr_gray;
	reg [AW:0] wr_ptr_gray_r1, wr_ptr_gray_r2;

	function automatic [AW:0] bin2gray;
		input [AW:0] b;
		bin2gray = b ^ (b >> 1);
	endfunction

	wire [AW:0] wr_ptr_bin_next = wr_ptr_bin + {{AW{1'b0}}, 1'b1};
	wire [AW:0] rd_ptr_bin_next = rd_ptr_bin + {{AW{1'b0}}, 1'b1};

	wire [AW:0] rd_ptr_bin_w;
	// reconstruct approx binary from synced gray for full check
	// full when next wr gray == {~rd_gray_sync[AW:AW-1], rd_gray_sync[AW-2:0]}
	wire [AW:0] rd_gray_sync = rd_ptr_gray_w2;
	wire [AW:0] wr_gray_sync = wr_ptr_gray_r2;

	assign wr_full = (bin2gray(wr_ptr_bin_next) ==
		{ ~rd_gray_sync[AW:AW-1], rd_gray_sync[AW-2:0] });
	// almost full: two slots or fewer free (conservative)
	wire [AW:0] wr_ptr_bin_p2 = wr_ptr_bin + (AW+1)'(2);
	assign wr_almost_full = wr_full ||
		(bin2gray(wr_ptr_bin_p2) == { ~rd_gray_sync[AW:AW-1], rd_gray_sync[AW-2:0] }) ||
		(bin2gray(wr_ptr_bin_next) == { ~rd_gray_sync[AW:AW-1], rd_gray_sync[AW-2:0] });

	assign rd_empty = (rd_ptr_gray == wr_gray_sync);

	// --- domain-local reset: async assert on raw, 2-FF sync deassert ---
	// ONLY these blocks touch raw *_rst on an async pin.
	reg wr_rst_meta, wr_rst_sync;
	always @(posedge wr_clk or posedge wr_rst) begin
		if (wr_rst) begin
			wr_rst_meta <= 1'b1;
			wr_rst_sync <= 1'b1;
		end else begin
			wr_rst_meta <= 1'b0;
			wr_rst_sync <= wr_rst_meta;
		end
	end

	reg rd_rst_meta, rd_rst_sync;
	always @(posedge rd_clk or posedge rd_rst) begin
		if (rd_rst) begin
			rd_rst_meta <= 1'b1;
			rd_rst_sync <= 1'b1;
		end else begin
			rd_rst_meta <= 1'b0;
			rd_rst_sync <= rd_rst_meta;
		end
	end

	// Write domain pointers: async pin = wr_rst_sync (never raw wr_rst).
	// Assert: wr_rst async-sets wr_rst_sync → this block clears async.
	// Deassert: wr_rst_sync falls on wr_clk only → recovery-safe vs wr_clk.
	always @(posedge wr_clk or posedge wr_rst_sync) begin
		if (wr_rst_sync) begin
			wr_ptr_bin      <= '0;
			wr_ptr_gray     <= '0;
			rd_ptr_gray_w1  <= '0;
			rd_ptr_gray_w2  <= '0;
		end else begin
			rd_ptr_gray_w1 <= rd_ptr_gray;
			rd_ptr_gray_w2 <= rd_ptr_gray_w1;
			if (wr_en && !wr_full) begin
				mem[wr_ptr_bin[AW-1:0]] <= {wr_addr, wr_data};
				wr_ptr_bin  <= wr_ptr_bin_next;
				wr_ptr_gray <= bin2gray(wr_ptr_bin_next);
			end
		end
	end

	// Read domain pointers/outputs: async pin = rd_rst_sync (never raw rd_rst).
	// Frozen clk_hdmi still clears when raw rd_rst asserts (sync chain async-sets).
	always @(posedge rd_clk or posedge rd_rst_sync) begin
		if (rd_rst_sync) begin
			rd_ptr_bin      <= '0;
			rd_ptr_gray     <= '0;
			wr_ptr_gray_r1  <= '0;
			wr_ptr_gray_r2  <= '0;
			rd_we           <= 1'b0;
			rd_addr         <= 8'd0;
			rd_data         <= 64'd0;
		end else begin
			wr_ptr_gray_r1 <= wr_ptr_gray;
			wr_ptr_gray_r2 <= wr_ptr_gray_r1;
			rd_we <= 1'b0;
			if (!rd_empty) begin
				{rd_addr, rd_data} <= mem[rd_ptr_bin[AW-1:0]];
				rd_we       <= 1'b1;
				rd_ptr_bin  <= rd_ptr_bin_next;
				rd_ptr_gray <= bin2gray(rd_ptr_bin_next);
			end
		end
	end

endmodule

// Broken edge-detect twin (red path only). Same ports as product consumer side.
module plex_chrome_plxc_cdc_edge_fault (
	input  wire        wr_clk,   // unused — samples on rd_clk only (the bug)
	input  wire        wr_rst,
	input  wire        wr_en,
	input  wire [7:0]  wr_addr,
	input  wire [63:0] wr_data,
	output wire        wr_full,
	output wire        wr_almost_full,
	input  wire        rd_clk,
	input  wire        rd_rst,
	output wire        rd_we,
	output wire [7:0]  rd_addr,
	output wire [63:0] rd_data,
	output wire        rd_empty
);
	assign wr_full = 1'b0;
	assign wr_almost_full = 1'b0;
	assign rd_empty = 1'b0;
	reg we_d1, we_d2, we_d3;
	reg [7:0] a_d1, a_d2;
	reg [63:0] d_d1, d_d2;
	always @(posedge rd_clk or posedge rd_rst) begin
		if (rd_rst) begin
			we_d1 <= 1'b0; we_d2 <= 1'b0; we_d3 <= 1'b0;
			a_d1 <= 8'd0; a_d2 <= 8'd0;
			d_d1 <= 64'd0; d_d2 <= 64'd0;
		end else begin
			// Unsynchronized multi-bit sample + rising-edge we (product defect class)
			we_d1 <= wr_en;
			we_d2 <= we_d1;
			we_d3 <= we_d2;
			a_d1  <= wr_addr;
			a_d2  <= a_d1;
			d_d1  <= wr_data;
			d_d2  <= d_d1;
		end
	end
	assign rd_we   = we_d2 & ~we_d3;
	assign rd_addr = a_d2;
	assign rd_data = d_d2;
endmodule

`default_nettype wire
