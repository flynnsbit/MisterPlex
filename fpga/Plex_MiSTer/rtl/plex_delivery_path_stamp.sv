// plex_delivery_path_stamp — fabric-visible frame delivery path class (w-fitgate).
//
// Parent Sweep 118 (measured): decode 32.705 ms/f + ARM sendDdrFrame copy
// 14.978 ms/f is 6.016 ms/f SHORT of 24 fps when serial. Fit/STA cannot see
// that copy. This stamp makes the *compiled* delivery path visible in the
// netlist so a FIT_RPT cannot be mistaken for "720p24 delivery PASS".
//
// Default product path: ARM_COPY (HPS /dev/mem → DDR frame banks).
// FABRIC_FRAME_DMA=1 (future w-mem/w-path): fabric fetches; ARM never copies.
// Registered + preserve so the fitter cannot strip the class bits.
//
// Does NOT prove DMA works — only which path class was elaborated.

`timescale 1ns / 1ps

module plex_delivery_path_stamp (
	input  wire        clk,
	input  wire        reset,
	output wire        arm_copy_path,     // 1 = product still relies on HPS sendDdrFrame copy
	output wire        fabric_dma_path,   // 1 = FABRIC_FRAME_DMA macro claimed at compile
	// Packed class for status/observe: {6'b0, fabric_dma_path, arm_copy_path}
	output wire [7:0]  path_class,
	// Live heart — parent top must consume so fitter cannot prune.
	output wire        stamp_alive
);

`ifdef FABRIC_FRAME_DMA
	localparam bit LP_FABRIC = 1'b1;
	localparam bit LP_ARM    = 1'b0;
`else
	// Honest default: ARM copy path is live until fabric DMA lands.
	localparam bit LP_FABRIC = 1'b0;
	localparam bit LP_ARM    = 1'b1;
`endif

(* preserve *) reg arm_r;
(* preserve *) reg fabric_r;
(* preserve *) reg [7:0] class_r;
(* preserve *) reg alive_r;

assign arm_copy_path   = arm_r;
assign fabric_dma_path = fabric_r;
assign path_class      = class_r;
assign stamp_alive     = alive_r;

always @(posedge clk or posedge reset) begin
	if (reset) begin
		arm_r    <= 1'b0;
		fabric_r <= 1'b0;
		class_r  <= 8'h00;
		alive_r  <= 1'b0;
	end else begin
		arm_r    <= LP_ARM;
		fabric_r <= LP_FABRIC;
		class_r  <= {6'b0, LP_FABRIC, LP_ARM};
		alive_r  <= 1'b1;
	end
end

endmodule
