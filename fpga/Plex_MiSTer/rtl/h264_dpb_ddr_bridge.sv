// Clock-domain bridge for the DDR-resident DPB.
//
// The decoder runs on clk_sys (general[0].gpll, 20 MHz); the HPS f2sdram
// bridge runs on clk_ddr (general[2].gpll, 90 MHz).  h264_dpb_ddr and its
// reference-window cache are deliberately kept on clk_sys so that a cache HIT
// -- which is the overwhelming majority of reference reads once a tap row is
// resident -- costs zero crossing latency and answers at full decoder rate.
// Only a cache MISS, and the posted write commands, pay a crossing.
//
// The slave side of this bridge is shaped exactly like a MiSTer sys/ddram.sv
// port, so h264_dpb_ddr connects to it with no changes at all and can be
// simulated against a plain single-clock DDR model by simply not instantiating
// the bridge.
//
// Crossing scheme (the same shape ddr_bus_arbiter already uses for its m1
// channel): a toggle handshake carries the command, the command payload is
// protocol-guarded because s_busy is held high for the whole transaction so
// the fields cannot move, and read beats come back through an async_fifo so a
// 90 MHz single-cycle DDRAM_DOUT_READY pulse is never missed by the 20 MHz
// consumer.
//
// Burst reads are supported up to MAX_BURST beats; the FIFO is sized to hold a
// whole burst so the DDR side never has to stall mid-burst.

