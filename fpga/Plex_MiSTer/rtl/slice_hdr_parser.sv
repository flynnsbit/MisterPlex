// Phase 3.3d/e/f: slice_header + first mb_type + CAVLC nC=0 residual token (I16 DC).
// Needs SPS (log2/poc) + PPS (deblock_ctrl, pic_init_qp).

module slice_hdr_parser (
	input  wire        clk,
	input  wire        reset,

	input  wire        cap_clear,
	input  wire        cap_en,
	input  wire [7:0]  cap_data,
	input  wire        cap_end,
	input  wire        is_idr_nal,
	input  wire [4:0]  log2_max_frame_num,
	input  wire [2:0]  poc_type,
	input  wire        sps_ready,
	input  wire        pps_ready,
	input  wire        deblock_ctrl,
	input  wire signed [7:0] pic_init_qp,

	output reg         valid,
	output reg  [15:0] first_mb,
	output reg  [7:0]  slice_type,
	output reg  [7:0]  pps_id,
	output reg  [15:0] frame_num,
	output reg  [15:0] idr_pic_id,
	output reg         is_i_slice,
	output reg  signed [7:0] slice_qp_delta,
	output reg  [5:0]  slice_qp,       // 0..51
	output reg  [7:0]  first_mb_type,
	output reg         has_mb_type,
	// 3.3f residual probe (first I_16x16 Intra16x16DCLevel, nC=0)
	output reg  [4:0]  residual_tc,
	output reg  [1:0]  residual_t1,
	output reg         residual_ok,
	output reg         busy
);

	localparam int MAXB = 48;
	reg [7:0] mem [0:MAXB-1];
	reg [5:0] len;

	reg [5:0] bbyte;
	reg [2:0] bpos;
	wire [7:0] cur = mem[bbyte];
	wire bitv = cur[bpos];
	wire oob = (bbyte >= len);

	reg [4:0] st, cont, ue_cont;
	reg [5:0] zcnt;
	reg [4:0] nleft;
	reg [15:0] acc, ue_val;
	reg        idr_lat, db_lat;
	reg [4:0]  log2_lat;
	reg signed [7:0] init_qp_lat;
	reg signed [7:0] dlt_tmp;
	reg signed [8:0] qp_tmp;
	reg [15:0] tcode;
	reg [4:0]  tbits;
	reg [4:0]  r_tc, r_t1;
	reg [2:0]  sign_left;

	function automatic signed [7:0] se_of;
		input [15:0] k;
		begin
			if (k[0] == 1'b0)
				se_of = -$signed({1'b0, k[7:1]});
			else
				se_of = $signed({1'b0, k[7:1]}) + 8'sd1;
		end
	endfunction

	localparam [4:0]
		ST_IDLE    = 5'd0,
		ST_GETBITS = 5'd1,
		ST_UE_Z    = 5'd2,
		ST_UE_V    = 5'd3,
		ST_FIRST   = 5'd4,
		ST_TYPE    = 5'd5,
		ST_PPS     = 5'd6,
		ST_FN      = 5'd7,
		ST_IDR     = 5'd8,
		ST_REFMARK = 5'd9,  // IDR dec_ref_pic_marking: 2 flags
		ST_QPD     = 5'd10,
		ST_DIDC    = 5'd11,
		ST_ALPHA   = 5'd12,
		ST_BETA    = 5'd13,
		ST_MBT     = 5'd14,
		ST_MBQP    = 5'd15,
		ST_TOK_BIT = 5'd16,
		ST_TOK_CHK = 5'd17,
		ST_SIGNS   = 5'd18,
		ST_DONE    = 5'd19,
		ST_FAIL    = 5'd20;

	always @(posedge clk) begin
		if (reset || cap_clear)
			len <= 0;
		else if (cap_en && len < MAXB[5:0]) begin
			mem[len] <= cap_data;
			len <= len + 1'd1;
		end
	end

	always @(posedge clk) begin
		if (reset) begin
			st <= ST_IDLE;
			valid <= 0;
			busy <= 0;
			first_mb <= 0;
			slice_type <= 0;
			pps_id <= 0;
			frame_num <= 0;
			idr_pic_id <= 0;
			is_i_slice <= 0;
			slice_qp_delta <= 0;
			slice_qp <= 0;
			first_mb_type <= 0;
			has_mb_type <= 0;
			residual_tc <= 0;
			residual_t1 <= 0;
			residual_ok <= 0;
			tcode <= 0;
			tbits <= 0;
			r_tc <= 0;
			r_t1 <= 0;
			sign_left <= 0;
			bbyte <= 0;
			bpos <= 3'd7;
			zcnt <= 0;
			nleft <= 0;
			acc <= 0;
			ue_val <= 0;
			cont <= ST_IDLE;
			ue_cont <= ST_IDLE;
			idr_lat <= 0;
			db_lat <= 0;
			log2_lat <= 5'd4;
			init_qp_lat <= 8'sd26;
			qp_tmp <= 0;
		end else begin
			case (st)
			ST_IDLE: begin
				busy <= 0;
				if (cap_end && len >= 6'd2 && sps_ready && pps_ready && poc_type != 3'd1) begin
					busy <= 1'b1;
					has_mb_type <= 0;
					residual_ok <= 0;
					residual_tc <= 0;
					residual_t1 <= 0;
					idr_lat <= is_idr_nal;
					db_lat <= deblock_ctrl;
					log2_lat <= (log2_max_frame_num == 0) ? 5'd4 : log2_max_frame_num;
					init_qp_lat <= pic_init_qp;
					bbyte <= 0;
					bpos <= 3'd7;
					zcnt <= 0;
					ue_cont <= ST_FIRST;
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
					if (zcnt >= 6'd20) st <= ST_FAIL;
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

			ST_FIRST: begin
				first_mb <= ue_val;
				zcnt <= 0; ue_cont <= ST_TYPE; st <= ST_UE_Z;
			end
			ST_TYPE: begin
				slice_type <= ue_val[7:0];
				is_i_slice <= (ue_val[7:0] == 8'd2) || (ue_val[7:0] == 8'd7);
				zcnt <= 0; ue_cont <= ST_PPS; st <= ST_UE_Z;
			end
			ST_PPS: begin
				pps_id <= ue_val[7:0];
				nleft <= log2_lat; acc <= 0; cont <= ST_FN; st <= ST_GETBITS;
			end
			ST_FN: begin
				frame_num <= acc;
				if (idr_lat) begin
					zcnt <= 0; ue_cont <= ST_IDR; st <= ST_UE_Z;
				end else begin
					zcnt <= 0; ue_cont <= ST_QPD; st <= ST_UE_Z;
				end
			end
			ST_IDR: begin
				idr_pic_id <= ue_val;
				// dec_ref_pic_marking (IDR): no_output_of_prior_pics + long_term_reference
				nleft <= 5'd2; acc <= 0; cont <= ST_REFMARK; st <= ST_GETBITS;
			end
			ST_REFMARK: begin
				zcnt <= 0; ue_cont <= ST_QPD; st <= ST_UE_Z;
			end
			ST_QPD: begin
				// se(slice_qp_delta); slice_qp = clamp(pic_init_qp + delta, 0, 51)
				dlt_tmp = se_of(ue_val);
				slice_qp_delta <= dlt_tmp;
				qp_tmp = init_qp_lat + dlt_tmp;
				if (qp_tmp < 0)
					slice_qp <= 6'd0;
				else if (qp_tmp > 51)
					slice_qp <= 6'd51;
				else
					slice_qp <= qp_tmp[5:0];
				if (db_lat) begin
					zcnt <= 0; ue_cont <= ST_DIDC; st <= ST_UE_Z;
				end else begin
					zcnt <= 0; ue_cont <= ST_MBT; st <= ST_UE_Z;
				end
			end
			ST_DIDC: begin
				if (ue_val != 16'd1) begin
					zcnt <= 0; ue_cont <= ST_ALPHA; st <= ST_UE_Z;
				end else begin
					zcnt <= 0; ue_cont <= ST_MBT; st <= ST_UE_Z;
				end
			end
			ST_ALPHA: begin zcnt <= 0; ue_cont <= ST_BETA; st <= ST_UE_Z; end
			ST_BETA: begin zcnt <= 0; ue_cont <= ST_MBT; st <= ST_UE_Z; end
			ST_MBT: begin
				first_mb_type <= ue_val[7:0];
				has_mb_type <= (ue_val <= 16'd25);
				// I_16x16 (1..24): mb_qp_delta then CAVLC DC residual (nC=0)
				if (ue_val >= 16'd1 && ue_val <= 16'd24) begin
					zcnt <= 0; ue_cont <= ST_MBQP; st <= ST_UE_Z;
				end else
					st <= ST_DONE;
			end
			ST_MBQP: begin
				// se(mb_qp_delta) consumed; start coeff_token nC=0
				tcode <= 0;
				tbits <= 0;
				st <= ST_TOK_BIT;
			end
			ST_TOK_BIT: begin
				if (oob) st <= ST_FAIL;
				else begin
					tcode <= {tcode[14:0], bitv};
					tbits <= tbits + 1'd1;
					if (bpos == 3'd0) begin bpos <= 3'd7; bbyte <= bbyte + 1'd1; end
					else bpos <= bpos - 1'd1;
					st <= ST_TOK_CHK;
				end
			end
			ST_TOK_CHK: begin
				// Match num-VLC0 (nC=0) common tokens including golden TC=2 T1=2 ("001")
				if (tbits == 5'd1 && tcode[0] == 1'b1) begin
					r_tc <= 0; r_t1 <= 0; residual_tc <= 0; residual_t1 <= 0;
					residual_ok <= 1'b1; st <= ST_DONE;
				end else if (tbits == 5'd2 && tcode[1:0] == 2'b01) begin
					r_tc <= 1; r_t1 <= 1; residual_tc <= 1; residual_t1 <= 2'd1;
					sign_left <= 1; st <= ST_SIGNS;
				end else if (tbits == 5'd3 && tcode[2:0] == 3'b001) begin
					// golden path for plex_real_baseline first I16 DC
					r_tc <= 2; r_t1 <= 2; residual_tc <= 2; residual_t1 <= 2'd2;
					sign_left <= 2; st <= ST_SIGNS;
				end else if (tbits == 5'd5 && tcode[4:0] == 5'b00011) begin
					r_tc <= 3; r_t1 <= 3; residual_tc <= 3; residual_t1 <= 2'd3;
					sign_left <= 3; st <= ST_SIGNS;
				end else if (tbits == 5'd6 && tcode[5:0] == 6'b000101) begin
					r_tc <= 1; r_t1 <= 0; residual_tc <= 1; residual_t1 <= 0;
					// no trailing ones; still mark token ok for probe
					residual_ok <= 1'b1; st <= ST_DONE;
				end else if (tbits == 5'd6 && tcode[5:0] == 6'b000100) begin
					r_tc <= 2; r_t1 <= 1; residual_tc <= 2; residual_t1 <= 2'd1;
					sign_left <= 1; st <= ST_SIGNS;
				end else if (tbits >= 5'd12) begin
					// token not in bring-up set — header still valid
					st <= ST_DONE;
				end else
					st <= ST_TOK_BIT;
			end
			ST_SIGNS: begin
				// Consume TrailingOnes sign bits (probe doesn't need values)
				if (oob) st <= ST_FAIL;
				else begin
					if (bpos == 3'd0) begin bpos <= 3'd7; bbyte <= bbyte + 1'd1; end
					else bpos <= bpos - 1'd1;
					if (sign_left <= 3'd1) begin
						residual_ok <= 1'b1;
						st <= ST_DONE;
					end else
						sign_left <= sign_left - 1'd1;
				end
			end
			ST_DONE: begin
				valid <= 1'b1;
				busy <= 0;
				st <= ST_IDLE;
			end
			ST_FAIL: begin
				busy <= 0;
				st <= ST_IDLE;
			end
			default: st <= ST_IDLE;
			endcase
		end
	end

endmodule
