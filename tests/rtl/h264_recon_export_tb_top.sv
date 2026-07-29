// Testbench wrapper for h264_recon_export.
// FAULT_EARLY_READY: forge PLXO ready=1 on the live wr bank mid-fill (torn-frame
// adversary). Product must stay RED under that mutation.
`default_nettype none

module h264_recon_export_tb_top #(
	parameter int FRAME_W = 16,
	parameter int FRAME_H = 16,
	parameter bit FAULT_EARLY_READY = 1'b0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        sample_valid,
	input  wire [31:0] sample_off,
	input  wire [7:0]  sample_data,
	input  wire        frame_start,
	input  wire        frame_done,
	input  wire        frame_abort,
	input  wire        ddr_busy,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output wire        ddr_want,
	output wire  [7:0] ddr_burstcnt,
	output wire [28:0] ddr_addr,
	output wire        ddr_rd,
	output wire [63:0] ddr_din,
	output wire  [7:0] ddr_be,
	output wire        ddr_we,
	output wire        busy,
	output wire [15:0] frames_exported,
	output wire        last_torn,
	// Visibility for bank-alt checks (not product ports)
	output wire        dbg_wr_bank,
	output wire        dbg_pub_bank,
	output wire [1:0]  dbg_state
);
	localparam [31:0] PHYS_BASE = 32'h3020_0000;
	localparam [31:0] BANK_STRIDE = 32'h0004_0000;
	localparam [31:0] MAILBOX_PHYS = 32'h3007_F130;
	localparam [31:0] MAGIC = 32'h504C_584F;

	wire        dut_want;
	wire  [7:0] dut_burstcnt;
	wire [28:0] dut_addr;
	wire        dut_rd;
	wire [63:0] dut_din;
	wire  [7:0] dut_be;
	wire        dut_we;

	h264_recon_export #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.PHYS_BASE(PHYS_BASE),
		.BANK_STRIDE(BANK_STRIDE),
		.MAILBOX_PHYS(MAILBOX_PHYS),
		.MAGIC(MAGIC)
	) dut (
		.clk(clk),
		.reset(reset),
		.sample_valid(sample_valid),
		.sample_off(sample_off),
		.sample_data(sample_data),
		.frame_start(frame_start),
		.frame_done(frame_done),
		.frame_abort(frame_abort),
		.ddr_want(dut_want),
		.ddr_busy(ddr_busy),
		.ddr_burstcnt(dut_burstcnt),
		.ddr_addr(dut_addr),
		.ddr_dout(ddr_dout),
		.ddr_dout_ready(ddr_dout_ready),
		.ddr_rd(dut_rd),
		.ddr_din(dut_din),
		.ddr_be(dut_be),
		.ddr_we(dut_we),
		.busy(busy),
		.frames_exported(frames_exported),
		.last_torn(last_torn)
	);

	// Expose internal bank/state via hierarchical refs (Verilator OK).
	assign dbg_wr_bank  = dut.wr_bank;
	assign dbg_pub_bank = dut.pub_bank;
	assign dbg_state    = dut.state;

	// Mutation: while filling, inject a forged mailbox beat claiming ready on wr bank.
	localparam [28:0] MBOX_Q = MAILBOX_PHYS[31:3];
	reg        fault_we;
	reg [28:0] fault_addr;
	reg [63:0] fault_din;
	reg  [7:0] fault_be;
	reg        fault_want;
	reg        fault_fired;

	always @(posedge clk) begin
		if (reset) begin
			fault_we   <= 1'b0;
			fault_want <= 1'b0;
			fault_fired <= 1'b0;
			fault_addr <= 29'd0;
			fault_din  <= 64'd0;
			fault_be   <= 8'h00;
		end else begin
			fault_we   <= 1'b0;
			fault_want <= 1'b0;
			if (FAULT_EARLY_READY && !fault_fired && dut.state == 2'd1 && sample_valid) begin
				// One forged PLXO write: ready=1, torn=0, bank=wr_bank, seq=0xEEEE
				fault_fired <= 1'b1;
				fault_we    <= 1'b1;
				fault_want  <= 1'b1;
				fault_addr  <= MBOX_Q;
				fault_be    <= 8'hFF;
				fault_din   <= {
					16'hEEEE,           // seq
					12'd0,
					1'b1,               // fmt_yuv
					1'b0,               // torn
					dut.wr_bank,        // bank being written NOW
					1'b1,               // ready — the defect
					MAGIC
				};
			end
		end
	end

	assign ddr_want     = fault_we ? fault_want     : dut_want;
	assign ddr_burstcnt = fault_we ? 8'd1           : dut_burstcnt;
	assign ddr_addr     = fault_we ? fault_addr     : dut_addr;
	assign ddr_rd       = fault_we ? 1'b0           : dut_rd;
	assign ddr_din      = fault_we ? fault_din      : dut_din;
	assign ddr_be       = fault_we ? fault_be       : dut_be;
	assign ddr_we       = fault_we ? 1'b1           : dut_we;
endmodule

`default_nettype wire
