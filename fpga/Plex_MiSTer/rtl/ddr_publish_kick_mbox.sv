// ddr_publish_kick_mbox — PLXG/PLXH host kick frontend for fabric publish (phase2).
//
// Host programs doorbell-relative control page (compact map):
//   +0x140 PLXG_LO magic 0x504C5847 "PLXG"
//   +0x144 PLXG_HI command (start_w / start_toggle / clr_* / bank_sel / cmd_seq)
//   +0x148 SRC_PHYS
//   +0x14C BANK_PHYS   (latched; u_pub uses bank_sel today)
//   +0x150 FRAME_BYTES
//   +0x154 RESERVED
//   +0x158 PLXH_LO magic 0x504C5848 "PLXH"
//   +0x15C PLXH_HI busy / done_sticky / err_align / done_seq
//
// Domain: clk_ddr (same as f2sdram / u_pub). Host writes DDR; FPGA polls like PLXK.
// Multi-bit SRC/BANK/LEN sampled only on accepted start edge (protocol-guarded).
// Start: toggle edge preferred; start_w rising also accepted.
//
// Bus: soft m2 peer. Asserts bus_want only while !pub_busy so u_pub COPY is
// never contended. PLXH busy=1 is posted *before* start_pulse so host can poll
// without mid-job mailbox traffic (engine holds bus_want for whole job).
// Does NOT ring PLXK (host owns doorbell after done).
//
// M10K: 0 (regs only). PRODUCT_WIRE research path only.

`timescale 1ns / 1ps
`default_nettype none

