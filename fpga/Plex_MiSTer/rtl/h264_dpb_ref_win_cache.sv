// On-chip reference-window cache for H.264 MC (DDR-resident DPB).
//
// Fills one 21x21 luma + 9x9 U + 9x9 V window from a 64-bit DDR master into
// M10K, then streams samples with the h264_dpb_one_ref window_* contract.
//
// M10K layouts (Cyclone V legal; every figure states depth x width):
//   luma_mem   [0:511] x 8  -> 1K x 8 M10K = 1 block (441 B used)
//   chroma_mem [0:255] x 8  -> 1K x 8 M10K = 1 block (U@0..80, V@128..208)
//   PREREG on-chip cost for one active window: 2 M10K.
//
// FAULT H264_DPB_DDR_FAULT_SMALL_WIN: fill 16x16 only (no +2 qpel border).
//
// Not product-wired to arbiter3 yet — m3 must be agreed with w-mem.
`default_nettype none

module h264_dpb_ref_win_cache #(
	parameter int FRAME_W = 1280,
	parameter int FRAME_H = 720
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        ref_ready,
	input  wire [31:0] reference_base,

	input  wire        fetch_start,
	input  wire [7:0]  fetch_mb_x,
	input  wire [7:0]  fetch_mb_y,
	input  wire [2:0]  fetch_part_mode,
	input  wire [1:0]  fetch_part_idx,
	input  wire signed [15:0] fetch_mv_x_qpel,
	input  wire signed [15:0] fetch_mv_y_qpel,
	output reg         fetch_busy,
	output reg         fetch_done,
	output reg         fetch_error_no_ref,

	output reg  [1:0]  luma_frac_x,
	output reg  [1:0]  luma_frac_y,
	output reg  [2:0]  chroma_frac_x,
	output reg  [2:0]  chroma_frac_y,
	output reg signed [15:0] luma_origin_x,
	output reg signed [15:0] luma_origin_y,
	output reg signed [15:0] chroma_origin_x,
	output reg signed [15:0] chroma_origin_y,

	output reg         luma_window_valid,
	output reg  [8:0]  luma_window_idx,
	output reg  [7:0]  luma_window_sample,
	output reg         chroma_u_window_valid,
	output reg         chroma_v_window_valid,
	output reg  [6:0]  chroma_window_idx,
	output reg  [7:0]  chroma_window_sample,

	output reg         ddr_want,
	input  wire        ddr_busy,
	output reg  [7:0]  ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output reg         ddr_rd
);
	localparam int C_W = FRAME_W / 2;
	localparam int C_H = FRAME_H / 2;
	localparam int Y_BYTES = FRAME_W * FRAME_H;
	localparam int C_BYTES = C_W * C_H;
	localparam int LUMA_WIN = 21;
	localparam int CHROMA_WIN = 9;
	localparam int LUMA_N = 441;
	localparam int CHROMA_N = 81;

`ifdef H264_DPB_DDR_FAULT_SMALL_WIN
	localparam int FILL_SIDE = 16;
	localparam int ORIGIN_PAD = 0;
