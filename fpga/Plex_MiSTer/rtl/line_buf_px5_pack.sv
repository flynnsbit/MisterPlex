// line_buf_px5_pack — 64-bit DDR beats → 40-bit packed words (5 px/word).
//
// clear: pulse at line start while !busy (or force).
// in_valid/in_q: 8-byte beat, pix0 in [7:0].
// out_*: packed words, out_addr = word index 0..PIXELS/5-1.
// line_done: 1-cycle pulse on final word emit.
//
// PIXELS % 5 == 0 (1280 luma / 640 chroma).
// SKID: beat skid depth; product fill @ continuous DOUT needs SKID >= beats/line.
// FIFO_DEPTH: packed-word FIFO (M10K). Default 256 = full luma line.
//
// M10K EST: 1 (256×40 FIFO). ALM EST: ~120 + SKID*64 FFs.
// Layout of line RAM consumer: 256×40 (line_buf_ram_px5).

module line_buf_px5_pack #(
	parameter int PIXELS     = 1280,
	parameter int AW         = 8,
	parameter int FIFO_DEPTH = 256,
	parameter int SKID       = 32
)(
	input  wire          clk,
	input  wire          reset,
	input  wire          clear,
	input  wire          in_valid,
	input  wire [63:0]   in_q,
	output reg           out_valid,
	output reg  [AW-1:0] out_addr,
	output reg  [39:0]   out_data,
	output reg           line_done,
	output wire          busy,
	output reg           skid_overflow
);
	localparam int NWORDS  = PIXELS / 5;
	localparam int FIFO_AW = $clog2(FIFO_DEPTH);
	localparam int SK_AW   = $clog2(SKID);

	reg [39:0]   acc;
	reg [2:0]    fill;
	reg [AW-1:0] widx;
	reg          active;

	reg [39:0]   side_d0, side_d1;
	reg [AW-1:0] side_a0, side_a1;
	reg [1:0]    side_n;

	reg [63:0]    sk_mem [0:SKID-1];
	reg [SK_AW:0] sk_w, sk_r;

	(* ramstyle = "M10K" *) reg [39:0]   fq_d [0:FIFO_DEPTH-1];
	(* ramstyle = "M10K" *) reg [AW-1:0] fq_a [0:FIFO_DEPTH-1];
	reg [FIFO_AW:0] fq_w, fq_r;

	reg [15:0] words_out;

	wire [SK_AW:0] sk_level = sk_w - sk_r;
	wire sk_empty = (sk_level == 0);
	wire sk_full  = (sk_level >= SKID[SK_AW:0]);
	wire [FIFO_AW:0] fq_level = fq_w - fq_r;
	wire fq_empty = (fq_level == 0);
	wire fq_full  = (fq_level >= FIFO_DEPTH[FIFO_AW:0]);

	assign busy = active || !sk_empty || (side_n != 2'd0) || !fq_empty;

	integer bi;
	reg [7:0] nb;
	reg [63:0] beat;
	reg [39:0] n_acc;
	reg [2:0] n_fill;
	reg [AW-1:0] n_widx;
	reg [1:0] n_side;
	reg [39:0] e0d, e1d;
	reg [AW-1:0] e0a, e1a;

	// next skid pointers (blocking helpers)
	reg [SK_AW:0] sk_w_n, sk_r_n;
	reg [FIFO_AW:0] fq_w_n, fq_r_n;
	reg [1:0] side_n_n;
	reg [39:0] sd0, sd1;
	reg [AW-1:0] sa0, sa1;
	reg did_out;

	always @(posedge clk) begin
		if (reset) begin
			out_valid <= 1'b0;
			out_addr <= '0;
			out_data <= 40'd0;
			line_done <= 1'b0;
			acc <= 40'd0;
			fill <= 3'd0;
			widx <= '0;
			active <= 1'b0;
			side_n <= 2'd0;
			side_d0 <= 40'd0;
			side_d1 <= 40'd0;
			side_a0 <= '0;
			side_a1 <= '0;
			sk_w <= '0;
			sk_r <= '0;
			fq_w <= '0;
			fq_r <= '0;
			words_out <= 16'd0;
			skid_overflow <= 1'b0;
		end else begin
			out_valid <= 1'b0;
			line_done <= 1'b0;
			did_out = 1'b0;

			sk_w_n = sk_w;
			sk_r_n = sk_r;
			fq_w_n = fq_w;
			fq_r_n = fq_r;
			side_n_n = side_n;
			sd0 = side_d0;
			sd1 = side_d1;
			sa0 = side_a0;
			sa1 = side_a1;

			if (clear) begin
				acc <= 40'd0;
				fill <= 3'd0;
				widx <= '0;
				active <= 1'b1;
				side_n_n = 2'd0;
				words_out <= 16'd0;
				skid_overflow <= 1'b0;
				sk_w_n = '0;
				sk_r_n = '0;
				fq_w_n = '0;
				fq_r_n = '0;
			end else if (active) begin
				// Push beat
				if (in_valid) begin
					if ((sk_w_n - sk_r_n) < SKID[SK_AW:0]) begin
						sk_mem[sk_w_n[SK_AW-1:0]] = in_q;
						sk_w_n = sk_w_n + 1'b1;
					end else
						skid_overflow <= 1'b1;
				end

				// Drain side → FIFO first (make room for new fold)
				if (side_n_n != 2'd0 && (fq_w_n - fq_r_n) < FIFO_DEPTH[FIFO_AW:0]) begin
					fq_d[fq_w_n[FIFO_AW-1:0]] = sd0;
					fq_a[fq_w_n[FIFO_AW-1:0]] = sa0;
					fq_w_n = fq_w_n + 1'b1;
					sd0 = sd1;
					sa0 = sa1;
					side_n_n = side_n_n - 2'd1;
				end

				// Fold one skid beat if side empty
				if (side_n_n == 2'd0 && (sk_w_n != sk_r_n)) begin
					beat = sk_mem[sk_r_n[SK_AW-1:0]];
					sk_r_n = sk_r_n + 1'b1;
					n_acc = acc;
					n_fill = fill;
					n_widx = widx;
					n_side = 2'd0;
					e0d = 40'd0; e1d = 40'd0;
					e0a = '0; e1a = '0;
					for (bi = 0; bi < 8; bi = bi + 1) begin
						nb = beat[bi*8 +: 8];
						n_acc = n_acc | ({{32{1'b0}}, nb} << (8 * n_fill));
						n_fill = n_fill + 3'd1;
						if (n_fill == 3'd5) begin
							if (n_side == 2'd0) begin
								e0d = n_acc; e0a = n_widx; n_side = 2'd1;
							end else begin
								e1d = n_acc; e1a = n_widx; n_side = 2'd2;
							end
							n_widx = n_widx + 1'b1;
							n_acc = 40'd0;
							n_fill = 3'd0;
						end
					end
					acc <= n_acc;
					fill <= n_fill;
					widx <= n_widx;
					sd0 = e0d; sa0 = e0a;
					sd1 = e1d; sa1 = e1a;
					side_n_n = n_side;
				end

				// FIFO → out
				if (fq_w_n != fq_r_n) begin
					out_valid <= 1'b1;
					out_data <= fq_d[fq_r_n[FIFO_AW-1:0]];
					out_addr <= fq_a[fq_r_n[FIFO_AW-1:0]];
					fq_r_n = fq_r_n + 1'b1;
					did_out = 1'b1;
					if (words_out + 16'd1 == 16'(NWORDS)) begin
						line_done <= 1'b1;
						active <= 1'b0;
					end
					words_out <= words_out + 16'd1;
				end
			end

			sk_w <= sk_w_n;
			sk_r <= sk_r_n;
			fq_w <= fq_w_n;
			fq_r <= fq_r_n;
			side_n <= side_n_n;
			side_d0 <= sd0;
			side_d1 <= sd1;
			side_a0 <= sa0;
			side_a1 <= sa1;
		end
	end
endmodule
