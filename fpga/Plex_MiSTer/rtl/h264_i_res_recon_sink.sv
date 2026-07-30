// I-slice residual → Clip1(pred + residual) MB plane sink.
//
// Consumes h264_p_mb_traverse res_blk_* / res_mb_end stream.
// Area/DSP (cycle-iterative): serial dequant (1 mul/16cy) + serial I16 Hadamard
// scale (1 mul/16cy). Kills parallel m15+m16 dequant farm (~52 DSP) and
// parallel hadamard muls (~32 DSP). See docs/cycle-iterative-sink-area.md.
// Target: <=4000 ALMs, <=12 DSP. Chroma product owned by sv-mvd (patch only).
//
// Neighbours: top-row linebuf (MAX_PIC_W default 1024) + left column.
// On res_mb_end, write_y/u/v are stable and write_req pulses for one cycle.

`default_nettype none

module h264_i_res_recon_sink #(
	parameter int MAX_PIC_W = 1024, // >=624 for clip2; M10K later (attr-only is trap)
	parameter bit FAULT_SERIAL_IQ_ZERO = 1'b0, // RED: serial dequant forces zeros
	parameter bit FAULT_SERIAL_I16_PRED_128 = 1'b0 // RED: I16 pred emits 128
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
	localparam [3:0]
		ST_IDLE      = 4'd0,
		ST_SETTLE    = 4'd1,  // lat_* NBA settle before serial start
		ST_I16_PRED  = 4'd2,  // serial I16 pred → plane_y (256 cy)
		ST_HAD_WAIT  = 4'd3,  // serial I16 DC hadamard
		ST_HAD_PAINT = 4'd4,  // serial DC residual paint (256 cy)
		ST_IQ_WAIT   = 4'd5,  // serial dequant
		ST_APPLY_PX  = 4'd6;  // serial pixel writeback (I4 / I16 AC)

	reg [3:0] st;
	reg [4:0] apply_px_i; // 0..15 serial recon write
	reg [8:0] paint_i;    // 0..256 serial I16 DC plane paint
	reg       apply_any_nz;
	reg [1:0] apply_bx, apply_by;
	reg       apply_is_i4;
	reg       apply_is_i16_ac;
	reg       apply_is_i16_dc;
	reg        have_mb;
	reg [15:0] cur_mb;
	reg [7:0]  cur_mb_x, cur_mb_y;
	reg [7:0]  plane_y [0:255];
	reg [7:0]  plane_u [0:63];
	reg [7:0]  plane_v [0:63];

	reg [7:0] top_row [0:MAX_PIC_W-1];
	reg [7:0] left_col [0:15];
	reg [7:0] tl_mb;
	// top_row[mb_x*16+15] is TL for the MB to the right (prev-row BR).
	// Finishing the left MB overwrites that entry with its own bottom row, so
	// snapshot it here before the top_row update (H.264 neighbour p[-1,-1]).
	reg [7:0] tl_for_right_mb;
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

	// Inverse of blk4_x/y: 4x4 block coords → residual/scan index 0..15.
	function automatic [3:0] blk4_idx;
		input [1:0] bx;
		input [1:0] by;
		begin
			case ({by, bx})
			4'b0000: blk4_idx = 4'd0;
			4'b0001: blk4_idx = 4'd1;
			4'b0100: blk4_idx = 4'd2;
			4'b0101: blk4_idx = 4'd3;
			4'b0010: blk4_idx = 4'd4;
			4'b0011: blk4_idx = 4'd5;
			4'b0110: blk4_idx = 4'd6;
			4'b0111: blk4_idx = 4'd7;
			4'b1000: blk4_idx = 4'd8;
			4'b1001: blk4_idx = 4'd9;
			4'b1100: blk4_idx = 4'd10;
			4'b1101: blk4_idx = 4'd11;
			4'b1010: blk4_idx = 4'd12;
			4'b1011: blk4_idx = 4'd13;
			4'b1110: blk4_idx = 4'd14;
			default: blk4_idx = 4'd15;
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
			// H.264 8.3.1.2: p[x,-1] x=4..7 unavailable → substitute p[3,-1].
			// Scan order leaves above-right 4x4 undecoded for some blocks (e.g.
			// scan3 needs scan4). Reading plane_y there yields the 128 init and
			// corrupts modes 3/7. Only sample plane when that 4x4 is already done.
			if (i4_bx != 2'd3 &&
			    (blk4_idx(i4_bx + 2'd1, i4_by - 2'd1) < lat_idx[3:0])) begin
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
	wire      i16_busy;
	wire      i16_done;
	wire      i16_unsup;
	wire      i16_px_valid;
	wire [7:0] i16_px_addr;
	wire [7:0] i16_px_data;

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

	h264_intra16x16_pred #(.FAULT_FORCE_128(FAULT_SERIAL_I16_PRED_128)) u_i16 (
		.clk(clk),
		.reset(reset | clear),
		.start(i16_start),
		.mode(lat_mode[1:0]),
		.above(i16_above),
		.left(i16_left),
		.top_left(i16_tl),
		.has_above(i16_ha),
		.has_left(i16_hl),
		.unsupported(i16_unsup),
		.busy(i16_busy),
		.done(i16_done),
		.px_valid(i16_px_valid),
		.px_addr(i16_px_addr),
		.px_data(i16_px_data)
	);

	wire signed [28:0] dq_raw [0:15];
	wire signed [28:0] idct_r [0:15];
	wire [7:0]         recon_px [0:15];
	wire signed [15:0] dc_had [0:15];
	wire               dq_busy, dq_done;
	wire               had_busy, had_done;
	reg                dq_start;
	reg                had_start;

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

	// I16 AC: inject Hadamard DC at dequant[0] before IDCT (host idct4x4_add).
	reg use_i16_dc_inject;
	reg signed [15:0] i16_inject_dc;
	wire signed [28:0] dq_for_idct [0:15];
	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : gen_dq_mux
			if (gi == 0)
				assign dq_for_idct[0] = use_i16_dc_inject ?
					{{13{i16_inject_dc[15]}}, i16_inject_dc} : dq_raw[0];
			else
				assign dq_for_idct[gi] = dq_raw[gi];
		end
	endgenerate

	wire [3:0] i16_ac_scan = lat_idx[3:0] - 4'd1;
	wire [3:0] i16_ac_spat = {blk4_y(i16_ac_scan), blk4_x(i16_ac_scan)};

	always @(*) begin
		use_i16_dc_inject = 1'b0;
		i16_inject_dc = 16'sd0;
		if (lat_is_i16 && lat_is_luma && lat_idx >= 5'd1 && lat_idx <= 5'd16 && i16_dc_valid) begin
			use_i16_dc_inject = 1'b1;
			i16_inject_dc = i16_dc[i16_ac_spat];
		end
	end

	h264_dequant4x4_serial #(.FAULT_FORCE_ZERO(FAULT_SERIAL_IQ_ZERO)) u_dq (
		.clk(clk), .reset(reset | clear),
		.start(dq_start),
		.coeff(coeff_for_iq),
		.qp(lat_qp),
		.max_coeff(max_for_iq),
		.busy(dq_busy), .done(dq_done),
		.dequant(dq_raw)
	);
	h264_idct4x4 u_idct (
		.dequant(dq_for_idct),
		.residual(idct_r)
	);
	h264_recon4x4 u_recon (
		.pred(i4_pred),
		.residual(idct_r),
		.recon(recon_px)
	);
	h264_i16_dc_hadamard_serial u_had (
		.clk(clk), .reset(reset | clear),
		.start(had_start),
		.coeff(lat_coeff),
		.qp(lat_qp),
		.busy(had_busy), .done(had_done),
		.dc_out(dc_had)
	);

	integer yi, ui, b, y, x, addr, k;
	wire [1:0] apx_y = apply_px_i[3:2];
	wire [1:0] apx_x = apply_px_i[1:0];
	wire [7:0] apx_addr = (apply_by * 4 + apx_y) * 16 + (apply_bx * 4 + apx_x);
	reg [1:0] bx, by;
	reg signed [17:0] tsum;
	reg any_nz;

	always @(posedge clk) begin
		write_req <= 1'b0;
		i16_start <= 1'b0;
		dq_start <= 1'b0;
		had_start <= 1'b0;

		if (reset || clear) begin
			st <= ST_IDLE;
			apply_px_i <= 5'd0;
			paint_i <= 9'd0;
			apply_any_nz <= 1'b0;
			apply_bx <= 2'd0;
			apply_by <= 2'd0;
			apply_is_i4 <= 1'b0;
			apply_is_i16_ac <= 1'b0;
			apply_is_i16_dc <= 1'b0;
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
			tl_for_right_mb <= 8'd128;
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
						// Use snapshot from left MB end — top_row[x*16-1] is already
						// the left MB bottom-right by the time this MB starts.
						if (res_blk_mb_x != 8'd0 && res_blk_mb_y != 8'd0)
							tl_mb <= tl_for_right_mb;
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

					// One settle cycle so lat_* / lat_coeff are visible to serial IQ.
					st <= ST_SETTLE;
				end else if (pend_mb_end && !write_busy) begin
					if (have_mb && (pend_mb_end_addr == cur_mb)) begin
						for (yi = 0; yi < 16; yi = yi + 1)
							left_col[yi] <= plane_y[yi * 16 + 15];
						left_col_v <= 1'b1;
						// Preserve prev-row BR before top_row overwrite; next MB TL.
						if (cur_mb_y != 8'd0 &&
						    (({8'd0, cur_mb_x} * 16 + 16'd15) < MAX_PIC_W[15:0]))
							tl_for_right_mb <=
								top_row[{8'd0, cur_mb_x} * 16 + 16'd15];
						else
							tl_for_right_mb <= 8'd128;
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

			ST_SETTLE: begin
				if (lat_is_luma && lat_is_i16 && lat_idx == 5'd0 && !i16_pred_done) begin
					i16_start <= 1'b1;
					st <= ST_I16_PRED;
				end else if (lat_is_luma && lat_is_i16 && lat_idx == 5'd0) begin
					had_start <= 1'b1;
					st <= ST_HAD_WAIT;
				end else if (lat_is_luma &&
				            ((lat_is_i16 && lat_idx >= 5'd1 && lat_idx <= 5'd16) ||
				             (!lat_is_i16 && lat_idx < 5'd16))) begin
					dq_start <= 1'b1;
					st <= ST_IQ_WAIT;
				end else
					st <= ST_IDLE; // non-luma / chroma deferred
			end

			ST_I16_PRED: begin
				// Stream 256 pred pixels into plane_y (no 256-wide parallel copy).
				if (i16_px_valid)
					plane_y[i16_px_addr] <= i16_px_data;
				if (i16_done) begin
					i16_pred_done <= 1'b1;
					had_start <= 1'b1;
					st <= ST_HAD_WAIT;
				end
			end

			ST_HAD_WAIT: begin
				if (had_done) begin
					for (b = 0; b < 16; b = b + 1)
						i16_dc[b] <= dc_had[b];
					// Serial DC paint next (was 256-wide parallel add).
					paint_i <= 9'd0;
					st <= ST_HAD_PAINT;
				end
			end

			ST_HAD_PAINT: begin
				// One plane_y pixel/cy: pred + ((dc+32)>>6). Use dc_had (stable
				// until next had_start); i16_dc NBA may still be settling cy0.
				if (paint_i < 9'd256) begin
					bx = paint_i[3:2]; // x[3:2] → 4x4 bx
					by = paint_i[7:6]; // y[3:2] → 4x4 by
					addr = paint_i[7:0];
					tsum = $signed({10'd0, plane_y[addr]}) +
						(($signed(dc_had[{by, bx}]) + 18'sd32) >>> 6);
					plane_y[addr] <= clip_u8(tsum);
					paint_i <= paint_i + 9'd1;
				end else begin
					i16_dc_valid <= 1'b1;
					dbg_blk_applied <= dbg_blk_applied + 32'd1;
					paint_i <= 9'd0;
					st <= ST_IDLE;
				end
			end

			ST_IQ_WAIT: begin
				if (dq_done) begin
					apply_is_i16_ac <= (lat_is_i16 && lat_idx >= 5'd1 && lat_idx <= 5'd16);
					apply_is_i4 <= (!lat_is_i16 && lat_idx < 5'd16);
					apply_is_i16_dc <= 1'b0;
					if (lat_is_i16 && lat_idx >= 5'd1 && lat_idx <= 5'd16) begin
						apply_bx <= blk4_x(lat_idx[3:0] - 4'd1);
						apply_by <= blk4_y(lat_idx[3:0] - 4'd1);
					end else begin
						apply_bx <= blk4_x(lat_idx[3:0]);
						apply_by <= blk4_y(lat_idx[3:0]);
					end
					any_nz = 1'b0;
					for (k = 0; k < 16; k = k + 1)
						if (lat_coeff[k] != 16'sd0) any_nz = 1'b1;
					apply_any_nz <= any_nz;
					apply_px_i <= 5'd0;
					st <= ST_APPLY_PX;
				end
			end

			ST_APPLY_PX: begin
				// One pixel per cycle into plane_y (shared path for I4 and I16 AC).
				if (apply_is_i16_ac) begin
					if (apply_any_nz) begin
						tsum = $signed({10'd0, plane_y[apx_addr]})
							- (($signed(i16_dc[{apply_by, apply_bx}]) + 18'sd32) >>> 6)
							+ idct_r[{apx_y, apx_x}];
						plane_y[apx_addr] <= clip_u8(tsum);
					end
				end else if (apply_is_i4) begin
					if (apply_any_nz)
						plane_y[apx_addr] <= recon_px[{apx_y, apx_x}];
					else
						plane_y[apx_addr] <= i4_pred[{apx_y, apx_x}];
				end
				if (apply_px_i == 5'd15) begin
					dbg_blk_applied <= dbg_blk_applied + 32'd1;
					st <= ST_IDLE;
					apply_px_i <= 5'd0;
				end else
					apply_px_i <= apply_px_i + 5'd1;
			end

			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
