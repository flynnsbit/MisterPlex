// HPS-DDR-backed YUV420p frame store.
//
// The ARM writes planar YUV420 frames into two HPS DDR banks using the layout
// from host/libmisterplex/ddr_frame_layout.hpp. The FPGA reads Y, U, and V
// source lines directly from HPS DDR into bank-tagged M10K line buffers.

module ddr_frame_store #(
	parameter int FRAME_W = 640,
	parameter int FRAME_H = 480,
	parameter int FRAME_STRIDE = FRAME_W,
	parameter int LINE_COUNT = 8,
	parameter [31:0] PHYS_BASE = 32'h3000_0000,
	parameter int HPS_BANK_STRIDE_BYTES = 524288,
	parameter [31:0] DOORBELL_PHYS = PHYS_BASE + (2 * HPS_BANK_STRIDE_BYTES) - 32'h1000,
	parameter [31:0] MAILBOX_PHYS  = 32'h3007_F100,
	parameter [31:0] INPUT_MAILBOX_PHYS = 32'h3007_F108,
	parameter [31:0] SDRAM_MAILBOX_PHYS = 32'h3007_F110,
	parameter [31:0] FRAME_MAILBOX_PHYS = 32'h3007_F118,
	parameter int DDR_BURST_MAX = 128
)(
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,

	input  wire [$clog2(FRAME_W)-1:0] rd_x,
	input  wire [$clog2(FRAME_H)-1:0] rd_y,
	input  wire        rd_active,
	output reg  [7:0]  rd_r,
	output reg  [7:0]  rd_g,
	output reg  [7:0]  rd_b,

	input  wire        start_req,
	input  wire        bank_sel,
	input  wire [15:0] status_osd,
	input  wire        input_cmd_valid,
	input  wire  [7:0] input_cmd,
	input  wire  [3:0] sdram_test_state,
	input  wire  [3:0] sdram_size_code,
	input  wire [15:0] sdram_error_count,

	output wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output reg   [7:0] DDRAM_BURSTCNT,
	output reg  [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output reg         DDRAM_RD,
	output reg  [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output reg         DDRAM_WE,

	input  wire        vsync_pulse,
	output reg         has_frame,
	output reg         swap_pending,
	output reg  [15:0] underrun_count,
	output reg  [15:0] frames_done,
	output reg         doorbell_ok,
	output wire  [7:0] debug_state
);
	localparam int X_W = $clog2(FRAME_W);
	localparam int Y_W = $clog2(FRAME_H);
	localparam int Y_LINE_QWORDS = FRAME_W / 8;
	localparam int C_LINE_QWORDS = FRAME_W / 16;
	localparam int Y_QW_AW = $clog2(Y_LINE_QWORDS);
	localparam int C_QW_AW = $clog2(C_LINE_QWORDS);
	localparam int LINE_SLOTS = LINE_COUNT * 2;
	localparam [4:0] SECOND_SET_BASE = LINE_COUNT;
	localparam [X_W-1:0] LAST_X = FRAME_W - 1;
	localparam [Y_W-1:0] LAST_Y = FRAME_H - 1;
	localparam [28:0] BASE_W0 = PHYS_BASE[31:3];
	localparam [28:0] HPS_BANK_STRIDE_QWORDS = HPS_BANK_STRIDE_BYTES / 8;
	localparam [28:0] BASE_W1 = PHYS_BASE[31:3] + HPS_BANK_STRIDE_QWORDS;
	localparam [28:0] DOORBELL_W = DOORBELL_PHYS[31:3];
	localparam [28:0] MAILBOX_W  = MAILBOX_PHYS[31:3];
	localparam [28:0] INPUT_MAILBOX_W = INPUT_MAILBOX_PHYS[31:3];
	localparam [28:0] SDRAM_MAILBOX_W = SDRAM_MAILBOX_PHYS[31:3];
	localparam [28:0] FRAME_MAILBOX_W = FRAME_MAILBOX_PHYS[31:3];
	localparam [28:0] Y_PLANE_QWORDS = (FRAME_W * FRAME_H) / 8;
	localparam [28:0] C_PLANE_QWORDS = (FRAME_W * FRAME_H) / 32;
	localparam [28:0] U_PLANE_BASE = Y_PLANE_QWORDS;
	localparam [28:0] V_PLANE_BASE = Y_PLANE_QWORDS + C_PLANE_QWORDS;
	localparam [31:0] MAGIC = 32'h504C_584B;
	localparam [31:0] MAGIC_S = 32'h504C_5853;
	localparam [31:0] MAGIC_I = 32'h504C_5849;
	localparam [31:0] MAGIC_M = 32'h504C_584D;
	localparam [31:0] MAGIC_F = 32'h504C_5846;

	assign DDRAM_CLK = clk_ddr;
	assign DDRAM_BE = 8'hFF;

	reg [LINE_SLOTS-1:0] y_wr, u_wr, v_wr;
	reg [Y_QW_AW-1:0] y_wr_addr;
	reg [C_QW_AW-1:0] c_wr_addr;
	reg [63:0] y_wr_data, u_wr_data, v_wr_data;
	wire [63:0] y_q [0:LINE_SLOTS-1];
	wire [63:0] u_q [0:LINE_SLOTS-1];
	wire [63:0] v_q [0:LINE_SLOTS-1];
	wire [X_W-1:0] rd_x_clamped = (rd_x < FRAME_W) ? rd_x : LAST_X;
	wire [Y_QW_AW-1:0] y_rd_addr = rd_x_clamped[X_W-1:3];
	wire [C_QW_AW-1:0] c_rd_addr = rd_x_clamped[X_W-1:4];

	genvar li;
	generate
		for (li = 0; li < LINE_SLOTS; li = li + 1) begin : gen_line
			line_buf_ram #(.WIDTH(Y_LINE_QWORDS), .AW(Y_QW_AW), .DATA_W(64)) yram (
				.wr_clk(clk_ddr), .wr_en(y_wr[li]), .wr_addr(y_wr_addr), .wr_data(y_wr_data),
				.rd_clk(clk), .rd_addr(y_rd_addr), .rd_data(y_q[li])
			);
			line_buf_ram #(.WIDTH(C_LINE_QWORDS), .AW(C_QW_AW), .DATA_W(64)) uram (
				.wr_clk(clk_ddr), .wr_en(u_wr[li]), .wr_addr(c_wr_addr), .wr_data(u_wr_data),
				.rd_clk(clk), .rd_addr(c_rd_addr), .rd_data(u_q[li])
			);
			line_buf_ram #(.WIDTH(C_LINE_QWORDS), .AW(C_QW_AW), .DATA_W(64)) vram (
				.wr_clk(clk_ddr), .wr_en(v_wr[li]), .wr_addr(c_wr_addr), .wr_data(v_wr_data),
				.rd_clk(clk), .rd_addr(c_rd_addr), .rd_data(v_q[li])
			);
		end
	endgenerate

	reg disp_bank;
	reg pending_bank;
	reg pending_bank_ddr;
	reg disp_buf;
	reg swap_req_s1, swap_req_s2, swap_req_seen;
	reg pending_bank_s1, pending_bank_s2;
	reg pending_ready_s1, pending_ready_s2;
	reg pending_ready_ddr;
	reg swap_req_t_ddr;

	always @(posedge clk) begin
		if (reset) begin
			disp_bank <= 1'b0;
			pending_bank <= 1'b0;
			disp_buf <= 1'b0;
			has_frame <= 1'b0;
			swap_pending <= 1'b0;
			frames_done <= 16'd0;
			swap_req_s1 <= 1'b0;
			swap_req_s2 <= 1'b0;
			swap_req_seen <= 1'b0;
			pending_bank_s1 <= 1'b0;
			pending_bank_s2 <= 1'b0;
			pending_ready_s1 <= 1'b0;
			pending_ready_s2 <= 1'b0;
		end else begin
			swap_req_s1 <= swap_req_t_ddr;
			swap_req_s2 <= swap_req_s1;
			pending_bank_s1 <= pending_bank_ddr;
			pending_bank_s2 <= pending_bank_s1;
			pending_ready_s1 <= pending_ready_ddr;
			pending_ready_s2 <= pending_ready_s1;

			if (swap_req_s2 != swap_req_seen) begin
				swap_req_seen <= swap_req_s2;
				pending_bank <= pending_bank_s2;
				swap_pending <= 1'b1;
			end

			if (vsync_pulse && swap_pending && pending_ready_s2) begin
				disp_bank <= pending_bank;
				disp_buf <= ~disp_buf;
				has_frame <= 1'b1;
				swap_pending <= 1'b0;
				frames_done <= frames_done + 16'd1;
			end
		end
	end

	function automatic [7:0] pick_byte(input [63:0] q, input [2:0] sel);
		case (sel)
			3'd0: pick_byte = q[7:0];
			3'd1: pick_byte = q[15:8];
			3'd2: pick_byte = q[23:16];
			3'd3: pick_byte = q[31:24];
			3'd4: pick_byte = q[39:32];
			3'd5: pick_byte = q[47:40];
			3'd6: pick_byte = q[55:48];
			default: pick_byte = q[63:56];
		endcase
	endfunction

	function automatic [7:0] sat8(input signed [11:0] v);
		begin
			if (v < 0)
				sat8 = 8'd0;
			else if (v > 12'sd255)
				sat8 = 8'd255;
			else
				sat8 = v[7:0];
		end
	endfunction

	reg [LINE_SLOTS-1:0] y_valid_v1, y_valid_v2, c_valid_v1, c_valid_v2;
	reg [LINE_SLOTS-1:0] y_bank_v1, y_bank_v2, c_bank_v1, c_bank_v2;
	reg [Y_W-1:0] y_line_v1 [0:LINE_SLOTS-1];
	reg [Y_W-1:0] y_line_v2 [0:LINE_SLOTS-1];
	reg [Y_W-2:0] c_line_v1 [0:LINE_SLOTS-1];
	reg [Y_W-2:0] c_line_v2 [0:LINE_SLOTS-1];
	reg [Y_W-1:0] want_y_sys;
	reg rd_active_r, rd_active_d, miss_d;
	reg y_hit_r, c_hit_r;
	reg [4:0] y_hit_idx_r, c_hit_idx_r;
	reg [2:0] y_sel_r, c_sel_r;

	integer vi;
	reg y_hit_now, c_hit_now;
	reg [4:0] y_hit_idx_now, c_hit_idx_now;
	reg [63:0] selected_y_q, selected_u_q, selected_v_q;
	reg [4:0] video_slot;
	wire [Y_W-2:0] rd_cy = rd_y[Y_W-1:1];
	always @* begin
		y_hit_now = 1'b0;
		c_hit_now = 1'b0;
		y_hit_idx_now = 5'd0;
		c_hit_idx_now = 5'd0;
		selected_y_q = 64'd0;
		selected_u_q = 64'd0;
		selected_v_q = 64'd0;
		for (vi = 0; vi < LINE_COUNT; vi = vi + 1) begin
			video_slot = (disp_buf ? SECOND_SET_BASE : 5'd0) + vi[4:0];
			if (y_valid_v2[video_slot] && (y_bank_v2[video_slot] == disp_bank)
			    && (y_line_v2[video_slot] == rd_y) && !y_hit_now) begin
				y_hit_now = 1'b1;
				y_hit_idx_now = video_slot;
			end
			if (c_valid_v2[video_slot] && (c_bank_v2[video_slot] == disp_bank)
			    && (c_line_v2[video_slot] == rd_cy) && !c_hit_now) begin
				c_hit_now = 1'b1;
				c_hit_idx_now = video_slot;
			end
			if (y_hit_idx_r == video_slot)
				selected_y_q = y_q[video_slot];
			if (c_hit_idx_r == video_slot) begin
				selected_u_q = u_q[video_slot];
				selected_v_q = v_q[video_slot];
			end
		end
	end
	wire rd_miss_now = rd_active && has_frame && (!y_hit_now || !c_hit_now);

	wire [7:0] y_pix = pick_byte(selected_y_q, y_sel_r);
	wire [7:0] u_pix = pick_byte(selected_u_q, c_sel_r);
	wire [7:0] v_pix = pick_byte(selected_v_q, c_sel_r);
	wire signed [11:0] y_s = {4'd0, y_pix};
	wire signed [11:0] u_s = {4'd0, u_pix} - 12'sd128;
	wire signed [11:0] v_s = {4'd0, v_pix} - 12'sd128;
	wire signed [20:0] r_calc_w = (y_s <<< 8) + (21'sd359 * v_s);
	wire signed [20:0] g_calc_w = (y_s <<< 8) - (21'sd88 * u_s) - (21'sd183 * v_s);
	wire signed [20:0] b_calc_w = (y_s <<< 8) + (21'sd454 * u_s);
	wire signed [11:0] r_calc = r_calc_w[20:8];
	wire signed [11:0] g_calc = g_calc_w[20:8];
	wire signed [11:0] b_calc = b_calc_w[20:8];

	always @(posedge clk) begin
		if (reset) begin
			rd_active_r <= 1'b0;
			rd_active_d <= 1'b0;
			miss_d <= 1'b0;
			underrun_count <= 16'd0;
			want_y_sys <= '0;
			y_valid_v1 <= '0;
			y_valid_v2 <= '0;
			c_valid_v1 <= '0;
			c_valid_v2 <= '0;
			y_bank_v1 <= '0;
			y_bank_v2 <= '0;
			c_bank_v1 <= '0;
			c_bank_v2 <= '0;
			y_hit_r <= 1'b0;
			c_hit_r <= 1'b0;
			y_hit_idx_r <= 5'd0;
			c_hit_idx_r <= 5'd0;
			y_sel_r <= 3'd0;
			c_sel_r <= 3'd0;
		end else begin
			y_valid_v1 <= y_valid;
			y_valid_v2 <= y_valid_v1;
			c_valid_v1 <= c_valid;
			c_valid_v2 <= c_valid_v1;
			y_bank_v1 <= y_bank;
			y_bank_v2 <= y_bank_v1;
			c_bank_v1 <= c_bank;
			c_bank_v2 <= c_bank_v1;
			for (vi = 0; vi < LINE_SLOTS; vi = vi + 1) begin
				y_line_v1[vi] <= y_line[vi];
				y_line_v2[vi] <= y_line_v1[vi];
				c_line_v1[vi] <= c_line[vi];
				c_line_v2[vi] <= c_line_v1[vi];
			end

			if (rd_y != want_y_sys)
				want_y_sys <= rd_y;

			rd_active_r <= rd_active;
			rd_active_d <= rd_active_r;
			y_hit_r <= y_hit_now;
			c_hit_r <= c_hit_now;
			y_hit_idx_r <= y_hit_idx_now;
			c_hit_idx_r <= c_hit_idx_now;
			y_sel_r <= rd_x_clamped[2:0];
			c_sel_r <= rd_x_clamped[3:1];
			miss_d <= rd_miss_now;
			if (miss_d && underrun_count != 16'hFFFF)
				underrun_count <= underrun_count + 16'd1;

			if ((rd_active_d || !rd_active) && has_frame && !miss_d && y_hit_r && c_hit_r) begin
				rd_r <= sat8(r_calc);
				rd_g <= sat8(g_calc);
				rd_b <= sat8(b_calc);
			end else if (!has_frame || miss_d) begin
				rd_r <= 8'd0;
				rd_g <= 8'd0;
				rd_b <= 8'd0;
			end
		end
	end

	localparam [3:0] S_IDLE       = 4'd0;
	localparam [3:0] S_LINE_ISSUE = 4'd1;
	localparam [3:0] S_LINE_WAIT  = 4'd2;
	localparam [3:0] S_POLL_WAIT  = 4'd3;
	localparam [3:0] S_WRITE_WAIT = 4'd4;

	reg [3:0] state_ddr;
	reg [LINE_SLOTS-1:0] y_valid, c_valid;
	reg [LINE_SLOTS-1:0] y_bank, c_bank;
	reg [Y_W-1:0] y_line [0:LINE_SLOTS-1];
	reg [Y_W-2:0] c_line [0:LINE_SLOTS-1];
	reg disp_bank_d1, disp_bank_d2;
	reg disp_buf_d1, disp_buf_d2;
	reg swap_pending_d1, swap_pending_d2;
	reg pending_bank_d1, pending_bank_d2;
	reg [Y_W-1:0] want_y_s1, want_y_s2;
	reg [Y_W-1:0] desired_y_r [0:LINE_COUNT-1];
	reg [15:0] poll_div;
	reg poll_pending;
	reg [30:0] last_seq;
	reg have_seq;
	reg [15:0] mbox_seq, mbox_last;
	reg mbox_req, mbox_valid;
	reg [17:0] mbox_hb;
	reg [7:0] sdram_mbox_seq, frame_mbox_seq;
	reg [23:0] sdram_mbox_last, frame_mbox_last;
	reg sdram_mbox_req, sdram_mbox_valid;
	reg frame_mbox_req, frame_mbox_valid;
	reg [17:0] sdram_mbox_hb, frame_mbox_hb;
	reg start_d1, start_d2, start_seen;
	reg bank_sel_d1, bank_sel_d2;
	reg [15:0] status_osd_d1, status_osd_d2;
	reg [23:0] sdram_status_d1, sdram_status_d2;

	wire cmd_empty;
	wire [7:0] cmd_rdata;
	reg cmd_pop;
	async_fifo #(.WIDTH(8), .AW(2)) input_fifo (
		.wr_clk(clk), .wr_reset(reset),
		.wr_en(input_cmd_valid && (input_cmd != 8'd0)), .wr_data(input_cmd),
		.wr_full(), .wr_almost_full(),
		.rd_clk(clk_ddr), .rd_reset(reset), .rd_en(cmd_pop), .rd_data(cmd_rdata), .rd_empty(cmd_empty)
	);

	function automatic [Y_W-1:0] clamp_ahead(input [Y_W-1:0] base, input integer ahead);
		integer sum;
		begin
			sum = base + ahead;
			clamp_ahead = (sum >= FRAME_H) ? LAST_Y : sum[Y_W-1:0];
		end
	endfunction

	integer ti, tj, tk;
	reg need_y_cur_c, need_c_cur_c, need_y_prep_c, need_c_prep_c, pending_ready_c;
	reg [Y_W-1:0] target_y_cur_c, target_y_prep_c;
	reg [Y_W-2:0] target_c_cur_c, target_c_prep_c;
	reg [4:0] target_y_idx_cur_c, target_y_idx_prep_c, target_c_idx_cur_c, target_c_idx_prep_c;
	reg found_line, slot_keep, found_slot_y_cur, found_slot_y_prep, found_slot_c_cur, found_slot_c_prep;
	reg [Y_W-1:0] desired_y;
	reg [Y_W-2:0] desired_c;
	reg [4:0] cur_base_idx, prep_base_idx;
	always @* begin
		cur_base_idx = disp_buf_d2 ? SECOND_SET_BASE : 5'd0;
		prep_base_idx = disp_buf_d2 ? 5'd0 : SECOND_SET_BASE;
		need_y_cur_c = 1'b0;
		need_c_cur_c = 1'b0;
		need_y_prep_c = 1'b0;
		need_c_prep_c = 1'b0;
		target_y_cur_c = desired_y_r[0];
		target_y_prep_c = '0;
		target_c_cur_c = desired_y_r[0][Y_W-1:1];
		target_c_prep_c = '0;
		target_y_idx_cur_c = cur_base_idx;
		target_y_idx_prep_c = prep_base_idx;
		target_c_idx_cur_c = cur_base_idx;
		target_c_idx_prep_c = prep_base_idx;
		found_slot_y_cur = 1'b0;
		found_slot_y_prep = 1'b0;
		found_slot_c_cur = 1'b0;
		found_slot_c_prep = 1'b0;
		pending_ready_c = 1'b1;

		for (ti = 0; ti < LINE_COUNT; ti = ti + 1) begin
			desired_y = desired_y_r[ti];
			desired_c = desired_y_r[ti][Y_W-1:1];
			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (y_valid[cur_base_idx + tj[4:0]] && (y_bank[cur_base_idx + tj[4:0]] == disp_bank_d2)
				    && (y_line[cur_base_idx + tj[4:0]] == desired_y))
					found_line = 1'b1;
			end
			if (!found_line && !need_y_cur_c) begin
				need_y_cur_c = 1'b1;
				target_y_cur_c = desired_y;
			end

			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (c_valid[cur_base_idx + tj[4:0]] && (c_bank[cur_base_idx + tj[4:0]] == disp_bank_d2)
				    && (c_line[cur_base_idx + tj[4:0]] == desired_c))
					found_line = 1'b1;
			end
			if (!found_line && !need_c_cur_c) begin
				need_c_cur_c = 1'b1;
				target_c_cur_c = desired_c;
			end

			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (y_valid[prep_base_idx + tj[4:0]] && (y_bank[prep_base_idx + tj[4:0]] == pending_bank_d2)
				    && (y_line[prep_base_idx + tj[4:0]] == ti[Y_W-1:0]))
					found_line = 1'b1;
			end
			if (swap_pending_d2 && !found_line) begin
				pending_ready_c = 1'b0;
				if (!need_y_prep_c) begin
					need_y_prep_c = 1'b1;
					target_y_prep_c = ti[Y_W-1:0];
				end
			end

			found_line = 1'b0;
			for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
				if (c_valid[prep_base_idx + tj[4:0]] && (c_bank[prep_base_idx + tj[4:0]] == pending_bank_d2)
				    && (c_line[prep_base_idx + tj[4:0]] == ti[Y_W-1:1]))
					found_line = 1'b1;
			end
			if (swap_pending_d2 && !found_line) begin
				pending_ready_c = 1'b0;
				if (!need_c_prep_c) begin
					need_c_prep_c = 1'b1;
					target_c_prep_c = ti[Y_W-1:1];
				end
			end
		end

		for (tj = 0; tj < LINE_COUNT; tj = tj + 1) begin
			slot_keep = 1'b0;
			for (tk = 0; tk < LINE_COUNT; tk = tk + 1) begin
				if (y_valid[cur_base_idx + tj[4:0]] && (y_bank[cur_base_idx + tj[4:0]] == disp_bank_d2)
				    && (y_line[cur_base_idx + tj[4:0]] == desired_y_r[tk]))
					slot_keep = 1'b1;
			end
			if ((!y_valid[cur_base_idx + tj[4:0]] || !slot_keep) && !found_slot_y_cur) begin
				found_slot_y_cur = 1'b1;
				target_y_idx_cur_c = cur_base_idx + tj[4:0];
			end

			slot_keep = 1'b0;
			for (tk = 0; tk < LINE_COUNT; tk = tk + 1) begin
				if (c_valid[cur_base_idx + tj[4:0]] && (c_bank[cur_base_idx + tj[4:0]] == disp_bank_d2)
				    && (c_line[cur_base_idx + tj[4:0]] == desired_y_r[tk][Y_W-1:1]))
					slot_keep = 1'b1;
			end
			if ((!c_valid[cur_base_idx + tj[4:0]] || !slot_keep) && !found_slot_c_cur) begin
				found_slot_c_cur = 1'b1;
				target_c_idx_cur_c = cur_base_idx + tj[4:0];
			end

			if ((!y_valid[prep_base_idx + tj[4:0]]) && !found_slot_y_prep) begin
				found_slot_y_prep = 1'b1;
				target_y_idx_prep_c = prep_base_idx + tj[4:0];
			end
			if ((!c_valid[prep_base_idx + tj[4:0]]) && !found_slot_c_prep) begin
				found_slot_c_prep = 1'b1;
				target_c_idx_prep_c = prep_base_idx + tj[4:0];
			end
		end
	end

	reg fill_bank, fill_is_chroma, fill_plane_v;
	reg [Y_W-1:0] fill_y;
	reg [Y_W-2:0] fill_cy;
	reg [4:0] fill_idx;
	reg [Y_QW_AW:0] fill_qword;
	reg [Y_QW_AW:0] burst_left;
	reg [Y_QW_AW:0] qwords_remaining;
	reg [7:0] imbox_cmd_seq;
	reg [15:0] imbox_seq;
	wire [28:0] fill_bank_base = fill_bank ? BASE_W1 : BASE_W0;
	wire [28:0] y_addr = fill_bank_base + (fill_y * Y_LINE_QWORDS) + fill_qword[Y_QW_AW-1:0];
	wire [28:0] u_addr = fill_bank_base + U_PLANE_BASE + (fill_cy * C_LINE_QWORDS) + fill_qword[C_QW_AW-1:0];
	wire [28:0] v_addr = fill_bank_base + V_PLANE_BASE + (fill_cy * C_LINE_QWORDS) + fill_qword[C_QW_AW-1:0];
	wire [28:0] line_addr = fill_is_chroma ? (fill_plane_v ? v_addr : u_addr) : y_addr;
	wire [Y_QW_AW:0] burst_cap = (qwords_remaining > DDR_BURST_MAX) ? DDR_BURST_MAX[Y_QW_AW:0] : qwords_remaining;
	wire [7:0] burst_this = burst_cap[7:0];
	wire db_magic_ok = poll_pending && DDRAM_DOUT_READY && (DDRAM_DOUT[31:0] == MAGIC);
	wire db_new_seq = db_magic_ok && (!have_seq || (DDRAM_DOUT[62:32] != last_seq));
	wire spi_edge_ddr = start_d2 != start_seen;

	assign debug_state = {LINE_COUNT[2:0], |y_valid, state_ddr};

	always @(posedge clk_ddr) begin
		if (reset) begin
			state_ddr <= S_IDLE;
			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;
			DDRAM_ADDR <= 29'd0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_DIN <= 64'd0;
			y_wr <= '0;
			u_wr <= '0;
			v_wr <= '0;
			y_wr_addr <= '0;
			c_wr_addr <= '0;
			y_wr_data <= 64'd0;
			u_wr_data <= 64'd0;
			v_wr_data <= 64'd0;
			y_valid <= '0;
			c_valid <= '0;
			y_bank <= '0;
			c_bank <= '0;
			for (ti = 0; ti < LINE_SLOTS; ti = ti + 1) begin
				y_line[ti] <= '0;
				c_line[ti] <= '0;
			end
			disp_bank_d1 <= 1'b0;
			disp_bank_d2 <= 1'b0;
			disp_buf_d1 <= 1'b0;
			disp_buf_d2 <= 1'b0;
			swap_pending_d1 <= 1'b0;
			swap_pending_d2 <= 1'b0;
			pending_bank_d1 <= 1'b0;
			pending_bank_d2 <= 1'b0;
			want_y_s1 <= '0;
			want_y_s2 <= '0;
			for (ti = 0; ti < LINE_COUNT; ti = ti + 1)
				desired_y_r[ti] <= '0;
			pending_ready_ddr <= 1'b0;
			pending_bank_ddr <= 1'b0;
			swap_req_t_ddr <= 1'b0;
			poll_div <= 16'd0;
			poll_pending <= 1'b0;
			last_seq <= 31'd0;
			have_seq <= 1'b0;
			doorbell_ok <= 1'b0;
			start_d1 <= 1'b0;
			start_d2 <= 1'b0;
			start_seen <= 1'b0;
			bank_sel_d1 <= 1'b0;
			bank_sel_d2 <= 1'b0;
			status_osd_d1 <= 16'd0;
			status_osd_d2 <= 16'd0;
			sdram_status_d1 <= 24'd0;
			sdram_status_d2 <= 24'd0;
			mbox_seq <= 16'd0;
			mbox_last <= 16'd0;
			mbox_req <= 1'b1;
			mbox_valid <= 1'b0;
			mbox_hb <= 18'd0;
			sdram_mbox_seq <= 8'd0;
			sdram_mbox_last <= 24'd0;
			sdram_mbox_req <= 1'b1;
			sdram_mbox_valid <= 1'b0;
			sdram_mbox_hb <= 18'd0;
			frame_mbox_seq <= 8'd0;
			frame_mbox_last <= 24'd0;
			frame_mbox_req <= 1'b1;
			frame_mbox_valid <= 1'b0;
			frame_mbox_hb <= 18'd0;
			cmd_pop <= 1'b0;
			imbox_seq <= 16'd0;
			imbox_cmd_seq <= 8'd0;
			fill_qword <= '0;
			burst_left <= '0;
			qwords_remaining <= '0;
			fill_is_chroma <= 1'b0;
			fill_plane_v <= 1'b0;
		end else begin
			if (!DDRAM_BUSY) begin
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
			end
			y_wr <= '0;
			u_wr <= '0;
			v_wr <= '0;
			cmd_pop <= 1'b0;

			disp_bank_d1 <= disp_bank;
			disp_bank_d2 <= disp_bank_d1;
			disp_buf_d1 <= disp_buf;
			disp_buf_d2 <= disp_buf_d1;
			swap_pending_d1 <= swap_pending;
			swap_pending_d2 <= swap_pending_d1;
			pending_bank_d1 <= pending_bank;
			pending_bank_d2 <= pending_bank_d1;
			want_y_s1 <= want_y_sys;
			want_y_s2 <= want_y_s1;
			for (ti = 0; ti < LINE_COUNT; ti = ti + 1)
				desired_y_r[ti] <= clamp_ahead(want_y_s1, ti);
			start_d1 <= start_req;
			start_d2 <= start_d1;
			bank_sel_d1 <= bank_sel;
			bank_sel_d2 <= bank_sel_d1;
			status_osd_d1 <= status_osd;
			status_osd_d2 <= status_osd_d1;
			sdram_status_d1 <= {sdram_error_count, sdram_size_code, sdram_test_state};
			sdram_status_d2 <= sdram_status_d1;

			mbox_hb <= mbox_hb + 18'd1;
			if (!mbox_valid || (status_osd_d2 != mbox_last) || (mbox_hb == 18'd0))
				mbox_req <= 1'b1;
			sdram_mbox_hb <= sdram_mbox_hb + 18'd1;
			if (!sdram_mbox_valid || (sdram_status_d2 != sdram_mbox_last) || (sdram_mbox_hb == 18'd0))
				sdram_mbox_req <= 1'b1;
			frame_mbox_hb <= frame_mbox_hb + 18'd1;
			if (!frame_mbox_valid || ({underrun_count, debug_state} != frame_mbox_last) || (frame_mbox_hb == 18'd0))
				frame_mbox_req <= 1'b1;

			if (db_new_seq) begin
				last_seq <= DDRAM_DOUT[62:32];
				have_seq <= 1'b1;
				pending_bank_ddr <= DDRAM_DOUT[63];
				swap_req_t_ddr <= ~swap_req_t_ddr;
				doorbell_ok <= 1'b1;
			end
			if (spi_edge_ddr) begin
				start_seen <= start_d2;
				pending_bank_ddr <= bank_sel_d2;
				swap_req_t_ddr <= ~swap_req_t_ddr;
			end

			case (state_ddr)
				S_IDLE: begin
					pending_ready_ddr <= pending_ready_c;
					poll_div <= poll_div + 16'd1;
					if (need_y_cur_c || (swap_pending_d2 && need_y_prep_c)) begin
						fill_bank <= need_y_cur_c ? disp_bank_d2 : pending_bank_d2;
						fill_y <= need_y_cur_c ? target_y_cur_c : target_y_prep_c;
						fill_idx <= need_y_cur_c ? target_y_idx_cur_c : target_y_idx_prep_c;
						y_valid[need_y_cur_c ? target_y_idx_cur_c : target_y_idx_prep_c] <= 1'b0;
						y_bank[need_y_cur_c ? target_y_idx_cur_c : target_y_idx_prep_c] <= need_y_cur_c ? disp_bank_d2 : pending_bank_d2;
						fill_is_chroma <= 1'b0;
						fill_plane_v <= 1'b0;
						fill_qword <= '0;
						qwords_remaining <= Y_LINE_QWORDS[Y_QW_AW:0];
						state_ddr <= S_LINE_ISSUE;
					end else if (need_c_cur_c || (swap_pending_d2 && need_c_prep_c)) begin
						fill_bank <= need_c_cur_c ? disp_bank_d2 : pending_bank_d2;
						fill_cy <= need_c_cur_c ? target_c_cur_c : target_c_prep_c;
						fill_idx <= need_c_cur_c ? target_c_idx_cur_c : target_c_idx_prep_c;
						c_valid[need_c_cur_c ? target_c_idx_cur_c : target_c_idx_prep_c] <= 1'b0;
						c_bank[need_c_cur_c ? target_c_idx_cur_c : target_c_idx_prep_c] <= need_c_cur_c ? disp_bank_d2 : pending_bank_d2;
						fill_is_chroma <= 1'b1;
						fill_plane_v <= 1'b0;
						fill_qword <= '0;
						qwords_remaining <= C_LINE_QWORDS[Y_QW_AW:0];
						state_ddr <= S_LINE_ISSUE;
					end else if (!poll_pending && poll_div[7:0] == 8'd0 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= DOORBELL_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						poll_pending <= 1'b1;
						state_ddr <= S_POLL_WAIT;
					end else if (!cmd_empty && poll_div[7:0] == 8'd64 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= INPUT_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {imbox_seq + 16'd1, imbox_cmd_seq + 8'd1, cmd_rdata, MAGIC_I};
						DDRAM_WE <= 1'b1;
						cmd_pop <= 1'b1;
						imbox_seq <= imbox_seq + 16'd1;
						imbox_cmd_seq <= imbox_cmd_seq + 8'd1;
						state_ddr <= S_WRITE_WAIT;
					end else if (mbox_req && poll_div[7:0] == 8'd128 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {mbox_seq + 16'd1, status_osd_d2, MAGIC_S};
						DDRAM_WE <= 1'b1;
						mbox_seq <= mbox_seq + 16'd1;
						mbox_last <= status_osd_d2;
						mbox_valid <= 1'b1;
						mbox_req <= 1'b0;
						state_ddr <= S_WRITE_WAIT;
					end else if (sdram_mbox_req && poll_div[7:0] == 8'd192 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= SDRAM_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {sdram_status_d2, sdram_mbox_seq + 8'd1, MAGIC_M};
						DDRAM_WE <= 1'b1;
						sdram_mbox_seq <= sdram_mbox_seq + 8'd1;
						sdram_mbox_last <= sdram_status_d2;
						sdram_mbox_valid <= 1'b1;
						sdram_mbox_req <= 1'b0;
						state_ddr <= S_WRITE_WAIT;
					end else if (frame_mbox_req && poll_div[7:0] == 8'd224 && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= FRAME_MAILBOX_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {underrun_count, debug_state, frame_mbox_seq + 8'd1, MAGIC_F};
						DDRAM_WE <= 1'b1;
						frame_mbox_seq <= frame_mbox_seq + 8'd1;
						frame_mbox_last <= {underrun_count, debug_state};
						frame_mbox_valid <= 1'b1;
						frame_mbox_req <= 1'b0;
						state_ddr <= S_WRITE_WAIT;
					end
				end

				S_LINE_ISSUE: begin
					if (!DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= line_addr;
						DDRAM_BURSTCNT <= burst_this;
						DDRAM_RD <= 1'b1;
						burst_left <= burst_cap;
						state_ddr <= S_LINE_WAIT;
					end
				end

				S_LINE_WAIT: begin
					if (DDRAM_DOUT_READY) begin
						if (fill_is_chroma) begin
							c_wr_addr <= fill_qword[C_QW_AW-1:0];
							if (fill_plane_v) begin
								v_wr_data <= DDRAM_DOUT;
								v_wr[fill_idx] <= 1'b1;
							end else begin
								u_wr_data <= DDRAM_DOUT;
								u_wr[fill_idx] <= 1'b1;
							end
						end else begin
							y_wr_addr <= fill_qword[Y_QW_AW-1:0];
							y_wr_data <= DDRAM_DOUT;
							y_wr[fill_idx] <= 1'b1;
						end
						fill_qword <= fill_qword + 1'b1;
						qwords_remaining <= qwords_remaining - 1'b1;
						burst_left <= burst_left - 1'b1;
						if (qwords_remaining == 1) begin
							if (fill_is_chroma && !fill_plane_v) begin
								fill_plane_v <= 1'b1;
								fill_qword <= '0;
								qwords_remaining <= C_LINE_QWORDS[Y_QW_AW:0];
								state_ddr <= S_LINE_ISSUE;
							end else begin
								if (fill_is_chroma) begin
									c_line[fill_idx] <= fill_cy;
									c_bank[fill_idx] <= fill_bank;
									c_valid[fill_idx] <= 1'b1;
								end else begin
									y_line[fill_idx] <= fill_y;
									y_bank[fill_idx] <= fill_bank;
									y_valid[fill_idx] <= 1'b1;
								end
								state_ddr <= S_IDLE;
							end
						end else if (burst_left == 1) begin
							state_ddr <= S_LINE_ISSUE;
						end
					end
				end

				S_POLL_WAIT: begin
					if (DDRAM_DOUT_READY) begin
						poll_pending <= 1'b0;
						state_ddr <= S_IDLE;
					end
				end

				S_WRITE_WAIT: begin
					if (!DDRAM_BUSY && !DDRAM_WE)
						state_ddr <= S_IDLE;
				end

				default: state_ddr <= S_IDLE;
			endcase
		end
	end

endmodule
