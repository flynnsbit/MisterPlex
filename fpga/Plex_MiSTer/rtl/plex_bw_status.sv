// plex_bw_status — noprune fabric stamp of the agreed 720p BW contract.
// Survives fitting so post-fit hierarchy can prove the SoT was compiled in.
// Headline: 33_177_600 B/s per direction (= 33.1776 MB/s). NACK DE-peak 3.0 as DDR.

`include "misterplex_bw_contract.svh"

module plex_bw_status (
	input  wire        clk,
	output wire [31:0] bw_dir_b_per_s,
	output wire [17:0] bw_beats_per_frame,
	output wire [18:0] bw_beats_rw_pair,
	output wire [7:0]  bw_product_ppc,
	output wire        bw_nack_de_peak_is_not_ddr,
	output wire [15:0] bw_t_copy_arm_us,
	output wire [15:0] bw_frame_budget_us
);
	(* noprune *) reg [31:0] r_dir_bps = 32'd0;
	(* noprune *) reg [17:0] r_beats   = 18'd0;
	(* noprune *) reg [18:0] r_rw      = 19'd0;
	(* noprune *) reg [7:0]  r_ppc     = 8'd0;
	// Constant 1: DE-peak 3.0 B/clk is linebuf I420-equiv, not DDRAM design load.
	(* noprune *) reg        r_nack    = 1'b1;
	(* noprune *) reg [15:0] r_tcopy   = 16'd0;
	(* noprune *) reg [15:0] r_budget  = 16'd0;

	always @(posedge clk) begin
		r_dir_bps <= 32'd33177600;
		r_beats   <= 18'd172800;
		r_rw      <= 19'd345600;
		r_ppc     <= 8'd2;
		r_nack    <= 1'b1;
		r_tcopy   <= 16'd14978;
		r_budget  <= 16'd41667;
	end

	assign bw_dir_b_per_s             = r_dir_bps;
	assign bw_beats_per_frame         = r_beats;
	assign bw_beats_rw_pair           = r_rw;
	assign bw_product_ppc             = r_ppc;
	assign bw_nack_de_peak_is_not_ddr = r_nack;
	assign bw_t_copy_arm_us           = r_tcopy;
	assign bw_frame_budget_us         = r_budget;

	// Elab-time arithmetic lock against the shared header
	initial begin
		if (MISTERPLEX_BW_I420_B_FRAME != (1280 * 720 * 3 / 2))
			$error("plex_bw_status: I420 B_frame mismatch");
		if (MISTERPLEX_BW_DIR_B_PER_S != 33_177_600)
			$error("plex_bw_status: dir B/s must be 33177600 (33.1776 MB/s)");
		if ((MISTERPLEX_BW_BEATS_PER_FRAME * MISTERPLEX_BW_BEAT_B) != MISTERPLEX_BW_I420_B_FRAME)
			$error("plex_bw_status: beats*8 != B_frame");
		if (MISTERPLEX_BW_BEATS_RW_PAIR != (2 * MISTERPLEX_BW_BEATS_PER_FRAME))
			$error("plex_bw_status: R+W beats must be 2*frame");
		if (MISTERPLEX_BW_NACK_DE_PEAK_E1 != 30)
			$error("plex_bw_status: NACK marker missing");
		if (MISTERPLEX_BW_BEATS_PER_FRAME != 172_800)
			$error("plex_bw_status: beats_per_frame SoT drift");
		if (MISTERPLEX_BW_T_COPY_ARM_US >= MISTERPLEX_BW_FRAME_BUDGET_US)
			$error("plex_bw_status: T_copy_arm must be < frame budget (units check)");
		// Serial deficit exists: T_copy 14978 > decode headroom ~8962 — fabric DMA target.
		if (MISTERPLEX_BW_T_COPY_ARM_US <= 8962)
			$error("plex_bw_status: T_copy_arm must reflect parent 14.978 ms (not under headroom)");
	end
endmodule