`else
	localparam int FILL_SIDE = 21;
	localparam int ORIGIN_PAD = 2;
`endif

	(* ramstyle = "M10K" *) reg [7:0] luma_mem [0:511];
	(* ramstyle = "M10K" *) reg [7:0] chroma_mem [0:255];

	localparam [2:0] ST_IDLE = 3'd0;
	localparam [2:0] ST_ISSUE = 3'd1;
	localparam [2:0] ST_WAIT = 3'd2;
	localparam [2:0] ST_STORE = 3'd3;
	localparam [2:0] ST_STREAM = 3'd4;
	localparam [2:0] ST_DONE = 3'd5;

	reg [2:0] state;
	// plane: 0=Y fill, 1=U, 2=V, 3=stream Y, 4=stream U, 5=stream V
	reg [2:0] plane;
	reg [4:0] row;
	reg [4:0] col;
	reg [8:0] stream_i;
	reg [63:0] beat_data;
	reg [2:0]  beat_lane;
	reg [31:0] req_byte_addr;
	reg signed [15:0] lx0, ly0, cx0, cy0;

	function automatic signed [15:0] part_x_off(input [2:0] mode, input [1:0] idx);
		begin
			case (mode)
			3'd2: part_x_off = (idx == 2'd1) ? 16'sd8 : 16'sd0;
			3'd3, 3'd4: part_x_off = idx[0] ? 16'sd8 : 16'sd0;
			default: part_x_off = 16'sd0;
			endcase
		end
	endfunction

	function automatic signed [15:0] part_y_off(input [2:0] mode, input [1:0] idx);
		begin
			case (mode)
			3'd1: part_y_off = (idx == 2'd1) ? 16'sd8 : 16'sd0;
			3'd3, 3'd4: part_y_off = idx[1] ? 16'sd8 : 16'sd0;
			default: part_y_off = 16'sd0;
			endcase
		end
	endfunction

	function automatic [15:0] clamp_u(input signed [15:0] v, input [15:0] limit);
		begin
			if (v < 0) clamp_u = 16'd0;
			else if (v >= $signed({1'b0, limit})) clamp_u = limit - 16'd1;
			else clamp_u = v[15:0];
		end
	endfunction

	function automatic [31:0] plane_addr(
		input [31:0] base,
		input [1:0] pl,
		input [15:0] x,
		input [15:0] y
	);
		begin
			case (pl)
			2'd0: plane_addr = base + (y * FRAME_W) + {16'd0, x};
			2'd1: plane_addr = base + Y_BYTES + (y * C_W) + {16'd0, x};
			default: plane_addr = base + Y_BYTES + C_BYTES + (y * C_W) + {16'd0, x};
			endcase
		end
	endfunction

	function automatic [7:0] pick(input [63:0] d, input [2:0] lane);
		begin
			case (lane)
			3'd0: pick = d[7:0];
			3'd1: pick = d[15:8];
			3'd2: pick = d[23:16];
			3'd3: pick = d[31:24];
			3'd4: pick = d[39:32];
			3'd5: pick = d[47:40];
			3'd6: pick = d[55:48];
			default: pick = d[63:56];
			endcase
		end
	endfunction

	// Next sample coordinate for current plane/row/col.
	reg signed [15:0] sample_sx, sample_sy;
	reg [15:0] sample_cx, sample_cy;
	reg [1:0] sample_pl;
	reg [15:0] lim_w, lim_h;
	reg [4:0] side_lim;

	always @* begin
		sample_pl = 2'd0;
		lim_w = FRAME_W[15:0];
		lim_h = FRAME_H[15:0];
		side_lim = 5'(FILL_SIDE);
		sample_sx = 16'sd0;
		sample_sy = 16'sd0;
		if (plane == 3'd0) begin
			sample_pl = 2'd0;
			sample_sx = lx0 + $signed({11'd0, col});
			sample_sy = ly0 + $signed({11'd0, row});
			lim_w = FRAME_W[15:0];
			lim_h = FRAME_H[15:0];
			side_lim = 5'(FILL_SIDE);
		end else if (plane == 3'd1) begin
			sample_pl = 2'd1;
			sample_sx = cx0 + $signed({11'd0, col});
			sample_sy = cy0 + $signed({11'd0, row});
			lim_w = C_W[15:0];
			lim_h = C_H[15:0];
			side_lim = 5'(CHROMA_WIN);
		end else begin
			sample_pl = 2'd2;
			sample_sx = cx0 + $signed({11'd0, col});
			sample_sy = cy0 + $signed({11'd0, row});
			lim_w = C_W[15:0];
			lim_h = C_H[15:0];
			side_lim = 5'(CHROMA_WIN);
		end
		sample_cx = clamp_u(sample_sx, lim_w);
		sample_cy = clamp_u(sample_sy, lim_h);
	end

	wire [31:0] sample_byte_addr =
		plane_addr(reference_base, sample_pl, sample_cx, sample_cy);

	always @(posedge clk) begin
		ddr_rd <= 1'b0;
		ddr_want <= 1'b0;
		ddr_burstcnt <= 8'd1;
		luma_window_valid <= 1'b0;
		chroma_u_window_valid <= 1'b0;
		chroma_v_window_valid <= 1'b0;

		if (reset) begin
			state <= ST_IDLE;
			fetch_busy <= 1'b0;
			fetch_done <= 1'b0;
			fetch_error_no_ref <= 1'b0;
			plane <= 3'd0;
			row <= 5'd0;
			col <= 5'd0;
			stream_i <= 9'd0;
			ddr_addr <= 29'd0;
			beat_data <= 64'd0;
			beat_lane <= 3'd0;
			req_byte_addr <= 32'd0;
			luma_frac_x <= 2'd0;
			luma_frac_y <= 2'd0;
			chroma_frac_x <= 3'd0;
			chroma_frac_y <= 3'd0;
			luma_origin_x <= 16'sd0;
			luma_origin_y <= 16'sd0;
			chroma_origin_x <= 16'sd0;
			chroma_origin_y <= 16'sd0;
			lx0 <= 16'sd0;
			ly0 <= 16'sd0;
			cx0 <= 16'sd0;
			cy0 <= 16'sd0;
			luma_window_idx <= 9'd0;
			luma_window_sample <= 8'd0;
			chroma_window_idx <= 7'd0;
			chroma_window_sample <= 8'd0;
		end else begin
			case (state)
			ST_IDLE: begin
				fetch_busy <= 1'b0;
				if (fetch_start) begin
					fetch_done <= 1'b0;
					fetch_error_no_ref <= !ref_ready;
					if (!ref_ready) begin
						fetch_done <= 1'b1;
					end else begin
						fetch_busy <= 1'b1;
						luma_frac_x <= fetch_mv_x_qpel[1:0];
						luma_frac_y <= fetch_mv_y_qpel[1:0];
						chroma_frac_x <= fetch_mv_x_qpel[2:0];
						chroma_frac_y <= fetch_mv_y_qpel[2:0];
						luma_origin_x <= $signed({4'd0, fetch_mb_x, 4'd0}) +
						                 part_x_off(fetch_part_mode, fetch_part_idx) +
						                 (fetch_mv_x_qpel >>> 2);
						luma_origin_y <= $signed({4'd0, fetch_mb_y, 4'd0}) +
						                 part_y_off(fetch_part_mode, fetch_part_idx) +
						                 (fetch_mv_y_qpel >>> 2);
						chroma_origin_x <= $signed({5'd0, fetch_mb_x, 3'd0}) +
						                   (part_x_off(fetch_part_mode, fetch_part_idx) >>> 1) +
						                   (fetch_mv_x_qpel >>> 3);
						chroma_origin_y <= $signed({5'd0, fetch_mb_y, 3'd0}) +
						                   (part_y_off(fetch_part_mode, fetch_part_idx) >>> 1) +
						                   (fetch_mv_y_qpel >>> 3);
						// Window top-left including pad (or not under FAULT).
						lx0 <= ($signed({4'd0, fetch_mb_x, 4'd0}) +
						        part_x_off(fetch_part_mode, fetch_part_idx) +
						        (fetch_mv_x_qpel >>> 2)) - 16'(ORIGIN_PAD);
						ly0 <= ($signed({4'd0, fetch_mb_y, 4'd0}) +
						        part_y_off(fetch_part_mode, fetch_part_idx) +
						        (fetch_mv_y_qpel >>> 2)) - 16'(ORIGIN_PAD);
						cx0 <= $signed({5'd0, fetch_mb_x, 3'd0}) +
						       (part_x_off(fetch_part_mode, fetch_part_idx) >>> 1) +
						       (fetch_mv_x_qpel >>> 3);
						cy0 <= $signed({5'd0, fetch_mb_y, 3'd0}) +
						       (part_y_off(fetch_part_mode, fetch_part_idx) >>> 1) +
						       (fetch_mv_y_qpel >>> 3);
						plane <= 3'd0;
						row <= 5'd0;
						col <= 5'd0;
						state <= ST_ISSUE;
					end
				end
			end

			ST_ISSUE: begin
				// sample_byte_addr is a typed wire (Quartus rejects f()[hi:lo]).
				req_byte_addr <= sample_byte_addr;
				beat_lane <= sample_byte_addr[2:0];
				ddr_want <= 1'b1;
				if (!ddr_busy) begin
					ddr_rd <= 1'b1;
					ddr_addr <= sample_byte_addr[31:3];
					state <= ST_WAIT;
				end
			end

			ST_WAIT: begin
				ddr_want <= 1'b1;
				if (ddr_dout_ready) begin
					beat_data <= ddr_dout;
					state <= ST_STORE;
					ddr_want <= 1'b0;
				end
			end

			ST_STORE: begin
				if (plane == 3'd0) begin
					// Map into 21x21 canonical window index.
					// Under SMALL_WIN, store into [row+2][col+2] so stream still
					// indexes 0..440 but border stays zero-init (wrong for qpel).
`ifdef H264_DPB_DDR_FAULT_SMALL_WIN
					luma_mem[(row + 5'd2) * LUMA_WIN + (col + 5'd2)] <= pick(beat_data, beat_lane);
`else
					luma_mem[row * LUMA_WIN + col] <= pick(beat_data, beat_lane);
`endif
				end else if (plane == 3'd1) begin
					chroma_mem[row * CHROMA_WIN + col] <= pick(beat_data, beat_lane);
				end else begin
					chroma_mem[8'd128 + row * CHROMA_WIN + col] <= pick(beat_data, beat_lane);
				end

				// Advance col/row/plane
				if (col == side_lim - 5'd1) begin
					col <= 5'd0;
					if (row == side_lim - 5'd1) begin
						row <= 5'd0;
						if (plane == 3'd0) begin
							plane <= 3'd1;
							state <= ST_ISSUE;
						end else if (plane == 3'd1) begin
							plane <= 3'd2;
							state <= ST_ISSUE;
						end else begin
							stream_i <= 9'd0;
							plane <= 3'd3;
							state <= ST_STREAM;
						end
					end else begin
						row <= row + 5'd1;
						state <= ST_ISSUE;
					end
				end else begin
					col <= col + 5'd1;
					state <= ST_ISSUE;
				end
			end

			ST_STREAM: begin
				if (plane == 3'd3) begin
					luma_window_valid <= 1'b1;
					luma_window_idx <= stream_i;
					luma_window_sample <= luma_mem[stream_i];
					if (stream_i == 9'(LUMA_N - 1)) begin
						stream_i <= 9'd0;
						plane <= 3'd4;
					end else stream_i <= stream_i + 9'd1;
				end else if (plane == 3'd4) begin
					chroma_u_window_valid <= 1'b1;
					chroma_window_idx <= stream_i[6:0];
					chroma_window_sample <= chroma_mem[stream_i[7:0]];
					if (stream_i == 9'(CHROMA_N - 1)) begin
						stream_i <= 9'd0;
						plane <= 3'd5;
					end else stream_i <= stream_i + 9'd1;
				end else begin
					chroma_v_window_valid <= 1'b1;
					chroma_window_idx <= stream_i[6:0];
					chroma_window_sample <= chroma_mem[8'd128 + stream_i[7:0]];
					if (stream_i == 9'(CHROMA_N - 1))
						state <= ST_DONE;
					else
						stream_i <= stream_i + 9'd1;
				end
			end

			ST_DONE: begin
				fetch_busy <= 1'b0;
				fetch_done <= 1'b1;
				state <= ST_IDLE;
			end

			default: state <= ST_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
