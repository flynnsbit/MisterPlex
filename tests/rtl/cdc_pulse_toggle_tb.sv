// cdc_pulse_toggle POS + NEG (FAULT_BARE_PULSE).
`timescale 1ns/1ps
/* verilator lint_off PROCASSINIT */

module cdc_pulse_toggle_tb;
`ifdef FAULT_BARE_PULSE
	localparam bit FAULT = 1;
`else
	localparam bit FAULT = 0;
`endif

	reg clk_src = 1'b0;
	reg clk_dst = 1'b0;
	always #17 clk_src = ~clk_src;
	always #25 clk_dst = ~clk_dst;

	reg rst_src = 1'b1;
	reg rst_dst = 1'b1;
	reg pulse_src = 1'b0;
	wire pulse_dst_good;
	reg pulse_dst_bare;

	cdc_pulse_toggle #(.STAGES(2)) u_good (
		.clk_src(clk_src), .rst_src(rst_src), .pulse_src(pulse_src),
		.clk_dst(clk_dst), .rst_dst(rst_dst), .pulse_dst(pulse_dst_good)
	);

	always @(posedge clk_dst) begin
		if (rst_dst)
			pulse_dst_bare <= 1'b0;
		else
			pulse_dst_bare <= pulse_src;
	end

	integer n_src, n_good, n_bare, i;
	reg done;

	always @(posedge clk_dst) begin
		if (!rst_dst) begin
			if (pulse_dst_good) n_good <= n_good + 1;
			if (pulse_dst_bare) n_bare <= n_bare + 1;
		end
	end

	initial begin
		done = 0;
		n_src = 0; n_good = 0; n_bare = 0;
		$display("=== cdc_pulse_toggle_tb EXECUTED FAULT=%0d ===", FAULT);
		repeat (10) @(posedge clk_src);
		rst_src = 0;
		rst_dst = 0;
		repeat (10) @(posedge clk_src);

		for (i = 0; i < 30; i = i + 1) begin
			repeat (11) @(posedge clk_src);
			pulse_src <= 1'b1;
			@(posedge clk_src);
			pulse_src <= 1'b0;
			n_src = n_src + 1;
		end
		repeat (30) @(posedge clk_dst);

		$display("COUNTS src=%0d good=%0d bare=%0d", n_src, n_good, n_bare);

		if (!FAULT) begin
			if (n_good != n_src) begin
				$display("FAIL POS: good %0d != src %0d", n_good, n_src);
				done = 1; #50; $finish;
			end
			$display("PASS POS cdc_pulse_toggle conserved=%0d", n_good);
			if (n_bare < n_src)
				$display("INFO bare_drops=%0d", n_src - n_bare);
		end else begin
			if (n_bare >= n_src) begin
				$display("FAIL NEG expected bare drops bare=%0d src=%0d", n_bare, n_src);
				done = 1; #50; $finish;
			end
			$display("REPRO_OK NEG bare_pulse drops bare=%0d src=%0d", n_bare, n_src);
		end
		done = 1;
		#50;
		$finish;
	end

	initial begin
		#5_000_000;
		if (!done) begin
			$display("FAIL timeout");
			$finish;
		end
	end
endmodule
