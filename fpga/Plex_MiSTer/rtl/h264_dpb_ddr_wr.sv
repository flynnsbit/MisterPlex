// DDR-resident DPB write path.
//
// Consumes the POST-deblock reconstructed sample stream as byte writes
// (wr_en/wr_addr/wr_data, plane-linear I420 byte offset inside a frame bank)
// and turns it into 64-bit DDR write commands on the MiSTer ddram convention
// (busy / burstcnt / addr[28:0] word index / din / be / we).
//
// WHY COALESCING IS EXACT HERE
// ---------------------------
// h264_dpb_mb_write_addr emits, for one macroblock row segment:
//   luma   : base = current_base + (mb_y*16 + row)*FRAME_W + mb_x*16, 16 bytes
//   chroma : base = plane_off    + (mb_y*8  + row)*(FRAME_W/2) + mb_x*8, 8 bytes
// FRAME_W = 624 and FRAME_W/2 = 312 are both multiples of 8, and mb_x*16 /
// mb_x*8 are multiples of 8, so every emitted run starts 8-byte aligned and is
// a whole number of 64-bit words.  The coalescer therefore produces BE=8'hFF
// full-word writes and never needs a read-modify-write cycle.  The byte-enable
// path is still implemented because unaligned runs are legal on the port
// contract (partition-level writes, cropped widths) and must not corrupt the
// neighbouring bytes of a shared word.
//
// Idiom sources: MiSTer sys/ddram.sv command shape (single-cycle WE strobe,
// every FSM transition gated on !busy), and the posted-write channel of
// PSX_MiSTer/rtl/ddram.sv (fire-and-forget writes, burst=1) so that the
// decoder never blocks on DDR write completion.
//
// The staging word is flushed when the incoming address leaves the staged
// 64-bit word, when the FIFO must be drained at a frame boundary (flush), or
// when the caller retires the frame.  wr_full is the only backpressure the
// decoder ever sees; it is asserted a slot early so a write already in flight
// is always accepted.

