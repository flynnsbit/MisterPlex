`timescale 1ps/1ps
// Bresenham V_TOTAL long-run lock @ H=1182, clk=20e6.
// GREEN: DEN=1773 frame_ticks → exact n_hi and long-run hz (NTSC or exact-int).
// RED FAULT_FIXED_VTOTAL: fixed 705/564 — long-run hz ≠ NTSC (negative case).
// Beam full-raster × DEN is intentionally NOT simulated (≈1.5e9 cycles); wiring is
// gated in the shell + present_core structural checks.
`default_nettype none
module bresenham_vtotal_tb;
	localparam int CLK_HALF = 25000; // 50 ns → 20 MHz
	reg clk = 0;
	always #CLK_HALF clk = ~clk;

	reg reset = 1;
	reg film = 1;
	reg tick = 0;
	wire [10:0] vtot, vlo, vhi;
	wire chose_hi;

	present_vtotal_bresenham u (
		.clk(clk),
		.reset(reset),
		.enable(1'b1),
		.film_class(film),
		.frame_tick(tick),
		.vtotal_out(vtot),
		.v_lo_out(vlo),
		.v_hi_out(vhi),
		.chose_hi(chose_hi)
	);

	localparam int DEN = 1773;
	localparam real CLK_HZ = 20000000.0;
	localparam real H = 1182.0;

	integer n_hi, i;
	real mean_v, hz, want_hz;
	integer sum_v_i;

	task automatic pulse_tick;
		begin
			@(posedge clk);
			tick = 1'b1;
			@(posedge clk);
			tick = 1'b0;
		end
	endtask

	task automatic run_den;
		input bit is_film;
		input integer want_hi;
		input real want;
		input bit must_miss_want; // RED: fixed V must not land on want
		begin
			film = is_film;
			want_hz = want;
			reset = 1'b1;
			tick = 1'b0;
			repeat (8) @(posedge clk);
			reset = 1'b0;
			repeat (2) @(posedge clk);

			n_hi = 0;
			sum_v_i = 0;
			for (i = 0; i < DEN; i = i + 1) begin
				pulse_tick();
				#1;
				sum_v_i = sum_v_i + vtot;
				if (chose_hi)
					n_hi = n_hi + 1;
			end
			mean_v = sum_v_i * 1.0 / DEN;
			hz = CLK_HZ / (H * mean_v);

			$display("class_film=%0d mean_V=%.10f n_hi=%0d/%0d hz=%.15f want=%.15f",
				is_film, mean_v, n_hi, DEN, hz, want_hz);

			if (must_miss_want) begin
				if (n_hi != 0) begin
					$display("FAIL RED expected n_hi=0 got %0d", n_hi);
					$fatal(1);
				end
				if (hz > want_hz - 0.001 && hz < want_hz + 0.001) begin
					$display("FAIL RED accidentally hits target hz");
					$fatal(1);
				end
				if (is_film) begin
					if (mean_v != 705.0) begin $display("FAIL fixed film mean"); $fatal(1); end
					if (hz < 24.000 || hz > 24.002) begin $display("FAIL fixed film hz band"); $fatal(1); end
				end else begin
					if (mean_v != 564.0) begin $display("FAIL fixed tv mean"); $fatal(1); end
					if (hz < 30.000 || hz > 30.002) begin $display("FAIL fixed tv hz band"); $fatal(1); end
				end
				$display("OK RED fixed V long-run hz=%.12f ≠ target (negative case)", hz);
			end else begin
				if (n_hi != want_hi) begin
					$display("FAIL n_hi=%0d want %0d", n_hi, want_hi);
					$fatal(1);
				end
				if (hz < want_hz - 1.0e-9 || hz > want_hz + 1.0e-9) begin
					$display("FAIL hz not exact long-run lock");
					$fatal(1);
				end
				$display("OK long-run lock n_hi=%0d/%0d hz=%.15f", n_hi, DEN, hz);
			end
		end
	endtask

	initial begin
		$display("bresenham_vtotal_tb start");
`ifdef FAULT_FIXED_VTOTAL
		$display("MODE FAULT_FIXED_VTOTAL");
		run_den(1'b1, 0, 24000.0/1001.0, 1'b1);
		run_den(1'b0, 0, 30000.0/1001.0, 1'b1);
		$display("PASS bresenham_vtotal_tb RED fixed");
`elsif FAULT_BRES_EXACT_INT
		$display("MODE FAULT_BRES_EXACT_INT");
		run_den(1'b1, 35, 24.0, 1'b0);
		run_den(1'b0, 28, 30.0, 1'b0);
		$display("PASS bresenham_vtotal_tb GREEN exact_int");
`else
		$display("MODE product NTSC Bresenham");
		run_den(1'b1, 1285, 24000.0/1001.0, 1'b0);
		run_den(1'b0, 1028, 30000.0/1001.0, 1'b0);
		$display("PASS bresenham_vtotal_tb GREEN ntsc");
`endif
		$finish;
	end
endmodule
`default_nettype wire
