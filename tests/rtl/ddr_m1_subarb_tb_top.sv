// ddr_m1_subarb + real ddr_bitstream_reader reset telemetry + plxg_ddr_poller.
// Proves PLXG still receives q0 after stream's post-reset 9× WE publish
// (rd-duck: WE must not stick outstanding).
`timescale 1ns / 1ps
`default_nettype none

module ddr_m1_subarb_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        stream_enable,
	output wire [1:0]  grant,
	output wire        stream_want,
	output wire        plxg_want,
	output wire        m_we,
	output wire        m_rd,
	output wire [31:0] stream_we_count,
	output wire [31:0] plxg_rd_count,
	output wire [31:0] plxg_cnt_commit,
	output wire [31:0] plxg_cnt_baseline,
	output wire        plxg_boot_baseline_done,
	output wire [31:0] plxg_cnt_torn,
	output wire [31:0] plxg_cnt_bad,
	output wire [15:0] plxg_last_seq,
	output wire        plxg_commit_pulse,
	output wire        plxg_got_q0
);

	wire        s_want, s_busy, s_rd, s_we, s_dout_ready;
	wire  [7:0] s_burstcnt, s_be;
	wire [28:0] s_addr;
	wire [63:0] s_din, s_dout;
	wire        p_want, p_busy, p_rd, p_we, p_dout_ready;
	wire  [7:0] p_burstcnt, p_be;
	wire [28:0] p_addr;
	wire [63:0] p_din, p_dout;

	wire        m_want, m_busy, m_rd_w, m_we_w, m_dout_ready;
	wire  [7:0] m_burstcnt, m_be;
	wire [28:0] m_addr;
	wire [63:0] m_din, m_dout;

	assign m_we = m_we_w;
	assign m_rd = m_rd_w;
	assign stream_want = s_want;
	assign plxg_want = p_want;

	wire        br_out_valid, br_out_flush, br_active;
	wire  [7:0] br_out_byte;
	wire [31:0] br_bytes_out, br_host_wc, br_fpga_rc;
	wire [15:0] br_underrun, br_overrun;

	ddr_bitstream_reader #(
		.POLL_DIV_BITS(8)
	) u_stream (
		.clk(clk),
		.reset(reset),
		.enable(stream_enable),
		.flush(1'b0),
		.out_valid(br_out_valid),
		.out_byte(br_out_byte),
		.out_flush(br_out_flush),
		.out_full(1'b0),
		.bus_want(s_want),
		.DDRAM_BUSY(s_busy),
		.DDRAM_BURSTCNT(s_burstcnt),
		.DDRAM_ADDR(s_addr),
		.DDRAM_DOUT(s_dout),
		.DDRAM_DOUT_READY(s_dout_ready),
		.DDRAM_RD(s_rd),
		.DDRAM_DIN(s_din),
		.DDRAM_BE(s_be),
		.DDRAM_WE(s_we),
		.active(br_active),
		.bytes_out(br_bytes_out),
		.underrun_count(br_underrun),
		.overrun_count(br_overrun),
		.host_write_count(br_host_wc),
		.fpga_read_count(br_fpga_rc)
	);

	wire        plxg_wr_en, plxg_commit, plxg_busy_poll;
	wire  [2:0] plxg_wr_idx;
	wire [63:0] plxg_wr_data;

	plxg_ddr_poller #(
		.ENABLE(1'b1),
		.BOOT_DOORBELL(32'h300F_F000),
		.PLXG_OFF(32'h800),
		.POLL_DIV(16'd4)
	) u_plxg (
		.clk(clk),
		.reset(reset),
		.want(p_want),
		.busy(p_busy),
		.burstcnt(p_burstcnt),
		.addr(p_addr),
		.dout(p_dout),
		.dout_ready(p_dout_ready),
		.rd(p_rd),
		.din(p_din),
		.be(p_be),
		.we(p_we),
		.wr_en(plxg_wr_en),
		.wr_idx(plxg_wr_idx),
		.wr_data(plxg_wr_data),
		.commit(plxg_commit),
		.last_seq(plxg_last_seq),
		.last_epoch(),
		.boot_baseline_done(plxg_boot_baseline_done),
		.busy_poll(plxg_busy_poll),
		.cnt_commit(plxg_cnt_commit),
		.cnt_baseline(plxg_cnt_baseline),
		.cnt_bad_magic(plxg_cnt_bad),
		.cnt_torn(plxg_cnt_torn),
		.cnt_bad_epoch()
	);

	ddr_m1_subarb u_sub (
		.clk(clk),
		.reset(reset),
		.s_want(s_want),
		.s_busy(s_busy),
		.s_burstcnt(s_burstcnt),
		.s_addr(s_addr),
		.s_dout(s_dout),
		.s_dout_ready(s_dout_ready),
		.s_rd(s_rd),
		.s_din(s_din),
		.s_be(s_be),
		.s_we(s_we),
		.p_want(p_want),
		.p_busy(p_busy),
		.p_burstcnt(p_burstcnt),
		.p_addr(p_addr),
		.p_dout(p_dout),
		.p_dout_ready(p_dout_ready),
		.p_rd(p_rd),
		.p_din(p_din),
		.p_be(p_be),
		.p_we(p_we),
		.m_want(m_want),
		.m_busy(m_busy),
		.m_burstcnt(m_burstcnt),
		.m_addr(m_addr),
		.m_dout(m_dout),
		.m_dout_ready(m_dout_ready),
		.m_rd(m_rd_w),
		.m_din(m_din),
		.m_be(m_be),
		.m_we(m_we_w),
		.grant(grant)
	);

	// Simple DDR slave: WE accept (busy pulse, no dout_ready); RD → delayed response.
	reg        busy_r;
	reg        rd_pend;
	reg  [1:0] rd_delay;
	reg [28:0] rd_addr_r;
	reg [63:0] dout_r;
	reg        dout_ready_r;
	reg [31:0] we_cnt, rd_cnt;
	reg        got_q0_r;
	reg        commit_r;

	localparam [28:0] Q0_W = 29'((32'h300F_F000 + 32'h800) >> 3);
	// q0: seq | epoch=1,win,geom | magic. Host default epoch=1 is NOT a boot nonce.
	// After poller boot-baseline of seq=1, TB bumps to seq=2 (post-reset publish).
	reg [15:0] plxg_seq_mem;
	// flags hi16: [15:2]=epoch=1, [1]=geom, [0]=win → 0x0007
	wire [63:0] PLXG_Q0 = {plxg_seq_mem, 16'h0007, 32'h504C5847};
	localparam [63:0] PLXG_Q1B = 64'(960) | (64'(540) << 16);
	localparam [63:0] PLXG_Q2B = 64'(1280) | (64'(720) << 16) | (64'(960) << 32) | (64'(540) << 48);
	localparam [63:0] PLXG_Q3B = 64'(960) | (64'(480) << 16) | (64'(960) << 32) | (64'(540) << 48);
	localparam [63:0] PLXG_Q4B = 64'd0;
	localparam [63:0] PLXG_Q5B = 64'd0;

	function automatic [63:0] mem_rd(input [28:0] a);
		begin
			if (a == Q0_W)              mem_rd = PLXG_Q0;
			else if (a == Q0_W + 29'd1) mem_rd = PLXG_Q1B;
			else if (a == Q0_W + 29'd2) mem_rd = PLXG_Q2B;
			else if (a == Q0_W + 29'd3) mem_rd = PLXG_Q3B;
			else if (a == Q0_W + 29'd4) mem_rd = PLXG_Q4B;
			else if (a == Q0_W + 29'd5) mem_rd = PLXG_Q5B;
			else                        mem_rd = 64'd0;
		end
	endfunction

	assign m_busy       = busy_r;
	assign m_dout       = dout_r;
	assign m_dout_ready = dout_ready_r;
	assign stream_we_count = we_cnt;
	assign plxg_rd_count   = rd_cnt;
	assign plxg_got_q0     = got_q0_r;
	assign plxg_commit_pulse = commit_r;

	always @(posedge clk) begin
		if (reset) begin
			busy_r       <= 1'b0;
			rd_pend      <= 1'b0;
			rd_delay     <= 2'd0;
			rd_addr_r    <= 29'd0;
			dout_r       <= 64'd0;
			dout_ready_r <= 1'b0;
			we_cnt       <= 32'd0;
			rd_cnt       <= 32'd0;
			got_q0_r     <= 1'b0;
			commit_r     <= 1'b0;
			plxg_seq_mem <= 16'd1; // retained epoch=1,seq=1 across "FPGA reset"
		end else begin
			dout_ready_r <= 1'b0;
			commit_r     <= plxg_commit;
			// Post-baseline host publication: bump seq so poller may promote.
			if (plxg_boot_baseline_done && plxg_seq_mem == 16'd1 && plxg_cnt_commit == 32'd0)
				plxg_seq_mem <= 16'd2;
			busy_r       <= 1'b0;

			if (rd_pend) begin
				if (rd_delay != 2'd0)
					rd_delay <= rd_delay - 2'd1;
				if (rd_delay == 2'd1) begin
					dout_r       <= mem_rd(rd_addr_r);
					dout_ready_r <= 1'b1;
					rd_pend      <= 1'b0;
					if (rd_addr_r == Q0_W)
						got_q0_r <= 1'b1;
				end else begin
					busy_r <= 1'b1;
				end
			end else if (m_want && m_we_w && !busy_r) begin
				// Accept WE — brief busy, NO dout_ready (real DDR write path).
				we_cnt <= we_cnt + 32'd1;
				busy_r <= 1'b1;
			end else if (m_want && m_rd_w && !busy_r) begin
				rd_pend   <= 1'b1;
				rd_delay  <= 2'd2;
				rd_addr_r <= m_addr;
				busy_r    <= 1'b1;
				if (grant == 2'd2)
					rd_cnt <= rd_cnt + 32'd1;
			end
		end
	end
endmodule

`default_nettype wire
