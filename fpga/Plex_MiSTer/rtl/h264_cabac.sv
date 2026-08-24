`default_nettype none
// H.264 CABAC arithmetic decoder. Target: 1 regular/bypass/terminate bin per
// clk_sys cycle when the bit FIFO has ≥8 bits (renorm is a barrel shift).
// Context init uses ITU-T H.264 Tables 9-12..9-24 m/n (ctxIdx 0..459).
//
// FAULT_SKIP_RENORM: never shift range/offset. FAULT_BAD_INIT: invert valMPS.
module h264_cabac (
	input  wire        clk,
	input  wire        reset,

	input  wire        slice_start,
	input  wire [1:0]  slice_type,       // 0=I, 1=P, 2=B
	input  wire [1:0]  cabac_init_idc,   // ignored on I slices
	input  wire [5:0]  slice_qp_y,

	input  wire        bit_valid,
	input  wire        bit_in,
	output wire        bit_ready,

	output reg         init_busy,
	output reg         init_done,
	output wire        primed,

	input  wire        dec_req,
	input  wire [8:0]  ctx_idx,          // 0..459
	input  wire        bypass,
	input  wire        terminate,
	output reg         dec_valid,
	output reg         dec_bin,
	output wire        dec_stall,        // 1 = waiting for bits (not 1 bin/cyc)

	output wire [8:0]  dbg_range,
	output wire [8:0]  dbg_offset,
	output wire [4:0]  dbg_fifo_count
);
	localparam int CTX_N = 460;
	localparam [8:0] RANGE_INIT = 9'd510; // 0x1FE

	reg [8:0] range_r;
	reg [9:0] offset_r; // 10-bit: bypass may exceed 9 bits before the next regular renorm
	reg [15:0] fifo_r;
	reg [4:0]  fifo_n_r;
	reg        primed_r; // 9-bit offset loaded
	reg [8:0]  ctx_i;
	reg [6:0]  ctx_r [0:CTX_N-1]; // {valMPS, pStateIdx[5:0]}

	function automatic [5:0] trans_mps;
		input [5:0] s;
		begin
			if (s >= 6'd62) trans_mps = s;
			else trans_mps = s + 6'd1;
		end
	endfunction

	function automatic [5:0] trans_lps;
		input [5:0] s;
		begin
			case (s)
			6'd0: trans_lps=6'd0;  6'd1: trans_lps=6'd0;  6'd2: trans_lps=6'd1;
			6'd3: trans_lps=6'd2;  6'd4: trans_lps=6'd2;  6'd5: trans_lps=6'd4;
			6'd6: trans_lps=6'd4;  6'd7: trans_lps=6'd5;  6'd8: trans_lps=6'd6;
			6'd9: trans_lps=6'd7;  6'd10:trans_lps=6'd8;  6'd11:trans_lps=6'd9;
			6'd12:trans_lps=6'd9;  6'd13:trans_lps=6'd11; 6'd14:trans_lps=6'd11;
			6'd15:trans_lps=6'd12; 6'd16:trans_lps=6'd13; 6'd17:trans_lps=6'd13;
			6'd18:trans_lps=6'd15; 6'd19:trans_lps=6'd15; 6'd20:trans_lps=6'd16;
			6'd21:trans_lps=6'd16; 6'd22:trans_lps=6'd18; 6'd23:trans_lps=6'd18;
			6'd24:trans_lps=6'd19; 6'd25:trans_lps=6'd19; 6'd26:trans_lps=6'd21;
			6'd27:trans_lps=6'd21; 6'd28:trans_lps=6'd22; 6'd29:trans_lps=6'd22;
			6'd30:trans_lps=6'd23; 6'd31:trans_lps=6'd24; 6'd32:trans_lps=6'd24;
			6'd33:trans_lps=6'd25; 6'd34:trans_lps=6'd26; 6'd35:trans_lps=6'd26;
			6'd36:trans_lps=6'd27; 6'd37:trans_lps=6'd27; 6'd38:trans_lps=6'd28;
			6'd39:trans_lps=6'd29; 6'd40:trans_lps=6'd29; 6'd41:trans_lps=6'd30;
			6'd42:trans_lps=6'd30; 6'd43:trans_lps=6'd30; 6'd44:trans_lps=6'd31;
			6'd45:trans_lps=6'd32; 6'd46:trans_lps=6'd32; 6'd47:trans_lps=6'd33;
			6'd48:trans_lps=6'd33; 6'd49:trans_lps=6'd33; 6'd50:trans_lps=6'd34;
			6'd51:trans_lps=6'd34; 6'd52:trans_lps=6'd35; 6'd53:trans_lps=6'd35;
			6'd54:trans_lps=6'd35; 6'd55:trans_lps=6'd36; 6'd56:trans_lps=6'd36;
			6'd57:trans_lps=6'd36; 6'd58:trans_lps=6'd37; 6'd59:trans_lps=6'd37;
			6'd60:trans_lps=6'd37; 6'd61:trans_lps=6'd38; 6'd62:trans_lps=6'd38;
			default: trans_lps=6'd63;
			endcase
		end
	endfunction

	function automatic [7:0] range_lps;
		input [5:0] s;
		input [1:0] q;
		reg [7:0] t0, t1, t2, t3;
		begin
			case (s)
			6'd0:  begin t0=8'd128; t1=8'd176; t2=8'd208; t3=8'd240; end
			6'd1:  begin t0=8'd128; t1=8'd167; t2=8'd197; t3=8'd227; end
			6'd2:  begin t0=8'd128; t1=8'd158; t2=8'd187; t3=8'd216; end
			6'd3:  begin t0=8'd123; t1=8'd150; t2=8'd178; t3=8'd205; end
			6'd4:  begin t0=8'd116; t1=8'd142; t2=8'd169; t3=8'd195; end
			6'd5:  begin t0=8'd111; t1=8'd135; t2=8'd160; t3=8'd185; end
			6'd6:  begin t0=8'd105; t1=8'd128; t2=8'd152; t3=8'd175; end
			6'd7:  begin t0=8'd100; t1=8'd122; t2=8'd144; t3=8'd166; end
			6'd8:  begin t0=8'd95;  t1=8'd116; t2=8'd137; t3=8'd158; end
			6'd9:  begin t0=8'd90;  t1=8'd110; t2=8'd130; t3=8'd150; end
			6'd10: begin t0=8'd85;  t1=8'd104; t2=8'd123; t3=8'd142; end
			6'd11: begin t0=8'd81;  t1=8'd99;  t2=8'd117; t3=8'd135; end
			6'd12: begin t0=8'd77;  t1=8'd94;  t2=8'd111; t3=8'd128; end
			6'd13: begin t0=8'd73;  t1=8'd89;  t2=8'd105; t3=8'd122; end
			6'd14: begin t0=8'd69;  t1=8'd85;  t2=8'd100; t3=8'd116; end
			6'd15: begin t0=8'd66;  t1=8'd80;  t2=8'd95;  t3=8'd110; end
			6'd16: begin t0=8'd62;  t1=8'd76;  t2=8'd90;  t3=8'd104; end
			6'd17: begin t0=8'd59;  t1=8'd72;  t2=8'd86;  t3=8'd99;  end
			6'd18: begin t0=8'd56;  t1=8'd69;  t2=8'd81;  t3=8'd94;  end
			6'd19: begin t0=8'd53;  t1=8'd65;  t2=8'd77;  t3=8'd89;  end
			6'd20: begin t0=8'd51;  t1=8'd62;  t2=8'd73;  t3=8'd85;  end
			6'd21: begin t0=8'd48;  t1=8'd59;  t2=8'd69;  t3=8'd80;  end
			6'd22: begin t0=8'd46;  t1=8'd56;  t2=8'd66;  t3=8'd76;  end
			6'd23: begin t0=8'd43;  t1=8'd53;  t2=8'd63;  t3=8'd72;  end
			6'd24: begin t0=8'd41;  t1=8'd50;  t2=8'd59;  t3=8'd69;  end
			6'd25: begin t0=8'd39;  t1=8'd48;  t2=8'd56;  t3=8'd65;  end
			6'd26: begin t0=8'd37;  t1=8'd45;  t2=8'd54;  t3=8'd62;  end
			6'd27: begin t0=8'd35;  t1=8'd43;  t2=8'd51;  t3=8'd59;  end
			6'd28: begin t0=8'd33;  t1=8'd41;  t2=8'd48;  t3=8'd56;  end
			6'd29: begin t0=8'd32;  t1=8'd39;  t2=8'd46;  t3=8'd53;  end
			6'd30: begin t0=8'd30;  t1=8'd37;  t2=8'd43;  t3=8'd50;  end
			6'd31: begin t0=8'd29;  t1=8'd35;  t2=8'd41;  t3=8'd48;  end
			6'd32: begin t0=8'd27;  t1=8'd33;  t2=8'd39;  t3=8'd45;  end
			6'd33: begin t0=8'd26;  t1=8'd31;  t2=8'd37;  t3=8'd43;  end
			6'd34: begin t0=8'd24;  t1=8'd30;  t2=8'd35;  t3=8'd41;  end
			6'd35: begin t0=8'd23;  t1=8'd28;  t2=8'd33;  t3=8'd39;  end
			6'd36: begin t0=8'd22;  t1=8'd27;  t2=8'd32;  t3=8'd37;  end
			6'd37: begin t0=8'd21;  t1=8'd26;  t2=8'd30;  t3=8'd35;  end
			6'd38: begin t0=8'd20;  t1=8'd24;  t2=8'd29;  t3=8'd33;  end
			6'd39: begin t0=8'd19;  t1=8'd23;  t2=8'd27;  t3=8'd31;  end
			6'd40: begin t0=8'd18;  t1=8'd22;  t2=8'd26;  t3=8'd30;  end
			6'd41: begin t0=8'd17;  t1=8'd21;  t2=8'd25;  t3=8'd28;  end
			6'd42: begin t0=8'd16;  t1=8'd20;  t2=8'd23;  t3=8'd27;  end
			6'd43: begin t0=8'd15;  t1=8'd19;  t2=8'd22;  t3=8'd25;  end
			6'd44: begin t0=8'd14;  t1=8'd18;  t2=8'd21;  t3=8'd24;  end
			6'd45: begin t0=8'd14;  t1=8'd17;  t2=8'd20;  t3=8'd23;  end
			6'd46: begin t0=8'd13;  t1=8'd16;  t2=8'd19;  t3=8'd22;  end
			6'd47: begin t0=8'd12;  t1=8'd15;  t2=8'd18;  t3=8'd21;  end
			6'd48: begin t0=8'd12;  t1=8'd14;  t2=8'd17;  t3=8'd20;  end
			6'd49: begin t0=8'd11;  t1=8'd14;  t2=8'd16;  t3=8'd19;  end
			6'd50: begin t0=8'd11;  t1=8'd13;  t2=8'd15;  t3=8'd18;  end
			6'd51: begin t0=8'd10;  t1=8'd12;  t2=8'd15;  t3=8'd17;  end
			6'd52: begin t0=8'd10;  t1=8'd12;  t2=8'd14;  t3=8'd16;  end
			6'd53: begin t0=8'd9;   t1=8'd11;  t2=8'd13;  t3=8'd15;  end
			6'd54: begin t0=8'd9;   t1=8'd11;  t2=8'd12;  t3=8'd14;  end
			6'd55: begin t0=8'd8;   t1=8'd10;  t2=8'd12;  t3=8'd14;  end
			6'd56: begin t0=8'd8;   t1=8'd9;   t2=8'd11;  t3=8'd13;  end
			6'd57: begin t0=8'd7;   t1=8'd9;   t2=8'd11;  t3=8'd12;  end
			6'd58: begin t0=8'd7;   t1=8'd9;   t2=8'd10;  t3=8'd12;  end
			6'd59: begin t0=8'd7;   t1=8'd8;   t2=8'd10;  t3=8'd11;  end
			6'd60: begin t0=8'd6;   t1=8'd8;   t2=8'd9;   t3=8'd11;  end
			6'd61: begin t0=8'd6;   t1=8'd7;   t2=8'd9;   t3=8'd10;  end
			6'd62: begin t0=8'd6;   t1=8'd7;   t2=8'd8;   t3=8'd9;   end
			default: begin t0=8'd2; t1=8'd2; t2=8'd2; t3=8'd2; end
			endcase
			case (q)
			2'd0: range_lps = t0;
			2'd1: range_lps = t1;
			2'd2: range_lps = t2;
			default: range_lps = t3;
			endcase
		end
	endfunction

	function automatic [3:0] lz9;
		input [8:0] r;
		begin
			if (r[8]) lz9 = 4'd0;
			else if (r[7]) lz9 = 4'd1;
			else if (r[6]) lz9 = 4'd2;
			else if (r[5]) lz9 = 4'd3;
			else if (r[4]) lz9 = 4'd4;
			else if (r[3]) lz9 = 4'd5;
			else if (r[2]) lz9 = 4'd6;
			else if (r[1]) lz9 = 4'd7;
			else lz9 = 4'd8;
		end
	endfunction

	function automatic [8:0] shl9;
		input [8:0] v;
		input [3:0] s;
		begin
			case (s)
			4'd0: shl9 = v;
			4'd1: shl9 = {v[7:0], 1'b0};
			4'd2: shl9 = {v[6:0], 2'b0};
			4'd3: shl9 = {v[5:0], 3'b0};
			4'd4: shl9 = {v[4:0], 4'b0};
			4'd5: shl9 = {v[3:0], 5'b0};
			4'd6: shl9 = {v[2:0], 6'b0};
			4'd7: shl9 = {v[1:0], 7'b0};
			default: shl9 = {v[0], 8'b0};
			endcase
		end
	endfunction

	function automatic [15:0] shl16;
		input [15:0] v;
		input [3:0] s;
		begin
			case (s)
			4'd0: shl16 = v;
			4'd1: shl16 = {v[14:0], 1'b0};
			4'd2: shl16 = {v[13:0], 2'b0};
			4'd3: shl16 = {v[12:0], 3'b0};
			4'd4: shl16 = {v[11:0], 4'b0};
			4'd5: shl16 = {v[10:0], 5'b0};
			4'd6: shl16 = {v[9:0], 6'b0};
			4'd7: shl16 = {v[8:0], 7'b0};
			default: shl16 = {v[7:0], 8'b0};
			endcase
		end
	endfunction

	// ITU-T H.264 Tables 9-12..9-24. Packed {m,n} ROM: I, P/B init_idc 0/1/2.
`include "h264_cabac_init_rom.svh"
	function automatic [10:0] mn_addr;
		input [8:0] ctx;
		input [1:0] stype;
		input [1:0] iidc;
		reg [8:0] c;
		reg [10:0] base;
		begin
			c = (ctx > 9'd459) ? 9'd459 : ctx;
			if (stype == 2'd0) base = 11'd0;
			else if (iidc == 2'd0) base = 11'd460;
			else if (iidc == 2'd1) base = 11'd920;
			else base = 11'd1380;
			mn_addr = base + {2'b00, c};
		end
	endfunction
	function automatic signed [7:0] init_m;
		input [8:0] ctx;
		input [1:0] stype;
		input [1:0] iidc;
		begin
			init_m = CABAC_MN_ROM[mn_addr(ctx, stype, iidc)][15:8];
		end
	endfunction
	function automatic signed [7:0] init_n;
		input [8:0] ctx;
		input [1:0] stype;
		input [1:0] iidc;
		begin
			init_n = CABAC_MN_ROM[mn_addr(ctx, stype, iidc)][7:0];
		end
	endfunction

	function automatic [6:0] ctx_init_pack;
		input [8:0] ctx;
		input [5:0] qp;
		input [1:0] stype;
		input [1:0] iidc;
		reg signed [15:0] pre;
		reg [6:0] preu;
		reg mps;
		reg [5:0] pstate;
		begin
			pre = ($signed({{8{init_m(ctx, stype, iidc)[7]}}, init_m(ctx, stype, iidc)}) * $signed({10'd0, qp})) >>> 4;
			pre = pre + {{8{init_n(ctx, stype, iidc)[7]}}, init_n(ctx, stype, iidc)};
			if (pre < 16'sd1) pre = 16'sd1;
			if (pre > 16'sd126) pre = 16'sd126;
			preu = pre[6:0];
			if (preu <= 7'd63) begin
				pstate = 6'd63 - preu[5:0];
				mps = 1'b0;
			end else begin
				pstate = preu[5:0];
				mps = 1'b1;
			end
`ifdef H264_CABAC_FAULT_BAD_INIT
			mps = ~mps;
`endif
			ctx_init_pack = {mps, pstate};
		end
	endfunction

	// Combinational FIFO: push first, then prime/decode consume the new count.
	wire do_push = bit_valid && (fifo_n_r < 5'd16) && !reset && !slice_start;
	wire [15:0] fifo_pushed = do_push ? {fifo_r[14:0], bit_in} : fifo_r;
	wire [4:0] n_pushed = do_push ? (fifo_n_r + 5'd1) : fifo_n_r;

	function automatic [8:0] fifo_msbs;
		input [15:0] f;
		input [4:0] n;
		input [3:0] s;
		reg [15:0] sh;
		begin
			if ((s == 4'd0) || (n < {1'b0, s}))
				fifo_msbs = 9'd0;
			else begin
				sh = f >> (n - {1'b0, s});
				fifo_msbs = sh[8:0] & 9'(((16'd1 << s) - 16'd1));
			end
		end
	endfunction

	wire [8:0] prime9 = fifo_msbs(fifo_pushed, n_pushed, 4'd9);
	wire       bypass_bit = fifo_msbs(fifo_pushed, n_pushed, 4'd1)[0];

	assign bit_ready = (fifo_n_r < 5'd16);
	assign primed = primed_r;
	assign dbg_range = range_r;
	assign dbg_offset = offset_r[8:0];
	assign dbg_fifo_count = fifo_n_r;

	wire [6:0] ctx_pack = ctx_r[ctx_idx];
	wire        val_mps = ctx_pack[6];
	wire [5:0]  pstate  = ctx_pack[5:0];
	wire [1:0]  rq = range_r[7:6];
	wire [8:0]  r_lps = {1'b0, range_lps(pstate, rq)};
	wire [8:0]  r_mps = range_r - r_lps;
	wire [8:0]  r_term_mps = range_r - 9'd2;
	wire [9:0]  range10 = {1'b0, range_r};
	wire [9:0]  r_mps10 = {1'b0, r_mps};
	wire [9:0]  r_term10 = {1'b0, r_term_mps};

	// ITU-T H.264 9.3.3.2.3 DecodeBypass: shift 1 bit first, then compare.
	wire [10:0] byp_acc = {offset_r, bypass_bit};
	wire        byp_ge = (byp_acc >= {1'b0, range10});
	wire        bin_byp = byp_ge;
	wire [9:0]  off_byp = byp_ge ? (byp_acc[9:0] - range10) : byp_acc[9:0];

	wire        term_ge = (offset_r >= r_term10);
	wire        reg_lps = (offset_r >= r_mps10);
	wire        bin_reg = terminate ? term_ge :
	                      bypass ? bin_byp :
	                      (reg_lps ? ~val_mps : val_mps);
	wire [8:0] r_after = terminate ? (term_ge ? 9'd2 : r_term_mps) :
	                     bypass ? range_r :
	                     (reg_lps ? r_lps : r_mps);
	wire [9:0] off_after = terminate ? (term_ge ? (offset_r - r_term10) : offset_r) :
	                       bypass ? off_byp :
	                       (reg_lps ? (offset_r - r_mps10) : offset_r);
	wire lps_hit = !bypass && !terminate && reg_lps;

	wire [3:0] renorm_s =
		bypass ? 4'd1 :
`ifdef H264_CABAC_FAULT_SKIP_RENORM
		4'd0;
`else
		lz9(r_after);
`endif
	wire [8:0] range_n = bypass ? range_r : shl9(r_after, renorm_s);
	wire [8:0] taken = fifo_msbs(fifo_pushed, n_pushed, renorm_s);
	wire [17:0] off_ren = ({8'd0, off_after} << renorm_s) | {9'd0, taken};
	wire [9:0] off_n = bypass ? off_byp : off_ren[9:0];
	wire [4:0] n_after_dec = (n_pushed >= {1'b0, renorm_s}) ?
	                         (n_pushed - {1'b0, renorm_s}) : 5'd0;
	wire bits_ok = bypass ? (n_pushed >= 5'd1) : (n_pushed >= 5'd8);
	assign dec_stall = dec_req && primed_r && !init_busy && !bits_ok;

	integer ci;

	always @(posedge clk) begin
		dec_valid <= 1'b0;
		init_done <= 1'b0;
		if (reset) begin
			range_r <= RANGE_INIT;
			offset_r <= 10'd0;
			fifo_r <= 16'd0;
			fifo_n_r <= 5'd0;
			primed_r <= 1'b0;
			init_busy <= 1'b0;
			ctx_i <= 9'd0;
			for (ci = 0; ci < CTX_N; ci = ci + 1)
				ctx_r[ci] <= 7'd0;
		end else if (slice_start) begin
			range_r <= RANGE_INIT;
			offset_r <= 10'd0;
			fifo_r <= 16'd0;
			fifo_n_r <= 5'd0;
			primed_r <= 1'b0;
			init_busy <= 1'b1;
			ctx_i <= 9'd0;
		end else begin
			fifo_r <= fifo_pushed;
			fifo_n_r <= n_pushed;
			if (init_busy) begin
				ctx_r[ctx_i] <= ctx_init_pack(ctx_i, slice_qp_y, slice_type, cabac_init_idc);
				if (ctx_i == 9'd459) begin
					init_busy <= 1'b0;
					init_done <= 1'b1;
				end else
					ctx_i <= ctx_i + 9'd1;
			end else if (!primed_r && (n_pushed >= 5'd9)) begin
				offset_r <= {1'b0, prime9};
				fifo_n_r <= n_pushed - 5'd9;
				primed_r <= 1'b1;
			end else if (dec_req && primed_r && bits_ok) begin
				range_r <= range_n;
				offset_r <= off_n;
				fifo_n_r <= n_after_dec;
				if (!bypass && !terminate) begin
					if (lps_hit)
						ctx_r[ctx_idx] <= {((pstate == 6'd0) ? ~val_mps : val_mps), trans_lps(pstate)};
					else
						ctx_r[ctx_idx] <= {val_mps, trans_mps(pstate)};
				end
				dec_valid <= 1'b1;
				dec_bin <= bin_reg;
			end
		end
	end
endmodule

// 1-cycle binarization helpers used by tests / future decode_core hook.
// coeff_abs UEG0 prefix: 1s then 0; suffix is bypass.
module h264_cabac_ueg0_pref (
	input  wire [4:0] abs_m1,     // coeff_abs_level_minus1, saturates at 14 prefix
	output wire [4:0] pref_ones,  // number of 1 bins before the terminating 0
	output wire       pref_zero   // always emit a 0 after the ones (if abs_m1<14)
);
	assign pref_ones = (abs_m1 >= 5'd14) ? 5'd14 : abs_m1;
	assign pref_zero = (abs_m1 < 5'd14);
endmodule

// residual_block_cabac for 4x4 (ctxBlockCat 0..4). Drives one h264_cabac engine.
// FAULT_FORCE_CBF0: treat coded_block_flag as 0 after the bin is consumed.
module h264_cabac_residual_4x4 (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [2:0]  cat,          // 0=I16DC 1=I16AC 2=luma4x4 3=chrDC 4=chrAC
	input  wire        cbf_nA,
	input  wire        cbf_nB,
	input  wire [4:0]  max_coeff,    // 16 / 15 / 4
	input  wire        skip_cbf,

	output reg         dec_req,
	output reg  [8:0]  ctx_idx,
	output reg         bypass,
	output reg         terminate,
	input  wire        dec_valid,
	input  wire        dec_bin,
	input  wire        primed,
	input  wire        init_busy,

	output reg         done,
	output reg         ok,
	output reg  signed [15:0] coeff [0:15],
	output reg  [4:0]  total_coeff
);
	localparam [3:0]
		S_IDLE  = 4'd0,
		S_CBF   = 4'd1,
		S_SIG   = 4'd2,
		S_LAST  = 4'd3,
		S_ABS0  = 4'd4,
		S_ABSGT = 4'd5,
		S_UEG1  = 4'd6,
		S_UEG2  = 4'd7,
		S_SIGN  = 4'd8,
		S_NEXT  = 4'd9,
		S_DONE  = 4'd10;

	function automatic [8:0] cbf_base;
		input [2:0] c;
		begin
			case (c)
			3'd0: cbf_base = 9'd85;
			3'd1: cbf_base = 9'd89;
			3'd2: cbf_base = 9'd93;
			3'd3: cbf_base = 9'd97;
			default: cbf_base = 9'd101;
			endcase
		end
	endfunction
	function automatic [8:0] sig_base;
		input [2:0] c;
		begin
			case (c)
			3'd0: sig_base = 9'd105;
			3'd1: sig_base = 9'd120;
			3'd2: sig_base = 9'd134;
			3'd3: sig_base = 9'd149;
			default: sig_base = 9'd152;
			endcase
		end
	endfunction
	function automatic [8:0] last_base;
		input [2:0] c;
		begin
			case (c)
			3'd0: last_base = 9'd166;
			3'd1: last_base = 9'd181;
			3'd2: last_base = 9'd191;
			3'd3: last_base = 9'd206;
			default: last_base = 9'd209;
			endcase
		end
	endfunction
	function automatic [8:0] abs_base;
		input [2:0] c;
		begin
			case (c)
			3'd0: abs_base = 9'd227;
			3'd1: abs_base = 9'd237;
			3'd2: abs_base = 9'd247;
			3'd3: abs_base = 9'd257;
			default: abs_base = 9'd266;
			endcase
		end
	endfunction
	function automatic [3:0] lvl1_ctx;
		input [2:0] n;
		begin
			case (n)
			3'd0: lvl1_ctx = 4'd1;
			3'd1: lvl1_ctx = 4'd2;
			3'd2: lvl1_ctx = 4'd3;
			3'd3: lvl1_ctx = 4'd4;
			default: lvl1_ctx = 4'd0;
			endcase
		end
	endfunction
	function automatic [3:0] gt1_ctx;
		input [2:0] n;
		begin
			case (n)
			3'd4: gt1_ctx = 4'd6;
			3'd5: gt1_ctx = 4'd7;
			3'd6: gt1_ctx = 4'd8;
			3'd7: gt1_ctx = 4'd9;
			default: gt1_ctx = 4'd5;
			endcase
		end
	endfunction
	function automatic [2:0] trans0;
		input [2:0] n;
		begin
			case (n)
			3'd0: trans0 = 3'd1;
			3'd1: trans0 = 3'd2;
			3'd2: trans0 = 3'd3;
			3'd3: trans0 = 3'd3;
			3'd4: trans0 = 3'd4;
			3'd5: trans0 = 3'd5;
			3'd6: trans0 = 3'd6;
			default: trans0 = 3'd7;
			endcase
		end
	endfunction
	function automatic [2:0] trans1;
		input [2:0] n;
		begin
			case (n)
			3'd0, 3'd1, 3'd2, 3'd3: trans1 = 3'd4;
			3'd4: trans1 = 3'd5;
			3'd5: trans1 = 3'd6;
			default: trans1 = 3'd7;
			endcase
		end
	endfunction

	reg [3:0]  st;
	reg [4:0]  scan_i;
	reg [15:0] sig_m;
	reg [2:0]  node_ctx;
	reg [4:0]  abs_acc;
	reg [4:0]  ueg_j;
	reg [4:0]  ueg_left;
	reg [15:0] abs_full;
	reg [2:0]  cat_r;
	reg [4:0]  max_r;
	reg        nA_r, nB_r;
	reg        want_bin;

	integer ci;

	wire [3:0] scan4 = scan_i[3:0];
	wire hold_req = want_bin && primed && !init_busy && !reset;
	// Bubble one cycle after dec_valid so ctx_idx is the registered next
	// state, not the consume-cycle state (engine has 1-cycle latency).

	always @* begin
		dec_req = 1'b0;
		ctx_idx = 9'd0;
		bypass = 1'b0;
		terminate = 1'b0;
		if (hold_req && !dec_valid) begin
			dec_req = 1'b1;
			case (st)
			S_CBF:  ctx_idx = cbf_base(cat_r) + {7'd0, nA_r} + {6'd0, nB_r, 1'b0};
			S_SIG:  ctx_idx = sig_base(cat_r) + {4'd0, scan_i};
			S_LAST: ctx_idx = last_base(cat_r) + {4'd0, scan_i};
			S_ABS0: ctx_idx = abs_base(cat_r) + {5'd0, lvl1_ctx(node_ctx)};
			S_ABSGT: ctx_idx = abs_base(cat_r) + {5'd0, gt1_ctx(node_ctx)};
			S_UEG1, S_UEG2, S_SIGN: bypass = 1'b1;
			default: dec_req = 1'b0;
			endcase
		end
	end

	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			st <= S_IDLE;
			ok <= 1'b0;
			total_coeff <= 5'd0;
			want_bin <= 1'b0;
			scan_i <= 5'd0;
			sig_m <= 16'd0;
			node_ctx <= 3'd0;
			abs_acc <= 5'd0;
			ueg_j <= 5'd0;
			ueg_left <= 5'd0;
			abs_full <= 16'd0;
			cat_r <= 3'd2;
			max_r <= 5'd16;
			nA_r <= 1'b0;
			nB_r <= 1'b0;
			for (ci = 0; ci < 16; ci = ci + 1)
				coeff[ci] <= 16'sd0;
		end else if (start) begin
			st <= skip_cbf ? S_SIG : S_CBF;
			ok <= 1'b0;
			total_coeff <= 5'd0;
			want_bin <= 1'b1;
			scan_i <= 5'd0;
			sig_m <= 16'd0;
			node_ctx <= 3'd0;
			abs_acc <= 5'd0;
			ueg_j <= 5'd0;
			ueg_left <= 5'd0;
			abs_full <= 16'd0;
			cat_r <= cat;
			max_r <= (max_coeff == 5'd0) ? 5'd16 : max_coeff;
			nA_r <= cbf_nA;
			nB_r <= cbf_nB;
			for (ci = 0; ci < 16; ci = ci + 1)
				coeff[ci] <= 16'sd0;
		end else if (st == S_DONE) begin
			done <= 1'b1;
			want_bin <= 1'b0;
			st <= S_IDLE;
		end else if (st == S_NEXT) begin
			if (scan_i == 5'd0) begin
				st <= S_IDLE;
				done <= 1'b1;
				ok <= 1'b1;
				want_bin <= 1'b0;
			end else begin
				scan_i <= scan_i - 5'd1;
				if (sig_m[scan_i[3:0] - 4'd1]) begin
					st <= S_ABS0;
					want_bin <= 1'b1;
				end else
					want_bin <= 1'b0;
			end
		end else if (dec_valid && want_bin) begin
			case (st)
			S_CBF: begin
`ifdef H264_CABAC_RES_FAULT_FORCE_CBF0
				st <= S_IDLE;
				done <= 1'b1;
				ok <= 1'b1;
				want_bin <= 1'b0;
`else
				if (!dec_bin) begin
					st <= S_IDLE;
					done <= 1'b1;
					ok <= 1'b1;
					want_bin <= 1'b0;
				end else if (max_r <= 5'd1) begin
					sig_m[0] <= 1'b1;
					scan_i <= 5'd0;
					st <= S_ABS0;
				end else begin
					scan_i <= 5'd0;
					st <= S_SIG;
				end
`endif
			end
			S_SIG: begin
				if (dec_bin) begin
					sig_m[scan4] <= 1'b1;
					st <= S_LAST;
				end else if (scan_i >= (max_r - 5'd2)) begin
					sig_m[max_r[3:0] - 4'd1] <= 1'b1;
					scan_i <= max_r - 5'd1;
					st <= S_ABS0;
				end else
					scan_i <= scan_i + 5'd1;
			end
			S_LAST: begin
				if (dec_bin) begin
					st <= S_ABS0;
				end else if (scan_i >= (max_r - 5'd2)) begin
					sig_m[max_r[3:0] - 4'd1] <= 1'b1;
					scan_i <= max_r - 5'd1;
					st <= S_ABS0;
				end else begin
					scan_i <= scan_i + 5'd1;
					st <= S_SIG;
				end
			end
			S_ABS0: begin
				if (!dec_bin) begin
					node_ctx <= trans0(node_ctx);
					abs_full <= 16'd1;
					st <= S_SIGN;
				end else begin
					node_ctx <= trans1(node_ctx);
					abs_acc <= 5'd2;
					st <= S_ABSGT;
				end
			end
			S_ABSGT: begin
				if (!dec_bin) begin
					abs_full <= {11'd0, abs_acc};
					st <= S_SIGN;
				end else if (abs_acc >= 5'd14) begin
					ueg_j <= 5'd0;
					st <= S_UEG1;
				end else
					abs_acc <= abs_acc + 5'd1;
			end
			S_UEG1: begin
				if (dec_bin && (ueg_j < 5'd23))
					ueg_j <= ueg_j + 5'd1;
				else if (ueg_j == 5'd0) begin
					abs_full <= 16'd15;
					st <= S_SIGN;
				end else begin
					abs_full <= 16'd1;
					ueg_left <= ueg_j;
					st <= S_UEG2;
				end
			end
			S_UEG2: begin
				if (ueg_left <= 5'd1) begin
					abs_full <= ({abs_full[14:0], 1'b0} + {15'd0, dec_bin}) + 16'd14;
					st <= S_SIGN;
				end else begin
					abs_full <= {abs_full[14:0], 1'b0} + {15'd0, dec_bin};
					ueg_left <= ueg_left - 5'd1;
				end
			end
			S_SIGN: begin
				if (dec_bin)
					coeff[scan4] <= -$signed(abs_full);
				else
					coeff[scan4] <= $signed(abs_full);
				total_coeff <= total_coeff + 5'd1;
				st <= S_NEXT;
				want_bin <= 1'b0;
			end
			default: begin
			end
			endcase
		end
	end
endmodule

// P-slice CABAC mb syntax: mb_skip_flag, mb_type, CBP, mb_qp_delta, mvd_l0.
// FAULT_FORCE_SKIP: treat mb_skip_flag as 1 after the bin is consumed.
module h264_cabac_mb_syntax (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire        nA_coded,   // neighbour A not skip (unavailable → 0)
	input  wire        nB_coded,

	output reg         dec_req,
	output reg  [8:0]  ctx_idx,
	output reg         bypass,
	output reg         terminate,
	input  wire        dec_valid,
	input  wire        dec_bin,
	input  wire        primed,
	input  wire        init_busy,

	output wire        busy,
	output reg         done,
	output reg         ok,
	output reg         mb_skip,
	output reg  [4:0]  mb_type,      // 0=P16x16 1=P16x8 2=P8x16 3=P8x8
	output reg  [3:0]  cbp_luma,
	output reg  [1:0]  cbp_chroma,
	output reg  signed [5:0] qp_delta,
	output reg  signed [15:0] mvd_x,
	output reg  signed [15:0] mvd_y
);
	localparam [3:0]
		S_IDLE  = 4'd0,
		S_SKIP  = 4'd1,
		S_T0    = 4'd2,
		S_T1    = 4'd3,
		S_T2    = 4'd4,
		S_CBP   = 4'd5,
		S_CH0   = 4'd6,
		S_CH1   = 4'd7,
		S_DQP0  = 4'd8,
		S_DQP1  = 4'd9,
		S_MV0   = 4'd10,
		S_MV1   = 4'd11,
		S_MVGT  = 4'd12,
		S_MVUEG = 4'd13,
		S_MVS   = 4'd14,
		S_NEXTV = 4'd15;

	reg [3:0]  st;
	reg        want_bin;
	reg        nA_r, nB_r;
	reg [1:0]  cbp_i;
	reg [4:0]  dqp_n;
	reg        mv_is_y;
	reg [4:0]  mv_abs;
	reg [4:0]  ueg_j;
	reg [4:0]  ueg_left;
	reg [15:0] mv_acc;

	wire hold_req = want_bin && primed && !init_busy && !reset;
	assign busy = (st != S_IDLE);

	wire [8:0] skip_ctx = 9'd11 + {8'd0, nA_r} + {8'd0, nB_r};
	wire [8:0] mv_base = mv_is_y ? 9'd47 : 9'd40;

	always @* begin
		dec_req = 1'b0;
		ctx_idx = 9'd0;
		bypass = 1'b0;
		terminate = 1'b0;
		if (hold_req && !dec_valid) begin
			dec_req = 1'b1;
			case (st)
			S_SKIP: ctx_idx = skip_ctx;
			S_T0:   ctx_idx = 9'd14;
			S_T1:   ctx_idx = 9'd15;
			S_T2:   ctx_idx = 9'd16;
			S_CBP:  ctx_idx = 9'd73 + {7'd0, cbp_i};
			S_CH0:  ctx_idx = 9'd77;
			S_CH1:  ctx_idx = 9'd78;
			S_DQP0: ctx_idx = 9'd60;
			S_DQP1: ctx_idx = (dqp_n <= 5'd1) ? 9'd61 : 9'd62;
			S_MV0:  ctx_idx = mv_base;
			S_MV1:  ctx_idx = mv_base + 9'd1;
			S_MVGT: ctx_idx = mv_base + 9'd2;
			S_MVUEG, S_MVS: bypass = 1'b1;
			default: dec_req = 1'b0;
			endcase
		end
	end

	function automatic signed [5:0] dqp_map;
		input [4:0] n;
		reg [5:0] mag;
		begin
			mag = {1'b0, n} + 6'd1;
			mag = mag >> 1;
			if (n[0])
				dqp_map = $signed(mag);
			else
				dqp_map = -$signed(mag);
		end
	endfunction

	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			st <= S_IDLE;
			ok <= 1'b0;
			want_bin <= 1'b0;
			mb_skip <= 1'b0;
			mb_type <= 5'd0;
			cbp_luma <= 4'd0;
			cbp_chroma <= 2'd0;
			qp_delta <= 6'sd0;
			mvd_x <= 16'sd0;
			mvd_y <= 16'sd0;
			nA_r <= 1'b0;
			nB_r <= 1'b0;
			cbp_i <= 2'd0;
			dqp_n <= 5'd0;
			mv_is_y <= 1'b0;
			mv_abs <= 5'd0;
			ueg_j <= 5'd0;
			ueg_left <= 5'd0;
			mv_acc <= 16'd0;
		end else if (start) begin
			st <= S_SKIP;
			ok <= 1'b0;
			want_bin <= 1'b1;
			mb_skip <= 1'b0;
			mb_type <= 5'd0;
			cbp_luma <= 4'd0;
			cbp_chroma <= 2'd0;
			qp_delta <= 6'sd0;
			mvd_x <= 16'sd0;
			mvd_y <= 16'sd0;
			nA_r <= nA_coded;
			nB_r <= nB_coded;
			cbp_i <= 2'd0;
			dqp_n <= 5'd0;
			mv_is_y <= 1'b0;
			mv_abs <= 5'd0;
			ueg_j <= 5'd0;
			ueg_left <= 5'd0;
			mv_acc <= 16'd0;
		end else if (st == S_NEXTV) begin
			if (!mv_is_y) begin
				mv_is_y <= 1'b1;
				st <= S_MV0;
				want_bin <= 1'b1;
			end else begin
				st <= S_IDLE;
				done <= 1'b1;
				ok <= 1'b1;
				want_bin <= 1'b0;
			end
		end else if (dec_valid && want_bin) begin
			case (st)
			S_SKIP: begin
`ifdef H264_CABAC_SYN_FAULT_FORCE_SKIP
				mb_skip <= 1'b1;
				st <= S_IDLE;
				done <= 1'b1;
				ok <= 1'b1;
				want_bin <= 1'b0;
`else
				if (dec_bin) begin
					mb_skip <= 1'b1;
					st <= S_IDLE;
					done <= 1'b1;
					ok <= 1'b1;
					want_bin <= 1'b0;
				end else
					st <= S_T0;
`endif
			end
			S_T0: begin
				if (!dec_bin) begin
					mb_type <= 5'd0;
					st <= S_CBP;
					cbp_i <= 2'd0;
				end else
					st <= S_T1;
			end
			S_T1: begin
				if (dec_bin) begin
					mb_type <= 5'd3;
					st <= S_CBP;
					cbp_i <= 2'd0;
				end else
					st <= S_T2;
			end
			S_T2: begin
				mb_type <= dec_bin ? 5'd2 : 5'd1;
				st <= S_CBP;
				cbp_i <= 2'd0;
			end
			S_CBP: begin
				cbp_luma[cbp_i] <= dec_bin;
				if (cbp_i == 2'd3)
					st <= S_CH0;
				else
					cbp_i <= cbp_i + 2'd1;
			end
			S_CH0: begin
				if (!dec_bin) begin
					cbp_chroma <= 2'd0;
					if (cbp_luma != 4'd0)
						st <= S_DQP0;
					else begin
						st <= S_MV0;
						mv_is_y <= 1'b0;
					end
				end else
					st <= S_CH1;
			end
			S_CH1: begin
				cbp_chroma <= dec_bin ? 2'd2 : 2'd1;
				st <= S_DQP0;
			end
			S_DQP0: begin
				if (!dec_bin) begin
					qp_delta <= 6'sd0;
					st <= S_MV0;
					mv_is_y <= 1'b0;
				end else begin
					dqp_n <= 5'd1;
					st <= S_DQP1;
				end
			end
			S_DQP1: begin
				if (!dec_bin || dqp_n >= 5'd31) begin
					qp_delta <= dqp_map(dqp_n);
					st <= S_MV0;
					mv_is_y <= 1'b0;
				end else
					dqp_n <= dqp_n + 5'd1;
			end
			S_MV0: begin
				if (!dec_bin) begin
					if (!mv_is_y) mvd_x <= 16'sd0;
					else mvd_y <= 16'sd0;
					st <= S_NEXTV;
					want_bin <= 1'b0;
				end else
					st <= S_MV1;
			end
			S_MV1: begin
				if (!dec_bin) begin
					mv_abs <= 5'd1;
					st <= S_MVS;
				end else begin
					mv_abs <= 5'd2;
					st <= S_MVGT;
				end
			end
			S_MVGT: begin
				if (!dec_bin) begin
					st <= S_MVS;
				end else if (mv_abs >= 5'd7) begin
					mv_abs <= mv_abs + 5'd1;
					st <= S_MVS;
				end else
					mv_abs <= mv_abs + 5'd1;
			end
			S_MVS: begin
				if (dec_bin) begin
					if (!mv_is_y) mvd_x <= -$signed({11'd0, mv_abs});
					else mvd_y <= -$signed({11'd0, mv_abs});
				end else begin
					if (!mv_is_y) mvd_x <= $signed({11'd0, mv_abs});
					else mvd_y <= $signed({11'd0, mv_abs});
				end
				st <= S_NEXTV;
				want_bin <= 1'b0;
			end
			default: begin
			end
			endcase
		end
	end
endmodule

`default_nettype wire
