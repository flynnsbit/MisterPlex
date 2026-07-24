// Present-domain stereo PCM FIFO (Phase 3.2) — sized for M10K inference.
// Write: clk_wr (sys). Read: clk_rd (CLK_AUDIO) @ 48 kHz (div 512).
// Keep a single registered read port so Quartus maps to altsyncram.

module audio_fifo #(
	parameter int DEPTH = 2048  // ~42 ms @ 48 kHz stereo
)(
	input  wire        clk_wr,
	input  wire        clk_rd,
	input  wire        reset,

	input  wire        wr_en,
	input  wire [31:0] wr_data,  // {R[15:0], L[15:0]}
	input  wire        wr_flush,
	output wire        wr_full,
	output reg  [15:0] wr_level,

	input  wire        rd_enable,
	output reg  [15:0] sample_l,
	output reg  [15:0] sample_r,
	output reg         underrun,
	output wire        has_audio
);

	localparam int AW = $clog2(DEPTH);

	// Force block RAM (avoid register explosion)
	(* ramstyle = "M10K" *)
	reg [31:0] mem [0:DEPTH-1];

	reg [AW:0] wr_ptr;
	reg [AW:0] rd_ptr;
	reg        has_wr;

	// CDC 2FF for pointers
	reg [AW:0] rd_ptr_s1, rd_ptr_s2;
	reg [AW:0] wr_ptr_s1, wr_ptr_s2;
	reg        has_wr_s1, has_wr_s2;

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
			has_wr_s1 <= 0;
			has_wr_s2 <= 0;
		end else begin
			wr_ptr_s1 <= wr_ptr;
			wr_ptr_s2 <= wr_ptr_s1;
			has_wr_s1 <= has_wr;
			has_wr_s2 <= has_wr_s1;
		end
	end

	assign wr_full =
		(wr_ptr[AW-1:0] == rd_ptr_s2[AW-1:0]) && (wr_ptr[AW] != rd_ptr_s2[AW]);
	wire rd_empty = (rd_ptr == wr_ptr_s2);

	// Write port only
	always @(posedge clk_wr) begin
		if (reset) begin
			wr_ptr   <= 0;
			wr_level <= 0;
			has_wr   <= 0;
		end else if (wr_flush) begin
			wr_ptr   <= 0;
			wr_level <= 0;
		end else begin
			if (wr_en && !wr_full) begin
				mem[wr_ptr[AW-1:0]] <= wr_data;
				wr_ptr <= wr_ptr + 1'd1;
				has_wr <= 1'b1;
			end
			// level ≈ wr - rd (low bits)
			wr_level <= wr_ptr[AW-1:0] - rd_ptr_s2[AW-1:0];
		end
	end

	assign has_audio = has_wr_s2;

	// Read @ 48 kHz: one registered memory read
	reg [8:0]  sdiv;
	reg [31:0] rd_data;
	reg [AW-1:0] rd_addr_r;

	always @(posedge clk_rd) begin
		if (reset) begin
			rd_ptr    <= 0;
			sdiv      <= 0;
			sample_l  <= 0;
			sample_r  <= 0;
			underrun  <= 0;
			rd_data   <= 0;
			rd_addr_r <= 0;
		end else if (!rd_enable) begin
			sample_l <= 0;
			sample_r <= 0;
		end else begin
			sdiv <= sdiv + 1'd1;
			// continuous registered read of current address
			rd_addr_r <= rd_ptr[AW-1:0];
			rd_data   <= mem[rd_addr_r];

			if (sdiv == 0) begin
				if (!rd_empty) begin
					sample_l <= rd_data[15:0];
					sample_r <= rd_data[31:16];
					rd_ptr   <= rd_ptr + 1'd1;
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
