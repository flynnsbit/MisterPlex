// I-slice residual → Clip1(pred + residual) MB plane sink.
//
// Consumes h264_p_mb_traverse res_blk_* / res_mb_end stream.
// Cycle-iterative: one shared I4 pred + one IQ/IDCT per block (no MB-wide unroll).
// I16 uses h264_intra16x16_pred (1–2 cycles) then DC/AC residual onto that plane.
// Chroma deferred flat 128 (stated).
//
// Neighbours: top-row linebuf (frame width) + left column of current MB row.
// On res_mb_end, write_y/u/v are stable and write_req pulses for one cycle.

`default_nettype none

module h264_i_res_recon_sink #(
	parameter int MAX_PIC_W = 1024  // luma samples; 64 MB * 16
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,             // picture start: idle planes + nb

	input  wire        res_blk_valid,
	output wire        res_blk_ready,
	input  wire [15:0] res_blk_mb_addr,
	input  wire [7:0]  res_blk_mb_x,
	input  wire [7:0]  res_blk_mb_y,
	input  wire [4:0]  res_blk_idx,
	input  wire        res_blk_is_i16,
	input  wire        res_blk_is_luma,
	input  wire [5:0]  res_blk_qp,
	input  wire [4:0]  res_blk_max_coeff,
	input  wire [3:0]  res_blk_pred_mode, // I4 mode 0..8 or I16 mode 0..3 on DC
	input  wire signed [15:0] res_blk_coeff [0:15],

	input  wire        res_mb_end,
	input  wire [15:0] res_mb_end_addr,

	output reg         write_req,
	output reg  [15:0] write_mb_addr,
	output reg  [7:0]  write_y [0:255],
	output reg  [7:0]  write_u [0:63],
	output reg  [7:0]  write_v [0:63],
	input  wire        write_busy,
	output reg  [31:0] dbg_blk_applied,
	output reg  [31:0] dbg_mb_written,
	output reg  [31:0] dbg_luma_nz
);
	localparam [2:0]
		ST_IDLE     = 3'd0,
		ST_I16_PRED = 3'd1,
		ST_SETTLE   = 3'd2,
		ST_APPLY    = 3'd3;

	reg [2:0] st;
	reg        have_mb;
	reg [15:0] cur_mb;
	reg [7:0]  cur_mb_x, cur_mb_y;
	reg [7:0]  plane_y [0:255];
	reg [7:0]  plane_u [0:63];
	reg [7:0]  plane_v [0:63];

	reg [7:0] top_row [0:MAX_PIC_W-1];
	reg [7:0] left_col [0:15];
	reg [7:0] tl_mb;
	reg       left_col_v;

	reg        lat_is_i16;
	reg        lat_is_luma;
	reg [4:0]  lat_idx;
	reg [5:0]  lat_qp;
	reg [4:0]  lat_max;
	reg [3:0]  lat_mode;
	reg signed [15:0] lat_coeff [0:15];
	reg signed [15:0] i16_dc [0:15];
	reg        i16_dc_valid;
	reg        i16_pred_done;
	reg        pend_mb_end;
	reg [15:0] pend_mb_end_addr;

	assign res_blk_ready = (st == ST_IDLE) && !write_busy && !pend_mb_end;

	function automatic [1:0] blk4_x;
		input [3:0] i;
		begin
			case (i)
			4'd0,4'd2,4'd8,4'd10: blk4_x = 2'd0;
			4'd1,4'd3,4'd9,4'd11: blk4_x = 2'd1;
			4'd4,4'd6,4'd12,4'd14: blk4_x = 2'd2;
			default: blk4_x = 2'd3;
			endcase
		end
	endfunction
	function automatic [1:0] blk4_y;
		input [3:0] i;
		begin
			case (i)
			4'd0,4'd1,4'd4,4'd5: blk4_y = 2'd0;
			4'd2,4'd3,4'd6,4'd7: blk4_y = 2'd1;
			4'd8,4'd9,4'd12,4'd13: blk4_y = 2'd2;
			default: blk4_y = 2'd3;
			endcase
		end
	endfunction

	function automatic [7:0] clip_u8;
		input signed [17:0] v;
		begin
			if (v < 18'sd0) clip_u8 = 8'd0;
			else if (v > 18'sd255) clip_u8 = 8'd255;
			else clip_u8 = v[7:0];
		end
	endfunction

	function automatic [7:0] add_res;
		input [7:0] base;
		input signed [28:0] res;
		reg signed [17:0] s;
		begin
			s = $signed({10'd0, base}) + res[17:0];
			add_res = clip_u8(s);
		end
	endfunction

	wire [1:0] i4_bx = blk4_x(lat_idx[3:0]);
	wire [1:0] i4_by = blk4_y(lat_idx[3:0]);
	wire [4:0] i4_x0 = {i4_bx, 2'b00};
	wire [4:0] i4_y0 = {i4_by, 2'b00};

	reg [7:0] i4_above [0:7];
	reg [7:0] i4_left  [0:3];
	reg [7:0] i4_tl;
	reg       i4_ha, i4_hl;
	integer t;

	wire [15:0] abs_x0 = {8'd0, cur_mb_x} * 16'd16 + {11'd0, i4_x0};

	always @(*) begin
		i4_ha = 1'b0;
		i4_hl = 1'b0;
		i4_tl = 8'd128;
		for (t = 0; t < 8; t = t + 1) i4_above[t] = 8'd128;
		for (t = 0; t < 4; t = t + 1) i4_left[t] = 8'd128;

		if (i4_by != 2'd0) begin
			i4_ha = 1'b1;
			for (t = 0; t < 4; t = t + 1)
				i4_above[t] = plane_y[(i4_y0 - 5'd1) * 16 + (i4_x0 + t[4:0])];
			if (i4_x0 + 5'd4 < 5'd16) begin
				for (t = 0; t < 4; t = t + 1)
					i4_above[4 + t] = plane_y[(i4_y0 - 5'd1) * 16 + (i4_x0 + 5'd4 + t[4:0])];
			end else begin
				for (t = 0; t < 4; t = t + 1)
					i4_above[4 + t] = i4_above[3];
			end
		end else if (cur_mb_y != 8'd0) begin
			i4_ha = 1'b1;
			for (t = 0; t < 4; t = t + 1)
				if ((abs_x0 + t[15:0]) < MAX_PIC_W[15:0])
					i4_above[t] = top_row[abs_x0 + t[15:0]];
			for (t = 0; t < 4; t = t + 1) begin
				if ((abs_x0 + 16'd4 + t[15:0]) < MAX_PIC_W[15:0])
					i4_above[4 + t] = top_row[abs_x0 + 16'd4 + t[15:0]];
				else
					i4_above[4 + t] = i4_above[3];
			end
		end

		if (i4_bx != 2'd0) begin
			i4_hl = 1'b1;
			for (t = 0; t < 4; t = t + 1)
				i4_left[t] = plane_y[(i4_y0 + t[4:0]) * 16 + (i4_x0 - 5'd1)];
		end else if (cur_mb_x != 8'd0 && left_col_v) begin
			i4_hl = 1'b1;
			for (t = 0; t < 4; t = t + 1)
				i4_left[t] = left_col[i4_y0 + t[4:0]];
		end

		if (i4_ha && i4_hl) begin
			if (i4_bx != 2'd0 && i4_by != 2'd0)
				i4_tl = plane_y[(i4_y0 - 5'd1) * 16 + (i4_x0 - 5'd1)];
			else if (i4_bx != 2'd0 && i4_by == 2'd0)
				i4_tl = (abs_x0 > 0) ? top_row[abs_x0 - 16'd1] : 8'd128;
			else if (i4_bx == 2'd0 && i4_by != 2'd0)
				i4_tl = left_col[i4_y0 - 5'd1];
			else
				i4_tl = tl_mb;
		end else if (i4_ha)
			i4_tl = i4_above[0];
		else if (i4_hl)
			i4_tl = i4_left[0];
	end

	wire [7:0] i4_pred [0:15];
	wire [3:0] i4_used_mode;
	h264_intra4x4_pred u_i4 (
		.mode(lat_mode),
		.above(i4_above),
		.left(i4_left),
		.top_left(i4_tl),
		.has_above(i4_ha),
		.has_left(i4_hl),
		.used_mode(i4_used_mode),
		.pred(i4_pred)
	);

	reg [7:0] i16_above [0:15];
	reg [7:0] i16_left  [0:15];
	reg [7:0] i16_tl;
	reg       i16_ha, i16_hl;
	reg       i16_start;
	wire      i16_valid;
	wire      i16_unsup;
	wire [7:0] i16_pred [0:255];

	always @(*) begin
		i16_ha = (cur_mb_y != 8'd0);
		i16_hl = (cur_mb_x != 8'd0) && left_col_v;
		i16_tl = 8'd128;
		for (t = 0; t < 16; t = t + 1) begin
			i16_above[t] = 8'd128;
			i16_left[t] = 8'd128;
		end
		if (i16_ha) begin
			for (t = 0; t < 16; t = t + 1)
				if (({8'd0, cur_mb_x} * 16 + t) < MAX_PIC_W)
					i16_above[t] = top_row[{8'd0, cur_mb_x} * 16 + t];
		end
		if (i16_hl) begin
			for (t = 0; t < 16; t = t + 1)
				i16_left[t] = left_col[t];
		end
		if (i16_ha && i16_hl)
			i16_tl = tl_mb;
		else if (i16_ha)
			i16_tl = i16_above[0];
		else if (i16_hl)
			i16_tl = i16_left[0];
	end

	h264_intra16x16_pred u_i16 (
		.clk(clk),
		.start(i16_start),
		.mode(lat_mode[1:0]),
		.above(i16_above),
		.left(i16_left),
		.top_left(i16_tl),
		.has_above(i16_ha),
		.has_left(i16_hl),
		.unsupported(i16_unsup),
		.valid(i16_valid),
		.pred(i16_pred)
	);

	wire signed [28:0] dq_raw [0:15];
	wire signed [28:0] idct_r [0:15];
	wire [7:0]         recon_px [0:15];
	wire signed [15:0] dc_had [0:15];

	reg signed [15:0] coeff_for_iq [0:15];
	reg [4:0]         max_for_iq;
	integer ci;

	always @(*) begin
		for (ci = 0; ci < 16; ci = ci + 1)
			coeff_for_iq[ci] = lat_coeff[ci];
		max_for_iq = lat_max;
		if (lat_is_i16 && lat_is_luma && lat_idx >= 5'd1 && lat_idx <= 5'd16)
			max_for_iq = 5'd15;
	end

	h264_dequant4x4 u_dq (
		.coeff(coeff_for_iq),
		.qp(lat_qp),
		.max_coeff(max_for_iq),
		.dequant(dq_raw)
	);
	h264_idct4x4 u_idct (
		.dequant(dq_raw),
		.residual(idct_r)
	);
	h264_recon4x4 u_recon (
		.pred(i4_pred),
		.residual(idct_r),
		.recon(recon_px)
	);
	h264_i16_dc_hadamard u_had (
		.coeff(lat_coeff),
		.qp(lat_qp),
		.dc_out(dc_had)
	);

	integer yi, ui, b, y, x, addr, k;
	reg [1:0] bx, by;
	reg signed [17:0] tsum;
	reg any_nz;

	always @(posedge clk) begin
		write_req <= 1'b0;
		i16_start <= 1'b0;

		if (reset || clear) begin
			st <= ST_IDLE;
			have_mb <= 1'b0;
			cur_mb <= 16'd0;
			cur_mb_x <= 8'd0;
			cur_mb_y <= 8'd0;
			i16_dc_valid <= 1'b0;
			i16_pred_done <= 1'b0;
			pend_mb_end <= 1'b0;
			pend_mb_end_addr <= 16'd0;
			lat_is_i16 <= 1'b0;
			lat_is_luma <= 1'b1;
			lat_idx <= 5'd0;
			lat_qp <= 6'd0;
			lat_max <= 5'd16;
			lat_mode <= 4'd2;
			left_col_v <= 1'b0;
			tl_mb <= 8'd128;
			dbg_blk_applied <= 32'd0;
			dbg_mb_written <= 32'd0;
			dbg_luma_nz <= 32'd0;
			write_mb_addr <= 16'd0;
			for (yi = 0; yi < 256; yi = yi + 1) begin
				plane_y[yi] <= 8'd128;
				write_y[yi] <= 8'd128;
			end
			for (ui = 0; ui < 64; ui = ui + 1) begin
				plane_u[ui] <= 8'd128;
				plane_v[ui] <= 8'd128;
				write_u[ui] <= 8'd128;
				write_v[ui] <= 8'd128;
			end
			for (ci = 0; ci < 16; ci = ci + 1) begin
				lat_coeff[ci] <= 16'sd0;
				i16_dc[ci] <= 16'sd0;
				left_col[ci] <= 8'd128;
			end
			for (yi = 0; yi < MAX_PIC_W; yi = yi + 1)
				top_row[yi] <= 8'd128;
		end else begin
			if (res_mb_end) begin
				pend_mb_end <= 1'b1;
				pend_mb_end_addr <= res_mb_end_addr;
			end

			case (st)
			ST_IDLE: begin
				if (res_blk_valid && res_blk_ready) begin
					if (!have_mb || (res_blk_mb_addr != cur_mb)) begin
						for (yi = 0; yi < 256; yi = yi + 1)
							plane_y[yi] <= 8'd128;
						for (ui = 0; ui < 64; ui = ui + 1) begin
							plane_u[ui] <= 8'd128;
							plane_v[ui] <= 8'd128;
						end
						have_mb <= 1'b1;
						cur_mb <= res_blk_mb_addr;
						cur_mb_x <= res_blk_mb_x;
						cur_mb_y <= res_blk_mb_y;
						i16_dc_valid <= 1'b0;
						i16_pred_done <= 1'b0;
						if (res_blk_mb_x == 8'd0)
							left_col_v <= 1'b0;
						if (res_blk_mb_x != 8'd0 && res_blk_mb_y != 8'd0)
							tl_mb <= top_row[{8'd0, res_blk_mb_x} * 16 - 16'd1];
						else
							tl_mb <= 8'd128;
					end
					lat_is_i16 <= res_blk_is_i16;
					lat_is_luma <= res_blk_is_luma;
					lat_idx <= res_blk_idx;
					lat_qp <= res_blk_qp;
					lat_max <= res_blk_max_coeff;
					lat_mode <= res_blk_pred_mode;
					for (ci = 0; ci < 16; ci = ci + 1)
						lat_coeff[ci] <= res_blk_coeff[ci];

					if (res_blk_is_luma && res_blk_is_i16 && res_blk_idx == 5'd0 &&
					    !i16_pred_done) begin
						i16_start <= 1'b1;
						st <= ST_I16_PRED;
					end else
						st <= ST_SETTLE;
				end else if (pend_mb_end && !write_busy) begin
					if (have_mb && (pend_mb_end_addr == cur_mb)) begin
						for (yi = 0; yi < 16; yi = yi + 1)
							left_col[yi] <= plane_y[yi * 16 + 15];
						left_col_v <= 1'b1;
						for (yi = 0; yi < 16; yi = yi + 1) begin
							if (({8'd0, cur_mb_x} * 16 + yi) < MAX_PIC_W)
								top_row[{8'd0, cur_mb_x} * 16 + yi] <=
									plane_y[15 * 16 + yi];
						end
						write_req <= 1'b1;
						write_mb_addr <= cur_mb;
						for (yi = 0; yi < 256; yi = yi + 1)
							write_y[yi] <= plane_y[yi];
						for (ui = 0; ui < 64; ui = ui + 1) begin
							write_u[ui] <= plane_u[ui];
							write_v[ui] <= plane_v[ui];
						end
					end else begin
						write_req <= 1'b1;
						write_mb_addr <= pend_mb_end_addr;
						for (yi = 0; yi < 256; yi = yi + 1)
							write_y[yi] <= 8'd128;
						for (ui = 0; ui < 64; ui = ui + 1) begin
							write_u[ui] <= 8'd128;
							write_v[ui] <= 8'd128;
						end
					end
					dbg_mb_written <= dbg_mb_written + 32'd1;
					have_mb <= 1'b0;
					i16_dc_valid <= 1'b0;
					i16_pred_done <= 1'b0;
					pend_mb_end <= 1'b0;
				end
			end

			ST_I16_PRED: begin
				if (i16_valid) begin
					for (yi = 0; yi < 256; yi = yi + 1)
						plane_y[yi] <= i16_pred[yi];
					i16_pred_done <= 1'b1;
					st <= ST_SETTLE;
				end
			end

			ST_SETTLE: st <= ST_APPLY;

			ST_APPLY: begin
				if (lat_is_luma) begin
					if (lat_is_i16 && lat_idx == 5'd0) begin
						for (b = 0; b < 16; b = b + 1) begin
							by = b[3:2];
							bx = b[1:0];
							for (y = 0; y < 4; y = y + 1)
								for (x = 0; x < 4; x = x + 1) begin
									addr = (by * 4 + y) * 16 + (bx * 4 + x);
									tsum = $signed({10'd0, plane_y[addr]}) +
										(($signed(dc_had[b]) + 18'sd32) >>> 6);
									plane_y[addr] <= clip_u8(tsum);
								end
							i16_dc[b] <= dc_had[b];
						end
						i16_dc_valid <= 1'b1;
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
					end else if (lat_is_i16 && lat_idx >= 5'd1 && lat_idx <= 5'd16) begin
						bx = blk4_x(lat_idx[3:0] - 4'd1);
						by = blk4_y(lat_idx[3:0] - 4'd1);
						any_nz = 1'b0;
						for (k = 0; k < 16; k = k + 1)
							if (lat_coeff[k] != 16'sd0) any_nz = 1'b1;
						// Zero AC: DC already painted — skip zero-idct (+32 bias).
						if (any_nz) begin
							for (y = 0; y < 4; y = y + 1)
								for (x = 0; x < 4; x = x + 1) begin
									addr = (by * 4 + y) * 16 + (bx * 4 + x);
									plane_y[addr] <= add_res(plane_y[addr],
										idct_r[{y[1:0], x[1:0]}]);
								end
						end
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
					end else if (!lat_is_i16 && lat_idx < 5'd16) begin
						bx = blk4_x(lat_idx[3:0]);
						by = blk4_y(lat_idx[3:0]);
						any_nz = 1'b0;
						for (k = 0; k < 16; k = k + 1)
							if (lat_coeff[k] != 16'sd0) any_nz = 1'b1;
						for (y = 0; y < 4; y = y + 1)
							for (x = 0; x < 4; x = x + 1) begin
								addr = (by * 4 + y) * 16 + (bx * 4 + x);
								if (any_nz)
									plane_y[addr] <= recon_px[{y[1:0], x[1:0]}];
								else
									plane_y[addr] <= i4_pred[{y[1:0], x[1:0]}];
							end
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
					end
				end
				st <= ST_IDLE;
			end

			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
