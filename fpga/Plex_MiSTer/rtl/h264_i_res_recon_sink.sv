// I-slice residual → Clip1(pred + residual) MB plane sink.
// plane_y + top_row via h264_byte_ram_sp (registered read: issue→wait→capture).
// Serial neighbour fetch; serial IQ; serial I16 pred. NO new DSP.
// RMW diet: no HAD_PAINT; MB_DUMP + I16 APPLY plane RMW pipelined 1/cy after fill.
// FAULT_SERIAL_IQ_ZERO / FAULT_SERIAL_I16_PRED_128 / FAULT_SKIP_PLANE_NB.

`default_nettype none

module h264_i_res_recon_sink #(
	parameter int MAX_PIC_W = 1024,
	parameter bit FAULT_SERIAL_IQ_ZERO = 1'b0,
	parameter bit FAULT_SERIAL_I16_PRED_128 = 1'b0,
	parameter bit FAULT_SKIP_PLANE_NB = 1'b0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,

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
	input  wire [3:0]  res_blk_pred_mode,
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
	localparam int TOP_AW = (MAX_PIC_W <= 1) ? 1 : $clog2(MAX_PIC_W);

	// FSM
	localparam [3:0]
		ST_IDLE       = 4'd0,
		ST_MB_INIT    = 4'd1,
		ST_SETTLE     = 4'd2,
		ST_I16_NB     = 4'd3,
		ST_I16_START  = 4'd4, // 1-cy gap so above/left NBA settles before start
		ST_I16_PRED   = 4'd5,
		ST_HAD_WAIT   = 4'd6,
		ST_HAD_PAINT  = 4'd7,
		ST_I4_NB      = 4'd8,
		ST_IQ_WAIT    = 4'd9,
		ST_APPLY_PX   = 4'd10,
		ST_MB_DUMP    = 4'd11;

	// I4_NB subphases
	localparam [2:0]
		NB_A0   = 3'd0,
		NB_A1   = 3'd1,
		NB_LEFT = 3'd2,
		NB_TL   = 3'd3,
		NB_DONE = 3'd4;

	// Read latency sub-phase for registered RAM: 0=issue raddr, 1=wait, 2=use q
	localparam [1:0] RD_ISSUE = 2'd0, RD_WAIT = 2'd1, RD_CAPT = 2'd2;

	reg [3:0] st;
	reg [8:0] cnt;
	reg [1:0] rd_ph;
	reg       after_init_settle;

	reg        have_mb;
	reg [15:0] cur_mb;
	reg [7:0]  cur_mb_x, cur_mb_y;
	reg [7:0]  plane_u [0:63];
	reg [7:0]  plane_v [0:63];
	reg [7:0]  left_col [0:15];
	reg [7:0]  tl_mb, tl_for_right_mb;
	reg        left_col_v;

	reg        lat_is_i16, lat_is_luma;
	reg [4:0]  lat_idx, lat_max;
	reg [5:0]  lat_qp;
	reg [3:0]  lat_mode;
	reg signed [15:0] lat_coeff [0:15];
	reg signed [15:0] i16_dc [0:15];
	reg        i16_dc_valid, i16_pred_done;
	// 1 = at least one I16 AC APPLY wrote pred+idct (cbp_l=15 path).
	// 0 + i16_dc_valid = cbp_l=0: dump must add ((dc+32)>>6) per 4x4.
	reg        i16_ac_recon;
	reg        pend_mb_end;
	reg [15:0] pend_mb_end_addr;

	reg        py_we;
	reg [7:0]  py_waddr, py_wdata, py_raddr;
	wire [7:0] py_q;
	h264_byte_ram_sp #(.DEPTH(256)) u_plane_y (
		.clk(clk), .we(py_we), .waddr(py_waddr), .wdata(py_wdata),
		.raddr(py_raddr), .q(py_q)
	);

	reg              tr_we;
	reg [TOP_AW-1:0] tr_waddr, tr_raddr;
	reg [7:0]        tr_wdata;
	wire [7:0]       tr_q;
	h264_byte_ram_sp #(.DEPTH(MAX_PIC_W), .AW(TOP_AW)) u_top_row (
		.clk(clk), .we(tr_we), .waddr(tr_waddr), .wdata(tr_wdata),
		.raddr(tr_raddr), .q(tr_q)
	);

	assign res_blk_ready = (st == ST_IDLE) && !write_busy && !pend_mb_end;

	function automatic [1:0] blk4_x;
		input [3:0] i;
		case (i)
		4'd0,4'd2,4'd8,4'd10: blk4_x = 2'd0;
		4'd1,4'd3,4'd9,4'd11: blk4_x = 2'd1;
		4'd4,4'd6,4'd12,4'd14: blk4_x = 2'd2;
		default: blk4_x = 2'd3;
		endcase
	endfunction
	function automatic [1:0] blk4_y;
		input [3:0] i;
		case (i)
		4'd0,4'd1,4'd4,4'd5: blk4_y = 2'd0;
		4'd2,4'd3,4'd6,4'd7: blk4_y = 2'd1;
		4'd8,4'd9,4'd12,4'd13: blk4_y = 2'd2;
		default: blk4_y = 2'd3;
		endcase
	endfunction
	function automatic [3:0] blk4_idx;
		input [1:0] bx;
		input [1:0] by;
		case ({by, bx})
		4'b0000: blk4_idx = 4'd0;  4'b0001: blk4_idx = 4'd1;
		4'b0100: blk4_idx = 4'd2;  4'b0101: blk4_idx = 4'd3;
		4'b0010: blk4_idx = 4'd4;  4'b0011: blk4_idx = 4'd5;
		4'b0110: blk4_idx = 4'd6;  4'b0111: blk4_idx = 4'd7;
		4'b1000: blk4_idx = 4'd8;  4'b1001: blk4_idx = 4'd9;
		4'b1100: blk4_idx = 4'd10; 4'b1101: blk4_idx = 4'd11;
		4'b1010: blk4_idx = 4'd12; 4'b1011: blk4_idx = 4'd13;
		4'b1110: blk4_idx = 4'd14; default: blk4_idx = 4'd15;
		endcase
	endfunction
	function automatic [7:0] clip_u8;
		input signed [17:0] v;
		if (v < 18'sd0) clip_u8 = 8'd0;
		else if (v > 18'sd255) clip_u8 = 8'd255;
		else clip_u8 = v[7:0];
	endfunction
	// y,x in 0..15 → y*16+x
	function automatic [7:0] plane_addr;
		input [4:0] y;
		input [4:0] x;
		plane_addr = {y[3:0], x[3:0]};
	endfunction

	wire [1:0] i4_bx = blk4_x(lat_idx[3:0]);
	wire [1:0] i4_by = blk4_y(lat_idx[3:0]);
	wire [4:0] i4_x0 = {1'b0, i4_bx, 2'b00};
	wire [4:0] i4_y0 = {1'b0, i4_by, 2'b00};
	wire [15:0] abs_x0 = {8'd0, cur_mb_x} * 16'd16 + {11'd0, i4_x0};
	wire i4_ar_ok = (i4_bx != 2'd3) &&
		(blk4_idx(i4_bx + 2'd1, i4_by - 2'd1) < lat_idx[3:0]);

	reg [7:0] i4_above [0:7];
	reg [7:0] i4_left  [0:3];
	reg [7:0] i4_tl;
	reg       i4_ha, i4_hl;
	reg [7:0] i16_above [0:15];
	reg [7:0] i16_left  [0:15];
	reg [7:0] i16_tl;
	reg       i16_ha, i16_hl;
	reg [7:0] i16_above0_cap;

	reg [2:0] nb_ph;
	reg       i4_ar_live_r;

	wire [7:0] i4_pred [0:15];
	wire [3:0] i4_used_mode;
	h264_intra4x4_pred u_i4 (
		.mode(lat_mode), .above(i4_above), .left(i4_left), .top_left(i4_tl),
		.has_above(i4_ha), .has_left(i4_hl), .used_mode(i4_used_mode), .pred(i4_pred)
	);

	reg i16_start;
	wire i16_busy, i16_done, i16_unsup, i16_px_valid;
	wire [7:0] i16_px_addr, i16_px_data;
	h264_intra16x16_pred #(.FAULT_FORCE_128(FAULT_SERIAL_I16_PRED_128)) u_i16 (
		.clk(clk), .reset(reset | clear), .start(i16_start),
		.mode(lat_mode[1:0]), .above(i16_above), .left(i16_left), .top_left(i16_tl),
		.has_above(i16_ha), .has_left(i16_hl),
		.unsupported(i16_unsup), .busy(i16_busy), .done(i16_done),
		.px_valid(i16_px_valid), .px_addr(i16_px_addr), .px_data(i16_px_data)
	);

	wire signed [28:0] dq_raw [0:15];
	wire signed [28:0] idct_r [0:15];
	wire [7:0] recon_px [0:15];
	wire signed [15:0] dc_had [0:15];
	wire dq_busy, dq_done, had_busy, had_done;
	reg dq_start, had_start;
	reg signed [15:0] coeff_for_iq [0:15];
	reg [4:0] max_for_iq;
	integer ci;

	always @(*) begin
		for (ci = 0; ci < 16; ci = ci + 1)
			coeff_for_iq[ci] = lat_coeff[ci];
		max_for_iq = lat_max;
		if (lat_is_i16 && lat_is_luma && lat_idx >= 5'd1 && lat_idx <= 5'd16)
			max_for_iq = 5'd15;
	end

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
		.clk(clk), .reset(reset | clear), .start(dq_start),
		.coeff(coeff_for_iq), .qp(lat_qp), .max_coeff(max_for_iq),
		.busy(dq_busy), .done(dq_done), .dequant(dq_raw)
	);
	h264_idct4x4 u_idct (.dequant(dq_for_idct), .residual(idct_r));
	h264_recon4x4 u_recon (.pred(i4_pred), .residual(idct_r), .recon(recon_px));
	h264_i16_dc_hadamard_serial u_had (
		.clk(clk), .reset(reset | clear), .start(had_start),
		.coeff(lat_coeff), .qp(lat_qp),
		.busy(had_busy), .done(had_done), .dc_out(dc_had)
	);

	reg [4:0] apply_i;
	reg apply_any_nz, apply_is_i4;
	// Combo from lat_* (stable in APPLY) — avoid NBA hazard on dq_done→APPLY.
	wire [1:0] apply_bx = lat_is_i16 ? blk4_x(lat_idx[3:0] - 4'd1) : blk4_x(lat_idx[3:0]);
	wire [1:0] apply_by = lat_is_i16 ? blk4_y(lat_idx[3:0] - 4'd1) : blk4_y(lat_idx[3:0]);
	// Pixel p (0..15) address inside current 4x4 (bx,by).
	function automatic [7:0] blk_px_addr;
		input [1:0] bx;
		input [1:0] by;
		input [3:0] p;
		blk_px_addr = (({6'd0, by} * 8'd4 + {6'd0, p[3:2]}) << 4) +
		              ({6'd0, bx} * 8'd4 + {6'd0, p[1:0]});
	endfunction
	wire [7:0] apply_addr = blk_px_addr(apply_bx, apply_by, apply_i[3:0]);
	// I16 APPLY pipe: capt index = apply_i-2 while apply_i in 2..17
	wire [3:0] apply_capt_i = 4'(apply_i - 5'd2);
	wire [7:0] apply_capt_addr = blk_px_addr(apply_bx, apply_by, apply_capt_i);

	reg [7:0] bot_row [0:15];
	integer ui, yi;
	reg signed [17:0] tsum;
	reg any_nz;
	wire any_nz_c = (lat_coeff[0]!=0)||(lat_coeff[1]!=0)||(lat_coeff[2]!=0)||(lat_coeff[3]!=0)
		||(lat_coeff[4]!=0)||(lat_coeff[5]!=0)||(lat_coeff[6]!=0)||(lat_coeff[7]!=0)
		||(lat_coeff[8]!=0)||(lat_coeff[9]!=0)||(lat_coeff[10]!=0)||(lat_coeff[11]!=0)
		||(lat_coeff[12]!=0)||(lat_coeff[13]!=0)||(lat_coeff[14]!=0)||(lat_coeff[15]!=0);
	// MB_DUMP pipeline capture address (= cnt-2 while cnt>=2)
	wire [7:0] dump_cap_a = 8'(cnt - 9'd2);
	wire [3:0] dump_dc_i  = {dump_cap_a[7:6], dump_cap_a[3:2]};

	always @(posedge clk) begin
		write_req <= 1'b0;
		i16_start <= 1'b0;
		dq_start <= 1'b0;
		had_start <= 1'b0;
		py_we <= 1'b0;
		tr_we <= 1'b0;

		if (reset || clear) begin
			st <= ST_IDLE;
			cnt <= 9'd0;
			rd_ph <= RD_ISSUE;
			after_init_settle <= 1'b0;
			have_mb <= 1'b0;
			cur_mb <= 16'd0;
			cur_mb_x <= 8'd0;
			cur_mb_y <= 8'd0;
			i16_dc_valid <= 1'b0;
			i16_pred_done <= 1'b0;
			i16_ac_recon <= 1'b0;
			pend_mb_end <= 1'b0;
			left_col_v <= 1'b0;
			tl_mb <= 8'd128;
			tl_for_right_mb <= 8'd128;
			dbg_blk_applied <= 32'd0;
			dbg_mb_written <= 32'd0;
			dbg_luma_nz <= 32'd0;
			write_mb_addr <= 16'd0;
			py_raddr <= 8'd0;
			tr_raddr <= {TOP_AW{1'b0}};
			apply_i <= 5'd0;
			nb_ph <= NB_A0;
			i4_ha <= 1'b0;
			i4_hl <= 1'b0;
			i16_ha <= 1'b0;
			i16_hl <= 1'b0;
			i4_ar_live_r <= 1'b0;
			i16_above0_cap <= 8'd128;
			for (yi = 0; yi < 256; yi = yi + 1)
				write_y[yi] <= 8'd128;
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
				i16_above[ci] <= 8'd128;
				i16_left[ci] <= 8'd128;
				bot_row[ci] <= 8'd128;
			end
			for (ci = 0; ci < 8; ci = ci + 1)
				i4_above[ci] <= 8'd128;
			for (ci = 0; ci < 4; ci = ci + 1)
				i4_left[ci] <= 8'd128;
			i4_tl <= 8'd128;
			i16_tl <= 8'd128;
		end else begin
			if (res_mb_end) begin
				pend_mb_end <= 1'b1;
				pend_mb_end_addr <= res_mb_end_addr;
			end

			case (st)
			//============================================================
			ST_IDLE: begin
				if (res_blk_valid && res_blk_ready) begin
					if (!have_mb || (res_blk_mb_addr != cur_mb)) begin
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
						i16_ac_recon <= 1'b0;
						if (res_blk_mb_x == 8'd0)
							left_col_v <= 1'b0;
						if (res_blk_mb_x != 8'd0 && res_blk_mb_y != 8'd0)
							tl_mb <= tl_for_right_mb;
						else
							tl_mb <= 8'd128;
						cnt <= 9'd0;
						after_init_settle <= 1'b1;
						lat_is_i16 <= res_blk_is_i16;
						lat_is_luma <= res_blk_is_luma;
						lat_idx <= res_blk_idx;
						lat_qp <= res_blk_qp;
						lat_max <= res_blk_max_coeff;
						lat_mode <= res_blk_pred_mode;
						for (ci = 0; ci < 16; ci = ci + 1)
							lat_coeff[ci] <= res_blk_coeff[ci];
						st <= ST_MB_INIT;
					end else begin
						lat_is_i16 <= res_blk_is_i16;
						lat_is_luma <= res_blk_is_luma;
						lat_idx <= res_blk_idx;
						lat_qp <= res_blk_qp;
						lat_max <= res_blk_max_coeff;
						lat_mode <= res_blk_pred_mode;
						for (ci = 0; ci < 16; ci = ci + 1)
							lat_coeff[ci] <= res_blk_coeff[ci];
						st <= ST_SETTLE;
					end
				end else if (pend_mb_end && !write_busy && have_mb &&
				             (pend_mb_end_addr == cur_mb)) begin
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_MB_DUMP;
				end else if (pend_mb_end && !write_busy &&
				             !(have_mb && pend_mb_end_addr == cur_mb)) begin
					write_req <= 1'b1;
					write_mb_addr <= pend_mb_end_addr;
					for (yi = 0; yi < 256; yi = yi + 1)
						write_y[yi] <= 8'd128;
					for (ui = 0; ui < 64; ui = ui + 1) begin
						write_u[ui] <= 8'd128;
						write_v[ui] <= 8'd128;
					end
					dbg_mb_written <= dbg_mb_written + 32'd1;
					pend_mb_end <= 1'b0;
				end
			end

			//============================================================
			ST_MB_INIT: begin
				if (cnt < 9'd256) begin
					py_we <= 1'b1;
					py_waddr <= cnt[7:0];
					py_wdata <= 8'd128;
					cnt <= cnt + 9'd1;
				end else begin
					cnt <= 9'd0;
					if (after_init_settle) begin
						after_init_settle <= 1'b0;
						st <= ST_SETTLE;
					end else
						st <= ST_IDLE;
				end
			end

			//============================================================
			ST_SETTLE: begin
				if (lat_is_luma && lat_is_i16 && lat_idx == 5'd0 && !i16_pred_done) begin
					i16_ha <= (cur_mb_y != 8'd0);
					i16_hl <= (cur_mb_x != 8'd0) && left_col_v;
					for (ci = 0; ci < 16; ci = ci + 1) begin
						i16_above[ci] <= 8'd128;
						i16_left[ci] <= ((cur_mb_x != 8'd0) && left_col_v) ?
							left_col[ci] : 8'd128;
					end
					i16_tl <= 8'd128;
					i16_above0_cap <= 8'd128;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					if (FAULT_SKIP_PLANE_NB || (cur_mb_y == 8'd0)) begin
						if ((cur_mb_x != 8'd0) && left_col_v)
							i16_tl <= left_col[0];
						// left NBA settles next cy
						st <= ST_I16_START;
					end else
						st <= ST_I16_NB;
				end else if (lat_is_luma && lat_is_i16 && lat_idx == 5'd0) begin
					had_start <= 1'b1;
					st <= ST_HAD_WAIT;
				end else if (lat_is_luma && lat_is_i16 &&
				             lat_idx >= 5'd1 && lat_idx <= 5'd16) begin
					dq_start <= 1'b1;
					st <= ST_IQ_WAIT;
				end else if (lat_is_luma && !lat_is_i16 && lat_idx < 5'd16) begin
					i4_ha <= 1'b0;
					i4_hl <= 1'b0;
					i4_tl <= 8'd128;
					for (ci = 0; ci < 8; ci = ci + 1) i4_above[ci] <= 8'd128;
					for (ci = 0; ci < 4; ci = ci + 1) i4_left[ci] <= 8'd128;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					nb_ph <= NB_A0;
					i4_ar_live_r <= i4_ar_ok;
					if (FAULT_SKIP_PLANE_NB) begin
						dq_start <= 1'b1;
						st <= ST_IQ_WAIT;
					end else
						st <= ST_I4_NB;
				end else
					st <= ST_IDLE;
			end

			//============================================================
			// top_row → i16_above: 3 cy/sample (issue/wait/capt)
			ST_I16_NB: begin
				if (rd_ph == RD_ISSUE) begin
					if (({8'd0, cur_mb_x} * 16 + {8'd0, cnt[7:0]}) < 32'(MAX_PIC_W))
						tr_raddr <= TOP_AW'(({8'd0, cur_mb_x} * 16 + {8'd0, cnt[7:0]}));
					rd_ph <= RD_WAIT;
				end else if (rd_ph == RD_WAIT) begin
					rd_ph <= RD_CAPT;
				end else begin
					i16_above[cnt[3:0]] <= tr_q;
					if (cnt == 9'd0)
						i16_above0_cap <= tr_q;
					rd_ph <= RD_ISSUE;
					if (cnt == 9'd15) begin
						if (i16_ha && i16_hl)
							i16_tl <= tl_mb;
						else if (i16_ha)
							i16_tl <= (cnt == 9'd0) ? tr_q : i16_above0_cap;
						else if (i16_hl)
							i16_tl <= i16_left[0];
						cnt <= 9'd0;
						st <= ST_I16_START;
					end else
						cnt <= cnt + 9'd1;
				end
			end

			//============================================================
			ST_I16_START: begin
				// above/left/tl registers stable
				i16_start <= 1'b1;
				st <= ST_I16_PRED;
			end

			//============================================================
			ST_I16_PRED: begin
				if (i16_px_valid) begin
					py_we <= 1'b1;
					py_waddr <= i16_px_addr;
					py_wdata <= i16_px_data;
				end
				if (i16_done) begin
					i16_pred_done <= 1'b1;
					had_start <= 1'b1;
					st <= ST_HAD_WAIT;
				end
			end

			//============================================================
			// B: no HAD_PAINT RMW. Keep scaled DC in i16_dc[]; plane_y stays pure
			// pred until AC APPLY (pred+idct) or MB_DUMP adds ((dc+32)>>6) if cbp_l=0.
			ST_HAD_WAIT: begin
				if (had_done) begin
					for (ci = 0; ci < 16; ci = ci + 1)
						i16_dc[ci] <= dc_had[ci];
					i16_dc_valid <= 1'b1;
					i16_ac_recon <= 1'b0;
					dbg_blk_applied <= dbg_blk_applied + 32'd1;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_IDLE;
				end
			end

			// Retired encoding (B removed body). Keep label so state nums stable.
			ST_HAD_PAINT: begin
				st <= ST_IDLE;
			end

			//============================================================
			ST_I4_NB: begin
				case (nb_ph)
				NB_A0: begin
					if (i4_by != 2'd0) begin
						i4_ha <= 1'b1;
						if (rd_ph == RD_ISSUE) begin
							py_raddr <= plane_addr(i4_y0 - 5'd1, i4_x0 + {3'b0, cnt[1:0]});
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							i4_above[cnt[1:0]] <= py_q;
							rd_ph <= RD_ISSUE;
							if (cnt == 9'd3) begin
								cnt <= 9'd0;
								nb_ph <= NB_A1;
							end else
								cnt <= cnt + 9'd1;
						end
					end else if (cur_mb_y != 8'd0) begin
						i4_ha <= 1'b1;
						if (rd_ph == RD_ISSUE) begin
							if ((abs_x0 + {14'd0, cnt[1:0]}) < MAX_PIC_W[15:0])
								tr_raddr <= TOP_AW'(abs_x0 + {14'd0, cnt[1:0]});
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							i4_above[cnt[1:0]] <= tr_q;
							rd_ph <= RD_ISSUE;
							if (cnt == 9'd3) begin
								cnt <= 9'd0;
								nb_ph <= NB_A1;
							end else
								cnt <= cnt + 9'd1;
						end
					end else begin
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						nb_ph <= NB_LEFT;
					end
				end
				NB_A1: begin
					if (i4_by != 2'd0) begin
						if (i4_ar_live_r) begin
							if (rd_ph == RD_ISSUE) begin
								py_raddr <= plane_addr(i4_y0 - 5'd1,
									i4_x0 + 5'd4 + {3'b0, cnt[1:0]});
								rd_ph <= RD_WAIT;
							end else if (rd_ph == RD_WAIT) begin
								rd_ph <= RD_CAPT;
							end else begin
								i4_above[{1'b1, cnt[1:0]}] <= py_q;
								rd_ph <= RD_ISSUE;
								if (cnt == 9'd3) begin
									cnt <= 9'd0;
									nb_ph <= NB_LEFT;
								end else
									cnt <= cnt + 9'd1;
							end
						end else begin
							i4_above[4] <= i4_above[3];
							i4_above[5] <= i4_above[3];
							i4_above[6] <= i4_above[3];
							i4_above[7] <= i4_above[3];
							cnt <= 9'd0;
							rd_ph <= RD_ISSUE;
							nb_ph <= NB_LEFT;
						end
					end else if (cur_mb_y != 8'd0) begin
						if (rd_ph == RD_ISSUE) begin
							if ((abs_x0 + 16'd4 + {14'd0, cnt[1:0]}) < MAX_PIC_W[15:0])
								tr_raddr <= TOP_AW'(abs_x0 + 16'd4 + {14'd0, cnt[1:0]});
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							if ((abs_x0 + 16'd4 + {14'd0, cnt[1:0]}) < MAX_PIC_W[15:0])
								i4_above[{1'b1, cnt[1:0]}] <= tr_q;
							else
								i4_above[{1'b1, cnt[1:0]}] <= i4_above[3];
							rd_ph <= RD_ISSUE;
							if (cnt == 9'd3) begin
								cnt <= 9'd0;
								nb_ph <= NB_LEFT;
							end else
								cnt <= cnt + 9'd1;
						end
					end else begin
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						nb_ph <= NB_LEFT;
					end
				end
				NB_LEFT: begin
					if (i4_bx != 2'd0) begin
						i4_hl <= 1'b1;
						if (rd_ph == RD_ISSUE) begin
							py_raddr <= plane_addr(i4_y0 + {3'b0, cnt[1:0]},
								i4_x0 - 5'd1);
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							i4_left[cnt[1:0]] <= py_q;
							rd_ph <= RD_ISSUE;
							if (cnt == 9'd3) begin
								cnt <= 9'd0;
								nb_ph <= NB_TL;
							end else
								cnt <= cnt + 9'd1;
						end
					end else if ((cur_mb_x != 8'd0) && left_col_v) begin
						i4_hl <= 1'b1;
						i4_left[0] <= left_col[i4_y0[3:0] + 4'd0];
						i4_left[1] <= left_col[i4_y0[3:0] + 4'd1];
						i4_left[2] <= left_col[i4_y0[3:0] + 4'd2];
						i4_left[3] <= left_col[i4_y0[3:0] + 4'd3];
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						nb_ph <= NB_TL;
					end else begin
						cnt <= 9'd0;
						rd_ph <= RD_ISSUE;
						nb_ph <= NB_TL;
					end
				end
				NB_TL: begin
					if (i4_ha && i4_hl) begin
						if (i4_bx != 2'd0 && i4_by != 2'd0) begin
							if (rd_ph == RD_ISSUE) begin
								py_raddr <= plane_addr(i4_y0 - 5'd1, i4_x0 - 5'd1);
								rd_ph <= RD_WAIT;
							end else if (rd_ph == RD_WAIT) begin
								rd_ph <= RD_CAPT;
							end else begin
								i4_tl <= py_q;
								rd_ph <= RD_ISSUE;
								nb_ph <= NB_DONE;
							end
						end else if (i4_bx != 2'd0 && i4_by == 2'd0) begin
							if (abs_x0 > 0) begin
								if (rd_ph == RD_ISSUE) begin
									tr_raddr <= TOP_AW'(abs_x0 - 16'd1);
									rd_ph <= RD_WAIT;
								end else if (rd_ph == RD_WAIT) begin
									rd_ph <= RD_CAPT;
								end else begin
									i4_tl <= tr_q;
									rd_ph <= RD_ISSUE;
									nb_ph <= NB_DONE;
								end
							end else begin
								i4_tl <= 8'd128;
								nb_ph <= NB_DONE;
							end
						end else if (i4_bx == 2'd0 && i4_by != 2'd0) begin
							i4_tl <= left_col[i4_y0[3:0] - 4'd1];
							nb_ph <= NB_DONE;
						end else begin
							i4_tl <= tl_mb;
							nb_ph <= NB_DONE;
						end
					end else if (i4_ha) begin
						i4_tl <= i4_above[0];
						nb_ph <= NB_DONE;
					end else if (i4_hl) begin
						i4_tl <= i4_left[0];
						nb_ph <= NB_DONE;
					end else
						nb_ph <= NB_DONE;
				end
				default: begin // NB_DONE
					dq_start <= 1'b1;
					st <= ST_IQ_WAIT;
					nb_ph <= NB_A0;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
				end
				endcase
			end

			//============================================================
			ST_IQ_WAIT: begin
				if (dq_done) begin
					any_nz = 1'b0;
					for (ci = 0; ci < 16; ci = ci + 1)
						if (lat_coeff[ci] != 0) any_nz = 1'b1;
					apply_any_nz <= any_nz;
					apply_is_i4 <= !lat_is_i16;
					apply_i <= 5'd0;
					rd_ph <= RD_ISSUE;
					// Always APPLY (matches prior sink); any_nz_c gates writes.
					st <= ST_APPLY_PX;
				end
			end

			//============================================================
			ST_APPLY_PX: begin
				if (!lat_is_i16) begin
					// I4: pred+idct already in regs → 1 write/cy (no plane RMW).
					py_we <= 1'b1;
					py_waddr <= apply_addr;
					py_wdata <= any_nz_c ? recon_px[apply_i[3:0]]
					           : i4_pred[apply_i[3:0]];
					if (apply_i == 5'd15) begin
						if (apply_any_nz)
							dbg_luma_nz <= dbg_luma_nz + 32'd1;
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
						st <= ST_IDLE;
					end else
						apply_i <= apply_i + 5'd1;
				end else begin
					// C: I16 AC RMW pipelined on u_plane_y (same 2-cy fill as dump).
					// apply_i 0..17: issue while <16; capt/write at i-2 for i=2..17.
					// idct has DC inject → write clip(pred + idct). No new memory.
					if (apply_i < 5'd16)
						py_raddr <= apply_addr; // issue idx = apply_i
					if (apply_i >= 5'd2) begin
						tsum = 18'($signed({10'd0, py_q}) + idct_r[apply_capt_i]);
						py_we <= 1'b1;
						py_waddr <= apply_capt_addr;
						py_wdata <= clip_u8(tsum);
					end
					if (apply_i == 5'd17) begin
						i16_ac_recon <= 1'b1;
						if (apply_any_nz)
							dbg_luma_nz <= dbg_luma_nz + 32'd1;
						dbg_blk_applied <= dbg_blk_applied + 32'd1;
						st <= ST_IDLE;
					end else
						apply_i <= apply_i + 5'd1;
				end
			end

			//============================================================
			// A: dump plane pipelined 1 result/cy after 2-cy read fill (258 cy),
			// B: if I16 DC-only (no AC APPLY) fold ((dc+32)>>6) here.
			// then TL save from top_row[mbx*16+15]; then bot→top_row we ×16.
			// cnt: 0..257 pipe dump, 258 hold, 259 TL, 260..275 top we, 276 commit.
			ST_MB_DUMP: begin
				if (cnt <= 9'd257) begin
					if (cnt < 9'd256)
						py_raddr <= cnt[7:0];
					if (cnt >= 9'd2) begin
						// dump_cap_a = address issued two cycles earlier
						if (i16_dc_valid && !i16_ac_recon) begin
							tsum = $signed({10'd0, py_q}) +
							       18'(($signed(i16_dc[dump_dc_i]) + 18'sd32) >>> 6);
							write_y[dump_cap_a] <= clip_u8(tsum);
							if (dump_cap_a[3:0] == 4'd15)
								left_col[dump_cap_a[7:4]] <= clip_u8(tsum);
							if (dump_cap_a[7:4] == 4'd15)
								bot_row[dump_cap_a[3:0]] <= clip_u8(tsum);
						end else begin
							write_y[dump_cap_a] <= py_q;
							if (dump_cap_a[3:0] == 4'd15)
								left_col[dump_cap_a[7:4]] <= py_q;
							if (dump_cap_a[7:4] == 4'd15)
								bot_row[dump_cap_a[3:0]] <= py_q;
						end
					end
					if (cnt == 9'd257) begin
						rd_ph <= RD_ISSUE;
						cnt <= 9'd258;
					end else
						cnt <= cnt + 9'd1;
				end else if (cnt == 9'd258) begin
					// one-cycle align before TL (rd_ph already ISSUE)
					cnt <= 9'd259;
				end else if (cnt == 9'd259) begin
					if (cur_mb_y != 8'd0 &&
					    (({8'd0, cur_mb_x} * 16 + 16'd15) < MAX_PIC_W[15:0])) begin
						if (rd_ph == RD_ISSUE) begin
							tr_raddr <= TOP_AW'(({8'd0, cur_mb_x} * 16 + 16'd15));
							rd_ph <= RD_WAIT;
						end else if (rd_ph == RD_WAIT) begin
							rd_ph <= RD_CAPT;
						end else begin
							tl_for_right_mb <= tr_q;
							rd_ph <= RD_ISSUE;
							cnt <= 9'd260;
						end
					end else begin
						tl_for_right_mb <= 8'd128;
						rd_ph <= RD_ISSUE;
						cnt <= 9'd260;
					end
				end else if (cnt < 9'd276) begin
					tr_we <= 1'b1;
					tr_waddr <= TOP_AW'(({8'd0, cur_mb_x} * 16 + 16'(cnt - 9'd260)));
					tr_wdata <= bot_row[4'(cnt - 9'd260)];
					cnt <= cnt + 9'd1;
				end else begin
					left_col_v <= 1'b1;
					for (ui = 0; ui < 64; ui = ui + 1) begin
						write_u[ui] <= plane_u[ui];
						write_v[ui] <= plane_v[ui];
					end
					write_req <= 1'b1;
					write_mb_addr <= cur_mb;
					dbg_mb_written <= dbg_mb_written + 32'd1;
					have_mb <= 1'b0;
					pend_mb_end <= 1'b0;
					cnt <= 9'd0;
					rd_ph <= RD_ISSUE;
					st <= ST_IDLE;
				end
			end

			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
