// fabric_ddr_frame_mem2mem — FALLBACK lab path: RD staging to WE Option-C bank + doorbell.
//
// rd-duck binding: preferred product path is dynamic-base DIRECT fabric reader
// (decode/raw writes once; ddr_frame_store reads that buffer — no source-to-bank mover).
// This mover adds read+write traffic (2x payload beats) and does NOT mean
// "ARM never touches the frame" (software decode/raw still writes pixels).
// It can only retire the uncached publication memcpy (fpga_spi.cpp ddrMap_ copy,
// T_copy_arm=14.978 ms archive) after pinned SG + cache-coherency contract.
//
// Sweep-118: serial decode + that memcpy fails 720p24 (~6 ms short). Path (a)
// overlap unproven (49% idle was pre-decode, not during). Keep this module as
// measured fallback (solo sim ~9.6 ms at 90MHz model) until direct-base lands.
//
// Macro FABRIC_DDR_FRAME_MEM2MEM default OFF — does not touch product path until
// arbiter attach + parent enable. Not PL330 userspace (unbind hung SoC).
//
// Ordering (tearing class — same as fabric_ddr_writer):
//   1) RD staging to WE bank for every payload qword (pipelined outstanding=1)
//   2) WRITE_DRAIN fence
//   3) one doorbell WE (hi, PLXK)
//   4) frame_done
//
// Defaults: Option-C 720p + staging at 0x30601000 (kPl330StagingPhys).
//
`default_nettype none
`include "ddr_frame_layout_params.svh"

