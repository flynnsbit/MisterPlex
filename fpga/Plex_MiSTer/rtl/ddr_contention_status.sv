// ddr_contention_status — observe f2sdram multi-master contention (w-plxd).
//
// Observation only. Does NOT change arbitration policy (w-mem owns that).
// Attach at ddr_bus_arbiter / ddr_bus_arbiter3 master sidebands:
//   present reader = m0, fabric publish/copy = m2 (bitstream may share m1).
//
// Counters are OBSERVED events on clk (clk_ddr), not compile-time constants.
// Wide increments are pipelined one cycle off the event detect (STA slack).
//
// Causality for "did present starve because of fabric copy?":
//   m0_stall_while_m2 increments when present asserts a cmd, is backpressured
//   (busy), AND publish also asserts a cmd in the same cycle — both consumers
//   want the port and present is waiting.
//   m0_stall_ddr vs m0_stall_arb split bridge busy from arbiter grant hold.
//
// Host ABI: host/libmisterplex/ddr_contention_abi.hpp (PLXC layout).
// Magic constant 0x504C5843 "PLXC" is stamped on the snapshot word0.

`default_nettype none

module ddr_contention_status (
	input  wire        clk,
	input  wire        reset,
	// Pulse to zero all counters (window restart). Level clear held is OK.
	input  wire        clear,

	// --- present reader (arbiter m0) ---
	input  wire        m0_busy,
	input  wire        m0_rd,
	input  wire        m0_we,
	input  wire        m0_dout_ready,

	// --- fabric publish / frame copy (arbiter m2) ---
	input  wire        m2_busy,
	input  wire        m2_rd,
	input  wire        m2_we,
	input  wire        m2_dout_ready,

	// Physical bridge busy (shared). Distinguishes arb hold vs DDR backpressure.
	input  wire        ddram_busy,

	// --- observed counters (noprune live regs) ---
	output wire [31:0] window_cycles,
	output wire [31:0] m0_req_cycles,
	output wire [31:0] m0_cmd_accepts,
	output wire [31:0] m0_rd_beats,
	output wire [31:0] m0_stall_cycles,
	output wire [31:0] m0_stall_ddr,
	output wire [31:0] m0_stall_arb,
	output wire [31:0] m0_stall_while_m2,
	output wire [31:0] m2_req_cycles,
	output wire [31:0] m2_cmd_accepts,
	output wire [31:0] m2_rd_beats,
	output wire [31:0] m2_wr_accepts,
	output wire [31:0] m2_stall_cycles,
	output wire [31:0] m2_stall_while_m0,
	// Packed snapshot for mailbox / keep-chain (word0 = magic|flags)
	output wire [63:0] snap_w0,
	output wire [63:0] snap_w1,
	output wire [63:0] snap_w2,
	output wire [63:0] snap_w3
);
	localparam [31:0] MAGIC_PLXC = 32'h504C_5843; // "PLXC"

	wire m0_cmd = m0_rd | m0_we;
	wire m2_cmd = m2_rd | m2_we;

	// Combinational event detect (registered next cycle before add).
	wire e_m0_req     = m0_cmd;
	wire e_m0_accept  = m0_cmd & ~m0_busy;
	wire e_m0_rdbeat  = m0_dout_ready;
	wire e_m0_stall   = m0_cmd & m0_busy;
	wire e_m0_st_ddr  = m0_cmd & m0_busy & ddram_busy;
	wire e_m0_st_arb  = m0_cmd & m0_busy & ~ddram_busy;
	wire e_m0_st_m2   = m0_cmd & m0_busy & m2_cmd;

	wire e_m2_req     = m2_cmd;
	wire e_m2_accept  = m2_cmd & ~m2_busy;
	wire e_m2_rdbeat  = m2_dout_ready;
	wire e_m2_wracc   = m2_we & ~m2_busy;
	wire e_m2_stall   = m2_cmd & m2_busy;
	wire e_m2_st_m0   = m2_cmd & m2_busy & m0_cmd;

	// Pipeline stage: freeze events away from wide adders.
	reg p_m0_req, p_m0_accept, p_m0_rdbeat, p_m0_stall, p_m0_st_ddr, p_m0_st_arb, p_m0_st_m2;
	reg p_m2_req, p_m2_accept, p_m2_rdbeat, p_m2_wracc, p_m2_stall, p_m2_st_m0;
	reg p_window;

	always @(posedge clk) begin
		if (reset || clear) begin
			p_m0_req    <= 1'b0;
			p_m0_accept <= 1'b0;
			p_m0_rdbeat <= 1'b0;
			p_m0_stall  <= 1'b0;
			p_m0_st_ddr <= 1'b0;
			p_m0_st_arb <= 1'b0;
			p_m0_st_m2  <= 1'b0;
			p_m2_req    <= 1'b0;
			p_m2_accept <= 1'b0;
			p_m2_rdbeat <= 1'b0;
			p_m2_wracc  <= 1'b0;
			p_m2_stall  <= 1'b0;
			p_m2_st_m0  <= 1'b0;
			p_window    <= 1'b0;
		end else begin
			p_m0_req    <= e_m0_req;
			p_m0_accept <= e_m0_accept;
			p_m0_rdbeat <= e_m0_rdbeat;
			p_m0_stall  <= e_m0_stall;
			p_m0_st_ddr <= e_m0_st_ddr;
			p_m0_st_arb <= e_m0_st_arb;
			p_m0_st_m2  <= e_m0_st_m2;
			p_m2_req    <= e_m2_req;
			p_m2_accept <= e_m2_accept;
			p_m2_rdbeat <= e_m2_rdbeat;
			p_m2_wracc  <= e_m2_wracc;
			p_m2_stall  <= e_m2_stall;
			p_m2_st_m0  <= e_m2_st_m0;
			p_window    <= 1'b1;
		end
	end

	// Saturating 32-bit counters (observed). noprune keeps them through fit.
	(* noprune *) reg [31:0] r_window       = 32'd0;
	(* noprune *) reg [31:0] r_m0_req       = 32'd0;
	(* noprune *) reg [31:0] r_m0_accept    = 32'd0;
	(* noprune *) reg [31:0] r_m0_rdbeat    = 32'd0;
	(* noprune *) reg [31:0] r_m0_stall     = 32'd0;
	(* noprune *) reg [31:0] r_m0_st_ddr    = 32'd0;
	(* noprune *) reg [31:0] r_m0_st_arb    = 32'd0;
	(* noprune *) reg [31:0] r_m0_st_m2     = 32'd0;
	(* noprune *) reg [31:0] r_m2_req       = 32'd0;
	(* noprune *) reg [31:0] r_m2_accept    = 32'd0;
	(* noprune *) reg [31:0] r_m2_rdbeat    = 32'd0;
	(* noprune *) reg [31:0] r_m2_wracc     = 32'd0;
	(* noprune *) reg [31:0] r_m2_stall     = 32'd0;
	(* noprune *) reg [31:0] r_m2_st_m0     = 32'd0;

	function automatic [31:0] sat_inc;
		input [31:0] v;
		input        en;
		begin
			if (!en)
				sat_inc = v;
			else if (v == 32'hFFFF_FFFF)
				sat_inc = v;
			else
				sat_inc = v + 32'd1;
		end
	endfunction

	always @(posedge clk) begin
		if (reset || clear) begin
			r_window    <= 32'd0;
			r_m0_req    <= 32'd0;
			r_m0_accept <= 32'd0;
			r_m0_rdbeat <= 32'd0;
			r_m0_stall  <= 32'd0;
			r_m0_st_ddr <= 32'd0;
			r_m0_st_arb <= 32'd0;
			r_m0_st_m2  <= 32'd0;
			r_m2_req    <= 32'd0;
			r_m2_accept <= 32'd0;
			r_m2_rdbeat <= 32'd0;
			r_m2_wracc  <= 32'd0;
			r_m2_stall  <= 32'd0;
			r_m2_st_m0  <= 32'd0;
		end else begin
			r_window    <= sat_inc(r_window,    p_window);
			r_m0_req    <= sat_inc(r_m0_req,    p_m0_req);
			r_m0_accept <= sat_inc(r_m0_accept, p_m0_accept);
			r_m0_rdbeat <= sat_inc(r_m0_rdbeat, p_m0_rdbeat);
			r_m0_stall  <= sat_inc(r_m0_stall,  p_m0_stall);
			r_m0_st_ddr <= sat_inc(r_m0_st_ddr, p_m0_st_ddr);
			r_m0_st_arb <= sat_inc(r_m0_st_arb, p_m0_st_arb);
			r_m0_st_m2  <= sat_inc(r_m0_st_m2,  p_m0_st_m2);
			r_m2_req    <= sat_inc(r_m2_req,    p_m2_req);
			r_m2_accept <= sat_inc(r_m2_accept, p_m2_accept);
			r_m2_rdbeat <= sat_inc(r_m2_rdbeat, p_m2_rdbeat);
			r_m2_wracc  <= sat_inc(r_m2_wracc,  p_m2_wracc);
			r_m2_stall  <= sat_inc(r_m2_stall,  p_m2_stall);
			r_m2_st_m0  <= sat_inc(r_m2_st_m0,  p_m2_st_m0);
		end
	end

	assign window_cycles      = r_window;
	assign m0_req_cycles      = r_m0_req;
	assign m0_cmd_accepts     = r_m0_accept;
	assign m0_rd_beats        = r_m0_rdbeat;
	assign m0_stall_cycles    = r_m0_stall;
	assign m0_stall_ddr       = r_m0_st_ddr;
	assign m0_stall_arb       = r_m0_st_arb;
	assign m0_stall_while_m2  = r_m0_st_m2;
	assign m2_req_cycles      = r_m2_req;
	assign m2_cmd_accepts     = r_m2_accept;
	assign m2_rd_beats        = r_m2_rdbeat;
	assign m2_wr_accepts      = r_m2_wracc;
	assign m2_stall_cycles    = r_m2_stall;
	assign m2_stall_while_m0  = r_m2_st_m0;

	// Snapshot packing (little-endian host view of each 64b word):
	//   w0: [31:0]=MAGIC_PLXC  [63:32]=window[31:0]
	//   w1: [31:0]=m0_stall    [63:32]=m0_stall_while_m2
	//   w2: [31:0]=m0_accept   [63:32]=m0_rd_beats
	//   w3: [31:0]=m2_accept   [63:32]=m2_stall_while_m0
	// Full counter set remains on dedicated ports; snap is the compact host view.
	assign snap_w0 = {r_window, MAGIC_PLXC};
	assign snap_w1 = {r_m0_st_m2, r_m0_stall};
	assign snap_w2 = {r_m0_rdbeat, r_m0_accept};
	assign snap_w3 = {r_m2_st_m0, r_m2_accept};

endmodule

`default_nettype wire
