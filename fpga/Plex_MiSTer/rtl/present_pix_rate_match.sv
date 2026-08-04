// Bresenham throttle: average pixel emission rate = F_PIX_HZ when beam emits
// PX_PER_CLK pixels per accepted enable on F_SYS_HZ.
//
//   long-term: enables/s = F_PIX_HZ / PX_PER_CLK
//              pixels/s  = F_PIX_HZ
//
// Product (PRESENT_CLK_PIX_PLL) may set F_PIX_HZ slightly *above* nominal clk_pix
// (producer lead, ~1000 ppm) so the CDC FIFO runs against backpressure rather
// than exact equality. Overflow throttles via in_ready; underflow cannot.
// Defaults come from misterplex_clk_hz.svh (sys) and CEA 720p24 (pix).
//
// Live MULTI path may use FIFO backpressure alone; this module is also kept
// noprune in present_core for hierarchy + rate arithmetic proof.

`include "misterplex_clk_hz.svh"

module present_pix_rate_match #(
	parameter int F_SYS_HZ   = `MISTERPLEX_CLK_SYS_HZ,
	parameter int F_PIX_HZ   = `MISTERPLEX_CEA720_F24_HZ,
	parameter int PX_PER_CLK = 2
)(
	input  wire clk,
	input  wire reset,
	input  wire in_ready,     // downstream can accept a group
	output wire fire          // 1-cycle enable for beam step
);
	// acc += F_PIX_HZ each cycle; fire when acc >= F_SYS_HZ * PX_PER_CLK
	localparam int THRESH = F_SYS_HZ * PX_PER_CLK;
	// Acc width: F_PIX_HZ + THRESH fits in 32 bits for our rates.
	reg [31:0] acc;
	reg        fire_r;

	assign fire = fire_r;

	always @(posedge clk) begin
		if (reset) begin
			acc    <= 32'd0;
			fire_r <= 1'b0;
		end else begin
			fire_r <= 1'b0;
			// Saturating add not required; acc stays < THRESH + F_PIX_HZ
			if (in_ready && (acc + 32'(F_PIX_HZ) >= 32'(THRESH))) begin
				acc    <= acc + 32'(F_PIX_HZ) - 32'(THRESH);
				fire_r <= 1'b1;
			end else begin
				acc <= acc + 32'(F_PIX_HZ);
			end
		end
	end
endmodule
