// One current reconstruction bank and one immutable short-term reference bank.
`default_nettype none

module h264_dpb_i420_addr #(
	parameter int FRAME_W = 624,
	parameter int FRAME_H = 480
)(
	input wire [31:0] base,
	input wire [1:0] plane,
	input wire [15:0] x, y,
	output reg [31:0] addr
);
	always @* begin
		case (plane)
		0: addr = base + y * FRAME_W + {16'd0, x};
		1: addr = base + FRAME_W * FRAME_H + y * (FRAME_W/2) + {16'd0, x};
		default: addr = base + FRAME_W * FRAME_H * 5/4 + y * (FRAME_W/2) + {16'd0, x};
		endcase
	end
endmodule

module h264_dpb_mb_write_addr #(
	parameter int FRAME_W = 624,
	parameter int FRAME_H = 480
)(
	input wire [31:0] bank_base,
	input wire [7:0] mb_x, mb_y,
	input wire [1:0] plane,
	input wire [7:0] sample_idx,
	output wire [31:0] addr
);
	wire [15:0] px = plane == 0 ? {4'd0, mb_x, 4'd0} + {12'd0, sample_idx[3:0]} :
	                             {5'd0, mb_x, 3'd0} + {13'd0, sample_idx[2:0]};
	wire [15:0] py = plane == 0 ? {4'd0, mb_y, 4'd0} + {12'd0, sample_idx[7:4]} :
	                             {5'd0, mb_y, 3'd0} + {13'd0, sample_idx[5:3]};
	h264_dpb_i420_addr #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) u_addr (
		.base(bank_base), .plane(plane), .x(px), .y(py), .addr(addr)
	);
endmodule

// Caller contract:
// - frame_start opens a complete picture; idr_start also invalidates the old ref.
// - frame_width/height are coded (not cropped) dimensions sampled at either
//   start. A geometry change requires idr_start with valid geometry at that edge.
// - Allocation strides/bank offsets remain FRAME_W/FRAME_H, independent of the
//   current coded rectangle. Reference geometry changes only on promotion.
// - Only reconstructed/filtered YUV may write. Hold sample metadata while !ready.
// - frame_done seals a fully filtered picture, after BOTH sides of every edge.
// - mem_wdrained fences accepted backend writes. Publish only on frame_promoted.
// - frame_abort discards a partial picture and drains all accepted reads/writes.
// - mem_rd/mem_rready accepts a byte request; mem_rvalid returns requests IN
//   ORDER at any latency, including the accepting cycle. Two registered credits
//   permit bounded prefetch. READY must reflect backend capacity. Request VALID
//   never depends combinationally on response VALID (zero-latency-safe).
// - Caller window arrays remain immutable until the next fetch: an identical
//   cached fetch completes without replaying sample events.
module h264_dpb_one_ref #(
	parameter int FRAME_W = 624,
	parameter int FRAME_H = 480,
	parameter int BANK0_BASE = 0,
	parameter int BANK1_BASE = FRAME_W * FRAME_H * 3/2
)(
	input wire clk, reset,
	input wire idr_start, frame_start, frame_abort, frame_done,
	input wire [15:0] frame_width, frame_height,
	output reg ref_ready,
	output wire frame_error,
	output reg frame_promoted,
	output reg [31:0] current_base, reference_base,
	output reg [15:0] reference_width, reference_height,
	input wire filtered_sample_valid,
	input wire [7:0] filtered_mb_x, filtered_mb_y,
	input wire [1:0] filtered_plane,
	input wire [7:0] filtered_sample_idx, filtered_sample,
	output wire filtered_sample_ready,
	output wire mem_we,
	output wire [31:0] mem_waddr,
	output wire [7:0] mem_wdata,
	input wire mem_wready, mem_wdrained,
	input wire fetch_start,
	input wire [7:0] fetch_mb_x, fetch_mb_y,
	input wire [2:0] fetch_part_mode,
	input wire [1:0] fetch_part_idx,
	input wire [4:0] fetch_part_w, fetch_part_h,
	input wire signed [15:0] fetch_mv_x_qpel, fetch_mv_y_qpel,
	output reg fetch_busy, fetch_done, fetch_error_no_ref,
	output reg [1:0] luma_frac_x, luma_frac_y,
	output reg [2:0] chroma_frac_x, chroma_frac_y,
	output reg signed [15:0] luma_origin_x, luma_origin_y,
	output reg signed [15:0] chroma_origin_x, chroma_origin_y,
	output wire mem_rd,
	output wire [31:0] mem_raddr,
	input wire mem_rready,
	input wire [7:0] mem_rdata,
	input wire mem_rvalid,
	output reg luma_window_valid,
	output reg [8:0] luma_window_idx,
	output reg [7:0] luma_window_sample,
	output reg chroma_u_window_valid, chroma_v_window_valid,
	output reg [6:0] chroma_window_idx,
	output reg [7:0] chroma_window_sample
);
	localparam [2:0] IDLE = 0, READ = 1, DRAIN = 3, CANCEL = 4;
	reg [2:0] state;
	reg [1:0] plane;
	reg [8:0] index;
	reg [1:0] issue_plane, outstanding;
	reg [8:0] issue_index;
	reg [4:0] issue_col, issue_row;
	reg issue_finished;
	reg packed_copy;
	reg frame_done_d, promote_pending, poisoned;
	reg [31:0] written;
	reg [15:0] coded_width, coded_height;
	reg geometry_known, idr_required;
	assign frame_error = poisoned || idr_required;
	wire valid_geometry = frame_width != 0 && frame_height != 0 &&
		frame_width[3:0] == 0 && frame_height[3:0] == 0 &&
		int'(frame_width) <= FRAME_W && int'(frame_height) <= FRAME_H;
	wire geometry_changed = geometry_known &&
		(frame_width != coded_width || frame_height != coded_height);
	wire [31:0] picture_samples = (32'(coded_width) * 32'(coded_height)) * 3 / 2;
	reg cache_valid;
	reg [7:0] cache_mb_x, cache_mb_y;
	reg signed [15:0] cache_mv_x, cache_mv_y;
	wire frame_done_pulse = frame_done && !frame_done_d;
	wire [31:0] write_ordinal =
		(filtered_mb_y * {20'd0, coded_width[15:4]} + {24'd0, filtered_mb_x}) * 384 +
		(filtered_plane == 0 ? 32'd0 : filtered_plane == 1 ? 32'd256 : 32'd320) +
		{24'd0, filtered_sample_idx};
	wire valid_write_coord = {4'd0, filtered_mb_x} < coded_width[15:4] &&
		{4'd0, filtered_mb_y} < coded_height[15:4] &&
		filtered_plane < 3 && (filtered_plane == 0 || filtered_sample_idx < 64);
	wire valid_write_order = valid_write_coord && write_ordinal <= written;
	// Initial writes cover every sample in MB Y/U/V order. Later p/q filter
	// updates may revisit accepted samples, but cannot fill a gap by counting twice.
	assign filtered_sample_ready = mem_wready && !poisoned && !promote_pending &&
		geometry_known && !idr_required && state != CANCEL &&
		!frame_abort && !idr_start && !frame_start;
	assign mem_we = filtered_sample_valid && valid_write_order && !poisoned &&
		!promote_pending && geometry_known && !idr_required && state != CANCEL &&
		!frame_abort && !idr_start && !frame_start;
	assign mem_wdata = filtered_sample;
	h264_dpb_mb_write_addr #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) u_write_addr (
		.bank_base(current_base), .mb_x(filtered_mb_x), .mb_y(filtered_mb_y),
		.plane(filtered_plane), .sample_idx(filtered_sample_idx), .addr(mem_waddr)
	);

	function automatic [15:0] clamp_coord(input signed [16:0] v, input integer limit);
		if (v < 0 || limit <= 0) clamp_coord = 0;
		else if (int'(v) >= limit) clamp_coord = 16'(limit - 1);
		else clamp_coord = v[15:0];
	endfunction
	wire signed [16:0] sx = issue_plane == 0 ?
		$signed({luma_origin_x[15], luma_origin_x}) +
		($signed({12'd0, issue_col}) - (packed_copy ? 17'sd0 : 17'sd2)) :
		$signed({chroma_origin_x[15], chroma_origin_x}) +
		$signed({12'd0, issue_col});
	wire signed [16:0] sy = issue_plane == 0 ?
		$signed({luma_origin_y[15], luma_origin_y}) +
		($signed({12'd0, issue_row}) - (packed_copy ? 17'sd0 : 17'sd2)) :
		$signed({chroma_origin_y[15], chroma_origin_y}) +
		$signed({12'd0, issue_row});
	reg [15:0] rx, ry;
	reg address_valid;
	reg [1:0] address_plane;
	h264_dpb_i420_addr #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) u_read_addr (
		.base(reference_base), .plane(address_plane), .x(rx), .y(ry), .addr(mem_raddr)
	);
	assign mem_rd = state == READ && address_valid && outstanding < 2 &&
		!frame_abort && !idr_start && !frame_start;
	wire read_accept = mem_rd && mem_rready;
	wire prepare_address = state == READ && !issue_finished &&
		(!address_valid || read_accept);
	wire response = mem_rvalid && (outstanding != 0 || read_accept);
	wire [2:0] outstanding_next = {1'b0,outstanding} + (read_accept ? 3'd1 : 3'd0) -
		(response ? 3'd1 : 3'd0);
	wire last_index = index == (plane == 0 ? (packed_copy ? 9'd255 : 9'd440) :
	                                                       (packed_copy ? 9'd63 : 9'd80));
	wire last_issue = issue_index == (issue_plane == 0 ? (packed_copy ? 9'd255 : 9'd440) :
	                                                               (packed_copy ? 9'd63 : 9'd80));
	wire last_issue_col = issue_col == (issue_plane == 0 ? (packed_copy ? 5'd15 : 5'd20) :
	                                                                    (packed_copy ? 5'd7 : 5'd8));
	wire supported_fetch = fetch_part_mode == 0 && fetch_part_idx == 0 &&
		fetch_part_w == 16 && fetch_part_h == 16 &&
		{4'd0, fetch_mb_x} < coded_width[15:4] &&
		{4'd0, fetch_mb_y} < coded_height[15:4];
	wire signed [15:0] fetch_luma_x =
		$signed({4'd0, fetch_mb_x, 4'd0}) + (fetch_mv_x_qpel >>> 2);
	wire signed [15:0] fetch_luma_y =
		$signed({4'd0, fetch_mb_y, 4'd0}) + (fetch_mv_y_qpel >>> 2);
	wire fetch_packed = fetch_mv_x_qpel == 0 && fetch_mv_y_qpel == 0;

	always @(posedge clk) begin
		luma_window_valid <= 0;
		chroma_u_window_valid <= 0;
		chroma_v_window_valid <= 0;
		frame_promoted <= 0;
		if (reset) begin
			current_base <= BANK0_BASE;
			reference_base <= BANK1_BASE;
			ref_ready <= 0;
			reference_width <= 0; reference_height <= 0;
			coded_width <= 16'(FRAME_W); coded_height <= 16'(FRAME_H);
			geometry_known <= 0; idr_required <= 0;
			written <= 0;
			poisoned <= 0;
			promote_pending <= 0;
			frame_done_d <= 0;
			state <= IDLE;
			fetch_busy <= 0;
			fetch_done <= 0;
			fetch_error_no_ref <= 0;
			cache_valid <= 0;
			cache_mb_x <= 0; cache_mb_y <= 0;
			cache_mv_x <= 0; cache_mv_y <= 0;
			plane <= 0; index <= 0; packed_copy <= 0;
			issue_plane <= 0; issue_index <= 0; issue_finished <= 0; outstanding <= 0;
			issue_col <= 0; issue_row <= 0;
			address_valid <= 0; address_plane <= 0; rx <= 0; ry <= 0;
			luma_frac_x <= 0; luma_frac_y <= 0;
			chroma_frac_x <= 0; chroma_frac_y <= 0;
			luma_origin_x <= 0; luma_origin_y <= 0;
			chroma_origin_x <= 0; chroma_origin_y <= 0;
			luma_window_idx <= 0; luma_window_sample <= 0;
			chroma_window_idx <= 0; chroma_window_sample <= 0;
		end else begin
			frame_done_d <= frame_done;
			outstanding <= outstanding_next[1:0];
			// Separate signed origin/clamp from pitch/bank addressing.
			// Refill the held address slot on acceptance, without a per-byte
			// bubble. Only accepted backend reads consume either read credit.
			if (read_accept) address_valid <= 0;
			if (prepare_address) begin
				rx <= clamp_coord(sx, issue_plane == 0 ? int'(reference_width) : int'(reference_width)/2);
				ry <= clamp_coord(sy, issue_plane == 0 ? int'(reference_height) : int'(reference_height)/2);
				address_plane <= issue_plane;
				address_valid <= 1;
				// Backpressure holds the prepared offer and its next context.
				if (last_issue) begin
					if (issue_plane != 2) begin issue_col <= 0; issue_row <= 0; end
				end else if (last_issue_col) begin
					issue_col <= 0; issue_row <= issue_row + 1'b1;
				end else issue_col <= issue_col + 1'b1;
				if (last_issue) begin
					if (issue_plane == 2) issue_finished <= 1;
					else begin issue_plane <= issue_plane + 1'b1; issue_index <= 0; end
				end else issue_index <= issue_index + 1'b1;
			end
			if (filtered_sample_valid && filtered_sample_ready) begin
				if (!valid_write_order) poisoned <= 1;
				else if (write_ordinal == written) written <= written + 1;
			end
			if (frame_done_pulse) promote_pending <= 1;
			if (promote_pending && mem_wdrained && state == IDLE && !frame_abort && !idr_start && !frame_start) begin
				promote_pending <= 0;
				cache_valid <= 0;
				if (!poisoned && geometry_known && !idr_required && written == picture_samples) begin
					reference_base <= current_base;
					reference_width <= coded_width;
					reference_height <= coded_height;
					current_base <= current_base == BANK0_BASE ? BANK1_BASE : BANK0_BASE;
					ref_ready <= 1;
					frame_promoted <= 1;
					written <= 0;
				end else begin
					poisoned <= 1;
					ref_ready <= 0;
				end
			end
			case (state)
			IDLE: begin
				fetch_busy <= 0;
				if (fetch_start) begin
					fetch_done <= 0;
					fetch_error_no_ref <= !ref_ready || frame_error || !supported_fetch || promote_pending || frame_done;
					luma_frac_x <= fetch_mv_x_qpel[1:0];
					luma_frac_y <= fetch_mv_y_qpel[1:0];
					chroma_frac_x <= fetch_mv_x_qpel[2:0];
					chroma_frac_y <= fetch_mv_y_qpel[2:0];
					// Arithmetic shifts implement floor, including negative MVs.
					luma_origin_x <= fetch_luma_x;
					luma_origin_y <= fetch_luma_y;
					chroma_origin_x <= $signed({5'd0, fetch_mb_x, 3'd0}) + (fetch_mv_x_qpel >>> 3);
					chroma_origin_y <= $signed({5'd0, fetch_mb_y, 3'd0}) + (fetch_mv_y_qpel >>> 3);
					if (!ref_ready || frame_error || !supported_fetch || promote_pending || frame_done) begin
						fetch_done <= 1;
					end else if (cache_valid && cache_mb_x == fetch_mb_x && cache_mb_y == fetch_mb_y &&
					             cache_mv_x == fetch_mv_x_qpel && cache_mv_y == fetch_mv_y_qpel) begin
						fetch_done <= 1;
					end else begin
						cache_valid <= 0;
						cache_mb_x <= fetch_mb_x; cache_mb_y <= fetch_mb_y;
						cache_mv_x <= fetch_mv_x_qpel; cache_mv_y <= fetch_mv_y_qpel;
						packed_copy <= fetch_packed;
						plane <= 0; index <= 0;
						// Prime the first clamped coordinate on start, preserving
						// the original first-request and whole-window cycle budget.
						rx <= clamp_coord($signed({fetch_luma_x[15],fetch_luma_x}) -
							(fetch_packed ? 17'sd0 : 17'sd2), int'(reference_width));
						ry <= clamp_coord($signed({fetch_luma_y[15],fetch_luma_y}) -
							(fetch_packed ? 17'sd0 : 17'sd2), int'(reference_height));
						address_plane <= 0; address_valid <= 1;
						issue_plane <= 0; issue_index <= 1; issue_finished <= 0;
						issue_col <= 1; issue_row <= 0;
						state <= READ; fetch_busy <= 1;
					end
				end
			end
			READ: begin end
			DRAIN: begin
				// Allow the caller to store the final registered window sample.
				state <= IDLE; fetch_busy <= 0; fetch_done <= 1; cache_valid <= 1;
			end
			CANCEL: if (outstanding_next == 0 && mem_wdrained) begin state <= IDLE; fetch_busy <= 0; end
			default: state <= IDLE;
			endcase
			if (response && state == READ) begin
				case (plane)
				0: begin
					luma_window_valid <= 1; luma_window_idx <= index; luma_window_sample <= mem_rdata;
				end
				1: begin
					chroma_u_window_valid <= 1; chroma_window_idx <= index[6:0]; chroma_window_sample <= mem_rdata;
				end
				default: begin
					chroma_v_window_valid <= 1; chroma_window_idx <= index[6:0]; chroma_window_sample <= mem_rdata;
				end
				endcase
				if (last_index) begin
					index <= 0;
					if (plane == 2) state <= DRAIN;
					else begin plane <= plane + 1'b1; state <= READ; end
				end else begin index <= index + 1'b1; state <= READ; end
			end
			if (frame_abort || idr_start || frame_start) begin
				address_valid <= 0;
				written <= 0;
				promote_pending <= 0;
				poisoned <= frame_abort;
				cache_valid <= 0;
				if (frame_abort || idr_start) ref_ready <= 0;
				if (frame_start || idr_start) begin
					if (!valid_geometry || (!idr_start && (geometry_changed || idr_required))) begin
						poisoned <= 1;
						idr_required <= 1;
						ref_ready <= 0;
					end else begin
						coded_width <= frame_width;
						coded_height <= frame_height;
						geometry_known <= 1;
						if (idr_start) idr_required <= 0;
					end
				end
				fetch_done <= 0;
				fetch_error_no_ref <= frame_abort;
				luma_window_valid <= 0;
				chroma_u_window_valid <= 0;
				chroma_v_window_valid <= 0;
				// Keep both read credits and accepted backend writes fenced;
				// neither a late response nor a late store may enter a new job.
				if (outstanding_next != 0 || !mem_wdrained) begin
					state <= CANCEL; fetch_busy <= 1;
				end else begin state <= IDLE; fetch_busy <= 0; end
			end
		end
	end
endmodule

module h264_luma_qpel_block_16x16 #(
	parameter bit SYNC_REFERENCE = 1'b0
) (
	input wire clk, reset, start,
	input wire [7:0] ref_win [0:440],
	input wire packed_copy,
	output wire [8:0] ref_address,
	input wire [7:0] ref_data,
	input wire [1:0] frac_x, frac_y,
	output reg [7:0] pred [0:255],
	output reg done,
	output wire sample_valid,
	output wire [7:0] sample_index, sample_value
);
	localparam [2:0] IDLE=0, HSCAN=1, HDRAIN=2, VSCAN=3, VDRAIN=4, OUTPUT=5;
	reg [2:0] state;
	reg [1:0] fx, fy;
	reg [4:0] row, col, read_row, read_col;
	wire [7:0] reference_read;
	reg packed_reference;
	reg raw_read_hit;
	wire signed [15:0] horizontal_read;
	wire signed [15:0] raw_read = raw_read_hit ? horizontal_read : 16'sd0;
	reg h_valid, v_valid;
	reg [7:0] h0,h1,h2,h3,h4, v0,v1,v2,v3,v4;
	reg signed [15:0] c0,c1,c2,c3,c4;
	wire [7:0] half_h_read, half_v_read, half_c_read;
	reg [7:0] out_idx;
	wire need_center = fx != 0 && fy != 0 && (fx == 2 || fy == 2);
	wire [4:0] last_h_row = need_center ? 5'd20 : (fy == 3 ? 5'd18 : 5'd17);
	// A sliding six-tap lane consumes each window byte once. Keep unrounded
	// horizontal sums for the diagonal pass: clipping them first is not H.264.
	function automatic signed [31:0] fir(
		input signed [31:0] a,b,c,d,e,f
	);
		fir = a - 5*b + 20*c + 20*d - 5*e + f;
	endfunction
	function automatic [7:0] clip(input signed [31:0] n);
		if (n < 0) clip = 0;
		else if (n > 255) clip = 255;
		else clip = n[7:0];
	endfunction
	function automatic [7:0] avg(input [7:0] a,b);
		reg [8:0] sum;
		begin sum = {1'b0,a}+{1'b0,b}+9'd1; avg = sum[8:1]; end
	endfunction
	wire signed [31:0] hf = fir({24'd0,h0},{24'd0,h1},{24'd0,h2},{24'd0,h3},{24'd0,h4},{24'd0,reference_read});
	wire signed [31:0] vf = fir({24'd0,v0},{24'd0,v1},{24'd0,v2},{24'd0,v3},{24'd0,v4},{24'd0,reference_read});
	wire signed [31:0] cf = fir(32'(c0),32'(c1),32'(c2),32'(c3),32'(c4),32'(raw_read));
	// Start/drain primes pixel0. Each output consumes its registered reads
	// while requesting the successor, preserving one output per clock.
	wire [7:0] output_read_index = state == OUTPUT && out_idx != 255 ? out_idx + 8'd1 : out_idx;
	wire [3:0] ox = output_read_index[3:0], oy = output_read_index[7:4];
	wire [7:0] g = reference_read, right_p = reference_read, below_p = reference_read;
	wire [7:0] hh = half_h_read, hh_below = half_h_read;
	wire [7:0] hv = half_v_read, hv_right = half_v_read, hc = half_c_read;
	wire [8:0] reference_address = start && state == IDLE ?
		(SYNC_REFERENCE && packed_copy ? 9'd0 : 9'd44) :
		state == HSCAN ? 9'(int'(row)*21+int'(col)) :
		state == VSCAN ? 9'(int'(row)*21+int'(col)+2) :
		packed_reference ? {1'b0,output_read_index} :
		9'((int'(oy)+2+(fy==3 && fx==0 ? 1 : 0))*21+int'(ox)+2+
		   (fy==0 && fx==3 ? 1 : 0));
	assign ref_address=reference_address;
	wire horizontal_write = !reset && h_valid && read_col >= 5;
	wire vertical_write = !reset && v_valid && read_row >= 5;
	wire [8:0] raw_write_address = 9'(int'(read_row)*16+int'(read_col)-5);
	wire [8:0] raw_read_address = state == VSCAN && need_center && col < 16 ?
		9'(int'(row)*16+int'(col)) : 9'd0;
	wire [8:0] h_write_address = 9'((int'(read_row)-2)*16+int'(read_col)-5);
	wire [8:0] v_write_address = 9'((int'(read_row)-5)*17+int'(read_col));
	wire [7:0] c_write_address = 8'((int'(read_row)-5)*16+int'(read_col));
	wire [8:0] h_read_address = {1'b0,output_read_index} + (fy==3 ? 9'd16 : 9'd0);
	wire [8:0] v_read_address = 9'(int'(oy)*17+int'(ox)+(fx==3 ? 1 : 0));
	// Separate reset-free RAM ports from the control/result registers. One
	// selected address per cache replaces parallel asynchronous output muxes.
	line_buf_ram #(.WIDTH(336), .AW(9), .DATA_W(16)) raw_cache (
		.wr_clk(clk), .wr_en(horizontal_write && need_center),
		.wr_addr(raw_write_address), .wr_data(hf[15:0]),
		.rd_clk(clk), .rd_addr(raw_read_address), .rd_data(horizontal_read)
	);
	line_buf_ram #(.WIDTH(272), .AW(9), .DATA_W(8)) h_cache (
		.wr_clk(clk), .wr_en(horizontal_write && read_row >= 2 && read_row <= 18),
		.wr_addr(h_write_address), .wr_data(clip((hf+16)>>>5)),
		.rd_clk(clk), .rd_addr(h_read_address), .rd_data(half_h_read)
	);
	line_buf_ram #(.WIDTH(272), .AW(9), .DATA_W(8)) v_cache (
		.wr_clk(clk), .wr_en(vertical_write),
		.wr_addr(v_write_address), .wr_data(clip((vf+16)>>>5)),
		.rd_clk(clk), .rd_addr(v_read_address), .rd_data(half_v_read)
	);
	line_buf_ram #(.WIDTH(256), .AW(8), .DATA_W(8)) c_cache (
		.wr_clk(clk), .wr_en(vertical_write && need_center && read_col < 16),
		.wr_addr(c_write_address), .wr_data(clip((cf+512)>>>10)),
		.rd_clk(clk), .rd_addr(output_read_index), .rd_data(half_c_read)
	);
	generate if (SYNC_REFERENCE) begin: g_sync_reference
		assign reference_read=ref_data;
	end else begin: g_parallel_reference
		reg [7:0] sample_q;
		always @(posedge clk) begin
			if ((start && state == IDLE) || state == HSCAN || state == VSCAN ||
			    state == HDRAIN || state == VDRAIN || (state == OUTPUT && out_idx != 255))
				sample_q <= ref_win[reference_address];
		end
		assign reference_read=sample_q;
	end endgenerate
	reg [7:0] result;
	assign sample_valid=!reset && state==OUTPUT;
	assign sample_index=out_idx;
	assign sample_value=result;
	always @* begin
		case ({fy,fx})
		0: result=g;                 1: result=avg(g,hh);
		2: result=hh;                3: result=avg(hh,right_p);
		4: result=avg(g,hv);          5: result=avg(hh,hv);
		6: result=avg(hh,hc);         7: result=avg(hh,hv_right);
		8: result=hv;                9: result=avg(hv,hc);
		10: result=hc;               11: result=avg(hc,hv_right);
		12: result=avg(hv,below_p);   13: result=avg(hh_below,hv);
		14: result=avg(hc,hh_below);  default: result=avg(hh_below,hv_right);
		endcase
	end
	always @(posedge clk) begin
		done <= 0;
		if (reset) begin
			state <= IDLE; h_valid <= 0; v_valid <= 0; raw_read_hit <= 0;
			packed_reference <= 0;
			row <= 0; col <= 0; out_idx <= 0; fx <= 0; fy <= 0;
		end else begin
			h_valid <= state == HSCAN;
			v_valid <= state == VSCAN;
			if (state == HSCAN) begin
				read_row <= row; read_col <= col;
				if (col == 20) begin
					col <= 0;
					if (row == last_h_row) state <= HDRAIN;
					else row <= row+1'b1;
				end else col <= col+1'b1;
			end
			if (h_valid) begin
				h0<=h1; h1<=h2; h2<=h3; h3<=h4; h4<=reference_read;
			end
			if (state == HDRAIN) begin
				row<=0; col<=0;
				state<=fy == 0 ? OUTPUT : VSCAN;
			end
			if (state == VSCAN) begin
				raw_read_hit <= need_center && col < 16;
				read_row <= row; read_col <= col;
				if (row == 20) begin
					row <= 0;
					if (col == (fx == 3 ? 5'd16 : 5'd15)) state <= VDRAIN;
					else col <= col+1'b1;
				end else row <= row+1'b1;
			end
			if (v_valid) begin
				v0<=v1; v1<=v2; v2<=v3; v3<=v4; v4<=reference_read;
				c0<=c1; c1<=c2; c2<=c3; c3<=c4; c4<=raw_read;
			end
			if (state == VDRAIN) begin out_idx<=0; state<=OUTPUT; end
			if (state == OUTPUT) begin
				pred[out_idx] <= result;
				if (out_idx == 255) begin state<=IDLE; done<=1; end
				else out_idx <= out_idx+1'b1;
			end
			if (start && state == IDLE) begin
				packed_reference <= SYNC_REFERENCE && packed_copy;
				fx<=frac_x; fy<=frac_y; col<=0; out_idx<=0;
				// Odd/odd quarter positions average H and V directly: no
				// diagonal six-by-six pass, nor its five halo rows, is needed.
				row<=(frac_y == 0 || (frac_x[0] && frac_y[0])) ?
					(frac_y == 3 ? 5'd3 : 5'd2) : 5'd0;
				// Axis-aligned phases need only one six-tap direction.
				state <= frac_x == 0 ? (frac_y == 0 ? OUTPUT : VSCAN) : HSCAN;
			end
		end
	end
endmodule

module h264_chroma_epel_block_8x8 #(
	parameter bit SYNC_REFERENCE = 1'b0
) (
	input wire clk, reset, start,
	input wire [7:0] ref_win [0:80],
	input wire packed_copy,
	output wire [5:0] ref_index,
	input wire [7:0] ref_quad [0:3],
	input wire [2:0] frac_x, frac_y,
	output reg [7:0] pred [0:63],
	output reg done,
	output wire sample_valid,
	output wire [5:0] sample_index,
	output wire [7:0] sample_value
);
	reg busy;
	reg [5:0] index;
	reg [2:0] fx,fy;
	reg packed_reference;
	reg product_valid;
	reg [5:0] product_index;
	reg [10:0] horizontal_top, horizontal_bottom;
	reg [7:0] packed_sample;
	assign ref_index = start && !busy ? 6'd0 :
		busy && index != 63 ? index+6'd1 : index;
	wire [6:0] pos = {1'b0,index[5:3],3'b0}+{4'd0,index[5:3]}+{4'd0,index[2:0]};
	wire [7:0] a = SYNC_REFERENCE ? ref_quad[0] : ref_win[pos];
	wire [7:0] b = SYNC_REFERENCE ? ref_quad[1] : ref_win[pos+7'd1];
	wire [7:0] c = SYNC_REFERENCE ? ref_quad[2] : ref_win[pos+7'd9];
	wire [7:0] d = SYNC_REFERENCE ? ref_quad[3] : ref_win[pos+7'd10];
	wire [3:0] ax = 4'd8-{1'b0,fx}, ay=4'd8-{1'b0,fy};
	wire [13:0] sum = horizontal_top*ay +
		horizontal_bottom*{1'b0,fy} + 14'd32;
	assign sample_valid=!reset && product_valid;
	assign sample_index=product_index;
	assign sample_value=packed_reference ? packed_sample : sum[13:6];
	always @(posedge clk) begin
		done <= 0;
		if (reset) begin
			busy<=0; index<=0; fx<=0; fy<=0; packed_reference<=0; product_valid<=0;
		end else begin
			product_valid <= busy;
			if (start && !busy && !product_valid) begin
				busy<=1; index<=0; fx<=frac_x; fy<=frac_y;
				packed_reference<=SYNC_REFERENCE && packed_copy;
			end
			if (busy) begin
				// No intermediate rounding: each horizontal sum is <=2040,
				// and the final rounded numerator is <=16352.
				horizontal_top <= ax*a + {1'b0,fx}*b;
				horizontal_bottom <= ax*c + {1'b0,fx}*d;
				packed_sample <= a;
				product_index <= index;
				if (index == 63) busy<=0;
				else index<=index+1'b1;
			end
			if (product_valid) begin
				pred[product_index] <= sample_value;
				if (product_index == 63) done<=1;
			end
		end
	end
endmodule

module h264_inter_mc_16x16 #(
	parameter bit SYNC_REFERENCE = 1'b0
) (
	input wire clk, reset, start,
	input wire [7:0] luma_ref_win [0:440],
	input wire [7:0] chroma_u_ref_win [0:80], chroma_v_ref_win [0:80],
	input wire packed_copy,
	input wire luma_write, chroma_u_write, chroma_v_write,
	input wire [8:0] luma_write_index,
	input wire [6:0] chroma_write_index,
	input wire [7:0] luma_write_data, chroma_write_data,
	input wire [1:0] luma_frac_x, luma_frac_y,
	input wire [2:0] chroma_frac_x, chroma_frac_y,
	output wire [7:0] pred_y [0:255],
	output reg [7:0] pred_u [0:63], pred_v [0:63],
	output reg done,
	output wire pred_y_valid, pred_c_valid, pred_c_v,
	output wire [7:0] pred_y_index, pred_y_sample, pred_c_sample,
	output wire [5:0] pred_c_index
);
	wire luma_done, chr_done;
	reg chr_start, chr_is_v, busy, luma_finished, chroma_finished;
	reg [2:0] cfx,cfy;
	wire [7:0] chr_win [0:80], chr_pred [0:63];
	wire [8:0] luma_read_address;
	wire [7:0] luma_read_data, chroma_quad [0:3];
	wire [5:0] chroma_read_index;
	reg packed_reference;
	assign pred_c_v=chr_is_v;
	genvar g;
	generate if (SYNC_REFERENCE) begin: g_reference_ram
		line_buf_ram #(.WIDTH(441), .AW(9), .DATA_W(8)) luma_ram (
			.wr_clk(clk), .wr_en(!reset && luma_write),
			.wr_addr(luma_write_index), .wr_data(luma_write_data),
			.rd_clk(clk), .rd_addr(luma_read_address), .rd_data(luma_read_data)
		);
		// Four parity banks service one 2x2 neighbourhood per clock. Each
		// bank stores both planes (25 cells each), with no payload reset.
		wire [3:0] wy = packed_copy ? {1'b0,chroma_write_index[5:3]} :
			4'(chroma_write_index/9);
		wire [3:0] wx = packed_copy ? {1'b0,chroma_write_index[2:0]} :
			4'(chroma_write_index%9);
		wire [5:0] wa = 6'((wy>>1)*5+(wx>>1)+(chroma_v_write ? 25 : 0));
		wire [7:0] bank_q [0:3];
		reg [1:0] read_parity;
		always @(posedge clk)
			read_parity<={chroma_read_index[3],chroma_read_index[0]};
		for (g=0;g<4;g=g+1) begin: g_chroma_bank
			wire [3:0] ry = {1'b0,chroma_read_index[5:3]} +
				(chroma_read_index[3] != ((g>>1)&1) ? 4'd1 : 4'd0);
			wire [3:0] rx = {1'b0,chroma_read_index[2:0]} +
				(chroma_read_index[0] != (g&1) ? 4'd1 : 4'd0);
			wire [5:0] ra = 6'((ry>>1)*5+(rx>>1)+(chr_is_v ? 25 : 0));
			line_buf_ram #(.WIDTH(50), .AW(6), .DATA_W(8)) chroma_ram (
				.wr_clk(clk),
				.wr_en(!reset && (chroma_u_write || chroma_v_write) && {wy[0],wx[0]}==g),
				.wr_addr(wa), .wr_data(chroma_write_data),
				.rd_clk(clk), .rd_addr(ra), .rd_data(bank_q[g])
			);
			assign chroma_quad[g]=bank_q[read_parity ^ 2'(g)];
		end
	end else begin: g_parallel_ram_ports
		assign luma_read_data=0;
		for (g=0;g<4;g=g+1) begin: g_quad
			assign chroma_quad[g]=0;
		end
	end endgenerate
	generate for (g=0; g<81; g=g+1) begin : g_chr_mux
		assign chr_win[g] = chr_is_v ? chroma_v_ref_win[g] : chroma_u_ref_win[g];
	end endgenerate
	h264_luma_qpel_block_16x16 #(.SYNC_REFERENCE(SYNC_REFERENCE)) u_luma (
		.clk(clk), .reset(reset), .start(start && !busy), .ref_win(luma_ref_win),
		.packed_copy(packed_copy), .ref_address(luma_read_address), .ref_data(luma_read_data),
		.sample_valid(pred_y_valid), .sample_index(pred_y_index), .sample_value(pred_y_sample),
		.frac_x(luma_frac_x), .frac_y(luma_frac_y), .pred(pred_y), .done(luma_done)
	);
	h264_chroma_epel_block_8x8 #(.SYNC_REFERENCE(SYNC_REFERENCE)) u_chroma (
		.clk(clk), .reset(reset), .start(chr_start), .ref_win(chr_win),
		.packed_copy(packed_reference), .ref_index(chroma_read_index), .ref_quad(chroma_quad),
		.sample_valid(pred_c_valid), .sample_index(pred_c_index), .sample_value(pred_c_sample),
		.frac_x(cfx), .frac_y(cfy), .pred(chr_pred), .done(chr_done)
	);
	integer i;
	always @(posedge clk) begin
		done<=0; chr_start<=0;
		if (reset) begin
			chr_is_v<=0; busy<=0; cfx<=0; cfy<=0;
			luma_finished<=0; chroma_finished<=0;
			packed_reference<=0;
		end else if (start && !busy) begin
			busy<=1; chr_is_v<=0; chr_start<=1;
			cfx<=chroma_frac_x; cfy<=chroma_frac_y;
			packed_reference<=SYNC_REFERENCE && packed_copy;
			luma_finished<=0; chroma_finished<=0;
		end else if (busy) begin
			// The existing shared U/V lane runs alongside luma, not after it.
			if (luma_done) luma_finished<=1;
			if (chr_done && !chr_is_v) begin
				for (i=0; i<64; i=i+1) pred_u[i]<=chr_pred[i];
				chr_is_v<=1; chr_start<=1;
			end else if (chr_done && chr_is_v) begin
				for (i=0; i<64; i=i+1) pred_v[i]<=chr_pred[i];
				chroma_finished<=1;
			end
			if ((luma_finished || luma_done) &&
			    (chroma_finished || (chr_done && chr_is_v))) begin
				done<=1; busy<=0;
			end
		end
	end
endmodule

// Legacy combinational partition interface cannot clock the sequential MC.
// Do not advertise valid uncomputed predictions; only P16 is implemented.
module h264_inter_mc_part (
	input wire [7:0] luma_ref_win [0:440],
	input wire [7:0] chroma_u_ref_win [0:80], chroma_v_ref_win [0:80],
	input wire [1:0] luma_frac_x, luma_frac_y,
	input wire [2:0] chroma_frac_x, chroma_frac_y,
	input wire [4:0] part_w, part_h,
	output wire [7:0] pred_y [0:255],
	output wire pred_y_valid [0:255],
	output wire [7:0] pred_u [0:63],
	output wire pred_u_valid [0:63],
	output wire [7:0] pred_v [0:63],
	output wire pred_v_valid [0:63]
);
	genvar i;
	generate
		for (i=0; i<256; i=i+1) begin : g_y
			assign pred_y[i]=0; assign pred_y_valid[i]=0;
		end
		for (i=0; i<64; i=i+1) begin : g_c
			assign pred_u[i]=0; assign pred_v[i]=0;
			assign pred_u_valid[i]=0; assign pred_v_valid[i]=0;
		end
	endgenerate
endmodule
`default_nettype wire
