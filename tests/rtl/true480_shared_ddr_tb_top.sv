`default_nettype none

module true480_shared_ddr_tb #(
	parameter int LINE_COUNT = 8,
	parameter int M1_GAP_SYS_CYCLES = 8,
	parameter bit M1_TRAFFIC_ENABLE = 1'b1,
	parameter int STALE_DOORBELL_FALLBACK_POLLS = 4096
)(
	input  wire        clk_sys,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire        m1_run,
	output wire        pixel_step,
	output wire [9:0]  beam_x,
	output wire [8:0]  beam_y,
	output wire        beam_active,
	output wire        beam_frame_start,
	output wire [7:0]  rd_r,
	output wire [7:0]  rd_g,
	output wire [7:0]  rd_b,
	output wire        has_frame,
	output wire [15:0] underrun_count,
	output wire [15:0] frames_done,
	output wire        doorbell_ok,
	output wire        obs_visible_now,
	output wire [9:0]  obs_src_x_now,
	output wire [8:0]  obs_src_y_now,
	output wire        obs_visible_pipe,
	output wire        obs_y_hit,
	output wire        obs_c_hit,
	output wire        obs_miss,
	output reg  [31:0] m1_want_cycles,
	output reg  [31:0] m1_reads_issued,
	output reg  [31:0] m1_responses_seen,
	output reg  [31:0] m1_protocol_errors,
	output wire [7:0]  cfg_line_count,
	output wire [31:0] cfg_linebuf_bits,
	output wire [15:0] cfg_m10k_estimate,
	output wire        cfg_active_config,
	output wire        cfg_native_beam_source,
	output wire [7:0]  cfg_y_fill_stride,
	output wire [31:0] cfg_stale_doorbell_fallback_polls,
	output wire        cfg_refill_telemetry,
	output wire        telem_fill_issue,
	output wire        telem_fill_complete,
	output wire        telem_fallback_fire,
	output wire        telem_fill_chroma,
	output wire        telem_fill_bank,
	output wire [8:0]  telem_fill_line,
	output wire [7:0]  telem_fill_slot,
	output wire        telem_issue_resident,
	output wire        telem_issue_any_resident,
	output wire        telem_issue_needed_current,
	output wire        telem_issue_needed_pending,
	output wire        telem_issue_need_combo,
	output wire        telem_issue_sched_replay,
	output wire        telem_issue_for_pending,
	output wire [8:0]  telem_desired_y0,
	output wire [8:0]  telem_desired_y7,
	output wire        telem_disp_bank,
	output wire        telem_swap_pending,
	output wire        telem_pending_bank,
	output wire [7:0]  store_debug_state,
	output wire        store_m0_rd,
	output wire        store_m0_we,
	output wire        store_m0_busy,
	output wire        test_m1_want,
	output wire        test_m1_busy,
	output wire        test_m1_rd,
	output wire        test_m1_we,
	output wire [1:0]  test_m1_state,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire [7:0]  DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire [7:0]  DDRAM_BE,
	output wire        DDRAM_WE
);
	localparam int CODED_W = 624;
	localparam int CODED_H = 480;
	localparam int Y_LINE_QWORDS = CODED_W / 8;
	localparam int C_LINE_QWORDS = CODED_W / 16;
	localparam int LINE_SLOTS = LINE_COUNT * 2;
	localparam int LINEBUF_BITS = LINE_SLOTS * (Y_LINE_QWORDS + 2 * C_LINE_QWORDS) * 64;
	// Cyclone V M10K simple/dual-port width is at most 40 bits. Each 64-bit
	// Y/U/V line RAM therefore consumes two blocks per slot.
	localparam int M10K_ESTIMATE = LINE_SLOTS * 3 * 2;

	assign cfg_line_count = 8'(LINE_COUNT);
	assign cfg_linebuf_bits = 32'(LINEBUF_BITS);
	assign cfg_m10k_estimate = 16'(M10K_ESTIMATE);
	assign cfg_stale_doorbell_fallback_polls =
	    32'(STALE_DOORBELL_FALLBACK_POLLS);

	wire pixel_step_i;
	wire [9:0] beam_x_i;
	wire [8:0] beam_y_i;
	wire beam_active_i;
	wire frame_start_i;
`ifdef PLEX_PRESENT_TRUE_480P
	wire native_hblank;
	wire native_hsync;
	wire native_vblank;
	wire native_vsync;
	wire [10:0] native_hc;
	wire [10:0] native_vc;
	present_beam_true_480p native_beam (
		.clk(clk_sys),
		.reset(reset),
		.ce_pix(pixel_step_i),
		.HBlank(native_hblank),
		.HSync(native_hsync),
		.VBlank(native_vblank),
		.VSync(native_vsync),
		.frame_start(frame_start_i),
		.hc_out(native_hc),
		.vc_out(native_vc)
	);
	assign beam_x_i = native_hc[9:0];
	assign beam_y_i = native_vc[8:0];
	assign beam_active_i = !native_hblank && !native_vblank;
	assign cfg_active_config = 1'b1;
	assign cfg_native_beam_source = 1'b1;
	assign cfg_y_fill_stride = 8'd1;
	wire _unused_native_sync = native_hsync | native_vsync;
