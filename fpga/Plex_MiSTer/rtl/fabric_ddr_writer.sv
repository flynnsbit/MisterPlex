// fabric_ddr_writer — fabric-side I420 bank fill + doorbell (zero ARM pixels).
//
// Macro: FABRIC_DDR_WRITER (default OFF). Product Plex.sv must not instantiate
// this unless the macro is defined — keeps w-nostub fits stable.
//
// Geometry is parameter-only (ddr_frame_layout_params.svh constants). 624x480
// and 1280x720 are parameter sets, never a code fork. PHYS_BASE / DOORBELL_PHYS
// are parameters so Option-C base can move after parent /proc/iomem.
//
// Pixel-source contract (pluggable: test pattern / idle / future decode):
//   src_valid/src_ready, 64-bit qword beats of planar I420 bank order
//   (Y plane then U then V, packed little-endian bytes in each qword).
//   src_frame_start must be high with the first beat of a frame.
//   src_bank is sampled on that first accepted beat.
//
// Doorbell ordering (tearing class):
//   1) Accept and issue every payload qword write into the active bank.
//   2) WRITE_DRAIN_CYCLES fence after last payload command accepted
//      (f2sdram has no write response — drain is the visibility fence).
//   3) Exactly one doorbell write: DIN={hi, PLXK} at DOORBELL_PHYS.
//   4) frame_done pulses after doorbell command is accepted.
//
// Burst / rate arithmetic (clk_ddr = 90 MHz, 8 B/qword, BURSTCNT=1):
//   720p24: 1_382_400 B * 24 = 33.18 MB/s → 4.15 Mqword/s → 4.6% of 90 MHz
//   720p30: 1_382_400 B * 30 = 41.47 MB/s → 5.18 Mqword/s → 5.8% of 90 MHz
//   Scanout read upper @60 Hz full I420: ~82.9 MB/s
//   Combined ~124 MB/s → ~15.5 Mqword/s → ~17% of 90 MHz peak
//   ⇒ Rate closes with outstanding depth = 1 write command.
//   If arbiter grant falls below ~6% writer share @30fps, rate does NOT close
//   — surface that; do not silently assume grant.
//
// Coordination (paper — w-clock / w-scaler):
//   Writer: clk_ddr master, fills coded banks, rings doorbell.
//   w-scaler: content-window READ path only; does not share this write port.
//   w-clock: multi-pixel present is read-side; no shared regs with writer.
//   Integration: third arbiter master or idle-slot mux — separate fit item.
//
`default_nettype none

module fabric_ddr_writer #(
	parameter int CODED_W = 1280,
	parameter int CODED_H = 720,
	parameter [31:0] PHYS_BASE = 32'h3018_0000,
	parameter int HPS_BANK_STRIDE_BYTES = 32'h0018_0000,
	parameter [31:0] DOORBELL_PHYS = 32'h3047_F000,
	parameter int WRITE_DRAIN_CYCLES = 16,
	parameter [31:0] DOORBELL_MAGIC = 32'h504C584B, // PLXK
	parameter [1:0] DOORBELL_FORMAT_YUV420P = 2'd1
)(
	input  wire        clk,
	input  wire        reset,

	// Pixel source — 64-bit planar I420 qword stream
	input  wire        src_valid,
	output wire        src_ready,
	input  wire [63:0] src_data,
	input  wire        src_frame_start,
	input  wire        src_bank,

	// DDRAM master (write-only)
	output wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output reg   [7:0] DDRAM_BURSTCNT,
	output reg  [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output reg         DDRAM_RD,
	output reg  [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output reg         DDRAM_WE,

	output wire        busy,
	output reg         frame_done,
	output reg  [28:0] dbg_seq,
	output reg         dbg_last_bank,
	output reg  [2:0]  dbg_state
);

	localparam int FRAME_BYTES  = (CODED_W * CODED_H * 3) / 2;
	localparam int FRAME_QWORDS = FRAME_BYTES / 8;

	localparam [28:0] BASE_Q     = PHYS_BASE[31:3];
	localparam [28:0] STRIDE_Q   = 29'(unsigned'(HPS_BANK_STRIDE_BYTES) / 8);
	localparam [28:0] DOORBELL_Q = DOORBELL_PHYS[31:3];

	localparam [2:0] ST_IDLE     = 3'd0;
	localparam [2:0] ST_RUN      = 3'd1;
	localparam [2:0] ST_DRAIN    = 3'd2;
	localparam [2:0] ST_DOORBELL = 3'd3;

	reg [2:0]  state;
	reg        bank_r;
	reg [28:0] seq_r;
	reg [31:0] q_left;     // payload qwords still to accept from source
	reg [28:0] wr_addr_q;
	reg [15:0] drain_cnt;

	// Skid holds one accepted source beat until DDR takes the write.
	reg        skid_valid;
	reg [63:0] skid_data;

	assign DDRAM_CLK = clk;
	assign DDRAM_BE  = 8'hFF;
	assign busy      = (state != ST_IDLE);
	assign dbg_state = state;

	wire issue_ok = !DDRAM_BUSY;

	// In IDLE: ready for a frame_start beat.
	// In RUN: ready when we still need beats and skid can take one this cycle.
	wire skid_fire = (state == ST_RUN) && skid_valid && issue_ok;
	assign src_ready =
		(state == ST_IDLE) ||
		((state == ST_RUN) && (q_left != 32'd0) && (!skid_valid || skid_fire));

	wire _unused = &{1'b0, DDRAM_DOUT, DDRAM_DOUT_READY};

	wire [31:0] db_hi = {bank_r, DOORBELL_FORMAT_YUV420P, seq_r};

	always @(posedge clk) begin
		if (reset) begin
			state          <= ST_IDLE;
			bank_r         <= 1'b0;
			seq_r          <= 29'd0;
			q_left         <= 32'd0;
			wr_addr_q      <= 29'd0;
			drain_cnt      <= 16'd0;
			skid_valid     <= 1'b0;
			skid_data      <= 64'd0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_ADDR     <= 29'd0;
			DDRAM_RD       <= 1'b0;
			DDRAM_DIN      <= 64'd0;
			DDRAM_WE       <= 1'b0;
			frame_done     <= 1'b0;
			dbg_seq        <= 29'd0;
			dbg_last_bank  <= 1'b0;
		end else begin
			frame_done <= 1'b0;
			DDRAM_RD   <= 1'b0;
			DDRAM_WE   <= 1'b0;

			case (state)
			ST_IDLE: begin
				skid_valid <= 1'b0;
				if (src_valid && src_frame_start && src_ready) begin
					bank_r     <= src_bank;
					seq_r      <= seq_r + 29'd1;
					// First beat consumed into skid; remaining = total-1.
					q_left     <= 32'(FRAME_QWORDS - 1);
					wr_addr_q  <= BASE_Q + (src_bank ? STRIDE_Q : 29'd0);
					skid_valid <= 1'b1;
					skid_data  <= src_data;
					state      <= ST_RUN;
				end
			end

			ST_RUN: begin
				// Combinational intent for this cycle:
				// 1) If skid_fire: issue write from skid.
				// 2) Source may refill skid if q_left>0 and ready.
				if (skid_fire) begin
					DDRAM_ADDR     <= wr_addr_q;
					DDRAM_BURSTCNT <= 8'd1;
					DDRAM_DIN      <= skid_data;
					DDRAM_WE       <= 1'b1;
					wr_addr_q      <= wr_addr_q + 29'd1;

					if (src_valid && src_ready && (q_left != 32'd0)) begin
						skid_valid <= 1'b1;
						skid_data  <= src_data;
						q_left     <= q_left - 32'd1;
					end else begin
						skid_valid <= 1'b0;
						// If no more source expected and skid empties → drain.
						if (q_left == 32'd0) begin
							drain_cnt <= (WRITE_DRAIN_CYCLES > 0) ?
							             16'(WRITE_DRAIN_CYCLES) : 16'd0;
							state     <= ST_DRAIN;
						end
					end
				end else if (!skid_valid && src_valid && src_ready &&
				            (q_left != 32'd0)) begin
					skid_valid <= 1'b1;
					skid_data  <= src_data;
					q_left     <= q_left - 32'd1;
				end
			end

			ST_DRAIN: begin
				if (drain_cnt != 16'd0)
					drain_cnt <= drain_cnt - 16'd1;
				else
					state <= ST_DOORBELL;
			end

			ST_DOORBELL: begin
				if (issue_ok) begin
					DDRAM_ADDR     <= DOORBELL_Q;
					DDRAM_BURSTCNT <= 8'd1;
					// DIN[31:0]=magic, DIN[63:32]=hi — matches ddram_frame_rd.
					DDRAM_DIN      <= {db_hi, DOORBELL_MAGIC};
					DDRAM_WE       <= 1'b1;
					frame_done     <= 1'b1;
					dbg_seq        <= seq_r;
					dbg_last_bank  <= bank_r;
					state          <= ST_IDLE;
				end
			end

			default: state <= ST_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
