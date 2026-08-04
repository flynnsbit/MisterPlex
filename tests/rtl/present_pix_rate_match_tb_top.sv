// Top for present_pix_rate_match Verilator gate (w-clock).
// Defaults: F_SYS=20e6, F_PIX=29.7e6, PPC=2 → pixels/s → 29.7e6.
module present_pix_rate_match_tb_top (
	input  wire clk,
	input  wire reset,
	input  wire in_ready,
	output wire fire
);
	present_pix_rate_match #(
		.F_SYS_HZ(20_000_000),
		.F_PIX_HZ(29_700_000),
		.PX_PER_CLK(2)
	) dut (
		.clk(clk),
		.reset(reset),
		.in_ready(in_ready),
		.fire(fire)
	);
endmodule
