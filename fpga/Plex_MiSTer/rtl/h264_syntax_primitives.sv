// Phase P3 syntax primitives: RBSP EPB removal and registered Exp-Golomb reader.
// Offsets produced/consumed here are RBSP offsets after emulation-prevention-byte removal.

module h264_rbsp_filter (
	input  wire       clk,
	input  wire       reset,
	input  wire       clear,

	input  wire       in_valid,
	input  wire [7:0] in_byte,
	input  wire       in_last,
	output wire       in_ready,

	output reg        out_valid,
	output reg  [7:0] out_byte,
	output reg        out_last,
	output reg [15:0] out_index,
	input  wire       out_ready,

	output reg [15:0] rbsp_len,
	output reg [15:0] epb_removed,
	output reg        done
);
	reg [1:0] zero_count;
	reg       inhibit_skip;

	wire can_accept = !out_valid || out_ready;
	wire skip_epb = in_valid && can_accept && !inhibit_skip && (zero_count == 2'd2) && (in_byte == 8'h03);
	assign in_ready = can_accept;

	always @(posedge clk) begin
		if (reset || clear) begin
			out_valid <= 1'b0;
			out_byte <= 8'd0;
			out_last <= 1'b0;
			out_index <= 16'd0;
			rbsp_len <= 16'd0;
			epb_removed <= 16'd0;
			done <= 1'b0;
			zero_count <= 2'd0;
			inhibit_skip <= 1'b0;
		end else begin
			if (out_valid && out_ready)
				out_valid <= 1'b0;
			if (in_valid && can_accept) begin
				if (skip_epb) begin
					epb_removed <= epb_removed + 16'd1;
					inhibit_skip <= 1'b1;
					if (in_last)
						done <= 1'b1;
				end else begin
					out_valid <= 1'b1;
					out_byte <= in_byte;
					out_last <= in_last;
					out_index <= rbsp_len;
					rbsp_len <= rbsp_len + 16'd1;
					if (in_byte == 8'h00)
						zero_count <= (zero_count == 2'd2) ? 2'd2 : (zero_count + 2'd1);
					else
						zero_count <= 2'd0;
					inhibit_skip <= 1'b0;
					if (in_last)
						done <= 1'b1;
				end
			end
		end
	end
endmodule

module h264_exp_golomb_reader #(
	parameter int MAX_LEADING_ZERO = 24
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire        signed_mode,
	input  wire        bit_valid,
	input  wire        bit_value,
	output wire        bit_ready,

	output reg         busy,
	output reg         done,
	output reg         ok,
	output reg [31:0]  ue_value,
	output reg signed [31:0] se_value,
	output reg [7:0]   bits_consumed
);
	localparam [1:0] ST_IDLE = 2'd0;
	localparam [1:0] ST_ZERO = 2'd1;
	localparam [1:0] ST_SUFFIX = 2'd2;
	localparam [1:0] ST_DONE = 2'd3;

	reg [1:0] st;
	reg [7:0] zero_count;
	reg [7:0] suffix_left;
	reg [31:0] suffix_acc;
	reg [31:0] code_num;

	assign bit_ready = (st == ST_ZERO) || (st == ST_SUFFIX);

	function automatic signed [31:0] se_map;
		input [31:0] code;
		begin
			if (code[0])
				se_map = $signed({1'b0, code[31:1]}) + 32'sd1;
			else
				se_map = -$signed({1'b0, code[31:1]});
		end
	endfunction

	always @(posedge clk) begin
		if (reset) begin
			st <= ST_IDLE;
			busy <= 1'b0;
			done <= 1'b0;
			ok <= 1'b0;
			ue_value <= 32'd0;
			se_value <= 32'sd0;
			bits_consumed <= 8'd0;
			zero_count <= 8'd0;
			suffix_left <= 8'd0;
			suffix_acc <= 32'd0;
			code_num <= 32'd0;
		end else begin
			done <= 1'b0;
			case (st)
			ST_IDLE: begin
				busy <= 1'b0;
				if (start) begin
					busy <= 1'b1;
					ok <= 1'b0;
					ue_value <= 32'd0;
					se_value <= 32'sd0;
					bits_consumed <= 8'd0;
					zero_count <= 8'd0;
					suffix_left <= 8'd0;
					suffix_acc <= 32'd0;
					code_num <= 32'd0;
					st <= ST_ZERO;
				end
			end
			ST_ZERO: begin
				if (bit_valid) begin
					bits_consumed <= bits_consumed + 8'd1;
					if (!bit_value) begin
						if (zero_count >= MAX_LEADING_ZERO[7:0]) begin
							ok <= 1'b0;
							done <= 1'b1;
							busy <= 1'b0;
							st <= ST_DONE;
						end else begin
							zero_count <= zero_count + 8'd1;
						end
					end else if (zero_count == 8'd0) begin
						code_num <= 32'd0;
						ue_value <= 32'd0;
						se_value <= 32'd0;
						ok <= 1'b1;
						done <= 1'b1;
						busy <= 1'b0;
						st <= ST_DONE;
					end else begin
						suffix_left <= zero_count;
						suffix_acc <= 32'd0;
						st <= ST_SUFFIX;
					end
				end
			end
			ST_SUFFIX: begin
				if (bit_valid) begin
					bits_consumed <= bits_consumed + 8'd1;
					suffix_acc <= (suffix_acc << 1) | {31'd0, bit_value};
					if (suffix_left == 8'd1) begin
						code_num <= ((32'd1 << zero_count) - 32'd1) + ((suffix_acc << 1) | {31'd0, bit_value});
						ue_value <= ((32'd1 << zero_count) - 32'd1) + ((suffix_acc << 1) | {31'd0, bit_value});
						se_value <= signed_mode ? se_map(((32'd1 << zero_count) - 32'd1) + ((suffix_acc << 1) | {31'd0, bit_value})) : $signed(((32'd1 << zero_count) - 32'd1) + ((suffix_acc << 1) | {31'd0, bit_value}));
						ok <= 1'b1;
						done <= 1'b1;
						busy <= 1'b0;
						st <= ST_DONE;
					end else begin
						suffix_left <= suffix_left - 8'd1;
					end
				end
			end
			ST_DONE: begin
				if (!start)
					st <= ST_IDLE;
			end
			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

module h264_sps_geometry_parser #(
	parameter int MAX_RBSP_BYTES = 128
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,

	input  wire        in_valid,
	input  wire [7:0]  in_byte,
	input  wire        in_last,
	output wire        in_ready,

	output reg         valid,
	output reg         error,
	output reg [7:0]   profile_idc,
	output reg [7:0]   level_idc,
	output reg [4:0]   log2_max_frame_num,
	output reg [2:0]   poc_type,
	output reg [15:0]  coded_width,
	output reg [15:0]  coded_height,
	output reg [15:0]  display_width,
	output reg [15:0]  display_height,
	output reg [15:0]  crop_left,
	output reg [15:0]  crop_right,
	output reg [15:0]  crop_top,
	output reg [15:0]  crop_bottom,
	output reg [15:0]  rbsp_bits_consumed,
	output reg         busy
);
	localparam int MAX_BITS = MAX_RBSP_BYTES * 8;
	reg [MAX_BITS-1:0] rbsp_bits;
	reg [15:0] rbsp_len;
	reg [15:0] bit_pos;

	reg [5:0] st;
	reg [5:0] ret_st;
	reg [7:0] fixed_left;
	reg [31:0] fixed_acc;
	reg [7:0] ue_zero;
	reg [7:0] ue_suffix_left;
	reg [31:0] ue_suffix;
	reg [31:0] ue_value;
	reg [15:0] pic_width_mbs;
	reg [15:0] pic_height_map_units;
	reg frame_mbs_only;
	reg crop_flag;

	assign in_ready = !busy && (rbsp_len < MAX_RBSP_BYTES[15:0]);

	function automatic bit rbsp_bit_at;
		input [15:0] idx;
		integer byte_i;
		integer bit_i;
		begin
			byte_i = $signed({16'd0, idx}) >>> 3;
			bit_i = 7 - ($signed({16'd0, idx}) & 32'd7);
			rbsp_bit_at = rbsp_bits[byte_i * 8 + bit_i];
		end
	endfunction

	localparam [5:0]
		ST_IDLE       = 6'd0,
		ST_BITS       = 6'd1,
		ST_UE_ZERO    = 6'd2,
		ST_UE_SUFFIX  = 6'd3,
		ST_PROFILE    = 6'd4,
		ST_CONSTRAINT = 6'd5,
		ST_LEVEL      = 6'd6,
		ST_SPS_ID     = 6'd7,
		ST_LOG2_FN    = 6'd8,
		ST_POC_TYPE   = 6'd9,
		ST_POC_LSB    = 6'd10,
		ST_REF_FRAMES = 6'd11,
		ST_GAPS       = 6'd12,
		ST_WIDTH      = 6'd13,
		ST_HEIGHT     = 6'd14,
		ST_FRAME_ONLY = 6'd15,
		ST_MBAFF      = 6'd16,
		ST_DIRECT     = 6'd17,
		ST_CROP_FLAG  = 6'd18,
		ST_CROP_L     = 6'd19,
		ST_CROP_R     = 6'd20,
		ST_CROP_T     = 6'd21,
		ST_CROP_B     = 6'd22,
		ST_FINISH     = 6'd23,
		ST_FAIL       = 6'd24;

	task automatic start_bits;
		input [7:0] nbits;
		input [5:0] next_st;
		begin
			fixed_left <= nbits;
			fixed_acc <= 32'd0;
			ret_st <= next_st;
			st <= ST_BITS;
		end
	endtask

	task automatic start_ue;
		input [5:0] next_st;
		begin
			ue_zero <= 8'd0;
			ue_suffix_left <= 8'd0;
			ue_suffix <= 32'd0;
			ue_value <= 32'd0;
			ret_st <= next_st;
			st <= ST_UE_ZERO;
		end
	endtask

	task automatic fail;
		begin
			error <= 1'b1;
			valid <= 1'b0;
			busy <= 1'b0;
			st <= ST_FAIL;
		end
	endtask

	always @(posedge clk) begin
		if (reset || clear) begin
			rbsp_bits <= {MAX_BITS{1'b0}};
			rbsp_len <= 16'd0;
			bit_pos <= 16'd0;
			valid <= 1'b0;
			error <= 1'b0;
			profile_idc <= 8'd0;
			level_idc <= 8'd0;
			log2_max_frame_num <= 5'd0;
			poc_type <= 3'd0;
			coded_width <= 16'd0;
			coded_height <= 16'd0;
			display_width <= 16'd0;
			display_height <= 16'd0;
			crop_left <= 16'd0;
			crop_right <= 16'd0;
			crop_top <= 16'd0;
			crop_bottom <= 16'd0;
			rbsp_bits_consumed <= 16'd0;
			busy <= 1'b0;
			st <= ST_IDLE;
			ret_st <= ST_IDLE;
			fixed_left <= 8'd0;
			fixed_acc <= 32'd0;
			ue_zero <= 8'd0;
			ue_suffix_left <= 8'd0;
			ue_suffix <= 32'd0;
			ue_value <= 32'd0;
			pic_width_mbs <= 16'd0;
			pic_height_map_units <= 16'd0;
			frame_mbs_only <= 1'b1;
			crop_flag <= 1'b0;
		end else begin
			if (!busy && in_valid && in_ready) begin
				rbsp_bits[rbsp_len * 8 +: 8] <= in_byte;
				rbsp_len <= rbsp_len + 16'd1;
				if (in_last) begin
					busy <= 1'b1;
					valid <= 1'b0;
					error <= 1'b0;
					bit_pos <= 16'd0;
					crop_left <= 16'd0;
					crop_right <= 16'd0;
					crop_top <= 16'd0;
					crop_bottom <= 16'd0;
					start_bits(8'd8, ST_PROFILE);
				end
			end else if (busy) begin
				case (st)
				ST_BITS: begin
					if (fixed_left == 8'd0) begin
						st <= ret_st;
					end else if (bit_pos >= (rbsp_len * 16'd8)) begin
						fail();
					end else begin
						fixed_acc <= (fixed_acc << 1) | {31'd0, rbsp_bit_at(bit_pos)};
						bit_pos <= bit_pos + 16'd1;
						fixed_left <= fixed_left - 8'd1;
						if (fixed_left == 8'd1)
							st <= ret_st;
					end
				end
				ST_UE_ZERO: begin
					if (bit_pos >= (rbsp_len * 16'd8)) begin
						fail();
					end else if (!rbsp_bit_at(bit_pos)) begin
						bit_pos <= bit_pos + 16'd1;
						if (ue_zero >= 8'd24)
							fail();
						else
							ue_zero <= ue_zero + 8'd1;
					end else begin
						bit_pos <= bit_pos + 16'd1;
						if (ue_zero == 8'd0) begin
							ue_value <= 32'd0;
							st <= ret_st;
						end else begin
							ue_suffix_left <= ue_zero;
							ue_suffix <= 32'd0;
							st <= ST_UE_SUFFIX;
						end
					end
				end
				ST_UE_SUFFIX: begin
					if (bit_pos >= (rbsp_len * 16'd8)) begin
						fail();
					end else begin
						ue_suffix <= (ue_suffix << 1) | {31'd0, rbsp_bit_at(bit_pos)};
						bit_pos <= bit_pos + 16'd1;
						if (ue_suffix_left == 8'd1) begin
							ue_value <= ((32'd1 << ue_zero) - 32'd1) + ((ue_suffix << 1) | {31'd0, rbsp_bit_at(bit_pos)});
							st <= ret_st;
						end
						ue_suffix_left <= ue_suffix_left - 8'd1;
					end
				end
				ST_PROFILE: begin
					profile_idc <= fixed_acc[7:0];
					start_bits(8'd8, ST_CONSTRAINT);
				end
				ST_CONSTRAINT: start_bits(8'd8, ST_LEVEL);
				ST_LEVEL: begin
					level_idc <= fixed_acc[7:0];
					start_ue(ST_SPS_ID);
				end
				ST_SPS_ID: start_ue(ST_LOG2_FN);
				ST_LOG2_FN: begin
					if (ue_value > 32'd12)
						fail();
					else begin
						log2_max_frame_num <= ue_value[4:0] + 5'd4;
						start_ue(ST_POC_TYPE);
					end
				end
				ST_POC_TYPE: begin
					poc_type <= ue_value[2:0];
					if (ue_value == 32'd0)
						start_ue(ST_POC_LSB);
					else if (ue_value == 32'd2)
						start_ue(ST_REF_FRAMES);
					else
						fail();
				end
				ST_POC_LSB: start_ue(ST_REF_FRAMES);
				ST_REF_FRAMES: start_bits(8'd1, ST_GAPS);
				ST_GAPS: start_ue(ST_WIDTH);
				ST_WIDTH: begin
					pic_width_mbs <= ue_value[15:0] + 16'd1;
					start_ue(ST_HEIGHT);
				end
				ST_HEIGHT: begin
					pic_height_map_units <= ue_value[15:0] + 16'd1;
					start_bits(8'd1, ST_FRAME_ONLY);
				end
				ST_FRAME_ONLY: begin
					frame_mbs_only <= fixed_acc[0];
					if (!fixed_acc[0])
						start_bits(8'd1, ST_MBAFF);
					else
						start_bits(8'd1, ST_DIRECT);
				end
				ST_MBAFF: start_bits(8'd1, ST_DIRECT);
				ST_DIRECT: start_bits(8'd1, ST_CROP_FLAG);
				ST_CROP_FLAG: begin
					crop_flag <= fixed_acc[0];
					if (fixed_acc[0])
						start_ue(ST_CROP_L);
					else
						st <= ST_FINISH;
				end
				ST_CROP_L: begin crop_left <= ue_value[15:0]; start_ue(ST_CROP_R); end
				ST_CROP_R: begin crop_right <= ue_value[15:0]; start_ue(ST_CROP_T); end
				ST_CROP_T: begin crop_top <= ue_value[15:0]; start_ue(ST_CROP_B); end
				ST_CROP_B: begin crop_bottom <= ue_value[15:0]; st <= ST_FINISH; end
				ST_FINISH: begin
					coded_width <= pic_width_mbs << 4;
					coded_height <= pic_height_map_units << (frame_mbs_only ? 4 : 5);
					display_width <= (pic_width_mbs << 4) - ((crop_left + crop_right) << 1);
					display_height <= (pic_height_map_units << (frame_mbs_only ? 4 : 5)) - ((crop_top + crop_bottom) << 1);
					rbsp_bits_consumed <= bit_pos;
					valid <= 1'b1;
					busy <= 1'b0;
					st <= ST_IDLE;
				end
				ST_FAIL: busy <= 1'b0;
				default: fail();
				endcase
			end
		end
	end
endmodule
