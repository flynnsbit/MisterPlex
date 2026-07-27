`default_nettype none

module h264_dpb_mb_writer #(
	parameter [31:0] BASE_PHYS = 32'h3020_0000,
	parameter int BANK_STRIDE = 32'h80000,
	parameter int LUMA_W = 624,
	parameter int LUMA_H = 480,
	parameter int CHROMA_W = 312,
	parameter int CHROMA_H = 240,
	parameter int U_OFFSET = 299520,
	parameter int V_OFFSET = 374400
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire        bank,
	input  wire [5:0]  mb_x,
	input  wire [4:0]  mb_y,
	input  wire [7:0]  y_samples [0:255],
	input  wire [7:0]  u_samples [0:63],
	input  wire [7:0]  v_samples [0:63],
	output reg         busy,
	output reg         done,
	output reg         out_valid,
	output reg [31:0]  out_addr,
	output reg [7:0]   out_data,
	output reg [1:0]   out_plane
);
	localparam int TOTAL = 384;
	reg [8:0] idx;

	function automatic [31:0] plane_addr(
		input [1:0] plane,
		input int x,
		input int y
	);
		int off;
		begin
			if (plane == 2'd0)
				off = y * LUMA_W + x;
			else if (plane == 2'd1)
				off = U_OFFSET + y * CHROMA_W + x;
			else
				off = V_OFFSET + y * CHROMA_W + x;
			plane_addr = BASE_PHYS + (bank ? BANK_STRIDE : 0) + off[31:0];
		end
	endfunction

	always @(posedge clk) begin
		done <= 1'b0;
		out_valid <= 1'b0;
		if (reset) begin
			busy <= 1'b0;
			idx <= 9'd0;
			out_addr <= 32'd0;
			out_data <= 8'd0;
			out_plane <= 2'd0;
		end else if (start && !busy) begin
			busy <= 1'b1;
			idx <= 9'd0;
		end else if (busy) begin
			out_valid <= 1'b1;
			if (idx < 9'd256) begin
				out_plane <= 2'd0;
				out_addr <= plane_addr(2'd0,
					int'({1'b0, mb_x}) * 16 + (int'(idx) % 16),
					int'({1'b0, mb_y}) * 16 + (int'(idx) / 16));
				out_data <= y_samples[idx[7:0]];
			end else if (idx < 9'd320) begin
				out_plane <= 2'd1;
				out_addr <= plane_addr(2'd1,
					int'({1'b0, mb_x}) * 8 + ((int'(idx) - 256) % 8),
					int'({1'b0, mb_y}) * 8 + ((int'(idx) - 256) / 8));
				out_data <= u_samples[idx[5:0]];
			end else begin
				out_plane <= 2'd2;
				out_addr <= plane_addr(2'd2,
					int'({1'b0, mb_x}) * 8 + ((int'(idx) - 320) % 8),
					int'({1'b0, mb_y}) * 8 + ((int'(idx) - 320) / 8));
				out_data <= v_samples[idx[5:0]];
			end

			if (idx == 9'(TOTAL - 1)) begin
				busy <= 1'b0;
				done <= 1'b1;
			end
			idx <= idx + 9'd1;
		end
	end
endmodule

module h264_dpb_ref_fetch #(
	parameter [31:0] BASE_PHYS = 32'h3020_0000,
	parameter int BANK_STRIDE = 32'h80000,
	parameter int LUMA_W = 624,
	parameter int LUMA_H = 480,
	parameter int CHROMA_W = 312,
	parameter int CHROMA_H = 240,
	parameter int U_OFFSET = 299520,
	parameter int V_OFFSET = 374400,
	parameter bit FAULT_NO_EDGE_CLAMP = 1'b0,
	parameter bit FAULT_V_OFFSET_U = 1'b0
)(
	input  wire               clk,
	input  wire               reset,
	input  wire               start,
	input  wire               bank,
	input  wire signed [15:0] luma_x_qpel,
	input  wire signed [15:0] luma_y_qpel,
	input  wire signed [15:0] chroma_x_epel,
	input  wire signed [15:0] chroma_y_epel,
	output reg                busy,
	output reg                done,
	output reg                req_valid,
	output reg [31:0]         req_addr,
	output reg [1:0]          req_plane,
	output reg [9:0]          req_index,
	input  wire               sample_valid,
	input  wire [7:0]         sample_data,
	output reg                out_valid,
	output reg [1:0]          out_plane,
	output reg [9:0]          out_index,
	output reg [7:0]          out_sample
);
	localparam int TOTAL = 603;
	localparam [1:0] ST_IDLE = 2'd0, ST_REQ = 2'd1, ST_WAIT = 2'd2;
	reg [1:0] state;
	reg [9:0] idx;
	reg [1:0] pend_plane;
	reg [9:0] pend_index;

	function automatic signed [15:0] floor_div_pow2(input signed [15:0] v, input int sh);
		reg signed [15:0] bias;
		begin
			bias = (16'sd1 <<< sh) - 16'sd1;
			floor_div_pow2 = (v < 0) ? -(((-v) + bias) >>> sh) : (v >>> sh);
		end
	endfunction

	function automatic [15:0] clamp_coord(
		input signed [15:0] v,
		input int limit
	);
		begin
			if (FAULT_NO_EDGE_CLAMP)
				clamp_coord = v[15:0];
			else if (v < 0)
				clamp_coord = 16'd0;
			else if ($signed(v) >= $signed(16'(limit)))
				clamp_coord = limit[15:0] - 16'd1;
			else
				clamp_coord = v[15:0];
		end
	endfunction

	function automatic [31:0] sample_addr(
		input [1:0] plane,
		input signed [15:0] sx,
		input signed [15:0] sy
	);
		reg [15:0] cx;
		reg [15:0] cy;
		int off;
		begin
			if (plane == 2'd0) begin
				cx = clamp_coord(sx, LUMA_W);
				cy = clamp_coord(sy, LUMA_H);
				off = int'(cy) * LUMA_W + int'(cx);
			end else if (plane == 2'd1) begin
				cx = clamp_coord(sx, CHROMA_W);
				cy = clamp_coord(sy, CHROMA_H);
				off = U_OFFSET + int'(cy) * CHROMA_W + int'(cx);
			end else begin
				cx = clamp_coord(sx, CHROMA_W);
				cy = clamp_coord(sy, CHROMA_H);
				off = (FAULT_V_OFFSET_U ? U_OFFSET : V_OFFSET) + int'(cy) * CHROMA_W + int'(cx);
			end
			sample_addr = BASE_PHYS + (bank ? BANK_STRIDE : 0) + off[31:0];
		end
	endfunction

	task automatic drive_req(input [9:0] i);
		reg [1:0] plane;
		reg signed [15:0] bx;
		reg signed [15:0] by;
		reg signed [15:0] sx;
		reg signed [15:0] sy;
		reg [9:0] local_idx;
		begin
			if (i < 10'd441) begin
				plane = 2'd0;
				bx = floor_div_pow2(luma_x_qpel, 2);
				by = floor_div_pow2(luma_y_qpel, 2);
				sx = bx - 16'sd2 + $signed({6'd0, (i % 10'd21)});
				sy = by - 16'sd2 + $signed({6'd0, (i / 10'd21)});
				local_idx = i;
			end else if (i < 10'd522) begin
				plane = 2'd1;
				local_idx = i - 10'd441;
				bx = floor_div_pow2(chroma_x_epel, 3);
				by = floor_div_pow2(chroma_y_epel, 3);
				sx = bx + $signed({6'd0, (local_idx % 10'd9)});
				sy = by + $signed({6'd0, (local_idx / 10'd9)});
			end else begin
				plane = 2'd2;
				local_idx = i - 10'd522;
				bx = floor_div_pow2(chroma_x_epel, 3);
				by = floor_div_pow2(chroma_y_epel, 3);
				sx = bx + $signed({6'd0, (local_idx % 10'd9)});
				sy = by + $signed({6'd0, (local_idx / 10'd9)});
			end
			req_valid <= 1'b1;
			req_plane <= plane;
			req_index <= i;
			req_addr <= sample_addr(plane, sx, sy);
			pend_plane <= plane;
			pend_index <= i;
		end
	endtask

	always @(posedge clk) begin
		req_valid <= 1'b0;
		out_valid <= 1'b0;
		if (reset) begin
			state <= ST_IDLE;
			busy <= 1'b0;
			done <= 1'b0;
			idx <= 10'd0;
			req_addr <= 32'd0;
			req_plane <= 2'd0;
			req_index <= 10'd0;
			pend_plane <= 2'd0;
			pend_index <= 10'd0;
			out_plane <= 2'd0;
			out_index <= 10'd0;
			out_sample <= 8'd0;
		end else begin
			case (state)
				ST_IDLE: begin
					if (start) begin
						busy <= 1'b1;
						done <= 1'b0;
						idx <= 10'd0;
						state <= ST_REQ;
					end
				end
				ST_REQ: begin
					drive_req(idx);
					state <= ST_WAIT;
				end
				ST_WAIT: begin
					if (sample_valid) begin
						out_valid <= 1'b1;
						out_plane <= pend_plane;
						out_index <= pend_index;
						out_sample <= sample_data;
						if (idx == 10'(TOTAL - 1)) begin
							busy <= 1'b0;
							done <= 1'b1;
							state <= ST_IDLE;
						end else begin
							idx <= idx + 10'd1;
							state <= ST_REQ;
						end
					end
				end
				default: state <= ST_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
