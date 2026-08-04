// plex_clk_status — fabric clock kit identity + runtime refresh/raster measure.
//
// rd-duck NACK (edge-count): never edge-count clk_pix in clk_sys (Nyquist).
//   → Gray free-run counters in clk_pix + period-based fps from VSync.
//
// rd-duck NACK (VSync-only): VSync cadence alone is NOT 720p timing proof.
//   Adversarial wrong H/V with same HT*VT keeps fps/CE/frame while raster wrong.
//   → Per-frame pixel-domain totals required:
//        CE/frame  == H_TOTAL*V_TOTAL   (1_200_000 product)
//        lines/frm == V_TOTAL           (750)
//        CE/line   == H_TOTAL           (1600)
//        DE/frame  == H_ACTIVE*V_ACTIVE (921_600)
//        DE/line   == H_ACTIVE (1280) on each active line, 0 on blank
//        active lines == V_ACTIVE (720)
//        CE≈1, underrun delta == 0
//
// PRODUCT glass @ shared pll 28.8 MHz H1600×V750: fps_eff = 24.000 (fps_x10=240)
// REJECT 242 (retired 30 MHz/H1650 defect). Trap ~16.67 Hz (20 MHz) → fps_x10≈167.
//
// flags: {raster_ok, de_ok, ce_ok, trap16, pll_on, fps_ok, pix_ok, valid}
// PASS product: fps∈[239,241] + valid + fps_ok + pix_ok + ce_ok + de_ok + raster_ok
//
// Work item: p720-clock-28p8-exact24

`include "misterplex_clk_hz.svh"
`include "misterplex_clk_pix_recipe.svh"

