// Two-master f2sdram arbiter for the single HPS DDR port.
//
// Master 0 is the video frame store — both master and arbiter share clk
// (the DDR bridge clock, general[2].gpll, 90 MHz).
//
// Master 1 is the compressed-bitstream ring reader on the system clock
// (general[0].gpll, 20 MHz).  Because both PLL outputs are synchronous
// (same PLL, 0 ps phase shift), Quartus times the crossing correctly.
// m1_want gets a 2-FF synchroniser for robustness; data/address signals
// are protocol-guarded (stable while m1_busy is deasserted).
//
// ⚠ This module previously ran on clk_sys (20 MHz) which placed its
// registered state (rsp_left, grant_m1) between the 90 MHz DDR bridge
// and the 90 MHz frame store, creating a 5.555 ns setup path that
// failed STA by −1.346 ns.  Moving to clk_ddr eliminates that crossing.

module ddr_bus_arbiter (
	input  wire        clk,
	input  wire        reset,

	input  wire        m1_want,

	output wire        m0_busy,
	input  wire  [7:0] m0_burstcnt,
	input  wire [28:0] m0_addr,
	output wire [63:0] m0_dout,
	output wire        m0_dout_ready,
	input  wire        m0_rd,
	input  wire [63:0] m0_din,
	input  wire  [7:0] m0_be,
	input  wire        m0_we,

	output wire        m1_busy,
	input  wire  [7:0] m1_burstcnt,
	input  wire [28:0] m1_addr,
	output wire [63:0] m1_dout,
	output wire        m1_dout_ready,
	input  wire        m1_rd,
	input  wire [63:0] m1_din,
	input  wire  [7:0] m1_be,
	input  wire        m1_we,

	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE
);
	// Reset synchroniser (reset originates in clk_sys, we run on clk_ddr)
	reg reset_s1, reset_s2;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			reset_s1 <= 1'b1;
			reset_s2 <= 1'b1;
		end else begin
			reset_s1 <= 1'b0;
			reset_s2 <= reset_s1;
		end
	end
	wire rst = reset_s2;

	// 2-FF synchroniser for m1_want (clk_sys → clk_ddr)
	reg m1_want_s1, m1_want_s2;
	always @(posedge clk) begin
		if (rst) begin
			m1_want_s1 <= 1'b0;
			m1_want_s2 <= 1'b0;
		end else begin
			m1_want_s1 <= m1_want;
			m1_want_s2 <= m1_want_s1;
		end
	end

	reg grant_m1;
	reg rsp_owner_m1;
	reg [8:0] rsp_left;

	wire rsp_active = rsp_left != 9'd0;
	wire m0_cmd = m0_rd | m0_we;
	wire m1_cmd = m1_rd | m1_we;
	wire use_m1 = grant_m1;
	wire [7:0] selected_burst = use_m1 ? m1_burstcnt : m0_burstcnt;

	assign m0_busy = DDRAM_BUSY | grant_m1 | (rsp_active & rsp_owner_m1);
	assign m1_busy = DDRAM_BUSY | !grant_m1 | (rsp_active & !rsp_owner_m1);

	assign DDRAM_BURSTCNT = use_m1 ? m1_burstcnt : m0_burstcnt;
	assign DDRAM_ADDR     = use_m1 ? m1_addr      : m0_addr;
	assign DDRAM_RD       = use_m1 ? m1_rd        : m0_rd;
	assign DDRAM_DIN      = use_m1 ? m1_din       : m0_din;
	assign DDRAM_BE       = use_m1 ? m1_be        : m0_be;
	assign DDRAM_WE       = use_m1 ? m1_we        : m0_we;

	assign m0_dout = DDRAM_DOUT;
	assign m1_dout = DDRAM_DOUT;
	assign m0_dout_ready = DDRAM_DOUT_READY & rsp_active & !rsp_owner_m1;
	assign m1_dout_ready = DDRAM_DOUT_READY & rsp_active & rsp_owner_m1;

	always @(posedge clk) begin
		if (rst) begin
			grant_m1 <= 1'b0;
			rsp_owner_m1 <= 1'b0;
			rsp_left <= 9'd0;
		end else begin
			if (DDRAM_DOUT_READY && rsp_active)
				rsp_left <= rsp_left - 9'd1;

			if (!DDRAM_BUSY && !rsp_active) begin
				if (grant_m1) begin
					if (m1_rd) begin
						rsp_owner_m1 <= 1'b1;
						rsp_left <= {1'b0, selected_burst};
						grant_m1 <= 1'b0;
					end else if (m1_we || !m1_want_s2) begin
						grant_m1 <= 1'b0;
					end
				end else begin
					if (m0_rd) begin
						rsp_owner_m1 <= 1'b0;
						rsp_left <= {1'b0, selected_burst};
					end else if (!m0_cmd && m1_want_s2) begin
						grant_m1 <= 1'b1;
					end
				end
			end

			if (grant_m1 && !DDRAM_BUSY && m1_cmd && !m1_rd)
				grant_m1 <= 1'b0;
		end
	end
endmodule
