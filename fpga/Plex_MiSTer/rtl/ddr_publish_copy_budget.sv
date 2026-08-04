// ddr_publish_copy_budget — PL330 vs fabric publication-copy arithmetic (RTL).
//
// PRE-REGISTERED predictions are localparam constants below. Computed outputs
// are derived from them + frame size. Tests assert PREREG values are the
// documented pins and that computed ms/frame match the closed-form math.
//
// Parent context: one effective A9 core (MiSTer owns the other at ~100% spin).
// ARM memcpy T_copy≈14.978 ms @720p is serial with decode; dual-core overlap
// withdrawn. Contenders to retire that copy:
//   A) HPS PL330 DMA  — ~0 fabric M10K; shares HPS DDR with CPU, not f2sdram
//   B) Fabric master  — bounce M10K; shares DDRAM port with present reader
//
// Contention row is load-bearing and mostly UNVERIFIED on device:
//   fabric_vs_present: same f2sdram port → copy stalls when present reads
//   pl330_vs_present:  different port (HPS MP vs FPGA) → lower direct collision
//   pl330_vs_cpu:      same HPS DDR; MiSTer spin may still contend
//
// M10K: 0. No fit. Device PL330 bench is parent-only (see tools/ + REPORT).

module ddr_publish_copy_budget #(
	parameter int FRAME_BYTES = 1_382_400,
	parameter int FPS = 24
)(
	// ---- PRE-REGISTERED pins (tests lock these literals) ----
	output wire [15:0] prereg_pl330_m10k,
	output wire [15:0] prereg_pl330_alm,
	output wire [15:0] prereg_fabric_bounce_m10k,
	output wire [15:0] prereg_fabric_alm_est,
	output wire [31:0] prereg_pl330_bw_kBps,     // conservative EST, device-unverified
	output wire [31:0] prereg_fabric_peak_kBps,  // 8 B * 90 MHz
	output wire [31:0] prereg_t_copy_arm_us,     // 14978 µs measured host path
	// ---- Computed from PREREG + FRAME_BYTES ----
	output wire [31:0] r_req_Bps,                // FRAME*FPS one direction
	output wire [31:0] t_pl330_us,               // FRAME / pl330_bw
	output wire [31:0] t_fabric_ideal_rw_us,     // 2*(FRAME/8)/90e6
	output wire [31:0] t_fabric_ideal_r_only_us, // present-R dyn-base path
	output wire [31:0] t_budget_24_us,           // 1e6/24
	output wire        pl330_beats_arm_copy,     // t_pl330 < t_copy_arm
	output wire        fabric_ideal_beats_arm,
	output wire        fabric_ideal_fits_24,
	output wire        pl330_est_fits_24,
	// Contention class flags (structural, not measured duty)
	output wire        fabric_contends_present_port, // 1: same DDRAM as store reader
	output wire        pl330_contends_present_port,  // 0: HPS path ≠ f2sdram
	output wire        pl330_contends_hps_cpu,       // 1: shares DRAM with MiSTer
	output wire        dyn_base_zero_mover_m10k,     // preferred: mux path M10K=0
	// Honesty: device BW not proven in this module
	output wire        pl330_bw_device_verified,     // always 0 here
	output wire        fabric_real_ms_device_verified
);
	// ===================== PRE-REGISTER (do not "fit" these) =====================
	// Changed only with an explicit GOLDEN-CHANGE + parent device evidence.
	localparam int PR_PL330_M10K = 0;
	localparam int PR_PL330_ALM = 0;
	localparam int PR_FABRIC_BOUNCE_M10K = 1;   // DEPTH=128 * 8 B → ≤1–2 M10K EST
	localparam int PR_FABRIC_ALM_EST = 400;     // UNVERIFIED pre-fit placeholder
	localparam int PR_PL330_BW_KBps = 150_000;  // 150 MB/s conservative EST
	localparam int PR_FABRIC_PEAK_KBps = 720_000; // 8 * 90e6
	localparam int PR_T_COPY_ARM_US = 14_978;
	localparam int CLK_DDR_HZ = 90_000_000;
	// ===========================================================================

	localparam int R_REQ = FRAME_BYTES * FPS;
	// t_us = FRAME_BYTES * 1e6 / (BW_KBps * 1000) = FRAME_BYTES * 1000 / BW_KBps
	// (FRAME_BYTES*1000 fits 32-bit: 1.382e9 < 2^31)
	localparam int T_PL330_US = (FRAME_BYTES * 1000) / PR_PL330_BW_KBps;
	// ideal R+W mover: 2 * (FRAME/8) cycles @ clk_ddr.
	// Avoid 32-bit overflow of (cycles * 1e6): at 90 MHz, us = cycles / 90.
	localparam int QWORDS = FRAME_BYTES / 8;
	localparam int CYCLES_PER_US = CLK_DDR_HZ / 1_000_000; // 90
	localparam int T_FAB_RW_US = (2 * QWORDS) / CYCLES_PER_US;
	localparam int T_FAB_R_US = QWORDS / CYCLES_PER_US;
	localparam int T_BUDGET_24_US = 1_000_000 / FPS;

	assign prereg_pl330_m10k = 16'(PR_PL330_M10K);
	assign prereg_pl330_alm = 16'(PR_PL330_ALM);
	assign prereg_fabric_bounce_m10k = 16'(PR_FABRIC_BOUNCE_M10K);
	assign prereg_fabric_alm_est = 16'(PR_FABRIC_ALM_EST);
	assign prereg_pl330_bw_kBps = 32'(PR_PL330_BW_KBps);
	assign prereg_fabric_peak_kBps = 32'(PR_FABRIC_PEAK_KBps);
	assign prereg_t_copy_arm_us = 32'(PR_T_COPY_ARM_US);

	assign r_req_Bps = 32'(R_REQ);
	assign t_pl330_us = 32'(T_PL330_US);
	assign t_fabric_ideal_rw_us = 32'(T_FAB_RW_US);
	assign t_fabric_ideal_r_only_us = 32'(T_FAB_R_US);
	assign t_budget_24_us = 32'(T_BUDGET_24_US);

	assign pl330_beats_arm_copy = (T_PL330_US < PR_T_COPY_ARM_US);
	assign fabric_ideal_beats_arm = (T_FAB_RW_US < PR_T_COPY_ARM_US);
	assign fabric_ideal_fits_24 = (T_FAB_RW_US < T_BUDGET_24_US);
	assign pl330_est_fits_24 = (T_PL330_US < T_BUDGET_24_US);

	assign fabric_contends_present_port = 1'b1;
	assign pl330_contends_present_port = 1'b0;
	assign pl330_contends_hps_cpu = 1'b1;
	assign dyn_base_zero_mover_m10k = 1'b1; // ddr_frame_base_mux path

	assign pl330_bw_device_verified = 1'b0;
	assign fabric_real_ms_device_verified = 1'b0;
endmodule
