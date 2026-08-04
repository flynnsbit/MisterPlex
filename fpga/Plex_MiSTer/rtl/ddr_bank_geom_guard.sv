// ddr_bank_geom_guard — LOUD bank overflow reject (w-mem).
//
// Failure class (parent / w-nostub): enabling FRAME_W=1280 while
// HPS_BANK_STRIDE_BYTES stays 512 KiB silently overruns the next bank.
// Same class as MB_WIDTH_MAX under-size — must be sticky + optional elab-fatal.
//
// Usable bytes = BANK_STRIDE - DOORBELL_PAGE (control page on bank1 tail).
// Frame bytes  = Y_STRIDE*CODED_H + 2*(C_STRIDE*(CODED_H/2))
//              = Y_STRIDE*H + C_STRIDE*H   (I420 planar).
//
// FATAL_ON_STATIC_OVERFLOW=1 forces an elaboration error when static geometry
// cannot fit (preferred for product QSF that pins FRAME_W/H + stride).
// Runtime path: sticky overflow_reject when check sees payload > usable.
//
// Mirror constants: ddr_frame_layout_params.svh / ddr_frame_layout.hpp.

`default_nettype none

module ddr_bank_geom_guard #(
	parameter int CODED_W = 624,
	parameter int CODED_H = 480,
	parameter int Y_STRIDE = CODED_W,
	parameter int C_STRIDE = CODED_W / 2,
	parameter int BANK_STRIDE = 32'h0008_0000, // 512 KiB legacy
	parameter int DOORBELL_PAGE = 32'h1000,    // 4 KiB control page
	parameter bit FATAL_ON_STATIC_OVERFLOW = 1'b0
)(
	input  wire        clk,
	input  wire        reset,

	// Optional runtime override (0 → use static params).
	input  wire [31:0] rt_frame_bytes,
	input  wire [31:0] rt_bank_stride, // 0 → BANK_STRIDE
	input  wire        check_en,       // level or pulse; sampled each clk

	output wire [31:0] frame_bytes,
	output wire [31:0] usable_bytes,
	output wire        overflow_now,
	output reg         overflow_reject // sticky until reset
);

	// Static I420 payload (exact bytes; no silent pad into bank math).
	localparam int STATIC_FRAME_BYTES =
		(Y_STRIDE * CODED_H) + (C_STRIDE * CODED_H);
	localparam int STATIC_USABLE =
		(BANK_STRIDE > DOORBELL_PAGE) ? (BANK_STRIDE - DOORBELL_PAGE) : 0;
	localparam bit STATIC_OVERFLOW = (STATIC_FRAME_BYTES > STATIC_USABLE);

	// Elab-time LOUD fail (product QSF pins). Red twin TBs set FATAL=1 with 720p+512K.
	// Both sim and synth see the nonexistent instance when the condition holds.
	generate
		if (FATAL_ON_STATIC_OVERFLOW && STATIC_OVERFLOW) begin : g_fatal_overflow
			// Deliberate elab failure — do not "fix" by removing this.
			ddr_bank_geom_guard_STATIC_OVERFLOW_FRAME_EXCEEDS_BANK_STRIDE u_fatal ();
		end
	endgenerate

	wire [31:0] bank_stride_eff =
		(rt_bank_stride == 32'd0) ? 32'(BANK_STRIDE) : rt_bank_stride;
	wire [31:0] usable_eff =
		(bank_stride_eff > 32'(DOORBELL_PAGE))
			? (bank_stride_eff - 32'(DOORBELL_PAGE))
			: 32'd0;
	wire [31:0] frame_eff =
		(rt_frame_bytes == 32'd0) ? 32'(STATIC_FRAME_BYTES) : rt_frame_bytes;

	assign frame_bytes  = frame_eff;
	assign usable_bytes = usable_eff;
	assign overflow_now = check_en && (frame_eff > usable_eff);

	always @(posedge clk) begin
		if (reset)
			overflow_reject <= 1'b0;
		else if (overflow_now)
			overflow_reject <= 1'b1;
	end

endmodule

`default_nettype wire
