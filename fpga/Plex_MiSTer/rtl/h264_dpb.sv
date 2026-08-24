// Phase 3 motion-compensation decoded picture buffer helpers.
// One short-term reference picture, one current reconstruction picture.
`default_nettype none

module h264_dpb_i420_addr #(
	parameter int FRAME_W = 624,
	parameter int FRAME_H = 480
)(
	input  wire [31:0] base,
	input  wire [1:0]  plane,
	input  wire [15:0] x,
	input  wire [15:0] y,
	output reg  [31:0] addr
);
	localparam int Y_BYTES = FRAME_W * FRAME_H;
	localparam int C_W     = FRAME_W / 2;
	localparam int C_H     = FRAME_H / 2;
	localparam int C_BYTES = C_W * C_H;

	always @* begin
		case (plane)
		2'd0: addr = base + (y * FRAME_W) + {16'd0, x};
		2'd1: addr = base + Y_BYTES + (y * C_W) + {16'd0, x};
		default: addr = base + Y_BYTES + C_BYTES + (y * C_W) + {16'd0, x};
		endcase
	end
endmodule

module h264_dpb_mb_write_addr #(
	parameter int FRAME_W = 624,
	parameter int FRAME_H = 480
)(
	input  wire [31:0] bank_base,
	input  wire [7:0]  mb_x,
	input  wire [7:0]  mb_y,
	input  wire [1:0]  plane,
	input  wire [7:0]  sample_idx,
	output wire [31:0] addr
);
	wire [15:0] y_x = {4'd0, mb_x, 4'd0} + {12'd0, sample_idx[3:0]};
	wire [15:0] y_y = {4'd0, mb_y, 4'd0} + {12'd0, sample_idx[7:4]};
	wire [15:0] c_x = {5'd0, mb_x, 3'd0} + {13'd0, sample_idx[2:0]};
	wire [15:0] c_y = {5'd0, mb_y, 3'd0} + {13'd0, sample_idx[5:3]};
	wire [15:0] px = (plane == 2'd0) ? y_x : c_x;
	wire [15:0] py = (plane == 2'd0) ? y_y : c_y;

	h264_dpb_i420_addr #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) u_addr (
		.base(bank_base), .plane(plane), .x(px), .y(py), .addr(addr)
	);
endmodule

module h264_dpb_one_ref #(
	parameter int FRAME_W = 624,
	parameter int FRAME_H = 480,
	parameter int BANK0_BASE = 0,
	parameter int BANK1_BASE = 898560 / 2
)(
	input  wire               clk,
	input  wire               reset,

	input  wire               idr_start,
	input  wire               frame_done,
	output reg                ref_ready,
	output reg  [31:0]        current_base,
	output reg  [31:0]        reference_base,

	input  wire               filtered_sample_valid,
	input  wire [7:0]         filtered_mb_x,
	input  wire [7:0]         filtered_mb_y,
	input  wire [1:0]         filtered_plane,
	input  wire [7:0]         filtered_sample_idx,
	input  wire [7:0]         filtered_sample,
	output wire               mem_we,
	output wire [31:0]        mem_waddr,
	output wire [7:0]         mem_wdata,

	input  wire               fetch_start,
	input  wire [7:0]         fetch_mb_x,
	input  wire [7:0]         fetch_mb_y,
	input  wire [2:0]         fetch_part_mode,
	input  wire [1:0]         fetch_part_idx,
	input  wire [4:0]         fetch_part_w,
	input  wire [4:0]         fetch_part_h,
	input  wire signed [15:0] fetch_mv_x_qpel,
	input  wire signed [15:0] fetch_mv_y_qpel,
	output reg                fetch_busy,
	output reg                fetch_done,
	output reg                fetch_error_no_ref,
	output reg  [1:0]         luma_frac_x,
	output reg  [1:0]         luma_frac_y,
	output reg  [2:0]         chroma_frac_x,
	output reg  [2:0]         chroma_frac_y,
	output reg  signed [15:0] luma_origin_x,
	output reg  signed [15:0] luma_origin_y,
	output reg  signed [15:0] chroma_origin_x,
	output reg  signed [15:0] chroma_origin_y,

	output wire               mem_rd,
	output wire [31:0]        mem_raddr,
	input  wire [7:0]         mem_rdata,
	input  wire               mem_rvalid,
	output reg                luma_window_valid,
	output reg  [8:0]         luma_window_idx,
	output reg  [7:0]         luma_window_sample,
	output reg                chroma_u_window_valid,
	output reg                chroma_v_window_valid,
	output reg  [6:0]         chroma_window_idx,
	output reg  [7:0]         chroma_window_sample
);
	localparam int C_W = FRAME_W / 2;
	localparam int C_H = FRAME_H / 2;
	localparam [2:0] PH_IDLE  = 3'd0;
	localparam [2:0] PH_LUMA  = 3'd1;
	localparam [2:0] PH_U     = 3'd2;
	localparam [2:0] PH_V     = 3'd3;
	localparam [2:0] PH_DRAIN = 3'd4;

	wire [31:0] write_addr;
	h264_dpb_mb_write_addr #(.FRAME_W(FRAME_W), .FRAME_H(FRAME_H)) u_write_addr (
		.bank_base(current_base),
		.mb_x(filtered_mb_x), .mb_y(filtered_mb_y),
		.plane(filtered_plane), .sample_idx(filtered_sample_idx),
		.addr(write_addr)
	);
	assign mem_we    = filtered_sample_valid;
	assign mem_waddr = write_addr;
	assign mem_wdata = filtered_sample;

	function automatic signed [15:0] part_x_off(input [2:0] mode, input [1:0] idx);
		begin
			case (mode)
			3'd2: part_x_off = (idx == 2'd1) ? 16'sd8 : 16'sd0; // P_8x16 right
			3'd3, 3'd4: part_x_off = idx[0] ? 16'sd8 : 16'sd0; // P_8x8/sub
			default: part_x_off = 16'sd0;
			endcase
		end
	endfunction

	function automatic signed [15:0] part_y_off(input [2:0] mode, input [1:0] idx);
		begin
			case (mode)
			3'd1: part_y_off = (idx == 2'd1) ? 16'sd8 : 16'sd0; // P_16x8 bottom
			3'd3, 3'd4: part_y_off = idx[1] ? 16'sd8 : 16'sd0; // P_8x8/sub
			default: part_y_off = 16'sd0;
			endcase
		end
	endfunction

	function automatic [15:0] clamp_coord(input signed [15:0] v, input [15:0] limit);
		begin
			if (v < 0) clamp_coord = 16'd0;
			else if ($signed({1'b0, v}) >= $signed({1'b0, limit})) clamp_coord = limit - 16'd1;
			else clamp_coord = v[15:0];
		end
	endfunction

	function automatic [31:0] i420_addr(
		input [31:0] base,
		input [1:0]  plane,
		input [15:0] x,
		input [15:0] y
	);
		begin
			case (plane)
			2'd0: i420_addr = base + (y * FRAME_W) + {16'd0, x};
			2'd1: i420_addr = base + (FRAME_W * FRAME_H) + (y * C_W) + {16'd0, x};
			default: i420_addr = base + (FRAME_W * FRAME_H) + (C_W * C_H) + (y * C_W) + {16'd0, x};
			endcase
		end
	endfunction

	reg [2:0] phase;
	reg [8:0] issue_idx;
	wire [8:0] issue_mod9 = issue_idx % 9'd9;
	wire [8:0] issue_div9 = issue_idx / 9'd9;
	wire signed [15:0] issue_mod9_s = $signed({7'd0, issue_mod9});
	wire signed [15:0] issue_div9_s = $signed({7'd0, issue_div9});
	reg [1:0] pending_plane;
	reg [8:0] pending_idx;
	reg       pending_valid;
	reg signed [15:0] lx;
	reg signed [15:0] ly;
	reg signed [15:0] cx;
	reg signed [15:0] cy;
	reg [1:0] lat_part_w_lo;
	reg [1:0] lat_part_h_lo;
	reg [7:0] lat_fmb_x, lat_fmb_y;
	reg [2:0] lat_part_mode;
	reg [1:0] lat_part_idx;
	reg signed [15:0] lat_mv_x, lat_mv_y;
	reg int_copy;
	reg issue_hold; // first LUMA/U/V idx stays 1 extra beat so tap0 is captured
	reg signed [15:0] sx;
	reg signed [15:0] sy;
	reg [15:0] clamped_x;
	reg [15:0] clamped_y;
	wire [1:0] issue_plane = (phase == PH_LUMA) ? 2'd0 : ((phase == PH_U) ? 2'd1 : 2'd2);
	// Combo rd/addr: stream_path flops rdata (1-cycle). A registered
	// mem_rd/raddr made a 2-cycle path and tagged rdata[N] as idx N+1
	// (tap 0 never written → F1 Y(0,0)=0 after 21x21 remap).
	assign mem_rd = (phase == PH_LUMA) || (phase == PH_U) || (phase == PH_V);
	assign mem_raddr = i420_addr(reference_base, issue_plane, clamped_x, clamped_y);

	// Address THIS mb every issue beat. Do not reuse a stale origin (mb0).
	always @* begin
		lx = $signed({4'd0, lat_fmb_x, 4'd0}) +
		     part_x_off(lat_part_mode, lat_part_idx) + (lat_mv_x >>> 2);
		ly = $signed({4'd0, lat_fmb_y, 4'd0}) +
		     part_y_off(lat_part_mode, lat_part_idx) + (lat_mv_y >>> 2);
		cx = $signed({5'd0, lat_fmb_x, 3'd0}) +
		     (part_x_off(lat_part_mode, lat_part_idx) >>> 1) + (lat_mv_x >>> 3);
		cy = $signed({5'd0, lat_fmb_y, 3'd0}) +
		     (part_y_off(lat_part_mode, lat_part_idx) >>> 1) + (lat_mv_y >>> 3);
		sx = 16'sd0;
		sy = 16'sd0;
		clamped_x = 16'd0;
		clamped_y = 16'd0;
		case (phase)
		PH_LUMA: begin
			if (int_copy) begin
				// 16x16 colocated window packed at [0:255] = THIS mb.
				sx = $signed({4'd0, lat_fmb_x, 4'd0}) + $signed({12'd0, issue_idx[3:0]});
				sy = $signed({4'd0, lat_fmb_y, 4'd0}) + $signed({12'd0, issue_idx[7:4]});
			end else begin
				sx = lx + $signed({7'd0, (issue_idx % 9'd21)}) - 16'sd2;
				sy = ly + $signed({7'd0, (issue_idx / 9'd21)}) - 16'sd2;
			end
			clamped_x = clamp_coord(sx, FRAME_W[15:0]);
			clamped_y = clamp_coord(sy, FRAME_H[15:0]);
		end
		default: begin
			if (int_copy) begin
				sx = $signed({5'd0, lat_fmb_x, 3'd0}) + $signed({13'd0, issue_idx[2:0]});
				sy = $signed({5'd0, lat_fmb_y, 3'd0}) + $signed({13'd0, issue_idx[5:3]});
			end else begin
				sx = cx + issue_mod9_s;
				sy = cy + issue_div9_s;
			end
			clamped_x = clamp_coord(sx, C_W[15:0]);
			clamped_y = clamp_coord(sy, C_H[15:0]);
		end
		endcase
	end

	always @(posedge clk) begin
		if (reset) begin
			current_base        <= BANK0_BASE[31:0];
			reference_base      <= BANK1_BASE[31:0];
			ref_ready           <= 1'b0;
			fetch_busy          <= 1'b0;
			fetch_done          <= 1'b0;
			fetch_error_no_ref  <= 1'b0;
			phase               <= PH_IDLE;
			issue_idx           <= 9'd0;
			pending_valid       <= 1'b0;
			pending_plane       <= 2'd0;
			pending_idx         <= 9'd0;
			luma_frac_x         <= 2'd0;
			luma_frac_y         <= 2'd0;
			chroma_frac_x       <= 3'd0;
			chroma_frac_y       <= 3'd0;
			luma_origin_x       <= 16'sd0;
			luma_origin_y       <= 16'sd0;
			chroma_origin_x     <= 16'sd0;
			chroma_origin_y     <= 16'sd0;
			lat_part_w_lo       <= 2'd0;
			lat_part_h_lo       <= 2'd0;
			lat_fmb_x           <= 8'd0;
			lat_fmb_y           <= 8'd0;
			lat_part_mode       <= 3'd0;
			lat_part_idx        <= 2'd0;
			lat_mv_x            <= 16'sd0;
			lat_mv_y            <= 16'sd0;
			int_copy            <= 1'b0;
			issue_hold          <= 1'b0;
		end else begin
			if (idr_start) begin
				ref_ready <= 1'b0;
			end
			if (frame_done) begin
				reference_base <= current_base;
				current_base   <= (current_base == BANK0_BASE[31:0]) ? BANK1_BASE[31:0] : BANK0_BASE[31:0];
				ref_ready      <= 1'b1;
			end

			if (phase == PH_IDLE) begin
				pending_valid <= 1'b0;
				fetch_busy    <= 1'b0;
				if (fetch_start) begin
					// One-pic DPB: always fetch THIS mb. ref_ready is
					// observational; do not no-op and keep mb0's window.
					fetch_done         <= 1'b0;
					fetch_error_no_ref <= !ref_ready;
					fetch_busy         <= 1'b1;
					phase              <= PH_LUMA;
					issue_idx          <= 9'd0;
					lat_fmb_x          <= fetch_mb_x;
					lat_fmb_y          <= fetch_mb_y;
					lat_part_mode      <= fetch_part_mode;
					lat_part_idx       <= fetch_part_idx;
					lat_mv_x           <= fetch_mv_x_qpel;
					lat_mv_y           <= fetch_mv_y_qpel;
					int_copy           <= (fetch_part_mode == 3'd0) &&
					                      (fetch_mv_x_qpel == 16'sd0) &&
					                      (fetch_mv_y_qpel == 16'sd0);
					issue_hold         <= 1'b1;
					luma_frac_x        <= fetch_mv_x_qpel[1:0];
					luma_frac_y        <= fetch_mv_y_qpel[1:0];
					chroma_frac_x      <= fetch_mv_x_qpel[2:0];
					chroma_frac_y      <= fetch_mv_y_qpel[2:0];
					luma_origin_x      <= $signed({4'd0, fetch_mb_x, 4'd0}) +
					                      part_x_off(fetch_part_mode, fetch_part_idx) +
					                      (fetch_mv_x_qpel >>> 2);
					luma_origin_y      <= $signed({4'd0, fetch_mb_y, 4'd0}) +
					                      part_y_off(fetch_part_mode, fetch_part_idx) +
					                      (fetch_mv_y_qpel >>> 2);
					chroma_origin_x    <= $signed({5'd0, fetch_mb_x, 3'd0}) +
					                      (part_x_off(fetch_part_mode, fetch_part_idx) >>> 1) +
					                      (fetch_mv_x_qpel >>> 3);
					chroma_origin_y    <= $signed({5'd0, fetch_mb_y, 3'd0}) +
					                      (part_y_off(fetch_part_mode, fetch_part_idx) >>> 1) +
					                      (fetch_mv_y_qpel >>> 3);
					lat_part_w_lo      <= fetch_part_w[1:0];
					lat_part_h_lo      <= fetch_part_h[1:0];
				end
			end else if (phase == PH_DRAIN) begin
				// Last V (or last 9x9) tap captures this beat. fetch_done one
				// beat later so pel_copy 64+64 sees mc_v[63] (F1 idx 97127
				// was V(7,7)=MB0 last tap rtl=0). Same idea as luma: last Y
				// lands during PH_U/PH_V before done.
				pending_valid <= 1'b0;
				if (!pending_valid) begin
					phase      <= PH_IDLE;
					fetch_busy <= 1'b0;
					fetch_done <= 1'b1;
				end
			end else begin
				fetch_error_no_ref <= 1'b0;
				pending_valid <= 1'b1;
				pending_plane <= issue_plane;
				pending_idx <= issue_idx;
				// synopsys translate_off
				if ((phase == PH_LUMA) && (issue_idx == 9'd44) && (lat_fmb_x <= 8'd2))
					$display("ISSUE44 mbx=%0d lx=%0d sx=%0d cx=%0d addr=%0d",
					         lat_fmb_x, lx, sx, clamped_x,
					         i420_addr(reference_base, 2'd0, clamped_x, clamped_y));
				// synopsys translate_on
				if (issue_hold) begin
					// Repeat idx 0: combo rd + flopped rdata drops the first beat.
					issue_hold <= 1'b0;
				end else if (phase == PH_LUMA) begin
					if (issue_idx == (int_copy ? 9'd255 : 9'd440)) begin
						phase       <= PH_U;
						issue_idx   <= 9'd0;
						issue_hold  <= 1'b1;
					end else begin
						issue_idx <= issue_idx + 9'd1;
					end
				end else if (phase == PH_U) begin
					if (issue_idx == (int_copy ? 9'd63 : 9'd80)) begin
						phase       <= PH_V;
						issue_idx   <= 9'd0;
						issue_hold  <= 1'b1;
					end else begin
						issue_idx <= issue_idx + 9'd1;
					end
				end else begin
					if (issue_idx == (int_copy ? 9'd63 : 9'd80)) begin
						phase      <= PH_DRAIN;
					end else begin
						issue_idx <= issue_idx + 9'd1;
					end
				end
			end
			if (lat_part_w_lo != 2'd0 || lat_part_h_lo != 2'd0) begin
				// Keep part_w/part_h observed for lint and future narrower fetch windows.
			end
		end
	end

	// Separate always: capture uses committed pending_* from the prior
	// issue beat. Same-block NBA+issue was pairing rdata[N] with idx N+1
	// (one tap left → F1 MB1 Y=160 instead of gold 80).
	always @(posedge clk) begin
		luma_window_valid     <= 1'b0;
		chroma_u_window_valid <= 1'b0;
		chroma_v_window_valid <= 1'b0;
		if (reset) begin
			luma_window_idx      <= 9'd0;
			luma_window_sample   <= 8'd0;
			chroma_window_idx    <= 7'd0;
			chroma_window_sample <= 8'd0;
		end else if (mem_rvalid && pending_valid) begin
			case (pending_plane)
			2'd0: begin
				luma_window_valid  <= 1'b1;
				luma_window_idx    <= pending_idx;
				luma_window_sample <= mem_rdata;
				// synopsys translate_off
				if ((pending_idx == 9'd44) && (pending_idx <= 9'd44))
					$display("CAP44 idx=%0d rdata=%0d", pending_idx, mem_rdata);
				// synopsys translate_on
			end
			2'd1: begin
				chroma_u_window_valid <= 1'b1;
				chroma_window_idx     <= pending_idx[6:0];
				chroma_window_sample  <= mem_rdata;
			end
			default: begin
				chroma_v_window_valid <= 1'b1;
				chroma_window_idx     <= pending_idx[6:0];
				chroma_window_sample  <= mem_rdata;
			end
			endcase
		end
	end
endmodule

module h264_luma_qpel_block_16x16 (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [7:0]  ref_win [0:440],
	input  wire [1:0]  frac_x,
	input  wire [1:0]  frac_y,
	output reg  [7:0]  pred [0:255],
	output reg         done
);
	// Combo qpel_at(ox,oy) / pix(row,col) DELETED.
	// One scalar window address per cycle; one 6-tap FIR reused for H, V, and j.
	localparam [1:0] KIND_PIX = 2'd0;
	localparam [1:0] KIND_HH  = 2'd1;
	localparam [1:0] KIND_HV  = 2'd2;
	localparam [1:0] KIND_HC  = 2'd3;

	localparam [3:0] ST_IDLE  = 4'd0;
	localparam [3:0] ST_SETUP = 4'd1;
	localparam [3:0] ST_WAIT  = 4'd2;
	localparam [3:0] ST_ACC   = 4'd3;
	localparam [3:0] ST_SAVEH = 4'd4;
	localparam [3:0] ST_HCV   = 4'd5;
	localparam [3:0] ST_ROUND = 4'd6;
	localparam [3:0] ST_SHIFT = 4'd7;
	localparam [3:0] ST_CLIP  = 4'd8;
	localparam [3:0] ST_STORE = 4'd9;
	localparam [3:0] ST_AVG   = 4'd10;
	localparam [3:0] ST_WRITE = 4'd11;
	localparam [3:0] ST_NEXT  = 4'd12;

	reg  [3:0]         st;
	reg  [8:0]         pix_i;
	reg                src_sel;
	reg  [1:0]         kind;
	reg                job_roff;
	reg                job_coff;
	reg  [2:0]         tap_i;
	reg  [2:0]         pass_i;
	reg  signed [31:0] acc;
	reg  signed [15:0] hraw0, hraw1, hraw2, hraw3, hraw4, hraw5;
	reg  signed [31:0] round_lat;
	reg  signed [31:0] shift_lat;
	reg  [7:0]         pel_a, pel_b, pel_x;
	reg  [8:0]         avg_sum;
	reg                wr_is_avg;
	reg  [7:0]         rdata;

	wire [3:0] ox = pix_i[3:0];
	wire [3:0] oy = pix_i[7:4];

	wire two_src = !(((frac_y == 2'b00) && (frac_x == 2'b00)) ||
	                 ((frac_y == 2'b00) && (frac_x == 2'b10)) ||
	                 ((frac_y == 2'b10) && (frac_x == 2'b00)) ||
	                 ((frac_y == 2'b10) && (frac_x == 2'b10)));

	reg [1:0] dec_kind;
	reg       dec_roff;
	reg       dec_coff;
	always @* begin
		dec_kind = KIND_PIX;
		dec_roff = 1'b0;
		dec_coff = 1'b0;
		case ({frac_y, frac_x, src_sel})
		5'b00000: begin dec_kind = KIND_PIX; end
		5'b00010: begin dec_kind = KIND_PIX; end
		5'b00011: begin dec_kind = KIND_HH;  end
		5'b00100: begin dec_kind = KIND_HH;  end
		5'b00110: begin dec_kind = KIND_HH;  end
		5'b00111: begin dec_kind = KIND_PIX; dec_coff = 1'b1; end
		5'b01000: begin dec_kind = KIND_PIX; end
		5'b01001: begin dec_kind = KIND_HV;  end
		5'b01010: begin dec_kind = KIND_HH;  end
		5'b01011: begin dec_kind = KIND_HV;  end
		5'b01100: begin dec_kind = KIND_HH;  end
		5'b01101: begin dec_kind = KIND_HC;  end
		5'b01110: begin dec_kind = KIND_HH;  end
		5'b01111: begin dec_kind = KIND_HV;  dec_coff = 1'b1; end
		5'b10000: begin dec_kind = KIND_HV;  end
		5'b10010: begin dec_kind = KIND_HV;  end
		5'b10011: begin dec_kind = KIND_HC;  end
		5'b10100: begin dec_kind = KIND_HC;  end
		5'b10110: begin dec_kind = KIND_HC;  end
		5'b10111: begin dec_kind = KIND_HV;  dec_coff = 1'b1; end
		5'b11000: begin dec_kind = KIND_HV;  end
		5'b11001: begin dec_kind = KIND_PIX; dec_roff = 1'b1; end
		5'b11010: begin dec_kind = KIND_HH;  dec_roff = 1'b1; end
		5'b11011: begin dec_kind = KIND_HV;  end
		5'b11100: begin dec_kind = KIND_HC;  end
		5'b11101: begin dec_kind = KIND_HH;  dec_roff = 1'b1; end
		5'b11110: begin dec_kind = KIND_HH;  dec_roff = 1'b1; end
		5'b11111: begin dec_kind = KIND_HV;  dec_coff = 1'b1; end
		default:  begin dec_kind = KIND_PIX; end
		endcase
	end

	// Scalar tap address. Offsets are constants per tap_i — not a 2D variable slice.
	reg [4:0] rr;
	reg [4:0] cc;
	always @* begin
		rr = {1'b0, oy} + 5'd2 + {4'b0, job_roff};
		cc = {1'b0, ox} + 5'd2 + {4'b0, job_coff};
		case (kind)
		KIND_PIX: begin
		end
		KIND_HH: begin
			case (tap_i)
			3'd0: cc = cc - 5'd2;
			3'd1: cc = cc - 5'd1;
			3'd2: cc = cc;
			3'd3: cc = cc + 5'd1;
			3'd4: cc = cc + 5'd2;
			default: cc = cc + 5'd3;
			endcase
		end
		KIND_HV: begin
			case (tap_i)
			3'd0: rr = rr - 5'd2;
			3'd1: rr = rr - 5'd1;
			3'd2: rr = rr;
			3'd3: rr = rr + 5'd1;
			3'd4: rr = rr + 5'd2;
			default: rr = rr + 5'd3;
			endcase
		end
		default: begin
			case (pass_i)
			3'd0: rr = {1'b0, oy};
			3'd1: rr = {1'b0, oy} + 5'd1;
			3'd2: rr = {1'b0, oy} + 5'd2;
			3'd3: rr = {1'b0, oy} + 5'd3;
			3'd4: rr = {1'b0, oy} + 5'd4;
			default: rr = {1'b0, oy} + 5'd5;
			endcase
			cc = {1'b0, ox} + 5'd2;
			case (tap_i)
			3'd0: cc = cc - 5'd2;
			3'd1: cc = cc - 5'd1;
			3'd2: cc = cc;
			3'd3: cc = cc + 5'd1;
			3'd4: cc = cc + 5'd2;
			default: cc = cc + 5'd3;
			endcase
		end
		endcase
	end

	wire [8:0] raddr_w = {rr, 4'b0} + {2'b0, rr, 2'b0} + {4'b0, rr} + {4'b0, cc};

	// Registered single-sample mux (not 36 parallel window reads).
	always @(posedge clk)
		rdata <= ref_win[raddr_w];

	wire [10:0] t5  = {rdata, 2'b00} + {3'b0, rdata};
	wire [12:0] t20 = {rdata, 4'b0000} + {2'b0, rdata, 2'b00};

	reg signed [31:0] acc_nxt;
	always @* begin
		case (tap_i)
		3'd0, 3'd5: acc_nxt = acc + $signed({24'd0, rdata});
		3'd1, 3'd4: acc_nxt = acc - $signed({21'd0, t5});
		default:    acc_nxt = acc + $signed({19'd0, t20});
		endcase
	end

	reg signed [15:0] hsel;
	always @* begin
		case (tap_i)
		3'd0: hsel = hraw0;
		3'd1: hsel = hraw1;
		3'd2: hsel = hraw2;
		3'd3: hsel = hraw3;
		3'd4: hsel = hraw4;
		default: hsel = hraw5;
		endcase
	end
	wire signed [31:0] hse = {{16{hsel[15]}}, hsel};
	wire signed [31:0] h5  = (hse <<< 2) + hse;
	wire signed [31:0] h20 = (hse <<< 4) + (hse <<< 2);
	reg signed [31:0] hacc_nxt;
	always @* begin
		case (tap_i)
		3'd0, 3'd5: hacc_nxt = acc + hse;
		3'd1, 3'd4: hacc_nxt = acc - h5;
		default:    hacc_nxt = acc + h20;
		endcase
	end

	wire [7:0] clip_low = shift_lat[7:0];
	reg  [7:0] clip_out;
	always @* begin
		if (shift_lat[31])
			clip_out = 8'd0;
		else if (shift_lat > 32'sd255)
			clip_out = 8'd255;
		else
			clip_out = clip_low;
	end

	wire [7:0] wr_sample = wr_is_avg ? avg_sum[8:1] : pel_a;
	wire       wr_en     = (st == ST_WRITE);

	genvar gi;
	generate
		for (gi = 0; gi < 256; gi = gi + 1) begin : g_pred
			always @(posedge clk) begin
				if (wr_en && (pix_i == gi[8:0]))
					pred[gi] <= wr_sample;
			end
		end
	endgenerate

	always @(posedge clk) begin
		done  <= 1'b0;
		if (reset) begin
			st        <= ST_IDLE;
			pix_i     <= 9'd0;
			src_sel   <= 1'b0;
			tap_i     <= 3'd0;
			pass_i    <= 3'd0;
			acc       <= 32'sd0;
			wr_is_avg <= 1'b0;
		end else if (start) begin
			st        <= ST_SETUP;
			pix_i     <= 9'd0;
			src_sel   <= 1'b0;
			tap_i     <= 3'd0;
			pass_i    <= 3'd0;
			acc       <= 32'sd0;
			wr_is_avg <= 1'b0;
		end else begin
			case (st)
			ST_SETUP: begin
				kind     <= dec_kind;
				job_roff <= dec_roff;
				job_coff <= dec_coff;
				tap_i    <= 3'd0;
				pass_i   <= 3'd0;
				acc      <= 32'sd0;
				st       <= ST_WAIT;
			end
			ST_WAIT: begin
				st <= ST_ACC;
			end
			ST_ACC: begin
				if (kind == KIND_PIX) begin
					pel_x <= rdata;
					st    <= ST_STORE;
				end else begin
					acc <= acc_nxt;
					if (tap_i != 3'd5) begin
						tap_i <= tap_i + 3'd1;
						st    <= ST_WAIT;
					end else if (kind == KIND_HC) begin
						st <= ST_SAVEH;
					end else begin
						st <= ST_ROUND;
					end
				end
			end
			ST_SAVEH: begin
				case (pass_i)
				3'd0: hraw0 <= acc[15:0];
				3'd1: hraw1 <= acc[15:0];
				3'd2: hraw2 <= acc[15:0];
				3'd3: hraw3 <= acc[15:0];
				3'd4: hraw4 <= acc[15:0];
				default: hraw5 <= acc[15:0];
				endcase
				if (pass_i != 3'd5) begin
					pass_i <= pass_i + 3'd1;
					tap_i  <= 3'd0;
					acc    <= 32'sd0;
					st     <= ST_WAIT;
				end else begin
					tap_i <= 3'd0;
					acc   <= 32'sd0;
					st    <= ST_HCV;
				end
			end
			ST_HCV: begin
				acc <= hacc_nxt;
				if (tap_i != 3'd5) begin
					tap_i <= tap_i + 3'd1;
				end else begin
					st <= ST_ROUND;
				end
			end
			ST_ROUND: begin
				if (kind == KIND_HC)
					round_lat <= acc + 32'sd512;
				else
					round_lat <= acc + 32'sd16;
				st <= ST_SHIFT;
			end
			ST_SHIFT: begin
				if (kind == KIND_HC)
					shift_lat <= round_lat >>> 10;
				else
					shift_lat <= round_lat >>> 5;
				st <= ST_CLIP;
			end
			ST_CLIP: begin
				pel_x <= clip_out;
				st    <= ST_STORE;
			end
			ST_STORE: begin
				if (src_sel == 1'b0) begin
					pel_a <= pel_x;
					if (!two_src) begin
						wr_is_avg <= 1'b0;
						st        <= ST_WRITE;
					end else begin
						src_sel <= 1'b1;
						st      <= ST_SETUP;
					end
				end else begin
					pel_b <= pel_x;
					st    <= ST_AVG;
				end
			end
			ST_AVG: begin
				avg_sum   <= {1'b0, pel_a} + {1'b0, pel_b} + 9'd1;
				wr_is_avg <= 1'b1;
				st        <= ST_WRITE;
			end
			ST_WRITE: begin
				st <= ST_NEXT;
			end
			ST_NEXT: begin
				src_sel   <= 1'b0;
				wr_is_avg <= 1'b0;
				if (pix_i == 9'd255) begin
					st   <= ST_IDLE;
					done <= 1'b1;
				end else begin
					pix_i <= pix_i + 9'd1;
					st    <= ST_SETUP;
				end
			end
			default: st <= ST_IDLE;
			endcase
		end
	end
endmodule

module h264_chroma_epel_block_8x8 (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [7:0]  ref_win [0:80],
	input  wire [2:0]  frac_x,
	input  wire [2:0]  frac_y,
	output reg  [7:0]  pred [0:63],
	output reg         done
);
	function automatic integer chroma_pix(input integer idx);
		reg [7:0] sample;
		begin
			sample = ref_win[idx];
			chroma_pix = {24'd0, sample};
		end
	endfunction

	function automatic [7:0] interp(input integer x, input integer y);
		integer p00;
		integer p10;
		integer p01;
		integer p11;
		integer fx;
		integer fy;
		integer sum;
		begin
			fx = {29'd0, frac_x};
			fy = {29'd0, frac_y};
			p00 = chroma_pix(y * 9 + x);
			p10 = chroma_pix(y * 9 + x + 1);
			p01 = chroma_pix((y + 1) * 9 + x);
			p11 = chroma_pix((y + 1) * 9 + x + 1);
			sum = (8 - fx) * (8 - fy) * p00 +
			      fx * (8 - fy) * p10 +
			      (8 - fx) * fy * p01 +
			      fx * fy * p11 + 32;
			interp = sum[13:6];
		end
	endfunction

	// One dest chroma pixel per cycle. One 8x8 shared for U then V.
	reg        busy;
	reg  [6:0] pix_i;
	wire [2:0] ox = pix_i[2:0];
	wire [2:0] oy = pix_i[5:3];
	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			busy  <= 1'b0;
			pix_i <= 7'd0;
		end else if (start) begin
			busy  <= 1'b1;
			pix_i <= 7'd0;
		end else if (busy) begin
			pred[pix_i] <= interp(ox, oy);
			if (pix_i == 7'd63) begin
				busy <= 1'b0;
				done <= 1'b1;
			end else
				pix_i <= pix_i + 7'd1;
		end
	end
endmodule

module h264_inter_mc_16x16 (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [7:0] luma_ref_win [0:440],
	input  wire [7:0] chroma_u_ref_win [0:80],
	input  wire [7:0] chroma_v_ref_win [0:80],
	input  wire [1:0] luma_frac_x,
	input  wire [1:0] luma_frac_y,
	input  wire [2:0] chroma_frac_x,
	input  wire [2:0] chroma_frac_y,
	output wire [7:0] pred_y [0:255],
	output reg  [7:0] pred_u [0:63],
	output reg  [7:0] pred_v [0:63],
	output reg        done
);
	wire luma_done;
	wire chr_done;
	reg  chr_start;
	reg  chr_is_v;
	reg  [7:0] chr_win [0:80];
	wire [7:0] chr_pred [0:63];
	integer ci;
	always @* begin
		for (ci = 0; ci < 81; ci = ci + 1)
			chr_win[ci] = chr_is_v ? chroma_v_ref_win[ci] : chroma_u_ref_win[ci];
	end
	h264_luma_qpel_block_16x16 u_luma (
		.clk(clk), .reset(reset), .start(start),
		.ref_win(luma_ref_win), .frac_x(luma_frac_x), .frac_y(luma_frac_y),
		.pred(pred_y), .done(luma_done)
	);
	h264_chroma_epel_block_8x8 u_chroma (
		.clk(clk), .reset(reset), .start(chr_start),
		.ref_win(chr_win), .frac_x(chroma_frac_x), .frac_y(chroma_frac_y),
		.pred(chr_pred), .done(chr_done)
	);
	always @(posedge clk) begin
		done      <= 1'b0;
		chr_start <= 1'b0;
		if (reset) begin
			chr_is_v <= 1'b0;
		end else if (start) begin
			chr_is_v <= 1'b0;
		end else if (luma_done) begin
			chr_is_v  <= 1'b0;
			chr_start <= 1'b1;
		end else if (chr_done && !chr_is_v) begin
			for (ci = 0; ci < 64; ci = ci + 1)
				pred_u[ci] <= chr_pred[ci];
			chr_is_v  <= 1'b1;
			chr_start <= 1'b1;
		end else if (chr_done && chr_is_v) begin
			for (ci = 0; ci < 64; ci = ci + 1)
				pred_v[ci] <= chr_pred[ci];
			done <= 1'b1;
		end
	end
endmodule

module h264_inter_mc_part (
	input  wire [7:0] luma_ref_win [0:440],
	input  wire [7:0] chroma_u_ref_win [0:80],
	input  wire [7:0] chroma_v_ref_win [0:80],
	input  wire [1:0] luma_frac_x,
	input  wire [1:0] luma_frac_y,
	input  wire [2:0] chroma_frac_x,
	input  wire [2:0] chroma_frac_y,
	input  wire [4:0] part_w,
	input  wire [4:0] part_h,
	output wire [7:0] pred_y [0:255],
	output wire       pred_y_valid [0:255],
	output wire [7:0] pred_u [0:63],
	output wire       pred_u_valid [0:63],
	output wire [7:0] pred_v [0:63],
	output wire       pred_v_valid [0:63]
);
	wire [7:0] full_y [0:255];
	wire [7:0] full_u [0:63];
	wire [7:0] full_v [0:63];
	wire [4:0] chroma_w = {1'b0, part_w[4:1]};
	wire [4:0] chroma_h = {1'b0, part_h[4:1]};

	// Unused by Phase-1 walker. Tie start low so this copy stays dark.
	h264_inter_mc_16x16 u_full (
		.clk(1'b0), .reset(1'b1), .start(1'b0),
		.luma_ref_win(luma_ref_win),
		.chroma_u_ref_win(chroma_u_ref_win),
		.chroma_v_ref_win(chroma_v_ref_win),
		.luma_frac_x(luma_frac_x), .luma_frac_y(luma_frac_y),
		.chroma_frac_x(chroma_frac_x), .chroma_frac_y(chroma_frac_y),
		.pred_y(full_y), .pred_u(full_u), .pred_v(full_v),
		.done()
	);

	genvar py_i;
	generate
		for (py_i = 0; py_i < 256; py_i = py_i + 1) begin : gen_part_y
			localparam int LX = py_i % 16;
			localparam int LY = py_i / 16;
			wire in_part = (LX[4:0] < part_w) && (LY[4:0] < part_h);
			assign pred_y_valid[py_i] = in_part;
			assign pred_y[py_i] = in_part ? full_y[py_i] : 8'd0;
		end
		for (py_i = 0; py_i < 64; py_i = py_i + 1) begin : gen_part_c
			localparam int CX = py_i % 8;
			localparam int CY = py_i / 8;
			wire in_part = (CX[4:0] < chroma_w) && (CY[4:0] < chroma_h);
			assign pred_u_valid[py_i] = in_part;
			assign pred_v_valid[py_i] = in_part;
			assign pred_u[py_i] = in_part ? full_u[py_i] : 8'd0;
			assign pred_v[py_i] = in_part ? full_v[py_i] : 8'd0;
		end
	endgenerate
endmodule

`default_nettype wire
