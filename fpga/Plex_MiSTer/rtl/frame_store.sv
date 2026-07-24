// Dual-bank RGB565 frame store (Phase 3 intermediate).
// Write path: HPS ioctl stream (byte pairs → RGB565).
// Read path: present engine samples active pixel (x,y).
// Bank swap after a full frame is written so display never tears mid-write.
//
// Size: 320×240 × 16-bit × 2 banks ≈ 307 KB BRAM — fits Cyclone V SE.

module frame_store #(
	parameter int WIDTH  = 320,
	parameter int HEIGHT = 240
)(
	input  wire        clk,
	input  wire        reset,

	// ---- write (ioctl / HPS) ----
	input  wire        wr_en,        // one RGB565 pixel
	input  wire [15:0] wr_pixel,
	input  wire        wr_reset_ptr, // start new frame at (0,0)
	output reg  [18:0] wr_count,     // pixels written this frame
	output wire        wr_frame_done,// pulse when count hits WIDTH*HEIGHT

	// ---- read (present) ----
	input  wire [9:0]  rd_x,
	input  wire [9:0]  rd_y,
	input  wire        rd_active,    // in visible area
	output reg  [7:0]  rd_r,
	output reg  [7:0]  rd_g,
	output reg  [7:0]  rd_b,

	// ---- control ----
	input  wire        swap_banks,   // display ← write bank (usually on frame done)
	output reg         has_frame     // at least one complete frame presented
);

	localparam int PIXELS = WIDTH * HEIGHT;
	localparam int ADDR_W = $clog2(PIXELS);

	// Two banks of RGB565 (M10K; dual-port registered)
	(* ramstyle = "M10K" *)
	reg [15:0] bank0 [0:PIXELS-1];
	(* ramstyle = "M10K" *)
	reg [15:0] bank1 [0:PIXELS-1];

	reg             disp_bank; // 0 → bank0 on display
	reg [ADDR_W-1:0] wr_addr;
	reg [ADDR_W-1:0] rd_addr;
	reg [15:0]       rd_q;

	wire [9:0] width_w  = WIDTH[9:0];
	wire [9:0] height_w = HEIGHT[9:0];
	wire [ADDR_W-1:0] calc_rd =
		(rd_y < height_w && rd_x < width_w) ?
			(rd_y * width_w) + rd_x :
			{ADDR_W{1'b0}};

	localparam [ADDR_W-1:0] LAST_PIX = PIXELS[ADDR_W-1:0] - 1'd1;
	assign wr_frame_done = wr_en && (wr_count == PIXELS[18:0] - 19'd1);

	// Write port — always into the non-display bank
	always @(posedge clk) begin
		if (reset) begin
			wr_addr  <= 0;
			wr_count <= 0;
		end else if (wr_reset_ptr) begin
			wr_addr  <= 0;
			wr_count <= 0;
		end else if (wr_en) begin
			if (disp_bank == 1'b0)
				bank1[wr_addr] <= wr_pixel;
			else
				bank0[wr_addr] <= wr_pixel;
			if (wr_addr == LAST_PIX)
				wr_addr <= 0;
			else
				wr_addr <= wr_addr + 1'd1;
			if (wr_count < PIXELS[18:0])
				wr_count <= wr_count + 1'd1;
		end
	end

	// Bank swap + ready
	always @(posedge clk) begin
		if (reset) begin
			disp_bank <= 0;
			has_frame <= 0;
		end else if (swap_banks) begin
			disp_bank <= ~disp_bank;
			has_frame <= 1'b1;
		end
	end

	// Sync read: register address then data (1-cycle)
	reg             rd_active_d;
	reg [ADDR_W-1:0] rd_addr_r;
	always @(posedge clk) begin
		rd_addr_r  <= calc_rd;
		rd_active_d <= rd_active;
		if (disp_bank == 1'b0)
			rd_q <= bank0[rd_addr_r];
		else
			rd_q <= bank1[rd_addr_r];

		// Expand RGB565 → 8-bit (replicate MSBs)
		if (rd_active_d && has_frame) begin
			rd_r <= {rd_q[15:11], rd_q[15:13]};
			rd_g <= {rd_q[10:5],  rd_q[10:9]};
			rd_b <= {rd_q[4:0],   rd_q[4:2]};
		end else begin
			rd_r <= 8'd0;
			rd_g <= 8'd0;
			rd_b <= 8'd0;
		end
	end

endmodule
