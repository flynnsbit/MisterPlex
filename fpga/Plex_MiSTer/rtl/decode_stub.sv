// Phase 3.3b: stand-in for H.264 soft-core.
// On each VCL NAL pulse (IDR/non-IDR), paint one 320×240 RGB565 diagnostic frame
// into frame_store write port and request bank swap.
//
// Pattern (eyes-on / status correlation):
//   - Outer border: green if last was IDR (type 5), cyan if P/slice (type 1)
//   - Fill: dark navy; diagonal bar steps with nalu_count
//   - Top strip encodes last_nal_type in red, idr_count in green
// Real Baseline IP will replace this module and keep the same write interface.

module decode_stub #(
	parameter int WIDTH  = 320,
	parameter int HEIGHT = 240
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        vcl_pulse,      // from nalu_scanner
	input  wire [7:0]  last_nal_type,
	input  wire [15:0] nalu_count,
	input  wire [7:0]  idr_count,
	input  wire        has_idr,

	// frame_store write side
	output reg         wr_en,
	output reg  [15:0] wr_pixel,
	output reg         wr_reset_ptr,
	output reg         swap_req,
	output reg         busy,
	output reg  [15:0] frames_out
);

	localparam int PIXELS = WIDTH * HEIGHT;
	localparam int ADDR_W = $clog2(PIXELS);

	reg [ADDR_W:0] pix_i; // 0..PIXELS
	reg [9:0]      x, y;
	reg            active;
	reg            is_idr_frame;
	reg [7:0]      lat_type;
	reg [15:0]     lat_nalu;
	reg [7:0]      lat_idr;

	// Combinational pixel colour for current (x,y) + latched meta
	wire [9:0] width_w  = WIDTH[9:0];
	wire [9:0] height_w = HEIGHT[9:0];
	wire border = (x < 10'd4) || (x >= (width_w - 10'd4)) ||
	              (y < 10'd4) || (y >= (height_w - 10'd4));
	wire diag   = ((x[7:0] + y[7:0] + lat_nalu[7:0]) & 8'h1F) < 8'd3;
	wire strip  = (y < 10'd16);

	wire idr_style = is_idr_frame || (lat_type[4:0] == 5'd5);

	wire [7:0] rr =
		border ? 8'h10 :
		strip  ? {lat_type[4:0], 3'b000} :
		diag   ? 8'hF0 :
		         8'h08;
	wire [7:0] gg =
		border ? (idr_style ? 8'hE0 : 8'hC0) :
		strip  ? lat_idr :
		diag   ? 8'hA0 :
		         (8'h10 + {4'b0, lat_nalu[3:0]});
	wire [7:0] bb =
		border ? (idr_style ? 8'h20 : 8'hE0) :
		strip  ? 8'h20 :
		diag   ? 8'h20 :
		         (8'h40 + {lat_nalu[5:0], 2'b00});
	wire [15:0] px_comb = {rr[7:3], gg[7:2], bb[7:3]};

	always @(posedge clk) begin
		wr_en        <= 1'b0;
		wr_reset_ptr <= 1'b0;
		swap_req     <= 1'b0;

		if (reset) begin
			active       <= 0;
			busy         <= 0;
			pix_i        <= 0;
			x            <= 0;
			y            <= 0;
			frames_out   <= 0;
			is_idr_frame <= 0;
			lat_type     <= 0;
			lat_nalu     <= 0;
			lat_idr      <= 0;
			wr_pixel     <= 0;
		end else if (!active) begin
			// Accept new VCL; ignore pulses while painting
			if (vcl_pulse) begin
				active       <= 1'b1;
				busy         <= 1'b1;
				pix_i        <= 0;
				x            <= 0;
				y            <= 0;
				wr_reset_ptr <= 1'b1;
				is_idr_frame <= (last_nal_type[4:0] == 5'd5);
				lat_type     <= last_nal_type;
				lat_nalu     <= nalu_count;
				lat_idr      <= idr_count;
			end
		end else begin
			// Paint one pixel / cycle
			wr_en    <= 1'b1;
			wr_pixel <= px_comb;

			if (pix_i == PIXELS[ADDR_W:0] - 1'd1) begin
				active     <= 1'b0;
				busy       <= 1'b0;
				swap_req   <= 1'b1;
				frames_out <= frames_out + 1'd1;
				pix_i      <= 0;
				x          <= 0;
				y          <= 0;
			end else begin
				pix_i <= pix_i + 1'd1;
				if (x == (width_w - 10'd1)) begin
					x <= 0;
					y <= y + 1'd1;
				end else
					x <= x + 1'd1;
			end
		end
	end

endmodule
