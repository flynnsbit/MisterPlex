// ddr_m1_subarb — transaction-safe mux of two m1-style masters onto one arbiter port.
//
// Problem (rd-duck): combinational stream|plxg mux flips owner when stream_want
// rises after PLXG issues RD but before dout_ready; generic arbiter has no
// sub-owner tag → PLXG beat dropped/misdelivered to stream.
//
// Fix: latch grant for the full single-beat command+response. Stream preferred
// only when idle (no outstanding). Owner held until dout_ready after an issued
// rd/we, then released if that master no longer wants.

`timescale 1ns / 1ps
`default_nettype none

module ddr_m1_subarb (
	input  wire        clk,
	input  wire        reset,

	// Stream master
	input  wire        s_want,
	output wire        s_busy,
	input  wire  [7:0] s_burstcnt,
	input  wire [28:0] s_addr,
	output wire [63:0] s_dout,
	output wire        s_dout_ready,
	input  wire        s_rd,
	input  wire [63:0] s_din,
	input  wire  [7:0] s_be,
	input  wire        s_we,

	// PLXG poller master
	input  wire        p_want,
	output wire        p_busy,
	input  wire  [7:0] p_burstcnt,
	input  wire [28:0] p_addr,
	output wire [63:0] p_dout,
	output wire        p_dout_ready,
	input  wire        p_rd,
	input  wire [63:0] p_din,
	input  wire  [7:0] p_be,
	input  wire        p_we,

	// Combined → ddr_bus_arbiter m1
	output wire        m_want,
	input  wire        m_busy,
	output wire  [7:0] m_burstcnt,
	output wire [28:0] m_addr,
	input  wire [63:0] m_dout,
	input  wire        m_dout_ready,
	output wire        m_rd,
	output wire [63:0] m_din,
	output wire  [7:0] m_be,
	output wire        m_we,

	output reg  [1:0]  grant // 0=none 1=stream 2=plxg (debug/keep)
);

	localparam [1:0] G_NONE = 2'd0;
	localparam [1:0] G_STR  = 2'd1;
	localparam [1:0] G_PLX  = 2'd2;

	reg outstanding; // issued cmd, waiting response beat(s)

	wire g_str = (grant == G_STR);
	wire g_plx = (grant == G_PLX);

	// New grant only when idle (no grant or granted master done + no outstanding).
	wire can_pick = !outstanding && (grant == G_NONE ||
	                 (g_str && !s_want) ||
	                 (g_plx && !p_want));

	always @(posedge clk) begin
		if (reset) begin
			grant <= G_NONE;
			outstanding <= 1'b0;
		end else begin
			// Issue tracking: any accepted rd/we while not busy starts outstanding.
			if ((g_str && (s_rd | s_we) && !m_busy) ||
			    (g_plx && (p_rd | p_we) && !m_busy))
				outstanding <= 1'b1;
			if (m_dout_ready)
				outstanding <= 1'b0;

			if (can_pick) begin
				if (s_want)
					grant <= G_STR;
				else if (p_want)
					grant <= G_PLX;
				else
					grant <= G_NONE;
			end
		end
	end

	assign m_want     = g_str ? s_want     : (g_plx ? p_want     : 1'b0);
	assign m_burstcnt = g_str ? s_burstcnt : (g_plx ? p_burstcnt : 8'd1);
	assign m_addr     = g_str ? s_addr     : (g_plx ? p_addr     : 29'd0);
	assign m_rd       = g_str ? s_rd       : (g_plx ? p_rd       : 1'b0);
	assign m_din      = g_str ? s_din      : (g_plx ? p_din      : 64'd0);
	assign m_be       = g_str ? s_be       : (g_plx ? p_be       : 8'd0);
	assign m_we       = g_str ? s_we       : (g_plx ? p_we       : 1'b0);

	// Loser always busy; winner sees real busy. Non-owner never gets dout_ready.
	assign s_busy       = !g_str | m_busy;
	assign p_busy       = !g_plx | m_busy;
	assign s_dout       = m_dout;
	assign p_dout       = m_dout;
	assign s_dout_ready = g_str & m_dout_ready;
	assign p_dout_ready = g_plx & m_dout_ready;
endmodule

`default_nettype wire
