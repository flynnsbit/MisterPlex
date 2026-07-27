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
