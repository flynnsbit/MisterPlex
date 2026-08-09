// fpga_ddr_writeback — Bridge h264_decode_core DPB byte-writes to DDR qword bursts.
//
// Decode core emits one sample/cycle (dpb_wr_en/addr/data) in I420 byte space
// relative to bank_base=0. This module packs them into 64-bit DDR writes at
// PHYS_BASE + bank_offset and rings the PLXK doorbell on frame_done so
// ddr_frame_store swaps the display bank.
//
// Doorbell ABI (host/libmisterplex/ddr_frame_layout.hpp):
//   lo32 = MAGIC "PLXK" (0x504C584B)
//   hi32 = {bank[0], format[1:0]=2'b01 YUV420p, seq[28:0]}
//
// Designed to share ddr_bus_arbiter m1 with stream_path via a Plex.sv mux.

`default_nettype none

module fpga_ddr_writeback #(
	parameter [31:0] PHYS_BASE = 32'h3000_0000,
	parameter int    BANK_STRIDE_BYTES = 32'h0008_0000,
	parameter [31:0] DOORBELL_PHYS = 32'h300F_F000,
	parameter [31:0] MAGIC_PLXK = 32'h504C_584B,
	parameter [1:0]  DOORBELL_FORMAT = 2'd1  // YUV420p
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        dpb_wr_en,
	input  wire [31:0] dpb_wr_addr,
	input  wire [7:0]  dpb_wr_data,
	input  wire        frame_done,

	output reg         ddr_want,
	input  wire        ddr_busy,
	output reg   [7:0] ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	output reg  [63:0] ddr_din,
	output reg   [7:0] ddr_be,
	output reg         ddr_we,
	output wire        ddr_rd,

	output reg  [15:0] frames_written,
	// 1-cycle pulse when PLXK doorbell is issued (pixels flushed + published).
	// Use this — not raw frame_done — for host_owns_fs reclaim / glass ownership.
	output reg         doorbell_pulse,
	output reg         active
);
	assign ddr_rd = 1'b0;

	reg        write_bank;
	reg [28:0] seq_counter;

	// Accumulator for one aligned qword
	reg [63:0] acc_data;
	reg  [7:0] acc_be;
	reg [28:0] acc_addr;
	reg        acc_valid;
	reg        acc_has;

	reg doorbell_pending;

	wire [28:0] bank_base_qw = write_bank
		? (PHYS_BASE[31:3] + BANK_STRIDE_BYTES[31:3])
		:  PHYS_BASE[31:3];

	wire [28:0] wr_qword_addr = bank_base_qw + dpb_wr_addr[31:3];
	wire [2:0]  wr_byte_lane  = dpb_wr_addr[2:0];
	wire [7:0]  wr_lane_be    = 8'h01 << wr_byte_lane;

	// hi doorbell word: bank | format | seq
	wire [31:0] doorbell_hi = {write_bank, DOORBELL_FORMAT, seq_counter};

	localparam [1:0] S_IDLE     = 2'd0;
	localparam [1:0] S_WRITE    = 2'd1;
	localparam [1:0] S_DOORBELL = 2'd2;
	localparam [1:0] S_WAIT     = 2'd3;

	reg [1:0] state;

	// Pending byte that arrived while flushing a different qword
	reg        pend_valid;
	reg [28:0] pend_addr;
	reg [7:0]  pend_data;
	reg [2:0]  pend_lane;

	always @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE;
			write_bank <= 1'b0;
			seq_counter <= 29'd1;
			acc_data <= 64'd0;
			acc_be <= 8'h00;
			acc_addr <= 29'd0;
			acc_valid <= 1'b0;
			acc_has <= 1'b0;
			doorbell_pending <= 1'b0;
			pend_valid <= 1'b0;
			pend_addr <= 29'd0;
			pend_data <= 8'd0;
			pend_lane <= 3'd0;
			ddr_want <= 1'b0;
			ddr_burstcnt <= 8'd1;
			ddr_addr <= 29'd0;
			ddr_din <= 64'd0;
			ddr_be <= 8'h00;
			ddr_we <= 1'b0;
			frames_written <= 16'd0;
			doorbell_pulse <= 1'b0;
			active <= 1'b0;
		end else begin
			doorbell_pulse <= 1'b0;

			if (!ddr_busy)
				ddr_we <= 1'b0;

			if (frame_done)
				doorbell_pending <= 1'b1;

			// Accept a new DPB byte into accumulator (or pend if flush in flight)
			if (dpb_wr_en) begin
				active <= 1'b1;
				if (acc_valid || (state != S_IDLE && state != S_WAIT && acc_has && wr_qword_addr != acc_addr)) begin
					// Can't merge now — hold one pending sample
					if (!pend_valid) begin
						pend_valid <= 1'b1;
						pend_addr <= wr_qword_addr;
						pend_data <= dpb_wr_data;
						pend_lane <= wr_byte_lane;
					end
				end else if (!acc_has) begin
					acc_addr <= wr_qword_addr;
					acc_data <= 64'd0;
					acc_data[wr_byte_lane*8 +: 8] <= dpb_wr_data;
					acc_be <= wr_lane_be;
					acc_has <= 1'b1;
					if (wr_lane_be == 8'hFF || (&(acc_be | wr_lane_be)))
						acc_valid <= 1'b1;
				end else if (wr_qword_addr == acc_addr) begin
					acc_data[wr_byte_lane*8 +: 8] <= dpb_wr_data;
					acc_be <= acc_be | wr_lane_be;
					if (&(acc_be | wr_lane_be))
						acc_valid <= 1'b1;
				end else begin
					// Different qword — flush current, start new via pend
					acc_valid <= 1'b1;
					pend_valid <= 1'b1;
					pend_addr <= wr_qword_addr;
					pend_data <= dpb_wr_data;
					pend_lane <= wr_byte_lane;
				end
			end

			// After a successful flush, absorb pend into fresh accumulator
			if (!acc_has && pend_valid && state == S_IDLE) begin
				acc_addr <= pend_addr;
				acc_data <= 64'd0;
				acc_data[pend_lane*8 +: 8] <= pend_data;
				acc_be <= (8'h01 << pend_lane);
				acc_has <= 1'b1;
				acc_valid <= 1'b0;
				pend_valid <= 1'b0;
			end

			case (state)
			S_IDLE: begin
				if (acc_valid || (acc_has && doorbell_pending)) begin
					// Flush full qword, or partial before doorbell
					ddr_want <= 1'b1;
					state <= S_WRITE;
				end else if (doorbell_pending && !acc_has && !pend_valid) begin
					ddr_want <= 1'b1;
					state <= S_DOORBELL;
				end else begin
					ddr_want <= 1'b0;
				end
			end

			S_WRITE: begin
				if (!ddr_busy && !ddr_we) begin
					ddr_addr <= acc_addr;
					ddr_din <= acc_data;
					ddr_be <= (acc_be == 8'h00) ? 8'hFF : acc_be;
					ddr_burstcnt <= 8'd1;
					ddr_we <= 1'b1;
					acc_valid <= 1'b0;
					acc_has <= 1'b0;
					acc_be <= 8'h00;
					acc_data <= 64'd0;
					state <= S_WAIT;
				end
			end

			S_DOORBELL: begin
				if (!ddr_busy && !ddr_we) begin
					ddr_addr <= DOORBELL_PHYS[31:3];
					ddr_din <= {doorbell_hi, MAGIC_PLXK};
					ddr_be <= 8'hFF;
					ddr_burstcnt <= 8'd1;
					ddr_we <= 1'b1;
					doorbell_pending <= 1'b0;
					write_bank <= ~write_bank;
					seq_counter <= seq_counter + 29'd1;
					frames_written <= frames_written + 16'd1;
					doorbell_pulse <= 1'b1;
					state <= S_WAIT;
				end
			end

			S_WAIT: begin
				if (!ddr_busy) begin
					ddr_want <= 1'b0;
					state <= S_IDLE;
					if (!doorbell_pending && !acc_valid && !acc_has && !pend_valid)
						active <= 1'b0;
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
