// SMPTE-style color bars + optional moving block driven by content frame index.
// Generates progressive 320x240-class timing (NTSC 15 kHz family when not scandoubled).
//
// Horizontal timing matches MiSTer Template mycore.v exactly so the scaler /
// analog VGA path locks HSync correctly:
//   hc 0..637, HBlank @529, HSync 544..589, ~59.8 Hz with 20 MHz / ce_pix.

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

	// Content is 320×240. Line total stays Template-like (638) for ~60 Hz, but
	// HBlank starts at 320 so DE == content width. Template HBlank@529 left a
	// black right half of active video (~320/529) so VGA/HDMI looked pillarboxed.
	// HSync still near end of line (544..589) for stable lock.
	localparam H_CONTENT = 10'd320;
	localparam H_LAST    = 10'd637; // wrap after this → 638 clocks/line
	localparam H_BLANK_S = H_CONTENT; // DE = content (full-width after scaler)
	localparam H_SYNC_S  = 10'd544;
	localparam H_SYNC_E  = 10'd590;

	reg [9:0] hc;
	reg [9:0] vc;

	// Pixel enable + counters (Template mycore style)
	always @(posedge clk) begin
		if (scandouble)
			ce_pix <= 1'b1;
		else
			ce_pix <= ~ce_pix;

		frame_start <= 1'b0;

		if (reset) begin
			hc     <= 0;
			vc     <= 0;
			ce_pix <= 0;
		end else if (ce_pix) begin
			if (hc == H_LAST) begin
				hc <= 0;
				if (vc == (pal ? (scandouble ? 10'd623 : 10'd311)
				               : (scandouble ? 10'd523 : 10'd261))) begin
					vc <= 0;
				end else begin
					vc <= vc + 1'd1;
				end
			end else begin
				hc <= hc + 1'd1;
			end

			// Display tick at start of first active line
			if (hc == H_LAST &&
			    vc == (pal ? (scandouble ? 10'd623 : 10'd311)
			               : (scandouble ? 10'd523 : 10'd261)))
				frame_start <= 1'b1;
		end
	end

	// H/V blank & sync — same edges as Template mycore.v (every clk, sample hc)
	always @(posedge clk) begin
		if (reset) begin
			HBlank <= 1'b1;
			HSync  <= 1'b0;
			VBlank <= 1'b1;
			VSync  <= 1'b0;
		end else begin
			if (hc == H_BLANK_S)
				HBlank <= 1'b1;
			else if (hc == 10'd0)
				HBlank <= 1'b0;

			if (hc == H_SYNC_S) begin
				HSync <= 1'b1;

				if (pal) begin
					if (vc == (scandouble ? 10'd609 : 10'd304))
						VSync <= 1'b1;
					else if (vc == (scandouble ? 10'd617 : 10'd308))
						VSync <= 1'b0;

					if (vc == (scandouble ? 10'd601 : 10'd300))
						VBlank <= 1'b1;
					else if (vc == 10'd0)
						VBlank <= 1'b0;
				end else begin
					if (vc == (scandouble ? 10'd490 : 10'd245))
						VSync <= 1'b1;
					else if (vc == (scandouble ? 10'd496 : 10'd248))
						VSync <= 1'b0;

					if (vc == (scandouble ? 10'd480 : 10'd240))
						VBlank <= 1'b1;
					else if (vc == 10'd0)
						VBlank <= 1'b0;
				end
			end

			if (hc == H_SYNC_E)
				HSync <= 1'b0;
		end
	end

	// Color bars fill the full DE window (hc 0..H_CONTENT-1)
	wire [9:0] px = hc;
	wire [9:0] py = scandouble ? (vc >> 1) : vc;
	wire [2:0] bar = px[8:6]; // ~40 px per bar in 0..319
	wire in_content = (hc < H_CONTENT) &&
	                  (py < 10'd240) &&
	                  ~HBlank && ~VBlank;

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
			if (!in_content) begin
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
