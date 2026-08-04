// TB: PL330 vs fabric copy budget — locks PREREG pins + computed µs.
module ddr_publish_copy_budget_tb_top (
	output wire [15:0] pl330_m10k,
	output wire [15:0] pl330_alm,
	output wire [15:0] fab_m10k,
	output wire [15:0] fab_alm,
	output wire [31:0] pl330_bw,
	output wire [31:0] fab_peak,
	output wire [31:0] t_arm,
	output wire [31:0] t_pl330,
	output wire [31:0] t_fab_rw,
	output wire [31:0] t_fab_r,
	output wire [31:0] t_budget,
	output wire [31:0] r_req,
	output wire        pl330_beats_arm,
	output wire        fab_beats_arm,
	output wire        fab_fits_24,
	output wire        pl330_fits_24,
	output wire        fab_contends_present,
	output wire        pl330_contends_present,
	output wire        pl330_contends_cpu,
	output wire        dyn_base_zero_m10k,
	output wire        pl330_dev_verified,
	output wire        fab_dev_verified
);
	ddr_publish_copy_budget #(
		.FRAME_BYTES(1_382_400),
		.FPS(24)
	) u (
		.prereg_pl330_m10k(pl330_m10k),
		.prereg_pl330_alm(pl330_alm),
		.prereg_fabric_bounce_m10k(fab_m10k),
		.prereg_fabric_alm_est(fab_alm),
		.prereg_pl330_bw_kBps(pl330_bw),
		.prereg_fabric_peak_kBps(fab_peak),
		.prereg_t_copy_arm_us(t_arm),
		.r_req_Bps(r_req),
		.t_pl330_us(t_pl330),
		.t_fabric_ideal_rw_us(t_fab_rw),
		.t_fabric_ideal_r_only_us(t_fab_r),
		.t_budget_24_us(t_budget),
		.pl330_beats_arm_copy(pl330_beats_arm),
		.fabric_ideal_beats_arm(fab_beats_arm),
		.fabric_ideal_fits_24(fab_fits_24),
		.pl330_est_fits_24(pl330_fits_24),
		.fabric_contends_present_port(fab_contends_present),
		.pl330_contends_present_port(pl330_contends_present),
		.pl330_contends_hps_cpu(pl330_contends_cpu),
		.dyn_base_zero_mover_m10k(dyn_base_zero_m10k),
		.pl330_bw_device_verified(pl330_dev_verified),
		.fabric_real_ms_device_verified(fab_dev_verified)
	);
endmodule
