// Constrained Baseline SPS: coded/visible geometry, luma-sample crop and VUI.
// Feeder supplies RBSP bytes (EPB already stripped). On cap_end, sequential bit-walk.
// High profiles (100+) → fail (product path is Baseline without scaling lists).

module sps_parser (
	input  wire        clk,
	input  wire        reset,

	input  wire        cap_clear,
	input  wire        cap_en,
	input  wire [7:0]  cap_data,
	input  wire        cap_end,

	output reg         valid,
	output reg         error,
	output reg [7:0]   sps_id,
	output reg  [7:0]  profile_idc,
	output reg  [7:0]  level_idc,
	output reg  [15:0] width,
	output reg  [15:0] height,
	output reg  [15:0] coded_width,
	output reg  [15:0] coded_height,
	output reg  [15:0] crop_left,
	output reg  [15:0] crop_top,
	output reg  [15:0] crop_right,
	output reg  [15:0] crop_bottom,
	output reg  [15:0] sar_width,
	output reg  [15:0] sar_height,
	output reg         sar_known,
	// Extras for slice header / MB grid (3.3d)
	output reg  [4:0]  log2_max_frame_num, // 4..16
	output reg  [4:0]  log2_max_pic_order_cnt_lsb,
	output reg  [2:0]  poc_type,           // 0..2
	output reg  [7:0]  max_num_ref_frames,
	output reg  [7:0]  mb_width,           // pic_width_in_mbs
	output reg  [7:0]  mb_height,          // frame height in MBs
	output reg         video_full_range_flag,
	output reg  [7:0]  matrix_coefficients,
	output reg         busy
);

	localparam int MAXB = 48;

	reg [7:0] mem [0:MAXB-1];
	reg [5:0] len;
	reg overflow;

	reg [5:0] bbyte;
	reg [2:0] bpos;

	wire [7:0] cur  = mem[bbyte];
	// H.264 bitstream is MSB-first within each byte. bpos counts 7→0.
	wire       bitv = cur[bpos];
	wire       oob  = (bbyte >= len);

	reg [5:0] st;
	reg [5:0] cont;
	reg [5:0] ue_cont;
	reg [5:0] zcnt;
	reg [6:0] nleft;
	reg [15:0] acc;
	reg [15:0] ue_val;
	reg [15:0] w_mbs, h_map;
	reg        frame_mbs_only;
	reg        crop_flag;
	reg [15:0] cl, cr, ct, cb;
	reg [7:0]  prof;
	reg [4:0]  log2_fn;
	reg [2:0]  poc_t;
	reg [2:0] vui_i;

	localparam [5:0]
		ST_IDLE    = 5'd0,
		ST_GETBITS = 5'd1,
		ST_UE_Z    = 5'd2,
		ST_UE_V    = 5'd3,
		ST_PROF    = 5'd4,
		ST_CONS    = 5'd5,
		ST_LEVEL   = 5'd6,
		ST_SPSID   = 5'd7,
		ST_LOG2    = 5'd8,
		ST_POC     = 5'd9,
		ST_POC0    = 5'd10,
		ST_REFS    = 5'd11,
		ST_GAPS    = 5'd12,
		ST_W       = 5'd13,
		ST_H       = 5'd14,
		ST_FMO     = 5'd15,
		ST_MBAFF   = 5'd16,
		ST_D8      = 5'd17,
		ST_CROP    = 5'd18,
		ST_CL      = 5'd19,
		ST_CR      = 5'd20,
		ST_CT      = 5'd21,
		ST_CB      = 5'd22,
		ST_FINISH  = 5'd23,
		ST_FAIL    = 5'd24,
		ST_VUI_READ = 6'd25, ST_VUI = 6'd26, ST_ASPECT = 6'd27,
		ST_SAR = 6'd28, ST_OVERSCAN_READ = 6'd29, ST_OVERSCAN = 6'd30,
		ST_VIDEO_READ = 6'd31, ST_VIDEO = 6'd32, ST_COLOUR = 6'd33,
		ST_CHROMA_READ = 6'd34, ST_CHROMA = 6'd35, ST_CHROMA_UE = 6'd36,
		ST_TIMING_READ = 6'd37, ST_TIMING = 6'd38,
		ST_HRD_READ = 6'd39, ST_NAL_HRD = 6'd40, ST_VCL_HRD = 6'd41,
		ST_PIC_STRUCT = 6'd42, ST_RESTRICT = 6'd43,
		ST_RESTRICT_START = 6'd44, ST_RESTRICT_UE = 6'd45,
		ST_STOP_READ = 6'd46, ST_STOP = 6'd47, ST_PAD = 6'd48,
		ST_MATRIX = 6'd49, ST_SAR_WIDTH = 6'd50, ST_SAR_HEIGHT = 6'd51;

	function automatic [31:0] sar_ratio(input [7:0] idc);
		begin
			case (idc)
			8'd1:  sar_ratio = {16'd1,   16'd1};
			8'd2:  sar_ratio = {16'd12,  16'd11};
			8'd3:  sar_ratio = {16'd10,  16'd11};
			8'd4:  sar_ratio = {16'd16,  16'd11};
			8'd5:  sar_ratio = {16'd40,  16'd33};
			8'd6:  sar_ratio = {16'd24,  16'd11};
			8'd7:  sar_ratio = {16'd20,  16'd11};
			8'd8:  sar_ratio = {16'd32,  16'd11};
			8'd9:  sar_ratio = {16'd80,  16'd33};
			8'd10: sar_ratio = {16'd18,  16'd11};
			8'd11: sar_ratio = {16'd15,  16'd11};
			8'd12: sar_ratio = {16'd64,  16'd33};
			8'd13: sar_ratio = {16'd160, 16'd99};
			8'd14: sar_ratio = {16'd4,   16'd3};
			8'd15: sar_ratio = {16'd3,   16'd2};
			8'd16: sar_ratio = {16'd2,   16'd1};
			default: sar_ratio = 32'd0;
			endcase
		end
	endfunction

	task automatic bits_to(input [6:0] n, input [5:0] target);
		begin nleft <= n; acc <= 0; cont <= target; st <= ST_GETBITS; end
	endtask
	task automatic ue_to(input [5:0] target);
		begin zcnt <= 0; ue_cont <= target; st <= ST_UE_Z; end
	endtask

	// capture buffer (independent of parse FSM)
	always @(posedge clk) begin
		if (reset || cap_clear) begin
			len <= 0;
			overflow <= 0;
		end
		else if (cap_en && len < MAXB[5:0]) begin
			mem[len] <= cap_data;
			len <= len + 1'd1;
		end else if (cap_en) overflow <= 1;
	end

	always @(posedge clk) begin
		if (reset || cap_clear) begin
			st <= ST_IDLE;
			valid <= 0;
			error <= 0;
			sps_id <= 0;
			busy <= 0;
			profile_idc <= 0;
			level_idc <= 0;
			width <= 0;
			height <= 0;
			coded_width <= 0; coded_height <= 0;
			crop_left <= 0; crop_top <= 0; crop_right <= 0; crop_bottom <= 0;
			sar_width <= 0; sar_height <= 0; sar_known <= 0;
			log2_max_frame_num <= 5'd4;
			log2_max_pic_order_cnt_lsb <= 5'd4;
			poc_type <= 0;
			max_num_ref_frames <= 0;
			mb_width <= 0;
			mb_height <= 0;
			video_full_range_flag <= 1'b0;
			matrix_coefficients <= 8'd2;
			log2_fn <= 5'd4;
			poc_t <= 0;
			vui_i <= 0;
			bbyte <= 0;
			bpos <= 3'd7;
			zcnt <= 0;
			nleft <= 0;
			acc <= 0;
			ue_val <= 0;
			w_mbs <= 0;
			h_map <= 0;
			frame_mbs_only <= 1;
			crop_flag <= 0;
			cl <= 0; cr <= 0; ct <= 0; cb <= 0;
			prof <= 0;
			cont <= ST_IDLE;
			ue_cont <= ST_IDLE;
		end else begin
			case (st)
			ST_IDLE: begin
				busy <= 0;
				if (cap_end && (({1'b0, len} + (cap_en ? 7'd1 : 7'd0)) < 7'd4 ||
				    overflow || (cap_en && len == MAXB))) st <= ST_FAIL;
				else if (cap_end) begin
					busy  <= 1'b1;
					bbyte <= 0;
					bpos  <= 3'd7;
					nleft <= 5'd8;
					acc   <= 0;
					cont  <= ST_PROF;
					st    <= ST_GETBITS;
				end
			end

			ST_GETBITS: begin
				if (oob) begin
					st <= ST_FAIL;
				end else begin
					acc <= {acc[14:0], bitv};
					if (bpos == 3'd0) begin
						bpos  <= 3'd7;
						bbyte <= bbyte + 1'd1;
					end else begin
						bpos <= bpos - 1'd1;
					end
					if (nleft == 5'd1)
						st <= cont;
					else
						nleft <= nleft - 1'd1;
				end
			end

			ST_UE_Z: begin
				if (oob) begin
					st <= ST_FAIL;
				end else if (bitv == 1'b0) begin
					if (zcnt >= 6'd16) begin
						st <= ST_FAIL;
					end else begin
						zcnt <= zcnt + 1'd1;
						if (bpos == 3'd0) begin
							bpos  <= 3'd7;
							bbyte <= bbyte + 1'd1;
						end else begin
							bpos <= bpos - 1'd1;
						end
					end
				end else begin
					// leading 1
					if (bpos == 3'd0) begin
						bpos  <= 3'd7;
						bbyte <= bbyte + 1'd1;
					end else begin
						bpos <= bpos - 1'd1;
					end
					if (zcnt == 0) begin
						ue_val <= 0;
						st <= ue_cont;
					end else begin
						nleft <= zcnt[4:0];
						acc   <= 0;
						cont  <= ST_UE_V;
						st    <= ST_GETBITS;
					end
				end
			end

			ST_UE_V: begin
				if (zcnt == 16 && acc != 0) st <= ST_FAIL;
				else begin
					ue_val <= ((17'd1 << zcnt) - 17'd1) + acc;
					st <= ue_cont;
				end
			end

			ST_PROF: begin
				prof <= acc[7:0];
				profile_idc <= acc[7:0];
				nleft <= 5'd8;
				acc <= 0;
				cont <= ST_CONS;
				st <= ST_GETBITS;
			end
			ST_CONS: begin
				nleft <= 5'd8;
				acc <= 0;
				cont <= ST_LEVEL;
				st <= (prof != 66 || !acc[6] || acc[1:0] != 0) ? ST_FAIL : ST_GETBITS;
			end
			ST_LEVEL: begin
				level_idc <= acc[7:0];
				zcnt <= 0;
				ue_cont <= ST_SPSID;
				st <= ST_UE_Z;
			end
			ST_SPSID: begin
				sps_id <= ue_val[7:0];
				if (ue_val > 31) begin
					st <= ST_FAIL;
				end else begin
					zcnt <= 0;
					ue_cont <= ST_LOG2;
					st <= ST_UE_Z;
				end
			end
			ST_LOG2: begin
				// ue_val = log2_max_frame_num_minus4
				log2_fn <= ue_val[4:0] + 5'd4;
				zcnt <= 0;
				ue_cont <= ST_POC;
				st <= (ue_val > 12) ? ST_FAIL : ST_UE_Z;
			end
			ST_POC: begin
				poc_t <= ue_val[2:0];
				if (ue_val == 16'd0) begin
					zcnt <= 0;
					ue_cont <= ST_POC0;
					st <= ST_UE_Z;
				end else if (ue_val != 16'd2) begin
					st <= ST_FAIL;
				end else begin
					zcnt <= 0;
					ue_cont <= ST_REFS;
					st <= ST_UE_Z;
				end
			end
			ST_POC0: begin
				log2_max_pic_order_cnt_lsb <= ue_val[4:0] + 5'd4;
				zcnt <= 0;
				ue_cont <= ST_REFS;
				st <= (ue_val > 12) ? ST_FAIL : ST_UE_Z;
			end
			ST_REFS: begin
				if (ue_val <= 1) max_num_ref_frames <= ue_val[7:0];
				nleft <= 5'd1;
				acc <= 0;
				cont <= ST_GAPS;
				st <= (ue_val > 1) ? ST_FAIL : ST_GETBITS;
			end
			ST_GAPS: begin
				zcnt <= 0;
				ue_cont <= ST_W;
				st <= acc[0] ? ST_FAIL : ST_UE_Z;
			end
			ST_W: begin
				w_mbs <= ue_val + 16'd1;
				zcnt <= 0;
				ue_cont <= ST_H;
				st <= (ue_val > 254) ? ST_FAIL : ST_UE_Z;
			end
			ST_H: begin
				h_map <= ue_val + 16'd1;
				nleft <= 5'd1;
				acc <= 0;
				cont <= ST_FMO;
				st <= (ue_val > 254) ? ST_FAIL : ST_GETBITS;
			end
			ST_FMO: begin
				frame_mbs_only <= acc[0];
				if (acc[0] == 1'b0) begin
					nleft <= 5'd1;
					acc <= 0;
					cont <= ST_MBAFF;
					st <= ST_FAIL;
				end else begin
					nleft <= 5'd1;
					acc <= 0;
					cont <= ST_D8;
					st <= ST_GETBITS;
				end
			end
			ST_MBAFF: begin
				nleft <= 5'd1;
				acc <= 0;
				cont <= ST_D8;
				st <= ST_GETBITS;
			end
			ST_D8: begin
				nleft <= 5'd1;
				acc <= 0;
				cont <= ST_CROP;
				st <= ST_GETBITS;
			end
			ST_CROP: begin
				crop_flag <= acc[0];
				if (acc[0]) begin
					zcnt <= 0;
					ue_cont <= ST_CL;
					st <= ST_UE_Z;
				end else begin
					st <= ST_VUI_READ;
				end
			end
			ST_CL: begin
				cl <= ue_val;
				zcnt <= 0;
				ue_cont <= ST_CR;
				st <= ST_UE_Z;
			end
			ST_CR: begin
				cr <= ue_val;
				zcnt <= 0;
				ue_cont <= ST_CT;
				st <= ST_UE_Z;
			end
			ST_CT: begin
				ct <= ue_val;
				zcnt <= 0;
				ue_cont <= ST_CB;
				st <= ST_UE_Z;
			end
			ST_CB: begin
				cb <= ue_val;
				st <= ST_VUI_READ;
			end

			ST_VUI_READ: bits_to(1, ST_VUI);
			ST_VUI: begin
				if (acc[0]) bits_to(1, ST_ASPECT);
				else st <= ST_STOP_READ;
			end
			ST_ASPECT: begin
				if (acc[0]) bits_to(8, ST_SAR);
				else st <= ST_OVERSCAN_READ;
			end
			ST_SAR: begin
				if (acc == 255) bits_to(16, ST_SAR_WIDTH);
				else if (acc > 16) st <= ST_FAIL;
				else begin
					{sar_width, sar_height} <= sar_ratio(acc[7:0]);
					sar_known <= acc != 0;
					st <= ST_OVERSCAN_READ;
				end
			end
			ST_SAR_WIDTH: begin sar_width <= acc; bits_to(16, ST_SAR_HEIGHT); end
			ST_SAR_HEIGHT: begin
				if (sar_width == 0 || acc == 0) begin
					sar_width <= 0; sar_height <= 0; sar_known <= 0;
				end else begin
					sar_height <= acc; sar_known <= 1;
				end
				st <= ST_OVERSCAN_READ;
			end
			ST_OVERSCAN_READ: bits_to(1, ST_OVERSCAN);
			ST_OVERSCAN: begin
				if (acc[0]) bits_to(1, ST_VIDEO_READ);
				else st <= ST_VIDEO_READ;
			end
			ST_VIDEO_READ: bits_to(1, ST_VIDEO);
			ST_VIDEO: begin
				if (acc[0]) bits_to(5, ST_COLOUR);
				else st <= ST_CHROMA_READ;
			end
			ST_COLOUR: begin
				video_full_range_flag <= acc[1];
				if (acc[0]) bits_to(24, ST_MATRIX);
				else st <= ST_CHROMA_READ;
			end
			ST_MATRIX: begin
				matrix_coefficients <= acc[7:0];
				if (acc[7:0] == 8'd1 || acc[7:0] == 8'd2 ||
				    acc[7:0] == 8'd5 || acc[7:0] == 8'd6)
					st <= ST_CHROMA_READ;
				else st <= ST_FAIL;
			end
			ST_CHROMA_READ: bits_to(1, ST_CHROMA);
			ST_CHROMA: begin
				vui_i <= 0;
				if (acc[0]) ue_to(ST_CHROMA_UE);
				else st <= ST_TIMING_READ;
			end
			ST_CHROMA_UE: begin
				// The current 4:2:0 publisher has no chroma-phase metadata.
				if (ue_val != 0) st <= ST_FAIL;
				else if (vui_i == 0) begin vui_i <= 1; ue_to(ST_CHROMA_UE); end
				else st <= ST_TIMING_READ;
			end
			ST_TIMING_READ: bits_to(1, ST_TIMING);
			ST_TIMING: begin
				if (acc[0]) bits_to(65, ST_HRD_READ);
				else st <= ST_HRD_READ;
			end
			ST_HRD_READ: bits_to(1, ST_NAL_HRD);
			ST_NAL_HRD: begin
				if (acc[0]) st <= ST_FAIL;
				else bits_to(1, ST_VCL_HRD);
			end
			ST_VCL_HRD: begin
				if (acc[0]) st <= ST_FAIL;
				else bits_to(1, ST_PIC_STRUCT);
			end
			ST_PIC_STRUCT: begin
				if (acc[0]) st <= ST_FAIL;
				else bits_to(1, ST_RESTRICT);
			end
			ST_RESTRICT: begin
				if (acc[0]) bits_to(1, ST_RESTRICT_START);
				else st <= ST_STOP_READ;
			end
			ST_RESTRICT_START: begin vui_i <= 0; ue_to(ST_RESTRICT_UE); end
			ST_RESTRICT_UE: begin
				if ((vui_i < 4 && ue_val > 16) ||
				    (vui_i == 4 && ue_val != 0) ||
				    (vui_i == 5 && ue_val > 1)) st <= ST_FAIL;
				else if (vui_i == 5) st <= ST_STOP_READ;
				else begin vui_i <= vui_i + 1'b1; ue_to(ST_RESTRICT_UE); end
			end
			ST_STOP_READ: bits_to(1, ST_STOP);
			ST_STOP: begin
				if (acc != 1) st <= ST_FAIL;
				else st <= ST_PAD;
			end
			ST_PAD: begin
				if (oob) st <= ST_FINISH;
				else if (bitv || bpos == 7) st <= ST_FAIL;
				else if (bpos == 0) begin bpos <= 7; bbyte <= bbyte + 1'b1; end
				else bpos <= bpos - 1'b1;
			end

			ST_FINISH: begin
				busy <= 0;
				st <= ST_IDLE;
				log2_max_frame_num <= log2_fn;
				poc_type <= poc_t;
				mb_width <= w_mbs[7:0];
				mb_height <= frame_mbs_only ? h_map[7:0] : {h_map[6:0], 1'b0};
				coded_width <= w_mbs << 4;
				coded_height <= h_map << 4;
				if (crop_flag) begin
					if ((w_mbs * 32'd16) > (({16'd0, cl} + cr) << 1) &&
					    (h_map * 32'd16) > (({16'd0, ct} + cb) << 1)) begin
						width  <= (w_mbs * 16'd16) - ((cl + cr) << 1);
						height <= (h_map * 16'd16 * (frame_mbs_only ? 16'd1 : 16'd2)) - ((ct + cb) << 1);
						// Progressive 4:2:0 crop units are two luma samples.
						crop_left <= cl << 1; crop_right <= cr << 1;
						crop_top <= ct << 1; crop_bottom <= cb << 1;
						valid  <= 1'b1;
					end else st <= ST_FAIL;
				end else begin
					width  <= w_mbs * 16'd16;
					height <= h_map * 16'd16 * (frame_mbs_only ? 16'd1 : 16'd2);
					valid  <= 1'b1;
				end
			end

			ST_FAIL: begin
				busy <= 0;
				valid <= 0;
				error <= 1;
			end

			default: st <= ST_IDLE;
			endcase
		end
	end

endmodule