module fabric_ddr_frame_mem2mem #(
	parameter int CODED_W = DDR_FRAME_720P_CODED_WIDTH,
	parameter int CODED_H = DDR_FRAME_720P_CODED_HEIGHT,
	parameter [31:0] PHYS_BASE = DDR_FRAME_720P_PHYS_BASE,
	parameter int HPS_BANK_STRIDE_BYTES = DDR_FRAME_720P_YUV420P_BANK_STRIDE,
	parameter [31:0] DOORBELL_PHYS = DDR_FRAME_720P_YUV420P_DOORBELL_PHYS,
	// Staging source (ARM-filled). Default matches host kPl330StagingPhys.
	parameter [31:0] STAGING_PHYS = 32'h3060_1000,
	parameter int WRITE_DRAIN_CYCLES = 16,
	parameter [31:0] DOORBELL_MAGIC = 32'h504C584B,
	parameter [1:0] DOORBELL_FORMAT_YUV420P = 2'd1,
	parameter int RD_LATENCY_HINT = 4 // TB/model only; hardware uses DOUT_READY
)(
	input  wire        clk, // clk_ddr domain
	input  wire        reset,

	input  wire        start,       // pulse/level: begin one frame when idle
	input  wire        bank_sel,    // 0/1 Option-C bank
	input  wire [31:0] staging_phys_rt, // 0 → use STAGING_PHYS param
	input  wire        staging_phys_use_rt,

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
	output reg  [3:0]  dbg_state,
	output reg  [31:0] dbg_beats_moved
);

	localparam int FRAME_BYTES  = (CODED_W * CODED_H * 3) / 2;
	localparam int FRAME_QWORDS = FRAME_BYTES / 8;

	localparam [28:0] BASE_Q     = PHYS_BASE[31:3];
	localparam [28:0] STRIDE_Q   = 29'(unsigned'(HPS_BANK_STRIDE_BYTES) / 8);
	localparam [28:0] DOORBELL_Q = DOORBELL_PHYS[31:3];
	localparam [28:0] STAGE_Q_D  = STAGING_PHYS[31:3];

	localparam [3:0] ST_IDLE     = 4'd0;
	localparam [3:0] ST_RD_ISSUE = 4'd1;
	localparam [3:0] ST_RD_WAIT  = 4'd2;
	localparam [3:0] ST_WR_ISSUE = 4'd3;
	localparam [3:0] ST_DRAIN    = 4'd4;
	localparam [3:0] ST_DOORBELL = 4'd5;

	reg [3:0]  state;
	reg        bank_r;
	reg [28:0] seq_r;
	reg [31:0] q_left;
	reg [28:0] rd_addr_q;
	reg [28:0] wr_addr_q;
	reg [63:0] data_r;
	reg [15:0] drain_cnt;
	reg        start_seen;

	assign DDRAM_CLK = clk;
	assign DDRAM_BE  = 8'hFF;
	assign busy      = (state != ST_IDLE);
	assign dbg_state = state;

	(* keep = 1 *) wire keep_m2m =
		busy | frame_done | DDRAM_RD | DDRAM_WE | |dbg_beats_moved | |q_left;

	wire issue_ok = !DDRAM_BUSY;
	wire [28:0] stage_base_q = staging_phys_use_rt ? staging_phys_rt[31:3] : STAGE_Q_D;

	// Silence unused param / keep net (synthesis keep attribute)
	wire _unused = keep_m2m ^ (RD_LATENCY_HINT == 0);

	wire [31:0] db_hi = {bank_r, DOORBELL_FORMAT_YUV420P, seq_r};

	always @(posedge clk) begin
		if (reset) begin
			state            <= ST_IDLE;
			bank_r           <= 1'b0;
			seq_r            <= 29'd0;
			q_left           <= 32'd0;
			rd_addr_q        <= 29'd0;
			wr_addr_q        <= 29'd0;
			data_r           <= 64'd0;
			drain_cnt        <= 16'd0;
			start_seen       <= 1'b0;
			DDRAM_BURSTCNT   <= 8'd1;
			DDRAM_ADDR       <= 29'd0;
			DDRAM_RD         <= 1'b0;
			DDRAM_DIN        <= 64'd0;
			DDRAM_WE         <= 1'b0;
			frame_done       <= 1'b0;
			dbg_seq          <= 29'd0;
			dbg_last_bank    <= 1'b0;
			dbg_beats_moved  <= 32'd0;
		end else begin
			frame_done <= 1'b0;
			DDRAM_RD   <= 1'b0;
			DDRAM_WE   <= 1'b0;

			// Edge-ish start capture while idle
			if (state == ST_IDLE)
				start_seen <= start;
			else if (!start)
				start_seen <= 1'b0;

			case (state)
			ST_IDLE: begin
				if (start && !start_seen) begin
					bank_r          <= bank_sel;
					seq_r           <= seq_r + 29'd1;
					q_left          <= 32'(FRAME_QWORDS);
					rd_addr_q       <= stage_base_q;
					wr_addr_q       <= BASE_Q + (bank_sel ? STRIDE_Q : 29'd0);
					dbg_beats_moved <= 32'd0;
					state           <= ST_RD_ISSUE;
				end
			end

			ST_RD_ISSUE: begin
				if (q_left == 32'd0) begin
					drain_cnt <= (WRITE_DRAIN_CYCLES > 0) ?
					             16'(WRITE_DRAIN_CYCLES) : 16'd0;
					state     <= ST_DRAIN;
				end else if (issue_ok) begin
					DDRAM_ADDR     <= rd_addr_q;
					DDRAM_BURSTCNT <= 8'd1;
					DDRAM_RD       <= 1'b1;
					state          <= ST_RD_WAIT;
				end
			end

			ST_RD_WAIT: begin
				if (DDRAM_DOUT_READY) begin
					data_r    <= DDRAM_DOUT;
					rd_addr_q <= rd_addr_q + 29'd1;
					state     <= ST_WR_ISSUE;
				end
			end

			ST_WR_ISSUE: begin
				if (issue_ok) begin
					DDRAM_ADDR     <= wr_addr_q;
					DDRAM_BURSTCNT <= 8'd1;
					DDRAM_DIN      <= data_r;
					DDRAM_WE       <= 1'b1;
					wr_addr_q      <= wr_addr_q + 29'd1;
					q_left         <= q_left - 32'd1;
					dbg_beats_moved <= dbg_beats_moved + 32'd1;
					state          <= ST_RD_ISSUE;
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
