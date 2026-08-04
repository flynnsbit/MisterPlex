// fabric_dma_arm_kick — ARM-side descriptor latch for ddr_frame_dma (w-plxd).
//
// Holds src_phys / bank_phys / frame_bytes and emits a one-cycle start pulse
// when kick is asserted in IDLE. Rejects misaligned descriptors (err sticky
// until next kick). Does not touch DDRAM (w-mem owns the port + bounce).
//
// M10K: 0 (registers only). ALM: EST few dozen (unfitted — entity row closes).
// Compose: integ/720p-compose wires defaults to Option-C 720p; kick held 0
// until HPS mailbox/SPI is connected. Fit still sees real phys constants.
//
// Refresh: none. Scanout rate is w-clock (PRESENT_CLK_PIX_PLL); do not claim
// 24 Hz from this module.

`timescale 1ns / 1ps

module fabric_dma_arm_kick (
	input  wire        clk,
	input  wire        reset,

	// ARM / HPS kick (level or pulse; re-armed when dma_busy falls).
	input  wire        kick,
	input  wire [31:0] src_phys_i,
	input  wire [31:0] bank_phys_i,
	input  wire [31:0] frame_bytes_i,

	// From ddr_frame_dma
	input  wire        dma_busy,
	input  wire        dma_done,
	input  wire        dma_err_align,

	// To ddr_frame_dma
	output reg         start,
	output reg  [31:0] src_phys,
	output reg  [31:0] bank_phys,
	output reg  [31:0] frame_bytes,

	// Status for future HPS readback
	output reg         kick_accept,
	output reg         kick_reject,
	output reg         last_err_align,
	output reg  [31:0] kicks_accepted,
	output reg  [31:0] kicks_rejected
);
	wire align_ok = (src_phys_i[2:0] == 3'b000) &&
	                (bank_phys_i[2:0] == 3'b000) &&
	                (frame_bytes_i[2:0] == 3'b000) &&
	                (frame_bytes_i != 32'd0);

	reg kick_d;
	wire kick_rise = kick & ~kick_d;

	always @(posedge clk) begin
		if (reset) begin
			kick_d <= 1'b0;
			start <= 1'b0;
			src_phys <= 32'd0;
			bank_phys <= 32'd0;
			frame_bytes <= 32'd0;
			kick_accept <= 1'b0;
			kick_reject <= 1'b0;
			last_err_align <= 1'b0;
			kicks_accepted <= 32'd0;
			kicks_rejected <= 32'd0;
		end else begin
			kick_d <= kick;
			start <= 1'b0;
			kick_accept <= 1'b0;
			kick_reject <= 1'b0;

			if (kick_rise && !dma_busy) begin
				if (!align_ok) begin
					kick_reject <= 1'b1;
					last_err_align <= 1'b1;
					kicks_rejected <= kicks_rejected + 32'd1;
				end else begin
					src_phys <= src_phys_i;
					bank_phys <= bank_phys_i;
					frame_bytes <= frame_bytes_i;
					start <= 1'b1;
					kick_accept <= 1'b1;
					last_err_align <= 1'b0;
					kicks_accepted <= kicks_accepted + 32'd1;
				end
			end

			// Capture DMA align fault if engine rejects after start.
			if (dma_done && dma_err_align)
				last_err_align <= 1'b1;
		end
	end
endmodule
