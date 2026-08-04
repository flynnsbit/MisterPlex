// Fabric clock kit + runtime refresh measure (w-clock).
//
// Compile-time: noprune recipe locks (COMPACT 29.7 vs CEA VIC60 59.4).
// Runtime: count observed clk_pix toggles and VSync rises over exactly
// SYS_HZ cycles of clk_sys (~1 s). Publishes meas_fps_x10 so 24 Hz vs the
// 16.16 Hz same-clock trap is device-checkable (still frames cannot tell).
//
// M10K: 0 (flops only). Keep paths short — counters + 2FF CDC, no mul/div on
// critical paths (fps_x10 = frame_count * 10 after window).
//
// PASS band:  fps_x10 in [230,250]  (23.0–25.0 Hz) with flags.valid & fps_ok
// FAIL trap:  fps_x10 in [150,170]  (~16.16 Hz = 20e6/(1650*750))
// Arithmetic: COMPACT H*V=1_237_500; 20e6/1_237_500≈16.162; 29.7e6/1_237_500=24.000

`include "misterplex_clk_hz.svh"
`include "misterplex_clk_pix_recipe.svh"

module plex_clk_status #(
	// Default = 1 s of clk_sys. TB overrides to a short window.
	parameter int MEAS_WINDOW_CYCLES = 0
) (
	input  wire        clk,       // clk_sys reference
	input  wire        reset,
	// Runtime observers (async to clk_sys — 2FF sync inside)
	input  wire        clk_pix,
	input  wire        vsync,
	// Compile-time kit stamp
	output wire [31:0] clk_sys_hz,
	output wire [31:0] clk_pix_hz,
	output wire [7:0]  present_ppc,
	output wire [31:0] cea_pix_frame,
	output wire [31:0] l4_pix_frame,
	output wire        cea_24_needs_faster_pix,
	output wire        l4_24_needs_faster_sys,
	output wire [15:0] peak_mpix_s_x10,
	output wire        kit_id_valid,
	// Runtime measure (sticky after first full window)
	output wire [31:0] meas_pix_count,   // diagnostic: undersampled pix edges (not Hz)
	output wire [15:0] meas_frame_count, // VSync rises in window (load-bearing)
	output wire [7:0]  meas_fps_x10,     // frames * 10 (240 = 24.0 Hz)
	// flags: {3'b0, trap16, pll_on, fps_ok, pix_toggling, valid}
	output wire [7:0]  meas_flags,
	output wire        meas_window_done
);
	localparam int SYS_HZ  = `MISTERPLEX_CLK_SYS_HZ;
	localparam int PIX_HZ  = `MISTERPLEX_CLK_PIX_HZ;
	localparam int WIN_CYC = (MEAS_WINDOW_CYCLES > 0) ? MEAS_WINDOW_CYCLES : SYS_HZ;
	localparam int PPC     = `MISTERPLEX_PRESENT_PPC;
	localparam int CEA_PF  = `MISTERPLEX_CEA720_PIX_FRAME;
	localparam int L4_PF   = `MISTERPLEX_L4_PIX_FRAME;
	localparam int CEA_NEED = `MISTERPLEX_CEA720_F24_HZ;
	localparam longint L4_NEED = longint'(`MISTERPLEX_L4_F24_HZ);

	// ---- recipe locks (elab) ----
	(* keep, noprune *) wire [31:0] keep_clkpix_compact = MISTERPLEX_CLKPIX_COMPACT_HZ[31:0];
	(* keep, noprune *) wire [31:0] keep_clkpix_cea24 = MISTERPLEX_CLKPIX_CEA24_HZ[31:0];
	(* keep, noprune *) wire [31:0] keep_clkpix_product = MISTERPLEX_CLKPIX_PRODUCT_HZ[31:0];
	(* keep, noprune *) wire [15:0] keep_clkpix_pll_m = MISTERPLEX_CLKPIX_COMPACT_PLL_M[15:0];
	generate
		if (MISTERPLEX_CLKPIX_COMPACT_HZ != 29_700_000) begin : g_clkpix_compact
			misterplex_clkpix_compact_must_be_29700000 u_compact();
		end
		if (MISTERPLEX_CLKPIX_CEA24_HZ != 59_400_000) begin : g_clkpix_cea24
			misterplex_clkpix_cea24_must_be_59400000 u_cea24();
		end
		if (MISTERPLEX_CLKPIX_CEA24_HZ != (MISTERPLEX_CLKPIX_CEA24_H * MISTERPLEX_CLKPIX_CEA24_V * 24)) begin : g_clkpix_cea24_arith
			misterplex_clkpix_cea24_arith_broken u_cea24_arith();
		end
		if (MISTERPLEX_CLKPIX_COMPACT_HZ != (MISTERPLEX_CLKPIX_COMPACT_H * MISTERPLEX_CLKPIX_COMPACT_V * 24)) begin : g_clkpix_compact_arith
			misterplex_clkpix_compact_arith_broken u_c_arith();
		end
		if (MISTERPLEX_CLKPIX_PRODUCT_HZ != MISTERPLEX_CLKPIX_COMPACT_HZ) begin : g_clkpix_product_is_compact
			misterplex_clkpix_product_must_be_compact_not_cea24 u_prod();
		end
		if (MISTERPLEX_CLKPIX_CEA24_HZ == MISTERPLEX_CLKPIX_COMPACT_HZ) begin : g_clkpix_cea_ne_compact
			misterplex_clkpix_cea24_must_differ_from_compact u_ne();
		end
		if ((64'd50_000_000 * MISTERPLEX_CLKPIX_COMPACT_PLL_M)
		    / (64'(MISTERPLEX_CLKPIX_COMPACT_PLL_N) * 64'(MISTERPLEX_CLKPIX_COMPACT_PLL_C))
		    != 64'(MISTERPLEX_CLKPIX_COMPACT_HZ)) begin : g_clkpix_mn_c
			misterplex_clkpix_compact_mnc_not_exact u_mnc();
		end
		if ((64'd50_000_000 * MISTERPLEX_CLKPIX_CEA24_PLL_M)
		    / (64'(MISTERPLEX_CLKPIX_CEA24_PLL_N) * 64'(MISTERPLEX_CLKPIX_CEA24_PLL_C))
		    != 64'(MISTERPLEX_CLKPIX_CEA24_HZ)) begin : g_clkpix_cea24_mn_c
			misterplex_clkpix_cea24_mnc_not_exact u_cea_mnc();
		end
	endgenerate

	(* noprune *) reg [31:0] r_sys, r_pix, r_cea_pf, r_l4_pf;
	(* noprune *) reg [7:0]  r_ppc;
	(* noprune *) reg        r_cea_fast, r_l4_fast, r_valid;
	(* noprune *) reg [15:0] r_peak_x10;

	localparam int PEAK_X10 = (SYS_HZ / 100_000) * PPC;

	always @(posedge clk) begin
		if (reset) begin
			r_sys <= 32'(SYS_HZ); r_pix <= 32'(PIX_HZ); r_ppc <= 8'(PPC);
			r_cea_pf <= 32'(CEA_PF); r_l4_pf <= 32'(L4_PF);
			r_cea_fast <= (PIX_HZ < CEA_NEED);
			r_l4_fast <= (longint'(SYS_HZ) < L4_NEED);
			r_peak_x10 <= 16'(PEAK_X10); r_valid <= 1'b1;
		end else begin
			r_sys <= 32'(SYS_HZ); r_pix <= 32'(PIX_HZ); r_ppc <= 8'(PPC);
			r_cea_pf <= 32'(CEA_PF); r_l4_pf <= 32'(L4_PF);
			r_cea_fast <= (PIX_HZ < CEA_NEED);
			r_l4_fast <= (longint'(SYS_HZ) < L4_NEED);
			r_peak_x10 <= 16'(PEAK_X10); r_valid <= 1'b1;
		end
	end

	assign clk_sys_hz = r_sys;
	assign clk_pix_hz = r_pix;
	assign present_ppc = r_ppc;
	assign cea_pix_frame = r_cea_pf;
	assign l4_pix_frame = r_l4_pf;
	assign cea_24_needs_faster_pix = r_cea_fast;
	assign l4_24_needs_faster_sys = r_l4_fast;
	assign peak_mpix_s_x10 = r_peak_x10;
	assign kit_id_valid = r_valid;

	// ---- runtime measure (load-bearing = VSync count → fps_x10) ----
	// VSync is ~24 Hz: safe to edge-detect after 2FF into clk_sys.
	// clk_pix may be 29.7 MHz > clk_sys/2: do NOT rate-count pix from sys
	// (Nyquist). pix_ok = saw both levels of clk_pix (clock not stuck).
	// meas_pix_count is undersampled edge activity only (diagnostic).
	reg pix_s1, pix_s2, pix_s3;
	reg vs_s1, vs_s2, vs_s3;
	always @(posedge clk) begin
		if (reset) begin
			pix_s1 <= 1'b0; pix_s2 <= 1'b0; pix_s3 <= 1'b0;
			vs_s1  <= 1'b0; vs_s2  <= 1'b0; vs_s3  <= 1'b0;
		end else begin
			pix_s1 <= clk_pix; pix_s2 <= pix_s1; pix_s3 <= pix_s2;
			vs_s1  <= vsync;   vs_s2  <= vs_s1;  vs_s3  <= vs_s2;
		end
	end
	wire pix_rise = pix_s2 & ~pix_s3;
	wire vs_rise  = vs_s2  & ~vs_s3;

	reg [31:0] win_cnt;
	reg [31:0] pix_acc;
	reg [15:0] frm_acc;
	reg        saw_pix0, saw_pix1;
	reg [31:0] pix_sticky;
	reg [15:0] frm_sticky;
	reg [7:0]  fps_x10_sticky, flags_sticky;
	reg        done_sticky;

	// fps bands fixed-point x10 — gap 60 keeps 16.16 and 24 non-overlapping
	localparam int FPS_PASS_LO = 230; // 23.0
	localparam int FPS_PASS_HI = 250; // 25.0
	localparam int FPS_TRAP_LO = 150; // 15.0
	localparam int FPS_TRAP_HI = 170; // 17.0

`ifdef PRESENT_CLK_PIX_PLL
	localparam bit PLL_ON = 1'b1;
`else
	localparam bit PLL_ON = 1'b0;
`endif

	always @(posedge clk) begin
		if (reset) begin
			win_cnt <= 32'd0;
			pix_acc <= 32'd0;
			frm_acc <= 16'd0;
			saw_pix0 <= 1'b0;
			saw_pix1 <= 1'b0;
			pix_sticky <= 32'd0;
			frm_sticky <= 16'd0;
			fps_x10_sticky <= 8'd0;
			flags_sticky <= 8'd0;
			done_sticky <= 1'b0;
		end else begin
			if (pix_rise)
				pix_acc <= pix_acc + 32'd1;
			if (vs_rise)
				frm_acc <= frm_acc + 16'd1;
			if (!pix_s2)
				saw_pix0 <= 1'b1;
			if (pix_s2)
				saw_pix1 <= 1'b1;

			if (win_cnt >= 32'(WIN_CYC - 1)) begin
				// close window → sticky publish (NBA: pre-update acc + this-cycle rise)
				pix_sticky <= pix_acc + (pix_rise ? 32'd1 : 32'd0);
				frm_sticky <= frm_acc + (vs_rise ? 16'd1 : 16'd0);
				// fps_x10 = frames*10; saturate ≥26 → 255
				if ((frm_acc + (vs_rise ? 16'd1 : 16'd0)) >= 16'd26)
					fps_x10_sticky <= 8'd255;
				else
					fps_x10_sticky <= 8'((frm_acc + (vs_rise ? 16'd1 : 16'd0)) * 16'd10);
				// {3'b0, trap16, pll_on, fps_ok, pix_toggling, valid}
				flags_sticky <= {
					3'b0,
					(((frm_acc + (vs_rise ? 16'd1 : 16'd0)) * 16'd10) >= 16'(FPS_TRAP_LO))
					 && (((frm_acc + (vs_rise ? 16'd1 : 16'd0)) * 16'd10) <= 16'(FPS_TRAP_HI)),
					PLL_ON,
					(((frm_acc + (vs_rise ? 16'd1 : 16'd0)) * 16'd10) >= 16'(FPS_PASS_LO))
					 && (((frm_acc + (vs_rise ? 16'd1 : 16'd0)) * 16'd10) <= 16'(FPS_PASS_HI)),
					(saw_pix0 & saw_pix1),
					1'b1
				};
				done_sticky <= 1'b1;
				win_cnt <= 32'd0;
				pix_acc <= 32'd0;
				frm_acc <= 16'd0;
				saw_pix0 <= 1'b0;
				saw_pix1 <= 1'b0;
			end else begin
				win_cnt <= win_cnt + 32'd1;
			end
		end
	end

	assign meas_pix_count   = pix_sticky;
	assign meas_frame_count = frm_sticky;
	assign meas_fps_x10     = fps_x10_sticky;
	assign meas_flags       = flags_sticky;
	assign meas_window_done = done_sticky;
endmodule
