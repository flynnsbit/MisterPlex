// SMPTE-style color bars + optional moving block driven by content frame index.
// Generates progressive 320x240-class timing (NTSC 15 kHz family when not scandoubled).

module colorbars (
	input  wire        clk,
	input  wire        reset,

	input  wire        pal,           // 0 NTSC-like, 1 PAL-like
	input  wire        scandouble,
	input  wire [31:0] content_index, // unique frame number (cadence-advanced)
	input  wire [1:0]  pattern,       // 0=bars, 1=bars+block, 2=grid, 3=solid ramp

	output reg         ce_pix,
	output reg         HBlank,
	output reg         HSync,
	output reg         VBlank,
	output reg         VSync,
	output reg         frame_start,   // 1-cycle pulse when leaving VBlank (display tick)

	output reg  [7:0]  r,
	output reg  [7:0]  g,
	output reg  [7:0]  b
);

	// Timing: match MiSTer Template / standard 320x240-class at ~60 Hz (NTSC)
	// and ~50 Hz (PAL) with the 20 MHz sys PLL.
	//
	// Previous H_TOTAL=426 yielded ~90 Hz → LCD "out of range" + vertical roll
	// (no vertical hold). Template uses ~638 px/line for ~59.8 Hz:
	//   half-rate ce_pix: 10 MHz / (638 * 262) ≈ 59.8 Hz progressive
	//   scandouble:       20 MHz / (638 * 524) ≈ 59.8 Hz
	localparam H_ACTIVE = 10'd320;
	localparam H_TOTAL  = 10'd638; // 0..637 like Template mycore
	localparam H_FP     = 10'd24;
	localparam H_SYNC   = 10'd64;
	// hblank starts after active
	// PAL vs NTSC vtotal (Template-aligned)
	wire [9:0] v_active = scandouble ? 10'd480 : 10'd240;
	wire [9:0] v_total  = scandouble ? (pal ? 10'd624 : 10'd524) : (pal ? 10'd312 : 10'd262);
	wire [9:0] v_sync_s = scandouble ? (pal ? 10'd490 : 10'd490) : (pal ? 10'd256 : 10'd245);
	wire [9:0] v_sync_e = scandouble ? (pal ? 10'd496 : 10'd496) : (pal ? 10'd259 : 10'd248);

	reg [9:0] hc;
	reg [9:0] vc;

	always @(posedge clk) begin
		if (scandouble)
			ce_pix <= 1'b1;
		else
			ce_pix <= ~ce_pix;

		frame_start <= 1'b0;

		if (reset) begin
			hc <= 0;
			vc <= 0;
			HBlank <= 1;
			VBlank <= 1;
			HSync  <= 0;
			VSync  <= 0;
			ce_pix <= 0;
		end else if (ce_pix) begin
			if (hc == H_TOTAL - 1) begin
				hc <= 0;
				if (vc == v_total - 1)
					vc <= 0;
				else
					vc <= vc + 1'd1;
			end else begin
				hc <= hc + 1'd1;
			end

			// HBlank / HSync
			HBlank <= (hc >= H_ACTIVE);
			if (hc == H_ACTIVE + H_FP)
				HSync <= 1'b1;
			if (hc == H_ACTIVE + H_FP + H_SYNC)
				HSync <= 1'b0;

			// VBlank / VSync
			VBlank <= (vc >= v_active);
			if (vc == v_sync_s)
				VSync <= 1'b1;
			if (vc == v_sync_e)
				VSync <= 1'b0;

			// Display tick: start of first active line of a new frame
			if (hc == 0 && vc == 0)
				frame_start <= 1'b1;
		end
	end

	// Color bars: 8 vertical stripes
	wire [9:0] px = hc;
	wire [9:0] py = scandouble ? (vc >> 1) : vc;
	wire [2:0] bar = px[8:6]; // 320/8 ≈ 40 px per bar using high bits of 0..319

	reg [7:0] br, bg, bb;
	always @(*) begin
		br = 8'd0; bg = 8'd0; bb = 8'd0;
		case (bar)
			3'd0: begin br = 8'hC0; bg = 8'hC0; bb = 8'hC0; end // white
			3'd1: begin br = 8'hC0; bg = 8'hC0; bb = 8'h00; end // yellow
			3'd2: begin br = 8'h00; bg = 8'hC0; bb = 8'hC0; end // cyan
			3'd3: begin br = 8'h00; bg = 8'hC0; bb = 8'h00; end // green
			3'd4: begin br = 8'hC0; bg = 8'h00; bb = 8'hC0; end // magenta
			3'd5: begin br = 8'hC0; bg = 8'h00; bb = 8'h00; end // red
			3'd6: begin br = 8'h00; bg = 8'h00; bb = 8'hC0; end // blue
			default: begin br = 8'h00; bg = 8'h00; bb = 8'h00; end // black
		endcase
	end

	// Moving block position from content_index (unique frames only)
	wire [7:0] bx = content_index[7:0];
	wire [7:0] by = content_index[15:8] ^ content_index[7:0];
	wire in_block = (px >= {2'b0, bx}) && (px < {2'b0, bx} + 10'd32)
	             && (py >= {2'b0, by[6:0], 1'b0}) && (py < {2'b0, by[6:0], 1'b0} + 10'd24);

	wire grid = px[3] ^ py[3];

	always @(posedge clk) begin
		if (ce_pix) begin
			if (HBlank || VBlank) begin
				r <= 0; g <= 0; b <= 0;
			end else begin
				case (pattern)
					2'd0: begin r <= br; g <= bg; b <= bb; end
					2'd1: begin
						if (in_block) begin
							r <= 8'hFF; g <= 8'hFF; b <= 8'h00;
						end else begin
							r <= br; g <= bg; b <= bb;
						end
					end
					2'd2: begin
						r <= grid ? 8'hFF : 8'h20;
						g <= grid ? 8'hFF : 8'h20;
						b <= grid ? 8'hFF : 8'h20;
					end
					default: begin
						r <= px[7:0];
						g <= py[7:0];
						b <= content_index[7:0];
					end
				endcase
			end
		end
	end

endmodule
