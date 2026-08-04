// ddr_contended_bandwidth — multi-client f2sdram beat share model (w-mem).
//
// Models the product DDR3 path under concurrent load:
//   C0 host_wr   : ARM/HPS write of I420 into bank (33.18 MB/s @24)
//   C1 scan_rd   : fabric read of I420 for present (same bytes/frame)
//   C2 spill_rw  : optional SDRAM line spill assist (small; default OFF)
//
// One beat (8 B) per clk when any client is served. Round-robin among ready
// clients. Proves (in sim) whether combined demand finishes inside BUDGET_CYCLES.
//
// Not a full memory controller — instrumentation / TB block. Product wiring is
// optional; default OFF (files.qip only until parent enables).

`default_nettype none

module ddr_contended_bandwidth #(
	parameter int BEAT_BYTES = 8,
	parameter int HOST_WR_BYTES = 1382400,
	parameter int SCAN_RD_BYTES = 1382400,
	parameter int SPILL_BYTES = 0, // 0 = spill client idle
	parameter int BUDGET_CYCLES = 3750000 // 90e6/24
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        start,

	// Optional duty: 1 = client has traffic remaining this window
	// (TB can gate these to model idle intervals / blanking).
	input  wire        host_wr_enable,
	input  wire        scan_rd_enable,
	input  wire        spill_enable,

	output reg         busy,
	output reg         done,
	output reg         budget_fail,
	output reg  [31:0] cycles,
	output reg  [31:0] host_beats,
	output reg  [31:0] scan_beats,
	output reg  [31:0] spill_beats,
	output reg  [31:0] total_beats,
	output wire [31:0] host_target,
	output wire [31:0] scan_target,
	output wire [31:0] spill_target,
	output wire [31:0] budget_w
);

	localparam int HOST_T  = HOST_WR_BYTES / BEAT_BYTES;
	localparam int SCAN_T  = SCAN_RD_BYTES / BEAT_BYTES;
	localparam int SPILL_T = (SPILL_BYTES > 0) ? (SPILL_BYTES / BEAT_BYTES) : 0;

	assign host_target  = 32'(HOST_T);
	assign scan_target  = 32'(SCAN_T);
	assign spill_target = 32'(SPILL_T);
	assign budget_w     = 32'(BUDGET_CYCLES);

	wire host_need  = host_wr_enable && (host_beats < 32'(HOST_T));
	wire scan_need  = scan_rd_enable && (scan_beats < 32'(SCAN_T));
	wire spill_need = spill_enable && (SPILL_T != 0) && (spill_beats < 32'(SPILL_T));

	// Round-robin pointer among 3 clients (0=host, 1=scan, 2=spill).
	reg [1:0] rr;

	wire host_n  = host_need;
	wire scan_n  = scan_need;
	wire spill_n = spill_need;

	// Explicit priority from rr — avoid %/variable-index lint issues under Verilator.
	reg [1:0] pick;
	reg       fire;
	always @(*) begin
		pick = 2'd0;
		fire = 1'b0;
		case (rr)
			2'd0: begin
				if (host_n) begin pick = 2'd0; fire = 1'b1; end
				else if (scan_n) begin pick = 2'd1; fire = 1'b1; end
				else if (spill_n) begin pick = 2'd2; fire = 1'b1; end
			end
			2'd1: begin
				if (scan_n) begin pick = 2'd1; fire = 1'b1; end
				else if (spill_n) begin pick = 2'd2; fire = 1'b1; end
				else if (host_n) begin pick = 2'd0; fire = 1'b1; end
			end
			default: begin // 2 or 3 → treat as spill start
				if (spill_n) begin pick = 2'd2; fire = 1'b1; end
				else if (host_n) begin pick = 2'd0; fire = 1'b1; end
				else if (scan_n) begin pick = 2'd1; fire = 1'b1; end
			end
		endcase
	end

	// Spill target may be 0 (client off) — avoid constant unsigned compares.
	wire host_done_now =
		(host_beats + ((fire && pick == 2'd0) ? 32'd1 : 32'd0)) >= 32'(HOST_T);
	wire scan_done_now =
		(scan_beats + ((fire && pick == 2'd1) ? 32'd1 : 32'd0)) >= 32'(SCAN_T);
	wire spill_done_now = (SPILL_T == 0) ? 1'b1 :
		((spill_beats + ((fire && pick == 2'd2) ? 32'd1 : 32'd0)) >= 32'(SPILL_T));

	always @(posedge clk) begin
		if (reset) begin
			busy        <= 1'b0;
			done        <= 1'b0;
			budget_fail <= 1'b0;
			cycles      <= 32'd0;
			host_beats  <= 32'd0;
			scan_beats  <= 32'd0;
			spill_beats <= 32'd0;
			total_beats <= 32'd0;
			rr          <= 2'd0;
		end else begin
			done <= 1'b0;
			if (start) begin
				busy        <= 1'b1;
				done        <= 1'b0;
				budget_fail <= 1'b0;
				cycles      <= 32'd0;
				host_beats  <= 32'd0;
				scan_beats  <= 32'd0;
				spill_beats <= 32'd0;
				total_beats <= 32'd0;
				rr          <= 2'd0;
			end else if (busy) begin
				cycles <= cycles + 32'd1;
				if (fire) begin
					total_beats <= total_beats + 32'd1;
					if (pick == 2'd0)
						host_beats <= host_beats + 32'd1;
					else if (pick == 2'd1)
						scan_beats <= scan_beats + 32'd1;
					else
						spill_beats <= spill_beats + 32'd1;
					rr <= (pick == 2'd2) ? 2'd0 : (pick + 2'd1);
				end

				if (host_done_now && scan_done_now && spill_done_now) begin
					busy <= 1'b0;
					done <= 1'b1;
				end else if ((cycles + 32'd1) >= 32'(BUDGET_CYCLES)) begin
					busy        <= 1'b0;
					budget_fail <= 1'b1;
				end
			end
		end
	end

endmodule

`default_nettype wire
