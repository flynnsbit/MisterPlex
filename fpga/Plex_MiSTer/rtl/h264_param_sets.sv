// Parameter set storage, indexed by pic_parameter_set_id / seq_parameter_set_id.
//
// A stream may carry several parameter sets and switch between them per
// slice, and it is entirely legal for none of them to use id 0. Latching
// "the most recently parsed PPS" and handing that to the slice header parser
// is wrong the moment a stream interleaves two: the slice would be parsed
// against a PPS it does not reference, which changes whether the deblocking
// offsets are even present in the bitstream and therefore desyncs every bit
// after them.
//
// Storage is a small fully-associative table rather than a 256-deep RAM.
// Real streams use a handful of ids, the records are narrow, and the slice
// header parser needs the lookup to be COMBINATIONAL: it discovers the id it
// wants part-way through its own bit walk and must latch the matching PPS in
// that same cycle to keep parsing. A registered M10K read cannot do that
// without stalling the walk.
//
// Replacement is: overwrite the entry with the same id if present, else take
// the first free entry, else round-robin. Re-transmitted parameter sets are
// the common case and must update in place, not evict something else.
//
// The PPS record carries its seq_parameter_set_id, so selecting a PPS also
// selects the SPS -- sps_sel_* follows pps_sel_id automatically.

