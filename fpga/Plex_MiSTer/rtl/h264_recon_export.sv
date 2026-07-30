// h264_recon_export.sv — P3-3l5 FPGA→ARM reconstructed I420 export.
//
// Pixel planes: dedicated HPS-DDR region (default 0x30200000), NEVER the
// present scanout banks at 0x30000000. Reading present banks returns the ARM's
// own last write — silently wrong hybrid.
//
// PLXO mailbox @ 0x3007F130 lives on the historical control/present *map page*
// (same 0x3007Fxxx window the ARM already maps for status). That is a mailbox
// only — not a pixel bank. Pixel memcpy uses the dedicated recon map alone.
//
// Handshake (PLXO magic "PLXO"):
//   ready=1 && torn=0  → bank holds a *complete* frame; seq advanced
//   torn=1             → abort / incomplete; ARM must fail closed
//   ready=0            → not safe to read
//
// Safety (closed, not merely narrowed):
//   1. frame_start accepted only when idle (or one-deep pending); never flips
//      wr_bank while a mailbox issue is still updating pub_bank.
//   2. ready published only if sample_count == FRAME_BYTES (no short write).
//   3. ARM must post-copy re-read PLXO (seq/bank unchanged) — see fpga_spi.cpp.
//
// Bank stride default 512 KiB (0x80000) fits 624×480 I420 (449280 B).
// Paper bandwidth @320×240/25: +2.88 MB/s. Device fps = UNKNOWN.

