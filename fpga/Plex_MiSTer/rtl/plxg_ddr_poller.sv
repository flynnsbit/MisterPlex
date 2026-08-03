// plxg_ddr_poller — read 5-qword PLXG record from DDR and feed present_geom_latch.
//
// Bootstrap address FIXED at product legacy doorbell + 0x2C0 (0x300FF2C0).
//
// Atomic snapshot (rd-duck): host publishes q1..q4 then q0 last. Poller reads
// q0..q4 then RE-READS q0; commit only if magic+seq match the first q0 sample
// (rejects torn mid-write snapshots).
//
// Master port matches ddr_bus_arbiter m1 (single-beat RD). Share m1 only via
// ddr_m1_subarb (latched owner through response) — never combinational mux.

`timescale 1ns / 1ps
`default_nettype none

module plxg_ddr_poller #(
	parameter bit        ENABLE        = 1'b0,
	parameter [31:0]     BOOT_DOORBELL = 32'h300F_F000,
	parameter [31:0]     PLXG_OFF      = 32'h2C0,
	parameter [15:0]     POLL_DIV      = 16'd512
)(
	input  wire        clk,
	input  wire        reset,

	output reg         want,
	input  wire        busy,
	output reg  [7:0]  burstcnt,
	output reg  [28:0] addr,
	input  wire [63:0] dout,
	input  wire        dout_ready,
	output reg         rd,
	output wire [63:0] din,
	output wire [7:0]  be,
	output wire        we,

	output reg         wr_en,
	output reg  [2:0]  wr_idx,
	output reg  [63:0] wr_data,
	output reg         commit,

	output reg  [15:0] last_seq,
	output reg         busy_poll,
	output reg  [31:0] cnt_commit,
	output reg  [31:0] cnt_bad_magic,
	output reg  [31:0] cnt_torn
);

	assign din = 64'd0;
	assign be  = 8'd0;
	assign we  = 1'b0;

	localparam [31:0] MAGIC = 32'h504C_5847; // PLXG
	localparam [28:0] Q0_W = 29'((BOOT_DOORBELL + PLXG_OFF) >> 3);

	localparam [2:0] S_IDLE    = 3'd0;
	localparam [2:0] S_ISSUE   = 3'd1;
	localparam [2:0] S_WAIT    = 3'd2;
	localparam [2:0] S_VRF_Q0  = 3'd3; // re-read q0
	localparam [2:0] S_WAIT_V  = 3'd4;
	localparam [2:0] S_PUSH    = 3'd5;
	localparam [2:0] S_COMMIT  = 3'd6;

	reg [2:0]  st;
	reg [15:0] poll_ctr;
	reg [2:0]  qi;
	reg [63:0] snap [0:4];
	reg [15:0] snap_seq;
	reg        verify_phase; // 1 = issuing q0 re-read

	integer ti;
	always @(posedge clk) begin
		if (reset) begin
			st          <= S_IDLE;
			poll_ctr    <= 16'd0;
			qi          <= 3'd0;
			want        <= 1'b0;
			burstcnt    <= 8'd1;
			addr        <= 29'd0;
			rd          <= 1'b0;
			wr_en       <= 1'b0;
			wr_idx      <= 3'd0;
			wr_data     <= 64'd0;
			commit      <= 1'b0;
			last_seq    <= 16'd0;
			busy_poll   <= 1'b0;
			cnt_commit  <= 32'd0;
			cnt_bad_magic <= 32'd0;
			cnt_torn    <= 32'd0;
			snap_seq    <= 16'd0;
			verify_phase <= 1'b0;
			for (ti = 0; ti < 5; ti = ti + 1)
				snap[ti] <= 64'd0;
		end else begin
			wr_en  <= 1'b0;
			commit <= 1'b0;
			rd     <= 1'b0;
			burstcnt <= 8'd1;

			if (!ENABLE) begin
				st        <= S_IDLE;
				want      <= 1'b0;
				busy_poll <= 1'b0;
				poll_ctr  <= 16'd0;
			end else begin
				case (st)
				S_IDLE: begin
					busy_poll <= 1'b0;
					want      <= 1'b0;
					verify_phase <= 1'b0;
					if (poll_ctr >= POLL_DIV) begin
						poll_ctr  <= 16'd0;
						qi        <= 3'd0;
						st        <= S_ISSUE;
						busy_poll <= 1'b1;
						want      <= 1'b1;
					end else
						poll_ctr <= poll_ctr + 16'd1;
				end
				S_ISSUE: begin
					want <= 1'b1;
					addr <= Q0_W + {26'd0, qi};
					if (!busy) begin
						rd <= 1'b1;
						st <= S_WAIT;
					end
				end
				S_WAIT: begin
					want <= 1'b1;
					if (dout_ready) begin
						snap[qi] <= dout;
						if (qi == 3'd0) begin
							if (dout[31:0] != MAGIC) begin
								cnt_bad_magic <= cnt_bad_magic + 32'd1;
								want <= 1'b0;
								st   <= S_IDLE;
								busy_poll <= 1'b0;
							end else if (dout[63:48] == last_seq) begin
								// stale seq — nothing new
								want <= 1'b0;
								st   <= S_IDLE;
								busy_poll <= 1'b0;
							end else begin
								snap_seq <= dout[63:48];
								qi <= 3'd1;
								st <= S_ISSUE;
							end
						end else if (qi == 3'd4) begin
							// Finished q1..q4; re-read q0 for tear check
							qi <= 3'd0;
							verify_phase <= 1'b1;
							st <= S_VRF_Q0;
						end else begin
							qi <= qi + 3'd1;
							st <= S_ISSUE;
						end
					end
				end
				S_VRF_Q0: begin
					want <= 1'b1;
					addr <= Q0_W; // q0 again
					if (!busy) begin
						rd <= 1'b1;
						st <= S_WAIT_V;
					end
				end
				S_WAIT_V: begin
					want <= 1'b1;
					if (dout_ready) begin
						// Must match first q0 sample (magic+seq+flags)
						if (dout != snap[0]) begin
							cnt_torn <= cnt_torn + 32'd1;
							want <= 1'b0;
							st   <= S_IDLE;
							busy_poll <= 1'b0;
						end else begin
							qi <= 3'd0;
							st <= S_PUSH;
							want <= 1'b0;
						end
					end
				end
				S_PUSH: begin
					want    <= 1'b0;
					wr_en   <= 1'b1;
					wr_idx  <= qi;
					wr_data <= snap[qi];
					if (qi == 3'd4) begin
						qi <= 3'd0;
						st <= S_COMMIT;
					end else
						qi <= qi + 3'd1;
				end
				S_COMMIT: begin
					want       <= 1'b0;
					commit     <= 1'b1;
					last_seq   <= snap_seq;
					cnt_commit <= cnt_commit + 32'd1;
					st         <= S_IDLE;
					busy_poll  <= 1'b0;
				end
				default: st <= S_IDLE;
				endcase
			end
		end
	end
endmodule

`default_nettype wire
