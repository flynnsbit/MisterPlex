// Cosim testbench: present_beam_ppc steps by PX_PER_CLK; DE covers H_DE.
`default_nettype none

module present_beam_ppc_tb #(
	parameter int PX_PER_CLK = 4,
	parameter bit RED_STEP1 = 1'b0
);
	reg clk = 1'b0;
	always #5 clk = ~clk;

	reg reset = 1'b1;
	wire beam_ce;
	wire [11:0] glass_x0, glass_y;
	wire [PX_PER_CLK-1:0] lane_de;
	wire HBlank, HSync, VBlank, VSync, frame_start;

	localparam int H_DE = 1280;
	localparam int H_TOTAL = 1652;
	localparam int V_ACTIVE = 720;
	localparam int V_TOTAL = 750;

	present_beam_ppc #(
		.PX_PER_CLK(PX_PER_CLK),
		.H_DE(H_DE),
		.H_TOTAL(H_TOTAL),
		.V_ACTIVE(V_ACTIVE),
		.V_TOTAL(V_TOTAL),
		.H_SYNC_S(1390),
		.H_SYNC_E(1430),
		.V_SYNC_S(725),
		.V_SYNC_E(730)
	) dut (
		.clk(clk),
		.reset(reset),
		.enable(1'b1),
		.beam_ce(beam_ce),
		.glass_x0(glass_x0),
		.glass_y(glass_y),
		.lane_de(lane_de),
		.HBlank(HBlank),
		.HSync(HSync),
		.VBlank(VBlank),
		.VSync(VSync),
		.frame_start(frame_start)
	);

	integer errors;
	integer samples;
	integer de_pix;
	reg [11:0] xs [0:15];
	integer expect_step;
	integer di;
	integer li;
	integer delta;

	task automatic tick;
		begin
			@(posedge clk);
			#1;
		end
	endtask

	initial begin
		errors = 0;
		samples = 0;
		de_pix = 0;
		expect_step = RED_STEP1 ? 1 : PX_PER_CLK;
		repeat (4) tick;
		reset = 1'b0;

		// Drain until first post-reset beam sample on line 0.
		while (!(beam_ce && glass_y == 0 && glass_x0 == 0))
			tick;

		// Count this and subsequent line-0 samples only.
		while (glass_y == 0) begin
			if (beam_ce) begin
				if (samples < 16) begin
					xs[samples] = glass_x0;
					samples = samples + 1;
				end
				for (li = 0; li < PX_PER_CLK; li = li + 1) begin
					if (lane_de[li])
						de_pix = de_pix + 1;
				end
			end
			tick;
		end

		if (samples < 2) begin
			$display("FAIL too few samples %0d", samples);
			$fatal(1);
		end

		for (di = 1; di < samples; di = di + 1) begin
			delta = xs[di] - xs[di - 1];
			if (delta != expect_step) begin
				$display("FAIL step[%0d] x %0d->%0d delta=%0d want %0d",
					di, xs[di - 1], xs[di], delta, expect_step);
				errors = errors + 1;
			end
		end

		if (RED_STEP1) begin
			if (errors == 0) begin
				$display("FAIL: RED_STEP1 expected step mismatches");
				$fatal(1);
			end
			$display("PASS present_beam_ppc RED: step mismatch detected errors=%0d", errors);
			$fatal(1);
		end else if (errors != 0) begin
			$display("FAIL present_beam_ppc step errors=%0d", errors);
			$fatal(1);
		end else if (de_pix != H_DE) begin
			$display("FAIL first-line DE count %0d want %0d", de_pix, H_DE);
			$fatal(1);
		end else begin
			$display("PASS present_beam_ppc ppc=%0d first_line_de=%0d", PX_PER_CLK, de_pix);
			$finish;
		end
	end
endmodule

`default_nettype wire
