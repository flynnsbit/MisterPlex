// Present-domain stereo PCM FIFO (Phase 3.2) — sized for M10K inference.
// Write: clk_wr (sys). Read: clk_rd (CLK_AUDIO) @ 48 kHz (div 512).
// Keep a single registered read port so Quartus maps to altsyncram.
//
// CDC uses Gray-coded pointers (not binary) to avoid multi-bit glitch
// when sampled across clock domains.  Binary pointers stayed in the
// original design by mistake; fixed 2026-07-27 per async_fifo pattern.

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

	function automatic [AW:0] bin2gray(input [AW:0] b);
		bin2gray = (b >> 1) ^ b;
	endfunction

	function automatic [AW:0] gray2bin(input [AW:0] g);
		integer k;
		begin
			gray2bin = g;
			for (k = AW - 1; k >= 0; k = k - 1)
				gray2bin[k] = gray2bin[k+1] ^ g[k];
		end
	endfunction

	// Force block RAM (avoid register explosion)
	(* ramstyle = "M10K" *)
	reg [31:0] mem [0:DEPTH-1];

	wire reset_request = reset | wr_flush;
	(* async_reg = "true", preserve = "true" *)
	reg [1:0] wr_reset_pipe = 2'b11, rd_reset_pipe = 2'b11;
	always @(posedge clk_wr or posedge reset_request)
		if (reset_request) wr_reset_pipe <= 2'b11;
		else wr_reset_pipe <= {wr_reset_pipe[0],1'b0};
	always @(posedge clk_rd or posedge reset_request)
		if (reset_request) rd_reset_pipe <= 2'b11;
		else rd_reset_pipe <= {rd_reset_pipe[0],1'b0};
	wire wr_reset = wr_reset_pipe[1];
	wire rd_reset = rd_reset_pipe[1];

	reg [AW:0] wr_ptr, rd_ptr;
	(* preserve = "true" *) reg [AW:0] wr_gray, rd_gray;
	(* preserve = "true" *) reg has_wr;
	(* async_reg = "true", preserve = "true" *)
	reg [AW:0] rd_gray_w1, rd_gray_w2, wr_gray_r1, wr_gray_r2;
	(* async_reg = "true", preserve = "true" *) reg has_wr_s1, has_wr_s2;
	(* async_reg = "true", preserve = "true" *)
	reg rd_up_w1, rd_up_w2, wr_up_r1, wr_up_r2;

	wire [AW:0] rd_bin_in_wr = gray2bin(rd_gray_w2);

	// Assertion reaches both pointer owners even if either clock is stopped.
	// Only local, synchronized release can restart that owner's traffic.
	always @(posedge clk_wr or posedge wr_reset) begin
		if (wr_reset) begin
			rd_gray_w1 <= '0;
			rd_gray_w2 <= '0;
			rd_up_w1 <= 0;
			rd_up_w2 <= 0;
		end else begin
			rd_gray_w1 <= rd_gray;
			rd_gray_w2 <= rd_gray_w1;
			rd_up_w1 <= !rd_reset;
			rd_up_w2 <= rd_up_w1;
		end
	end

	always @(posedge clk_rd or posedge rd_reset) begin
		if (rd_reset) begin
			wr_gray_r1 <= '0;
			wr_gray_r2 <= '0;
			has_wr_s1  <= 1'b0;
			has_wr_s2  <= 1'b0;
			wr_up_r1 <= 0;
			wr_up_r2 <= 0;
		end else begin
			wr_gray_r1 <= wr_gray;
			wr_gray_r2 <= wr_gray_r1;
			has_wr_s1  <= has_wr;
			has_wr_s2  <= has_wr_s1;
			wr_up_r1 <= !wr_reset;
			wr_up_r2 <= wr_up_r1;
		end
	end

	// Full/empty use Gray-coded comparisons (safe across CDC)
	wire [AW:0] wr_gray_full = {~rd_gray_w2[AW:AW-1], rd_gray_w2[AW-2:0]};
	assign wr_full = wr_reset || !rd_up_w2 || (wr_gray == wr_gray_full);
	wire rd_empty = (rd_gray == wr_gray_r2);
	wire wr_accept = wr_en && !wr_full;
	wire [AW:0] wr_next = wr_ptr + {{AW{1'b0}},wr_accept};
	wire [AW:0] wr_used = wr_next - rd_bin_in_wr;

	always @(posedge clk_wr)
		if (wr_accept) mem[wr_ptr[AW-1:0]] <= wr_data;

	always @(posedge clk_wr or posedge wr_reset) begin
		if (wr_reset) begin
			wr_ptr   <= '0;
			wr_gray  <= '0;
			wr_level <= 16'd0;
			has_wr   <= 1'b0;
		end else begin
			if (wr_accept) begin
				wr_ptr  <= wr_next;
				wr_gray <= bin2gray(wr_next);
				has_wr  <= 1'b1;
			end
			wr_level <= 16'(wr_used);
		end
	end

	assign has_audio = has_wr_s2;

	// Read @ 48 kHz: one registered memory read
	reg [8:0]  sdiv;
	reg [31:0] rd_data;
	reg [AW-1:0] rd_addr_r;
	reg [1:0] read_primed;

	// Do not reset the RAM read port. The visibility pipeline is reset
	// instead, retaining M10K inference and keeping old-epoch data hidden.
	always @(posedge clk_rd)
		if (!rd_reset) rd_data <= mem[rd_addr_r];
	always @(posedge clk_rd or posedge rd_reset) begin
		if (rd_reset) begin
			rd_addr_r <= '0;
			read_primed <= 0;
		end else begin
			rd_addr_r <= rd_ptr[AW-1:0];
			read_primed <= {read_primed[0],1'b1};
		end
	end

	always @(posedge clk_rd or posedge rd_reset) begin
		if (rd_reset) begin
			rd_ptr    <= '0;
			rd_gray   <= '0;
			sdiv      <= 9'd0;
			sample_l  <= 16'd0;
			sample_r  <= 16'd0;
			underrun  <= 1'b0;
		end else if (!rd_enable || !wr_up_r2) begin
			sample_l <= 16'd0;
			sample_r <= 16'd0;
		end else begin
			sdiv <= sdiv + 1'd1;
			if (sdiv == 0 && read_primed[1]) begin
				if (!rd_empty) begin
					sample_l <= rd_data[15:0];
					sample_r <= rd_data[31:16];
					rd_ptr   <= rd_ptr + 1'd1;
					rd_gray  <= bin2gray(rd_ptr + 1'd1);
				end else begin
					sample_l <= 16'd0;
					sample_r <= 16'd0;
					if (has_wr_s2)
						underrun <= 1'b1;
				end
			end
		end
	end

	// ── RED GUARD: binary pointer CDC must never return ──────────
	// If anyone removes Gray coding and reverts to raw binary pointer
	// synchronization, this block will fire during simulation.
	// Flush/reset are exempt — they are domain-local reset events, not
	// incremental pointer advances.
`ifdef SIMULATION
	reg [AW:0] _red_prev_wr_gray = '0;
	reg [AW:0] _red_prev_rd_gray = '0;
	always @(posedge clk_wr or posedge wr_reset) begin
		if (wr_reset) _red_prev_wr_gray <= '0;
		else begin
		_red_prev_wr_gray <= wr_gray;
		if (_red_prev_wr_gray !== wr_gray) begin
			// Gray codes must differ in exactly one bit per transition
			if ($countones(_red_prev_wr_gray ^ wr_gray) != 1)
				$error("RED GUARD: wr_gray changed >1 bit — binary CDC regression");
		end
		end
	end
	always @(posedge clk_rd or posedge rd_reset) begin
		if (rd_reset) _red_prev_rd_gray <= '0;
		else begin
		_red_prev_rd_gray <= rd_gray;
		if (_red_prev_rd_gray !== rd_gray) begin
			if ($countones(_red_prev_rd_gray ^ rd_gray) != 1)
				$error("RED GUARD: rd_gray changed >1 bit — binary CDC regression");
		end
		end
	end
`endif

endmodule