module h264_dpb_ddr_wr #(
	// Physical byte base of the DPB region in DDR3.  Kept above the
	// ddr_frame_store presentation banks (0x30000000..0x300FFFFF) so the two
	// stores never alias.
	parameter [31:0] DDR_BASE   = 32'h3040_0000,
	parameter int    FIFO_DEPTH = 64
) (
	input  wire        clk,
	input  wire        reset,

	// Byte-granular write port (post-deblock samples).
	input  wire        wr_en,
	input  wire [31:0] wr_addr,
	input  wire  [7:0] wr_data,
	output wire        wr_full,

	// Retire the staging word and drain the FIFO.  wr_idle rises only when the
	// staging word is empty AND the FIFO is empty AND no command is in flight,
	// i.e. every accepted byte is visible in DDR.
	input  wire        flush,
	output wire        wr_idle,

	// DDR master (write-only side of the shared port).
	input  wire        ddr_busy,
	output reg   [7:0] ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	output reg  [63:0] ddr_din,
	output reg   [7:0] ddr_be,
	output reg         ddr_we,
	// Raised while this path wants the shared DDR port; the top level
	// arbitrates it against the read path.
	output wire        ddr_req,
	input  wire        ddr_grant
);
	localparam int PTRW = $clog2(FIFO_DEPTH);
	localparam [28:0] BASE_W = DDR_BASE[31:3];

	// ---------------------------------------------------------------- stage
	// One 64-bit word under construction plus its byte-enable mask.
	reg [28:0] stage_word;
	reg [63:0] stage_data;
	reg  [7:0] stage_be;
	wire       stage_dirty = |stage_be;

	wire [28:0] in_word   = wr_addr[31:3];
	wire  [2:0] in_byte   = wr_addr[2:0];
	wire        same_word = stage_dirty && (in_word == stage_word);

	// ----------------------------------------------------------------- fifo
	// Posted-write queue.  Depth is sized so an entire macroblock luma row pair
	// can be absorbed while the read path holds the DDR port.
	// Consumer: command-issue FSM reads head on posedge into ddr_addr/din/be
	// (registered outputs). M10K sync read matches that NBA pattern — no extra
	// cycle vs LUTRAM. Do not combo-index these arrays outside the clocked block.
	(* ramstyle = "M10K, no_rw_check" *) reg [28:0] fifo_word [0:FIFO_DEPTH-1];
	(* ramstyle = "M10K, no_rw_check" *) reg [63:0] fifo_data [0:FIFO_DEPTH-1];
	(* ramstyle = "M10K, no_rw_check" *) reg  [7:0] fifo_be   [0:FIFO_DEPTH-1];
	reg [PTRW:0] fifo_wp;
	reg [PTRW:0] fifo_rp;

	wire [PTRW:0] fifo_level = fifo_wp - fifo_rp;
	wire fifo_empty = (fifo_wp == fifo_rp);
	wire fifo_full  = (fifo_level >= FIFO_DEPTH[PTRW:0]);
	// Leave one slot of headroom: the staging word may have to be evicted on
	// the same cycle a new byte arrives.
	assign wr_full = (fifo_level >= (FIFO_DEPTH[PTRW:0] - 1'b1));

	// A push happens when the staging word is evicted, either because the
	// incoming byte belongs to a different word or because of an explicit
	// flush.
	wire evict_for_new = wr_en && stage_dirty && !same_word;
	wire evict_for_flush = flush && stage_dirty;
	wire do_push = evict_for_new || evict_for_flush;

	// -------------------------------------------------------------- command
	reg cmd_busy;

	assign ddr_req = !fifo_empty || cmd_busy;

	always @(posedge clk) begin
		if (reset) begin
			stage_word   <= 29'd0;
			stage_data   <= 64'd0;
			stage_be     <= 8'd0;
			fifo_wp      <= '0;
			fifo_rp      <= '0;
			cmd_busy     <= 1'b0;
			ddr_we       <= 1'b0;
			ddr_addr     <= 29'd0;
			ddr_din      <= 64'd0;
			ddr_be       <= 8'd0;
			ddr_burstcnt <= 8'd1;
		end else begin
			ddr_we <= 1'b0;

			// ---- staging / eviction
			if (do_push && !fifo_full) begin
				fifo_word[fifo_wp[PTRW-1:0]] <= stage_word;
				fifo_data[fifo_wp[PTRW-1:0]] <= stage_data;
				fifo_be  [fifo_wp[PTRW-1:0]] <= stage_be;
				fifo_wp <= fifo_wp + 1'b1;
			end

			if (wr_en) begin
				if (same_word) begin
					stage_data[8*in_byte +: 8] <= wr_data;
					stage_be[in_byte]          <= 1'b1;
				end else begin
					// Start a fresh word; the old one was pushed above (or was
					// clean and can be discarded).
					stage_word <= in_word;
					stage_data <= {56'd0, wr_data} << (8 * in_byte);
					stage_be   <= (8'd1 << in_byte);
				end
			end else if (evict_for_flush) begin
				stage_be <= 8'd0;
			end

			// ---- command issue
			// Single-beat posted writes.  ddr_we is a one-cycle strobe and is
			// only raised while the shared port is granted and not busy, which
			// is the contract every MiSTer sys/ddram.sv wrapper enforces.
			if (!ddr_busy) begin
				if (cmd_busy) begin
					cmd_busy <= 1'b0;
				end else if (ddr_grant && !fifo_empty) begin
					ddr_addr     <= BASE_W + fifo_word[fifo_rp[PTRW-1:0]];
					ddr_din      <= fifo_data[fifo_rp[PTRW-1:0]];
					ddr_be       <= fifo_be  [fifo_rp[PTRW-1:0]];
					ddr_burstcnt <= 8'd1;
					ddr_we       <= 1'b1;
					fifo_rp      <= fifo_rp + 1'b1;
					cmd_busy     <= 1'b1;
				end
			end
		end
	end

	assign wr_idle = fifo_empty && !stage_dirty && !cmd_busy && !ddr_we;
endmodule
