// Offline Verilator TB: ddr_publish_kick_mbox (module-alone).
// Covers: PLXG magic decode → SRC/BANK/LEN latch → start_pulse → PLXH busy/done sticky.
// NO device / NO quartus / FIT_GO=NO. pub_* stubbed (no full engine).
`timescale 1ns / 1ps

module ddr_publish_kick_mbox_tb;
	localparam [31:0] DOORBELL_PHYS = 32'h302F_F000;
	localparam int    ADDR_W = 29;
	// Fast poll for sim (default RTL POLL_DIV_BITS=8)
	localparam int    POLL_DIV_BITS = 2;

	localparam [31:0] OFF_PLXG = 32'h140;
	localparam [31:0] OFF_SRC  = 32'h148;
	localparam [31:0] OFF_LEN  = 32'h150;
	localparam [31:0] OFF_PLXH = 32'h158;

	localparam [31:0] MAGIC_G = 32'h504C_5847; // "PLXG"
	localparam [31:0] MAGIC_H = 32'h504C_5848; // "PLXH"

	// Host ABI bitfields (mailbox_abi_spec.hpp / path WT LAND 377d2a39)
	// PLXG_HI: start_w[0] start_tog[1] clr_done[2] clr_err[3] bank_sel[4]
	//          use_bsel[5] abort[6] cmd_seq[31:16]
	// PLXH_HI: busy[0] done_sticky[1] err_align[2] err_timeout[3]
	//          err_busy_kick[4] accepted[5] done_seq[31:16]

	reg clk = 0;
	reg reset = 1;
	always #5 clk = ~clk;

	reg  pub_busy = 0;
	reg  pub_done_pulse = 0;
	reg  pub_err = 0;

	wire start_pulse;
	wire bank_sel;
	wire [31:0] src_phys, bank_phys, frame_bytes;
	wire cmd_mode_copy, ring_doorbell;
	wire bus_want;

	reg         DDRAM_BUSY = 0;
	wire [7:0]  DDRAM_BURSTCNT;
	wire [ADDR_W-1:0] DDRAM_ADDR;
	reg  [63:0] DDRAM_DOUT = 0;
	reg         DDRAM_DOUT_READY = 0;
	wire        DDRAM_RD, DDRAM_WE;
	wire [63:0] DDRAM_DIN;
	wire [7:0]  DDRAM_BE;

	// Sparse mailbox image (host-writable + PLXH capture)
	reg [63:0] mem_plxg = 0;
	reg [63:0] mem_src  = 0;  // [31:0]=SRC [63:32]=BANK
	reg [63:0] mem_len  = 0;  // [31:0]=FRAME_BYTES
	reg [63:0] mem_plxh = 0;

	// Qword addresses (truncate to ADDR_W explicitly)
	wire [ADDR_W-1:0] Q_PLXG = ADDR_W'((DOORBELL_PHYS + OFF_PLXG) >> 3);
	wire [ADDR_W-1:0] Q_SRC  = ADDR_W'((DOORBELL_PHYS + OFF_SRC)  >> 3);
	wire [ADDR_W-1:0] Q_LEN  = ADDR_W'((DOORBELL_PHYS + OFF_LEN)  >> 3);
	wire [ADDR_W-1:0] Q_PLXH = ADDR_W'((DOORBELL_PHYS + OFF_PLXH) >> 3);

	integer fails;
	integer g;
	integer starts;
	reg saw_start;
	reg [31:0] cap_src, cap_bank, cap_len;
	reg cap_bank_sel;
	reg saw_busy_in_plxh;
	reg saw_done_in_plxh;
	reg [15:0] plxh_done_seq;
	reg [7:0] rd_left;
	reg [ADDR_W-1:0] rd_addr;
	reg wr_busy_cy;
	reg auto_pub; // when 1, start_pulse auto-asserts pub_busy
	// Single-driver pub_busy: force_idle_pub clears without done (G2 busy-kick)
	reg force_idle_pub;
	reg req_pub_done;

	ddr_publish_kick_mbox #(
		.DOORBELL_PHYS(DOORBELL_PHYS),
		.ADDR_W(ADDR_W),
		.POLL_DIV_BITS(POLL_DIV_BITS)
	) dut (
		.clk(clk),
		.reset(reset),
		.pub_busy(pub_busy),
		.pub_done_pulse(pub_done_pulse),
		.pub_err(pub_err),
		.start_pulse(start_pulse),
		.bank_sel(bank_sel),
		.src_phys(src_phys),
		.bank_phys(bank_phys),
		.frame_bytes(frame_bytes),
		.cmd_mode_copy(cmd_mode_copy),
		.ring_doorbell(ring_doorbell),
		.bus_want(bus_want),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE)
	);

	// f2sdram-ish model (accept → next-cycle beat; BUSY held while pending).
	// Default-clear BUSY when no pending rd/wr so a stalled master cannot wedge can_cmd.
	always @(posedge clk) begin
		if (reset) begin
			DDRAM_BUSY <= 1'b0;
			DDRAM_DOUT_READY <= 1'b0;
			DDRAM_DOUT <= 64'd0;
			rd_left <= 8'd0;
			wr_busy_cy <= 1'b0;
		end else begin
			DDRAM_DOUT_READY <= 1'b0;
			if (wr_busy_cy) begin
				wr_busy_cy <= 1'b0;
				DDRAM_BUSY <= 1'b0;
			end else if (rd_left != 8'd0) begin
				if (rd_addr == Q_PLXG)
					DDRAM_DOUT <= mem_plxg;
				else if (rd_addr == Q_SRC)
					DDRAM_DOUT <= mem_src;
				else if (rd_addr == Q_LEN)
					DDRAM_DOUT <= mem_len;
				else if (rd_addr == Q_PLXH)
					DDRAM_DOUT <= mem_plxh;
				else
					DDRAM_DOUT <= 64'hDEAD_BEEF_CAFE_BABE;
				DDRAM_DOUT_READY <= 1'b1;
				rd_addr <= rd_addr + {{(ADDR_W-1){1'b0}}, 1'b1};
				rd_left <= rd_left - 8'd1;
				if (rd_left == 8'd1)
					DDRAM_BUSY <= 1'b0;
			end else if (DDRAM_RD && !DDRAM_BUSY) begin
				rd_left <= (DDRAM_BURSTCNT == 8'd0) ? 8'd1 : DDRAM_BURSTCNT;
				rd_addr <= DDRAM_ADDR;
				DDRAM_BUSY <= 1'b1;
			end else if (DDRAM_WE && !DDRAM_BUSY) begin
				if (DDRAM_ADDR == Q_PLXG)
					mem_plxg <= DDRAM_DIN;
				else if (DDRAM_ADDR == Q_SRC)
					mem_src <= DDRAM_DIN;
				else if (DDRAM_ADDR == Q_LEN)
					mem_len <= DDRAM_DIN;
				else if (DDRAM_ADDR == Q_PLXH)
					mem_plxh <= DDRAM_DIN;
				wr_busy_cy <= 1'b1;
				DDRAM_BUSY <= 1'b1;
			end else begin
				// Idle: ensure BUSY cannot stick after master dropped RD/WE mid-flight
				DDRAM_BUSY <= 1'b0;
			end
		end
	end

	// Capture start edge params; single-driver pub_busy/pub_done_pulse
	always @(posedge clk) begin
		if (reset) begin
			saw_start <= 1'b0;
			cap_src <= 32'd0;
			cap_bank <= 32'd0;
			cap_len <= 32'd0;
			cap_bank_sel <= 1'b0;
			pub_busy <= 1'b0;
			pub_done_pulse <= 1'b0;
			pub_err <= 1'b0;
		end else begin
			pub_done_pulse <= 1'b0;
			if (start_pulse) begin
				saw_start <= 1'b1;
				cap_src <= src_phys;
				cap_bank <= bank_phys;
				cap_len <= frame_bytes;
				cap_bank_sel <= bank_sel;
				if (auto_pub)
					pub_busy <= 1'b1;
			end
			if (force_idle_pub)
				pub_busy <= 1'b0;
			if (req_pub_done) begin
				pub_busy <= 1'b0;
				pub_err <= 1'b0;
				pub_done_pulse <= 1'b1;
			end
		end
	end

	// Observe PLXH host-visible sticky (FPGA writes)
	always @(posedge clk) begin
		if (reset) begin
			saw_busy_in_plxh <= 1'b0;
			saw_done_in_plxh <= 1'b0;
			plxh_done_seq <= 16'd0;
		end else if (mem_plxh[31:0] == MAGIC_H) begin
			if (mem_plxh[32]) // busy
				saw_busy_in_plxh <= 1'b1;
			if (mem_plxh[33]) begin // done_sticky
				saw_done_in_plxh <= 1'b1;
				plxh_done_seq <= mem_plxh[63:48];
			end
		end
	end

	task automatic step;
		begin @(posedge clk); #1; end
	endtask

	task automatic host_program_kick;
		input [31:0] src;
		input [31:0] bank;
		input [31:0] len;
		input        bank_sel_i;
		input        start_w;
		input        start_tog;
		input [15:0] seq;
		reg [31:0] hi;
		begin
			hi = 32'd0;
			hi[0] = start_w;
			hi[1] = start_tog;
			hi[4] = bank_sel_i;
			hi[5] = 1'b1; // use_bank_sel
			hi[31:16] = seq;
			mem_src  = {bank, src};
			mem_len  = {32'd0, len};
			mem_plxg = {hi, MAGIC_G};
		end
	endtask

	task automatic wait_start;
		input integer maxc;
		begin
			g = 0;
			while (!saw_start && g < maxc) begin
				step();
				g = g + 1;
			end
		end
	endtask

	task automatic pub_finish;
		begin
			// Simulate engine completion a few cycles after start
			repeat (6) step();
			req_pub_done = 1'b1;
			step();
			req_pub_done = 1'b0;
			step();
		end
	endtask

	task automatic wait_plxh_done;
		input integer maxc;
		begin
			g = 0;
			while (!saw_done_in_plxh && g < maxc) begin
				step();
				g = g + 1;
			end
		end
	endtask

	task automatic reset_dut;
		begin
			reset = 1;
			auto_pub = 1;
			force_idle_pub = 0;
			req_pub_done = 0;
			saw_start = 0;
			saw_busy_in_plxh = 0;
			saw_done_in_plxh = 0;
			plxh_done_seq = 0;
			mem_plxg = 64'd0;
			mem_src  = 64'd0;
			mem_len  = 64'd0;
			mem_plxh = 64'd0;
			repeat (8) step();
			reset = 0;
			repeat (4) step();
		end
	endtask

	// G0: start_w rising edge → latch SRC/BANK/LEN → start_pulse → PLXH busy then done
	task automatic test_start_w;
		begin
			$display("=== G0 start_w rising + SRC/BANK/LEN + PLXH sticky ===");
			reset_dut();

			// Establish baseline last_start_w=0 (no start)
			host_program_kick(32'h3100_0000, 32'h3000_0000, 32'h0009_0000,
			                  1'b0, 1'b0, 1'b0, 16'h0001);
			repeat (80) step();

			// Rising start_w
			saw_start = 0;
			saw_busy_in_plxh = 0;
			saw_done_in_plxh = 0;
			host_program_kick(32'h3100_0040, 32'h3018_0000, 32'h0009_6000,
			                  1'b1, 1'b1, 1'b0, 16'h00A5);
			wait_start(800);

			if (!saw_start) begin
				$display("FAIL G0 no start_pulse plxh=%h st=%0d src_out=%h",
				         mem_plxh, dut.st, src_phys);
				fails = fails + 1;
			end else if (cap_src !== 32'h3100_0040 || cap_bank !== 32'h3018_0000 ||
			             cap_len !== 32'h0009_6000 || cap_bank_sel !== 1'b1) begin
				$display("FAIL G0 latch src=%h bank=%h len=%h bsel=%0d",
				         cap_src, cap_bank, cap_len, cap_bank_sel);
				fails = fails + 1;
			end else if (!cmd_mode_copy || ring_doorbell) begin
				$display("FAIL G0 mode/ring copy=%0d ring=%0d", cmd_mode_copy, ring_doorbell);
				fails = fails + 1;
			end else begin
				$display("PASS G0_LATCH src=%h bank=%h len=%h bsel=1",
				         cap_src, cap_bank, cap_len);
			end

			// busy should be posted to PLXH before start
			if (!saw_busy_in_plxh) begin
				repeat (40) step();
			end
			if (!(saw_busy_in_plxh || (mem_plxh[31:0] == MAGIC_H && mem_plxh[32]))) begin
				$display("FAIL G0 PLXH busy not posted (plxh=%h)", mem_plxh);
				fails = fails + 1;
			end else
				$display("PASS G0_BUSY plxh=%h", mem_plxh);

			pub_finish();
			wait_plxh_done(800);
			if (!saw_done_in_plxh || plxh_done_seq !== 16'h00A5) begin
				$display("FAIL G0 done sticky/seq plxh=%h done=%0d seq=%h",
				         mem_plxh, saw_done_in_plxh, plxh_done_seq);
				fails = fails + 1;
			end else if (mem_plxh[31:0] !== MAGIC_H) begin
				$display("FAIL G0 PLXH magic %h", mem_plxh[31:0]);
				fails = fails + 1;
			end else
				$display("PASS G0_DONE sticky seq=0x%h plxh=%h", plxh_done_seq, mem_plxh);
		end
	endtask

	// G1: preferred start_toggle edge
	task automatic test_toggle;
		begin
			$display("=== G1 start_toggle edge ===");
			reset_dut();

			// Baseline toggle=0
			host_program_kick(32'h3200_0000, 32'h3000_0000, 32'h0001_0000,
			                  1'b0, 1'b0, 1'b0, 16'h0011);
			repeat (80) step();

			saw_start = 0;
			saw_done_in_plxh = 0;
			host_program_kick(32'h3200_0080, 32'h3000_0000, 32'h0002_0000,
			                  1'b0, 1'b0, 1'b1, 16'h0012);
			wait_start(800);

			if (!saw_start) begin
				$display("FAIL G1 no start_pulse on toggle");
				fails = fails + 1;
			end else if (cap_src !== 32'h3200_0080 || cap_len !== 32'h0002_0000) begin
				$display("FAIL G1 latch src=%h len=%h", cap_src, cap_len);
				fails = fails + 1;
			end else begin
				$display("PASS G1_TOGGLE src=%h len=%h", cap_src, cap_len);
			end

			pub_finish();
			wait_plxh_done(800);
			if (!saw_done_in_plxh || plxh_done_seq !== 16'h0012) begin
				$display("FAIL G1 done seq plxh=%h", mem_plxh);
				fails = fails + 1;
			end else
				$display("PASS G1_DONE seq=0x%h", plxh_done_seq);
		end
	endtask

	// G2: while posted_busy, mbox YIELDS bus (no PLXG poll) so u_pub COPY
	// can run (device BusyStuck fix). Second host kick mid-job must NOT
	// produce an extra start_pulse. Mid-job err_busy_kick sampling is deferred
	// until after done (no monopolizing m2 poll).
	task automatic test_busy_kick;
		begin
			$display("=== G2 busy-kick yield (no second start mid-job) ===");
			reset_dut();

			// Baseline toggle=0, start_w=0
			host_program_kick(32'h3300_0000, 32'h3000_0000, 32'h0001_0000,
			                  1'b0, 1'b0, 1'b0, 16'h0020);
			repeat (80) step();

			// First start via toggle 0→1
			saw_start = 0;
			host_program_kick(32'h3300_0000, 32'h3000_0000, 32'h0001_0000,
			                  1'b0, 1'b0, 1'b1, 16'h0021);
			wait_start(800);
			if (!saw_start) begin
				$display("FAIL G2 first start missing");
				fails = fails + 1;
			end
			starts = saw_start ? 1 : 0;

			// Drop pub_busy without done; kick stays posted_busy and must yield
			// (bus_want=0) — re-kick must not start until job retires.
			auto_pub = 0;
			force_idle_pub = 1;
			step();
			force_idle_pub = 0;
			repeat (8) step();
			// Second host command while posted_busy
			mem_src = {32'h3000_0000, 32'h33FF_0000};
			mem_len = {32'd0, 32'h0001_0000};
			// hi: tog=0 start_w=0 use_bsel=1 seq=0x22
			mem_plxg = {32'h0022_0020, MAGIC_G};
			g = 0;
			while (g < 400) begin
				if (start_pulse) starts = starts + 1;
				if (dut.bus_want && dut.posted_busy)
					$display("WARN G2 bus_want while posted_busy (should yield)");
				step();
				g = g + 1;
			end
			if (starts != 1) begin
				$display("FAIL G2 unexpected extra start starts=%0d posted=%0d",
				         starts, dut.posted_busy);
				fails = fails + 1;
			end else if (!dut.posted_busy) begin
				$display("FAIL G2 expected posted_busy still set");
				fails = fails + 1;
			end else
				$display("PASS G2_YIELD_NO_SECOND_START starts=%0d posted=%0d",
				         starts, dut.posted_busy);

			// Clean up
			req_pub_done = 1;
			step();
			req_pub_done = 0;
			repeat (40) step();
		end
	endtask

	// G_NEG: wrong magic must not start
	task automatic test_no_magic;
		begin
			$display("=== G_NEG no-magic must not start ===");
			reset_dut();
			mem_src = {32'h3000_0000, 32'h3100_0000};
			mem_len = {32'd0, 32'h0001_0000};
			// garbage magic + start_w=1 + seq
			mem_plxg = {32'h0001_0001, 32'hDEAD_BEEF};
			repeat (160) step();
			if (saw_start) begin
				$display("FAIL G_NEG started without PLXG magic");
				fails = fails + 1;
			end else
				$display("PASS G_NEG no start without magic");
		end
	endtask

	initial begin
		fails = 0;
		auto_pub = 1;
		$display("=== test_ddr_publish_kick_mbox_tb EXECUTED ===");
		$display("RTL=ddr_publish_kick_mbox DOORBELL=0x%h POLL_DIV_BITS=%0d",
		         DOORBELL_PHYS, POLL_DIV_BITS);
		$display("Q_PLXG=%h Q_SRC=%h Q_LEN=%h Q_PLXH=%h",
		         Q_PLXG, Q_SRC, Q_LEN, Q_PLXH);

		test_start_w();
		test_toggle();
		test_busy_kick();
		test_no_magic();

		if (fails == 0) begin
			$display("PASS ddr_publish_kick_mbox_tb all");
			$display("PASS G0");
			$display("PASS G1");
			$display("PASS G2");
			$display("PASS G_NEG");
			$finish;
		end else begin
			$display("FAIL ddr_publish_kick_mbox_tb fails=%0d", fails);
			$fatal(1);
		end
	end

	// Safety timeout
	initial begin
		#5_000_000;
		$display("FAIL timeout");
		$fatal(1);
	end
endmodule
