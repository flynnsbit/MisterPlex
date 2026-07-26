// SDRAM-backed RGB565 frame store.
// Write path: HPS/decoder pixels cross into the 100 MHz SDRAM controller.
// Read path: scanout uses two 320-pixel line buffers and prefetches one line
// ahead so the visible pixel path remains BRAM-like and edge timing is stable.

module frame_store #(
	parameter int WIDTH  = 320,
	parameter int HEIGHT = 240,
	parameter int REFRESH_CYCLES = 780,
	parameter int CMD_FIFO_AW = 5
)(
	input  wire        clk,
	input  wire        clk_sdram,
	input  wire        reset,

	// ---- write (ioctl / HPS) ----
	input  wire        wr_en,
	input  wire [15:0] wr_pixel,
	input  wire        wr_reset_ptr,
	output wire        wr_ready,
	output reg  [18:0] wr_count,
	output wire        wr_frame_done,

	// ---- read (present) ----
	input  wire [9:0]  rd_x,
	input  wire [9:0]  rd_y,
	input  wire        rd_active,
	output reg  [7:0]  rd_r,
	output reg  [7:0]  rd_g,
	output reg  [7:0]  rd_b,

	// ---- SDRAM controller port (clk_sdram domain) ----
	input  wire [15:0] sdram_dout,
	input  wire        sdram_ready,
	output reg         sdram_sel,
	output reg  [26:1] sdram_addr,
	output reg  [15:0] sdram_din,
	output reg         sdram_wr,
	output reg         sdram_rd,
	output wire  [1:0] sdram_bs,
	output reg         sdram_refresh,

	// ---- control ----
	input  wire        swap_banks,
	input  wire        vsync_pulse,
	output reg         has_frame,
	output reg         swap_pending,
	output reg  [15:0] underrun_count,
	output wire  [7:0] debug_state
);

	localparam int PIXELS = WIDTH * HEIGHT;
	localparam int ADDR_W = $clog2(PIXELS * 2);
	localparam [ADDR_W-1:0] PIXELS_WORDS = PIXELS;
	localparam [ADDR_W-1:0] BANK0_BASE = '0;
	localparam [ADDR_W-1:0] BANK1_BASE = PIXELS_WORDS;
	localparam [ADDR_W-1:0] LAST_WORD = PIXELS_WORDS - 1'b1;
	localparam [18:0] PIXELS_COUNT = PIXELS;
	localparam [18:0] LAST_COUNT = PIXELS_COUNT - 19'd1;
	localparam [9:0] WIDTH_W = WIDTH[9:0];
	localparam [9:0] HEIGHT_W = HEIGHT[9:0];
	localparam [15:0] REFRESH_LIMIT = REFRESH_CYCLES[15:0];
	localparam int SDRAM_ADDR_PAD = 26 - ADDR_W;

	localparam [1:0] CMD_PIXEL = 2'd0;
	localparam [1:0] CMD_RESET = 2'd1;
	localparam [1:0] CMD_SWAP  = 2'd2;

	assign sdram_bs = 2'b11;

	localparam int LINE_AW = $clog2(WIDTH);

	reg                 line0_wr, line1_wr;
	reg  [LINE_AW-1:0]  line_wr_addr;
	reg  [15:0]         line_wr_data;
	wire [15:0]         line0_q, line1_q;
	wire [9:0]          rd_x_clamped = (rd_x < WIDTH_W) ? rd_x : (WIDTH_W - 10'd1);
	wire [LINE_AW-1:0]  line_rd_addr = rd_x_clamped[LINE_AW-1:0];

	line_buf_ram #(
		.WIDTH(WIDTH),
		.AW(LINE_AW)
	) line0_ram (
		.wr_clk(clk_sdram),
		.wr_en(line0_wr),
		.wr_addr(line_wr_addr),
		.wr_data(line_wr_data),
		.rd_clk(clk),
		.rd_addr(line_rd_addr),
		.rd_data(line0_q)
	);

	line_buf_ram #(
		.WIDTH(WIDTH),
		.AW(LINE_AW)
	) line1_ram (
		.wr_clk(clk_sdram),
		.wr_en(line1_wr),
		.wr_addr(line_wr_addr),
		.wr_data(line_wr_data),
		.rd_clk(clk),
		.rd_addr(line_rd_addr),
		.rd_data(line1_q)
	);

	reg disp_bank;
	reg swap_commit_wait;
	wire cmd_full, cmd_almost_full, cmd_empty;
	wire [17:0] cmd_rdata;
	reg  cmd_pop;
	wire accept_cmd = !cmd_almost_full && !swap_pending && !swap_commit_wait;
	wire push_reset = wr_reset_ptr && accept_cmd;
	wire push_pixel = wr_en && accept_cmd;
	wire push_swap  = swap_banks && accept_cmd;
	wire cmd_push   = push_reset || push_pixel || push_swap;
	wire [17:0] cmd_wdata = push_reset ? {CMD_RESET, 16'd0} :
	                       push_swap  ? {CMD_SWAP,  16'd0} :
	                                    {CMD_PIXEL, wr_pixel};
	assign wr_ready = accept_cmd;
	assign wr_frame_done = push_pixel && (wr_count == LAST_COUNT);

	async_fifo #(
		.WIDTH(18),
		.AW(CMD_FIFO_AW)
	) cmd_fifo (
		.wr_clk(clk),
		.wr_reset(reset),
		.wr_en(cmd_push),
		.wr_data(cmd_wdata),
		.wr_full(cmd_full),
		.wr_almost_full(cmd_almost_full),
		.rd_clk(clk_sdram),
		.rd_reset(reset),
		.rd_en(cmd_pop),
		.rd_data(cmd_rdata),
		.rd_empty(cmd_empty)
	);
	wire _cmd_full_unused = cmd_full;

	reg swap_done_t_sdram;
	reg swap_done_s1, swap_done_s2, swap_done_seen;
	wire read_bank_sys = swap_pending ? ~disp_bank : disp_bank;
	always @(posedge clk) begin
		if (reset) begin
			disp_bank <= 1'b0;
			has_frame <= 1'b0;
			swap_pending <= 1'b0;
			swap_commit_wait <= 1'b0;
			wr_count <= 19'd0;
			swap_done_s1 <= 1'b0;
			swap_done_s2 <= 1'b0;
			swap_done_seen <= 1'b0;
		end else begin
			swap_done_s1 <= swap_done_t_sdram;
			swap_done_s2 <= swap_done_s1;

			if (push_reset)
				wr_count <= 19'd0;
			else if (push_pixel && wr_count < PIXELS_COUNT)
				wr_count <= wr_count + 19'd1;

			if (push_swap)
				swap_commit_wait <= 1'b1;
			if (swap_done_s2 != swap_done_seen) begin
				swap_done_seen <= swap_done_s2;
				swap_commit_wait <= 1'b0;
				swap_pending <= 1'b1;
			end
			if (vsync_pulse && swap_pending) begin
				disp_bank <= ~disp_bank;
				has_frame <= 1'b1;
				swap_pending <= 1'b0;
			end
		end
	end

	// Video-domain line-buffer read. Keep the old 3-cycle frame_store latency so
	// present_core's measured DE_LAG=3 remains valid.
	reg       rd_active_r;
	reg       hit0_r, hit1_r;
	reg [15:0] rd_q;
	reg        rd_active_d;
	reg        miss_d;
	reg [9:0] line0_y_v1, line0_y_v2, line1_y_v1, line1_y_v2;
	reg       line0_valid_v1, line0_valid_v2, line1_valid_v1, line1_valid_v2;

	reg [9:0] want_y_sys;
	reg [9:0] want_y_s1, want_y_s2;

	wire hit0_now = line0_valid_v2 && (line0_y_v2 == rd_y);
	wire hit1_now = line1_valid_v2 && (line1_y_v2 == rd_y);
	wire rd_miss_now = rd_active && has_frame && !(hit0_now || hit1_now);

	always @(posedge clk) begin
		if (reset) begin
			rd_active_r <= 1'b0;
			hit0_r <= 1'b0;
			hit1_r <= 1'b0;
			rd_q <= 16'd0;
			rd_active_d <= 1'b0;
			miss_d <= 1'b0;
			underrun_count <= 16'd0;
			want_y_sys <= 10'd0;
			{line0_valid_v1, line0_valid_v2, line1_valid_v1, line1_valid_v2} <= 4'd0;
		end else begin
			line0_valid_v1 <= line0_valid;
			line0_valid_v2 <= line0_valid_v1;
			line1_valid_v1 <= line1_valid;
			line1_valid_v2 <= line1_valid_v1;
			line0_y_v1 <= line0_y;
			line0_y_v2 <= line0_y_v1;
			line1_y_v1 <= line1_y;
			line1_y_v2 <= line1_y_v1;

			if (rd_y != want_y_sys) begin
				want_y_sys <= rd_y;
			end

			rd_active_r <= rd_active;
			hit0_r <= hit0_now;
			hit1_r <= hit1_now;
			miss_d <= rd_miss_now;
			if (hit0_r)
				rd_q <= line0_q;
			else if (hit1_r)
				rd_q <= line1_q;
			else
				rd_q <= 16'd0;
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

	// SDRAM-domain controller: line reads have priority; writes drain in the
	// slack and blanking windows. A 100 MHz controller at ~8 cycles/word fills
	// one 320-word line in ~25.6 us; the 20 MHz raster line is ~31.8 us, leaving
	// ~6 us before the next line needs the buffer.
	localparam [3:0] S_IDLE       = 4'd0;
	localparam [3:0] S_READ_ISSUE = 4'd1;
	localparam [3:0] S_READ_WAIT  = 4'd2;
	localparam [3:0] S_WRITE_ISSUE= 4'd3;
	localparam [3:0] S_WRITE_WAIT = 4'd4;
	localparam [3:0] S_SWAP       = 4'd5;

	reg [3:0] state_sdram;
	reg [ADDR_W-1:0] wr_addr_sdram;
	reg              wr_bank_sdram;
	reg [9:0]        fill_x;
	reg [9:0]        fill_y;
	reg              fill_buf;
	reg [15:0]       refresh_ctr;
	reg              line0_valid, line1_valid;
	reg [9:0]        line0_y, line1_y;
	reg              disp_bank_s1, disp_bank_s2;
	reg              read_bank_s1, read_bank_s2, read_bank_prev;
	reg [17:0]       cmd_hold;

	wire [9:0] want_y_next = (want_y_s2 == (HEIGHT_W - 10'd1)) ? want_y_s2 : (want_y_s2 + 10'd1);
	wire have_want = (line0_valid && line0_y == want_y_s2) || (line1_valid && line1_y == want_y_s2);
	wire have_next = (line0_valid && line0_y == want_y_next) || (line1_valid && line1_y == want_y_next);
	wire choose_current = !have_want;
	wire need_fill = !have_want || !have_next;
	wire [9:0] target_y = choose_current ? want_y_s2 : want_y_next;
	wire target_buf = (!line0_valid || (line0_y != want_y_s2 && line0_y != want_y_next)) ? 1'b0 : 1'b1;
	wire [ADDR_W-1:0] rd_base = read_bank_s2 ? BANK1_BASE : BANK0_BASE;
	wire [ADDR_W-1:0] wr_base = wr_bank_sdram ? BANK1_BASE : BANK0_BASE;
	wire [ADDR_W-1:0] read_word_addr = rd_base + (fill_y * WIDTH_W) + fill_x;

	assign debug_state = {1'b0, line1_valid, line0_valid, state_sdram};

	always @(posedge clk_sdram) begin
		if (reset) begin
			state_sdram <= S_IDLE;
			sdram_sel <= 1'b0;
			sdram_wr <= 1'b0;
			sdram_rd <= 1'b0;
			sdram_addr <= 26'd0;
			sdram_din <= 16'd0;
			line0_wr <= 1'b0;
			line1_wr <= 1'b0;
			line_wr_addr <= '0;
			line_wr_data <= 16'd0;
			sdram_refresh <= 1'b0;
			refresh_ctr <= 16'd0;
			wr_addr_sdram <= BANK1_BASE;
			wr_bank_sdram <= 1'b1;
			fill_x <= 10'd0;
			fill_y <= 10'd0;
			fill_buf <= 1'b0;
			line0_valid <= 1'b0;
			line1_valid <= 1'b0;
			line0_y <= 10'd0;
			line1_y <= 10'd0;
			disp_bank_s1 <= 1'b0;
			disp_bank_s2 <= 1'b0;
			read_bank_s1 <= 1'b0;
			read_bank_s2 <= 1'b0;
			read_bank_prev <= 1'b0;
			want_y_s1 <= 10'd0;
			want_y_s2 <= 10'd0;
			swap_done_t_sdram <= 1'b0;
			cmd_hold <= 18'd0;
			cmd_pop <= 1'b0;
		end else begin
			sdram_sel <= 1'b0;
			sdram_wr <= 1'b0;
			sdram_rd <= 1'b0;
			line0_wr <= 1'b0;
			line1_wr <= 1'b0;
			cmd_pop <= 1'b0;

			disp_bank_s1 <= disp_bank;
			disp_bank_s2 <= disp_bank_s1;
			read_bank_s1 <= read_bank_sys;
			read_bank_s2 <= read_bank_s1;
			want_y_s1 <= want_y_sys;
			want_y_s2 <= want_y_s1;

			if (refresh_ctr == REFRESH_LIMIT) begin
				refresh_ctr <= 16'd0;
				sdram_refresh <= ~sdram_refresh;
			end else begin
				refresh_ctr <= refresh_ctr + 16'd1;
			end

			if (read_bank_s2 != read_bank_prev) begin
				read_bank_prev <= read_bank_s2;
				line0_valid <= 1'b0;
				line1_valid <= 1'b0;
			end

			case (state_sdram)
				S_IDLE: begin
					if (need_fill) begin
						fill_y <= target_y;
						fill_x <= 10'd0;
						fill_buf <= target_buf;
						if (!target_buf) line0_valid <= 1'b0; else line1_valid <= 1'b0;
						state_sdram <= S_READ_ISSUE;
					end else if (!cmd_empty) begin
						cmd_hold <= cmd_rdata;
						cmd_pop <= 1'b1;
						case (cmd_rdata[17:16])
							CMD_RESET: begin
								wr_bank_sdram <= ~disp_bank_s2;
								wr_addr_sdram <= (~disp_bank_s2) ? BANK1_BASE : BANK0_BASE;
							end
							CMD_SWAP: state_sdram <= S_SWAP;
							default: state_sdram <= S_WRITE_ISSUE;
						endcase
					end
				end

				S_READ_ISSUE: begin
					if (sdram_ready) begin
						sdram_sel <= 1'b1;
						sdram_addr <= {{SDRAM_ADDR_PAD{1'b0}}, read_word_addr};
						sdram_rd <= 1'b1;
						state_sdram <= S_READ_WAIT;
					end
				end

				S_READ_WAIT: begin
					if (sdram_ready) begin
						line_wr_addr <= fill_x[LINE_AW-1:0];
						line_wr_data <= sdram_dout;
						line0_wr <= !fill_buf;
						line1_wr <= fill_buf;
						if (fill_x == (WIDTH_W - 10'd1)) begin
							if (!fill_buf) begin
								line0_y <= fill_y;
								line0_valid <= 1'b1;
							end else begin
								line1_y <= fill_y;
								line1_valid <= 1'b1;
							end
							state_sdram <= S_IDLE;
						end else begin
							fill_x <= fill_x + 10'd1;
							state_sdram <= S_READ_ISSUE;
						end
					end
				end

				S_WRITE_ISSUE: begin
					if (sdram_ready) begin
						sdram_sel <= 1'b1;
						sdram_addr <= {{SDRAM_ADDR_PAD{1'b0}}, wr_addr_sdram};
						sdram_din <= cmd_hold[15:0];
						sdram_wr <= 1'b1;
						state_sdram <= S_WRITE_WAIT;
					end
				end

				S_WRITE_WAIT: begin
					if (sdram_ready) begin
						wr_addr_sdram <= (wr_addr_sdram == (wr_base + LAST_WORD)) ?
						                 wr_base : (wr_addr_sdram + 1'b1);
						state_sdram <= S_IDLE;
					end
				end

				S_SWAP: begin
					swap_done_t_sdram <= ~swap_done_t_sdram;
					state_sdram <= S_IDLE;
				end

				default: state_sdram <= S_IDLE;
			endcase
		end
	end

endmodule
