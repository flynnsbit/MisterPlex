// Beat Conservation Assertion — simulation-only checker for CDC pulse integrity.
//
// Wraps a fast-domain pulse source and a slow-domain pulse sink, counting
// beats on both sides and asserting they match within a configurable window.
//
// USE:  Instantiate in testbench alongside any fast→slow pulse crossing.
//       After the test completes, assert beat_mismatch == 0.
//
// DOES NOT PROVE:
//   - Ordering of beats (only count, not sequence)
//   - Latency bounds (only eventual delivery)
//   - Correct data associated with each beat
//
// synthesis translate_off — this module is simulation-only.
// synopsys translate_off
// verilator lint_off UNUSED
// verilator lint_off DECLFILENAME

module beat_conservation_assert #(
	parameter string LABEL       = "unnamed",
	parameter int    SETTLE_CYCLES = 16  // extra cycles after last beat before final check
)(
	input  wire  fast_clk,
	input  wire  fast_reset,
	input  wire  fast_pulse,     // source pulse in fast domain

	input  wire  slow_clk,
	input  wire  slow_reset,
	input  wire  slow_pulse,     // observed pulse in slow domain

	output logic beat_mismatch,  // asserted when counts diverge beyond window
	output logic [31:0] fast_count,
	output logic [31:0] slow_count
);

	// Count beats in each domain independently
	always_ff @(posedge fast_clk) begin
		if (fast_reset) begin
			fast_count <= 0;
		end else if (fast_pulse) begin
			fast_count <= fast_count + 1;
		end
	end

	always_ff @(posedge slow_clk) begin
		if (slow_reset) begin
			slow_count <= 0;
		end else if (slow_pulse) begin
			slow_count <= slow_count + 1;
		end
	end

	// Settle counter: after each fast_pulse, reset a countdown.
	// Only assert mismatch after the system has settled.
	reg [7:0] settle_ctr;
	always_ff @(posedge slow_clk) begin
		if (slow_reset) begin
			settle_ctr <= 0;
		end else if (fast_pulse) begin
			// Cross-domain sample of fast_pulse is intentionally unsynchronized
			// here because this is a simulation-only checker — metastability
			// does not apply in simulation.
			settle_ctr <= SETTLE_CYCLES[7:0];
		end else if (settle_ctr > 0) begin
			settle_ctr <= settle_ctr - 1;
		end
	end

	// Mismatch detection: only valid after settlement
	always_ff @(posedge slow_clk) begin
		if (slow_reset) begin
			beat_mismatch <= 0;
		end else if (settle_ctr == 0 && fast_count != slow_count) begin
			beat_mismatch <= 1;
			// synthesis translate_off
			$display("[BEAT_CONSERVATION %s] MISMATCH: fast=%0d slow=%0d at time %0t",
				LABEL, fast_count, slow_count, $time);
			// synthesis translate_on
		end
	end

	// Final check assertion (simulation only)
	// synthesis translate_off
	final begin
		if (fast_count != slow_count) begin
			$error("[BEAT_CONSERVATION %s] FINAL MISMATCH: fast=%0d slow=%0d — DATA LOSS",
				LABEL, fast_count, slow_count);
		end else begin
			$display("[BEAT_CONSERVATION %s] OK: %0d beats matched", LABEL, fast_count);
		end
	end
	// synthesis translate_on

endmodule

// verilator lint_on UNUSED
// verilator lint_on DECLFILENAME
// synopsys translate_on
// synthesis translate_on
