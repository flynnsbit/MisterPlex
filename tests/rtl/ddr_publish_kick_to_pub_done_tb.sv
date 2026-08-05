// ddr_publish_kick_to_pub_done_tb — OFFLINE compose Verilator TB
//
// Compose: kick_mbox + ddr_publish_path/engine + Plex PRODUCT_WIRE m2 mux
//           + ddr_bus_arbiter3 + simple f2sdram slave.
// Goal: pin stop-cause of silicon BusyStuck hi=0x21 offline (R5 residual).
// R8: also pin false-done / no bank write (G_CONTENT bank==staging after done).
// R9: bank dest — eng must land at programmed bank_phys (0x30000000), not bank1
//     (0x30180000) when use_bank_sel=0 (device face).
//
// Cases (CI gate): C0_NOPRESENT (+G_CONTENT + G_BANK0_LAND), C4_YIELD_REGRESS,
//                  C3_KICK_GRANT_STUCK.
// NO device / NO Quartus / FIT_GO=NO. TB PASS ≠ silicon PASS.
//
// Pre-R8 false-green class: G2 counted beats (model accepts) only — could PASS
// while silicon bank stayed poison. G_CONTENT requires model bank==staging.
// Pre-R9 false-green: bank_sel=0 + use_bank_sel=1 made geom==LAB_BANK so
// bank_phys unused still greened G_CONTENT. C0 now programs device face
// use_bank_sel=0, bank_phys=0x30000000, bank_sel=1 (geom trap → bank1).
//
// Status: Memory/lab/status/UNIT_KICK_TO_PUB_DONE_TB_R9.txt
// Design: Memory/lab/status/DESIGN_CARD_PW_KICK_R9_BANK_DEST.txt

`timescale 1ns / 1ps
`default_nettype none

