// plex_clk_status — fabric clock kit identity + runtime refresh measure.
//
// Static kit: intended SYS/PIX/PPC via misterplex_clk_hz.svh + recipe locks.
// Runtime measure (PRODUCT_NO_STUB raw[14]/raw[15]): OBSERVED events.
//
// rd-duck NACK: never edge-count clk_pix in clk_sys (Nyquist). Use Gray
// free-run counters in clk_pix domain + period-based fps from VSync.
//
// Product glass @ 30 MHz H1650×V750: fps_eff = 24.242424… (fps_x10≈242)
// Exact 24.000 (fps_x10=240) is a DIFFERENT recipe (28.8/H1600) — distinguishable
// via period measure. Trap 16.16 Hz (20 MHz same-clock) → fps_x10≈162.
//
// flags: {0, de_ok, ce_ok, trap16, pll_on, fps_ok, pix_ok, valid}
// PASS product: fps_x10 ∈ [241,244] + valid + fps_ok + pix_ok
// FAIL trap:    fps_x10 ∈ [150,170]
// EXACT24 band: fps_x10 ∈ [238,240] reported (not product PASS if we ship 24.242)
//
// Work item: p720-clock-pll-legal-30

`include "misterplex_clk_hz.svh"
`include "misterplex_clk_pix_recipe.svh"

