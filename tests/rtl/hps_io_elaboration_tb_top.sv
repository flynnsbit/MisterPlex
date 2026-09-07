module hps_io_elaboration_tb_top (
	input wire clk_sys,
	inout wire [45:0] hps_bus_disabled,
	inout wire [45:0] hps_bus_enabled,
	output wire [31:0] build_date
);
	assign build_date = `BUILD_DATE;

	hps_io #(.CONF_STR("Plex;"), .PS2DIV(0)) without_ps2 (
		.clk_sys(clk_sys),
		.HPS_BUS(hps_bus_disabled)
	);

	hps_io #(.CONF_STR("Plex;"), .PS2DIV(16)) with_ps2 (
		.clk_sys(clk_sys),
		.HPS_BUS(hps_bus_enabled)
	);
endmodule
