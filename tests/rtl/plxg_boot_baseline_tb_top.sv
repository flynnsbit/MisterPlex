// plxg_boot_baseline_tb_top — rd-duck retained-DDR / fresh-zero / pre-poll race.
// seed_retained=1: preseed epoch=1,seq=N; baseline without commit; publish N+1 commits.
// seed_retained=0: zero DDR; empty observation completes baseline; ONE publish commits.
// seed_race=1 (with seed_retained=0): valid host record present at reset release
//   (write-before-first-poll). First poll BASELINES without commit — liveness gap.
//   Single host_publish must NOT suffice if it only re-hits same pair; second
//   distinct seq (host_publish_2) commits. Not stale-live closure.
// FAULT_PLXG_NO_BASELINE: commit on retained immediately.
// FAULT_PLXG_EMPTY_NO_BASELINE: empty does not complete; first valid swallowed.
`timescale 1ns / 1ps
`default_nettype none

module plxg_boot_baseline_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        host_publish,
	input  wire        host_publish_2, // second distinct seq (EnsureLive half)
	input  wire        seed_retained, // 1=retained seq=7, 0=fresh/race
	input  wire        seed_race,     // 1=valid pre-poll host seq=3 at release
	output wire [15:0] last_seq,
	output wire [13:0] last_epoch,
	output wire        boot_baseline_done,
	output wire [31:0] cnt_commit,
	output wire [31:0] cnt_baseline,
	output wire [31:0] cnt_bad_magic,
	output wire        commit_pulse,
	output wire        wr_en_pulse
);

	wire        want, busy, rd, we, dout_ready;
	wire  [7:0] burstcnt, be;
	wire [28:0] addr;
	wire [63:0] din, dout;
	wire        wr_en, commit;
	wire  [2:0] wr_idx;
	wire [63:0] wr_data;
	wire        busy_poll;
	wire [31:0] cnt_torn, cnt_bad_epoch;

	plxg_ddr_poller #(
		.ENABLE(1'b1),
		.BOOT_DOORBELL(32'h300F_F000),
		.PLXG_OFF(32'h800),
		.POLL_DIV(16'd2)
	) u_poll (
		.clk(clk),
		.reset(reset),
		.want(want),
		.busy(busy),
		.burstcnt(burstcnt),
		.addr(addr),
		.dout(dout),
		.dout_ready(dout_ready),
		.rd(rd),
		.din(din),
		.be(be),
		.we(we),
		.wr_en(wr_en),
		.wr_idx(wr_idx),
		.wr_data(wr_data),
		.commit(commit),
		.last_seq(last_seq),
		.last_epoch(last_epoch),
		.boot_baseline_done(boot_baseline_done),
		.busy_poll(busy_poll),
		.cnt_commit(cnt_commit),
		.cnt_baseline(cnt_baseline),
		.cnt_bad_magic(cnt_bad_magic),
		.cnt_torn(cnt_torn),
		.cnt_bad_epoch(cnt_bad_epoch)
	);

	assign commit_pulse = commit;
	assign wr_en_pulse  = wr_en;

	localparam [28:0] Q0_W = 29'((32'h300F_F000 + 32'h800) >> 3);
	localparam [15:0] RET_SEQ = 16'd7;
	localparam [15:0] RACE_SEQ = 16'd3;
	reg [15:0] seq_mem;
	reg        valid_mem; // 0 = fresh zero DDR (no magic)
	reg        host_publish_d1, host_publish_2_d1;
	// epoch=1 in hi[15:2] → bits of q0[47:34]; pack as 16'h0007 with seq in [63:48].
	wire [63:0] q0 = valid_mem ? {seq_mem, 16'h0007, 32'h504C5847} : 64'd0;
	wire [63:0] q1 = 64'(624) | (64'(480) << 16);
	wire [63:0] q2 = 64'(624) | (64'(480) << 16) | (64'(624) << 32) | (64'(480) << 48);
	wire [63:0] q3 = 64'(624) | (64'(312) << 16) | (64'(624) << 32) | (64'(480) << 48);
	wire [63:0] q4 = 64'd0;
	wire [63:0] q5 = 64'd0;

	function automatic [63:0] mem_rd(input [28:0] a);
		begin
			if (!valid_mem)
				mem_rd = 64'd0;
			else if (a == Q0_W)              mem_rd = q0;
			else if (a == Q0_W + 29'd1) mem_rd = q1;
			else if (a == Q0_W + 29'd2) mem_rd = q2;
			else if (a == Q0_W + 29'd3) mem_rd = q3;
			else if (a == Q0_W + 29'd4) mem_rd = q4;
			else if (a == Q0_W + 29'd5) mem_rd = q5;
			else                        mem_rd = 64'd0;
		end
	endfunction

	reg        busy_r, dout_ready_r, rd_pend;
	reg  [1:0] rd_delay;
	reg [28:0] rd_addr_r;
	reg [63:0] dout_r;
	assign busy = busy_r;
	assign dout = dout_r;
	assign dout_ready = dout_ready_r;

	always @(posedge clk) begin
		if (reset) begin
			busy_r <= 1'b0;
			dout_ready_r <= 1'b0;
			rd_pend <= 1'b0;
			rd_delay <= 2'd0;
			rd_addr_r <= 29'd0;
			dout_r <= 64'd0;
			// Sample seed while reset held (C++ drives before release).
			host_publish_d1 <= 1'b0;
			host_publish_2_d1 <= 1'b0;
			if (seed_retained) begin
				seq_mem   <= RET_SEQ;
				valid_mem <= 1'b1;
			end else if (seed_race) begin
				// Pre-poll host write already in DDR (liveness race).
				seq_mem   <= RACE_SEQ;
				valid_mem <= 1'b1;
			end else begin
				seq_mem   <= 16'd0;
				valid_mem <= 1'b0;
			end
		end else begin
			host_publish_d1 <= host_publish;
			host_publish_2_d1 <= host_publish_2;
			// Rising-edge only — multi-cycle hold must not multi-bump seq.
			// Retained: 7→8. Fresh: first publish seq=1.
			// Race: host_publish alone does not change pair; publish_2 does +1.
			if (host_publish && !host_publish_d1) begin
				if (seed_retained && seq_mem == RET_SEQ)
					seq_mem <= RET_SEQ + 16'd1;
				else if (!seed_retained && !seed_race && !valid_mem) begin
					valid_mem <= 1'b1;
					seq_mem   <= 16'd1;
				end
			end
			if (host_publish_2 && !host_publish_2_d1) begin
				if (valid_mem)
					seq_mem <= seq_mem + 16'd1;
				else begin
					valid_mem <= 1'b1;
					seq_mem   <= 16'd1;
				end
			end
			dout_ready_r <= 1'b0;
			busy_r <= 1'b0;
			if (rd && !rd_pend) begin
				busy_r <= 1'b1;
				rd_pend <= 1'b1;
				rd_delay <= 2'd2;
				rd_addr_r <= addr;
			end else if (rd_pend) begin
				if (rd_delay != 2'd0)
					rd_delay <= rd_delay - 2'd1;
				else begin
					dout_r <= mem_rd(rd_addr_r);
					dout_ready_r <= 1'b1;
					rd_pend <= 1'b0;
				end
			end
		end
	end
endmodule
`default_nettype wire