module h264_recon_export #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter [31:0] PHYS_BASE = 32'h3020_0000,
	// 512 KiB/bank: 320x240 I420=115200; 624x480 I420=449280 — both fit.
	parameter [31:0] BANK_STRIDE = 32'h0008_0000,
	parameter [31:0] MAILBOX_PHYS = 32'h3007_F130,
	parameter [31:0] MAGIC = 32'h504C_584F  // "PLXO"
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        sample_valid,
	input  wire [31:0] sample_off,
	input  wire [7:0]  sample_data,
	input  wire        frame_start,
	input  wire        frame_done,
	input  wire        frame_abort,

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

	output wire        busy,
	output wire [15:0] frames_exported,
	output wire        last_torn
);
	localparam int FRAME_BYTES = FRAME_W * FRAME_H + 2 * ((FRAME_W / 2) * (FRAME_H / 2));
	localparam [28:0] MBOX_Q = MAILBOX_PHYS[31:3];

	// synthesis translate_off
	initial begin
		if (BANK_STRIDE < FRAME_BYTES[31:0]) begin
			$error("h264_recon_export: BANK_STRIDE too small for FRAME_W x FRAME_H I420");
		end
	end
	// synthesis translate_on

	localparam [1:0] ST_IDLE  = 2'd0;
	localparam [1:0] ST_FILL  = 2'd1;
	localparam [1:0] ST_FLUSH = 2'd2;
	localparam [1:0] ST_MBOX  = 2'd3;

	reg [1:0]  state;
	reg        wr_bank;
	reg        pub_bank;
	reg        torn_sticky;
	reg [15:0] seq;
	reg [15:0] frames_q;
	reg        busy_r;
	reg        last_torn_r;
	reg        pending_start;
	reg [31:0] sample_count;

	reg        pq_valid;
	reg [28:0] pq_addr_q;
	reg [63:0] pq_data;
	reg [7:0]  pq_be;
	reg        pq_bank;

	reg        cmd_valid;
	reg        cmd_is_mbox;
	reg [28:0] cmd_addr;
	reg [63:0] cmd_data;
	reg [7:0]  cmd_be;
	reg        cmd_torn;
	reg        cmd_bank;
	reg [15:0] cmd_seq;

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
	wire pq_hit = pq_valid && (pq_addr_q == sample_q) && (pq_bank == wr_bank);
	wire start_ready = (state == ST_IDLE) && !cmd_valid && !need_mbox;

	always @(posedge clk) begin
		if (reset) begin
			state         <= ST_IDLE;
			wr_bank       <= 1'b0;
			pub_bank      <= 1'b0;
			torn_sticky   <= 1'b0;
			seq           <= 16'd0;
			frames_q      <= 16'd0;
			busy_r        <= 1'b0;
			last_torn_r   <= 1'b0;
			pending_start <= 1'b0;
			sample_count  <= 32'd0;
			pq_valid      <= 1'b0;
			pq_addr_q     <= 29'd0;
			pq_data       <= 64'd0;
			pq_be         <= 8'd0;
			pq_bank       <= 1'b0;
			cmd_valid     <= 1'b0;
			cmd_is_mbox   <= 1'b0;
			cmd_addr      <= 29'd0;
			cmd_data      <= 64'd0;
			cmd_be        <= 8'hFF;
			cmd_torn      <= 1'b0;
			cmd_bank      <= 1'b0;
			cmd_seq       <= 16'd0;
			need_mbox     <= 1'b0;
			mbox_torn     <= 1'b0;
			mbox_bank     <= 1'b0;
			mbox_seq      <= 16'd0;
			ddr_want      <= 1'b0;
			ddr_rd        <= 1'b0;
			ddr_we        <= 1'b0;
			ddr_burstcnt  <= 8'd1;
			ddr_addr      <= 29'd0;
			ddr_din       <= 64'd0;
			ddr_be        <= 8'hFF;
		end else begin
			ddr_rd <= 1'b0;
			ddr_we <= 1'b0;
			if (!cmd_valid)
				ddr_want <= 1'b0;

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
					if (!cmd_torn)
						frames_q <= frames_q + 16'd1;
					busy_r <= 1'b0;
					state  <= ST_IDLE;
				end
			end

			// frame_start only when idle; else one-deep pending.
			// Never derive wr_bank from pub_bank in the same cycle pub_bank updates.
			if (frame_start) begin
				if (start_ready) begin
					wr_bank       <= ~pub_bank;
					torn_sticky   <= 1'b0;
					busy_r        <= 1'b1;
					pq_valid      <= 1'b0;
					need_mbox     <= 1'b0;
					sample_count  <= 32'd0;
					pending_start <= 1'b0;
					state         <= ST_FILL;
				end else begin
					pending_start <= 1'b1;
				end
			end else if (pending_start && start_ready) begin
				wr_bank       <= ~pub_bank;
				torn_sticky   <= 1'b0;
				busy_r        <= 1'b1;
				pq_valid      <= 1'b0;
				need_mbox     <= 1'b0;
				sample_count  <= 32'd0;
				pending_start <= 1'b0;
				state         <= ST_FILL;
			end

			if (frame_abort && (state == ST_FILL || state == ST_FLUSH))
				torn_sticky <= 1'b1;

			if (state == ST_FILL && sample_in_range) begin
				sample_count <= sample_count + 32'd1;
				if (pq_valid && !pq_hit) begin
					if (!cmd_valid) begin
						cmd_valid   <= 1'b1;
						cmd_is_mbox <= 1'b0;
						cmd_addr    <= pq_addr_q;
						cmd_data    <= pq_data;
						cmd_be      <= pq_be;
						ddr_want    <= 1'b1;
						pq_valid    <= 1'b1;
						pq_addr_q   <= sample_q;
						pq_bank     <= wr_bank;
						pq_data     <= sample_lane_data;
						pq_be       <= sample_be;
					end else begin
						torn_sticky <= 1'b1;
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

			if (state == ST_FILL && frame_done) begin
				// Short write → torn (refuse ready). Include same-cycle sample.
				if ((sample_count + (sample_in_range ? 32'd1 : 32'd0)) != frame_bytes_u)
					torn_sticky <= 1'b1;
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
					// 16-bit seq wrap is deliberate; ARM uses seq for post-copy
					// identity, not a strict monotonic +1 across wrap.
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
				cmd_valid   <= 1'b1;
				cmd_is_mbox <= 1'b1;
				cmd_addr    <= MBOX_Q;
				cmd_be      <= 8'hFF;
				cmd_torn    <= mbox_torn;
				cmd_bank    <= mbox_bank;
				cmd_seq     <= mbox_seq;
				cmd_data    <= {
					mbox_seq,
					12'd0,
					1'b1,
					mbox_torn,
					mbox_bank,
					~mbox_torn,
					MAGIC
				};
				ddr_want  <= 1'b1;
				need_mbox <= 1'b0;
			end

			if (ddr_dout_ready) begin
			end
		end
	end
endmodule
