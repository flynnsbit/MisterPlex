// Present-domain stereo PCM FIFO (Phase 3.2).
// Write: clk_sys (ioctl F2 / HPS) — packed s16le L then R → 32-bit words.
// Read:  CLK_AUDIO @ 48 kHz (div 512 from 24.576 MHz).
// Empty → silence; underrun sticky until reset.

module audio_fifo #(
	parameter int DEPTH = 4096  // stereo frames (~85 ms @ 48 kHz)
)(
	input  wire        clk_wr,
	input  wire        clk_rd,   // CLK_AUDIO
	input  wire        reset,

	// write side (sys clock)
	input  wire        wr_en,    // one stereo sample (32-bit)
	input  wire [31:0] wr_data,  // {R[15:0], L[15:0]} little-endian stream assembled upstream
	input  wire        wr_flush, // clear write pointer (new stream)
	output wire        wr_full,
	output reg  [15:0] wr_level,

	// read side (audio clock)
	input  wire        rd_enable,
	output reg  [15:0] sample_l,
	output reg  [15:0] sample_r,
	output reg         underrun,
	output wire        has_audio // at least one sample ever written since reset
);

	localparam int AW = $clog2(DEPTH);

	(* ramstyle = "no_rw_check, M10K" *)
	reg [31:0] mem [0:DEPTH-1];

	// --- write pointer (clk_wr) ---
	reg [AW:0] wr_ptr; // extra bit for full/empty
	reg [AW:0] rd_ptr_wr; // sync'd rd_ptr
	reg        has_wr;

	// --- read pointer (clk_rd) ---
	reg [AW:0] rd_ptr;
	reg [AW:0] wr_ptr_rd;

	// CDC: 2FF sync pointers
	reg [AW:0] rd_ptr_s1, rd_ptr_s2;
	reg [AW:0] wr_ptr_s1, wr_ptr_s2;

	always @(posedge clk_wr) begin
		if (reset) begin
			rd_ptr_s1 <= 0;
			rd_ptr_s2 <= 0;
		end else begin
			rd_ptr_s1 <= rd_ptr;
			rd_ptr_s2 <= rd_ptr_s1;
		end
	end
	always @(posedge clk_rd) begin
		if (reset) begin
			wr_ptr_s1 <= 0;
			wr_ptr_s2 <= 0;
		end else begin
			wr_ptr_s1 <= wr_ptr;
			wr_ptr_s2 <= wr_ptr_s1;
		end
	end

	wire [AW:0] wr_ptr_bin = wr_ptr;
	wire [AW:0] rd_ptr_bin_w = rd_ptr_s2;
	wire [AW:0] wr_ptr_bin_r = wr_ptr_s2;
	wire [AW:0] rd_ptr_bin = rd_ptr;

	assign wr_full = (wr_ptr_bin[AW-1:0] == rd_ptr_bin_w[AW-1:0]) &&
	                 (wr_ptr_bin[AW] != rd_ptr_bin_w[AW]);
	wire rd_empty = (rd_ptr_bin == wr_ptr_bin_r);

	// Write
	always @(posedge clk_wr) begin
		if (reset) begin
			wr_ptr  <= 0;
			wr_level <= 0;
			has_wr  <= 0;
		end else if (wr_flush) begin
			wr_ptr  <= 0;
			wr_level <= 0;
		end else if (wr_en && !wr_full) begin
			mem[wr_ptr[AW-1:0]] <= wr_data;
			wr_ptr <= wr_ptr + 1'd1;
			has_wr <= 1'b1;
			wr_level <= wr_level + 1'd1; // approximate
		end else begin
			// refresh level estimate
			wr_level <= wr_ptr_bin[AW-1:0] - rd_ptr_bin_w[AW-1:0];
		end
	end

	// CDC has_wr → read domain
	reg has_wr_s1, has_wr_s2;
	always @(posedge clk_rd) begin
		if (reset) begin
			has_wr_s1 <= 0;
			has_wr_s2 <= 0;
		end else begin
			has_wr_s1 <= has_wr;
			has_wr_s2 <= has_wr_s1;
		end
	end
	assign has_audio = has_wr_s2;

	// Read @ 48 kHz from 24.576 MHz
	reg [8:0] sdiv;
	reg [31:0] rd_q;

	always @(posedge clk_rd) begin
		if (reset) begin
			rd_ptr   <= 0;
			sdiv     <= 0;
			sample_l <= 0;
			sample_r <= 0;
			underrun <= 0;
			rd_q     <= 0;
		end else if (!rd_enable) begin
			sample_l <= 0;
			sample_r <= 0;
		end else begin
			sdiv <= sdiv + 1'd1;
			if (sdiv == 0) begin
				if (!rd_empty) begin
					rd_q     <= mem[rd_ptr[AW-1:0]];
					rd_ptr   <= rd_ptr + 1'd1;
					sample_l <= mem[rd_ptr[AW-1:0]][15:0];
					sample_r <= mem[rd_ptr[AW-1:0]][31:16];
				end else begin
					sample_l <= 0;
					sample_r <= 0;
					if (has_wr_s2)
						underrun <= 1'b1;
				end
			end
		end
	end

endmodule
