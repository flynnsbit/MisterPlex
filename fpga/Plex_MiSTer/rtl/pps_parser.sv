// Baseline picture parameter set parser (NAL unit type 8).
//
// Parses every field of pic_parameter_set_rbsp() in order and exports the
// ones the reconstruction path consumes. Reading the whole set in order
// matters even for fields nothing uses: exp-Golomb is self-delimiting only
// if you actually consume each element, so skipping one desyncs everything
// after it.
//
// Baseline restrictions we enforce rather than mis-decode:
//   entropy_coding_mode_flag == 1  -> CABAC, which this decoder cannot do.
//   num_slice_groups_minus1 > 0    -> FMO, which this decoder cannot do.
// Both raise `unsupported` and suppress `valid` instead of emitting a
// parameter set that would silently produce garbage.
//
// `wr_pulse` is a one-cycle strobe for the id-indexed parameter set store;
// `valid` stays sticky as a "we have at least one usable PPS" ready flag.

module pps_parser (
	input  wire        clk,
	input  wire        reset,

	input  wire        cap_clear,
	input  wire        cap_en,
	input  wire [7:0]  cap_data,
	input  wire        cap_end,

	output reg         valid,
	output reg         wr_pulse,
	output reg  [7:0]  pps_id,
	output reg  [7:0]  sps_id,

	output reg         entropy_cabac,
	output reg         bottom_field_pic_order_present,
	output reg  [7:0]  num_slice_groups_minus1,
	output reg  [7:0]  num_ref_l0,           // num_ref_idx_l0_default_active_minus1
	output reg  [7:0]  num_ref_l1,           // num_ref_idx_l1_default_active_minus1
	output reg         weighted_pred,
	output reg  [1:0]  weighted_bipred_idc,
	output reg  signed [7:0] pic_init_qp,    // 26 + pic_init_qp_minus26
	output reg  signed [7:0] pic_init_qs,    // 26 + pic_init_qs_minus26
	output reg  signed [4:0] chroma_qp_index_offset,
	output reg         deblock_ctrl,         // deblocking_filter_control_present_flag
	output reg         constrained_intra_pred,
	output reg         redundant_pic_cnt_present,

	output reg         unsupported,          // CABAC or multiple slice groups seen
	output reg         parse_fail,
	output reg         busy
);

	localparam int MAXB = 24;
	reg [7:0] mem [0:MAXB-1];
	reg [4:0] len;

	reg [4:0] bbyte;
	reg [2:0] bpos;
	wire [7:0] cur = mem[bbyte];
	wire bitv = cur[bpos];
	wire oob = (bbyte >= len);

	reg [4:0] st, cont, ue_cont;
	reg [5:0] zcnt;
	reg [4:0] nleft;
	reg [15:0] acc, ue_val;

	localparam [4:0]
		ST_IDLE    = 5'd0,
		ST_GETBITS = 5'd1,
		ST_UE_Z    = 5'd2,
		ST_UE_V    = 5'd3,
		ST_PPSID   = 5'd4,
		ST_SPSID   = 5'd5,
		ST_ENT     = 5'd6,
		ST_BOT     = 5'd7,
		ST_SG      = 5'd8,
		ST_NRL0    = 5'd9,
		ST_NRL1    = 5'd10,
		ST_WP      = 5'd11,
		ST_WBI     = 5'd12,
		ST_QP      = 5'd13,
		ST_QS      = 5'd14,
		ST_CHR     = 5'd15,
		ST_DB      = 5'd16,
		ST_CI      = 5'd17,
		ST_RED     = 5'd18,
		ST_DONE    = 5'd19,
		ST_FAIL    = 5'd20;

	function automatic signed [7:0] se_of;
		input [15:0] k;
		begin
			if (k[0] == 1'b0)
				se_of = -$signed({1'b0, k[7:1]});
			else
				se_of = $signed({1'b0, k[7:1]}) + 8'sd1;
		end
	endfunction

	wire signed [7:0] se_now = se_of(ue_val);

	always @(posedge clk) begin
		if (reset || cap_clear)
			len <= 0;
		else if (cap_en && len < MAXB[4:0]) begin
			mem[len] <= cap_data;
			len <= len + 1'd1;
		end
	end

	always @(posedge clk) begin
		if (reset) begin
			st <= ST_IDLE;
			valid <= 0;
			wr_pulse <= 0;
			busy <= 0;
			pps_id <= 0;
			sps_id <= 0;
			entropy_cabac <= 0;
			bottom_field_pic_order_present <= 0;
			num_slice_groups_minus1 <= 0;
			num_ref_l0 <= 0;
			num_ref_l1 <= 0;
			weighted_pred <= 0;
			weighted_bipred_idc <= 0;
			pic_init_qp <= 8'sd26;
			pic_init_qs <= 8'sd26;
			chroma_qp_index_offset <= 5'sd0;
			deblock_ctrl <= 0;
			constrained_intra_pred <= 0;
			redundant_pic_cnt_present <= 0;
			unsupported <= 0;
			parse_fail <= 0;
			bbyte <= 0;
			bpos <= 3'd7;
			zcnt <= 0;
			nleft <= 0;
			acc <= 0;
			ue_val <= 0;
			cont <= ST_IDLE;
			ue_cont <= ST_IDLE;
		end else begin
			wr_pulse <= 1'b0;
			case (st)
			ST_IDLE: begin
				busy <= 0;
				if (cap_end && len >= 5'd2) begin
					busy <= 1'b1;
					bbyte <= 0;
					bpos <= 3'd7;
					zcnt <= 0;
					ue_cont <= ST_PPSID;
					st <= ST_UE_Z;
				end
			end

			ST_GETBITS: begin
				if (oob) st <= ST_FAIL;
				else begin
					acc <= {acc[14:0], bitv};
					if (bpos == 3'd0) begin bpos <= 3'd7; bbyte <= bbyte + 1'd1; end
					else bpos <= bpos - 1'd1;
					if (nleft == 5'd1) st <= cont;
					else nleft <= nleft - 1'd1;
				end
			end

			ST_UE_Z: begin
				if (oob) st <= ST_FAIL;
				else if (bitv == 1'b0) begin
					if (zcnt >= 6'd16) st <= ST_FAIL;
					else begin
						zcnt <= zcnt + 1'd1;
						if (bpos == 3'd0) begin bpos <= 3'd7; bbyte <= bbyte + 1'd1; end
						else bpos <= bpos - 1'd1;
					end
				end else begin
					if (bpos == 3'd0) begin bpos <= 3'd7; bbyte <= bbyte + 1'd1; end
					else bpos <= bpos - 1'd1;
					if (zcnt == 0) begin ue_val <= 0; st <= ue_cont; end
					else begin
						nleft <= zcnt[4:0]; acc <= 0; cont <= ST_UE_V; st <= ST_GETBITS;
					end
				end
			end

			ST_UE_V: begin
				ue_val <= ((16'd1 << zcnt) - 16'd1) + acc;
				st <= ue_cont;
			end

			// Each state below consumes the element that was just read and
			// launches the read for the next one, so the state name lags the
			// syntax element by one step.
			ST_PPSID: begin
				pps_id <= ue_val[7:0];
				zcnt <= 0; ue_cont <= ST_SPSID; st <= ST_UE_Z;
			end
			ST_SPSID: begin
				sps_id <= ue_val[7:0];
				nleft <= 5'd1; acc <= 0; cont <= ST_ENT; st <= ST_GETBITS;
			end
			ST_ENT: begin
				entropy_cabac <= acc[0];
				nleft <= 5'd1; acc <= 0; cont <= ST_BOT; st <= ST_GETBITS;
			end
			ST_BOT: begin
				bottom_field_pic_order_present <= acc[0];
				zcnt <= 0; ue_cont <= ST_SG; st <= ST_UE_Z;
			end
			ST_SG: begin
				num_slice_groups_minus1 <= ue_val[7:0];
				// slice_group_map_type and its payload only exist when there is
				// more than one slice group. We cannot decode FMO, and we also
				// cannot skip a payload whose length depends on fields we do not
				// model, so stop here rather than desync on the rest of the PPS.
				if (ue_val != 0) st <= ST_FAIL;
				else begin zcnt <= 0; ue_cont <= ST_NRL0; st <= ST_UE_Z; end
			end
			ST_NRL0: begin
				num_ref_l0 <= ue_val[7:0];
				zcnt <= 0; ue_cont <= ST_NRL1; st <= ST_UE_Z;
			end
			ST_NRL1: begin
				num_ref_l1 <= ue_val[7:0];
				nleft <= 5'd1; acc <= 0; cont <= ST_WP; st <= ST_GETBITS;
			end
			ST_WP: begin
				weighted_pred <= acc[0];
				nleft <= 5'd2; acc <= 0; cont <= ST_WBI; st <= ST_GETBITS;
			end
			ST_WBI: begin
				weighted_bipred_idc <= acc[1:0];
				zcnt <= 0; ue_cont <= ST_QP; st <= ST_UE_Z;
			end
			ST_QP: begin
				pic_init_qp <= 8'sd26 + se_now;
				zcnt <= 0; ue_cont <= ST_QS; st <= ST_UE_Z;
			end
			ST_QS: begin
				pic_init_qs <= 8'sd26 + se_now;
				zcnt <= 0; ue_cont <= ST_CHR; st <= ST_UE_Z;
			end
			ST_CHR: begin
				// se(v), legal range [-12, +12].
				chroma_qp_index_offset <= (se_now < -8'sd12) ? -5'sd12 :
				                          (se_now >  8'sd12) ?  5'sd12 :
				                          se_now[4:0];
				nleft <= 5'd1; acc <= 0; cont <= ST_DB; st <= ST_GETBITS;
			end
			ST_DB: begin
				deblock_ctrl <= acc[0];
				nleft <= 5'd1; acc <= 0; cont <= ST_CI; st <= ST_GETBITS;
			end
			ST_CI: begin
				constrained_intra_pred <= acc[0];
				nleft <= 5'd1; acc <= 0; cont <= ST_RED; st <= ST_GETBITS;
			end
			ST_RED: begin
				redundant_pic_cnt_present <= acc[0];
				st <= ST_DONE;
			end
			ST_DONE: begin
				busy <= 0;
				st <= ST_IDLE;
				if (entropy_cabac)
					unsupported <= 1'b1;
				else begin
					valid <= 1'b1;
					wr_pulse <= 1'b1;
				end
			end
			ST_FAIL: begin
				busy <= 0;
				parse_fail <= 1'b1;
				if (num_slice_groups_minus1 != 8'd0)
					unsupported <= 1'b1;
				st <= ST_IDLE;
			end
			default: st <= ST_IDLE;
			endcase
		end
	end

endmodule
