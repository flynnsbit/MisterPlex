// ddr_perf_mailbox — publish ddr_perf_counters shadows to DDR PLXP page.
// Seqlock: write payload then header last; trailer mirrors seq. Host double-reads.
// Avalon master: single-beat WE, hold under BUSY. M10K: 0.
// PLXP version 2: 24 qwords (latency bins + efficiency).

`default_nettype none

module ddr_perf_mailbox #(
	parameter [31:0] PLXP_PHYS = 32'h300F_F200,
	parameter int PUBLISH_PERIOD_LOG2 = 20
) (
	input  wire        clk,
	input  wire        reset,

	input  wire  [7:0]  snap_seq,
	input  wire [31:0]  sh_cycles,
	input  wire [31:0]  sh_wr_beats,
	input  wire [31:0]  sh_rd_beats,
	input  wire [31:0]  sh_stall_cyc,
	input  wire [31:0]  sh_lat_sum,
	input  wire [31:0]  sh_lat_max,
	input  wire [31:0]  sh_lat_n,
	input  wire [31:0]  sh_m0_rd,
	input  wire [31:0]  sh_m0_wr,
	input  wire [31:0]  sh_m1_rd,
	input  wire [31:0]  sh_m1_wr,
	input  wire [31:0]  sh_m2_rd,
	input  wire [31:0]  sh_m2_wr,
	input  wire [31:0]  sh_lat_bin0,
	input  wire [31:0]  sh_lat_bin1,
	input  wire [31:0]  sh_lat_bin2,
	input  wire [31:0]  sh_lat_bin3,
	input  wire [31:0]  sh_lat_bin4,
	input  wire [31:0]  sh_lat_bin5,
	input  wire [31:0]  sh_rd_cmds,
	input  wire [31:0]  sh_burst_sum,
	input  wire [31:0]  sh_single_cmds,
	input  wire [31:0]  sh_issue_cyc,
	input  wire [15:0]  sh_sat_flags,

	output reg          snap_req,
	output reg          clear_req,
	output wire         want,

	input  wire         DDRAM_BUSY,
	output reg   [7:0]  DDRAM_BURSTCNT,
	output reg  [28:0]  DDRAM_ADDR,
	input  wire [63:0]  DDRAM_DOUT,
	input  wire         DDRAM_DOUT_READY,
	output reg          DDRAM_RD,
	output reg  [63:0]  DDRAM_DIN,
	output reg   [7:0]  DDRAM_BE,
	output reg          DDRAM_WE
);
	localparam [31:0] MAGIC = 32'h504C_5850; // "PLXP"
	localparam [7:0]  VER   = 8'd2;
	localparam int    NWORD = 24;
	localparam [28:0] BASE_W = PLXP_PHYS[31:3];

	localparam int ST_IDLE = 0;
	localparam int ST_SNAP = 1;
	localparam int ST_LOAD = 2;
	localparam int ST_WR   = 3;

	reg [1:0] st;
	reg [4:0] step; // 0..23
	reg [PUBLISH_PERIOD_LOG2-1:0] div;
	reg [63:0] words [0:23];
	reg [7:0]  seq_r;

	wire busy_hold = DDRAM_WE && DDRAM_BUSY;
	assign want = (st == ST_WR[1:0]) || (st == ST_LOAD[1:0]);

	// step 0..22 -> words 1..23; step 23 -> word 0 (header last)
	wire [4:0] wsel = (step < 5'd23) ? (step + 5'd1) : 5'd0;

	always @(posedge clk) begin
		if (reset) begin
			st <= ST_IDLE[1:0];
			step <= 5'd0;
			div <= '0;
			snap_req <= 1'b0;
			clear_req <= 1'b0;
			seq_r <= 8'd0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_ADDR <= 29'd0;
			DDRAM_RD <= 1'b0;
			DDRAM_DIN <= 64'd0;
			DDRAM_BE <= 8'hFF;
			DDRAM_WE <= 1'b0;
		end else begin
			DDRAM_RD <= 1'b0;
			clear_req <= 1'b0;

			if (busy_hold) begin
				// hold WE/ADDR/DIN
			end else begin
				case (st)
				ST_IDLE[1:0]: begin
					DDRAM_WE <= 1'b0;
					snap_req <= 1'b0;
					div <= div + 1'b1;
					if (&div) begin
						st <= ST_SNAP[1:0];
					end
				end
				ST_SNAP[1:0]: begin
					snap_req <= 1'b1;
					st <= ST_LOAD[1:0];
				end
				ST_LOAD[1:0]: begin
					snap_req <= 1'b0;
					seq_r <= snap_seq;
					// Pack payload (header written last as words[0])
					words[1]  <= {32'd0, sh_cycles};
					words[2]  <= {32'd0, sh_wr_beats};
					words[3]  <= {32'd0, sh_rd_beats};
					words[4]  <= {32'd0, sh_stall_cyc};
					words[5]  <= {32'd0, sh_lat_sum};
					words[6]  <= {32'd0, sh_lat_max};
					words[7]  <= {32'd0, sh_lat_n};
					words[8]  <= {32'd0, sh_m0_rd};
					words[9]  <= {32'd0, sh_m0_wr};
					words[10] <= {32'd0, sh_m1_rd};
					words[11] <= {32'd0, sh_m1_wr};
					words[12] <= {32'd0, sh_m2_rd};
					words[13] <= {32'd0, sh_m2_wr};
					words[14] <= {32'd0, sh_lat_bin0};
					words[15] <= {32'd0, sh_lat_bin1};
					words[16] <= {32'd0, sh_lat_bin2};
					words[17] <= {32'd0, sh_lat_bin3};
					words[18] <= {32'd0, sh_lat_bin4};
					words[19] <= {32'd0, sh_lat_bin5};
					words[20] <= {32'd0, sh_rd_cmds};
					words[21] <= {32'd0, sh_burst_sum};
					// packed: {issue_cyc[31:0], single_cmds[31:0]}
					words[22] <= {sh_issue_cyc, sh_single_cmds};
					words[23] <= {16'd0, snap_seq, MAGIC};
					words[0]  <= {sh_sat_flags, snap_seq, VER, MAGIC};
					step <= 5'd0;
					st <= ST_WR[1:0];
				end
				ST_WR[1:0]: begin
					DDRAM_WE <= 1'b1;
					DDRAM_BURSTCNT <= 8'd1;
					DDRAM_BE <= 8'hFF;
					DDRAM_ADDR <= BASE_W + {24'd0, wsel};
					DDRAM_DIN <= words[wsel];
					if (!DDRAM_BUSY) begin
						if (step == 5'd23) begin
							// last write accepted (header)
							DDRAM_WE <= 1'b0;
							step <= 5'd0;
							st <= ST_IDLE[1:0];
						end else begin
							step <= step + 5'd1;
						end
					end
				end
				default: st <= ST_IDLE[1:0];
				endcase
			end
		end
	end

endmodule

`default_nettype wire
