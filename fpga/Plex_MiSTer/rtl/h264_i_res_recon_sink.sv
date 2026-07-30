// I-slice residual → Clip1(pred + residual) MB plane sink.
//
// Consumes h264_p_mb_traverse res_blk_* / res_mb_end stream.
// Phase-1 prediction: constant 128 (real I4x4/I16 modes deferred; chroma deferred
// to 128). I_16x16 DC uses h264_i16_dc_hadamard; AC uses max15 dequant + DC inject
// + idct_add. I_NxN uses full 4x4 IQ/IDCT with pred=128.
//
// On res_mb_end, write_y/u/v are stable and write_req pulses for one cycle.
// Consumer (decode_stub recon_store) must accept before the next MB end.

`default_nettype none

module h264_i_res_recon_sink (
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,             // picture start: idle planes

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
	input  wire signed [15:0] res_blk_coeff [0:15],

	input  wire        res_mb_end,
	input  wire [15:0] res_mb_end_addr,

	output reg         write_req,
	output reg  [15:0] write_mb_addr,
	output reg  [7:0]  write_y [0:255],
	output reg  [7:0]  write_u [0:63],
	output reg  [7:0]  write_v [0:63],
	input  wire        write_busy,        // store still draining prior write
	// Debug
	output reg  [31:0] dbg_blk_applied,
	output reg  [31:0] dbg_mb_written,
	output reg  [31:0] dbg_luma_nz
);
	// ── latched block command ──────────────────────────────────────────
	localparam [2:0]
		ST_IDLE  = 3'd0,
		ST_SETTLE = 3'd1,  // coeff latched → combo IQ settle
		ST_APPLY = 3'd2,
		ST_WR_WAIT = 3'd3;

	reg [2:0] st;
	reg        have_mb;
	reg [15:0] cur_mb;
	reg [7:0]  plane_y [0:255];
	reg [7:0]  plane_u [0:63];
	reg [7:0]  plane_v [0:63];

	reg        lat_is_i16;
	reg        lat_is_luma;
	reg [4:0]  lat_idx;
	reg [5:0]  lat_qp;
	reg [4:0]  lat_max;
	reg signed [15:0] lat_coeff [0:15];
	reg signed [15:0] i16_dc [0:15]; // saved after DC block
	reg        i16_dc_valid;
	reg        pend_mb_end;
	reg [15:0] pend_mb_end_addr;

	// Ready only in IDLE (one block in flight) and not waiting on store
	assign res_blk_ready = (st == ST_IDLE) && !write_busy && !pend_mb_end;

	// ── IQ / IDCT / recon combo path (pred forced 128) ─────────────────
	wire signed [28:0] dq [0:15];
	wire signed [28:0] idct_r [0:15];
	wire [7:0]         pred128 [0:15];
	wire [7:0]         recon_px [0:15];
	wire signed [15:0] dc_had [0:15];

	// For I16 AC: inject DC into dequant domain before IDCT.
	// Host sets blkq[0][0] = dc[ly][lx] after AC dequant (max15 leaves [0]=0).
	reg signed [15:0] coeff_for_iq [0:15];
	reg [4:0]         max_for_iq;
	integer ci;

	always @(*) begin
		for (ci = 0; ci < 16; ci = ci + 1)
			coeff_for_iq[ci] = lat_coeff[ci];
		max_for_iq = lat_max;
		// I16 AC: idx 1..16 → ac_i = idx-1; DC already in i16_dc
		if (lat_is_i16 && lat_is_luma && lat_idx >= 5'd1 && lat_idx <= 5'd16) begin
			max_for_iq = 5'd15;
			// AC coeffs as-is; DC injected post-dequant via separate path below
		end
	end

	genvar pi;
	generate
		for (pi = 0; pi < 16; pi = pi + 1) begin : gen_pred
			assign pred128[pi] = 8'd128;
		end
	endgenerate

	h264_dequant4x4 u_dq (
		.coeff(coeff_for_iq),
		.qp(lat_qp),
		.max_coeff(max_for_iq),
		.dequant(dq)
	);

	// blk4 coords (I_NxN / I16 AC index)
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

	// I16 path: DC painted first via hadamard; AC uses plain dequant/idct
	// residual added onto that base (no DC reinject — avoids double-count).
	h264_idct4x4 u_idct (
		.dequant(dq),
		.residual(idct_r)
	);
	h264_recon4x4 u_recon (
		.pred(pred128),
		.residual(idct_r),
		.recon(recon_px)
	);

	h264_i16_dc_hadamard u_had (
		.coeff(lat_coeff),
		.qp(lat_qp),
		.dc_out(dc_had)
	);

	function automatic [7:0] clip_u8;
		input signed [17:0] v;
		begin
			if (v < 18'sd0) clip_u8 = 8'd0;
			else if (v > 18'sd255) clip_u8 = 8'd255;
			else clip_u8 = v[7:0];
		end
	endfunction

	// idct_add onto existing plane sample (for I16 AC after DC base)
	function automatic [7:0] add_res;
		input [7:0] base;
		input signed [28:0] res;
		reg signed [17:0] s;
		begin
			s = $signed({10'd0, base}) + res[17:0];
			add_res = clip_u8(s);
		end
	endfunction

	integer yi, ui, b, y, x, addr, k, c;
	reg [1:0] bx, by;
	reg signed [17:0] t;
	reg [7:0] val;

	always @(posedge clk) begin
		write_req <= 1'b0;
		if (reset || clear) begin
			st <= ST_IDLE;
			have_mb <= 1'b0;
			cur_mb <= 16'd0;
			i16_dc_valid <= 1'b0;
			pend_mb_end <= 1'b0;
			pend_mb_end_addr <= 16'd0;
			lat_is_i16 <= 1'b0;
			lat_is_luma <= 1'b1;
			lat_idx <= 5'd0;
			lat_qp <= 6'd0;
			lat_max <= 5'd16;
			dbg_blk_applied <= 32'd0;
			dbg_mb_written <= 32'd0;
			dbg_luma_nz <= 32'd0;
			write_mb_addr <= 16'd0;
			for (yi = 0; yi < 256; yi = yi + 1)
				plane_y[yi] <= 8'd128;
			for (ui = 0; ui < 64; ui = ui + 1) begin
				plane_u[ui] <= 8'd128;
				plane_v[ui] <= 8'd128;
			end
			for (ci = 0; ci < 16; ci = ci + 1) begin
				lat_coeff[ci] <= 16'sd0;
				i16_dc[ci] <= 16'sd0;
			end
			for (yi = 0; yi < 256; yi = yi + 1)
				write_y[yi] <= 8'd128;
			for (ui = 0; ui < 64; ui = ui + 1) begin
				write_u[ui] <= 8'd128;
				write_v[ui] <= 8'd128;
			end
		end else begin
			// Sticky MB-end (pulse may arrive while APPLY in flight)
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
						i16_dc_valid <= 1'b0;
					end
					lat_is_i16 <= res_blk_is_i16;
					lat_is_luma <= res_blk_is_luma;
					lat_idx <= res_blk_idx;
					lat_qp <= res_blk_qp;
					lat_max <= res_blk_max_coeff;
					for (ci = 0; ci < 16; ci = ci + 1)
						lat_coeff[ci] <= res_blk_coeff[ci];
					st <= ST_SETTLE;
				end else if (pend_mb_end && !write_busy) begin
					write_req <= 1'b1;
					write_mb_addr <= (have_mb && (pend_mb_end_addr == cur_mb)) ?
						cur_mb : pend_mb_end_addr;
					if (have_mb && (pend_mb_end_addr == cur_mb)) begin
						for (yi = 0; yi < 256; yi = yi + 1)
							write_y[yi] <= plane_y[yi];
						for (ui = 0; ui < 64; ui = ui + 1) begin
							write_u[ui] <= plane_u[ui];
							write_v[ui] <= plane_v[ui];
						end
					end else begin
						// zero-residual / no blocks seen → mid-gray
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
					pend_mb_end <= 1'b0;
				end
			end
			ST_SETTLE: begin
				st <= ST_APPLY;
			end
			ST_APPLY: begin
				if (lat_is_luma) begin
					if (lat_is_i16 && lat_idx == 5'd0) begin
						// DC paint: Clip1(128 + ((dc+32)>>6)) per 4x4
						for (b = 0; b < 16; b = b + 1) begin
							by = b[3:2];
							bx = b[1:0];
							t = 18'sd128 + (($signed(dc_had[b]) + 18'sd32) >>> 6);
							val = clip_u8(t);
							for (y = 0; y < 4; y = y + 1)
								for (x = 0; x < 4; x = x + 1)
									plane_y[(by*4+y)*16 + (bx*4+x)] <= val;
							i16_dc[b] <= dc_had[b];
						end
						i16_dc_valid <= 1'b1;
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
					end else if (lat_is_i16 && lat_idx >= 5'd1 && lat_idx <= 5'd16) begin
						bx = blk4_x(lat_idx[3:0] - 4'd1);
						by = blk4_y(lat_idx[3:0] - 4'd1);
						for (y = 0; y < 4; y = y + 1)
							for (x = 0; x < 4; x = x + 1) begin
								addr = (by*4+y)*16 + (bx*4+x);
								plane_y[addr] <= add_res(plane_y[addr], idct_r[{y[1:0], x[1:0]}]);
							end
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
					end else if (!lat_is_i16 && lat_idx < 5'd16) begin
						bx = blk4_x(lat_idx[3:0]);
						by = blk4_y(lat_idx[3:0]);
						for (y = 0; y < 4; y = y + 1)
							for (x = 0; x < 4; x = x + 1) begin
								addr = (by*4+y)*16 + (bx*4+x);
								plane_y[addr] <= recon_px[{y[1:0], x[1:0]}];
							end
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
					end
					c = 0;
					for (k = 0; k < 256; k = k + 1)
						if (plane_y[k] != 8'd128) c = c + 1;
					// NBA plane updates not visible yet — approximate via recon
					if (c > 0)
						dbg_luma_nz <= dbg_luma_nz; // keep prior peak; updated next idle
				end
				st <= ST_IDLE;
			end
			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
