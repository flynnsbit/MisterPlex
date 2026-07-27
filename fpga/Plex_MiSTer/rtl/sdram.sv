//============================================================================
// MiSTerPlex SDRAM controller.
//
// Random-access adaptation of the fixed 8-state command pipeline used by
// MiSTer-devel/MemTest_MiSTer, which passed on the project DE10-Nano at
// 142 MHz with zero failures.
//
// Reference source:
//   https://github.com/MiSTer-devel/MemTest_MiSTer/blob/86f89561b325d329ab96dfa6097d895e79ded36a/rtl/sdram.v
//   Copyright (c) MiSTer-devel / Sorgelig, GPL-2.0-or-later as distributed in
//   MemTest_MiSTer.
//
// Key reference behaviours intentionally retained here:
//   * short init: 31 iterations of an 8-state loop, not a JEDEC 100us delay
//   * fixed 8-state cadence: ACTIVE at state 1, READ/WRITE at state 4,
//     read capture/operation completion at state 7
//   * CAS command uses A10=1 auto-precharge; no separate precharge command in
//     the normal access path
//   * refresh follows MemTest's rcnt cadence (two refresh slots every 51 loops)
//============================================================================

module sdram
#(
	parameter int unsigned SDRAM_CLK_HZ = 100_000_000
)(
	input             init,
	input             clk,

	inout      [15:0] SDRAM_DQ,
	output reg [12:0] SDRAM_A,
	output            SDRAM_DQML,
	output            SDRAM_DQMH,
	output reg  [1:0] SDRAM_BA,
	output            SDRAM_nCS,
	output            SDRAM_nWE,
	output            SDRAM_nRAS,
	output            SDRAM_nCAS,
	output            SDRAM_CKE,
	output            SDRAM_CLK,
	input             SDRAM_EN,

	input             sel,
	input      [26:1] addr,
	output reg [15:0] dout,
	input      [15:0] din,
	input             wr,
	input       [1:0] bs,
	input             rd,
	output reg        ready,
	input             refresh,

	input             cpsel,
	input      [26:1] cpaddr,
	input      [15:0] cpdin,
	output reg        cprd,
	input             cpreq,
	output reg        cpbusy
);

assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1'b1;
assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];
assign SDRAM_DQ = sdram_dq_oe ? sdram_dq_out : 16'hZZZZ;

localparam [2:0] CMD_NOP             = 3'b111;
localparam [2:0] CMD_ACTIVE          = 3'b011;
localparam [2:0] CMD_READ            = 3'b101;
localparam [2:0] CMD_WRITE           = 3'b100;
localparam [2:0] CMD_PRECHARGE       = 3'b010;
localparam [2:0] CMD_AUTO_REFRESH    = 3'b001;
localparam [2:0] CMD_LOAD_MODE       = 3'b000;

