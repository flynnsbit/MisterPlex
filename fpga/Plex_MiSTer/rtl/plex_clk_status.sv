// Fabric clock configuration stamp + runtime refresh measure (w-clock).
//
// Compile-time: noprune Hz/PPC/recipe gates (post-fit hierarchy proof).
// Runtime: measure clk_pix edges and VSync rises over exactly SYS_HZ cycles of
// clk_sys (~1 s wall if sys is 20 MHz). Independent of clk_pix period — this is
// how 16.16 Hz (same-clock trap) is distinguished from 24 Hz on the device.
//
// Expected with PRESENT_CLK_PIX_PLL COMPACT 29.7 + H1650xV750 glass:
//   meas_pix_count  ~ 29_700_000  (+/-1%)
//   meas_frame_count ~ 24         (+/-1)
// FAIL mode (clk_pix tied to 20 MHz, same glass): pix~20e6, frames~16
//
// M10K: 0 — no RAM arrays (flops/counters only); layout N/A. ALM: <200 ESTIMATE UNVERIFIED until fit.

`include "misterplex_clk_hz.svh"
`include "misterplex_clk_pix_recipe.svh"

module plex_clk_status (
	input  wire        clk,       // clk_sys — time base for 1 s window
	input  wire        reset,
	input  wire        clk_pix,   // pixel domain (pll outclk_3 or tied sys)
	input  wire        vsync,     // present VSync (2FF into sys)
	output wire [31:0] clk_sys_hz,
	output wire [31:0] clk_pix_hz,
	output wire [7:0]  present_ppc,
	output wire [31:0] cea_pix_frame,
	output wire [31:0] l4_pix_frame,
	output wire        cea_24_needs_faster_pix,
	output wire        l4_24_needs_faster_sys,
	output wire [15:0] peak_mpix_s_x10,
	output wire        kit_id_valid,
	output wire [31:0] meas_pix_count,
	output wire [15:0] meas_frame_count,
	output wire [7:0]  meas_fps_x10,
	output wire [7:0]  meas_flags,
	output wire        meas_window_done
);
	localparam int SYS_HZ  = `MISTERPLEX_CLK_SYS_HZ;
	localparam int PIX_HZ  = `MISTERPLEX_CLK_PIX_HZ;
	localparam int PPC     = `MISTERPLEX_PRESENT_PPC;
	localparam int CEA_PF  = `MISTERPLEX_CEA720_PIX_FRAME;
	localparam int L4_PF   = `MISTERPLEX_L4_PIX_FRAME;
	localparam int CEA_NEED = `MISTERPLEX_CEA720_F24_HZ;
	localparam longint L4_NEED = longint'(`MISTERPLEX_L4_F24_HZ);

`ifdef PRESENT_CLK_PIX_PLL
	localparam bit PLL_ON = 1'b1;
`else
	localparam bit PLL_ON = 1'b0;
`endif

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

	// Toggle on clk_pix; count rising edges on clk_sys via 2FF (1 count per pix clk).
	(* keep *) reg pix_tog = 1'b0;
	always @(posedge clk_pix or posedge reset) begin
		if (reset) pix_tog <= 1'b0;
		else pix_tog <= ~pix_tog;
	end
	reg [2:0] pix_sync;
	always @(posedge clk) begin
		if (reset) pix_sync <= 3'b0;
		else pix_sync <= {pix_sync[1:0], pix_tog};
	end

	reg [2:0] vs_sync;
	always @(posedge clk) begin
		if (reset) vs_sync <= 3'b0;
		else vs_sync <= {vs_sync[1:0], vsync};
	end
	wire vs_rise = vs_sync[1] & ~vs_sync[2];

	reg [31:0] win_cnt, pix_acc, pix_sticky;
	reg [15:0] frm_acc, frm_sticky;
	reg [7:0]  fps_x10_sticky, flags_sticky;
	reg        done_sticky;
	localparam int PIX_LO = (PIX_HZ * 99) / 100;
	localparam int PIX_HI = (PIX_HZ * 101) / 100;

	always @(posedge clk) begin
		if (reset) begin
			win_cnt <= 32'd0; pix_acc <= 32'd0; frm_acc <= 16'd0;
			pix_sticky <= 32'd0; frm_sticky <= 16'd0;
			fps_x10_sticky <= 8'd0; flags_sticky <= 8'd0; done_sticky <= 1'b0;
		end else begin
			if (pix_sync[2] & ~pix_sync[1])
				pix_acc <= pix_acc + 32'd1;
			if (vs_rise)
				frm_acc <= frm_acc + 16'd1;
			if (win_cnt >= 32'(SYS_HZ - 1)) begin
				pix_sticky <= pix_acc;
				frm_sticky <= frm_acc;
				if (frm_acc > 16'd25)
					fps_x10_sticky <= 8'd255;
				else
					fps_x10_sticky <= 8'(frm_acc * 16'd10);
				flags_sticky <= {
					4'b0,
					PLL_ON,
					(frm_acc >= 16'd23 && frm_acc <= 16'd25),
					(pix_acc >= 32'(PIX_LO) && pix_acc <= 32'(PIX_HI)),
					1'b1
				};
				done_sticky <= 1'b1;
				win_cnt <= 32'd0;
				pix_acc <= 32'd0;
				frm_acc <= 16'd0;
			end else begin
				win_cnt <= win_cnt + 32'd1;
			end
		end
	end

	assign meas_pix_count = pix_sticky;
	assign meas_frame_count = frm_sticky;
	assign meas_fps_x10 = fps_x10_sticky;
	assign meas_flags = flags_sticky;
	assign meas_window_done = done_sticky;
endmodule
