`timescale 1ps/1ps
// Forced consumer stall + exact lane scoreboard (rd-duck).
// Count-only conservation accepts equal drop+dup; this queues every accepted
// lane R/G/B and pops in order under held clk_pix + mid-stream re-stall.
// FAULT_LANE_SWAP: wire order broken, scoreboard keeps push order → must FAIL.
`default_nettype none
module present_npx_af_conserve_tb #(
	parameter bit FAULT_LANE_SWAP = 1'b0
);
	localparam int PPC = 2;
	localparam int N_PUSH_MAX = 48;
	localparam int QMAX = 512;

	reg clk_sys = 0;
	reg clk_pix = 0;
	reg run_pix = 0;
	always #25000 clk_sys = ~clk_sys;
	always begin
		if (run_pix) begin
			#16835 clk_pix = ~clk_pix;
		end else begin
			#16835;
		end
	end

	reg reset_sys = 1, reset_pix = 1;
	reg in_valid = 0;
	reg [PPC*8-1:0] in_r = 0, in_g = 0, in_b = 0;
	reg [PPC-1:0] in_lv = 0;
	reg in_hb = 1, in_hs = 0, in_vb = 1, in_vs = 0, in_fs = 0;
	wire in_ready, out_ce, wr_full, wr_af, rd_ur, rd_empty;
	wire [7:0] out_r, out_g, out_b;
	wire out_hb, out_hs, out_vb, out_vs, out_fs;

	present_npx_path #(
		.PX_PER_CLK(PPC),
		.FIFO_AW(4),
		.INCLUDE_SYNC(1),
		.PREFILL_GROUPS(4),
		.SKID_AW(4)
	) dut (
		.clk_sys(clk_sys), .reset_sys(reset_sys),
		.clk_pix(clk_pix), .reset_pix(reset_pix),
		.in_valid(in_valid), .in_r(in_r), .in_g(in_g), .in_b(in_b),
		.in_lane_valid(in_lv),
		.in_hblank(in_hb), .in_hsync(in_hs), .in_vblank(in_vb), .in_vsync(in_vs),
		.in_fstart(in_fs),
		.in_ready(in_ready),
		.out_ce(out_ce), .out_r(out_r), .out_g(out_g), .out_b(out_b),
		.out_hblank(out_hb), .out_hsync(out_hs), .out_vblank(out_vb), .out_vsync(out_vs),
		.out_fstart(out_fs),
		.wr_full(wr_full), .wr_almost_full(wr_af),
		.rd_underrun(rd_ur), .rd_empty(rd_empty)
	);

	reg [7:0] q_r [0:QMAX-1];
	reg [7:0] q_g [0:QMAX-1];
	reg [7:0] q_b [0:QMAX-1];
	integer q_wr, q_rd;
	integer wr_n, rd_n, af_seen, full_seen, blocked_no_af, cycles, stuck;
	integer mism, empty_pop;

	task automatic tick; begin @(posedge clk_sys); #1; end endtask

	task automatic push_group(input integer gid);
		integer li;
		reg [7:0] rid, gid8, bid;
		reg [7:0] t0, t1;
		begin
			in_r = '0; in_g = '0; in_b = '0;
			in_lv = {PPC{1'b1}};
			in_hb = 0; in_vb = 0; in_hs = 0; in_vs = 0;
			in_fs = (gid == 0);
			for (li = 0; li < PPC; li = li + 1) begin
				rid  = 8'(gid * PPC + li);
				gid8 = 8'hA0 ^ gid[7:0] ^ li[7:0];
				bid  = 8'h5A + gid[7:0] - li[7:0];
				in_r[li*8 +: 8] = rid;
				in_g[li*8 +: 8] = gid8;
				in_b[li*8 +: 8] = bid;
				if (q_wr >= QMAX) begin
					$display("FAIL scoreboard overflow");
					begin $display("TB_FAIL"); $finish(1); end
				end
				// Scoreboard always records logical push order (pre-fault).
				q_r[q_wr] = rid;
				q_g[q_wr] = gid8;
				q_b[q_wr] = bid;
				q_wr = q_wr + 1;
			end
			if (FAULT_LANE_SWAP && PPC >= 2) begin
				t0 = in_r[7:0]; t1 = in_r[15:8];
				in_r[7:0] = t1; in_r[15:8] = t0;
				t0 = in_g[7:0]; t1 = in_g[15:8];
				in_g[7:0] = t1; in_g[15:8] = t0;
				t0 = in_b[7:0]; t1 = in_b[15:8];
				in_b[7:0] = t1; in_b[15:8] = t0;
			end
			in_valid = 1;
			tick;
			in_valid = 0;
			in_fs = 0;
			wr_n = wr_n + 1;
		end
	endtask

	always @(posedge clk_pix) begin
		if (!reset_pix && out_ce && !out_hb && !out_vb) begin
			if (q_rd >= q_wr) begin
				empty_pop = empty_pop + 1;
				mism = mism + 1;
			end else if (out_r !== q_r[q_rd] || out_g !== q_g[q_rd] || out_b !== q_b[q_rd]) begin
				mism = mism + 1;
				if (mism <= 8)
					$display("FAIL sb pix=%0d got %02x/%02x/%02x exp %02x/%02x/%02x",
						rd_n, out_r, out_g, out_b, q_r[q_rd], q_g[q_rd], q_b[q_rd]);
				q_rd = q_rd + 1;
			end else begin
				q_rd = q_rd + 1;
			end
			rd_n = rd_n + 1;
		end
	end

	initial begin
		wr_n = 0; rd_n = 0; af_seen = 0; full_seen = 0;
		blocked_no_af = 0; mism = 0; empty_pop = 0;
		q_wr = 0; q_rd = 0; stuck = 0;
		repeat (20) tick;
		reset_sys = 0;
		reset_pix = 0;
		run_pix = 0; // held consumer stall
		repeat (10) tick;

		// --- Phase A: fill under stall until AF/ready blocks ---
		while (wr_n < N_PUSH_MAX) begin
			if (in_ready) begin
				push_group(wr_n);
				stuck = 0;
				if (wr_af) af_seen = af_seen + 1;
				if (wr_full) full_seen = full_seen + 1;
			end else begin
				if (!wr_af && !wr_full)
					blocked_no_af = blocked_no_af + 1;
				if (wr_af) af_seen = af_seen + 1;
				if (wr_full) full_seen = full_seen + 1;
				tick;
				stuck = stuck + 1;
				if (wr_n >= 12 && stuck > 64)
					break;
			end
		end

		if (wr_n < 12) begin
			$display("FAIL too few groups under stall wr=%0d", wr_n);
			begin $display("TB_FAIL"); $finish(1); end
		end
		if (af_seen < 2) begin
			$display("FAIL never sticky almost_full af=%0d full=%0d wr=%0d",
				af_seen, full_seen, wr_n);
			begin $display("TB_FAIL"); $finish(1); end
		end
		if (blocked_no_af > 8) begin
			$display("FAIL blocked without AF/full count=%0d", blocked_no_af);
			begin $display("TB_FAIL"); $finish(1); end
		end
		if (q_wr != wr_n * PPC) begin
			$display("FAIL sb push q_wr=%0d want=%0d", q_wr, wr_n * PPC);
			begin $display("TB_FAIL"); $finish(1); end
		end

		// --- Phase B: full drain, exact scoreboard ---
		run_pix = 1;
		cycles = 0;
		while (q_rd < q_wr && cycles < 500000) begin
			tick;
			cycles = cycles + 1;
		end
		repeat (3000) tick;

		if (q_rd != q_wr || rd_n != wr_n * PPC) begin
			$display("FAIL drain q_rd=%0d q_wr=%0d rd_n=%0d want_px=%0d",
				q_rd, q_wr, rd_n, wr_n * PPC);
			begin $display("TB_FAIL"); $finish(1); end
		end
		if (mism != 0 || empty_pop != 0) begin
			$display("FAIL scoreboard after drain mism=%0d empty_pop=%0d", mism, empty_pop);
			begin $display("TB_FAIL"); $finish(1); end
		end

		// --- Phase C: mid-stream re-stall while more groups flow ---
		begin : midstream
			integer wr_mark, rd_mark, bursts, b;
			wr_mark = wr_n;
			rd_mark = rd_n;
			// Keep pix running but freeze in bursts
			for (bursts = 0; bursts < 4; bursts = bursts + 1) begin
				// push a few
				b = 0;
				while (b < 6 && wr_n < N_PUSH_MAX) begin
					if (in_ready) begin
						push_group(wr_n);
						b = b + 1;
					end else tick;
				end
				// stall consumer
				run_pix = 0;
				repeat (80) tick;
				// resume
				run_pix = 1;
				repeat (200) tick;
			end
			// final drain
			cycles = 0;
			while (q_rd < q_wr && cycles < 500000) begin
				tick;
				cycles = cycles + 1;
			end
			repeat (3000) tick;
			if (q_rd != q_wr) begin
				$display("FAIL midstream residual q_rd=%0d q_wr=%0d", q_rd, q_wr);
				begin $display("TB_FAIL"); $finish(1); end
			end
			if (wr_n <= wr_mark) begin
				$display("FAIL midstream no new pushes wr=%0d mark=%0d", wr_n, wr_mark);
				begin $display("TB_FAIL"); $finish(1); end
			end
			if (rd_n <= rd_mark) begin
				$display("FAIL midstream no new pops rd=%0d mark=%0d", rd_n, rd_mark);
				begin $display("TB_FAIL"); $finish(1); end
			end
		end

		// --- Phase D: held dual-reset, fresh sequence, stall, drain ---
		run_pix = 0;
		reset_sys = 1;
		reset_pix = 1;
		repeat (20) tick;
		// Clear scoreboard with DUT
		q_wr = 0; q_rd = 0; wr_n = 0; rd_n = 0;
		mism = 0; empty_pop = 0;
		reset_sys = 0;
		reset_pix = 0;
		repeat (10) tick;

		while (wr_n < 16) begin
			if (in_ready) begin
				push_group(wr_n);
				stuck = 0;
			end else begin
				tick;
				stuck = stuck + 1;
				if (wr_n >= 8 && stuck > 64) break;
			end
		end
		if (wr_n < 8) begin
			$display("FAIL post dual-reset fill wr=%0d", wr_n);
			begin $display("TB_FAIL"); $finish(1); end
		end
		// Hold stall a bit longer with full-ish FIFO
		repeat (50) tick;
		run_pix = 1;
		cycles = 0;
		while (q_rd < q_wr && cycles < 500000) begin
			tick;
			cycles = cycles + 1;
		end
		repeat (3000) tick;

		if (q_rd != q_wr || rd_n != wr_n * PPC) begin
			$display("FAIL post-reset conserve q_rd=%0d q_wr=%0d rd=%0d want=%0d",
				q_rd, q_wr, rd_n, wr_n * PPC);
			begin $display("TB_FAIL"); $finish(1); end
		end
		if (mism != 0 || empty_pop != 0) begin
			$display("FAIL post-reset scoreboard mism=%0d empty_pop=%0d", mism, empty_pop);
			begin $display("TB_FAIL"); $finish(1); end
		end

		$display("PASS present_npx_af_conserve wr_g=%0d rd_px=%0d af=%0d full=%0d sb_exact=1",
			wr_n, rd_n, af_seen, full_seen);
		$finish;
	end
endmodule
`default_nettype wire
