// DDR-resident decoded picture buffer.
//
// This is the memory the H.264 inter predictor reads from and the deblocking
// filter writes into.  It owns three things:
//
//   1. the write path  (h264_dpb_ddr_wr) : post-deblock samples -> DDR3
//   2. the read path   (h264_dpb_ddr_rd) : DDR3 -> MC reference window cache
//   3. the frame swap  (below)           : current/reference bank ping-pong,
//                                          sequenced so the swap is coherent
//
// WHY DDR AND NOT M10K
//   One I420 624x480 picture is 624*480 + 2*(312*240) = 449280 bytes =
//   3,594,240 bits.  The DE10-Nano 5CSEBA6 has 553 M10K blocks = 5,662,720
//   bits in total.  A single reference picture is already 63% of every block
//   RAM bit on the device, and the decoder needs a reference AND a
//   reconstruction target simultaneously: 7,188,480 bits, which is 127% of the
//   device.  On-chip is not merely tight, it does not fit.  Retiring
//   decode_stub does not change this, because decode_stub's 2,097,152 bits are
//   themselves one DPB RAM and a real decoder needs a bigger one.
//
// PORT CONTRACT FOR OTHER WORKERS
//   Reference reads:
//     ref_rd_en, ref_rd_addr[31:0], ref_rd_stall, ref_rd_data[7:0], ref_rd_valid
//     Hold ref_rd_en/ref_rd_addr stable while ref_rd_stall is high.  ref_rd_valid
//     strobes exactly one cycle after an accepted (ref_rd_en && !ref_rd_stall)
//     cycle and carries the byte on ref_rd_data.
//   Reconstruction writes (POST-deblock only):
//     rec_wr_en, rec_wr_addr[31:0], rec_wr_data[7:0], rec_wr_full
//     Do not assert rec_wr_en while rec_wr_full.
//   Frame boundary:
//     frame_done_req in, frame_done_ack out, swap_busy out,
//     current_base/reference_base out, ref_ready out, idr_start in.
//
// PRE- vs POST-DEBLOCK
//   Only the deblocked sample stream is ever presented on rec_wr_*.  Intra
//   prediction neighbour taps do NOT come from here; they read the
//   pre-deblocking reconstruction held in h264_intra_nb_ctx.  Keeping intra
//   neighbours out of this module is what preserves that distinction.
//
// ARBITRATION
//   One shared DDR master port, round-robin at transaction granularity between
//   the read burst and the posted write command.  The read path only asserts
//   its request for the duration of a burst, so a long run of reference misses
//   can never starve the write queue, and the write queue is posted so the
//   decoder never blocks on DDR completion.  This is the jtframe_sdram_mux
//   pattern (one selected owner at a time, owner released when its transaction
//   retires) reduced to two slots.
//
// FRAME SWAP SEQUENCING
//   frame_done_req -> flush the write staging word and drain the posted write
//   FIFO -> invalidate the reference cache -> move the bank pointers ->
//   frame_done_ack.  Downstream logic that keeps its own bank pointers (the
//   h264_dpb_one_ref address generator) must be clocked from frame_done_ack,
//   not from the raw request, or it will start reading the new reference bank
//   while the last writes to it are still queued.