`else
	reg ce_div;
	reg [9:0] beam_x_r;
	reg [8:0] beam_y_r;
	reg frame_start_r;
	always @(posedge clk_sys) begin
		frame_start_r <= 1'b0;
		if (reset) begin
			ce_div <= 1'b0;
			beam_x_r <= 10'd0;
			beam_y_r <= 9'd0;
		end else begin
			ce_div <= ~ce_div;
			if (ce_div) begin
				if (beam_x_r == 10'd671) begin
					beam_x_r <= 10'd0;
					if (beam_y_r == 9'd495) begin
						beam_y_r <= 9'd0;
						frame_start_r <= 1'b1;
					end else begin
						beam_y_r <= beam_y_r + 9'd1;
					end
				end else begin
					beam_x_r <= beam_x_r + 10'd1;
				end
			end
		end
	end
	assign pixel_step_i = ce_div;
	assign beam_x_i = beam_x_r;
	assign beam_y_i = beam_y_r;
	assign beam_active_i = (beam_x_r < 10'd640) && (beam_y_r < 9'd480);
	assign frame_start_i = frame_start_r;
	assign cfg_active_config = 1'b0;
	assign cfg_native_beam_source = 1'b0;
	assign cfg_y_fill_stride = 8'd0;
`endif
	assign pixel_step = pixel_step_i;
	assign beam_x = beam_x_i;
	assign beam_y = beam_y_i;
	assign beam_active = beam_active_i;
	assign beam_frame_start = frame_start_i;

	wire [9:0] store_rd_x = (beam_x_i < 10'd640) ? beam_x_i : 10'd639;
	wire [8:0] store_rd_y = (beam_y_i < 9'd480) ? beam_y_i : 9'd479;

	wire m0_busy;
	wire [7:0] m0_burstcnt;
	wire [28:0] m0_addr;
	wire [63:0] m0_dout;
	wire m0_dout_ready;
	wire m0_rd;
	wire [63:0] m0_din;
	wire [7:0] m0_be;
	wire m0_we;
	wire m0_clk;
	wire swap_pending;
	wire [7:0] debug_state;
	assign store_debug_state = debug_state;
	assign store_m0_rd = m0_rd;
	assign store_m0_we = m0_we;
	assign store_m0_busy = m0_busy;

	ddr_frame_store #(
		.FRAME_W(640),
		.FRAME_H(480),
		.FRAME_STRIDE(640),
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.DISPLAY_W(618),
		.DISPLAY_H(480),
		.CROP_LEFT(0),
		.CROP_TOP(0),
		.PRESENT_X(11),
		.PRESENT_Y(0),
		.LINE_COUNT(LINE_COUNT),
`ifdef PLEX_PRESENT_TRUE_480P
		.Y_FILL_STRIDE(1),
`endif
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(32'h0008_0000),
		.DOORBELL_PHYS(32'h300f_f000),
		.STALE_DOORBELL_FALLBACK_POLLS(STALE_DOORBELL_FALLBACK_POLLS)
	) store (
		.clk(clk_sys),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(store_rd_x),
		.rd_y(store_rd_y),
		.rd_active(beam_active_i),
		.rd_r(rd_r),
		.rd_g(rd_g),
		.rd_b(rd_b),
		.start_req(1'b0),
		.bank_sel(1'b0),
		.status_osd(16'd0),
		.input_cmd_valid(1'b0),
		.input_cmd(8'd0),
		.sdram_test_state(4'd0),
		.sdram_size_code(4'd0),
		.sdram_error_count(16'd0),
		.DDRAM_CLK(m0_clk),
		.DDRAM_BUSY(m0_busy),
		.DDRAM_BURSTCNT(m0_burstcnt),
		.DDRAM_ADDR(m0_addr),
		.DDRAM_DOUT(m0_dout),
		.DDRAM_DOUT_READY(m0_dout_ready),
		.DDRAM_RD(m0_rd),
		.DDRAM_DIN(m0_din),
		.DDRAM_BE(m0_be),
		.DDRAM_WE(m0_we),
		.vsync_pulse(frame_start_i),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(underrun_count),
		.frames_done(frames_done),
		.doorbell_ok(doorbell_ok),
		.debug_state(debug_state)
	);

	assign obs_visible_now = store.rd_visible;
	assign obs_src_x_now = store.src_x;
	assign obs_src_y_now = store.src_y;
	assign obs_visible_pipe = store.rd_visible_d;
	assign obs_y_hit = store.y_hit_r;
	assign obs_c_hit = store.c_hit_r;
	assign obs_miss = store.miss_d;

`ifdef PLEX_PRESENT_TRUE_480P
	reg telem_fill_issue_r;
	reg telem_fill_complete_r;
	reg telem_fallback_fire_r;
	reg telem_fill_chroma_r;
	reg telem_fill_bank_r;
	reg [8:0] telem_fill_line_r;
	reg [7:0] telem_fill_slot_r;
	reg telem_issue_resident_r;
	reg telem_issue_any_resident_r;
	reg telem_issue_needed_current_r;
	reg telem_issue_needed_pending_r;
	reg telem_issue_need_combo_r;
	reg telem_issue_sched_replay_r;
	reg telem_issue_for_pending_r;
	reg [3:0] telem_prev_state;
	reg telem_prev_sched_valid;
	reg telem_prev_sched_for_pending;
	reg telem_resident_now;
	reg telem_any_resident_now;
	reg telem_needed_current_now;
	reg telem_needed_pending_now;
	reg telem_need_combo_now;
	integer telem_i;

	always @* begin
		telem_resident_now = 1'b0;
		telem_any_resident_now = 1'b0;
		telem_needed_current_now = 1'b0;
		telem_needed_pending_now = 1'b0;
		telem_need_combo_now = 1'b0;
		for (telem_i = 0; telem_i < LINE_SLOTS; telem_i = telem_i + 1) begin
			if (store.fill_is_chroma) begin
				if (store.c_valid[telem_i] &&
				    store.c_bank[telem_i] == store.fill_bank &&
				    store.c_line[telem_i] == store.fill_cy)
					telem_any_resident_now = 1'b1;
			end else begin
				if (store.y_valid[telem_i] &&
				    store.y_bank[telem_i] == store.fill_bank &&
				    store.y_line[telem_i] == store.fill_y)
					telem_any_resident_now = 1'b1;
			end
		end
		if (store.fill_is_chroma) begin
			telem_resident_now =
			    store.c_valid[store.fill_idx] &&
			    store.c_bank[store.fill_idx] == store.fill_bank &&
			    store.c_line[store.fill_idx] == store.fill_cy;
		end else begin
			telem_resident_now =
			    store.y_valid[store.fill_idx] &&
			    store.y_bank[store.fill_idx] == store.fill_bank &&
			    store.y_line[store.fill_idx] == store.fill_y;
		end
		for (telem_i = 0; telem_i < LINE_COUNT; telem_i = telem_i + 1) begin
			if (store.fill_bank == store.disp_bank_d2) begin
				if (store.fill_is_chroma) begin
					if (store.fill_cy == store.desired_y_r[telem_i][8:1])
						telem_needed_current_now = 1'b1;
				end else if (store.fill_y == store.desired_y_r[telem_i]) begin
					telem_needed_current_now = 1'b1;
				end
			end
			if (store.swap_pending_d2 &&
			    store.fill_bank == store.pending_bank_d2) begin
				if (store.fill_is_chroma) begin
					if (store.fill_cy == telem_i[8:1])
						telem_needed_pending_now = 1'b1;
				end else if (store.fill_y == telem_i[8:0]) begin
					telem_needed_pending_now = 1'b1;
				end
			end
		end
		if (telem_prev_sched_for_pending) begin
			telem_need_combo_now = store.fill_is_chroma
			    ? (store.need_c_prep_c && store.target_c_prep_c == store.fill_cy)
			    : (store.need_y_prep_c && store.target_y_prep_c == store.fill_y);
		end else begin
			telem_need_combo_now = store.fill_is_chroma
			    ? (store.need_c_cur_c && store.target_c_cur_c == store.fill_cy)
			    : (store.need_y_cur_c && store.target_y_cur_c == store.fill_y);
		end
	end

	always @(posedge clk_ddr) begin
		telem_fill_issue_r <= 1'b0;
		telem_fill_complete_r <= 1'b0;
		if (reset) begin
			telem_fallback_fire_r <= 1'b0;
			telem_fill_chroma_r <= 1'b0;
			telem_fill_bank_r <= 1'b0;
			telem_fill_line_r <= 9'd0;
			telem_fill_slot_r <= 8'd0;
			telem_issue_resident_r <= 1'b0;
			telem_issue_any_resident_r <= 1'b0;
			telem_issue_needed_current_r <= 1'b0;
			telem_issue_needed_pending_r <= 1'b0;
			telem_issue_need_combo_r <= 1'b0;
			telem_issue_sched_replay_r <= 1'b0;
			telem_issue_for_pending_r <= 1'b0;
			telem_prev_state <= 4'd0;
			telem_prev_sched_valid <= 1'b0;
			telem_prev_sched_for_pending <= 1'b0;
		end else begin
			telem_fallback_fire_r <= store.db_stale_fallback;
			if (telem_prev_state == 4'd0 && store.state_ddr == 4'd5) begin
				telem_fill_issue_r <= 1'b1;
				telem_fill_chroma_r <= store.fill_is_chroma;
				telem_fill_bank_r <= store.fill_bank;
				telem_fill_line_r <= store.fill_is_chroma
				    ? {1'b0, store.fill_cy} : store.fill_y;
				telem_fill_slot_r <= 8'(store.fill_idx);
				telem_issue_resident_r <= telem_resident_now;
				telem_issue_any_resident_r <= telem_any_resident_now;
				telem_issue_needed_current_r <= telem_needed_current_now;
				telem_issue_needed_pending_r <= telem_needed_pending_now;
				telem_issue_need_combo_r <= telem_need_combo_now;
				telem_issue_sched_replay_r <= telem_prev_sched_valid;
				telem_issue_for_pending_r <= telem_prev_sched_for_pending;
			end
			if (telem_prev_state == 4'd2 && store.state_ddr == 4'd0) begin
				telem_fill_complete_r <= 1'b1;
				telem_fill_chroma_r <= store.fill_is_chroma;
				telem_fill_bank_r <= store.fill_bank;
				telem_fill_line_r <= store.fill_is_chroma
				    ? {1'b0, store.fill_cy} : store.fill_y;
				telem_fill_slot_r <= 8'(store.fill_idx);
			end
			telem_prev_state <= store.state_ddr;
			telem_prev_sched_valid <= store.sched_valid;
			telem_prev_sched_for_pending <= store.sched_for_pending;
		end
	end

	assign cfg_refill_telemetry = 1'b1;
	assign telem_fill_issue = telem_fill_issue_r;
	assign telem_fill_complete = telem_fill_complete_r;
	assign telem_fallback_fire = telem_fallback_fire_r;
	assign telem_fill_chroma = telem_fill_chroma_r;
	assign telem_fill_bank = telem_fill_bank_r;
	assign telem_fill_line = telem_fill_line_r;
	assign telem_fill_slot = telem_fill_slot_r;
	assign telem_issue_resident = telem_issue_resident_r;
	assign telem_issue_any_resident = telem_issue_any_resident_r;
	assign telem_issue_needed_current = telem_issue_needed_current_r;
	assign telem_issue_needed_pending = telem_issue_needed_pending_r;
	assign telem_issue_need_combo = telem_issue_need_combo_r;
	assign telem_issue_sched_replay = telem_issue_sched_replay_r;
	assign telem_issue_for_pending = telem_issue_for_pending_r;
	assign telem_desired_y0 = store.desired_y_r[0];
	assign telem_desired_y7 = store.desired_y_r[LINE_COUNT-1];
	assign telem_disp_bank = store.disp_bank_d2;
	assign telem_swap_pending = store.swap_pending_d2;
	assign telem_pending_bank = store.pending_bank_d2;
`else
	assign cfg_refill_telemetry = 1'b0;
	assign telem_fill_issue = 1'b0;
	assign telem_fill_complete = 1'b0;
	assign telem_fallback_fire = 1'b0;
	assign telem_fill_chroma = 1'b0;
	assign telem_fill_bank = 1'b0;
	assign telem_fill_line = 9'd0;
	assign telem_fill_slot = 8'd0;
	assign telem_issue_resident = 1'b0;
	assign telem_issue_any_resident = 1'b0;
	assign telem_issue_needed_current = 1'b0;
	assign telem_issue_needed_pending = 1'b0;
	assign telem_issue_need_combo = 1'b0;
	assign telem_issue_sched_replay = 1'b0;
	assign telem_issue_for_pending = 1'b0;
	assign telem_desired_y0 = 9'd0;
	assign telem_desired_y7 = 9'd0;
	assign telem_disp_bank = 1'b0;
	assign telem_swap_pending = 1'b0;
	assign telem_pending_bank = 1'b0;
`endif

	wire m1_busy;
	reg [7:0] m1_burstcnt;
	reg [28:0] m1_addr;
	wire [63:0] m1_dout;
	wire m1_dout_ready;
	reg m1_rd;
	reg [63:0] m1_din;
	reg [7:0] m1_be;
	reg m1_we;
	reg m1_want;
	reg [15:0] m1_gap;
	reg [1:0] m1_state;
	assign test_m1_want = m1_want;
	assign test_m1_busy = m1_busy;
	assign test_m1_rd = m1_rd;
	assign test_m1_we = m1_we;
	assign test_m1_state = m1_state;
	localparam [1:0] M1_GAP = 2'd0;
	localparam [1:0] M1_WAIT_GRANT = 2'd1;
	localparam [1:0] M1_ISSUE = 2'd2;
	localparam [1:0] M1_WAIT_RESPONSE = 2'd3;

	always @(posedge clk_sys) begin
		m1_rd <= 1'b0;
		m1_we <= 1'b0;
		if (reset) begin
			m1_burstcnt <= 8'd1;
			m1_addr <= 29'(32'h3010_0000 >> 3);
			m1_din <= 64'd0;
			m1_be <= 8'hff;
			m1_want <= 1'b0;
			m1_gap <= 16'd0;
			m1_state <= M1_GAP;
			m1_want_cycles <= 32'd0;
			m1_reads_issued <= 32'd0;
			m1_responses_seen <= 32'd0;
			m1_protocol_errors <= 32'd0;
		end else begin
			if (m1_want)
				m1_want_cycles <= m1_want_cycles + 32'd1;
			if (m1_dout_ready)
				m1_responses_seen <= m1_responses_seen + 32'd1;

			if (!M1_TRAFFIC_ENABLE || !m1_run) begin
				m1_want <= 1'b0;
				if (m1_state != M1_WAIT_RESPONSE)
					m1_state <= M1_GAP;
			end else begin
				case (m1_state)
				M1_GAP: begin
					m1_want <= 1'b0;
					if (m1_gap == 16'd0) begin
						m1_want <= 1'b1;
						m1_state <= M1_WAIT_GRANT;
					end else begin
						m1_gap <= m1_gap - 16'd1;
					end
				end
				M1_WAIT_GRANT: begin
					m1_want <= 1'b1;
					if (!m1_busy) begin
						m1_rd <= 1'b1;
						m1_reads_issued <= m1_reads_issued + 32'd1;
						m1_state <= M1_ISSUE;
					end
				end
				M1_ISSUE: begin
					m1_want <= 1'b1;
					m1_rd <= 1'b1;
					if (m1_busy)
						m1_state <= M1_WAIT_RESPONSE;
				end
				M1_WAIT_RESPONSE: begin
					m1_want <= 1'b1;
					if (m1_dout_ready) begin
						m1_want <= 1'b0;
						if (m1_addr == 29'((32'h3011_0000 >> 3) - 1))
							m1_addr <= 29'(32'h3010_0000 >> 3);
						else
							m1_addr <= m1_addr + 29'd1;
						m1_gap <= 16'(M1_GAP_SYS_CYCLES);
						m1_state <= M1_GAP;
					end
				end
				default: m1_state <= M1_GAP;
				endcase
			end
			if (m1_responses_seen > m1_reads_issued)
				m1_protocol_errors <= m1_protocol_errors + 32'd1;
		end
	end

	ddr_bus_arbiter arb (
		.clk(clk_ddr),
		.clk_m1(clk_sys),
		.reset(reset),
		.m1_want(m1_want),
		.m0_busy(m0_busy),
		.m0_burstcnt(m0_burstcnt),
		.m0_addr(m0_addr),
		.m0_dout(m0_dout),
		.m0_dout_ready(m0_dout_ready),
		.m0_rd(m0_rd),
		.m0_din(m0_din),
		.m0_be(m0_be),
		.m0_we(m0_we),
		.m1_busy(m1_busy),
		.m1_burstcnt(m1_burstcnt),
		.m1_addr(m1_addr),
		.m1_dout(m1_dout),
		.m1_dout_ready(m1_dout_ready),
		.m1_rd(m1_rd),
		.m1_din(m1_din),
		.m1_be(m1_be),
		.m1_we(m1_we),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE)
	);
endmodule

`default_nettype wire