module plex_clk_status #(
	parameter int MEAS_WINDOW_CYCLES = 0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        clk_pix,
	input  wire        vsync,
	input  wire        ce_pix,
	input  wire        de,
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
	output wire [31:0] meas_ce_count,
	output wire [31:0] meas_de_count,
	output wire [15:0] meas_frame_count,
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

	localparam int H_TOTAL  = 1650;
	localparam int V_TOTAL  = 750;
	localparam int H_ACTIVE = 1280;
	localparam int V_ACTIVE = 720;

	localparam longint EXP_PIX =
		(longint'(PIX_HZ) * longint'(WIN_CYC)) / longint'(SYS_HZ);
	localparam longint EXP_PIX_LO = (EXP_PIX * 98) / 100;
	localparam longint EXP_PIX_HI = (EXP_PIX * 102) / 100;
	localparam longint EXP_DE =
		(longint'(PIX_HZ) * longint'(H_ACTIVE) * longint'(V_ACTIVE) * longint'(WIN_CYC))
		/ (longint'(SYS_HZ) * longint'(H_TOTAL) * longint'(V_TOTAL));
	localparam longint EXP_DE_LO = (EXP_DE * 90) / 100;
	localparam longint EXP_DE_HI = (EXP_DE * 110) / 100;

	// Expected VSync period in clk_sys cycles: SYS_HZ * HT * VT / PIX_HZ
	localparam longint EXP_PERIOD =
		(longint'(SYS_HZ) * longint'(H_TOTAL) * longint'(V_TOTAL)) / longint'(PIX_HZ);
	// fps_x10 from period: (SYS_HZ * 10) / period

	(* keep, noprune *) wire [31:0] keep_clkpix_compact = MISTERPLEX_CLKPIX_COMPACT_HZ[31:0];
	(* keep, noprune *) wire [31:0] keep_clkpix_cea24 = MISTERPLEX_CLKPIX_CEA24_HZ[31:0];
	(* keep, noprune *) wire [31:0] keep_clkpix_product = MISTERPLEX_CLKPIX_PRODUCT_HZ[31:0];
	generate
		if (MISTERPLEX_CLKPIX_COMPACT_HZ != 30_000_000) begin : g_clkpix_compact
			misterplex_clkpix_compact_must_be_30000000 u_compact();
		end
		if (MISTERPLEX_CLKPIX_COMPACT_HZ == 29_700_000) begin : g_clkpix_no_illegal
			misterplex_clkpix_297_illegal_on_integer_pll u_no297();
		end
		if (MISTERPLEX_CLKPIX_CEA24_HZ != 59_400_000) begin : g_clkpix_cea24
			misterplex_clkpix_cea24_must_be_59400000 u_cea24();
		end
		if (MISTERPLEX_CLKPIX_PRODUCT_HZ != MISTERPLEX_CLKPIX_COMPACT_HZ) begin : g_clkpix_product
			misterplex_clkpix_product_must_be_compact u_prod();
		end
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

	// ---- Gray free-run in clk_pix ----
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

	reg [31:0] pix_bin, ce_bin, de_bin;
	reg [31:0] pix_gray, ce_gray, de_gray;
	always @(posedge clk_pix or posedge reset) begin
		if (reset) begin
			pix_bin <= 0; ce_bin <= 0; de_bin <= 0;
			pix_gray <= 0; ce_gray <= 0; de_gray <= 0;
		end else begin
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
		end
	end

	reg [31:0] pix_g_s1, pix_g_s2, ce_g_s1, ce_g_s2, de_g_s1, de_g_s2;
	always @(posedge clk) begin
		if (reset) begin
			pix_g_s1 <= 0; pix_g_s2 <= 0;
			ce_g_s1 <= 0; ce_g_s2 <= 0;
			de_g_s1 <= 0; de_g_s2 <= 0;
		end else begin
			pix_g_s1 <= pix_gray; pix_g_s2 <= pix_g_s1;
			ce_g_s1 <= ce_gray; ce_g_s2 <= ce_g_s1;
			de_g_s1 <= de_gray; de_g_s2 <= de_g_s1;
		end
	end
	wire [31:0] pix_now = gray2bin(pix_g_s2);
	wire [31:0] ce_now  = gray2bin(ce_g_s2);
	wire [31:0] de_now  = gray2bin(de_g_s2);

	// VSync 2FF + period measure (sys cycles between rises)
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

	// fps_x10 from period: (SYS_HZ * 10) / period  — distinguishes 240 vs 242
	// 32-bit: SYS_HZ*10 fits (200e6); period >= 1000 keeps quotient <= 200000.
	wire [31:0] fps_x10_raw = (period_valid && period_sticky >= 32'd1000)
		? (32'(SYS_HZ) * 32'd10) / period_sticky
		: 32'd0;
	wire [7:0] fps_from_period = (fps_x10_raw > 32'd255) ? 8'd255 : fps_x10_raw[7:0];

	reg [31:0] win_cnt, pix_mark, ce_mark, de_mark;
	reg [15:0] frm_acc;
	reg [31:0] pix_sticky, ce_sticky, de_sticky;
	reg [15:0] frm_sticky;
	reg [7:0]  fps_x10_sticky, flags_sticky;
	reg        done_sticky, marked;

	reg [31:0] d_pix_w, d_ce_w, d_de_w;
	reg [15:0] f_now_w;
	reg [7:0]  fx10_w;
	reg        pix_ok_w, ce_ok_w, de_ok_w, fps_ok_w, trap_w;

	// Product PASS band around 24.242 (242); excludes exact-24 (240) and 16.16
	localparam int FPS_PASS_LO = 241;
	localparam int FPS_PASS_HI = 244;
	localparam int FPS_EXACT24_LO = 238; // distinguishable near-exact 24.0
	localparam int FPS_EXACT24_HI = 240;
	localparam int FPS_TRAP_LO = 150;
	localparam int FPS_TRAP_HI = 170;

`ifdef PRESENT_CLK_PIX_PLL
	localparam bit PLL_ON = 1'b1;
`else
	localparam bit PLL_ON = 1'b0;
`endif

	always @(*) begin
		d_pix_w = pix_now - pix_mark;
		d_ce_w  = ce_now  - ce_mark;
		d_de_w  = de_now  - de_mark;
		f_now_w = frm_acc + (vs_rise ? 16'd1 : 16'd0);
		// Prefer period-derived fps (fine grain); fall back to frame count *10
		if (period_valid && fps_from_period != 8'd0)
			fx10_w = fps_from_period;
		else if (f_now_w >= 16'd26)
			fx10_w = 8'd255;
		else
			fx10_w = 8'(f_now_w * 16'd10);
		pix_ok_w = (d_pix_w >= 32'(EXP_PIX_LO)) && (d_pix_w <= 32'(EXP_PIX_HI));
		ce_ok_w  = (d_ce_w >= (d_pix_w >> 2)) && (d_ce_w <= d_pix_w + 32'd8);
		de_ok_w  = (d_de_w >= 32'(EXP_DE_LO)) && (d_de_w <= 32'(EXP_DE_HI));
		fps_ok_w = (fx10_w >= 8'(FPS_PASS_LO)) && (fx10_w <= 8'(FPS_PASS_HI));
		trap_w   = (fx10_w >= 8'(FPS_TRAP_LO)) && (fx10_w <= 8'(FPS_TRAP_HI));
	end

	always @(posedge clk) begin
		if (reset) begin
			win_cnt <= 0; pix_mark <= 0; ce_mark <= 0; de_mark <= 0;
			frm_acc <= 0; pix_sticky <= 0; ce_sticky <= 0; de_sticky <= 0;
			frm_sticky <= 0; fps_x10_sticky <= 0; flags_sticky <= 0;
			done_sticky <= 0; marked <= 0;
		end else begin
			if (vs_rise)
				frm_acc <= frm_acc + 16'd1;
			if (!marked) begin
				pix_mark <= pix_now; ce_mark <= ce_now; de_mark <= de_now;
				marked <= 1'b1; win_cnt <= 0; frm_acc <= 0;
			end else if (win_cnt >= 32'(WIN_CYC - 1)) begin
				pix_sticky <= d_pix_w; ce_sticky <= d_ce_w; de_sticky <= d_de_w;
				frm_sticky <= f_now_w; fps_x10_sticky <= fx10_w;
				flags_sticky <= {1'b0, de_ok_w, ce_ok_w, trap_w, PLL_ON,
				                 fps_ok_w, pix_ok_w, 1'b1};
				done_sticky <= 1'b1;
				pix_mark <= pix_now; ce_mark <= ce_now; de_mark <= de_now;
				win_cnt <= 0; frm_acc <= 0;
			end else
				win_cnt <= win_cnt + 32'd1;
		end
	end

	assign meas_pix_count   = pix_sticky;
	assign meas_ce_count    = ce_sticky;
	assign meas_de_count    = de_sticky;
	assign meas_frame_count = frm_sticky;
	assign meas_fps_x10     = fps_x10_sticky;
	assign meas_flags       = flags_sticky;
	assign meas_window_done = done_sticky;
endmodule