localparam [2:0] BURST_CODE          = 3'b010; // burst length 4
localparam       ACCESS_TYPE         = 1'b0;
`ifdef SDRAM_CL3
localparam [2:0] CAS_LATENCY         = 3'd3;
`else
localparam [2:0] CAS_LATENCY         = 3'd2;
`endif
localparam [1:0] OP_MODE             = 2'b00;
localparam       NO_WRITE_BURST      = 1'b0;
localparam [12:0] MODE               = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};
localparam [2:0] READ_CAPTURE_STATE  = CAS_LATENCY - 3'd1;

reg [2:0]  state;
reg [4:0]  initstate;
reg        init_done;
reg        busy;
reg        op_write;
reg [12:0] cas_addr;
reg [15:0] saved_data;
reg        saved_chip;
reg [1:0]  saved_bank;
reg [12:0] saved_row;
reg [12:0] sdram_a_next;
reg [1:0]  sdram_ba_next;
reg [5:0]  rcnt;
reg        refresh_pending;
reg        refresh_chip;
reg        read_capture_pending;
reg [15:0] dq_pipe0, dq_pipe1;
reg [15:0] sdram_dq_out;
reg        sdram_dq_oe;
reg        sdram_dq_oe_next;
reg        chip;
reg [2:0]  command;
reg [2:0]  command_next;

wire request = sel & (rd | wr);

always @(posedge clk) begin
	sdram_dq_oe <= sdram_dq_oe_next;
	sdram_dq_oe_next <= 1'b0;
	command  <= command_next;
	command_next <= CMD_NOP;
	cprd     <= 1'b0;
	cpbusy   <= 1'b0;
	state    <= state + 3'd1;
	sdram_dq_out <= saved_data;
	SDRAM_A <= sdram_a_next;
	SDRAM_BA <= sdram_ba_next;

	dq_pipe0 <= SDRAM_DQ;
	dq_pipe1 <= dq_pipe0;

	if (init || !SDRAM_EN) begin
		state           <= 3'd0;
		initstate       <= 5'd0;
		init_done       <= 1'b0;
		busy            <= 1'b0;
		ready           <= 1'b0;
		chip            <= 1'b1;
		SDRAM_A         <= 13'd0;
		SDRAM_BA        <= 2'd0;
		sdram_a_next    <= 13'd0;
		sdram_ba_next   <= 2'd0;
		dout            <= 16'd0;
		rcnt            <= 6'd0;
		refresh_pending <= 1'b0;
		refresh_chip    <= 1'b0;
		read_capture_pending <= 1'b0;
		op_write        <= 1'b0;
		cas_addr        <= 13'd0;
		saved_data      <= 16'd0;
		saved_chip      <= 1'b0;
		saved_bank      <= 2'd0;
		saved_row       <= 13'd0;
		sdram_dq_oe    <= 1'b0;
		sdram_dq_oe_next <= 1'b0;
		command_next   <= CMD_NOP;
	end else if (!init_done) begin
		ready <= 1'b0;
		chip  <= initstate[4];
		busy  <= 1'b0;
		if (state == 3'd0) begin
			case (initstate[3:0])
				4'd2: begin
					sdram_a_next  <= 13'd1024;
					sdram_ba_next <= 2'b00;
					command_next<= CMD_PRECHARGE;
				end
				4'd4, 4'd7: begin
					command_next <= CMD_AUTO_REFRESH;
				end
				4'd10, 4'd13: begin
					sdram_ba_next <= 2'b00;
					sdram_a_next  <= MODE;
					command_next <= CMD_LOAD_MODE;
				end
				default: begin
				end
			endcase
		end
		if (state == 3'd5) begin
			if (~&initstate)
				initstate <= initstate + 5'd1;
			else begin
				init_done <= 1'b1;
				ready     <= 1'b1;
				chip      <= 1'b1;
				state     <= 3'd0;
			end
		end
	end else begin
		if (state == 3'd0) begin
			if (rcnt == 6'd50)
				rcnt <= 6'd0;
			else
				rcnt <= rcnt + 6'd1;
			if (!busy && (rcnt >= 6'd49)) begin
				busy            <= 1'b1;
				ready           <= 1'b0;
				refresh_pending <= 1'b1;
				refresh_chip    <= rcnt[0];
			end
		end

		if (!busy) begin
			chip <= 1'b1;
			ready <= 1'b1;
			if (request) begin
				busy      <= 1'b1;
				ready     <= 1'b0;
				op_write  <= wr;
				{cas_addr[12:9], saved_bank, saved_row, cas_addr[8:0]} <= {wr ? ~bs : 2'b00, 1'b1, addr[25:1]};
				saved_chip <= addr[26];
				if (wr)
					saved_data <= din;
				state      <= 3'd0;
			end
		end else begin
			if (read_capture_pending) begin
				if (state == READ_CAPTURE_STATE) begin
					dout <= dq_pipe1;
					read_capture_pending <= 1'b0;
					busy  <= 1'b0;
					ready <= 1'b1;
					chip  <= 1'b1;
				end
			end else begin
			case (state)
				3'd0: begin
					if (refresh_pending) begin
						chip    <= refresh_chip;
						command_next <= CMD_AUTO_REFRESH;
					end else begin
						chip     <= saved_chip;
						sdram_ba_next <= saved_bank;
						sdram_a_next  <= saved_row;
						command_next <= CMD_ACTIVE;
					end
				end
				3'd3: begin
					if (!refresh_pending) begin
						sdram_a_next <= cas_addr; // A10 is already set for auto-precharge.
						command_next <= op_write ? CMD_WRITE : CMD_READ;
						if (op_write) begin
							sdram_dq_oe_next <= 1'b1;
						end else
							read_capture_pending <= 1'b1;
					end
				end
				3'd7: begin
					if (refresh_pending || op_write) begin
						busy            <= 1'b0;
						refresh_pending <= 1'b0;
						ready           <= 1'b1;
						chip            <= 1'b1;
					end
				end
				default: begin
				end
			endcase
			end
		end
	end
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

wire _unused = &{SDRAM_CLK_HZ[0], refresh, cpsel, cpaddr, cpdin, cpreq};

endmodule
