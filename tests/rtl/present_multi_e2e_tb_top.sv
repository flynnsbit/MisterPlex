// present_multi_e2e_tb_top — MULTI path gradient + sync under target macros.
// Models present_core MULTI store-valid gate (fs_rd_n_valid) + beam + npx_path.
// NOT full present_core (that pulls HPS/audio); contracts the push path rd-duck NACK'd.
//
// Target recipe (product MULTI default-off; this TB forces it):
//   PRESENT_PX_PER_CLK=2, FRAME 1280x720 glass, COMPACT H=1650 V=750 beam
//   MP_STORE_LAT=4 beam delay; RGB gated by store_nv (fs_rd_n_valid analogue)
`timescale 1ns/1ps

module present_multi_e2e_tb_top (
	input  wire clk,
	input  wire reset,
	// Force store miss after warm-up (C++ drives)
	input  wire force_store_miss,
	output wire out_ce,
	output wire [7:0] out_r,
	output wire [7:0] out_g,
	output wire [7:0] out_b,
	output wire out_hblank,
	output wire out_hsync,
	output wire out_vblank,
	output wire out_vsync,
	output wire out_fstart,
	output wire store_nv_live,
	output wire [7:0] dbg_push_r0
);
	localparam int PPC = 2;
	localparam int MP_STORE_LAT = 4;
	// Compact H totals (product 1650); short V so VSync is reachable in TB cycles.
	// Product glass is 720/750 — geometry contract is H path + valid gate, not full 750.
	localparam int H_DE = 1280;
	localparam int H_TOTAL = 1650;
	localparam int V_ACTIVE = 8;
	localparam int V_TOTAL = 16;

	wire in_ready;
	wire beam_ce;
	wire [11:0] glass_x0, glass_y;
	wire [PPC-1:0] lane_de;
	wire hb, hs, vb, vs, fstart;

	// Always-ready consumer (npx path backpressure open)
	// present_beam_ppc enable follows in_ready like present_core.
	present_beam_ppc #(
		.PX_PER_CLK(PPC),
		.H_DE(H_DE),
		.H_TOTAL(H_TOTAL),
		.V_ACTIVE(V_ACTIVE),
		.V_TOTAL(V_TOTAL),
		.H_SYNC_S(1390),
		.H_SYNC_E(1430),
		.V_SYNC_S(10),
		.V_SYNC_E(12)
	) u_beam (
		.clk(clk),
		.reset(reset),
		.enable(~reset & in_ready),
		.beam_ce(beam_ce),
		.glass_x0(glass_x0),
		.glass_y(glass_y),
		.lane_de(lane_de),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.frame_start(fstart)
	);

	// Registered store address (1-cycle like present_core mp_store_*)
	reg [11:0] store_x, store_y;
	reg        store_de;
	always @(posedge clk) begin
		if (reset) begin
			store_x  <= 12'd0;
			store_y  <= 12'd0;
			store_de <= 1'b0;
		end else if (beam_ce) begin
			store_x  <= glass_x0;
			store_y  <= glass_y;
			store_de <= |lane_de;
		end
	end

	// Mock ddr_frame_store dual-lane: gradient RGB, valid after 3 cycles of active.
	// Lane0 x=store_x, lane1 x=store_x+1. R=x[7:0], G=y[7:0], B=x[11:4]^y[7:0]
	reg [2:0] pipe_v;
	reg [11:0] pipe_x[0:2];
	reg [11:0] pipe_y[0:2];
	reg [PPC-1:0] pipe_lv[0:2];
	integer pi;
	always @(posedge clk) begin
		if (reset) begin
			pipe_v <= 3'b0;
			for (pi = 0; pi < 3; pi = pi + 1) begin
				pipe_x[pi] <= 12'd0;
				pipe_y[pi] <= 12'd0;
				pipe_lv[pi] <= '0;
			end
		end else begin
			pipe_v <= {pipe_v[1:0], store_de};
			pipe_x[0] <= store_x;
			pipe_y[0] <= store_y;
			pipe_lv[0] <= store_de ? {PPC{1'b1}} : '0;
			for (pi = 1; pi < 3; pi = pi + 1) begin
				pipe_x[pi] <= pipe_x[pi-1];
				pipe_y[pi] <= pipe_y[pi-1];
				pipe_lv[pi] <= pipe_lv[pi-1];
			end
		end
	end

	wire        mock_nv = pipe_v[2] & ~force_store_miss;
	wire [11:0] mx = pipe_x[2];
	wire [11:0] my = pipe_y[2];
	wire [PPC-1:0] mock_lv = force_store_miss ? '0 : pipe_lv[2];
	// Packed RGB PPC=2
	wire [7:0] r0 = mx[7:0];
	wire [7:0] r1 = mx[7:0] + 8'd1;
	wire [7:0] g0 = my[7:0];
	wire [7:0] g1 = my[7:0];
	wire [7:0] b0 = mx[11:4] ^ my[7:0];
	wire [7:0] b1 = (mx[11:4] + 4'd1) ^ my[7:0];
	wire [PPC*8-1:0] mock_r = {r1, r0};
	wire [PPC*8-1:0] mock_g = {g1, g0};
	wire [PPC*8-1:0] mock_b = {b1, b0};

	assign store_nv_live = mock_nv;

	// Beam delay queue (mirror present_core MULTI)
	reg [MP_STORE_LAT-1:0] tq_v;
	reg tq_hb[0:MP_STORE_LAT-1];
	reg tq_hs[0:MP_STORE_LAT-1];
	reg tq_vb[0:MP_STORE_LAT-1];
	reg tq_vs[0:MP_STORE_LAT-1];
	reg tq_fs[0:MP_STORE_LAT-1];
	reg [PPC-1:0] tq_lde[0:MP_STORE_LAT-1];
	integer ti;
	always @(posedge clk) begin
		if (reset) begin
			tq_v <= '0;
			for (ti = 0; ti < MP_STORE_LAT; ti = ti + 1) begin
				tq_hb[ti] <= 1'b1;
				tq_hs[ti] <= 1'b0;
				tq_vb[ti] <= 1'b1;
				tq_vs[ti] <= 1'b0;
				tq_fs[ti] <= 1'b0;
				tq_lde[ti] <= '0;
			end
		end else begin
			for (ti = MP_STORE_LAT-1; ti > 0; ti = ti - 1) begin
				tq_v[ti]   <= tq_v[ti-1];
				tq_hb[ti]  <= tq_hb[ti-1];
				tq_hs[ti]  <= tq_hs[ti-1];
				tq_vb[ti]  <= tq_vb[ti-1];
				tq_vs[ti]  <= tq_vs[ti-1];
				tq_fs[ti]  <= tq_fs[ti-1];
				tq_lde[ti] <= tq_lde[ti-1];
			end
			tq_v[0]   <= beam_ce;
			tq_hb[0]  <= beam_ce ? hb : 1'b1;
			tq_hs[0]  <= beam_ce ? hs : 1'b0;
			tq_vb[0]  <= beam_ce ? vb : 1'b1;
			tq_vs[0]  <= beam_ce ? vs : 1'b0;
			tq_fs[0]  <= beam_ce ? fstart : 1'b0;
			tq_lde[0] <= beam_ce ? lane_de : '0;
		end
	end

	wire push = tq_v[MP_STORE_LAT-1];
	// Quality gate — THE contract under test (must use store valid)
	wire rgb_ok = mock_nv; // has_frame=1 always in this TB
	wire [PPC*8-1:0] npx_r = rgb_ok ? mock_r : {PPC*8{1'b0}};
	wire [PPC*8-1:0] npx_g = rgb_ok ? mock_g : {PPC*8{1'b0}};
	wire [PPC*8-1:0] npx_b = rgb_ok ? mock_b : {PPC*8{1'b0}};
	wire [PPC-1:0]   npx_lv = tq_lde[MP_STORE_LAT-1] & (rgb_ok ? mock_lv : {PPC{1'b0}});

	assign dbg_push_r0 = npx_r[7:0];

	// Same clock for sys and pix (no PLL in TB); PREFILL=0 for fast start
	present_npx_path #(
		.PX_PER_CLK(PPC),
		.FIFO_AW(5),
		.INCLUDE_SYNC(1'b1),
		.PREFILL_GROUPS(0),
		.SKID_AW(3)
	) u_npx (
		.clk_sys(clk),
		.reset_sys(reset),
		.clk_pix(clk),
		.reset_pix(reset),
		.in_valid(push),
		.in_r(npx_r),
		.in_g(npx_g),
		.in_b(npx_b),
		.in_lane_valid(npx_lv),
		.in_hblank(tq_hb[MP_STORE_LAT-1]),
		.in_hsync(tq_hs[MP_STORE_LAT-1]),
		.in_vblank(tq_vb[MP_STORE_LAT-1]),
		.in_vsync(tq_vs[MP_STORE_LAT-1]),
		.in_fstart(tq_fs[MP_STORE_LAT-1]),
		.in_ready(in_ready),
		.out_ce(out_ce),
		.out_r(out_r),
		.out_g(out_g),
		.out_b(out_b),
		.out_hblank(out_hblank),
		.out_hsync(out_hsync),
		.out_vblank(out_vblank),
		.out_vsync(out_vsync),
		.out_fstart(out_fstart),
		.wr_full(),
		.wr_almost_full(),
		.rd_underrun(),
		.rd_empty()
	);
endmodule
