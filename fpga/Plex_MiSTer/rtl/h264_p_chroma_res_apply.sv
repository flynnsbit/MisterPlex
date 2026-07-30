// h264_p_chroma_res_apply.sv — cycle-iterative P-slice chroma residual (8.5.5)
// Consumes traverse residual export for chroma slots only; writes signed
// residual planes for Clip1(pred_mc + res). One 4×4 (or 2×2 DC) per accept.
// Area: serial dequant (h264_dequant4x4_serial) + IDCT + 2×2 DC Hadamard.
// NEVER instantiate parallel h264_dequant4x4 here.
`default_nettype none

module h264_p_chroma_res_apply #(
	parameter bit FAULT_SKIP = 1'b0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        clear_mb,           // pulse: zero residual planes (new P MB)
	input  wire        enable,             // 1 while P path owns residual bus

	input  wire        res_blk_valid,
	output wire        res_blk_ready,
	input  wire [15:0] res_blk_mb_addr,
	input  wire [4:0]  res_blk_idx,
	input  wire        res_blk_is_i16,
	input  wire        res_blk_is_luma,
	input  wire [5:0]  res_blk_qp,         // wrapped QP_Y
	input  wire [4:0]  res_blk_max_coeff,
	input  wire signed [15:0] res_blk_coeff [0:15],
	input  wire signed [4:0] chroma_qp_index_offset,

	input  wire        res_mb_end,
	input  wire [15:0] res_mb_end_addr,
	output reg         mb_res_done,        // pulse: chroma residual complete for MB
	output reg  [15:0] mb_res_done_addr,
	output wire        busy,               // apply in-flight; do not accept next MB

	output reg signed [15:0] res_u [0:63],
	output reg signed [15:0] res_v [0:63]
);
	localparam [2:0]
		ST_IDLE    = 3'd0,
		ST_SETTLE  = 3'd1,
		ST_IQ_WAIT = 3'd2,
		ST_APPLY_PX= 3'd3,
		ST_DC_SET  = 3'd4,
		ST_DC_KICK = 3'd5;

	reg [2:0] st;
	reg        have_mb;
	reg [15:0] cur_mb;
	reg        lat_i16;
	reg [4:0]  lat_idx;
	reg [5:0]  lat_qp;
	reg [4:0]  lat_max;
	reg signed [15:0] lat_coeff [0:15];
	reg        chr_dc_u_v, chr_dc_v_v;
	reg signed [15:0] chr_dc_u [0:3];
	reg signed [15:0] chr_dc_v [0:3];
	reg [3:0]  ac_u_done, ac_v_done;
	reg [1:0]  dc_only_bi;
	reg        dc_only_v;
	reg        dc_only_active;
	reg        pend_end;
	reg [15:0] pend_end_addr;
	assign busy = (st != ST_IDLE) || have_mb || pend_end;
	reg [5:0]  qp_hold;

	reg [4:0]  apply_px_i;
	reg [1:0]  apply_bx, apply_by;
	reg        apply_plane_v;
	reg        apply_is_dc_only;

	reg        dq_start;
	wire       dq_busy, dq_done;

	assign res_blk_ready = enable && (st == ST_IDLE);

	function automatic is_chr_dc;
		input i16; input [4:0] idx;
		begin
			if (i16) is_chr_dc = (idx == 5'd17) || (idx == 5'd18);
			else is_chr_dc = (idx == 5'd16) || (idx == 5'd17);
		end
	endfunction
	function automatic is_v;
		input i16; input [4:0] idx;
		begin
			if (i16) is_v = (idx == 5'd18) || (idx >= 5'd23);
			else is_v = (idx == 5'd17) || (idx >= 5'd22);
		end
	endfunction
	function automatic [1:0] ac_bi;
		input i16; input [4:0] idx;
		reg [4:0] base;
		begin
			if (i16) base = is_v(i16, idx) ? (idx - 5'd23) : (idx - 5'd19);
			else base = is_v(i16, idx) ? (idx - 5'd22) : (idx - 5'd18);
			ac_bi = base[1:0];
		end
	endfunction

	wire [5:0] qpc_w;
	h264_chroma_qp u_qpc (
		.qpy((dc_only_active || (st == ST_DC_KICK) || (st == ST_DC_SET)) ? qp_hold : lat_qp),
		.chroma_qp_index_offset(chroma_qp_index_offset),
		.qpc(qpc_w)
	);
	wire signed [15:0] dc_in [0:3];
	wire signed [15:0] dc_out [0:3];
	assign dc_in[0] = lat_coeff[0];
	assign dc_in[1] = lat_coeff[1];
	assign dc_in[2] = lat_coeff[2];
	assign dc_in[3] = lat_coeff[3];
	h264_chroma_dc_hadamard_inv u_dc (
		.coeff(dc_in), .qpc(qpc_w), .dc_out(dc_out)
	);

	reg signed [15:0] coeff_iq [0:15];
	reg [4:0] max_iq;
	reg [5:0] qp_iq;
	reg use_inj;
	reg signed [15:0] inj_dc;
	integer ci;
	wire signed [28:0] dq_raw [0:15];
	wire signed [28:0] idct_r [0:15];
	wire signed [28:0] dq_idct [0:15];
	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_dq
			if (gi == 0)
				assign dq_idct[0] = use_inj ? {{13{inj_dc[15]}}, inj_dc} : dq_raw[0];
			else
				assign dq_idct[gi] = dq_raw[gi];
		end
	endgenerate

	always @(*) begin
		for (ci = 0; ci < 16; ci = ci + 1) coeff_iq[ci] = lat_coeff[ci];
		max_iq = lat_max;
		qp_iq = qpc_w;
		use_inj = 1'b0;
		inj_dc = 16'sd0;
		if (!dc_only_active && (st != ST_DC_KICK) && (st != ST_DC_SET) &&
		    !is_chr_dc(lat_i16, lat_idx)) begin
			max_iq = 5'd15;
			use_inj = 1'b1;
			if (is_v(lat_i16, lat_idx))
				inj_dc = chr_dc_v_v ? chr_dc_v[ac_bi(lat_i16, lat_idx)] : 16'sd0;
			else
				inj_dc = chr_dc_u_v ? chr_dc_u[ac_bi(lat_i16, lat_idx)] : 16'sd0;
		end
		if (dc_only_active || (st == ST_DC_KICK) || (st == ST_DC_SET)) begin
			max_iq = 5'd15;
			use_inj = 1'b1;
			for (ci = 0; ci < 16; ci = ci + 1) coeff_iq[ci] = 16'sd0;
			if (dc_only_v)
				inj_dc = chr_dc_v_v ? chr_dc_v[dc_only_bi] : 16'sd0;
			else
				inj_dc = chr_dc_u_v ? chr_dc_u[dc_only_bi] : 16'sd0;
		end
	end

	h264_dequant4x4_serial u_dq (
		.clk(clk), .reset(reset),
		.start(dq_start),
		.coeff(coeff_iq),
		.qp(qp_iq),
		.max_coeff(max_iq),
		.busy(dq_busy), .done(dq_done),
		.dequant(dq_raw)
	);
	h264_idct4x4 u_idct (.dequant(dq_idct), .residual(idct_r));

	integer k;
	reg [1:0] cbi;
	wire [1:0] apx_y = apply_px_i[3:2];
	wire [1:0] apx_x = apply_px_i[1:0];
	// Width-cast 2-bit coords before the 6-bit chroma address math (lint WIDTHEXPAND).
	wire [5:0] apx_addr =
		(({4'd0, apply_by[0]} * 6'd4) + {4'd0, apx_y}) * 6'd8
		+ (({4'd0, apply_bx[0]} * 6'd4) + {4'd0, apx_x});

	always @(posedge clk) begin
		mb_res_done <= 1'b0;
		dq_start <= 1'b0;

		if (reset) begin
			st <= ST_IDLE;
			have_mb <= 1'b0;
			cur_mb <= 16'd0;
			lat_i16 <= 1'b0; lat_idx <= 5'd0; lat_qp <= 6'd0; lat_max <= 5'd4;
			chr_dc_u_v <= 1'b0; chr_dc_v_v <= 1'b0;
			ac_u_done <= 4'd0; ac_v_done <= 4'd0;
			pend_end <= 1'b0; pend_end_addr <= 16'd0;
			qp_hold <= 6'd0;
			dc_only_bi <= 2'd0; dc_only_v <= 1'b0; dc_only_active <= 1'b0;
			mb_res_done_addr <= 16'd0;
			apply_px_i <= 5'd0;
			apply_bx <= 2'd0; apply_by <= 2'd0;
			apply_plane_v <= 1'b0; apply_is_dc_only <= 1'b0;
			for (k = 0; k < 4; k = k + 1) begin chr_dc_u[k] <= 16'sd0; chr_dc_v[k] <= 16'sd0; end
			for (k = 0; k < 16; k = k + 1) lat_coeff[k] <= 16'sd0;
			for (k = 0; k < 64; k = k + 1) begin res_u[k] <= 16'sd0; res_v[k] <= 16'sd0; end
		end else if (clear_mb) begin
			// Highest priority: must win over in-flight ST_APPLY_PX / pend_end.
			// Same-cycle NBA after case(st) previously left stale residual when
			// the next MB (often cbp_c=0 / P_Skip) accepted while apply still ran.
			have_mb <= 1'b0;
			chr_dc_u_v <= 1'b0; chr_dc_v_v <= 1'b0;
			ac_u_done <= 4'd0; ac_v_done <= 4'd0;
			pend_end <= 1'b0;
			dc_only_active <= 1'b0;
			dc_only_v <= 1'b0;
			apply_is_dc_only <= 1'b0;
			apply_px_i <= 5'd0;
			dq_start <= 1'b0;
			st <= ST_IDLE;
			for (k = 0; k < 64; k = k + 1) begin res_u[k] <= 16'sd0; res_v[k] <= 16'sd0; end
	end else begin
			if (res_mb_end && enable) begin
				pend_end <= 1'b1;
				pend_end_addr <= res_mb_end_addr;
			end

			case (st)
			ST_IDLE: begin
				if (enable && res_blk_valid && res_blk_ready && !res_blk_is_luma && !FAULT_SKIP) begin
					if (!have_mb || (res_blk_mb_addr != cur_mb)) begin
						have_mb <= 1'b1;
						cur_mb <= res_blk_mb_addr;
						chr_dc_u_v <= 1'b0; chr_dc_v_v <= 1'b0;
						ac_u_done <= 4'd0; ac_v_done <= 4'd0;
						for (k = 0; k < 64; k = k + 1) begin
							res_u[k] <= 16'sd0; res_v[k] <= 16'sd0;
						end
					end
					lat_i16 <= res_blk_is_i16;
					lat_idx <= res_blk_idx;
					lat_qp <= res_blk_qp;
					lat_max <= res_blk_max_coeff;
					qp_hold <= res_blk_qp;
					for (ci = 0; ci < 16; ci = ci + 1)
						lat_coeff[ci] <= res_blk_coeff[ci];
					st <= ST_SETTLE;
				end else if (enable && pend_end && have_mb && (pend_end_addr == cur_mb)) begin
					// Finish DC-only blocks that never saw AC.
					if (chr_dc_u_v && (ac_u_done != 4'hF)) begin
						dc_only_v <= 1'b0;
						dc_only_bi <= !ac_u_done[0] ? 2'd0 :
						              !ac_u_done[1] ? 2'd1 :
						              !ac_u_done[2] ? 2'd2 : 2'd3;
						st <= ST_DC_SET;
					end else if (chr_dc_v_v && (ac_v_done != 4'hF)) begin
						dc_only_v <= 1'b1;
						dc_only_bi <= !ac_v_done[0] ? 2'd0 :
						              !ac_v_done[1] ? 2'd1 :
						              !ac_v_done[2] ? 2'd2 : 2'd3;
						st <= ST_DC_SET;
					end else begin
						mb_res_done <= 1'b1;
						mb_res_done_addr <= pend_end_addr;
						pend_end <= 1'b0;
						have_mb <= 1'b0;
					end
				end else if (enable && pend_end && !have_mb) begin
					mb_res_done <= 1'b1;
					mb_res_done_addr <= pend_end_addr;
					pend_end <= 1'b0;
				end
			end

			ST_SETTLE: begin
				if (is_chr_dc(lat_i16, lat_idx)) begin
					if (is_v(lat_i16, lat_idx)) begin
						for (k = 0; k < 4; k = k + 1) chr_dc_v[k] <= dc_out[k];
						chr_dc_v_v <= 1'b1;
					end else begin
						for (k = 0; k < 4; k = k + 1) chr_dc_u[k] <= dc_out[k];
						chr_dc_u_v <= 1'b1;
					end
					st <= ST_IDLE;
				end else begin
					// Chroma AC: serial dequant then pixel apply
					apply_is_dc_only <= 1'b0;
					cbi = ac_bi(lat_i16, lat_idx);
					apply_bx <= {1'b0, cbi[0]};
					apply_by <= {1'b0, cbi[1]};
					apply_plane_v <= is_v(lat_i16, lat_idx);
					dq_start <= 1'b1;
					st <= ST_IQ_WAIT;
				end
			end

			ST_DC_SET: begin
				// One settle so combo sees dc_only_* before start sample.
				dc_only_active <= 1'b1;
				apply_is_dc_only <= 1'b1;
				apply_bx <= {1'b0, dc_only_bi[0]};
				apply_by <= {1'b0, dc_only_bi[1]};
				apply_plane_v <= dc_only_v;
				st <= ST_DC_KICK;
			end

			ST_DC_KICK: begin
				dq_start <= 1'b1;
				st <= ST_IQ_WAIT;
			end

			ST_IQ_WAIT: begin
				if (dq_done) begin
					apply_px_i <= 5'd0;
					st <= ST_APPLY_PX;
				end
			end

			ST_APPLY_PX: begin
				if (apply_plane_v)
					res_v[apx_addr] <= idct_r[{apx_y, apx_x}][15:0];
				else
					res_u[apx_addr] <= idct_r[{apx_y, apx_x}][15:0];

				if (apply_px_i == 5'd15) begin
					if (apply_is_dc_only || dc_only_active) begin
						if (dc_only_v) ac_v_done[dc_only_bi] <= 1'b1;
						else ac_u_done[dc_only_bi] <= 1'b1;
						dc_only_active <= 1'b0;
						apply_is_dc_only <= 1'b0;
					end else begin
						cbi = ac_bi(lat_i16, lat_idx);
						if (apply_plane_v) ac_v_done[cbi] <= 1'b1;
						else ac_u_done[cbi] <= 1'b1;
					end
					apply_px_i <= 5'd0;
					st <= ST_IDLE;
				end else
					apply_px_i <= apply_px_i + 5'd1;
			end

			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
