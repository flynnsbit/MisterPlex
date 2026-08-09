// Self-checking testbench for the P_Skip motion vector path.
//
// Covers the four spec 8.4.1.1 zero-MV special cases against hand computed
// values, the 8.4.1.3 median / directional / substitution rules, the neighbour
// context row buffer, and CAVLC mb_skip_run tracking.
//
// Simulate with a Verilator binary build (--binary --timing) whose top module
// is h264_pskip_mv_tb, over fpga/Plex_MiSTer/rtl/h264_inter_pred.sv,
// fpga/Plex_MiSTer/rtl/h264_pskip_mv.sv and this file.

`default_nettype none

module h264_pskip_mv_tb;

	integer errors = 0;

	// ---------------- P_Skip MV derivation ----------------
	reg               a_present, a_inter;
	reg        [1:0]  a_ref;
	reg signed [15:0] a_mv_x, a_mv_y;
	reg               b_present, b_inter;
	reg        [1:0]  b_ref;
	reg signed [15:0] b_mv_x, b_mv_y;
	reg               c_present, c_inter;
	reg        [1:0]  c_ref;
	reg signed [15:0] c_mv_x, c_mv_y;
	reg               d_present, d_inter;
	reg        [1:0]  d_ref;
	reg signed [15:0] d_mv_x, d_mv_y;

	wire signed [15:0] skip_mv_x, skip_mv_y, skip_mvp_x, skip_mvp_y;
	wire        [1:0]  skip_ref;
	wire               skip_zero;
	wire        [3:0]  skip_reason;

	h264_pskip_mv u_skip (
		.nb_a_present(a_present), .nb_a_inter(a_inter), .nb_a_ref(a_ref),
		.nb_a_mv_x(a_mv_x), .nb_a_mv_y(a_mv_y),
		.nb_b_present(b_present), .nb_b_inter(b_inter), .nb_b_ref(b_ref),
		.nb_b_mv_x(b_mv_x), .nb_b_mv_y(b_mv_y),
		.nb_c_present(c_present), .nb_c_inter(c_inter), .nb_c_ref(c_ref),
		.nb_c_mv_x(c_mv_x), .nb_c_mv_y(c_mv_y),
		.nb_d_present(d_present), .nb_d_inter(d_inter), .nb_d_ref(d_ref),
		.nb_d_mv_x(d_mv_x), .nb_d_mv_y(d_mv_y),
		.mv_x(skip_mv_x), .mv_y(skip_mv_y),
		.ref_idx_l0(skip_ref),
		.mvp_x(skip_mvp_x), .mvp_y(skip_mvp_y),
		.zero_mv(skip_zero), .zero_reason(skip_reason)
	);

	// ---------------- Neighbour context ----------------
	reg        clk = 1'b0;
	reg        reset = 1'b1;
	reg [7:0]  ctx_mb_x = 8'd0;
	reg [7:0]  ctx_mb_y = 8'd0;
	reg        ctx_commit = 1'b0;
	reg [7:0]  ctx_commit_x = 8'd0;
	reg        ctx_commit_inter = 1'b0;
	reg [1:0]  ctx_commit_ref = 2'd0;
	reg signed [15:0] ctx_commit_mv_x = 16'sd0;
	reg signed [15:0] ctx_commit_mv_y = 16'sd0;

	wire               ctx_a_present, ctx_a_inter;
	wire        [1:0]  ctx_a_ref;
	wire signed [15:0] ctx_a_mv_x, ctx_a_mv_y;
	wire               ctx_b_present, ctx_b_inter;
	wire        [1:0]  ctx_b_ref;
	wire signed [15:0] ctx_b_mv_x, ctx_b_mv_y;
	wire               ctx_c_present, ctx_c_inter;
	wire        [1:0]  ctx_c_ref;
	wire signed [15:0] ctx_c_mv_x, ctx_c_mv_y;
	wire               ctx_d_present, ctx_d_inter;
	wire        [1:0]  ctx_d_ref;
	wire signed [15:0] ctx_d_mv_x, ctx_d_mv_y;

	h264_pskip_nb_ctx #(.MB_WIDTH_MAX(39), .MB_WIDTH_DEFAULT(39)) u_ctx (
		.clk(clk), .reset(reset),
		.mb_x(ctx_mb_x), .mb_y(ctx_mb_y), .mb_width(8'd39),
		.first_mb_in_slice(16'd0),
		.mb_commit(ctx_commit), .commit_mb_x(ctx_commit_x),
		.commit_is_inter(ctx_commit_inter), .commit_ref_idx(ctx_commit_ref),
		.commit_mv_x(ctx_commit_mv_x), .commit_mv_y(ctx_commit_mv_y),
		.nb_a_present(ctx_a_present), .nb_a_inter(ctx_a_inter), .nb_a_ref(ctx_a_ref),
		.nb_a_mv_x(ctx_a_mv_x), .nb_a_mv_y(ctx_a_mv_y),
		.nb_b_present(ctx_b_present), .nb_b_inter(ctx_b_inter), .nb_b_ref(ctx_b_ref),
		.nb_b_mv_x(ctx_b_mv_x), .nb_b_mv_y(ctx_b_mv_y),
		.nb_c_present(ctx_c_present), .nb_c_inter(ctx_c_inter), .nb_c_ref(ctx_c_ref),
		.nb_c_mv_x(ctx_c_mv_x), .nb_c_mv_y(ctx_c_mv_y),
		.nb_d_present(ctx_d_present), .nb_d_inter(ctx_d_inter), .nb_d_ref(ctx_d_ref),
		.nb_d_mv_x(ctx_d_mv_x), .nb_d_mv_y(ctx_d_mv_y)
	);

	// ---------------- mb_skip_run tracking ----------------
	reg        run_load = 1'b0;
	reg [15:0] run_value = 16'd0;
	reg        run_consume = 1'b0;
	wire       run_is_skip;
	wire       run_need;
	wire [15:0] run_left;
	wire       run_coded_pending;

	h264_mb_skip_run_track u_run (
		.clk(clk), .reset(reset), .slice_start(1'b0),
		.skip_run_valid(run_load), .skip_run(run_value), .mb_consume(run_consume),
		.mb_is_skip(run_is_skip), .need_skip_run(run_need),
		.skip_run_left(run_left), .coded_pending(run_coded_pending)
	);

	always #5 clk = ~clk;

	task automatic set_a(input p, input i, input [1:0] r,
	                     input signed [15:0] x, input signed [15:0] y);
		begin a_present = p; a_inter = i; a_ref = r; a_mv_x = x; a_mv_y = y; end
	endtask
	task automatic set_b(input p, input i, input [1:0] r,
	                     input signed [15:0] x, input signed [15:0] y);
		begin b_present = p; b_inter = i; b_ref = r; b_mv_x = x; b_mv_y = y; end
	endtask
	task automatic set_c(input p, input i, input [1:0] r,
	                     input signed [15:0] x, input signed [15:0] y);
		begin c_present = p; c_inter = i; c_ref = r; c_mv_x = x; c_mv_y = y; end
	endtask
	task automatic set_d(input p, input i, input [1:0] r,
	                     input signed [15:0] x, input signed [15:0] y);
		begin d_present = p; d_inter = i; d_ref = r; d_mv_x = x; d_mv_y = y; end
	endtask

	task automatic expect_mv(input [511:0] name,
	                         input signed [15:0] exp_x,
	                         input signed [15:0] exp_y,
	                         input exp_zero);
		begin
			#1;
			if (skip_mv_x !== exp_x || skip_mv_y !== exp_y || skip_zero !== exp_zero) begin
				$display("FAIL %0s: mv=(%0d,%0d) zero=%0b reason=%b, expected mv=(%0d,%0d) zero=%0b",
				         name, skip_mv_x, skip_mv_y, skip_zero, skip_reason,
				         exp_x, exp_y, exp_zero);
				errors = errors + 1;
			end else begin
				$display("ok   %0s: mv=(%0d,%0d) zero=%0b reason=%b",
				         name, skip_mv_x, skip_mv_y, skip_zero, skip_reason);
			end
		end
	endtask

	task automatic expect_int(input [511:0] name, input integer got, input integer exp);
		begin
			if (got !== exp) begin
				$display("FAIL %0s: got %0d expected %0d", name, got, exp);
				errors = errors + 1;
			end else begin
				$display("ok   %0s: %0d", name, got);
			end
		end
	endtask

	initial begin
		// Defaults: all four neighbours present, inter, refIdx 0, non-zero MVs.
		set_a(1, 1, 2'd0, 16'sd12, 16'sd8);
		set_b(1, 1, 2'd0, 16'sd4, -16'sd4);
		set_c(1, 1, 2'd0, 16'sd8, 16'sd16);
		set_d(1, 1, 2'd0, 16'sd0, 16'sd0);

		// ---- Special case 1: mbAddrA not available (left picture edge) ----
		set_a(0, 0, 2'd0, 16'sd0, 16'sd0);
		expect_mv("case1 A unavailable", 16'sd0, 16'sd0, 1'b1);
		if (skip_reason[0] !== 1'b1) begin
			$display("FAIL case1 reason bit0 not set: %b", skip_reason);
			errors = errors + 1;
		end
		set_a(1, 1, 2'd0, 16'sd12, 16'sd8);

		// ---- Special case 2: mbAddrB not available (top picture edge) ----
		set_b(0, 0, 2'd0, 16'sd0, 16'sd0);
		expect_mv("case2 B unavailable", 16'sd0, 16'sd0, 1'b1);
		if (skip_reason[1] !== 1'b1) begin
			$display("FAIL case2 reason bit1 not set: %b", skip_reason);
			errors = errors + 1;
		end
		set_b(1, 1, 2'd0, 16'sd4, -16'sd4);

		// ---- Special case 3: refIdxL0A == 0 and mvL0A == (0,0) ----
		set_a(1, 1, 2'd0, 16'sd0, 16'sd0);
		expect_mv("case3 A zero mv ref0", 16'sd0, 16'sd0, 1'b1);
		if (skip_reason[2] !== 1'b1) begin
			$display("FAIL case3 reason bit2 not set: %b", skip_reason);
			errors = errors + 1;
		end
		set_a(1, 1, 2'd0, 16'sd12, 16'sd8);

		// ---- Special case 4: refIdxL0B == 0 and mvL0B == (0,0) ----
		set_b(1, 1, 2'd0, 16'sd0, 16'sd0);
		expect_mv("case4 B zero mv ref0", 16'sd0, 16'sd0, 1'b1);
		if (skip_reason[3] !== 1'b1) begin
			$display("FAIL case4 reason bit3 not set: %b", skip_reason);
			errors = errors + 1;
		end
		set_b(1, 1, 2'd0, 16'sd4, -16'sd4);

		// ---- Negative case 3a: A zero MV but refIdx 1 -> no special case ----
		// A=(0,0) ref1, B=(4,-4) ref0, C=(8,16) ref0.
		// refIdxL0 = 0 matches B and C only -> two matches -> median.
		// median x = median(0,4,8) = 4, median y = median(0,-4,16) = 0.
		set_a(1, 1, 2'd1, 16'sd0, 16'sd0);
		expect_mv("case3 negative: A zero mv ref1", 16'sd4, 16'sd0, 1'b0);
		set_a(1, 1, 2'd0, 16'sd12, 16'sd8);

		// ---- Negative case 3b: A intra (present, refIdxL0 = -1) ----
		// A contributes mv (0,0) ref -1; matches are B and C -> median again.
		set_a(1, 0, 2'd0, 16'sd0, 16'sd0);
		expect_mv("case3 negative: A intra", 16'sd4, 16'sd0, 1'b0);
		set_a(1, 1, 2'd0, 16'sd12, 16'sd8);

		// ---- Negative case 4b: B intra ----
		// A=(12,8) ref0, B intra -> (0,0)/-1, C=(8,16) ref0 -> two matches
		// median x = median(12,0,8) = 8, median y = median(8,0,16) = 8.
		set_b(1, 0, 2'd0, 16'sd0, 16'sd0);
		expect_mv("case4 negative: B intra", 16'sd8, 16'sd8, 1'b0);
		set_b(1, 1, 2'd0, 16'sd4, -16'sd4);

		// ---- Median path, all three available with refIdx 0 ----
		// A=(12,8) B=(4,-4) C=(8,16): median x = 8, median y = 8.
		expect_mv("median A/B/C", 16'sd8, 16'sd8, 1'b0);

		// ---- C substituted by D when the above-right MB is unavailable ----
		// A=(12,8) B=(4,-4) D=(-16,32): median x = median(12,4,-16) = 4,
		// median y = median(8,-4,32) = 8.
		set_c(0, 0, 2'd0, 16'sd0, 16'sd0);
		set_d(1, 1, 2'd0, -16'sd16, 16'sd32);
		expect_mv("C substituted by D", 16'sd4, 16'sd8, 1'b0);
		set_c(1, 1, 2'd0, 16'sd8, 16'sd16);
		set_d(1, 1, 2'd0, 16'sd0, 16'sd0);

		// ---- Directional rule: exactly one neighbour with refIdxL0 == 0 ----
		// A=(12,8) ref0, B ref1, C ref1 -> predictor is A, not the median.
		set_b(1, 1, 2'd1, 16'sd4, -16'sd4);
		set_c(1, 1, 2'd1, 16'sd8, 16'sd16);
		expect_mv("directional single ref0 match", 16'sd12, 16'sd8, 1'b0);
		set_b(1, 1, 2'd0, 16'sd4, -16'sd4);
		set_c(1, 1, 2'd0, 16'sd8, 16'sd16);

		// ---- Negative MVs survive the median unchanged ----
		// A=(-12,-8) B=(-4,4) C=(-8,-16): median x = -8, median y = -8.
		set_a(1, 1, 2'd0, -16'sd12, -16'sd8);
		set_b(1, 1, 2'd0, -16'sd4, 16'sd4);
		set_c(1, 1, 2'd0, -16'sd8, -16'sd16);
		expect_mv("median negative MVs", -16'sd8, -16'sd8, 1'b0);

		// ---------------- Neighbour context row buffer ----------------
		@(negedge clk);
		reset = 1'b0;
		@(negedge clk);

		// Row 0: commit MBs 0,1,2 as inter with distinct MVs.
		ctx_commit = 1'b1; ctx_commit_inter = 1'b1; ctx_commit_ref = 2'd0;
		ctx_commit_x = 8'd0; ctx_commit_mv_x = 16'sd4;  ctx_commit_mv_y = 16'sd4;
		@(negedge clk);
		ctx_commit_x = 8'd1; ctx_commit_mv_x = 16'sd8;  ctx_commit_mv_y = 16'sd8;
		@(negedge clk);
		ctx_commit_x = 8'd2; ctx_commit_mv_x = 16'sd12; ctx_commit_mv_y = 16'sd12;
		@(negedge clk);
		ctx_commit = 1'b0;

		// Row 1, column 0: A/D unavailable, B is row0 col0, C is row0 col1.
		ctx_mb_y = 8'd1; ctx_mb_x = 8'd0;
		#1;
		expect_int("ctx row1 col0 A present", ctx_a_present, 0);
		expect_int("ctx row1 col0 D present", ctx_d_present, 0);
		expect_int("ctx row1 col0 B present", ctx_b_present, 1);
		expect_int("ctx row1 col0 B mv_x", ctx_b_mv_x, 4);
		expect_int("ctx row1 col0 C mv_x", ctx_c_mv_x, 8);

		// Commit row 1 column 0 with a different MV, then look at column 1.
		ctx_commit = 1'b1; ctx_commit_x = 8'd0;
		ctx_commit_mv_x = 16'sd40; ctx_commit_mv_y = 16'sd40;
		@(negedge clk);
		ctx_commit = 1'b0;
		ctx_mb_x = 8'd1;
		#1;
		expect_int("ctx row1 col1 A mv_x (left, this row)", ctx_a_mv_x, 40);
		expect_int("ctx row1 col1 B mv_x (above)", ctx_b_mv_x, 8);
		expect_int("ctx row1 col1 C mv_x (above-right)", ctx_c_mv_x, 12);
		expect_int("ctx row1 col1 D mv_x (above-left)", ctx_d_mv_x, 4);

		// Last column: above-right does not exist.
		ctx_mb_x = 8'd38;
		#1;
		expect_int("ctx last column C present", ctx_c_present, 0);
		ctx_mb_x = 8'd1;

		// Intra commit must clear the inter flag so refIdxL0 reads back as -1.
		ctx_commit = 1'b1; ctx_commit_x = 8'd1; ctx_commit_inter = 1'b0;
		ctx_commit_mv_x = 16'sd0; ctx_commit_mv_y = 16'sd0;
		@(negedge clk);
		ctx_commit = 1'b0; ctx_commit_inter = 1'b1;
		ctx_mb_x = 8'd2;
		#1;
		expect_int("ctx intra left neighbour present", ctx_a_present, 1);
		expect_int("ctx intra left neighbour inter", ctx_a_inter, 0);

		// ---------------- mb_skip_run tracking ----------------
		// mb_skip_run = 3 -> three P_Skip MBs, then one coded MB, then the
		// walker must parse a fresh mb_skip_run.
		@(negedge clk);
		run_value = 16'd3; run_load = 1'b1;
		@(negedge clk);
		run_load = 1'b0;
		#1;
		expect_int("skip run left after load", run_left, 3);
		expect_int("skip mb 0 is skip", run_is_skip, 1);

		run_consume = 1'b1; @(negedge clk); #1;
		expect_int("skip mb 1 is skip", run_is_skip, 1);
		@(negedge clk); #1;
		expect_int("skip mb 2 is skip", run_is_skip, 1);
		@(negedge clk); #1;
		expect_int("run exhausted -> coded MB", run_is_skip, 0);
		expect_int("coded MB pending, no reparse yet", run_need, 0);
		@(negedge clk); run_consume = 1'b0; #1;
		expect_int("after coded MB, need new skip run", run_need, 1);

		// mb_skip_run = 0 means the very next MB is coded.
		run_value = 16'd0; run_load = 1'b1;
		@(negedge clk);
		run_load = 1'b0; #1;
		expect_int("zero run is not skip", run_is_skip, 0);
		expect_int("zero run still expects a coded MB", run_need, 0);

		if (errors == 0)
			$display("PASS h264_pskip_mv: all P_Skip MV checks matched");
		else
			$display("FAIL h264_pskip_mv: %0d mismatches", errors);
		if (errors != 0) $fatal(1, "h264_pskip_mv testbench failed");
		$finish;
	end
endmodule

`default_nettype wire