module h264_dpb_ddr_bridge #(
	parameter int MAX_BURST = 8,
	parameter int FIFO_AW   = 4
) (
	// ---------------- slave side (decoder clock)
	input  wire        clk_sys,
	input  wire        reset,

	output reg         s_busy,
	input  wire  [7:0] s_burstcnt,
	input  wire [28:0] s_addr,
	output reg  [63:0] s_dout,
	output reg         s_dout_ready,
	input  wire        s_rd,
	input  wire [63:0] s_din,
	input  wire  [7:0] s_be,
	input  wire        s_we,

	// ---------------- master side (DDR bridge clock)
	input  wire        clk_ddr,
	input  wire        DDRAM_BUSY,
	output reg   [7:0] DDRAM_BURSTCNT,
	output reg  [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output reg         DDRAM_RD,
	output reg  [63:0] DDRAM_DIN,
	output reg   [7:0] DDRAM_BE,
	output reg         DDRAM_WE
);
	// ------------------------------------------------- clk_sys command latch
	reg  [7:0] cmd_burst;
	reg [28:0] cmd_addr;
	reg [63:0] cmd_din;
	reg  [7:0] cmd_be;
	reg        cmd_rnw;
	reg        cmd_tgl;
	reg  [8:0] beats_left;

	reg        done_tgl_s1, done_tgl_s2, done_tgl_s3;
	wire       done_pulse = done_tgl_s2 ^ done_tgl_s3;
	reg        done_seen;

	wire        fifo_empty;
	wire [63:0] fifo_data;
	wire        fifo_pop = !fifo_empty;

	always @(posedge clk_sys) begin
		if (reset) begin
			s_busy       <= 1'b0;
			s_dout       <= 64'd0;
			s_dout_ready <= 1'b0;
			cmd_burst    <= 8'd1;
			cmd_addr     <= 29'd0;
			cmd_din      <= 64'd0;
			cmd_be       <= 8'hFF;
			cmd_rnw      <= 1'b0;
			cmd_tgl      <= 1'b0;
			beats_left   <= 9'd0;
			done_tgl_s1  <= 1'b0;
			done_tgl_s2  <= 1'b0;
			done_tgl_s3  <= 1'b0;
			done_seen    <= 1'b0;
		end else begin
			s_dout_ready <= 1'b0;

			done_tgl_s1 <= done_tgl;
			done_tgl_s3 <= done_tgl_s2;
			done_tgl_s2 <= done_tgl_s1;

			if (done_pulse) done_seen <= 1'b1;

			if (fifo_pop) begin
				s_dout       <= fifo_data;
				s_dout_ready <= 1'b1;
				if (beats_left != 9'd0) beats_left <= beats_left - 9'd1;
			end

			if (!s_busy) begin
				if (s_rd || s_we) begin
					cmd_burst  <= s_rd ? s_burstcnt : 8'd1;
					cmd_addr   <= s_addr;
					cmd_din    <= s_din;
					cmd_be     <= s_be;
					cmd_rnw    <= s_rd;
					beats_left <= s_rd ? {1'b0, s_burstcnt} : 9'd0;
					cmd_tgl    <= ~cmd_tgl;
					s_busy     <= 1'b1;
					done_seen  <= 1'b0;
				end
			end else begin
				// The transaction retires when the DDR side has finished AND
				// every read beat has been handed to the consumer.
				if (done_seen && (beats_left == 9'd0) && !fifo_pop) begin
					s_busy    <= 1'b0;
					done_seen <= 1'b0;
				end
			end
		end
	end

	// ------------------------------------------------------ clk_ddr command
	reg rst_d1, rst_d2;
	always @(posedge clk_ddr) begin
		rst_d1 <= reset;
		rst_d2 <= rst_d1;
	end
	wire rst_ddr = rst_d2;

	reg cmd_tgl_d1, cmd_tgl_d2, cmd_tgl_d3;
	wire cmd_pulse = cmd_tgl_d2 ^ cmd_tgl_d3;

	localparam [1:0] D_IDLE = 2'd0;
	localparam [1:0] D_ISSUE = 2'd1;
	localparam [1:0] D_COLLECT = 2'd2;

	reg [1:0] dstate;
	reg [8:0] rx_left;
	reg       done_tgl;

	reg        fifo_wr;
	reg [63:0] fifo_wdata;

	always @(posedge clk_ddr) begin
		if (rst_ddr) begin
			cmd_tgl_d1     <= 1'b0;
			cmd_tgl_d2     <= 1'b0;
			cmd_tgl_d3     <= 1'b0;
			dstate         <= D_IDLE;
			rx_left        <= 9'd0;
			done_tgl       <= 1'b0;
			DDRAM_RD       <= 1'b0;
			DDRAM_WE       <= 1'b0;
			DDRAM_ADDR     <= 29'd0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_DIN      <= 64'd0;
			DDRAM_BE       <= 8'hFF;
			fifo_wr        <= 1'b0;
			fifo_wdata     <= 64'd0;
		end else begin
			cmd_tgl_d1 <= cmd_tgl;
			cmd_tgl_d2 <= cmd_tgl_d1;
			cmd_tgl_d3 <= cmd_tgl_d2;

			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;
			fifo_wr  <= 1'b0;

			case (dstate)
			D_IDLE: begin
				if (cmd_pulse) dstate <= D_ISSUE;
			end
			D_ISSUE: begin
				// Every command is gated on !DDRAM_BUSY, which is the whole of
				// the sys/ddram.sv contract.
				if (!DDRAM_BUSY) begin
					DDRAM_ADDR     <= cmd_addr;
					DDRAM_BURSTCNT <= cmd_burst;
					DDRAM_BE       <= cmd_be;
					if (cmd_rnw) begin
						DDRAM_RD <= 1'b1;
						rx_left  <= {1'b0, cmd_burst};
						dstate   <= D_COLLECT;
					end else begin
						DDRAM_DIN <= cmd_din;
						DDRAM_WE  <= 1'b1;
						done_tgl  <= ~done_tgl;
						dstate    <= D_IDLE;
					end
				end
			end
			D_COLLECT: begin
				if (DDRAM_DOUT_READY) begin
					fifo_wr    <= 1'b1;
					fifo_wdata <= DDRAM_DOUT;
					if (rx_left <= 9'd1) begin
						done_tgl <= ~done_tgl;
						rx_left  <= 9'd0;
						dstate   <= D_IDLE;
					end else begin
						rx_left <= rx_left - 9'd1;
					end
				end
			end
			default: dstate <= D_IDLE;
			endcase
		end
	end

	async_fifo #(
		.WIDTH(64),
		.AW(FIFO_AW)
	) u_rdata_fifo (
		.wr_clk(clk_ddr),
		.wr_reset(rst_ddr),
		.wr_en(fifo_wr),
		.wr_data(fifo_wdata),
		.wr_full(),
		.wr_almost_full(),
		.rd_clk(clk_sys),
		.rd_reset(reset),
		.rd_en(fifo_pop),
		.rd_data(fifo_data),
		.rd_empty(fifo_empty)
	);

	// MAX_BURST is a design contract: the response FIFO must be able to
	// swallow a whole burst without the DDR side ever stalling mid-burst, so
	// (1 << FIFO_AW) must be >= MAX_BURST.  Kept as a parameter so a larger
	// reference line size only needs the two numbers moved together.
	localparam int UNUSED_MAX_BURST = MAX_BURST;
endmodule