module plex_clk_status #(
	parameter int MEAS_WINDOW_CYCLES = 0,
	// Product COMPACT defaults; TB overrides for fast adversarial raster cases.
	parameter int H_TOTAL  = 1600,
	parameter int V_TOTAL  = 750,
	parameter int H_ACTIVE = 1280,
	parameter int V_ACTIVE = 720
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        clk_pix,
	input  wire        vsync,
	input  wire        hsync,
	input  wire        ce_pix,
	input  wire        de,
	input  wire [15:0] underrun_count,
	output wire [31:0] clk_sys_hz,
	output wire [31:0] clk_pix_hz,
	output wire [7:0]  present_ppc,
	output wire [31:0] cea_pix_frame,
	output wire [31:0] l4_pix_frame,
	output wire        cea_24_needs_faster_pix,
	output wire        l4_24_needs_faster_sys,
	output wire [15:0] peak_mpix_s_x10,
	output wire        kit_id_valid,
	// Window totals (sys-sampled Gray deltas over MEAS_WINDOW)
	output wire [31:0] meas_pix_count,
	output wire [31:0] meas_ce_count,
	output wire [31:0] meas_de_count,
	output wire [15:0] meas_frame_count,
	// Last complete frame (pixel-domain sticky, sys-visible)
	output wire [31:0] meas_ce_frame,
	output wire [31:0] meas_de_frame,
	output wire [15:0] meas_lines_frame,
	output wire [15:0] meas_active_lines,
	output wire [15:0] meas_ce_line,
	output wire [7:0]  meas_fps_x10,
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

	// Geometry expectations (product: 1600×750, DE 1280×720 → CE/frm=1_200_000, DE/frm=921_600)
	localparam int CE_FRAME_EXP = H_TOTAL * V_TOTAL;
	localparam int DE_FRAME_EXP = H_ACTIVE * V_ACTIVE;

	localparam longint EXP_PIX =
		(longint'(PIX_HZ) * longint'(WIN_CYC)) / longint'(SYS_HZ);
	localparam longint EXP_PIX_LO = (EXP_PIX * 98) / 100;
	localparam longint EXP_PIX_HI = (EXP_PIX * 102) / 100;

	// Frame-total tolerances (edge alignment / first partial line)
	localparam int CE_FRAME_TOL = 8;
	localparam int DE_FRAME_TOL = 8;
	localparam int CE_LINE_TOL  = 2;
	localparam int LINES_TOL    = 1;

	(* keep, noprune *) wire [31:0] keep_clkpix_compact = MISTERPLEX_CLKPIX_COMPACT_HZ[31:0];
	(* keep, noprune *) wire [31:0] keep_clkpix_cea24 = MISTERPLEX_CLKPIX_CEA24_HZ[31:0];
	(* keep, noprune *) wire [31:0] keep_clkpix_product = MISTERPLEX_CLKPIX_PRODUCT_HZ[31:0];
	generate
		// Product MUST be shared-PLL 28.8 MHz (exact 24.000 @ H1600×V750).
		if (MISTERPLEX_CLKPIX_COMPACT_HZ != 28_800_000) begin : g_clkpix_compact
			misterplex_clkpix_compact_must_be_28800000 u_compact();
		end
		if (MISTERPLEX_CLKPIX_COMPACT_H != 1600) begin : g_clkpix_h
			misterplex_clkpix_compact_h_must_be_1600 u_h();
		end
		// 29.7 illegal on shared VCO; 30 MHz was false product (24.242).
		if (MISTERPLEX_CLKPIX_COMPACT_HZ == 29_700_000) begin : g_clkpix_no297
			misterplex_clkpix_297_illegal_on_shared_pll u_no297();
		end
		if (MISTERPLEX_CLKPIX_COMPACT_HZ == 30_000_000) begin : g_clkpix_no30
			misterplex_clkpix_30000000_is_retired_false_product u_no30();
		end
		if (MISTERPLEX_CLKPIX_CEA24_HZ != 59_400_000) begin : g_clkpix_cea24
			misterplex_clkpix_cea24_must_be_59400000 u_cea24();
		end
		if (MISTERPLEX_CLKPIX_PRODUCT_HZ != MISTERPLEX_CLKPIX_COMPACT_HZ) begin : g_clkpix_product
			misterplex_clkpix_product_must_be_compact u_prod();
		end
		// Shared VCO recipe: 50*M/(N*C) must equal COMPACT_HZ exactly.
		if ((64'd50_000_000 * MISTERPLEX_CLKPIX_COMPACT_PLL_M)
		    / (64'(MISTERPLEX_CLKPIX_COMPACT_PLL_N) * 64'(MISTERPLEX_CLKPIX_COMPACT_PLL_C))
		    != 64'(MISTERPLEX_CLKPIX_COMPACT_HZ)) begin : g_clkpix_mn_c
			misterplex_clkpix_compact_mnc_not_exact u_mnc();
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

	// ---- Gray helpers ----
	function automatic [31:0] bin2gray(input [31:0] b);
		bin2gray = b ^ (b >> 1);
	endfunction
	function automatic [31:0] gray2bin(input [31:0] g);
		integer k;
		reg [31:0] b;
		begin
			b[31] = g[31];
			for (k = 30; k >= 0; k = k - 1)
				b[k] = b[k+1] ^ g[k];
			gray2bin = b;
		end
	endfunction

	// ---- Pix-domain free-run (window) + per-frame raster ----
	reg [31:0] pix_bin, ce_bin, de_bin;
	reg [31:0] pix_gray, ce_gray, de_gray;

	reg        hs_d, vs_d;
	reg [31:0] frm_ce, frm_de, frm_pix;
	reg [15:0] frm_lines, frm_active;
	reg [15:0] line_ce, line_de;
	reg        line_seen;          // completed ≥1 full hs→hs this frame
	reg        de_line_bad, ce_line_bad;
	reg [15:0] last_ce_line;

	// Sticky last complete frame (pix domain)
	reg [31:0] st_ce_frame, st_de_frame, st_pix_frame;
	reg [15:0] st_lines, st_active, st_ce_line;
	reg        st_de_line_ok, st_ce_line_ok, st_frame_valid;
	reg [31:0] st_ce_g, st_de_g, st_pix_g;
	reg [15:0] st_lines_g, st_active_g, st_ce_line_g;
	reg        st_meta_g; // {frame_valid, de_line_ok, ce_line_ok} packed later via bin gray of flags

	reg [2:0]  st_flag_bin, st_flag_gray; // [0]=frame_valid [1]=de_line_ok [2]=ce_line_ok

	always @(posedge clk_pix or posedge reset) begin
		if (reset) begin
			pix_bin <= 0; ce_bin <= 0; de_bin <= 0;
			pix_gray <= 0; ce_gray <= 0; de_gray <= 0;
			hs_d <= 0; vs_d <= 0;
			frm_ce <= 0; frm_de <= 0; frm_pix <= 0;
			frm_lines <= 0; frm_active <= 0;
			line_ce <= 0; line_de <= 0; line_seen <= 0;
			de_line_bad <= 0; ce_line_bad <= 0; last_ce_line <= 0;
			st_ce_frame <= 0; st_de_frame <= 0; st_pix_frame <= 0;
			st_lines <= 0; st_active <= 0; st_ce_line <= 0;
			st_de_line_ok <= 0; st_ce_line_ok <= 0; st_frame_valid <= 0;
			st_ce_g <= 0; st_de_g <= 0; st_pix_g <= 0;
			st_lines_g <= 0; st_active_g <= 0; st_ce_line_g <= 0;
			st_flag_bin <= 0; st_flag_gray <= 0;
		end else begin
			hs_d <= hsync;
			vs_d <= vsync;

			// free-run window counters
			pix_bin  <= pix_bin + 32'd1;
			pix_gray <= bin2gray(pix_bin + 32'd1);
			if (ce_pix) begin
				ce_bin  <= ce_bin + 32'd1;
				ce_gray <= bin2gray(ce_bin + 32'd1);
			end
			if (de) begin
				de_bin  <= de_bin + 32'd1;
				de_gray <= bin2gray(de_bin + 32'd1);
			end

			// per-frame accumulators (every pix clock)
			frm_pix <= frm_pix + 32'd1;
			if (ce_pix) begin
				frm_ce  <= frm_ce + 32'd1;
				line_ce <= line_ce + 16'd1;
			end
			if (de) begin
				frm_de  <= frm_de + 32'd1;
				line_de <= line_de + 16'd1;
			end

			// End of line: HSync rise (pixel domain)
			if (hsync && !hs_d) begin
				if (line_seen) begin
					// Complete line checks
					if (line_de != 16'd0 && line_de != 16'(H_ACTIVE))
						de_line_bad <= 1'b1;
					if (line_de == 16'(H_ACTIVE))
						frm_active <= frm_active + 16'd1;
					// CE/line must be H_TOTAL when CE=1 every clk
					if ((line_ce < 16'(H_TOTAL - CE_LINE_TOL)) ||
					    (line_ce > 16'(H_TOTAL + CE_LINE_TOL)))
						ce_line_bad <= 1'b1;
					last_ce_line <= line_ce;
				end
				frm_lines <= frm_lines + 16'd1;
				line_ce <= 16'd0;
				line_de <= 16'd0;
				line_seen <= 1'b1;
			end

			// End of frame: VSync rise — publish sticky, reset accumulators
			if (vsync && !vs_d) begin
				st_ce_frame   <= frm_ce;
				st_de_frame   <= frm_de;
				st_pix_frame  <= frm_pix;
				st_lines      <= frm_lines;
				st_active     <= frm_active;
				st_ce_line    <= last_ce_line;
				st_de_line_ok <= ~de_line_bad;
				st_ce_line_ok <= ~ce_line_bad;
				st_frame_valid<= 1'b1;
				st_ce_g       <= bin2gray(frm_ce);
				st_de_g       <= bin2gray(frm_de);
				st_pix_g      <= bin2gray(frm_pix);
				st_lines_g    <= frm_lines ^ (frm_lines >> 1); // 16-bit gray
				st_active_g   <= frm_active ^ (frm_active >> 1);
				st_ce_line_g  <= last_ce_line ^ (last_ce_line >> 1);
				// flag_next = {ce_line_ok, de_line_ok, frame_valid}
				st_flag_bin   <= {~ce_line_bad, ~de_line_bad, 1'b1};
				st_flag_gray  <= {~ce_line_bad, ~de_line_bad, 1'b1}
				                 ^ ({~ce_line_bad, ~de_line_bad, 1'b1} >> 1);

				frm_ce <= 0; frm_de <= 0; frm_pix <= 0;
				frm_lines <= 0; frm_active <= 0;
				line_ce <= 0; line_de <= 0; line_seen <= 0;
				de_line_bad <= 0; ce_line_bad <= 0;
			end
		end
	end

	// ---- Sys-domain: sample Gray frame stickies + window Gray ----
	reg [31:0] pix_g_s1, pix_g_s2, ce_g_s1, ce_g_s2, de_g_s1, de_g_s2;
	reg [31:0] fce_g_s1, fce_g_s2, fde_g_s1, fde_g_s2, fpx_g_s1, fpx_g_s2;
	reg [15:0] fln_g_s1, fln_g_s2, fac_g_s1, fac_g_s2, fcl_g_s1, fcl_g_s2;
	reg [2:0]  ffg_s1, ffg_s2;
	always @(posedge clk) begin
		if (reset) begin
			pix_g_s1 <= 0; pix_g_s2 <= 0;
			ce_g_s1 <= 0; ce_g_s2 <= 0;
			de_g_s1 <= 0; de_g_s2 <= 0;
			fce_g_s1 <= 0; fce_g_s2 <= 0;
			fde_g_s1 <= 0; fde_g_s2 <= 0;
			fpx_g_s1 <= 0; fpx_g_s2 <= 0;
			fln_g_s1 <= 0; fln_g_s2 <= 0;
			fac_g_s1 <= 0; fac_g_s2 <= 0;
			fcl_g_s1 <= 0; fcl_g_s2 <= 0;
			ffg_s1 <= 0; ffg_s2 <= 0;
		end else begin
			pix_g_s1 <= pix_gray; pix_g_s2 <= pix_g_s1;
			ce_g_s1  <= ce_gray;  ce_g_s2  <= ce_g_s1;
			de_g_s1  <= de_gray;  de_g_s2  <= de_g_s1;
			fce_g_s1 <= st_ce_g;  fce_g_s2 <= fce_g_s1;
			fde_g_s1 <= st_de_g;  fde_g_s2 <= fde_g_s1;
			fpx_g_s1 <= st_pix_g; fpx_g_s2 <= fpx_g_s1;
			fln_g_s1 <= st_lines_g; fln_g_s2 <= fln_g_s1;
			fac_g_s1 <= st_active_g; fac_g_s2 <= fac_g_s1;
			fcl_g_s1 <= st_ce_line_g; fcl_g_s2 <= fcl_g_s1;
			ffg_s1   <= st_flag_gray; ffg_s2 <= ffg_s1;
		end
	end
	wire [31:0] pix_now = gray2bin(pix_g_s2);
	wire [31:0] ce_now  = gray2bin(ce_g_s2);
	wire [31:0] de_now  = gray2bin(de_g_s2);
	wire [31:0] ce_frm  = gray2bin(fce_g_s2);
	wire [31:0] de_frm  = gray2bin(fde_g_s2);
	wire [31:0] pix_frm = gray2bin(fpx_g_s2);
	// 16-bit gray2bin
	function automatic [15:0] gray2bin16(input [15:0] g);
		integer k;
		reg [15:0] b;
		begin
			b[15] = g[15];
			for (k = 14; k >= 0; k = k - 1)
				b[k] = b[k+1] ^ g[k];
			gray2bin16 = b;
		end
	endfunction
	function automatic [2:0] gray2bin3(input [2:0] g);
		reg [2:0] b;
		begin
			b[2] = g[2];
			b[1] = b[2] ^ g[1];
			b[0] = b[1] ^ g[0];
			gray2bin3 = b;
		end
	endfunction
	wire [15:0] lines_frm  = gray2bin16(fln_g_s2);
	wire [15:0] active_frm = gray2bin16(fac_g_s2);
	wire [15:0] celine_frm = gray2bin16(fcl_g_s2);
	wire [2:0]  flag_frm   = gray2bin3(ffg_s2);
	wire        frame_valid_s = flag_frm[0];
	wire        de_line_ok_s  = flag_frm[1];
	wire        ce_line_ok_s  = flag_frm[2];

	// VSync 2FF + period (sys cycles) — distinguishes 240 vs 242 without ±1 Hz window quant
	reg vs_s1, vs_s2, vs_s3;
	always @(posedge clk) begin
		if (reset) begin
			vs_s1 <= 0; vs_s2 <= 0; vs_s3 <= 0;
		end else begin
			vs_s1 <= vsync; vs_s2 <= vs_s1; vs_s3 <= vs_s2;
		end
	end
	wire vs_rise = vs_s2 & ~vs_s3;

	reg [31:0] period_cnt, period_sticky;
	reg        period_valid;
	always @(posedge clk) begin
		if (reset) begin
			period_cnt <= 0; period_sticky <= 0; period_valid <= 0;
		end else if (vs_rise) begin
			if (period_cnt != 0) begin
				period_sticky <= period_cnt;
				period_valid  <= 1'b1;
			end
			period_cnt <= 32'd1;
		end else if (period_cnt != 32'hFFFF_FFFF) begin
			period_cnt <= period_cnt + 32'd1;
		end
	end

	wire [31:0] fps_x10_raw = (period_valid && period_sticky >= 32'd1000)
		? (32'(SYS_HZ) * 32'd10) / period_sticky
		: 32'd0;
	wire [7:0] fps_from_period = (fps_x10_raw > 32'd255) ? 8'd255 : fps_x10_raw[7:0];

	// Underrun: any increase over the measure window fails (sys domain)
	reg [15:0] ur_mark;
	reg        ur_bad;

	// Window bookkeeping
	reg [31:0] win_cnt, pix_mark, ce_mark, de_mark;
	reg [15:0] frm_acc;
	reg [31:0] pix_sticky, ce_sticky, de_sticky;
	reg [15:0] frm_sticky;
	reg [31:0] ce_frame_sticky, de_frame_sticky;
	reg [15:0] lines_sticky, active_sticky, celine_sticky;
	reg [7:0]  fps_x10_sticky, flags_sticky;
	reg        done_sticky, marked;

	reg [31:0] d_pix_w, d_ce_w, d_de_w;
	reg [15:0] f_now_w;
	reg [7:0]  fx10_w;
	reg        pix_ok_w, ce_ok_w, de_ok_w, fps_ok_w, trap_w, raster_ok_w;
	reg        ce_frame_ok_w, de_frame_ok_w, lines_ok_w, active_ok_w, ce1_ok_w;

	// Product exact-24 → fps_x10=240. MUST PASS 240 and REJECT 242 (false product).
	localparam int FPS_PASS_LO = 239;
	localparam int FPS_PASS_HI = 241;
	localparam int FPS_DEFECT242_LO = 242;
	localparam int FPS_DEFECT242_HI = 244;
	localparam int FPS_TRAP_LO = 150;
	localparam int FPS_TRAP_HI = 170;

`ifdef PRESENT_CLK_PIX_PLL
	localparam bit PLL_ON = 1'b1;
`else
	localparam bit PLL_ON = 1'b0;
`endif

	function automatic int abs_diff32(input [31:0] a, input [31:0] b);
		abs_diff32 = (a > b) ? int'(a - b) : int'(b - a);
	endfunction
	function automatic int abs_diff16(input [15:0] a, input [15:0] b);
		// Cast before SUB so Verilator does not WIDTHEXPAND 16→32 on operands.
		abs_diff16 = (a > b) ? (int'(a) - int'(b)) : (int'(b) - int'(a));
	endfunction

	always @(*) begin
		d_pix_w = pix_now - pix_mark;
		d_ce_w  = ce_now  - ce_mark;
		d_de_w  = de_now  - de_mark;
		f_now_w = frm_acc + (vs_rise ? 16'd1 : 16'd0);
		if (period_valid && fps_from_period != 8'd0)
			fx10_w = fps_from_period;
		else if (f_now_w >= 16'd26)
			fx10_w = 8'd255;
		else
			fx10_w = 8'(f_now_w * 16'd10);

		pix_ok_w = (d_pix_w >= 32'(EXP_PIX_LO)) && (d_pix_w <= 32'(EXP_PIX_HI));
		// Window CE should track pix (CE≈1); loose floor still rejects CE stuck-0
		ce_ok_w  = frame_valid_s &&
		           (abs_diff32(ce_frm, 32'(CE_FRAME_EXP)) <= CE_FRAME_TOL);
		de_ok_w  = frame_valid_s &&
		           (abs_diff32(de_frm, 32'(DE_FRAME_EXP)) <= DE_FRAME_TOL);
		fps_ok_w = (fx10_w >= 8'(FPS_PASS_LO)) && (fx10_w <= 8'(FPS_PASS_HI));
		trap_w   = (fx10_w >= 8'(FPS_TRAP_LO)) && (fx10_w <= 8'(FPS_TRAP_HI));

		ce_frame_ok_w = ce_ok_w;
		de_frame_ok_w = de_ok_w;
		lines_ok_w = frame_valid_s &&
		             (abs_diff16(lines_frm, 16'(V_TOTAL)) <= LINES_TOL);
		active_ok_w = frame_valid_s &&
		              (abs_diff16(active_frm, 16'(V_ACTIVE)) <= LINES_TOL);
		// CE≈1: pix clocks in frame ≈ CE count ≈ H*V
		ce1_ok_w = frame_valid_s &&
		           (abs_diff32(pix_frm, 32'(CE_FRAME_EXP)) <= CE_FRAME_TOL) &&
		           (abs_diff32(ce_frm, pix_frm) <= CE_FRAME_TOL);

		raster_ok_w = frame_valid_s && ce_frame_ok_w && de_frame_ok_w &&
		              lines_ok_w && active_ok_w && ce_line_ok_s && de_line_ok_s &&
		              ce1_ok_w && !ur_bad &&
		              (abs_diff16(celine_frm, 16'(H_TOTAL)) <= CE_LINE_TOL);
	end

	always @(posedge clk) begin
		if (reset) begin
			win_cnt <= 0; pix_mark <= 0; ce_mark <= 0; de_mark <= 0;
			frm_acc <= 0; pix_sticky <= 0; ce_sticky <= 0; de_sticky <= 0;
			frm_sticky <= 0; fps_x10_sticky <= 0; flags_sticky <= 0;
			ce_frame_sticky <= 0; de_frame_sticky <= 0;
			lines_sticky <= 0; active_sticky <= 0; celine_sticky <= 0;
			done_sticky <= 0; marked <= 0;
			ur_mark <= 0; ur_bad <= 1'b0;
		end else begin
			if (vs_rise)
				frm_acc <= frm_acc + 16'd1;
			if (!marked) begin
				pix_mark <= pix_now; ce_mark <= ce_now; de_mark <= de_now;
				ur_mark <= underrun_count; ur_bad <= 1'b0;
				marked <= 1'b1; win_cnt <= 0; frm_acc <= 0;
			end else begin
				if (underrun_count != ur_mark)
					ur_bad <= 1'b1;
				if (win_cnt >= 32'(WIN_CYC - 1)) begin
					pix_sticky <= d_pix_w; ce_sticky <= d_ce_w; de_sticky <= d_de_w;
					frm_sticky <= f_now_w; fps_x10_sticky <= fx10_w;
					ce_frame_sticky <= ce_frm;
					de_frame_sticky <= de_frm;
					lines_sticky <= lines_frm;
					active_sticky <= active_frm;
					celine_sticky <= celine_frm;
					// flags: {raster_ok, de_ok, ce_ok, trap16, pll_on, fps_ok, pix_ok, valid}
					flags_sticky <= {raster_ok_w, de_ok_w, ce_ok_w, trap_w, PLL_ON,
					                 fps_ok_w, pix_ok_w, 1'b1};
					done_sticky <= 1'b1;
					pix_mark <= pix_now; ce_mark <= ce_now; de_mark <= de_now;
					ur_mark <= underrun_count; ur_bad <= 1'b0;
					win_cnt <= 0; frm_acc <= 0;
				end else
					win_cnt <= win_cnt + 32'd1;
			end
		end
	end

	assign meas_pix_count    = pix_sticky;
	assign meas_ce_count     = ce_sticky;
	assign meas_de_count     = de_sticky;
	assign meas_frame_count  = frm_sticky;
	assign meas_ce_frame     = ce_frame_sticky;
	assign meas_de_frame     = de_frame_sticky;
	assign meas_lines_frame  = lines_sticky;
	assign meas_active_lines = active_sticky;
	assign meas_ce_line      = celine_sticky;
	assign meas_fps_x10      = fps_x10_sticky;
	assign meas_flags        = flags_sticky;
	assign meas_window_done  = done_sticky;
endmodule
