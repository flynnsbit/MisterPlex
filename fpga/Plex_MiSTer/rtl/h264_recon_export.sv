// h264_recon_export.sv — P3-3l5 FPGA→ARM reconstructed I420 export.
//
// Dedicated HPS-DDR region (default 0x30200000), NEVER the present banks at
// 0x30000000. Aliasing present banks would return the ARM's own last write and
// silently look like a working hybrid — that trap is forbidden.
//
// Handshake (PLXO mailbox @ 0x3007F130, magic "PLXO"):
//   ready=1 && torn=0  → bank holds a complete frame; seq advanced
//   torn=1             → mid-frame abort; ARM must fail closed
//   ready=0            → not safe to read (in progress / idle)
//
// Sample stream: byte writes at I420 frame offsets (same packing as DPB:
// Y plane then U then V). Writer coalesces to 64-bit DDR beats.
//
// Expected added HPS bandwidth (paper, 320x240 @ 25 fps): 115200 B * 25
// ≈ 2.88 MB/s FPGA→DDR on top of present traffic. Device-measured fps = UNKNOWN.

module h264_recon_export #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter [31:0] PHYS_BASE = 32'h3020_0000,
	parameter [31:0] BANK_STRIDE = 32'h0004_0000,
	parameter [31:0] MAILBOX_PHYS = 32'h3007_F130,
	parameter [31:0] MAGIC = 32'h504C_584F  // "PLXO"
)(
	input  wire        clk,
	input  wire        reset,

	// Byte sample stream (I420 tightly packed; offset 0 = Y[0])
	input  wire        sample_valid,
	input  wire [31:0] sample_off,
	input  wire [7:0]  sample_data,
	input  wire        frame_start,   // begin filling the inactive bank
	input  wire        frame_done,    // all samples for this frame committed
	input  wire        frame_abort,   // tear — do not publish ready

	// DDR master (shares stream-side arbiter slot via external mux)
	output reg         ddr_want,
	input  wire        ddr_busy,
	output reg   [7:0] ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output reg         ddr_rd,
	output reg  [63:0] ddr_din,
	output reg   [7:0] ddr_be,
	output reg         ddr_we,

	// Debug / status
	output wire        busy,
	output wire [15:0] frames_exported,
	output wire        last_torn
);
	localparam int FRAME_BYTES = FRAME_W * FRAME_H + 2 * ((FRAME_W / 2) * (FRAME_H / 2));
	// Qword (beat) address for PLXO mailbox; DDRAM_ADDR is byte_addr[31:3].
	localparam [28:0] MBOX_Q = MAILBOX_PHYS[31:3];

	localparam [1:0] ST_IDLE    = 2'd0;
	localparam [1:0] ST_FILL    = 2'd1;
	localparam [1:0] ST_FLUSH   = 2'd2;
	localparam [1:0] ST_MBOX    = 2'd3;

	reg [1:0]  state;
	reg        wr_bank;       // bank currently being filled
	reg        pub_bank;      // last published bank
	reg        torn_sticky;
	reg [15:0] seq;
	reg [15:0] frames_q;
	reg        busy_r;
	reg        last_torn_r;

	// Pending qword assemble (byte → 64-bit)
	reg        pq_valid;
	reg [28:0] pq_addr_q;     // qword address (byte_addr[31:3])
	reg [63:0] pq_data;
	reg [7:0]  pq_be;
	reg        pq_bank;

	// Outbound DDR command queue (single slot)
	reg        cmd_valid;
	reg        cmd_is_mbox;
	reg [28:0] cmd_addr;
	reg [63:0] cmd_data;
	reg [7:0]  cmd_be;
	reg        cmd_torn;
	reg        cmd_bank;
	reg [15:0] cmd_seq;

	// Post-fill: need mailbox publish
	reg        need_mbox;
	reg        mbox_torn;
	reg        mbox_bank;
	reg [15:0] mbox_seq;

	assign busy = busy_r;
	assign frames_exported = frames_q;
	assign last_torn = last_torn_r;

	wire [31:0] frame_bytes_u = FRAME_BYTES[31:0];
	wire sample_in_range = sample_valid && (sample_off < frame_bytes_u);
	wire [31:0] sample_abs = (wr_bank ? (PHYS_BASE + BANK_STRIDE) : PHYS_BASE) + sample_off;
	wire [28:0] sample_q = sample_abs[31:3];
	wire [2:0]  sample_lane = sample_off[2:0];
	wire [7:0]  sample_be = 8'b1 << sample_lane;
	wire [63:0] sample_lane_data = {56'd0, sample_data} << {sample_lane, 3'b000};

	wire can_issue = cmd_valid && !ddr_busy;

	// Merge byte into pending qword (same bank/addr) or push previous.
	wire pq_hit = pq_valid && (pq_addr_q == sample_q) && (pq_bank == wr_bank);

	always @(posedge clk) begin
		if (reset) begin
			state        <= ST_IDLE;
			wr_bank      <= 1'b0;
			pub_bank     <= 1'b0;
			torn_sticky  <= 1'b0;
			seq          <= 16'd0;
			frames_q     <= 16'd0;
			busy_r       <= 1'b0;
			last_torn_r  <= 1'b0;
			pq_valid     <= 1'b0;
			pq_addr_q    <= 29'd0;
			pq_data      <= 64'd0;
			pq_be        <= 8'd0;
			pq_bank      <= 1'b0;
			cmd_valid    <= 1'b0;
			cmd_is_mbox  <= 1'b0;
			cmd_addr     <= 29'd0;
			cmd_data     <= 64'd0;
			cmd_be       <= 8'hFF;
			cmd_torn     <= 1'b0;
			cmd_bank     <= 1'b0;
			cmd_seq      <= 16'd0;
			need_mbox    <= 1'b0;
			mbox_torn    <= 1'b0;
			mbox_bank    <= 1'b0;
			mbox_seq     <= 16'd0;
			ddr_want     <= 1'b0;
			ddr_rd       <= 1'b0;
			ddr_we       <= 1'b0;
			ddr_burstcnt <= 8'd1;
			ddr_addr     <= 29'd0;
			ddr_din      <= 64'd0;
			ddr_be       <= 8'hFF;
		end else begin
			// Default: drop single-cycle strobes; hold level want while cmd pending.
			ddr_rd <= 1'b0;
			ddr_we <= 1'b0;
			if (!cmd_valid)
				ddr_want <= 1'b0;

			// Complete in-flight issue
			if (can_issue) begin
				ddr_want     <= 1'b1;
				ddr_burstcnt <= 8'd1;
				ddr_addr     <= cmd_addr;
				ddr_din      <= cmd_data;
				ddr_be       <= cmd_be;
				ddr_we       <= 1'b1;
				ddr_rd       <= 1'b0;
				cmd_valid    <= 1'b0;
				if (cmd_is_mbox) begin
					pub_bank    <= cmd_bank;
					last_torn_r <= cmd_torn;
					if (!cmd_torn) begin
						frames_q <= frames_q + 16'd1;
					end
					busy_r <= 1'b0;
					state  <= ST_IDLE;
				end
			end

			// Frame start: switch fill bank (opposite of last published when possible)
			if (frame_start) begin
				wr_bank     <= ~pub_bank;
				torn_sticky <= 1'b0;
				busy_r      <= 1'b1;
				pq_valid    <= 1'b0;
				need_mbox   <= 1'b0;
				state       <= ST_FILL;
			end

			if (frame_abort && (state == ST_FILL || state == ST_FLUSH)) begin
				torn_sticky <= 1'b1;
			end

			// Accept samples while filling
			if (state == ST_FILL && sample_in_range) begin
				if (pq_valid && !pq_hit) begin
					// Push previous pending qword into cmd if free; else drop sample
					// (fail closed via torn if we cannot drain — mark torn).
					if (!cmd_valid) begin
						cmd_valid   <= 1'b1;
						cmd_is_mbox <= 1'b0;
						cmd_addr    <= pq_addr_q;
						cmd_data    <= pq_data;
						cmd_be      <= pq_be;
						ddr_want    <= 1'b1;
						// start new pending with this sample
						pq_valid  <= 1'b1;
						pq_addr_q <= sample_q;
						pq_bank   <= wr_bank;
						pq_data   <= sample_lane_data;
						pq_be     <= sample_be;
					end else begin
						torn_sticky <= 1'b1; // backpressure tear
					end
				end else if (pq_valid && pq_hit) begin
					pq_data <= pq_data | sample_lane_data;
					pq_be   <= pq_be | sample_be;
				end else begin
					pq_valid  <= 1'b1;
					pq_addr_q <= sample_q;
					pq_bank   <= wr_bank;
					pq_data   <= sample_lane_data;
					pq_be     <= sample_be;
				end
			end

			// Frame done → flush pending then mailbox
			if (state == ST_FILL && frame_done) begin
				state <= ST_FLUSH;
			end

			if (state == ST_FLUSH) begin
				if (pq_valid) begin
					if (!cmd_valid) begin
						cmd_valid   <= 1'b1;
						cmd_is_mbox <= 1'b0;
						cmd_addr    <= pq_addr_q;
						cmd_data    <= pq_data;
						cmd_be      <= pq_be;
						ddr_want    <= 1'b1;
						pq_valid    <= 1'b0;
					end
				end else if (!cmd_valid && !need_mbox) begin
					// Prepare mailbox publish
					if (!torn_sticky)
						seq <= seq + 16'd1;
					need_mbox <= 1'b1;
					mbox_torn <= torn_sticky;
					mbox_bank <= wr_bank;
					mbox_seq  <= torn_sticky ? seq : (seq + 16'd1);
					state     <= ST_MBOX;
				end
			end

			if (state == ST_MBOX && need_mbox && !cmd_valid) begin
				// PLXO: {seq[15:0], reserved[11:0], fmt, torn, bank, ready, magic}
				// ready = !torn; torn as flagged; fmt_yuv=1
				cmd_valid   <= 1'b1;
				cmd_is_mbox <= 1'b1;
				cmd_addr    <= MBOX_Q;
				cmd_be      <= 8'hFF;
				cmd_torn    <= mbox_torn;
				cmd_bank    <= mbox_bank;
				cmd_seq     <= mbox_seq;
				cmd_data    <= {
					mbox_seq,                           // [63:48]
					12'd0,                              // [47:36]
					1'b1,                               // [35] fmt_yuv
					mbox_torn,                          // [34] torn
					mbox_bank,                          // [33] bank
					~mbox_torn,                         // [32] ready
					MAGIC                               // [31:0]
				};
				ddr_want    <= 1'b1;
				need_mbox   <= 1'b0;
			end

			// Ignore unused read data path
			if (ddr_dout_ready) begin
				// no-op
			end
		end
	end
endmodule
