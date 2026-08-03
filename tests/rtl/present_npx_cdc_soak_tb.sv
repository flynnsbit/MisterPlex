// Long dual-clock soak for present_npx_path CDC (async_fifo gray pointers).
// Distinct sys/pix periods; random backpressure via almost-full natural stall;
// beat conservation + lane RGB order over many groups.
`default_nettype none

module present_npx_cdc_soak_tb #(
	parameter int PX_PER_CLK = 2,
	parameter int N_GROUPS   = 4096
);
	reg clk_sys = 1'b0;
	reg clk_pix = 1'b0;
	// Unrelated periods (not integer multiple) stress gray CDC.
	always #23 clk_sys = ~clk_sys; // ~21.7 MHz
	always #11 clk_pix = ~clk_pix; // ~45.5 MHz

	reg reset_sys = 1'b1;
	reg reset_pix = 1'b1;

	reg in_valid = 1'b0;
	reg [PX_PER_CLK*8-1:0] in_r = '0, in_g = '0, in_b = '0;
	reg [PX_PER_CLK-1:0] in_lane_valid = '0;
	wire in_ready;

	wire out_ce;
	wire [7:0] out_r, out_g, out_b;
	wire wr_full, wr_almost_full, rd_empty, rd_underrun;

	present_npx_path #(
		.PX_PER_CLK(PX_PER_CLK),
		.FIFO_AW(5)
	) dut (
		.clk_sys(clk_sys),
		.reset_sys(reset_sys),
		.clk_pix(clk_pix),
		.reset_pix(reset_pix),
		.in_valid(in_valid),
		.in_r(in_r),
		.in_g(in_g),
		.in_b(in_b),
		.in_lane_valid(in_lane_valid),
		.in_ready(in_ready),
		.out_ce(out_ce),
		.out_r(out_r),
		.out_g(out_g),
		.out_b(out_b),
		.wr_full(wr_full),
		.wr_almost_full(wr_almost_full),
		.rd_underrun(rd_underrun),
		.rd_empty(rd_empty)
	);

	integer wr_beats, rd_beats, errors, g, li, timeout, stall;
	reg [7:0] exp_q [$];
	reg [7:0] got;

	task automatic sys_tick;
		begin
			@(posedge clk_sys);
			#1;
		end
	endtask

	always @(posedge clk_pix) begin
		if (!reset_pix && out_ce) begin
			rd_beats = rd_beats + 1;
			if (exp_q.size() == 0) begin
				errors = errors + 1;
				$display("FAIL unexpected pix beat with empty expect q");
			end else begin
				got = exp_q.pop_front();
				if (out_r !== got || out_g !== 8'hA5 || out_b !== 8'h5A) begin
					errors = errors + 1;
					$display("FAIL RGB mismatch got r=%02x g=%02x b=%02x exp_r=%02x",
						out_r, out_g, out_b, got);
				end
			end
		end
	end

	initial begin
		wr_beats = 0;
		rd_beats = 0;
		errors = 0;
		repeat (20) sys_tick;
		reset_sys = 1'b0;
		reset_pix = 1'b0;
		repeat (20) sys_tick;

		for (g = 0; g < N_GROUPS; g = g + 1) begin
			// Wait for backpressure clear
			stall = 0;
			while (!in_ready && stall < 10000) begin
				sys_tick;
				stall = stall + 1;
			end
			if (!in_ready) begin
				$display("FAIL in_ready stuck group=%0d", g);
				$fatal(1);
			end

			in_r = '0;
			in_g = '0;
			in_b = '0;
			in_lane_valid = {PX_PER_CLK{1'b1}};
			for (li = 0; li < PX_PER_CLK; li = li + 1) begin
				in_r[li*8 +: 8] = (g[7:0] + li[7:0]);
				in_g[li*8 +: 8] = 8'hA5;
				in_b[li*8 +: 8] = 8'h5A;
				exp_q.push_back(g[7:0] + li[7:0]);
			end
			in_valid = 1'b1;
			sys_tick;
			in_valid = 1'b0;
			wr_beats = wr_beats + PX_PER_CLK;
			// Occasional gap (same-clock backpressure realism)
			if (g[2:0] == 3'd0)
				repeat (3) sys_tick;
		end

		timeout = 0;
		while ((rd_beats < wr_beats || exp_q.size() != 0) && timeout < 200000) begin
			sys_tick;
			timeout = timeout + 1;
		end

		if (rd_beats != wr_beats) begin
			$display("FAIL soak beat wr=%0d rd=%0d", wr_beats, rd_beats);
			$fatal(1);
		end
		if (exp_q.size() != 0) begin
			$display("FAIL expect q residual %0d", exp_q.size());
			$fatal(1);
		end
		if (errors != 0) begin
			$display("FAIL soak errors=%0d", errors);
			$fatal(1);
		end
		$display("PASS present_npx_cdc_soak wr=rd=%0d groups=%0d ppc=%0d",
			wr_beats, N_GROUPS, PX_PER_CLK);
		$finish;
	end
endmodule

`default_nettype wire
