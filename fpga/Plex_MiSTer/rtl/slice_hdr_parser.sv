// Phase 3.3d: Baseline slice_header for IDR / I-slice (poc_type != 1).

module slice_hdr_parser (
	input  wire        clk,
	input  wire        reset,

	input  wire        cap_clear,
	input  wire        cap_en,
	input  wire [7:0]  cap_data,
	input  wire        cap_end,
	input  wire        is_idr_nal,         // nal_unit_type == 5
	input  wire [4:0]  log2_max_frame_num, // from SPS
	input  wire [2:0]  poc_type,           // from SPS; type1 unsupported
	input  wire        sps_ready,

	output reg         valid,
	output reg  [15:0] first_mb,
	output reg  [7:0]  slice_type,
	output reg  [7:0]  pps_id,
	output reg  [15:0] frame_num,
	output reg  [15:0] idr_pic_id,
	output reg         is_i_slice,
	output reg         busy
);

	localparam int MAXB = 32;
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
	reg        idr_lat;
	reg [4:0]  log2_lat;

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
		ST_DONE    = 5'd9,
		ST_FAIL    = 5'd10;

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
			bbyte <= 0;
			bpos <= 3'd7;
			zcnt <= 0;
			nleft <= 0;
			acc <= 0;
			ue_val <= 0;
			cont <= ST_IDLE;
			ue_cont <= ST_IDLE;
			idr_lat <= 0;
			log2_lat <= 5'd4;
		end else begin
			case (st)
			ST_IDLE: begin
				busy <= 0;
				if (cap_end && len >= 6'd1 && sps_ready && poc_type != 3'd1) begin
					busy <= 1'b1;
					idr_lat <= is_idr_nal;
					log2_lat <= (log2_max_frame_num == 0) ? 5'd4 : log2_max_frame_num;
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
				end else
					st <= ST_DONE;
			end
			ST_IDR: begin
				idr_pic_id <= ue_val;
				st <= ST_DONE;
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
