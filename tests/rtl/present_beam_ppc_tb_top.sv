module present_beam_ppc_tb_top #(
	parameter int PX_PER_CLK = 2
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        enable,
	output wire        beam_ce,
	output wire [11:0] glass_x0,
	output wire [11:0] glass_y,
	output wire [PX_PER_CLK-1:0] lane_de,
	output wire        HBlank,
	output wire        HSync,
	output wire        VBlank,
	output wire        VSync,
	output wire        frame_start
);
	// CEA 720p timing constants used by present_core MULTI_PIXEL path.
	present_beam_ppc #(
		.PX_PER_CLK(PX_PER_CLK),
		.H_DE(1280),
		.H_TOTAL(1650),
		.V_ACTIVE(720),
		.V_TOTAL(750),
		.H_SYNC_S(1390),
		.H_SYNC_E(1430),
		.V_SYNC_S(725),
		.V_SYNC_E(730)
	) u_dut (
		.clk(clk),
		.reset(reset),
		.enable(enable),
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
endmodule
