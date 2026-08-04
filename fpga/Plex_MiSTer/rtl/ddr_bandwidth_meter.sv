// ddr_bandwidth_meter — prove a payload transfer fits a frame-time budget (w-mem).
//
// Models f2sdram beats: BEAT_BYTES=8 at clk_ddr (product 90 MHz, pll_0002.v).
// On start, counts beat_fire cycles until TARGET_BYTES are moved. If cycles
// exceed BUDGET_CYCLES before done, sticky budget_fail.
//
// Product numbers (compile-time helpers via parameters):
//   720p I420 = 1_382_400 B = 172_800 beats
//   clk_ddr 90e6 / 24 fps = 3_750_000 cycles/frame
//   R+W combined = 345_600 beats → fits with large peak-util margin
//
// This is a SIMULATION / instrumentation block. It does not touch the real
// DDRAM ports; TBs drive beat_fire. Keep off product critical path until
// parent wires a real probe (default OFF via no files.qip enable alone —
// module is inert unless instantiated).

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
