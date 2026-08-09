`default_nettype none
// Macroblock reconstruction routing for Baseline CAVLC.
//
// One macroblock arrives per mb_type_valid pulse. This decides which
// reconstruction engine owns it:
//
//   ROUTE_INTRA16  I_16x16, any of the four prediction modes. DC (mode 2) is
//                  the only one this integration reconstructs standalone; the
//                  rest still fall through to the I_NxN/decode_top datapath.
//   ROUTE_INTRA4   I_NxN (mb_type 0). Owned by h264_decode_top.
//   ROUTE_PSKIP    P_Skip, driven by mb_skip_run rather than a coded mb_type.
//   ROUTE_P16      P_L0_16x16 (mb_type 0 in a P slice).
//   ROUTE_OTHER    everything else (P16x8 / P8x16 / P8x8 / I_PCM). Not yet
//                  reconstructed; `unsupported` flags it for the caller.
//
// The I-slice mb_type table (clause 7.4.5, Table 7-11) packs three fields into
// mb_type 1..24 for I_16x16:
//   n = mb_type - 1
//   i16_pred_mode = n % 4          0=V, 1=H, 2=DC, 3=Plane
//   cbp_chroma    = (n / 4) % 3    0=none, 1=DC only, 2=DC+AC
//   cbp_luma_ac   = n >= 12        AC coefficients present in all 16 blocks
// mb_type 0 is I_NxN, mb_type 25 is I_PCM.
//
// In a P slice the intra types are the same table shifted by 5, so mb_type 5
// there means I_NxN and 6..29 mean I_16x16 (clause 7.4.5, Table 7-13).
//
// DEBLOCKING NOTE: a P_Skip macroblock carries no residual and no coded
// coefficients, but it is still filtered by the deblocking filter (clause
// 8.7 has no skip exemption -- bS is derived from motion vectors and reference
// indices, which a skipped MB still has). A future deblocking filter must walk
// every macroblock including the ones routed to ROUTE_PSKIP here.

module h264_mb_recon_route (
	input  wire        slice_is_i,      // I or IDR slice
	input  wire        mb_is_skip,      // from h264_mb_skip_run_track
	input  wire [5:0]  mb_type,         // raw mb_type for the current slice type

	output reg  [2:0]  route,
	output reg  [2:0]  part_mode,       // 0=16x16, 1=16x8, 2=8x16, 3=8x8
	output reg  [5:0]  norm_mb_type,    // intra mb_type normalised to I-slice numbering
	output reg  [1:0]  i16_pred_mode,
	output reg  [1:0]  cbp_chroma,
	output reg         cbp_luma_ac,
	output reg         is_intra,
	output reg         is_inter,
	output reg         unsupported
);
	localparam [2:0] ROUTE_OTHER   = 3'd0;
	localparam [2:0] ROUTE_INTRA4  = 3'd1;
	localparam [2:0] ROUTE_INTRA16 = 3'd2;
	localparam [2:0] ROUTE_PSKIP   = 3'd3;
	localparam [2:0] ROUTE_P16     = 3'd4;
	// Multi-partition inter macroblocks: P_L0_L0_16x8, P_L0_L0_8x16 and
	// P_8x8 / P_8x8ref0, which reconstruct partition by partition.
	localparam [2:0] ROUTE_PPART   = 3'd5;

	// Intra type base offset: 0 in an I slice, 5 in a P slice.
	wire [5:0] intra_base = slice_is_i ? 6'd0 : 6'd5;
	wire       intra_range = (mb_type >= intra_base) && (mb_type <= (intra_base + 6'd25));
	wire [5:0] intra_type = mb_type - intra_base;
	wire       is_i_nxn = intra_range && (intra_type == 6'd0);
	wire       is_i_pcm = intra_range && (intra_type == 6'd25);
	wire       is_i16 = intra_range && (intra_type >= 6'd1) && (intra_type <= 6'd24);

	wire [5:0] i16_n = intra_type - 6'd1;      // 0..23
	// n % 4 and (n / 4) % 3 without a divider: n <= 23 so a small table on the
	// upper bits is cheaper and keeps the fitter from inferring a divide.
	wire [3:0] i16_group = i16_n[5:2];         // 0..5
	wire [1:0] i16_mode_bits = i16_n[1:0];
	reg  [1:0] i16_cbp_chroma;
	reg        i16_cbp_luma_ac;
	always @* begin
		case (i16_group)
		4'd0: begin i16_cbp_chroma = 2'd0; i16_cbp_luma_ac = 1'b0; end
		4'd1: begin i16_cbp_chroma = 2'd1; i16_cbp_luma_ac = 1'b0; end
		4'd2: begin i16_cbp_chroma = 2'd2; i16_cbp_luma_ac = 1'b0; end
		4'd3: begin i16_cbp_chroma = 2'd0; i16_cbp_luma_ac = 1'b1; end
		4'd4: begin i16_cbp_chroma = 2'd1; i16_cbp_luma_ac = 1'b1; end
		4'd5: begin i16_cbp_chroma = 2'd2; i16_cbp_luma_ac = 1'b1; end
		default: begin i16_cbp_chroma = 2'd0; i16_cbp_luma_ac = 1'b0; end
		endcase
	end

	// P-slice inter types. mb_type 0 is P_L0_16x16, 1/2 are the two-partition
	// splits, 3/4 are the 8x8 forms. Only 16x16 has a reconstruction path.
	wire p_is_16x16 = !slice_is_i && !mb_is_skip && (mb_type == 6'd0);
	wire p_is_part  = !slice_is_i && !mb_is_skip &&
	                  (mb_type >= 6'd1) && (mb_type <= 6'd4);

	always @* begin
		route = ROUTE_OTHER;
		part_mode = 3'd0;
		// An intra macroblock inside a P slice carries mb_type 5..30. Strip the
		// offset so the intra reconstruction path only ever sees I-slice
		// numbering and does not need to know the slice type.
		norm_mb_type = intra_range ? intra_type : mb_type;
		i16_pred_mode = 2'd0;
		cbp_chroma = 2'd0;
		cbp_luma_ac = 1'b0;
		is_intra = 1'b0;
		is_inter = 1'b0;
		unsupported = 1'b0;

		if (!slice_is_i && mb_is_skip) begin
			// P_Skip is signalled by mb_skip_run, not by a coded mb_type, so it
			// wins over whatever mb_type happens to be presented.
			route = ROUTE_PSKIP;
			is_inter = 1'b1;
		end else if (is_i16) begin
			route = ROUTE_INTRA16;
			i16_pred_mode = i16_mode_bits;
			cbp_chroma = i16_cbp_chroma;
			cbp_luma_ac = i16_cbp_luma_ac;
			is_intra = 1'b1;
		end else if (is_i_nxn) begin
			route = ROUTE_INTRA4;
			is_intra = 1'b1;
		end else if (is_i_pcm) begin
			route = ROUTE_OTHER;
			is_intra = 1'b1;
			unsupported = 1'b1;
		end else if (p_is_16x16) begin
			route = ROUTE_P16;
			is_inter = 1'b1;
		end else if (p_is_part) begin
			route = ROUTE_PPART;
			// mb_type 1 -> 16x8, 2 -> 8x16, 3/4 -> 8x8 with sub-partitions.
			part_mode = (mb_type == 6'd1) ? 3'd1 :
			            (mb_type == 6'd2) ? 3'd2 : 3'd3;
			is_inter = 1'b1;
		end else begin
			route = ROUTE_OTHER;
			is_inter = !slice_is_i;
			unsupported = 1'b1;
		end
	end
endmodule

`default_nettype wire