module ddr_publish_kick_mbox #(
	parameter [31:0] DOORBELL_PHYS = 32'h302F_F000,
	parameter int    ADDR_W = 29,
	// Poll period while idle (~256 clk_ddr ≈ 2.8 us @90 MHz)
	parameter int    POLL_DIV_BITS = 8
)(
	input  wire              clk,
	input  wire              reset,

	// u_pub status (clk_ddr)
	input  wire              pub_busy,
	input  wire              pub_done_pulse,
	input  wire              pub_err,          // align/illegal → err_align sticky

	// Job outputs → u_pub
	output reg               start_pulse,      // 1-cycle start to u_pub
	output reg               bank_sel,
	output reg  [31:0]       src_phys,
	output reg  [31:0]       bank_phys,        // absolute PA (diagnostic / future)
	output reg  [31:0]       frame_bytes,      // → bytes_override
	output wire              cmd_mode_copy,    // hardwired 1 = COPY
	output wire              ring_doorbell,    // hardwired 0 — host owns PLXK

	// f2sdram master (muxed onto arb3 m2 when !pub_busy)
	output reg               bus_want,
	input  wire              DDRAM_BUSY,
	output reg  [7:0]        DDRAM_BURSTCNT,
	output reg  [ADDR_W-1:0] DDRAM_ADDR,
	input  wire [63:0]       DDRAM_DOUT,
	input  wire              DDRAM_DOUT_READY,
	output reg               DDRAM_RD,
	output reg  [63:0]       DDRAM_DIN,
	output wire [7:0]        DDRAM_BE,
	output reg               DDRAM_WE
);

	localparam [31:0] OFF_PLXG = 32'h140;
	localparam [31:0] OFF_SRC  = 32'h148;
	localparam [31:0] OFF_LEN  = 32'h150;
	localparam [31:0] OFF_PLXH = 32'h158;

	localparam [31:0] MAGIC_G = 32'h504C_5847; // "PLXG"
	localparam [31:0] MAGIC_H = 32'h504C_5848; // "PLXH"

	localparam [ADDR_W-1:0] Q_PLXG = (DOORBELL_PHYS + OFF_PLXG) >> 3;
	localparam [ADDR_W-1:0] Q_SRC  = (DOORBELL_PHYS + OFF_SRC)  >> 3;
	localparam [ADDR_W-1:0] Q_LEN  = (DOORBELL_PHYS + OFF_LEN)  >> 3;
	localparam [ADDR_W-1:0] Q_PLXH = (DOORBELL_PHYS + OFF_PLXH) >> 3;

	assign DDRAM_BE      = 8'hFF;
	assign cmd_mode_copy = 1'b1;
	assign ring_doorbell = 1'b0;

	localparam [2:0]
		ST_IDLE      = 3'd0,
		ST_RD_CMD    = 3'd1,
		ST_RD_SRC    = 3'd2,
		ST_RD_LEN    = 3'd3,
		ST_WR_ACCEPT = 3'd4,  // PLXH busy=1 + accepted before start
		ST_START     = 3'd5,
		ST_WR_DONE   = 3'd6;  // PLXH after done / clear / idle refresh

	reg [2:0] st;
	reg [POLL_DIV_BITS-1:0] poll_div;
	reg        rd_issued, wr_issued;
	reg        have_toggle;
	reg        last_toggle;
	reg        last_start_w;
	reg        need_status_wr;
	reg        posted_busy;      // sticky 1 from accept-write until done
	reg        st_done_sticky;
	reg        st_err_align;
	reg        st_err_busy_kick;
	reg        st_accepted;
	reg [15:0] st_done_seq;
	reg [15:0] latched_cmd_seq;
	reg        latched_bank_sel;
	reg        latched_use_bank_sel;
	reg [31:0] latched_src;
	reg [31:0] latched_bank;
	reg [31:0] latched_len;

	// Live PLXG_HI decode (valid only with DOUT_READY in ST_RD_CMD)
	wire        cmd_magic_ok   = (DDRAM_DOUT[31:0] == MAGIC_G);
	wire        cmd_start_w    = DDRAM_DOUT[32];
	wire        cmd_start_tog  = DDRAM_DOUT[33];
	wire        cmd_clr_done   = DDRAM_DOUT[34];
	wire        cmd_clr_err    = DDRAM_DOUT[35];
	wire        cmd_bank_sel   = DDRAM_DOUT[36];
	wire        cmd_use_bsel   = DDRAM_DOUT[37];
	wire [15:0] cmd_seq        = DDRAM_DOUT[63:48];
	wire        cmd_tog_edge   = have_toggle && (cmd_start_tog != last_toggle);
	wire        cmd_sw_rise    = cmd_start_w && !last_start_w;
	wire        cmd_want_start = cmd_tog_edge || cmd_sw_rise;

	wire can_cmd   = !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE;
	wire rd_accept = DDRAM_RD && !DDRAM_BUSY;
	wire wr_accept = DDRAM_WE && !DDRAM_BUSY;

	// busy bit: posted before start, then tracks pub_busy
	wire status_busy = posted_busy | pub_busy;

	wire [31:0] plxh_hi = {
		st_done_seq,                 // [31:16]
		10'd0,                       // [15:6] reserved
		st_accepted,                 // [5]
		st_err_busy_kick,            // [4]
		1'b0,                        // [3] err_timeout (host-only v1)
		st_err_align,                // [2]
		st_done_sticky,              // [1]
		status_busy                  // [0]
	};
	wire [63:0] plxh_qword = {plxh_hi, MAGIC_H};

	always @(posedge clk) begin
		if (reset) begin
			st <= ST_IDLE;
			poll_div <= '0;
			rd_issued <= 1'b0;
			wr_issued <= 1'b0;
			have_toggle <= 1'b0;
			last_toggle <= 1'b0;
			last_start_w <= 1'b0;
			need_status_wr <= 1'b1;
			posted_busy <= 1'b0;
			st_done_sticky <= 1'b0;
			st_err_align <= 1'b0;
			st_err_busy_kick <= 1'b0;
			st_accepted <= 1'b0;
			st_done_seq <= 16'd0;
			latched_cmd_seq <= 16'd0;
			latched_bank_sel <= 1'b0;
			latched_use_bank_sel <= 1'b1;
			latched_src <= 32'd0;
			latched_bank <= 32'd0;
			latched_len <= 32'd0;
			start_pulse <= 1'b0;
			bank_sel <= 1'b0;
			src_phys <= 32'd0;
			bank_phys <= 32'd0;
			frame_bytes <= 32'd0;
			bus_want <= 1'b0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_ADDR <= '0;
			DDRAM_RD <= 1'b0;
			DDRAM_DIN <= 64'd0;
			DDRAM_WE <= 1'b0;
		end else begin
			start_pulse <= 1'b0;

			// Done path: sticky + force status write once engine frees bus
			if (pub_done_pulse) begin
				st_done_sticky <= 1'b1;
				st_done_seq <= latched_cmd_seq;
				if (pub_err)
					st_err_align <= 1'b1;
				posted_busy <= 1'b0;
				st_accepted <= 1'b0;
				need_status_wr <= 1'b1;
			end

			case (st)
			ST_IDLE: begin
				bus_want <= 1'b0;
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				rd_issued <= 1'b0;
				wr_issued <= 1'b0;
				poll_div <= poll_div + 1'b1;

				// Only when publish engine idle (no bus_want conflict with u_pub).
				// Still poll while posted_busy so a new start edge can raise
				// err_busy_kick; edge detect (toggle/start_w) prevents re-accept
				// of the same host command between start_pulse and pub_busy.
				if (!pub_busy) begin
					if (need_status_wr && can_cmd && (poll_div[1:0] == 2'b01)) begin
						bus_want <= 1'b1;
						st <= ST_WR_DONE;
					end else if ((poll_div == {POLL_DIV_BITS{1'b0}}) && can_cmd) begin
						bus_want <= 1'b1;
						st <= ST_RD_CMD;
					end
				end
			end

			// Read handshake: keep rd_issued until DOUT_READY. Clearing it on
			// rd_accept made the if (!rd_issued) arm swallow data beats (stuck).
			ST_RD_CMD: begin
				bus_want <= 1'b1;
				if (!rd_issued) begin
					if (can_cmd) begin
						DDRAM_ADDR <= Q_PLXG;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						rd_issued <= 1'b1;
					end
				end else begin
					if (rd_accept)
						DDRAM_RD <= 1'b0;
					if (DDRAM_DOUT_READY) begin
						rd_issued <= 1'b0;
						if (cmd_magic_ok) begin
							if (!pub_busy && cmd_clr_done) begin
								st_done_sticky <= 1'b0;
								st_err_align <= 1'b0;
								st_err_busy_kick <= 1'b0;
								need_status_wr <= 1'b1;
							end else if (!pub_busy && cmd_clr_err) begin
								st_err_align <= 1'b0;
								need_status_wr <= 1'b1;
							end

							last_toggle  <= cmd_start_tog;
							have_toggle  <= 1'b1;
							last_start_w <= cmd_start_w;

							if (cmd_want_start) begin
								if (pub_busy || posted_busy) begin
									st_err_busy_kick <= 1'b1;
									need_status_wr <= 1'b1;
									st <= ST_WR_DONE;
								end else begin
									latched_cmd_seq <= cmd_seq;
									latched_bank_sel <= cmd_bank_sel;
									latched_use_bank_sel <= cmd_use_bsel;
									st <= ST_RD_SRC;
								end
							end else if (need_status_wr) begin
								st <= ST_WR_DONE;
							end else begin
								st <= ST_IDLE;
							end
						end else if (need_status_wr) begin
							st <= ST_WR_DONE;
						end else begin
							st <= ST_IDLE;
						end
					end
				end
			end

			ST_RD_SRC: begin
				bus_want <= 1'b1;
				if (!rd_issued) begin
					if (can_cmd) begin
						DDRAM_ADDR <= Q_SRC;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						rd_issued <= 1'b1;
					end
				end else begin
					if (rd_accept)
						DDRAM_RD <= 1'b0;
					if (DDRAM_DOUT_READY) begin
						rd_issued <= 1'b0;
						latched_src  <= DDRAM_DOUT[31:0];
						latched_bank <= DDRAM_DOUT[63:32];
						st <= ST_RD_LEN;
					end
				end
			end

			ST_RD_LEN: begin
				bus_want <= 1'b1;
				if (!rd_issued) begin
					if (can_cmd) begin
						DDRAM_ADDR <= Q_LEN;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						rd_issued <= 1'b1;
					end
				end else begin
					if (rd_accept)
						DDRAM_RD <= 1'b0;
					if (DDRAM_DOUT_READY) begin
						rd_issued <= 1'b0;
						latched_len <= DDRAM_DOUT[31:0];
						// Prepare accept status: busy sticky + clear prior done
						src_phys    <= latched_src;
						bank_phys   <= latched_bank;
						bank_sel    <= latched_bank_sel;
						frame_bytes <= DDRAM_DOUT[31:0];
						posted_busy <= 1'b1;
						st_accepted <= 1'b1;
						st_done_sticky <= 1'b0;
						st_err_align <= 1'b0;
						st <= ST_WR_ACCEPT;
					end
				end
			end

			// Post PLXH with busy=1 *before* pulsing start (host-visible)
			ST_WR_ACCEPT: begin
				bus_want <= 1'b1;
				if (!wr_issued) begin
					if (can_cmd) begin
						DDRAM_ADDR <= Q_PLXH;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= plxh_qword;
						DDRAM_WE <= 1'b1;
						wr_issued <= 1'b1;
					end
				end else if (wr_accept) begin
					DDRAM_WE <= 1'b0;
					wr_issued <= 1'b0;
					st <= ST_START;
				end
			end

			ST_START: begin
				bus_want <= 1'b0;
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				// Params already stable; path edge-detects start
				start_pulse <= 1'b1;
				// Engine takes bus next; we stay off bus until !pub_busy
				st <= ST_IDLE;
			end

			ST_WR_DONE: begin
				bus_want <= 1'b1;
				if (!wr_issued) begin
					if (can_cmd) begin
						DDRAM_ADDR <= Q_PLXH;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= plxh_qword;
						DDRAM_WE <= 1'b1;
						wr_issued <= 1'b1;
					end
				end else if (wr_accept) begin
					DDRAM_WE <= 1'b0;
					wr_issued <= 1'b0;
					need_status_wr <= 1'b0;
					st <= ST_IDLE;
				end
			end

			default: st <= ST_IDLE;
			endcase
		end
	end

	(* keep *) wire _keep_use_bsel = latched_use_bank_sel;

endmodule

`default_nettype wire
