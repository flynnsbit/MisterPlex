// fabric_ddr_writer — fabric I420 bank fill + doorbell (zero ARM per-pixel).
//
// Macro FABRIC_DDR_WRITER default OFF (Plex.qsf commented) — w-nostub fit safe.
//
// Parent-verified 2026-08-02 (device cmdline + /proc/iomem):
//   mem=511M; memmap=513M$511M → reserved 0x1FF00000..0x40000000
//   Option-C base 0x30180000, doorbell 0x3047F000, end 0x30480000 all inside
//   reserved and unclaimed. Headroom ≈ 251.5 MB — DDR bytes not scarce.
//   Triple-buffer map (3*0x180000) still fits easily; doorbell bank field remains
//   1 bit until ddr_frame_store consumer widens (bank_id[0] published today).
//
// Geometry is parameter-only (624x480 / 1280x720 sets from layout .svh).
//
// Pixel source (pluggable — see fabric_i420_pattern_src.sv):
//   src_valid/src_ready, 64-bit planar I420 qwords (Y then U then V),
//   src_frame_start with first beat, src_bank_id[1:0] sampled then.
//
// Doorbell ordering (tearing class — do not relax):
//   1) Accept and issue every payload qword write into the active bank.
//   2) WRITE_DRAIN_CYCLES fence after last payload command accepted
//      (f2sdram has no write response — drain is the visibility fence).
//   3) Exactly one doorbell write DIN={hi, PLXK} at DOORBELL_PHYS.
//   4) frame_done pulses after doorbell command is accepted.
//
// Burst / rate (clk_ddr=90 MHz, 8 B/qword, BURSTCNT=1, outstanding=1):
//   720p24: 33.18 MB/s → 4.15 Mqword/s → 4.6% of 90 MHz peak
//   720p30: 41.47 MB/s → 5.18 Mqword/s → 5.8% of 90 MHz peak
//   + scanout read upper ~82.9 MB/s → combined ~17% peak
//   ⇒ Rate closes. If arbiter grant < ~6% writer share @30fps, does NOT close.
//   Device sustained fabric write BW: unknown until fit + parent measure.
//
// Coordination: w-scaler = content-window READ; w-clock = multi-pixel present
// READ; this module = WRITE master on clk_ddr. Arbiter 3rd port = later fit.
//
`default_nettype none

// Defaults track Option-C 720p constants in ddr_frame_layout_params.svh
// (must stay in lockstep with host/libmisterplex/ddr_frame_layout.hpp).
`include "ddr_frame_layout_params.svh"

module fabric_ddr_writer #(
	parameter int CODED_W = DDR_FRAME_720P_CODED_WIDTH,
	parameter int CODED_H = DDR_FRAME_720P_CODED_HEIGHT,
	parameter [31:0] PHYS_BASE = DDR_FRAME_720P_PHYS_BASE,
	parameter int HPS_BANK_STRIDE_BYTES = DDR_FRAME_720P_YUV420P_BANK_STRIDE,
	parameter [31:0] DOORBELL_PHYS = DDR_FRAME_720P_YUV420P_DOORBELL_PHYS,
	parameter int NUM_BANKS = 2,
	parameter int WRITE_DRAIN_CYCLES = 16,
	parameter [31:0] DOORBELL_MAGIC = 32'h504C584B, // PLXK
	parameter [1:0] DOORBELL_FORMAT_YUV420P = 2'd1
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        src_valid,
	output wire        src_ready,
	input  wire [63:0] src_data,
	input  wire        src_frame_start,
	input  wire [1:0]  src_bank_id,

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
	output reg  [1:0]  dbg_last_bank,
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
	reg [1:0]  bank_r;
	reg [28:0] seq_r;
	reg [31:0] q_left;
	reg [28:0] wr_addr_q;
	reg [15:0] drain_cnt;

	reg        skid_valid;
	reg [63:0] skid_data;

	assign DDRAM_CLK = clk;
	assign DDRAM_BE  = 8'hFF;
	assign busy      = (state != ST_IDLE);
	assign dbg_state = state;

	wire issue_ok = !DDRAM_BUSY;
	wire skid_fire = (state == ST_RUN) && skid_valid && issue_ok;
	assign src_ready =
		(state == ST_IDLE) ||
		((state == ST_RUN) && (q_left != 32'd0) && (!skid_valid || skid_fire));

	wire _unused = &{1'b0, DDRAM_DOUT, DDRAM_DOUT_READY, NUM_BANKS[31:0]};

	// Product doorbell bank field is 1 bit — publish bank_id[0].
	wire [31:0] db_hi = {bank_r[0], DOORBELL_FORMAT_YUV420P, seq_r};

	always @(posedge clk) begin
		if (reset) begin
			state          <= ST_IDLE;
			bank_r         <= 2'd0;
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
			dbg_last_bank  <= 2'd0;
		end else begin
			frame_done <= 1'b0;
			DDRAM_RD   <= 1'b0;
			DDRAM_WE   <= 1'b0;

			case (state)
			ST_IDLE: begin
				skid_valid <= 1'b0;
				if (src_valid && src_frame_start && src_ready) begin
					bank_r     <= src_bank_id;
					seq_r      <= seq_r + 29'd1;
					q_left     <= 32'(FRAME_QWORDS - 1);
					wr_addr_q  <= BASE_Q + (29'(src_bank_id) * STRIDE_Q);
					skid_valid <= 1'b1;
					skid_data  <= src_data;
					state      <= ST_RUN;
				end
			end

			ST_RUN: begin
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
