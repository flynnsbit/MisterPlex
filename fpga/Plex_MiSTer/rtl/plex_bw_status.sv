// plex_bw_status — noprune fabric stamp of the agreed 720p BW contract.
// CONSUMES misterplex_bw_contract.svh / P720 aliases — not QIP-only dead code.
// Headline: 33_177_600 B/s per direction. NACK DE-peak 3.0 as DDR.
// claim_split: accepted-request delta OBSERVED/CLOSED; PPC2 delivery OPEN; fabric BW OPEN.
// Include is INSIDE the module so P720_* localparams are module-local (rd-duck scope).

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
	// Module-local contract expand (no global include guard on .svh).
	`include "plex_720p_bw_contract.svh"

	// Live loads from shared contract (not independent magic numbers).
	(* noprune *) reg [31:0] r_dir_bps = 32'd0;
	(* noprune *) reg [17:0] r_beats   = 18'd0;
	(* noprune *) reg [18:0] r_rw      = 19'd0;
	(* noprune *) reg [7:0]  r_ppc     = 8'd0;
	(* noprune *) reg        r_nack    = 1'b1;
	(* noprune *) reg [15:0] r_tcopy   = 16'd0;
	(* noprune *) reg [15:0] r_budget  = 16'd0;

	always @(posedge clk) begin
		r_dir_bps <= P720_FABRIC_RD_BPS[31:0];
		r_beats   <= P720_BEATS_PER_FRAME[17:0];
		r_rw      <= P720_BEATS_RW_PAIR[18:0];
		r_ppc     <= P720_PPC[7:0];
		r_nack    <= (P720_NACK_DE_PEAK_E1 == 30);
		r_tcopy   <= P720_HOST_COPY_US[15:0];
		r_budget  <= P720_FRAME_US[15:0];
	end

	assign bw_dir_b_per_s             = r_dir_bps;
	assign bw_beats_per_frame         = r_beats;
	assign bw_beats_rw_pair           = r_rw;
	assign bw_product_ppc             = r_ppc;
	assign bw_nack_de_peak_is_not_ddr = r_nack;
	assign bw_t_copy_arm_us           = r_tcopy;
	assign bw_frame_budget_us         = r_budget;

	// Synthesis-ACTIVE gates (rd-duck: dead localparams ≠ fabric work).
	generate
		if (P720_FABRIC_RD_BPS != 33_177_600) begin : g_bwstat_bps
			p720_bw_contract_rd_bps_must_be_33177600 u_bwstat_bps();
		end
		if (P720_BEATS_PER_FRAME != 172_800) begin : g_bwstat_beats
			p720_bw_contract_beats_must_be_172800 u_bwstat_beats();
		end
		if (P720_I420_BYTES != 1_382_400) begin : g_bwstat_i420
			p720_bw_contract_i420_must_be_1382400 u_bwstat_i420();
		end
	endgenerate

	// synthesis translate_off
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
		if (MISTERPLEX_BW_T_COPY_ARM_US >= MISTERPLEX_BW_FRAME_BUDGET_US)
			$error("plex_bw_status: T_copy_arm must be < frame budget (units check)");
		if (MISTERPLEX_BW_T_COPY_ARM_US <= 8962)
			$error("plex_bw_status: T_copy_arm must reflect parent 14.978 ms");
	end
	// synthesis translate_on
endmodule
