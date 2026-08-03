// present_pix_rate_match: long-term pixel rate ≈ F_PIX_HZ.
`default_nettype none

module present_pix_rate_match_tb;
	localparam int F_SYS = 20_000_000;
	localparam int F_PIX = 29_700_000;
	localparam int PPC   = 2;
	localparam int CYCLES = 200_000; // 10 ms @ 20 MHz

	reg clk = 1'b0;
	always #25 clk = ~clk; // 20 MHz

	reg reset = 1'b1;
	reg in_ready = 1'b1;
	wire fire;

	present_pix_rate_match #(
		.F_SYS_HZ(F_SYS),
		.F_PIX_HZ(F_PIX),
		.PX_PER_CLK(PPC)
	) dut (
		.clk(clk),
		.reset(reset),
		.in_ready(in_ready),
		.fire(fire)
	);

	integer fires;
	integer cyc;
	real pixels;
	real rate;
	real err;

	initial begin
		fires = 0;
		repeat (4) @(posedge clk);
		reset = 1'b0;
		for (cyc = 0; cyc < CYCLES; cyc = cyc + 1) begin
			@(posedge clk);
			if (fire)
				fires = fires + 1;
		end
		pixels = fires * PPC;
		// elapsed = CYCLES / F_SYS seconds; rate = pixels * F_SYS / CYCLES
		rate = pixels * F_SYS / CYCLES;
		err = (rate - F_PIX) / F_PIX;
		$display("RATE_MATCH fires=%0d pixels=%0f rate=%0f target=%0d err=%0f",
			fires, pixels, rate, F_PIX, err);
		if (err > 0.002 || err < -0.002) begin
			$display("FAIL present_pix_rate_match |err|=%0f > 0.2%%", err);
			$finish(1);
		end
		$display("PASS present_pix_rate_match");
		$finish;
	end
endmodule
