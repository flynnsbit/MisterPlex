// HPS-DDR-backed RGB565 frame store.
//
// The ARM writes complete RGB565 frames into two HPS DDR banks and rings the
// existing PLXK doorbell. The FPGA never copies the frame through the MiSTer
// SDRAM stick; it only prefetches source lines from HPS DDR into bank-tagged
// M10K line buffers for scanout.

module ddr_frame_store #(
	parameter int FRAME_W = 640,
	parameter int FRAME_H = 480,
	parameter int FRAME_STRIDE = FRAME_W,
	parameter int LINE_COUNT = 8,
	parameter [31:0] PHYS_BASE = 32'h3000_0000,
	parameter int HPS_BANK_STRIDE_BYTES = 1048576,
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
	localparam int LINE_QWORDS = (FRAME_W + 3) / 4;
	localparam int LINE_QW_AW = $clog2(LINE_QWORDS);
	localparam int MAX_LINES = LINE_COUNT;
	localparam int LINE_SLOTS = MAX_LINES * 2;
	localparam [4:0] SECOND_SET_BASE = MAX_LINES;
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
	localparam [31:0] MAGIC = 32'h504C_584B;
	localparam [31:0] MAGIC_S = 32'h504C_5853;
	localparam [31:0] MAGIC_I = 32'h504C_5849;
	localparam [31:0] MAGIC_M = 32'h504C_584D;
	localparam [31:0] MAGIC_F = 32'h504C_5846;

	assign DDRAM_CLK = clk_ddr;
	assign DDRAM_BE = 8'hFF;

	reg [LINE_SLOTS-1:0] line_wr;
	reg [LINE_QW_AW-1:0] line_wr_addr;
	reg [63:0] line_wr_data;
	wire [63:0] line_q [0:LINE_SLOTS-1];
	wire [X_W-1:0] rd_x_clamped = (rd_x < FRAME_W) ? rd_x : LAST_X;
	wire [LINE_QW_AW-1:0] line_rd_addr = rd_x_clamped[X_W-1:2];

	genvar li;
	generate
		for (li = 0; li < LINE_SLOTS; li = li + 1) begin : gen_line
			if ((li < LINE_COUNT) ||
			    ((li >= MAX_LINES) && (li < (MAX_LINES + LINE_COUNT)))) begin : used
				line_buf_ram #(
					.WIDTH(LINE_QWORDS),
					.AW(LINE_QW_AW),
					.DATA_W(64)
				) ram (
					.wr_clk(clk_ddr),
					.wr_en(line_wr[li]),
					.wr_addr(line_wr_addr),
					.wr_data(line_wr_data),
					.rd_clk(clk),
					.rd_addr(line_rd_addr),
					.rd_data(line_q[li])
				);
			end else begin : unused
				assign line_q[li] = 64'd0;
			end
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

	reg       rd_active_r;
	reg       hit_r;
	reg [4:0] hit_idx_r;
	reg [1:0] pix_sel_r;
	reg [15:0] rd_q;
	reg        rd_active_d;
	reg        miss_d;
	reg [LINE_SLOTS-1:0] line_valid_v1, line_valid_v2;
	reg [LINE_SLOTS-1:0] line_bank_v1, line_bank_v2;
	reg [Y_W-1:0] line_y_v1 [0:LINE_SLOTS-1];
	reg [Y_W-1:0] line_y_v2 [0:LINE_SLOTS-1];
	reg [Y_W-1:0] want_y_sys;
	reg [Y_W-1:0] want_y_s1, want_y_s2;

	function automatic [15:0] pick_pixel(input [63:0] q, input [1:0] sel);
		case (sel)
			2'd0: pick_pixel = q[15:0];
			2'd1: pick_pixel = q[31:16];
			2'd2: pick_pixel = q[47:32];
			default: pick_pixel = q[63:48];
		endcase
	endfunction

	integer vi;
	reg hit_now;
	reg [4:0] hit_idx_now;
	reg [63:0] selected_line_q;
	reg [4:0] video_slot;
	always @* begin
		hit_now = 1'b0;
		hit_idx_now = 5'd0;
		selected_line_q = 64'd0;
		for (vi = 0; vi < MAX_LINES; vi = vi + 1) begin
			if (vi < LINE_COUNT) begin
				video_slot = (disp_buf ? SECOND_SET_BASE : 5'd0) + vi[4:0];
				if (line_valid_v2[video_slot] && (line_bank_v2[video_slot] == disp_bank)
				    && (line_y_v2[video_slot] == rd_y) && !hit_now) begin
					hit_now = 1'b1;
					hit_idx_now = video_slot;
				end
				if (hit_idx_r == video_slot)
					selected_line_q = line_q[video_slot];
			end
		end
	end
	wire rd_miss_now = rd_active && has_frame && !hit_now;

	always @(posedge clk) begin
		if (reset) begin
			rd_active_r <= 1'b0;
			hit_r <= 1'b0;
			hit_idx_r <= 5'd0;
			pix_sel_r <= 2'd0;
			rd_q <= 16'd0;
			rd_active_d <= 1'b0;
			miss_d <= 1'b0;
			underrun_count <= 16'd0;
			want_y_sys <= '0;
			line_valid_v1 <= '0;
			line_valid_v2 <= '0;
			line_bank_v1 <= '0;
			line_bank_v2 <= '0;
		end else begin
			line_valid_v1 <= line_valid;
			line_valid_v2 <= line_valid_v1;
			line_bank_v1 <= line_bank;
			line_bank_v2 <= line_bank_v1;
			for (vi = 0; vi < LINE_SLOTS; vi = vi + 1) begin
				line_y_v1[vi] <= line_y[vi];
				line_y_v2[vi] <= line_y_v1[vi];
			end

			if (rd_y != want_y_sys)
				want_y_sys <= rd_y;

			rd_active_r <= rd_active;
			hit_r <= hit_now;
			hit_idx_r <= hit_idx_now;
			pix_sel_r <= rd_x_clamped[1:0];
			miss_d <= rd_miss_now;
			rd_q <= hit_r ? pick_pixel(selected_line_q, pix_sel_r) : 16'd0;
			rd_active_d <= rd_active_r;
			if (miss_d && underrun_count != 16'hFFFF)
				underrun_count <= underrun_count + 16'd1;

			if ((rd_active_d || !rd_active) && has_frame && !miss_d) begin
				rd_r <= {rd_q[15:11], rd_q[15:13]};
				rd_g <= {rd_q[10:5],  rd_q[10:9]};
				rd_b <= {rd_q[4:0],   rd_q[4:2]};
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
	reg [LINE_SLOTS-1:0] line_valid;
	reg [LINE_SLOTS-1:0] line_bank;
	reg [Y_W-1:0] line_y [0:LINE_SLOTS-1];
	reg disp_bank_d1, disp_bank_d2;
	reg disp_buf_d1, disp_buf_d2;
	reg swap_pending_d1, swap_pending_d2;
	reg pending_bank_d1, pending_bank_d2;
	reg [Y_W-1:0] desired_y_r [0:MAX_LINES-1];
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
	async_fifo #(
		.WIDTH(8),
		.AW(2)
	) input_fifo (
		.wr_clk(clk),
		.wr_reset(reset),
		.wr_en(input_cmd_valid && (input_cmd != 8'd0)),
		.wr_data(input_cmd),
		.wr_full(),
		.wr_almost_full(),
		.rd_clk(clk_ddr),
		.rd_reset(reset),
		.rd_en(cmd_pop),
		.rd_data(cmd_rdata),
		.rd_empty(cmd_empty)
	);

	function automatic [Y_W-1:0] clamp_ahead(input [Y_W-1:0] base, input integer ahead);
		integer sum;
		begin
			sum = base + ahead;
			clamp_ahead = (sum >= FRAME_H) ? LAST_Y : sum[Y_W-1:0];
		end
	endfunction

	function automatic [28:0] row_qword_addr(input [Y_W-1:0] row);
		row_qword_addr = (row * FRAME_STRIDE) >> 2;
	endfunction

	integer ti, tj, tk;
	reg need_fill_cur_c, need_fill_prep_c, pending_ready_c;
	reg [Y_W-1:0] target_y_cur_c, target_y_prep_c;
	reg [4:0] target_idx_cur_c, target_idx_prep_c;
	reg found_line, slot_keep, found_slot_cur, found_slot_prep;
	reg [Y_W-1:0] desired_y;
	reg [4:0] cur_base_idx, prep_base_idx;
	always @* begin
		cur_base_idx = disp_buf_d2 ? SECOND_SET_BASE : 5'd0;
		prep_base_idx = disp_buf_d2 ? 5'd0 : SECOND_SET_BASE;
		need_fill_cur_c = 1'b0;
		need_fill_prep_c = 1'b0;
		target_y_cur_c = desired_y_r[0];
		target_y_prep_c = '0;
		target_idx_cur_c = cur_base_idx;
		target_idx_prep_c = prep_base_idx;
		found_slot_cur = 1'b0;
		found_slot_prep = 1'b0;
		pending_ready_c = 1'b1;

		for (ti = 0; ti < MAX_LINES; ti = ti + 1) begin
			if (ti < LINE_COUNT) begin
				desired_y = desired_y_r[ti];
				found_line = 1'b0;
				for (tj = 0; tj < MAX_LINES; tj = tj + 1) begin
					if (tj < LINE_COUNT && line_valid[cur_base_idx + tj[4:0]]
					    && (line_bank[cur_base_idx + tj[4:0]] == disp_bank_d2)
					    && (line_y[cur_base_idx + tj[4:0]] == desired_y))
						found_line = 1'b1;
				end
				if (!found_line && !need_fill_cur_c) begin
					need_fill_cur_c = 1'b1;
					target_y_cur_c = desired_y;
				end

				found_line = 1'b0;
				for (tj = 0; tj < MAX_LINES; tj = tj + 1) begin
					if (tj < LINE_COUNT && line_valid[prep_base_idx + tj[4:0]]
					    && (line_bank[prep_base_idx + tj[4:0]] == pending_bank_d2)
					    && (line_y[prep_base_idx + tj[4:0]] == ti[Y_W-1:0]))
						found_line = 1'b1;
				end
				if (swap_pending_d2 && !found_line) begin
					pending_ready_c = 1'b0;
					if (!need_fill_prep_c) begin
						need_fill_prep_c = 1'b1;
						target_y_prep_c = ti[Y_W-1:0];
					end
				end
			end
		end

		for (tj = 0; tj < MAX_LINES; tj = tj + 1) begin
			if (tj < LINE_COUNT) begin
				slot_keep = 1'b0;
				for (tk = 0; tk < MAX_LINES; tk = tk + 1) begin
					if (tk < LINE_COUNT && line_valid[cur_base_idx + tj[4:0]]
					    && (line_bank[cur_base_idx + tj[4:0]] == disp_bank_d2)
					    && (line_y[cur_base_idx + tj[4:0]] == desired_y_r[tk]))
						slot_keep = 1'b1;
				end
				if ((!line_valid[cur_base_idx + tj[4:0]] || !slot_keep) && !found_slot_cur) begin
					found_slot_cur = 1'b1;
					target_idx_cur_c = cur_base_idx + tj[4:0];
				end

				slot_keep = 1'b0;
				for (tk = 0; tk < MAX_LINES; tk = tk + 1) begin
					if (tk < LINE_COUNT && line_valid[prep_base_idx + tj[4:0]]
					    && (line_bank[prep_base_idx + tj[4:0]] == pending_bank_d2)
					    && (line_y[prep_base_idx + tj[4:0]] == tk[Y_W-1:0]))
						slot_keep = 1'b1;
				end
				if ((!line_valid[prep_base_idx + tj[4:0]] || !slot_keep) && !found_slot_prep) begin
					found_slot_prep = 1'b1;
					target_idx_prep_c = prep_base_idx + tj[4:0];
				end
			end
		end
	end

	reg need_fill_cur, need_fill_prep;
	reg [Y_W-1:0] target_y_cur, target_y_prep;
	reg [4:0] target_idx_cur, target_idx_prep;
	reg fill_bank, fill_pending_bank;
	reg [Y_W-1:0] fill_y;
	reg [4:0] fill_idx;
	reg [LINE_QW_AW:0] fill_qword;
	reg [LINE_QW_AW:0] burst_left;
	reg [LINE_QW_AW:0] qwords_remaining;
	reg [7:0] imbox_cmd_seq;
	reg [15:0] imbox_seq;

	wire [28:0] fill_bank_base = fill_bank ? BASE_W1 : BASE_W0;
	wire [28:0] line_addr = fill_bank_base + row_qword_addr(fill_y) + fill_qword[LINE_QW_AW-1:0];
	wire [LINE_QW_AW:0] burst_cap = (qwords_remaining > DDR_BURST_MAX) ? DDR_BURST_MAX[LINE_QW_AW:0] : qwords_remaining;
	wire [7:0] burst_this = burst_cap[7:0];
	wire db_magic_ok = poll_pending && DDRAM_DOUT_READY && (DDRAM_DOUT[31:0] == MAGIC);
	wire db_new_seq = db_magic_ok && (!have_seq || (DDRAM_DOUT[62:32] != last_seq));
	wire spi_edge_ddr = start_d2 != start_seen;
	assign debug_state = {LINE_COUNT[2:0], |line_valid, state_ddr};

	always @(posedge clk_ddr) begin
		if (reset) begin
			state_ddr <= S_IDLE;
			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;
			DDRAM_ADDR <= 29'd0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_DIN <= 64'd0;
			line_wr <= '0;
			line_wr_addr <= '0;
			line_wr_data <= 64'd0;
			line_valid <= '0;
			line_bank <= '0;
			for (ti = 0; ti < LINE_SLOTS; ti = ti + 1)
				line_y[ti] <= '0;
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
			for (ti = 0; ti < MAX_LINES; ti = ti + 1)
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
		end else begin
			if (!DDRAM_BUSY) begin
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
			end
			line_wr <= '0;
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
			for (ti = 0; ti < MAX_LINES; ti = ti + 1)
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
					need_fill_cur <= need_fill_cur_c;
					need_fill_prep <= need_fill_prep_c;
					target_y_cur <= target_y_cur_c;
					target_y_prep <= target_y_prep_c;
					target_idx_cur <= target_idx_cur_c;
					target_idx_prep <= target_idx_prep_c;
					pending_ready_ddr <= pending_ready_c;
					poll_div <= poll_div + 16'd1;
					if (need_fill_cur_c) begin
						fill_bank <= disp_bank_d2;
						fill_y <= target_y_cur_c;
						fill_idx <= target_idx_cur_c;
						line_valid[target_idx_cur_c] <= 1'b0;
						line_bank[target_idx_cur_c] <= disp_bank_d2;
						fill_qword <= '0;
						qwords_remaining <= LINE_QWORDS[LINE_QW_AW:0];
						state_ddr <= S_LINE_ISSUE;
					end else if (swap_pending_d2 && need_fill_prep_c) begin
						fill_bank <= pending_bank_d2;
						fill_y <= target_y_prep_c;
						fill_idx <= target_idx_prep_c;
						line_valid[target_idx_prep_c] <= 1'b0;
						line_bank[target_idx_prep_c] <= pending_bank_d2;
						fill_qword <= '0;
						qwords_remaining <= LINE_QWORDS[LINE_QW_AW:0];
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
						line_wr_addr <= fill_qword[LINE_QW_AW-1:0];
						line_wr_data <= DDRAM_DOUT;
						line_wr[fill_idx] <= 1'b1;
						fill_qword <= fill_qword + 1'b1;
						qwords_remaining <= qwords_remaining - 1'b1;
						burst_left <= burst_left - 1'b1;
						if (qwords_remaining == 1) begin
							line_y[fill_idx] <= fill_y;
							line_bank[fill_idx] <= fill_bank;
							line_valid[fill_idx] <= 1'b1;
							state_ddr <= S_IDLE;
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