module ddr_publish_kick_to_pub_done_tb;
	localparam int    CLK_HALF      = 5;
	localparam int    ADDR_W        = 29;
	localparam int    POLL_DIV_BITS = 2;   // fast poll for sim
	localparam int    MAX_BURST     = 16;
	localparam int    M2_Q          = 8;
	localparam [31:0] DOORBELL_PHYS = 32'h302F_F000;
	localparam [31:0] PHYS_BASE     = 32'h3000_0000;
	localparam [31:0] BANK_STRIDE   = 32'h0018_0000;

	// Lab job (device content_match_lab face)
	localparam [31:0] LAB_SRC   = 32'h3060_1000;
	localparam [31:0] LAB_BANK  = 32'h3000_0000; // bank0 absolute (BANK_PHYS)
	localparam [31:0] LAB_BANK1 = 32'h3018_0000; // bank1 (wrong-bank residual)
	localparam [31:0] LAB_LEN   = 32'h0000_1000; // 4096 B
	localparam [15:0] LAB_SEQ   = 16'h00C1;

	localparam [31:0] OFF_PLXG = 32'h140;
	localparam [31:0] OFF_SRC  = 32'h148;
	localparam [31:0] OFF_LEN  = 32'h150;
	localparam [31:0] OFF_PLXH = 32'h158;
	localparam [31:0] MAGIC_G  = 32'h504C_5847; // "PLXG"
	localparam [31:0] MAGIC_H  = 32'h504C_5848; // "PLXH"

	// Named stop IDs (primary FAIL taxonomy)
	localparam [3:0]
		STOP_OK_DONE        = 4'd0,
		STOP_S0_START_EDGE  = 4'd1,
		STOP_S1_KICK_BAD    = 4'd2,
		STOP_S2_ENG_ACCEPT  = 4'd3,
		STOP_S3_CAN_START   = 4'd4,
		STOP_S4_M2_GRANT    = 4'd5,
		STOP_S5_COPY_RSP    = 4'd6,
		STOP_S6_NO_DONE_PULSE = 4'd7,
		STOP_S7_STATUS_WR   = 4'd8,
		STOP_TIMEOUT_OTHER  = 4'd9;

	reg clk = 0;
	reg reset = 1;
	always #CLK_HALF clk = ~clk;
	// m1 domain unused (bitstream want=0); same clock OK for arb3 CDC
	wire clk_m1 = clk;

	integer fails;
	integer case_fails;

	// ── kick_mbox ────────────────────────────────────────────────────────
	wire        kick_start;
	wire        kick_bank_sel;
	wire        kick_use_bank_sel;
	wire [31:0] kick_src_phys, kick_bank_phys, kick_frame_bytes;
	wire        pub_cmd_mode;
	wire        pub_ring_db;
	wire        kick_bus_want;
	wire  [7:0] kick_burstcnt, kick_be;
	wire [28:0] kick_addr;
	wire [63:0] kick_din;
	wire        kick_rd, kick_we;
	wire        kick_m2_busy;
	wire [63:0] kick_dout;
	wire        kick_dout_ready;

	// ── path / eng ───────────────────────────────────────────────────────
	wire        pub_busy, pub_done, pub_err, pub_job_legal, pub_src_aligned;
	wire        pub_bus_want;
	wire [31:0] pub_frame_bytes, pub_dst_bank, pub_db_phys, pub_bytes_copied;
	wire [15:0] pub_beats_rd, pub_beats_wr;
	wire  [7:0] pub_burstcnt, pub_be;
	wire [28:0] pub_addr;
	wire [63:0] pub_din;
	wire        pub_rd, pub_we;
	wire        pub_m2_busy;
	wire [63:0] pub_dout;
	wire        pub_dout_ready;
	wire [63:0] pub_db_word = 64'h0;

	// R5 face: present_want=0 always (C0)
	reg present_want;

	// ── m2 mux (Plex.sv PRODUCT_WIRE rules) ──────────────────────────────
	reg  kick_grant;
	// C3 fault: force kick ownership after accept/start (reproduce 0x21)
	reg  force_kick_sel;
	// C5 twin (optional): force kick bus_want high while posted (not CI default)
	reg  force_kick_want;

	wire kick_bus_want_eff = force_kick_want ? 1'b1 : kick_bus_want;

	always @(posedge clk) begin
		if (reset)
			kick_grant <= 1'b0;
		else if (kick_grant)
			kick_grant <= kick_bus_want_eff;
		else if (kick_bus_want_eff && !pub_busy && !pub_bus_want)
			kick_grant <= 1'b1;
	end

	wire m2_sel_kick_nat = kick_grant || (kick_bus_want_eff && !pub_busy && !pub_bus_want);
	wire m2_sel_kick     = force_kick_sel ? 1'b1 : m2_sel_kick_nat;
	wire m2_sel_pub      = !m2_sel_kick;
	wire m2_want         = m2_sel_kick ? kick_bus_want_eff : pub_bus_want;
	wire  [7:0] m2_burstcnt = m2_sel_kick ? kick_burstcnt : pub_burstcnt;
	wire [28:0] m2_addr     = m2_sel_kick ? kick_addr     : pub_addr;
	wire [63:0] m2_din      = m2_sel_kick ? kick_din      : pub_din;
	wire  [7:0] m2_be       = m2_sel_kick ? kick_be       : pub_be;
	wire        m2_rd       = m2_sel_kick ? kick_rd       : pub_rd;
	wire        m2_we       = m2_sel_kick ? kick_we       : pub_we;

	wire        m2_busy_phys;
	wire [63:0] m2_dout_phys;
	wire        m2_dout_ready_phys;

	assign pub_m2_busy     = m2_sel_pub  ? m2_busy_phys : 1'b1;
	assign pub_dout        = m2_dout_phys;
	assign pub_dout_ready  = m2_sel_pub  ? m2_dout_ready_phys : 1'b0;
	assign kick_m2_busy    = m2_sel_kick ? m2_busy_phys : 1'b1;
	assign kick_dout       = m2_dout_phys;
	assign kick_dout_ready = m2_sel_kick ? m2_dout_ready_phys : 1'b0;

	// ── physical DDRAM (after arb3) ──────────────────────────────────────
	wire        DDRAM_BUSY;
	wire  [7:0] DDRAM_BURSTCNT;
	wire [28:0] DDRAM_ADDR;
	wire [63:0] DDRAM_DOUT;
	wire        DDRAM_DOUT_READY;
	wire        DDRAM_RD, DDRAM_WE;
	wire [63:0] DDRAM_DIN;
	wire  [7:0] DDRAM_BE;

	// slave-side regs
	reg         s_busy;
	reg         s_ready;
	reg  [63:0] s_dout;
	reg  [7:0]  s_rd_left;
	reg  [28:0] s_rd_addr;
	reg         s_wr_busy;

	assign DDRAM_BUSY       = s_busy;
	assign DDRAM_DOUT       = s_dout;
	assign DDRAM_DOUT_READY = s_ready;

	// ── DUT instances ────────────────────────────────────────────────────
	ddr_publish_kick_mbox #(
		.DOORBELL_PHYS(DOORBELL_PHYS),
		.ADDR_W(ADDR_W),
		.POLL_DIV_BITS(POLL_DIV_BITS)
	) u_kick (
		.clk(clk),
		.reset(reset),
		.pub_busy(pub_busy),
		.pub_done_pulse(pub_done),
		.pub_err(pub_err),
		.start_pulse(kick_start),
		.bank_sel(kick_bank_sel),
		.use_bank_sel(kick_use_bank_sel),
		.src_phys(kick_src_phys),
		.bank_phys(kick_bank_phys),
		.frame_bytes(kick_frame_bytes),
		.cmd_mode_copy(pub_cmd_mode),
		.ring_doorbell(pub_ring_db),
		.bus_want(kick_bus_want),
		.DDRAM_BUSY(kick_m2_busy),
		.DDRAM_BURSTCNT(kick_burstcnt),
		.DDRAM_ADDR(kick_addr),
		.DDRAM_DOUT(kick_dout),
		.DDRAM_DOUT_READY(kick_dout_ready),
		.DDRAM_RD(kick_rd),
		.DDRAM_DIN(kick_din),
		.DDRAM_BE(kick_be),
		.DDRAM_WE(kick_we)
	);

	ddr_publish_path #(
		.CODED_W(1280),
		.CODED_H(720),
		.PHYS_BASE(PHYS_BASE),
		.BANK_STRIDE_BYTES(BANK_STRIDE),
		.DOORBELL_PHYS(DOORBELL_PHYS),
		.MAX_BURST(MAX_BURST),
		.ADDR_W(ADDR_W)
	) u_pub (
		.clk(clk),
		.reset(reset),
		.start(kick_start),
		.cmd_mode(pub_cmd_mode),
		.bank_sel(kick_bank_sel),
		.use_bank_sel(kick_use_bank_sel),
		.bank_phys_abs(kick_bank_phys),
		.src_phys(kick_src_phys),
		.ring_doorbell(pub_ring_db),
		.doorbell_word(pub_db_word),
		.bytes_override(kick_frame_bytes),
		.busy(pub_busy),
		.done_pulse(pub_done),
		.err(pub_err),
		.job_legal(pub_job_legal),
		.src_aligned(pub_src_aligned),
		.frame_bytes(pub_frame_bytes),
		.dst_bank_phys(pub_dst_bank),
		.doorbell_phys_o(pub_db_phys),
		.bytes_copied(pub_bytes_copied),
		.beats_rd(pub_beats_rd),
		.beats_wr(pub_beats_wr),
		.present_want(present_want),
		.bus_want(pub_bus_want),
		.DDRAM_BUSY(pub_m2_busy),
		.DDRAM_BURSTCNT(pub_burstcnt),
		.DDRAM_ADDR(pub_addr),
		.DDRAM_DOUT(pub_dout),
		.DDRAM_DOUT_READY(pub_dout_ready),
		.DDRAM_RD(pub_rd),
		.DDRAM_DIN(pub_din),
		.DDRAM_BE(pub_be),
		.DDRAM_WE(pub_we)
	);

	ddr_bus_arbiter3 #(.M2_QUANTUM_BEATS(M2_Q)) u_arb (
		.clk(clk),
		.clk_m1(clk_m1),
		.reset(reset),
		.m1_want(1'b0),
		.m2_want(m2_want),
		// m0 present idle (C0 nopresent face)
		.m0_busy(),
		.m0_burstcnt(8'd1),
		.m0_addr(29'd0),
		.m0_dout(),
		.m0_dout_ready(),
		.m0_rd(1'b0),
		.m0_din(64'd0),
		.m0_be(8'hFF),
		.m0_we(1'b0),
		// m1 bitstream idle
		.m1_busy(),
		.m1_burstcnt(8'd1),
		.m1_addr(29'd0),
		.m1_dout(),
		.m1_dout_ready(),
		.m1_rd(1'b0),
		.m1_din(64'd0),
		.m1_be(8'hFF),
		.m1_we(1'b0),
		// m2 muxed
		.m2_busy(m2_busy_phys),
		.m2_burstcnt(m2_burstcnt),
		.m2_addr(m2_addr),
		.m2_dout(m2_dout_phys),
		.m2_dout_ready(m2_dout_ready_phys),
		.m2_rd(m2_rd),
		.m2_din(m2_din),
		.m2_be(m2_be),
		.m2_we(m2_we),
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

	// ── mailbox + sparse DDR model ───────────────────────────────────────
	wire [ADDR_W-1:0] Q_PLXG = ADDR_W'((DOORBELL_PHYS + OFF_PLXG) >> 3);
	wire [ADDR_W-1:0] Q_SRC  = ADDR_W'((DOORBELL_PHYS + OFF_SRC)  >> 3);
	wire [ADDR_W-1:0] Q_LEN  = ADDR_W'((DOORBELL_PHYS + OFF_LEN)  >> 3);
	wire [ADDR_W-1:0] Q_PLXH = ADDR_W'((DOORBELL_PHYS + OFF_PLXH) >> 3);

	reg [63:0] mem_plxg, mem_src, mem_len, mem_plxh;
	// Sparse general mem (staging + bank). Key = qword addr.
	reg [63:0] mem [bit [28:0]];

	function automatic [63:0] mem_read(input [28:0] a);
		begin
			if (a == Q_PLXG)      mem_read = mem_plxg;
			else if (a == Q_SRC)  mem_read = mem_src;
			else if (a == Q_LEN)  mem_read = mem_len;
			else if (a == Q_PLXH) mem_read = mem_plxh;
			else if (mem.exists(a)) mem_read = mem[a];
			else
				// Unwritten staging pattern: low 32 = qword index, high = marker
				mem_read = {32'hA5A5_0000, {3'b0, a}};
		end
	endfunction

	task automatic mem_write(input [28:0] a, input [63:0] d);
		begin
			if (a == Q_PLXG)      mem_plxg = d;
			else if (a == Q_SRC)  mem_src  = d;
			else if (a == Q_LEN)  mem_len  = d;
			else if (a == Q_PLXH) mem_plxh = d;
			else                  mem[a]   = d;
		end
	endtask

	always @(posedge clk) begin
		if (reset) begin
			s_busy    <= 1'b0;
			s_ready   <= 1'b0;
			s_dout    <= 64'd0;
			s_rd_left <= 8'd0;
			s_wr_busy <= 1'b0;
		end else begin
			s_ready <= 1'b0;
			if (s_wr_busy) begin
				s_wr_busy <= 1'b0;
				s_busy    <= 1'b0;
			end else if (s_rd_left != 8'd0) begin
				s_dout    <= mem_read(s_rd_addr);
				s_ready   <= 1'b1;
				s_rd_addr <= s_rd_addr + 29'd1;
				s_rd_left <= s_rd_left - 8'd1;
				if (s_rd_left == 8'd1)
					s_busy <= 1'b0;
			end else if (DDRAM_RD && !s_busy) begin
				s_rd_left <= (DDRAM_BURSTCNT == 8'd0) ? 8'd1 : DDRAM_BURSTCNT;
				s_rd_addr <= DDRAM_ADDR;
				s_busy    <= 1'b1;
			end else if (DDRAM_WE && !s_busy) begin
				mem_write(DDRAM_ADDR, DDRAM_DIN);
				s_wr_busy <= 1'b1;
				s_busy    <= 1'b1;
			end else begin
				s_busy <= 1'b0;
			end
		end
	end

	// ── observers ────────────────────────────────────────────────────────
	reg        saw_start_pulse;
	reg        saw_eng_busy;
	reg        saw_accept_plxh;   // PLXH magic + busy + accepted mid-flight class
	reg        saw_done_plxh;
	reg        saw_pub_done;
	reg        saw_m2_sel_pub_while_eng;
	reg        saw_m2_grant_window; // m2 not force-busy while eng wants
	reg        saw_rd_accept_eng;
	reg        saw_wr_accept_eng;
	reg        yield_violation;   // kick bus_want while posted && !pub_busy after start
	reg        post_start_window;
	reg [15:0] max_beats_rd, max_beats_wr;
	reg [15:0] plxh_done_seq_cap;
	reg [31:0] plxh_hi_last;
	integer    cyc_since_start;
	integer    cyc_eng_busy_want_no_progress;

	// Hierarchical probes (path + engine + kick)
	wire        eng_busy_h  = u_pub.u_eng.busy;
	wire [2:0]  eng_state_h = u_pub.u_eng.state;
	wire        eng_start_h = u_pub.eng_start;
	wire        posted_busy_h = u_kick.posted_busy;
	wire        kick_ok_h   = u_pub.kick_ok;
	wire        kick_bad_h  = u_pub.kick_bad;
	wire        hold_present_h = u_pub.u_eng.hold_present;
	wire        eng_rd_h    = u_pub.u_eng.DDRAM_RD;
	wire        eng_we_h    = u_pub.u_eng.DDRAM_WE;

	always @(posedge clk) begin
		if (reset) begin
			saw_start_pulse <= 1'b0;
			saw_eng_busy <= 1'b0;
			saw_accept_plxh <= 1'b0;
			saw_done_plxh <= 1'b0;
			saw_pub_done <= 1'b0;
			saw_m2_sel_pub_while_eng <= 1'b0;
			saw_m2_grant_window <= 1'b0;
			saw_rd_accept_eng <= 1'b0;
			saw_wr_accept_eng <= 1'b0;
			yield_violation <= 1'b0;
			post_start_window <= 1'b0;
			max_beats_rd <= 16'd0;
			max_beats_wr <= 16'd0;
			plxh_done_seq_cap <= 16'd0;
			plxh_hi_last <= 32'd0;
			cyc_since_start <= 0;
			cyc_eng_busy_want_no_progress <= 0;
		end else begin
			if (kick_start) begin
				saw_start_pulse <= 1'b1;
				post_start_window <= 1'b1;
				cyc_since_start <= 0;
			end else if (post_start_window)
				cyc_since_start <= cyc_since_start + 1;

			if (eng_busy_h)
				saw_eng_busy <= 1'b1;

			if (pub_done)
				saw_pub_done <= 1'b1;

			if (pub_beats_rd > max_beats_rd)
				max_beats_rd <= pub_beats_rd;
			if (pub_beats_wr > max_beats_wr)
				max_beats_wr <= pub_beats_wr;

			// PLXH host-visible
			if (mem_plxh[31:0] == MAGIC_H) begin
				plxh_hi_last <= mem_plxh[63:32];
				// busy=1 accepted=1 done=0 → 0x21 class
				if (mem_plxh[32] && mem_plxh[37] && !mem_plxh[33])
					saw_accept_plxh <= 1'b1;
				if (mem_plxh[33]) begin
					saw_done_plxh <= 1'b1;
					plxh_done_seq_cap <= mem_plxh[63:48];
				end
			end

			// G5 yield: after start, while posted_busy && !pub_busy, kick must release
			if (post_start_window && posted_busy_h && !pub_busy && kick_bus_want && !force_kick_want)
				yield_violation <= 1'b1;

			// m2 ownership while eng wants
			if (eng_busy_h && pub_bus_want && m2_sel_pub)
				saw_m2_sel_pub_while_eng <= 1'b1;
			if (eng_busy_h && pub_bus_want && m2_sel_pub && !m2_busy_phys)
				saw_m2_grant_window <= 1'b1;

			// eng command accepts (through mux: eng sees !pub_m2_busy)
			if (eng_rd_h && !pub_m2_busy)
				saw_rd_accept_eng <= 1'b1;
			if (eng_we_h && !pub_m2_busy)
				saw_wr_accept_eng <= 1'b1;

			// stall counter: eng busy+want, zero beat progress
			if (eng_busy_h && pub_bus_want && (pub_beats_rd == 16'd0) && (pub_beats_wr == 16'd0))
				cyc_eng_busy_want_no_progress <= cyc_eng_busy_want_no_progress + 1;
		end
	end

	// ── helpers ──────────────────────────────────────────────────────────
	task automatic step;
		begin @(posedge clk); #1; end
	endtask

	task automatic clear_obs;
		begin
			saw_start_pulse = 0;
			saw_eng_busy = 0;
			saw_accept_plxh = 0;
			saw_done_plxh = 0;
			saw_pub_done = 0;
			saw_m2_sel_pub_while_eng = 0;
			saw_m2_grant_window = 0;
			saw_rd_accept_eng = 0;
			saw_wr_accept_eng = 0;
			yield_violation = 0;
			post_start_window = 0;
			max_beats_rd = 0;
			max_beats_wr = 0;
			plxh_done_seq_cap = 0;
			plxh_hi_last = 0;
			cyc_since_start = 0;
			cyc_eng_busy_want_no_progress = 0;
		end
	endtask

	task automatic reset_dut;
		begin
			reset = 1;
			present_want = 0;
			force_kick_sel = 0;
			force_kick_want = 0;
			mem_plxg = 64'd0;
			mem_src  = 64'd0;
			mem_len  = 64'd0;
			mem_plxh = 64'd0;
			mem.delete();
			clear_obs();
			repeat (12) step();
			reset = 0;
			repeat (8) step();
		end
	endtask

	// Host-like program: SRC/BANK/LEN then PLXG with toggle edge (magic last via 64b)
	// R9 device face: use_bank_sel=0 + BANK_PHYS=LAB_BANK (0x30000000).
	// bank_sel=1 is a geom TRAP: if eng still uses bank_sel only, COPY lands at
	// bank1 0x30180000 and G_CONTENT/G_WRONG_BANK fail offline (device residual).
	task automatic host_program_lab_kick;
		input        tog;
		input [15:0] seq;
		reg [31:0] hi;
		begin
			hi = 32'd0;
			hi[1] = tog;          // start_toggle
			hi[4] = 1'b1;         // bank_sel=1 TRAP (geom → bank1 if abs unused)
			hi[5] = 1'b0;         // use_bank_sel=0 (device R2 absolute BANK_PHYS)
			hi[31:16] = seq;
			mem_src = {LAB_BANK, LAB_SRC};
			mem_len = {32'd0, LAB_LEN};
			// magic in LO last (same-cycle 64b write — host does dword LO last)
			mem_plxg = {hi, MAGIC_G};
		end
	endtask

	// R8/R9 G_CONTENT: bank0 (LAB_BANK / programmed bank_phys) == staging.
	// Staging uses mem_read default pattern when never host-written.
	function automatic integer bank_content_match;
		input [31:0] bank_base;
		integer qi, nq, bad;
		reg [28:0] a_src, a_dst;
		begin
			nq  = LAB_LEN >> 3;
			bad = 0;
			a_src = LAB_SRC[31:3];
			a_dst = bank_base[31:3];
			for (qi = 0; qi < nq; qi = qi + 1) begin
				if (mem_read(a_dst + qi[28:0]) !== mem_read(a_src + qi[28:0]))
					bad = bad + 1;
			end
			bank_content_match = (bad == 0) ? 1 : 0;
		end
	endfunction

	function automatic integer wrong_bank_class;
		begin
			// Device residual class: payload at bank1, bank0 still empty/poison.
			wrong_bank_class =
				(bank_content_match(LAB_BANK1) != 0) &&
				(bank_content_match(LAB_BANK) == 0) ? 1 : 0;
		end
	endfunction

	// Diagnostic: beats progress without bank0 content (pre-R8 false-green class)
	function automatic integer beats_without_content;
		begin
			beats_without_content =
				((max_beats_rd > 0) && (max_beats_wr > 0) &&
				 (bank_content_match(LAB_BANK) == 0)) ? 1 : 0;
		end
	endfunction

	function automatic [3:0] classify_stop;
		reg [3:0] s;
		reg final_21;
		begin
			final_21 = (mem_plxh[31:0] == MAGIC_H) &&
			           (mem_plxh[32]) && !mem_plxh[33] && mem_plxh[37];
			// STOP_OK_DONE still uses beats+done (G_CONTENT is a separate C0 gate)
			if (saw_done_plxh && !mem_plxh[32] &&
			    (plxh_done_seq_cap == LAB_SEQ) && (max_beats_rd > 0) && (max_beats_wr > 0))
				s = STOP_OK_DONE;
			else if (!saw_accept_plxh && !saw_start_pulse)
				s = STOP_TIMEOUT_OTHER;
			else if (kick_bad_h && !saw_eng_busy)
				s = STOP_S1_KICK_BAD;
			else if (!saw_start_pulse)
				s = STOP_S0_START_EDGE;
			else if (!saw_eng_busy)
				s = STOP_S2_ENG_ACCEPT;
			else if (max_beats_rd == 0 && max_beats_wr == 0) begin
				// busy but no COPY progress
				// ST_RD_DATA + zero beats + no rsp_left history → false RD accept
				// (arb3 grant drop vs registered m2_busy; device 0x21 class)
				if (eng_state_h == 3'd3 /*ST_RD_DATA*/)
					s = STOP_S5_COPY_RSP;
				else if (m2_sel_kick || force_kick_sel || !saw_m2_sel_pub_while_eng)
					s = STOP_S4_M2_GRANT;
				else if (hold_present_h)
					s = STOP_S3_CAN_START;
				else if (eng_state_h == 3'd2 /*ST_RD_ISSUE*/ && !saw_rd_accept_eng)
					s = STOP_S3_CAN_START;
				else if (!saw_m2_grant_window)
					s = STOP_S4_M2_GRANT;
				else
					s = STOP_S5_COPY_RSP;
			end else if (!saw_pub_done)
				s = STOP_S6_NO_DONE_PULSE;
			else if (!saw_done_plxh || final_21)
				s = STOP_S7_STATUS_WR;
			else
				s = STOP_TIMEOUT_OTHER;
			classify_stop = s;
		end
	endfunction

	function automatic string stop_name(input [3:0] s);
		begin
			case (s)
				STOP_OK_DONE:          stop_name = "STOP_OK_DONE";
				STOP_S0_START_EDGE:    stop_name = "STOP_S0_START_EDGE";
				STOP_S1_KICK_BAD:      stop_name = "STOP_S1_KICK_BAD";
				STOP_S2_ENG_ACCEPT:    stop_name = "STOP_S2_ENG_ACCEPT";
				STOP_S3_CAN_START:     stop_name = "STOP_S3_CAN_START";
				STOP_S4_M2_GRANT:      stop_name = "STOP_S4_M2_GRANT";
				STOP_S5_COPY_RSP:      stop_name = "STOP_S5_COPY_RSP";
				STOP_S6_NO_DONE_PULSE: stop_name = "STOP_S6_NO_DONE_PULSE";
				STOP_S7_STATUS_WR:     stop_name = "STOP_S7_STATUS_WR";
				default:               stop_name = "STOP_TIMEOUT_OTHER";
			endcase
		end
	endfunction

	task automatic dump_probe(input string tag);
		begin
			$display("  PROBE[%s] start=%0d eng_busy=%0d eng_st=%0d eng_start=%0d",
			         tag, saw_start_pulse, eng_busy_h, eng_state_h, eng_start_h);
			$display("  PROBE[%s] posted=%0d kick_want=%0d pub_want=%0d pub_busy=%0d",
			         tag, posted_busy_h, kick_bus_want, pub_bus_want, pub_busy);
			$display("  PROBE[%s] kick_grant=%0d m2_sel_kick=%0d m2_sel_pub=%0d m2_busy=%0d",
			         tag, kick_grant, m2_sel_kick, m2_sel_pub, m2_busy_phys);
			$display("  PROBE[%s] beats_rd=%0d beats_wr=%0d copied=%0d",
			         tag, pub_beats_rd, pub_beats_wr, pub_bytes_copied);
			$display("  PROBE[%s] plxh=%h hi_last=%h done=%0d accept=%0d",
			         tag, mem_plxh, plxh_hi_last, saw_done_plxh, saw_accept_plxh);
			$display("  PROBE[%s] job_legal=%0d src_al=%0d kick_ok=%0d kick_bad=%0d",
			         tag, pub_job_legal, pub_src_aligned, kick_ok_h, kick_bad_h);
		end
	endtask

	// Wait until done sticky or budget; sample stop
	task automatic run_until_done_or_budget;
		input integer budget;
		integer g;
		begin
			g = 0;
			while (!saw_done_plxh && g < budget) begin
				step();
				g = g + 1;
			end
			// allow a few cycles for final status settle
			repeat (16) step();
		end
	endtask

	// ── C0: present_want=0 happy path (R5 face) ──────────────────────────
	task automatic test_c0_nopresent;
		reg [3:0] stop;
		reg local_fail;
		begin
			$display("=== C0_NOPRESENT (present_want=0; lab COPY 0x1000) ===");
			local_fail = 1'b0;
			case_fails = 0;
			reset_dut();
			present_want = 0;

			// baseline toggle=0
			host_program_lab_kick(1'b0, LAB_SEQ);
			repeat (64) step();
			clear_obs();

			// rising toggle 0→1 with lab job
			host_program_lab_kick(1'b1, LAB_SEQ);
			// Compact post-start sample (grant/busy desync evidence for STOP_S5)
			begin : c0_sample
				integer dg;
				integer saw_false_accept;
				dg = 0;
				saw_false_accept = 0;
				while (!saw_start_pulse && dg < 5000) begin step(); dg = dg + 1; end
				for (dg = 0; dg < 16; dg = dg + 1) begin
					// false accept: eng leaves ST_RD_ISSUE→ST_RD_DATA with rsp_left==0
					if (eng_state_h == 3'd3 && u_arb.rsp_left == 9'd0 &&
					    pub_beats_rd == 16'd0 && !DDRAM_DOUT_READY)
						saw_false_accept = 1;
					step();
				end
				if (saw_false_accept)
					$display("C0_EVIDENCE FALSE_RD_ACCEPT eng ST_RD_DATA rsp_left=0 (grant/busy desync)");
			end
			run_until_done_or_budget(200000);

			stop = classify_stop();
			$display("C0 stop=%s plxh=%h beats_rd=%0d beats_wr=%0d",
			         stop_name(stop), mem_plxh, max_beats_rd, max_beats_wr);
			dump_probe("C0");

			// G0 accept mid-flight may have been overwritten by done; require start
			if (!saw_start_pulse) begin
				$display("FAIL C0 G0_ACCEPT/G1 no start_pulse STOP=%s", stop_name(stop));
				local_fail = 1'b1;
			end else
				$display("PASS C0_G0_START_PULSE");

			if (!saw_eng_busy) begin
				$display("FAIL C0 G1_ENG_START eng never busy STOP=%s", stop_name(stop));
				local_fail = 1'b1;
			end else
				$display("PASS C0_G1_ENG_BUSY");

			if (max_beats_rd < 16'd1 || max_beats_wr < 16'd1) begin
				$display("FAIL C0 G2_COPY_PROGRESS brd=%0d bwr=%0d STOP=%s",
				         max_beats_rd, max_beats_wr, stop_name(stop));
				local_fail = 1'b1;
			end else
				$display("PASS C0_G2_BEATS brd=%0d bwr=%0d", max_beats_rd, max_beats_wr);

			// R8/R9 G_CONTENT: bank0 @ 0x30000000 must match staging (model store proof).
			// Pre-R8: G2 alone could green on accepts without this (false-green vs silicon).
			// R9: bank_sel trap + use_bank_sel=0; wrong land at 0x30180000 is FAIL.
			begin : c0_g_content
				integer content_ok;
				integer false_green_class;
				integer wb;
				integer m1;
				content_ok = bank_content_match(LAB_BANK);
				false_green_class = beats_without_content();
				wb = wrong_bank_class();
				m1 = bank_content_match(LAB_BANK1);
				if (false_green_class)
					$display("C0_EVIDENCE PRE_R8_FALSE_GREEN_CLASS beats>0 but bank0!=staging");
				if (wb)
					$display("C0_EVIDENCE WRONG_BANK_CLASS bank1@0x%h==staging bank0@0x%h empty",
					         LAB_BANK1, LAB_BANK);
				$display("C0_BANK_PROBE dst_stat=%h kick_bank_phys=%h use_bsel=%0d bank_sel=%0d m0=%0d m1=%0d",
				         pub_dst_bank, kick_bank_phys, kick_use_bank_sel, kick_bank_sel,
				         content_ok, m1);
				if (!content_ok) begin
					$display("FAIL C0 G_CONTENT bank0@0x%h!=staging brd=%0d bwr=%0d STOP=%s",
					         LAB_BANK, max_beats_rd, max_beats_wr, stop_name(stop));
					if (wb)
						$display("FAIL_WRONG_BANK bank1@0x%h has staging (R9 residual)",
						         LAB_BANK1);
					else
						$display("FAIL_FALSE_DONE_NO_WRITE (compose model content residual)");
					local_fail = 1'b1;
				end else
					$display("PASS C0_G_CONTENT bank0@0x%h==staging len=%0d", LAB_BANK, LAB_LEN);

				// G_BANK0_LAND: eng dst status and content at programmed bank_phys
				if (content_ok && (pub_dst_bank == LAB_BANK) && !wb)
					$display("PASS C0_G_BANK0_LAND dst=%h bank0 match bank1_match=%0d",
					         pub_dst_bank, m1);
				else begin
					$display("FAIL C0 G_BANK0_LAND dst=%h expect=%h content0=%0d wrong_bank=%0d",
					         pub_dst_bank, LAB_BANK, content_ok, wb);
					local_fail = 1'b1;
				end
			end

			// G2b: eng must report full lab beat budget (512 for 0x1000)
			if (max_beats_rd < 16'd512 || max_beats_wr < 16'd512) begin
				$display("FAIL C0 G2b_BEATS_EXPECTED brd=%0d bwr=%0d need=512",
				         max_beats_rd, max_beats_wr);
				local_fail = 1'b1;
			end else
				$display("PASS C0_G2b_BEATS_EXPECTED brd=%0d bwr=%0d", max_beats_rd, max_beats_wr);

			if (!(saw_done_plxh && !mem_plxh[32] && (plxh_done_seq_cap == LAB_SEQ) &&
			      (mem_plxh[31:0] == MAGIC_H))) begin
				$display("FAIL C0 G3_DONE_STICKY plxh=%h seq=%h STOP=%s",
				         mem_plxh, plxh_done_seq_cap, stop_name(stop));
				// named fail class for device signature match
				if ((mem_plxh[31:0] == MAGIC_H) && mem_plxh[32] && !mem_plxh[33] &&
				    max_beats_rd == 0)
					$display("FAIL_BUSYSTUCK_0x21 STOP=%s", stop_name(stop));
				else if (max_beats_rd > 0 && !saw_done_plxh)
					$display("FAIL_PARTIAL_COPY STOP=%s", stop_name(stop));
				local_fail = 1'b1;
			end else
				$display("PASS C0_G3_DONE_STICKY seq=0x%h plxh=%h", plxh_done_seq_cap, mem_plxh);

			// G4: must not leave frozen 0x21 with zero beats
			if ((mem_plxh[31:0] == MAGIC_H) && mem_plxh[32] && !mem_plxh[33] &&
			    max_beats_rd == 0) begin
				$display("FAIL C0 G4_NEG_DEVICE_SIG frozen 0x21 STOP=%s", stop_name(stop));
				local_fail = 1'b1;
			end else
				$display("PASS C0_G4_NEG_DEVICE_SIG");

			// G5: no err_align on happy path (R8 eng short-copy → err)
			if (mem_plxh[31:0] == MAGIC_H && mem_plxh[34]) begin
				$display("FAIL C0 G5_ERR_ALIGN unexpected err_align plxh=%h", mem_plxh);
				local_fail = 1'b1;
			end else
				$display("PASS C0_G5_NO_ERR_ALIGN");

			if (local_fail) begin
				if (stop == STOP_S0_START_EDGE || stop == STOP_S2_ENG_ACCEPT)
					$display("FAIL C0_NOPRESENT STOP=%s R8_SOLE=cutb-r1-pw-kick-r8-engstart",
					         stop_name(stop));
				else if (stop == STOP_S4_M2_GRANT || stop == STOP_S3_CAN_START)
					$display("FAIL C0_NOPRESENT STOP=%s R8_SOLE=cutb-r1-pw-kick-r8-m2grant",
					         stop_name(stop));
				else if (stop == STOP_S5_COPY_RSP)
					$display("FAIL C0_NOPRESENT STOP=%s R8_SOLE=cutb-r1-pw-kick-r8-rsppath",
					         stop_name(stop));
				else if (wrong_bank_class())
					$display("FAIL C0_NOPRESENT STOP=%s R9_SOLE=cutb-r1-pw-kick-r9-bank-dest",
					         stop_name(stop));
				else if (bank_content_match(LAB_BANK) == 0)
					$display("FAIL C0_NOPRESENT STOP=%s R8_SOLE=cutb-r1-pw-kick-r8-false-done",
					         stop_name(stop));
				else
					$display("FAIL C0_NOPRESENT STOP=%s R9_SOLE=cutb-r1-pw-kick-r9-investigate",
					         stop_name(stop));
				// Extra pin for parent: H-S0 closed if eng_busy rose
				if (saw_eng_busy)
					$display("C0_RANK H-S0_ENG_START=CLOSED (busy rose) residual=%s",
					         stop_name(stop));
				fails = fails + 1;
				case_fails = 1;
			end else begin
				$display("PASS C0_NOPRESENT STOP_OK_DONE G_CONTENT G_BANK0_LAND");
			end
		end
	endtask

	// ── C4: yield regress (posted_busy → kick bus_want=0) ────────────────
	task automatic test_c4_yield;
		integer g;
		reg local_fail;
		integer want_while_posted;
		begin
			$display("=== C4_YIELD_REGRESS (posted_busy bus_want==0) ===");
			local_fail = 1'b0;
			reset_dut();
			present_want = 0;
			host_program_lab_kick(1'b0, LAB_SEQ);
			repeat (64) step();
			clear_obs();
			host_program_lab_kick(1'b1, LAB_SEQ);

			// Wait for start_pulse then sample yield for a window before done
			g = 0;
			while (!saw_start_pulse && g < 5000) begin step(); g = g + 1; end
			if (!saw_start_pulse) begin
				$display("FAIL C4 no start_pulse (cannot check yield)");
				fails = fails + 1;
			end else begin
				want_while_posted = 0;
				g = 0;
				// sample ~200 cycles after start while job may still be in flight
				while (g < 400) begin
					if (posted_busy_h && !pub_busy && kick_bus_want)
						want_while_posted = want_while_posted + 1;
					// once eng busy, also check kick still yields
					if (posted_busy_h && eng_busy_h && kick_bus_want)
						want_while_posted = want_while_posted + 1;
					step();
					g = g + 1;
				end
				if (want_while_posted != 0 || yield_violation) begin
					$display("FAIL C4 G5_YIELD kick bus_want while posted cnt=%0d",
					         want_while_posted);
					fails = fails + 1;
					local_fail = 1'b1;
				end else
					$display("PASS C4_G5_YIELD bus_want=0 under posted_busy");

				// let job finish so we don't leave sticky state
				run_until_done_or_budget(200000);
				if (!local_fail)
					$display("PASS C4_YIELD_REGRESS");
			end
		end
	endtask

	// ── C3: force m2_sel_kick after start → expect FAIL STOP_S4 ──────────
	task automatic test_c3_fault_kick_grant;
		reg [3:0] stop;
		integer g;
		reg local_fail;
		begin
			$display("=== C3_KICK_GRANT_STUCK fault twin (expect STOP_S4) ===");
			local_fail = 1'b0;
			reset_dut();
			present_want = 0;
			host_program_lab_kick(1'b0, LAB_SEQ);
			repeat (64) step();
			clear_obs();
			host_program_lab_kick(1'b1, LAB_SEQ);

			// Wait for accept/start then force kick ownership
			g = 0;
			while (!saw_start_pulse && g < 5000) begin step(); g = g + 1; end
			if (!saw_start_pulse) begin
				// still force and budget-run for taxonomy
				$display("WARN C3 no start before force; forcing anyway");
			end
			force_kick_sel = 1'b1;
			// also keep kick_grant sticky idea: force is enough for m2_sel_kick
			run_until_done_or_budget(30000);

			stop = classify_stop();
			$display("C3 stop=%s plxh=%h beats_rd=%0d",
			         stop_name(stop), mem_plxh, max_beats_rd);
			dump_probe("C3");

			// Expect discriminator: stuck 0x21 class OR no beats + STOP_S4
			if (stop == STOP_S4_M2_GRANT ||
			    (max_beats_rd == 0 && !saw_done_plxh && saw_start_pulse)) begin
				$display("PASS C3_FAULT_REPRO STOP=%s (expected fail twin)", stop_name(stop));
				if ((mem_plxh[31:0] == MAGIC_H) && mem_plxh[32] && !mem_plxh[33])
					$display("PASS C3_BUSYSTUCK_0x21_IMAGE");
			end else if (saw_done_plxh && max_beats_rd > 0) begin
				$display("FAIL C3 fault twin unexpectedly PASSED full path (mux force ineffective)");
				fails = fails + 1;
				local_fail = 1'b1;
			end else begin
				// other named stop still proves discriminator as long as not OK
				if (stop != STOP_OK_DONE) begin
					$display("PASS C3_FAULT_REPRO STOP=%s (named fail; not OK)", stop_name(stop));
				end else begin
					$display("FAIL C3 unexpected STOP_OK_DONE under force_kick_sel");
					fails = fails + 1;
					local_fail = 1'b1;
				end
			end
			if (!local_fail)
				$display("PASS C3_KICK_GRANT_STUCK");
			force_kick_sel = 0;
		end
	endtask

	// ── main ─────────────────────────────────────────────────────────────
	initial begin
		fails = 0;
		$display("=== test_ddr_publish_kick_to_pub_done_tb EXECUTED ===");
		$display("COMPOSE=kick_mbox+path/eng+m2_mux+arb3+ddram_model");
		$display("LAB src=%h len=%h seq=%h present_want default=0",
		         LAB_SRC, LAB_LEN, LAB_SEQ);
		$display("Q_PLXG=%h Q_SRC=%h Q_LEN=%h Q_PLXH=%h", Q_PLXG, Q_SRC, Q_LEN, Q_PLXH);

		test_c0_nopresent();
		test_c4_yield();
		test_c3_fault_kick_grant();

		if (fails == 0) begin
			$display("PASS ddr_publish_kick_to_pub_done_tb all");
			$display("PASS C0");
			$display("PASS C4");
			$display("PASS C3");
			$display("true rc=0");
			$finish;
		end else begin
			$display("FAIL ddr_publish_kick_to_pub_done_tb fails=%0d", fails);
			$fatal(1);
		end
	end

	// global safety
	initial begin
		#50_000_000;
		$display("FAIL global timeout");
		dump_probe("TIMEOUT");
		$fatal(1);
	end
endmodule

`default_nettype wire
