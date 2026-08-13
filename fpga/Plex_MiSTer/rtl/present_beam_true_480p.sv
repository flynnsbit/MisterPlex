// Fixed first-recovery beam for the native 640x480 product path.
// clk_sys/2 = 10 MHz, 672x496 total -> 30.0019 Hz.
// Runtime cadence/geometry is intentionally excluded.

`default_nettype none

module present_beam_true_480p (
	input  wire        clk,
	input  wire        reset,
	output reg         ce_pix,
	output reg         HBlank,
	output reg         HSync,
	output reg         VBlank,
	output reg         VSync,
	output reg         frame_start,
	output reg  [10:0] hc_out,
	output reg  [10:0] vc_out
);
	localparam [10:0] H_DE     = 11'd640;
	localparam [10:0] V_ACTIVE = 11'd480;
	localparam [10:0] H_TOTAL  = 11'd672;
	localparam [10:0] V_TOTAL  = 11'd496;
	localparam [10:0] H_SYNC_S = 11'd648;
	localparam [10:0] H_SYNC_E = 11'd656;
	localparam [10:0] V_SYNC_S = 11'd484;
	localparam [10:0] V_SYNC_E = 11'd486;

	wire h_wrap = (hc_out == (H_TOTAL - 11'd1));
	wire v_wrap = h_wrap && (vc_out == (V_TOTAL - 11'd1));
	wire [10:0] hc_n = h_wrap ? 11'd0 : (hc_out + 11'd1);
	wire [10:0] vc_n = h_wrap ? (v_wrap ? 11'd0 : (vc_out + 11'd1)) : vc_out;

	always @(posedge clk) begin
		ce_pix <= ~ce_pix;
		frame_start <= 1'b0;
		if (reset) begin
			hc_out <= 11'd0;
			vc_out <= 11'd0;
			ce_pix <= 1'b0;
			HBlank <= 1'b0;
			HSync <= 1'b0;
			VBlank <= 1'b0;
			VSync <= 1'b0;
		end else if (ce_pix) begin
			hc_out <= hc_n;
			vc_out <= vc_n;
			HBlank <= (hc_n >= H_DE);
			HSync <= (hc_n >= H_SYNC_S) && (hc_n < H_SYNC_E);
			VBlank <= (vc_n >= V_ACTIVE);
			VSync <= (vc_n >= V_SYNC_S) && (vc_n < V_SYNC_E);
			frame_start <= v_wrap;
		end
	end
endmodule

`default_nettype wire
