// 960×540 ascal-native core timing (w-clock).
// Copied into w-scaler worktree for true-DE count sim + fit card; owner remains w-clock.
// First-fit beam class: clk_sys=20 MHz, CE=1, DE=960×540.
// HDMI 1280×720@60 remains HPS/ascal output — not this module.
//
// Primary: ~30.0008 Hz  (H_TOTAL=1182, V_TOTAL=564)
//   20e6/(1182*564) = 30.0008…  Hblank=222  Vblank=24
// Alternate exact-ish 30.012: 1190×560 (Hblank=230, Vblank=20)
// Film 24 Hz option: 1389×600 → 23.997 Hz (Hblank=429, Vblank=60)
//
// Default OFF — selected only when PRESENT_BEAM_960 (parent fit grant).
// Does NOT enable PRESENT_CLK_PIX_PLL / MULTI_PIXEL.

module present_video_timing_960 #(
	// 0 = 30 Hz primary (1182×564), 1 = 30 Hz roomy-H (1190×560), 2 = 24 Hz film
	parameter int MODE = 0,
	parameter int CLK_PIX_HZ = 20_000_000
)(
	output wire [11:0] h_de,
	output wire [11:0] h_total,
	output wire [11:0] v_active,
	output wire [11:0] v_total,
	output wire [11:0] h_sync_s,
	output wire [11:0] h_sync_e,
	output wire [11:0] v_sync_s,
	output wire [11:0] v_sync_e,
	output wire [15:0] fps_eff_milli,
	output wire        mode_30hz,
	output wire        needs_wide_fifo  // 1 if active mpix > 13.33 (legacy serialize); 0 on 1px path
);
	localparam int H_DE_L = 960;
	localparam int V_ACT_L = 540;

	// Sync placement: porch after DE, pulse width comfortable for ascal iauto.
	// Not CEA-legal (ascal input need not be); keep HS/VS away from DE edges.
	localparam int H_TOTAL_30A = 1182; // primary
	localparam int V_TOTAL_30A = 564;
	localparam int H_TOTAL_30B = 1190;
	localparam int V_TOTAL_30B = 560;
	localparam int H_TOTAL_24  = 1389;
	localparam int V_TOTAL_24  = 600;

	localparam int HT = (MODE == 2) ? H_TOTAL_24  :
	                    (MODE == 1) ? H_TOTAL_30B : H_TOTAL_30A;
	localparam int VT = (MODE == 2) ? V_TOTAL_24  :
	                    (MODE == 1) ? V_TOTAL_30B : V_TOTAL_30A;

	// HS: 64 px pulse starting 32 px after DE end
	localparam int HS_S = H_DE_L + 32;
	localparam int HS_E = HS_S + 64;
	// VS: 6 lines starting 8 lines after DE end (clamped into blank)
	localparam int VS_S = V_ACT_L + 8;
	localparam int VS_E = VS_S + 6;

	// fps_milli = 1000 * CLK / (HT*VT)
	localparam int PIX_FRAME = HT * VT;
	localparam int FPS_MILLI = (CLK_PIX_HZ * 1000) / PIX_FRAME;

	// Active content rate
	localparam int ACT_MPIX_MILLI = (H_DE_L * V_ACT_L * (FPS_MILLI)) / 1000; // approx

	assign h_de      = 12'(H_DE_L);
	assign h_total   = 12'(HT);
	assign v_active  = 12'(V_ACT_L);
	assign v_total   = 12'(VT);
	assign h_sync_s  = 12'(HS_S);
	assign h_sync_e  = 12'(HS_E);
	assign v_sync_s  = 12'(VS_S);
	assign v_sync_e  = 12'(VS_E);
	assign fps_eff_milli = 16'(FPS_MILLI);
	assign mode_30hz = (MODE != 2) ? 1'b1 : 1'b0;
	// 1px @20 MHz peak=20 Mpix/s; 15.55 needs B1 only if serialize PPC path ON.
	assign needs_wide_fifo = 1'b0;
endmodule