module h264_dpb_ddr #(
	parameter int    FRAME_W     = 624,
	parameter int    FRAME_H     = 480,
	// Byte base of the DPB region in DDR3.  Above the ddr_frame_store
	// presentation banks (0x30000000..0x300FFFFF) so the two never alias.
	parameter [31:0] DDR_BASE    = 32'h3040_0000,
	// Frame bank stride.  Must match the address generator feeding
	// rec_wr_addr / ref_rd_addr.  449280 = one I420 624x480 picture.
	parameter int    BANK_STRIDE = 449280,
	parameter int    WR_FIFO_DEPTH = 64
) (
	input  wire        clk,
	input  wire        reset,

	// ---------------- frame / bank control
	input  wire        idr_start,
	input  wire        frame_done_req,
	output reg         frame_done_ack,
	output wire        swap_busy,
	output reg         ref_ready,
	output reg  [31:0] current_base,
	output reg  [31:0] reference_base,

	// ---------------- reconstruction write port (POST-deblock)
	input  wire        rec_wr_en,
	input  wire [31:0] rec_wr_addr,
	input  wire  [7:0] rec_wr_data,
	output wire        rec_wr_full,

	// ---------------- reference read port (motion compensation)
	input  wire        ref_rd_en,
	input  wire [31:0] ref_rd_addr,
	output wire        ref_rd_stall,
	output wire  [7:0] ref_rd_data,
	output wire        ref_rd_valid,

	// ---------------- shared DDR master (MiSTer sys/ddram.sv convention)
	input  wire        ddr_busy,
	output reg   [7:0] ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output reg         ddr_rd,
	output reg  [63:0] ddr_din,
	output reg   [7:0] ddr_be,
	output reg         ddr_we
);
	localparam [31:0] BANK0_BASE = 32'd0;
	localparam [31:0] BANK1_BASE = BANK_STRIDE[31:0];

	// ------------------------------------------------------------ sub-paths
	wire        wr_flush;
	wire        wr_idle;
	wire  [7:0] w_burstcnt;
	wire [28:0] w_addr;
	wire [63:0] w_din;
	wire  [7:0] w_be;
	wire        w_we;
	wire        w_req;
	reg         w_grant;

	h264_dpb_ddr_wr #(
		.DDR_BASE(DDR_BASE),
		.FIFO_DEPTH(WR_FIFO_DEPTH)
	) u_wr (
		.clk(clk),
		.reset(reset),
		.wr_en(rec_wr_en),
		.wr_addr(rec_wr_addr),
		.wr_data(rec_wr_data),
		.wr_full(rec_wr_full),
		.flush(wr_flush),
		.wr_idle(wr_idle),
		.ddr_busy(ddr_busy),
		.ddr_burstcnt(w_burstcnt),
		.ddr_addr(w_addr),
		.ddr_din(w_din),
		.ddr_be(w_be),
		.ddr_we(w_we),
		.ddr_req(w_req),
		.ddr_grant(w_grant)
	);

	reg         cache_invalidate;
	wire  [7:0] r_burstcnt;
	wire [28:0] r_addr;
	wire        r_rd;
	wire        r_req;
	reg         r_grant;

	h264_dpb_ddr_rd #(
		.DDR_BASE(DDR_BASE)
	) u_rd (
		.clk(clk),
		.reset(reset),
		.rd_en(ref_rd_en),
		.rd_addr(ref_rd_addr),
		.rd_stall(ref_rd_stall),
		.rd_data(ref_rd_data),
		.rd_valid(ref_rd_valid),
		.invalidate(cache_invalidate),
		.ddr_busy(ddr_busy),
		.ddr_burstcnt(r_burstcnt),
		.ddr_addr(r_addr),
		.ddr_dout(ddr_dout),
		.ddr_dout_ready(ddr_dout_ready),
		.ddr_rd(r_rd),
		.ddr_req(r_req),
		.ddr_grant(r_grant)
	);

	// ---------------------------------------------------------- arbitration
	localparam [1:0] OWN_NONE = 2'd0;
	localparam [1:0] OWN_RD   = 2'd1;
	localparam [1:0] OWN_WR   = 2'd2;

	reg [1:0] own;
	reg       last_rd;

	always @(posedge clk) begin
		if (reset) begin
			own     <= OWN_NONE;
			last_rd <= 1'b0;
		end else begin
			case (own)
			OWN_NONE: begin
				// Round robin: whoever did not go last wins a tie.  Reads are
				// latency-critical so they win when nothing went last.
				if (r_req && !(last_rd && w_req)) own <= OWN_RD;
				else if (w_req)                   own <= OWN_WR;
				else if (r_req)                   own <= OWN_RD;
			end
			OWN_RD: if (!r_req) begin
				own     <= OWN_NONE;
				last_rd <= 1'b1;
			end
			OWN_WR: if (!w_req) begin
				own     <= OWN_NONE;
				last_rd <= 1'b0;
			end
			default: own <= OWN_NONE;
			endcase
		end
	end

	always @* begin
		r_grant = (own == OWN_RD);
		w_grant = (own == OWN_WR);
	end

	always @* begin
		if (own == OWN_RD) begin
			ddr_burstcnt = r_burstcnt;
			ddr_addr     = r_addr;
			ddr_rd       = r_rd;
			ddr_din      = 64'd0;
			ddr_be       = 8'hFF;
			ddr_we       = 1'b0;
		end else if (own == OWN_WR) begin
			ddr_burstcnt = w_burstcnt;
			ddr_addr     = w_addr;
			ddr_rd       = 1'b0;
			ddr_din      = w_din;
			ddr_be       = w_be;
			ddr_we       = w_we;
		end else begin
			ddr_burstcnt = 8'd1;
			ddr_addr     = 29'd0;
			ddr_rd       = 1'b0;
			ddr_din      = 64'd0;
			ddr_be       = 8'hFF;
			ddr_we       = 1'b0;
		end
	end

	// ------------------------------------------------------------ frame swap
	localparam [1:0] SW_IDLE  = 2'd0;
	localparam [1:0] SW_FLUSH = 2'd1;
	localparam [1:0] SW_DRAIN = 2'd2;
	localparam [1:0] SW_COMMIT = 2'd3;

	reg [1:0] swap_state;
	assign swap_busy = (swap_state != SW_IDLE);
	reg  swap_flush_r;
	assign wr_flush = swap_flush_r;

	always @(posedge clk) begin
		if (reset) begin
			swap_state       <= SW_IDLE;
			swap_flush_r     <= 1'b0;
			cache_invalidate <= 1'b0;
			frame_done_ack   <= 1'b0;
			ref_ready        <= 1'b0;
			current_base     <= BANK0_BASE;
			reference_base   <= BANK1_BASE;
		end else begin
			swap_flush_r     <= 1'b0;
			cache_invalidate <= 1'b0;
			frame_done_ack   <= 1'b0;

			// An IDR clears the reference: nothing decoded before it may be
			// predicted from.
			if (idr_start) begin
				ref_ready        <= 1'b0;
				cache_invalidate <= 1'b1;
			end

			case (swap_state)
			SW_IDLE: begin
				if (frame_done_req) begin
					swap_flush_r <= 1'b1;
					swap_state   <= SW_FLUSH;
				end
			end
			SW_FLUSH: begin
				// One cycle for the staging word to be retired into the FIFO.
				swap_state <= SW_DRAIN;
			end
			SW_DRAIN: begin
				// Every accepted sample must be visible in DDR before the bank
				// the MC path is about to read becomes the reference.
				if (wr_idle) begin
					cache_invalidate <= 1'b1;
					swap_state       <= SW_COMMIT;
				end
			end
			SW_COMMIT: begin
				reference_base <= current_base;
				current_base   <= (current_base == BANK0_BASE) ? BANK1_BASE : BANK0_BASE;
				ref_ready      <= 1'b1;
				frame_done_ack <= 1'b1;
				swap_state     <= SW_IDLE;
			end
			default: swap_state <= SW_IDLE;
			endcase
		end
	end
endmodule
