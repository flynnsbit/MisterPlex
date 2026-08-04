// Fabric clock configuration stamp (w-clock).
// Exposes compile-time Hz and raster math as noprune regs so post-fit hierarchy
// can prove which clock kit was built. No runtime flops on the critical path —
// constants only (assigned once at elab via initial/always_comb style regs).
//
// Product default: sys=20e6, pix=sys, ppc=1, cea_need_faster=1 (20 < 29.7).

`include "misterplex_clk_hz.svh"

module plex_clk_status (
	input  wire        clk,
	input  wire        reset,
	// Observability (tie to status/debug or leave open with noprune)
	output wire [31:0] clk_sys_hz,
	output wire [31:0] clk_pix_hz,
	output wire [7:0]  present_ppc,
	output wire [31:0] cea_pix_frame,
	output wire [31:0] l4_pix_frame,
	output wire        cea_24_needs_faster_pix,
	output wire        l4_24_needs_faster_sys,
	output wire [15:0] peak_mpix_s_x10, // F_sys*PPC/1e5 → e.g. 400 = 40.0 Mpix/s
	output wire        kit_id_valid
);
	localparam int SYS_HZ  = `MISTERPLEX_CLK_SYS_HZ;
	localparam int PIX_HZ  = `MISTERPLEX_CLK_PIX_HZ;
	localparam int PPC     = `MISTERPLEX_PRESENT_PPC;
	localparam int CEA_PF  = `MISTERPLEX_CEA720_PIX_FRAME;
	localparam int L4_PF   = `MISTERPLEX_L4_PIX_FRAME;
	// 29_700_000 and L4 24 fps needs
	localparam int CEA_NEED = 29_700_000;
	localparam longint L4_NEED = 24 * longint'(L4_PF); // 1312*762*24 = 23_993_856

	(* noprune *) reg [31:0] r_sys, r_pix, r_cea_pf, r_l4_pf;
	(* noprune *) reg [7:0]  r_ppc;
	(* noprune *) reg        r_cea_fast, r_l4_fast, r_valid;
	(* noprune *) reg [15:0] r_peak_x10;

	// Peak Mpix/s * 10 as integer: (SYS_HZ / 100_000) * PPC
	localparam int PEAK_X10 = (SYS_HZ / 100_000) * PPC;

	always @(posedge clk) begin
		if (reset) begin
			r_sys      <= 32'(SYS_HZ);
			r_pix      <= 32'(PIX_HZ);
			r_ppc      <= 8'(PPC);
			r_cea_pf   <= 32'(CEA_PF);
			r_l4_pf    <= 32'(L4_PF);
			r_cea_fast <= (PIX_HZ < CEA_NEED);
			r_l4_fast  <= (longint'(SYS_HZ) < L4_NEED);
			r_peak_x10 <= 16'(PEAK_X10);
			r_valid    <= 1'b1;
		end else begin
			// Hold constants (re-assert so synthesis cannot DCE if load is light)
			r_sys      <= 32'(SYS_HZ);
			r_pix      <= 32'(PIX_HZ);
			r_ppc      <= 8'(PPC);
			r_cea_pf   <= 32'(CEA_PF);
			r_l4_pf    <= 32'(L4_PF);
			r_cea_fast <= (PIX_HZ < CEA_NEED);
			r_l4_fast  <= (longint'(SYS_HZ) < L4_NEED);
			r_peak_x10 <= 16'(PEAK_X10);
			r_valid    <= 1'b1;
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
endmodule
