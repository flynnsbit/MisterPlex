// Phase 3.1b: HPS → DDR3 bulk RGB565 → frame_store (bypass SPI F1).
//
// Physical layout (HPS /dev/mem view, same f2sdram window as Menu/ao486):
//   Bank 0: 0x30000000
//   Bank 1: 0x30040000  (256 KiB stride; frame is 153600 B)
// Frame: 320×240 RGB565 little-endian = 76800 pixels = 19200 × 64-bit words.
//
// Protocol:
//   1. ARM writes full frame to bank N via mmap(/dev/mem)
//   2. ARM sets status[12]=1 (start), status[13]=bank
//   3. Rising edge of start_req → DMA-read DDR into frame_store, then swap
//   4. busy is status_in[39]; frames_done increments per completed copy
//
// DDRAM_ADDR is physical[31:3] (64-bit word address). Base 0x30000000 → 0x06000000.
//
// Avalon burst: beats land with DDRAM_DOUT_READY; a small FIFO absorbs them while
// we unpack 4× RGB565 per beat into frame_store (1 pixel/clk).

module ddram_frame_rd #(
	parameter int WIDTH      = 320,
	parameter int HEIGHT     = 240,
	parameter [31:0] PHYS_BASE = 32'h3000_0000,
	parameter int BURST      = 16   // 64-bit beats per Avalon read
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        start_req,   // level; rising edge starts copy
	input  wire        bank_sel,    // 0 → base, 1 → base+0x40000

	output wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output reg   [7:0] DDRAM_BURSTCNT,
	output reg  [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output reg         DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,

	output reg         wr_en,
	output reg  [15:0] wr_pixel,
	output reg         wr_reset_ptr,
	output reg         swap_req,

	output reg         busy,
	output reg  [15:0] frames_done
);

	localparam int PIXELS = WIDTH * HEIGHT;
	localparam int QWORDS = PIXELS / 4; // 19200 for 320×240
	localparam [28:0] BASE_W0 = PHYS_BASE[31:3];
	// bank1 = PHYS_BASE + 0x40000 → word addr
	localparam [28:0] BASE_W1 = PHYS_BASE[31:3] + 29'h8000; // 0x40000/8

	// Beat FIFO: enough for a couple of bursts while unpacking (4 clks/beat)
	localparam int FIFO_AW = 5; // 32 entries
	localparam int FIFO_N  = 1 << FIFO_AW;

	assign DDRAM_CLK = clk;
	assign DDRAM_DIN = 64'd0;
	assign DDRAM_BE  = 8'hFF;
	assign DDRAM_WE  = 1'b0;

	reg [63:0] fifo_mem [0:FIFO_N-1];
	reg [FIFO_AW:0] fifo_wr, fifo_rd; // extra bit for full/empty
	wire [FIFO_AW:0] fifo_level = fifo_wr - fifo_rd;
	wire fifo_empty = (fifo_wr == fifo_rd);
	wire [FIFO_AW-1:0] fifo_wix = fifo_wr[FIFO_AW-1:0];
	wire [FIFO_AW-1:0] fifo_rix = fifo_rd[FIFO_AW-1:0];

	reg [28:0] rd_addr;
	reg [15:0] qwords_issued;  // total beats requested this frame
	reg [15:0] qwords_written; // beats fully unpacked to pixels
	reg [15:0] inflight;       // issued but not yet DOUT_READY
	reg        start_d;
	reg        active;
	reg [1:0]  pix_i;
	reg [63:0] beat_q;
	reg        have_beat;
	reg        need_reset;

	wire [28:0] bank_base = bank_sel ? BASE_W1 : BASE_W0;

	wire [15:0] cur_pix =
		(pix_i == 2'd0) ? beat_q[15:0]  :
		(pix_i == 2'd1) ? beat_q[31:16] :
		(pix_i == 2'd2) ? beat_q[47:32] : beat_q[63:48];

	// Space in FIFO for another full burst?
	wire [FIFO_AW:0] space = FIFO_N[FIFO_AW:0] - fifo_level;
	wire can_issue = active && !DDRAM_BUSY && !DDRAM_RD
		&& (qwords_issued < QWORDS[15:0])
		&& (inflight == 0) // one burst in flight
		&& (space >= BURST[FIFO_AW:0])
		&& !need_reset;

	wire [15:0] remain = QWORDS[15:0] - qwords_issued;
	wire [7:0]  this_burst = (remain >= BURST[15:0]) ? BURST[7:0] : remain[7:0];

	// Combinational next inflight (issue and/or ready same cycle)
	wire        do_issue = can_issue;
	wire [15:0] inf_after_issue = do_issue ? (inflight + {8'd0, this_burst}) : inflight;
	wire        do_ready = DDRAM_DOUT_READY && active;
	wire [15:0] inf_next =
		do_ready ? (inf_after_issue != 0 ? inf_after_issue - 16'd1 : 16'd0)
		         : inf_after_issue;

	always @(posedge clk) begin
		wr_en        <= 1'b0;
		wr_reset_ptr <= 1'b0;
		swap_req     <= 1'b0;
		start_d      <= start_req;

		if (reset) begin
			busy           <= 1'b0;
			active         <= 1'b0;
			frames_done    <= 16'd0;
			DDRAM_RD       <= 1'b0;
			DDRAM_ADDR     <= 29'd0;
			DDRAM_BURSTCNT <= 8'd1;
			fifo_wr        <= 0;
			fifo_rd        <= 0;
			qwords_issued  <= 0;
			qwords_written <= 0;
			inflight       <= 0;
			have_beat      <= 1'b0;
			pix_i          <= 2'd0;
			need_reset     <= 1'b0;
		end else begin
			if (!DDRAM_BUSY)
				DDRAM_RD <= 1'b0;

			// --- start ---
			if (start_req && !start_d && !active) begin
				active         <= 1'b1;
				busy           <= 1'b1;
				rd_addr        <= bank_base;
				qwords_issued  <= 0;
				qwords_written <= 0;
				inflight       <= 0;
				fifo_wr        <= 0;
				fifo_rd        <= 0;
				have_beat      <= 1'b0;
				pix_i          <= 2'd0;
				need_reset     <= 1'b1;
			end else begin
				// --- reset ptr pulse ---
				if (need_reset) begin
					wr_reset_ptr <= 1'b1;
					need_reset   <= 1'b0;
				end

				// --- issue burst ---
				if (do_issue) begin
					DDRAM_ADDR     <= rd_addr;
					DDRAM_BURSTCNT <= this_burst;
					DDRAM_RD       <= 1'b1;
					rd_addr        <= rd_addr + {21'd0, this_burst};
					qwords_issued  <= qwords_issued + {8'd0, this_burst};
				end

				// --- push beats into FIFO ---
				if (do_ready) begin
					fifo_mem[fifo_wix] <= DDRAM_DOUT;
					fifo_wr <= fifo_wr + 1'd1;
				end

				inflight <= (start_req && !start_d && !active) ? 16'd0 : inf_next;

				// --- pop FIFO → 4 pixels ---
				if (active && !need_reset) begin
					if (!have_beat) begin
						if (!fifo_empty) begin
							beat_q    <= fifo_mem[fifo_rix];
							fifo_rd   <= fifo_rd + 1'd1;
							have_beat <= 1'b1;
							pix_i     <= 2'd0;
						end
					end else begin
						wr_pixel <= cur_pix;
						wr_en    <= 1'b1;
						if (pix_i == 2'd3) begin
							have_beat <= 1'b0;
							qwords_written <= qwords_written + 16'd1;
							if (qwords_written + 16'd1 == QWORDS[15:0]) begin
								swap_req    <= 1'b1;
								frames_done <= frames_done + 16'd1;
								active      <= 1'b0;
								busy        <= 1'b0;
							end
						end else
							pix_i <= pix_i + 2'd1;
					end
				end
			end
		end
	end

endmodule