`default_nettype none

module h264_param_sets #(
	parameter int NUM_PPS = 4,
	parameter int NUM_SPS = 2
)(
	input  wire        clk,
	input  wire        reset,

	// ── SPS write port (from sps_parser) ─────────────────────────────
	input  wire        sps_wr,
	input  wire [7:0]  sps_wr_id,
	input  wire [15:0] sps_wr_width,
	input  wire [15:0] sps_wr_height,
	input  wire [7:0]  sps_wr_mb_width,
	input  wire [7:0]  sps_wr_mb_height,
	input  wire [4:0]  sps_wr_log2_max_frame_num,
	input  wire [2:0]  sps_wr_poc_type,

	// ── PPS write port (from pps_parser) ─────────────────────────────
	input  wire        pps_wr,
	input  wire [7:0]  pps_wr_id,
	input  wire [7:0]  pps_wr_sps_id,
	input  wire        pps_wr_bottom_field_pic_order_present,
	input  wire [7:0]  pps_wr_num_ref_l0,
	input  wire [7:0]  pps_wr_num_ref_l1,
	input  wire        pps_wr_weighted_pred,
	input  wire [1:0]  pps_wr_weighted_bipred_idc,
	input  wire signed [7:0] pps_wr_pic_init_qp,
	input  wire signed [7:0] pps_wr_pic_init_qs,
	input  wire signed [4:0] pps_wr_chroma_qp_index_offset,
	input  wire        pps_wr_deblock_ctrl,
	input  wire        pps_wr_constrained_intra_pred,
	input  wire        pps_wr_redundant_pic_cnt_present,

	// ── PPS lookup (combinational, by id) ────────────────────────────
	input  wire [7:0]  pps_sel_id,
	output wire        pps_sel_found,
	output wire [7:0]  pps_sel_sps_id,
	output wire        pps_sel_bottom_field_pic_order_present,
	output wire [7:0]  pps_sel_num_ref_l0,
	output wire [7:0]  pps_sel_num_ref_l1,
	output wire        pps_sel_weighted_pred,
	output wire [1:0]  pps_sel_weighted_bipred_idc,
	output wire signed [7:0] pps_sel_pic_init_qp,
	output wire signed [7:0] pps_sel_pic_init_qs,
	output wire signed [4:0] pps_sel_chroma_qp_index_offset,
	output wire        pps_sel_deblock_ctrl,
	output wire        pps_sel_constrained_intra_pred,
	output wire        pps_sel_redundant_pic_cnt_present,

	// ── SPS lookup, following the selected PPS ───────────────────────
	output wire        sps_sel_found,
	output wire [15:0] sps_sel_width,
	output wire [15:0] sps_sel_height,
	output wire [7:0]  sps_sel_mb_width,
	output wire [7:0]  sps_sel_mb_height,
	output wire [4:0]  sps_sel_log2_max_frame_num,
	output wire [2:0]  sps_sel_poc_type,

	// ── Status ───────────────────────────────────────────────────────
	output wire        any_pps_valid,
	output wire        any_sps_valid,
	output reg  [7:0]  pps_count,
	output reg  [7:0]  sps_count
);
	// ── PPS table ────────────────────────────────────────────────────
	reg        p_val  [0:NUM_PPS-1];
	reg [7:0]  p_id   [0:NUM_PPS-1];
	reg [7:0]  p_sps  [0:NUM_PPS-1];
	reg        p_bfpo [0:NUM_PPS-1];
	reg [7:0]  p_nr0  [0:NUM_PPS-1];
	reg [7:0]  p_nr1  [0:NUM_PPS-1];
	reg        p_wp   [0:NUM_PPS-1];
	reg [1:0]  p_wbi  [0:NUM_PPS-1];
	reg signed [7:0] p_qp [0:NUM_PPS-1];
	reg signed [7:0] p_qs [0:NUM_PPS-1];
	reg signed [4:0] p_cqo [0:NUM_PPS-1];
	reg        p_db   [0:NUM_PPS-1];
	reg        p_cip  [0:NUM_PPS-1];
	reg        p_rpc  [0:NUM_PPS-1];
	reg [7:0]  p_rr;

	// ── SPS table ────────────────────────────────────────────────────
	reg        s_val  [0:NUM_SPS-1];
	reg [7:0]  s_id   [0:NUM_SPS-1];
	reg [15:0] s_w    [0:NUM_SPS-1];
	reg [15:0] s_h    [0:NUM_SPS-1];
	reg [7:0]  s_mbw  [0:NUM_SPS-1];
	reg [7:0]  s_mbh  [0:NUM_SPS-1];
	reg [4:0]  s_l2fn [0:NUM_SPS-1];
	reg [2:0]  s_poc  [0:NUM_SPS-1];
	reg [7:0]  s_rr;

	integer i;

	// ── Write slot selection ─────────────────────────────────────────
	// Same-id hit wins so a re-sent parameter set updates in place. Then a
	// free slot. Only when both fail do we evict, round-robin.
	function automatic [7:0] pps_slot;
		input [7:0] want;
		integer k;
		reg [7:0] hit, free;
		begin
			hit = 8'hFF;
			free = 8'hFF;
			for (k = NUM_PPS - 1; k >= 0; k = k - 1) begin
				if (p_val[k] && (p_id[k] == want)) hit = k[7:0];
				else if (!p_val[k]) free = k[7:0];
			end
			pps_slot = (hit != 8'hFF) ? hit : (free != 8'hFF) ? free : p_rr;
		end
	endfunction

	function automatic [7:0] sps_slot;
		input [7:0] want;
		integer k;
		reg [7:0] hit, free;
		begin
			hit = 8'hFF;
			free = 8'hFF;
			for (k = NUM_SPS - 1; k >= 0; k = k - 1) begin
				if (s_val[k] && (s_id[k] == want)) hit = k[7:0];
				else if (!s_val[k]) free = k[7:0];
			end
			sps_slot = (hit != 8'hFF) ? hit : (free != 8'hFF) ? free : s_rr;
		end
	endfunction

	wire [7:0] pps_wslot = pps_slot(pps_wr_id);
	wire [7:0] sps_wslot = sps_slot(sps_wr_id);

	always @(posedge clk) begin
		if (reset) begin
			for (i = 0; i < NUM_PPS; i = i + 1) p_val[i] <= 1'b0;
			for (i = 0; i < NUM_SPS; i = i + 1) s_val[i] <= 1'b0;
			p_rr <= 8'd0;
			s_rr <= 8'd0;
			pps_count <= 8'd0;
			sps_count <= 8'd0;
		end else begin
			if (pps_wr) begin
				p_val[pps_wslot]  <= 1'b1;
				p_id[pps_wslot]   <= pps_wr_id;
				p_sps[pps_wslot]  <= pps_wr_sps_id;
				p_bfpo[pps_wslot] <= pps_wr_bottom_field_pic_order_present;
				p_nr0[pps_wslot]  <= pps_wr_num_ref_l0;
				p_nr1[pps_wslot]  <= pps_wr_num_ref_l1;
				p_wp[pps_wslot]   <= pps_wr_weighted_pred;
				p_wbi[pps_wslot]  <= pps_wr_weighted_bipred_idc;
				p_qp[pps_wslot]   <= pps_wr_pic_init_qp;
				p_qs[pps_wslot]   <= pps_wr_pic_init_qs;
				p_cqo[pps_wslot]  <= pps_wr_chroma_qp_index_offset;
				p_db[pps_wslot]   <= pps_wr_deblock_ctrl;
				p_cip[pps_wslot]  <= pps_wr_constrained_intra_pred;
				p_rpc[pps_wslot]  <= pps_wr_redundant_pic_cnt_present;
				if (!p_val[pps_wslot]) pps_count <= pps_count + 8'd1;
				if (pps_wslot == p_rr)
					p_rr <= (p_rr == (NUM_PPS[7:0] - 8'd1)) ? 8'd0 : (p_rr + 8'd1);
			end
			if (sps_wr) begin
				s_val[sps_wslot]  <= 1'b1;
				s_id[sps_wslot]   <= sps_wr_id;
				s_w[sps_wslot]    <= sps_wr_width;
				s_h[sps_wslot]    <= sps_wr_height;
				s_mbw[sps_wslot]  <= sps_wr_mb_width;
				s_mbh[sps_wslot]  <= sps_wr_mb_height;
				s_l2fn[sps_wslot] <= sps_wr_log2_max_frame_num;
				s_poc[sps_wslot]  <= sps_wr_poc_type;
				if (!s_val[sps_wslot]) sps_count <= sps_count + 8'd1;
				if (sps_wslot == s_rr)
					s_rr <= (s_rr == (NUM_SPS[7:0] - 8'd1)) ? 8'd0 : (s_rr + 8'd1);
			end
		end
	end

	// ── Combinational lookup ─────────────────────────────────────────
	// Priority encode down so the lowest matching slot wins; ties cannot
	// happen because writes update the same-id slot in place.
	function automatic [7:0] pps_find;
		input [7:0] want;
		integer k;
		reg [7:0] hit;
		begin
			hit = 8'hFF;
			for (k = NUM_PPS - 1; k >= 0; k = k - 1)
				if (p_val[k] && (p_id[k] == want)) hit = k[7:0];
			pps_find = hit;
		end
	endfunction

	function automatic [7:0] sps_find;
		input [7:0] want;
		integer k;
		reg [7:0] hit;
		begin
			hit = 8'hFF;
			for (k = NUM_SPS - 1; k >= 0; k = k - 1)
				if (s_val[k] && (s_id[k] == want)) hit = k[7:0];
			sps_find = hit;
		end
	endfunction

	wire [7:0] pfound = pps_find(pps_sel_id);
	wire [7:0] psel = (pfound == 8'hFF) ? 8'd0 : pfound;

	assign pps_sel_found = (pfound != 8'hFF);
	assign pps_sel_sps_id = p_sps[psel];
	assign pps_sel_bottom_field_pic_order_present = p_bfpo[psel];
	assign pps_sel_num_ref_l0 = p_nr0[psel];
	assign pps_sel_num_ref_l1 = p_nr1[psel];
	assign pps_sel_weighted_pred = p_wp[psel];
	assign pps_sel_weighted_bipred_idc = p_wbi[psel];
	assign pps_sel_pic_init_qp = p_qp[psel];
	assign pps_sel_pic_init_qs = p_qs[psel];
	assign pps_sel_chroma_qp_index_offset = p_cqo[psel];
	assign pps_sel_deblock_ctrl = p_db[psel];
	assign pps_sel_constrained_intra_pred = p_cip[psel];
	assign pps_sel_redundant_pic_cnt_present = p_rpc[psel];

	wire [7:0] sfound = sps_find(pps_sel_sps_id);
	wire [7:0] ssel = (sfound == 8'hFF) ? 8'd0 : sfound;

	assign sps_sel_found = pps_sel_found && (sfound != 8'hFF);
	assign sps_sel_width = s_w[ssel];
	assign sps_sel_height = s_h[ssel];
	assign sps_sel_mb_width = s_mbw[ssel];
	assign sps_sel_mb_height = s_mbh[ssel];
	assign sps_sel_log2_max_frame_num = s_l2fn[ssel];
	assign sps_sel_poc_type = s_poc[ssel];

	assign any_pps_valid = (pps_count != 8'd0);
	assign any_sps_valid = (sps_count != 8'd0);
endmodule

`default_nettype wire
