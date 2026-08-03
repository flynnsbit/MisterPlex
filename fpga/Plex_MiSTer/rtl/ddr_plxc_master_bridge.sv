// ddr_plxc_master_bridge — chrome simple master (req/gnt) ↔ f2sdram arbiter port
//
// Chrome loader uses: m_req → m_gnt (1-cycle) → [RD: m_rd_valid + m_rdata]
// Arbiter masters use: want + !busy gate, then rd/we with burstcnt=1.
//
// Acceptance contract (rd-duck lost-read B):
//   !a_busy alone is NOT acceptance — m0_ov / CDC can make busy lag a full
//   registered+2FF path after the arbiter has already stolen the mux. Product
//   waits for a_accept (arbiter pulse: cmd was placed on DDR). FAULT twin can
//   tie a_accept=!a_busy to REPRO hang under m0 collision.
//
// Both sides expected on the same clock (clk_sys for product PLXC).

`timescale 1ns / 1ps
`default_nettype none

module ddr_plxc_master_bridge (
	input  wire        clk,
	input  wire        reset,

	// chrome loader side
	input  wire        c_req,
	input  wire        c_we,
	input  wire [28:0] c_addr,
	input  wire [63:0] c_wdata,
	output reg         c_gnt,
	output reg         c_rd_valid,
	output reg  [63:0] c_rdata,

	// arbiter master side (clk_m* domain style)
	output reg         a_want,
	input  wire        a_busy,
	// Arbiter-accepted cmd pulse (consumer clock). Required for product.
	input  wire        a_accept,
	output reg   [7:0] a_burstcnt,
	output reg  [28:0] a_addr,
	input  wire [63:0] a_dout,
	input  wire        a_dout_ready,
	output reg         a_rd,
	output reg  [63:0] a_din,
	output reg   [7:0] a_be,
	output reg         a_we,

	// observability
	output reg  [31:0] cnt_gnt,
	output reg  [31:0] cnt_rd_beats,
	output reg  [31:0] cnt_we_beats
);

	localparam [1:0] S_IDLE   = 2'd0;
	localparam [1:0] S_ISSUE  = 2'd1;
	localparam [1:0] S_WAIT_R = 2'd2;

	reg [1:0] st;
	reg       pend_we;
	reg [28:0] pend_addr;
	reg [63:0] pend_wdata;
	// Hold one-shot cmd until a_accept (may span several cycles under m0 traffic).
	reg       cmd_armed;

	always @(posedge clk) begin
		if (reset) begin
			st          <= S_IDLE;
			c_gnt       <= 1'b0;
			c_rd_valid  <= 1'b0;
			c_rdata     <= 64'd0;
			a_want      <= 1'b0;
			a_burstcnt  <= 8'd1;
			a_addr      <= 29'd0;
			a_rd        <= 1'b0;
			a_din       <= 64'd0;
			a_be        <= 8'hFF;
			a_we        <= 1'b0;
			pend_we     <= 1'b0;
			pend_addr   <= 29'd0;
			pend_wdata  <= 64'd0;
			cmd_armed   <= 1'b0;
			cnt_gnt     <= 32'd0;
			cnt_rd_beats<= 32'd0;
			cnt_we_beats<= 32'd0;
		end else begin
			c_gnt      <= 1'b0;
			c_rd_valid <= 1'b0;
			// Default: drop one-shot unless ISSUE keeps them armed.
			if (!cmd_armed) begin
				a_rd <= 1'b0;
				a_we <= 1'b0;
			end

			case (st)
				S_IDLE: begin
					a_want    <= 1'b0;
					cmd_armed <= 1'b0;
					a_rd      <= 1'b0;
					a_we      <= 1'b0;
					if (c_req) begin
						pend_we    <= c_we;
						pend_addr  <= c_addr;
						pend_wdata <= c_wdata;
						a_want     <= 1'b1;
						a_addr     <= c_addr;
						a_din      <= c_wdata;
						a_be       <= 8'hFF;
						a_burstcnt <= 8'd1;
						st         <= S_ISSUE;
					end
				end

				S_ISSUE: begin
					// Hold want + payload stable until arbiter accepts.
					a_want     <= 1'b1;
					a_addr     <= pend_addr;
					a_din      <= pend_wdata;
					a_be       <= 8'hFF;
					a_burstcnt <= 8'd1;
					if (!cmd_armed && !a_busy) begin
						// Present command; do NOT c_gnt yet — wait a_accept.
						cmd_armed <= 1'b1;
						if (pend_we)
							a_we <= 1'b1;
						else
							a_rd <= 1'b1;
					end else if (cmd_armed) begin
						// Keep cmd lines high until accept (or re-drive).
						if (pend_we)
							a_we <= 1'b1;
						else
							a_rd <= 1'b1;
						if (a_accept) begin
							c_gnt     <= 1'b1;
							cnt_gnt   <= cnt_gnt + 32'd1;
							cmd_armed <= 1'b0;
							a_rd      <= 1'b0;
							a_we      <= 1'b0;
							a_want    <= 1'b0;
							if (pend_we) begin
								cnt_we_beats <= cnt_we_beats + 32'd1;
								st           <= S_IDLE;
							end else begin
								st <= S_WAIT_R;
							end
						end
					end
				end

				S_WAIT_R: begin
					a_want    <= 1'b0;
					cmd_armed <= 1'b0;
					a_rd      <= 1'b0;
					a_we      <= 1'b0;
					if (a_dout_ready) begin
						c_rd_valid   <= 1'b1;
						c_rdata      <= a_dout;
						cnt_rd_beats <= cnt_rd_beats + 32'd1;
						st           <= S_IDLE;
					end
				end

				default: st <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
