// ddr_bandwidth_meter — IDEAL BEAT COUNTER ONLY (w-mem).
//
// *** NOT A DDR BUS SIMULATION (rd-duck BLOCKING on ff696624). ***
// Does NOT touch DDRAM_* ports. TB drives beat_fire=1 every cycle → this only
// checks that TARGET_BEATS < BUDGET_CYCLES (arithmetic as a counter).
// Zero arbitration, backpressure, latency, or real ddr_frame_store.
//
// COMBINED_RW must NOT be read as "ARM host write on f2sdram". Host cost is
// CPU /dev/mem stores (~14.978 ms/f @ 88 MiB/s, parent HW) — see
// ddr_zero_copy_ingest.hpp. Fabric scanout bus proof lives in
// tests/rtl/ddr_frame_store_bus_stall_tb*.
//
// Kept as a cheap cycle-budget helper / instrumentation stub only.

`default_nettype none

module ddr_bandwidth_meter #(
	parameter int BEAT_BYTES = 8,
	parameter int TARGET_BYTES = 1382400, // one 720p I420 frame
	parameter int BUDGET_CYCLES = 3750000, // 90e6/24
	// When 1: require two full TARGET_BYTES moves (host write + fabric read).
	parameter bit COMBINED_RW = 1'b1
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        start,      // pulse: arm a measurement
	input  wire        beat_fire,  // 1 = one beat transferred this cycle

	output reg         busy,
	output reg         done,
	output reg         budget_fail, // sticky until reset or new start
	output reg  [31:0] cycles,
	output reg  [31:0] beats,
	output wire [31:0] target_beats,
	output wire [31:0] budget_cycles_w
);

	localparam int FRAMES = COMBINED_RW ? 2 : 1;
	localparam int TBEATS = (TARGET_BYTES / BEAT_BYTES) * FRAMES;

	assign target_beats    = 32'(TBEATS);
	assign budget_cycles_w = 32'(BUDGET_CYCLES);

	always @(posedge clk) begin
		if (reset) begin
			busy        <= 1'b0;
			done        <= 1'b0;
			budget_fail <= 1'b0;
			cycles      <= 32'd0;
			beats       <= 32'd0;
		end else begin
			done <= 1'b0;
			if (start) begin
				busy        <= 1'b1;
				done        <= 1'b0;
				budget_fail <= 1'b0;
				cycles      <= 32'd0;
				beats       <= 32'd0;
			end else if (busy) begin
				cycles <= cycles + 32'd1;
				if (beat_fire)
					beats <= beats + 32'd1;

				// Complete when enough beats observed.
				if ((beats + (beat_fire ? 32'd1 : 32'd0)) >= 32'(TBEATS)) begin
					busy <= 1'b0;
					done <= 1'b1;
				end else if ((cycles + 32'd1) >= 32'(BUDGET_CYCLES)) begin
					// Budget exhausted before target beats — LOUD fail.
					busy        <= 1'b0;
					budget_fail <= 1'b1;
				end
			end
		end
	end

endmodule

`default_nettype wire
