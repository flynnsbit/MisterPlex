`include "plex_performance_clock.svh"

module fpga_video_publish_tb #(
	parameter bit INTEGRATE_STREAM = 1'b0,
	parameter bit IDR_ONLY_PROFILE = 1'b0,
	parameter bit ENABLE_FRAME_DEBLOCK = 1'b0,
	parameter bit SYNC_MB_PLANES = 1'b1,
	parameter bit TEST_FILTER_METADATA_FAULT = 1'b0,
	parameter bit TEST_ACTIVE_FILTER_FAULT = 1'b0,
	parameter bit NATIVE_BEAM = 1'b0,
	parameter bit NATIVE_SCANDOUBLE = 1'b1,
	parameter int MAX_AU_BYTES = 8192
) (
	input wire clk,
	input wire clk_ddr,
	input wire reset,
	input wire clear,
	input wire inject_filter_metadata,
	input wire inject_active_filter_fault,
	input wire [63:0] nonce,
	input wire frame_valid,
	output wire frame_ready,
	input wire [63:0] session_id,
	input wire [31:0] seq,
	input wire signed [63:0] pts,
	input wire [31:0] tb_num,
	input wire [31:0] tb_den,
	input wire [15:0] test_width, test_height,
	input wire [15:0] test_left, test_right, test_top, test_bottom,
	output wire mem_rd,
	output wire [17:0] mem_addr,
	input wire [7:0] mem_data,
	input wire mem_valid,
	input wire vsync,
	input wire [8:0] sample_x,
	input wire [7:0] sample_y,
	output wire [23:0] pixel_rgb,
	output wire pixel_de,
	output wire native_ce, native_frame_start,
	output wire native_hs, native_vs,
	output wire overlay_ce, overlay_hs, overlay_vs, overlay_de,
	output wire [23:0] overlay_rgb,
	output wire [31:0] clock_sys_hz, clock_native_divisor,
	output wire idle,
	output wire error,
	output wire [31:0] count,
	output wire has_frame,
	output wire swap_pending,
	output wire [15:0] frames_done,
	output wire swap_toggle,
	output wire [4:0] publish_state,
	output wire pending_ready,
	output wire generation_idle,
	output wire [63:0] observed_nonce,
	output wire [63:0] observed_session,
	output wire published_bank,
	output wire published_native_bank,
	output wire observed_decoder_busy,
	output wire legacy_rgb_accept, legacy_full_range,
	output wire [7:0] legacy_matrix,
	output wire [15:0] legacy_rgb565,
	output wire [9:0] legacy_x, legacy_y,
	output wire [31:0] observed_au_seq,
	output wire [7:0] perf_events, perf_stalls,
	output wire filter_read_outstanding,
	output wire [31:0] active_filter_faults,
	output wire active_filter_owned_read_witness,
	output wire filter_meta_ready, filter_error, filter_busy,
	output wire [31:0] injected_filter_metadata_accepts,
	output wire [31:0] filter_starts, filter_completions, filter_stores, prediction_fetches,
	output wire stream_idle,
	output wire [31:0] stream_read_count,
	output wire [31:0] stream_bytes_out,
	output wire stream_reset_pending,
	output wire stream_transport_quiescent,
	output wire observed_au_active,
	output wire next_vcl_ready,
	output wire observed_vcl,
	output wire [4:0] decoder_phase,
	output wire [7:0] decoder_plane_state,
	output wire [7:0] decoder_error,
	output wire [15:0] decoder_mb,
	output wire [16:0] decoder_bit_pos,
	output wire [7:0] parameter_flags,
	output wire [31:0] coded_geometry,
	output wire [31:0] parameter_values,
	output wire [4:0] header_state,
	output wire [16:0] header_cursor,
	output wire [23:0] header_capture,
	output wire [4:0] native_transactions,
	output wire native_reference_ready,
	output wire [2:0] parser_errors,
	output wire controller_header_error,
	output wire decoded_picture_valid,
	output wire parameter_id_mismatch,
	output wire observed_codec_error_committed,
	output wire [7:0] observed_codec_error_code,
	output wire [15:0] geometry_width, geometry_height,
	output wire [15:0] geometry_left, geometry_right, geometry_top, geometry_bottom,
	output wire [15:0] reference_width, reference_height,
	output wire [31:0] native_sample_count,
	output wire [15:0] active_coded_width, active_coded_height,
	output wire [15:0] active_visible_width, active_visible_height,
	input wire DDRAM_BUSY,
	input wire [63:0] DDRAM_DOUT,
	input wire DDRAM_DOUT_READY,
	output wire [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire [7:0] DDRAM_BE,
	output wire DDRAM_WE
);
	assign clock_sys_hz = `PLEX_PERF_SYS_HZ;
	assign clock_native_divisor = `PLEX_PERF_SYS_MULT;
	wire swap_bank;
	assign published_bank = swap_bank;
	assign published_native_bank = publish.native_bank;
	assign publish_state = publish.state;
	wire p_want, p_rd, p_we, p_busy, p_ready;
	wire [28:0] p_addr;
	wire [63:0] p_din, p_dout;
	wire source_valid, source_bank, source_clear, source_mem_ready, source_mem_valid;
	wire source_codec_error, source_codec_error_pulse;
	wire [7:0] source_codec_error_code;
	assign observed_codec_error_code = source_codec_error_code;
	wire [63:0] source_session, source_nonce;
	wire [31:0] source_seq, source_num, source_den;
	wire signed [63:0] source_pts;
	wire [15:0] source_width, source_height;
	wire [15:0] source_left, source_right, source_top, source_bottom;
	wire [7:0] source_mem_data;
	wire a_want, a_rd, a_we, a_busy, a_ready;
	wire [28:0] a_addr;
	wire [63:0] a_din, a_dout;
	wire [7:0] a_be;
	assign observed_nonce = source_nonce;
	assign decoded_picture_valid = source_valid;
	generate
`ifdef FULL_AU_RTL
	if (INTEGRATE_STREAM) begin : decoded
		stream_path #(
			.ENABLE_AU_PROTOCOL(1'b1), .ENABLE_PICTURE_PUBLISH(1'b1),
			.MAX_AU_BYTES(MAX_AU_BYTES),
			.IDR_ONLY_PROFILE(IDR_ONLY_PROFILE),
			.ENABLE_FRAME_DEBLOCK(ENABLE_FRAME_DEBLOCK),
			.SYNC_MB_PLANES(SYNC_MB_PLANES),
			.VIDEO_FEATURES(32'd0)
		) stream (
			.clk(clk), .reset(reset),
			.ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_dout(8'd0),
			.enable(1'b0), .flush(clear), .ddr_stream_enable(1'b1),
			.ddr_bus_want(a_want), .ddr_busy(a_busy), .ddr_addr(a_addr),
			.ddr_dout(a_dout), .ddr_dout_ready(a_ready), .ddr_rd(a_rd),
			.ddr_din(a_din), .ddr_be(a_be), .ddr_we(a_we),
			.fs_wr_ready(1'b1), .fs_present_sel(1'b1), .fs_writes_idle(idle),
			.decoder_idle(stream_idle), .stream_ddr_fpga_read(stream_read_count),
			.next_vcl_ready(next_vcl_ready),
			.stream_ddr_bytes_out(stream_bytes_out),
			.video_reset_pending(stream_reset_pending),
			.transport_quiescent(stream_transport_quiescent),
			.current_au_valid(observed_au_active),
			.current_au_session_id(source_session), .current_au_seq(source_seq),
			.current_au_pts(source_pts), .current_au_timebase_num(source_num),
			.current_au_timebase_den(source_den), .video_nonce(source_nonce),
			.video_session_id(observed_session),
			.video_clear(source_clear), .picture_valid(source_valid),
			.codec_error_valid(source_codec_error),
			.codec_error_code(source_codec_error_code),
			.codec_error_pulse(source_codec_error_pulse),
			.codec_error_committed(observed_codec_error_committed),
			.picture_ready(frame_ready), .picture_bank(source_bank),
			.picture_coded_width(source_width), .picture_coded_height(source_height),
			.picture_crop_left(source_left), .picture_crop_right(source_right),
			.picture_crop_top(source_top), .picture_crop_bottom(source_bottom),
			.pub_mem_rd(mem_rd), .pub_mem_addr(mem_addr),
			.pub_mem_ready(source_mem_ready), .pub_mem_data(source_mem_data),
			.pub_mem_valid(source_mem_valid)
		);
		assign decoder_phase = stream.mb_ctrl.phase;
		assign decoder_plane_state = {SYNC_MB_PLANES,stream.mb_ctrl.plane_i,stream.mb_ctrl.plane_neighbor_step};
		assign observed_vcl = stream.vcl_pulse;
		assign decoder_error = stream.mb_decode_error;
		assign decoder_mb = stream.mb_ctrl.mb_index;
		assign decoder_bit_pos = stream.mb_ctrl.bit_pos;
		assign parameter_flags = {stream.sl_busy, stream.sps_busy, stream.pps_busy,
			stream.sl_bit_pos_valid, stream.sl_header_error, stream.slice_valid,
			stream.pps_valid, stream.sps_valid};
		assign coded_geometry = {stream.sps_coded_h, stream.sps_coded_w};
		assign reference_width = stream.mb_ctrl.u_dpb.reference_width;
		assign reference_height = stream.mb_ctrl.u_dpb.reference_height;
		assign native_sample_count = stream.mb_ctrl.we_n;
		assign parameter_values = {stream.log2_fn, stream.log2_poc, stream.poc_t,
			3'd0, stream.pps_nref_minus1, stream.pps_qp};
		assign header_state = stream.slp.bounded_header.parser.st;
		assign header_cursor = stream.slp.bounded_header.parser.pos;
		assign header_capture = {2'd0, stream.sps_cap_clear, stream.sps_cap_en,
			stream.sps_cap_end, stream.pps_cap_clear, stream.pps_cap_en,
			stream.pps_cap_end, stream.sps_cap_data, stream.pps_cap_data};
		assign native_transactions = {stream.pipeline_reset, stream.pub_mem_valid,
			stream.pub_read, stream.dpb_mem_rvalid, stream.dpb_read_accept};
		assign native_reference_ready = stream.mb_ctrl.dpb_ref_ready;
		assign parser_errors = {stream.sps.error, stream.pps.error, stream.sl_header_error};
		assign controller_header_error = stream.mb_ctrl.slice_error;
		assign parameter_id_mismatch = stream.sps_valid && stream.pps_valid &&
		                              stream.pps_sps_id != stream.active_sps_id;
		assign observed_decoder_busy = stream.mb_busy;
		assign legacy_rgb_accept = !stream.pipeline_reset && stream.mb_ctrl.wr_en && stream.mb_ctrl.wr_ready &&
			stream.mb_ctrl.present_sel && !stream.mb_ctrl.wr_reset_ptr && !stream.mb_ctrl.swap_req;
		assign legacy_rgb565 = stream.mb_ctrl.wr_pixel;
		assign legacy_x = stream.mb_ctrl.x, legacy_y = stream.mb_ctrl.y;
		assign legacy_full_range = stream.mb_ctrl.lat_full_range;
		assign legacy_matrix = stream.mb_ctrl.lat_matrix;
		assign observed_au_seq = source_seq;
		assign perf_events[0] = stream.mb_ctrl.dpb_frame_promoted;
		assign perf_events[1] = source_valid && frame_ready;
		assign perf_events[2] = stream.mb_ctrl.frame_filter_start;
		assign perf_events[3] = stream.mb_ctrl.frame_filter_done;
		assign perf_events[4] = stream.mb_ctrl.dpb_kick;
		assign perf_events[5] = stream.dpb_w_hit && stream.mb_ctrl.filter_owns_memory;
		assign perf_events[6] = stream.mb_ctrl.dpb_kick &&
			(stream.mb_ctrl.mv_kick_x[1:0] != 0 || stream.mb_ctrl.mv_kick_y[1:0] != 0);
		assign perf_events[7] = stream.mb_ctrl.coeff_store && !stream.mb_ctrl.is_intra_mb &&
			stream.mb_ctrl.cav_tc != 0;
		assign perf_stalls[0] = stream.mb_ctrl.phase == stream.mb_ctrl.ST_COMMIT &&
			!stream.mb_ctrl.commit_ready;
		assign perf_stalls[1] = mem_rd && !source_mem_ready;
		assign perf_stalls[2] = p_want && p_busy;
		assign perf_stalls[3] = a_want && a_busy;
		assign perf_stalls[4] = filter_busy && filter_read_outstanding;
		assign perf_stalls[5] = stream.au_collecting && !stream.au_bytes_complete;
		assign perf_stalls[6] = stream.mb_ctrl.phase == stream.mb_ctrl.ST_NATIVE_RELEASE;
		assign perf_stalls[7] = stream.scan.boundary_wait && !next_vcl_ready;
		reg [31:0] filter_start_count = 0, filter_done_count = 0;
		reg [31:0] filter_store_count = 0, prediction_fetch_count = 0;
		assign filter_starts = filter_start_count, filter_completions = filter_done_count;
		assign filter_stores = filter_store_count, prediction_fetches = prediction_fetch_count;
		always @(posedge clk) begin
			if (reset) begin
				filter_start_count <= 0; filter_done_count <= 0;
				filter_store_count <= 0; prediction_fetch_count <= 0;
			end else begin
				if (stream.mb_ctrl.frame_filter_start) filter_start_count <= filter_start_count + 1'b1;
				if (stream.mb_ctrl.frame_filter_done) filter_done_count <= filter_done_count + 1'b1;
				if (stream.dpb_w_hit && stream.mb_ctrl.filter_owns_memory)
					filter_store_count <= filter_store_count + 1'b1;
				if (stream.mb_ctrl.dpb_kick) prediction_fetch_count <= prediction_fetch_count + 1'b1;
			end
		end
		if (ENABLE_FRAME_DEBLOCK) begin : observe_filter
			assign filter_meta_ready = stream.mb_ctrl.frame_filter_meta_ready;
			assign filter_error = stream.mb_ctrl.frame_filter_error;
			assign filter_busy = stream.mb_ctrl.frame_filter_busy;
			assign filter_read_outstanding = stream.mb_ctrl.g_frame_deblock.u_filter.read_outstanding;
			if (TEST_ACTIVE_FILTER_FAULT) begin : inject_active_state
				reg held = 0, witnessed = 0;
				reg [31:0] faults = 0;
				assign active_filter_faults = faults;
				assign active_filter_owned_read_witness = witnessed;
				initial assert(!TEST_FILTER_METADATA_FAULT)
					else $fatal(1, "select one explicitly identified test fault");
				// Test-only unused-state upset while a real accepted BRAM read
				// awaits its consuming edge. The helper's default/error/drain
				// logic runs; neither error, response nor readiness is forced.
				always @(negedge clk) begin
					if (reset) begin
						release stream.mb_ctrl.g_frame_deblock.u_filter.state;
						held <= 0; witnessed <= 0; faults <= 0;
					end else if (inject_active_filter_fault) begin
						if (!held) begin
							assert(stream.mb_ctrl.phase == 29 && filter_busy &&
							       filter_read_outstanding && stream.dpb_mem_rvalid)
								else $fatal(1, "active fault lacked an owned in-flight filter read");
							witnessed <= 1;
							faults <= faults + 1'b1;
						end
						force stream.mb_ctrl.g_frame_deblock.u_filter.state = 4'd15;
						held <= 1;
					end else begin
						release stream.mb_ctrl.g_frame_deblock.u_filter.state;
						held <= 0;
					end
				end
			end else begin : no_active_fault
				assign active_filter_faults = 0, active_filter_owned_read_witness = 0;
				always @(posedge clk)
					assert(!inject_active_filter_fault)
						else $fatal(1, "active-state fault not enabled in this test build");
			end
			if (TEST_FILTER_METADATA_FAULT) begin : inject_metadata
				reg [31:0] accepted = 0;
				assign injected_filter_metadata_accepts = accepted;
				// Test-only bad producer metadata. The actual helper performs
				// admission/rejection; no READY, error output or ACK is forced.
				always @(negedge clk) begin
					if (inject_filter_metadata && !reset) begin
						force stream.mb_ctrl.g_frame_deblock.u_filter.meta_valid = 1'b1;
						force stream.mb_ctrl.g_frame_deblock.u_filter.meta_mode = 3'd7;
					end else begin
						release stream.mb_ctrl.g_frame_deblock.u_filter.meta_valid;
						release stream.mb_ctrl.g_frame_deblock.u_filter.meta_mode;
					end
				end
				always @(posedge clk) begin
					if (reset) accepted <= 0;
					else if (inject_filter_metadata && filter_meta_ready &&
					         stream.mb_ctrl.g_frame_deblock.u_filter.meta_valid) begin
						assert(stream.mb_ctrl.g_frame_deblock.u_filter.meta_mode == 7)
							else $fatal(1, "test metadata fault was not applied");
						accepted <= accepted + 1'b1;
					end
				end
			end else begin : no_metadata_fault
				assign injected_filter_metadata_accepts = 0;
				always @(posedge clk)
					assert(!inject_filter_metadata)
						else $fatal(1, "metadata injection not enabled in this test build");
			end
		end else begin : no_filter
			assign filter_meta_ready = 0, filter_error = 0, filter_busy = 0;
			assign filter_read_outstanding = 0;
			assign active_filter_faults = 0, active_filter_owned_read_witness = 0;
			assign injected_filter_metadata_accepts = 0;
			initial assert(!TEST_FILTER_METADATA_FAULT && !TEST_ACTIVE_FILTER_FAULT)
				else $fatal(1, "metadata fault test requires real filter helper");
		end
		always @(posedge clk) if (!reset && !stream.pipeline_reset) begin
			if (source_valid) begin
				assert(stream.mb_native_valid && !stream.mb_ctrl.frame_filter_busy)
					else $fatal(1, "publication preceded post-filter promotion");
				assert(source_bank == (stream.mb_native_base == 115200))
					else $fatal(1, "publication did not acquire promoted bank");
			end
			if (stream.native_copy_accepted) begin
				assert(!stream.vcl_pulse)
					else $fatal(1, "new VCL overwrote external native lease");
				if (stream.dpb_w_hit)
					assert((stream.dpb_mem_waddr >= 115200) != source_bank)
						else $fatal(1, "write into publisher-owned native bank");
			end
			if (stream.mb_native_release)
				assert(idle && !stream.pub_read && !stream.pub_mem_valid)
					else $fatal(1, "native lease released before external retirement");
		end
	end else
`endif
	begin : controlled
		assign stream_reset_pending = 1'b0;
		assign stream_transport_quiescent = 1'b1;
		assign observed_au_active = 1'b0;
		assign source_valid = frame_valid;
		assign source_bank = 1'b0;
		assign source_clear = clear;
		assign source_codec_error = 1'b0;
		assign source_codec_error_code = 0;
		assign source_codec_error_pulse = 1'b0;
		assign source_session = session_id;
		assign source_nonce = nonce;
		assign observed_session = session_id;
		assign observed_decoder_busy = 0, observed_au_seq = 0;
		assign legacy_rgb_accept = 0, legacy_full_range = 0, legacy_matrix = 0;
		assign legacy_rgb565 = 0, legacy_x = 0, legacy_y = 0;
		assign perf_events = 0, perf_stalls = 0, filter_read_outstanding = 0;
		assign active_filter_faults = 0, active_filter_owned_read_witness = 0;
		assign filter_meta_ready = 0, filter_error = 0, filter_busy = 0;
		assign injected_filter_metadata_accepts = 0;
		assign filter_starts = 0, filter_completions = 0, filter_stores = 0, prediction_fetches = 0;
		assign source_seq = seq;
		assign source_pts = pts;
		assign source_num = tb_num;
		assign source_den = tb_den;
		assign source_width = test_width; assign source_height = test_height;
		assign source_left = test_left; assign source_right = test_right;
		assign source_top = test_top; assign source_bottom = test_bottom;
		assign reference_width = 0; assign reference_height = 0;
		assign native_sample_count = 0;
		assign source_mem_ready = 1'b1;
		assign source_mem_data = mem_data;
		assign source_mem_valid = mem_valid;
		assign a_want = 1'b0;
		assign a_rd = 1'b0;
		assign a_we = 1'b0;
		assign a_addr = 29'd0;
		assign a_din = 64'd0;
		assign a_be = 8'hff;
		assign stream_idle = idle;
		assign stream_read_count = 32'd0;
		assign stream_bytes_out = 32'd0;
		assign next_vcl_ready = 1'b0;
		assign observed_vcl = 1'b0;
		assign decoder_phase = 5'd0;
		assign decoder_plane_state = 8'd0;
		assign decoder_error = 8'd0;
		assign decoder_mb = 16'd0;
		assign decoder_bit_pos = 17'd0;
		assign parameter_flags = 8'd0;
		assign coded_geometry = 32'd0;
		assign parameter_values = 32'd0;
		assign header_state = 5'd0;
		assign header_cursor = 17'd0;
		assign header_capture = 24'd0;
		assign native_transactions = 5'd0;
		assign native_reference_ready = 1'b0;
		assign parser_errors = 3'd0;
		assign controller_header_error = 1'b0;
		assign parameter_id_mismatch = 1'b0;
	end
	endgenerate
	fpga_video_publish #(.RUNTIME_GEOMETRY(1'b1)) publish (
		.clk(clk), .reset(reset), .clear(source_clear), .video_nonce(source_nonce),
		.codec_error_valid(source_codec_error), .codec_error_code(source_codec_error_code),
		.codec_error_committed(observed_codec_error_committed),
		.frame_valid(source_valid), .frame_ready(frame_ready), .frame_bank(source_bank),
		.frame_session_id(source_session), .frame_seq(source_seq), .frame_pts(source_pts),
		.frame_timebase_num(source_num), .frame_timebase_den(source_den),
		.frame_coded_width(source_width), .frame_coded_height(source_height),
		.frame_crop_left(source_left), .frame_crop_right(source_right),
		.frame_crop_top(source_top), .frame_crop_bottom(source_bottom),
		.display_coded_width(geometry_width), .display_coded_height(geometry_height),
		.display_crop_left(geometry_left), .display_crop_right(geometry_right),
		.display_crop_top(geometry_top), .display_crop_bottom(geometry_bottom),
		.mem_rd(mem_rd), .mem_addr(mem_addr), .mem_ready(source_mem_ready),
		.mem_data(source_mem_data), .mem_valid(source_mem_valid),
		.swap_toggle(swap_toggle), .swap_bank(swap_bank),
		.display_has_frame(has_frame), .display_frames_done(frames_done),
		.display_swap_pending(swap_pending), .idle(idle), .error(error),
		.display_clear_idle(generation_idle),
		.presentation_count(count),
		.bus_want(p_want), .bus_rd(p_rd), .bus_we(p_we), .bus_addr(p_addr),
		.bus_din(p_din), .bus_busy(p_busy), .bus_dout(p_dout), .bus_dout_ready(p_ready)
	);
	wire t_want, t_rd, t_we, t_busy, t_ready;
	wire [28:0] t_addr;
	wire [63:0] t_din, t_dout;
	wire [7:0] t_be;
	ddr_transport_mux mux (
		.clk(clk), .reset(reset),
		.a_want(a_want), .a_rd(a_rd), .a_we(a_we), .a_addr(a_addr), .a_din(a_din),
		.a_be(a_be), .a_busy(a_busy), .a_dout(a_dout), .a_dout_ready(a_ready),
		.b_want(p_want), .b_rd(p_rd), .b_we(p_we), .b_addr(p_addr), .b_din(p_din),
		.b_be(8'hff), .b_busy(p_busy), .b_dout(p_dout), .b_dout_ready(p_ready),
		.want(t_want), .rd(t_rd), .we(t_we), .addr(t_addr), .din(t_din), .be(t_be),
		.busy(t_busy), .dout(t_dout), .dout_ready(t_ready)
	);
	wire s_busy, s_ready, s_rd, s_we;
	wire [7:0] s_burst, s_be;
	wire [28:0] s_addr;
	wire [63:0] s_din, s_dout;
	generate
`ifdef DDR_FRAME_STORE
	if (NATIVE_BEAM) begin : native_output
		present_core #(
			.FRAME_W(320), .FRAME_H(240), .FRAME_STRIDE(320),
			.FPGA_DECODE_320(1'b1), .FRAME_LINE_COUNT(8)
		) presenter (
			.clk(clk), .clk_sdram(clk), .clk_audio(clk), .clk_pix(clk),
			.reset(reset), .pal(1'b0), .scandouble(NATIVE_SCANDOUBLE),
			.content_fps(8'd24), .display_hz(8'd60), .pattern(2'd0),
			.audio_en(1'b0), .use_frame_store(1'b0),
			.content_w(11'd0), .content_h(11'd0),
			.fs_wr_en(1'b0), .fs_wr_pixel(16'd0), .fs_wr_reset(1'b0), .fs_swap(1'b0),
			.generation_clear(source_clear || source_codec_error_pulse), .generation_idle(generation_idle),
			.sdram_dout(16'd0), .sdram_ready(1'b0),
			.ddr_start_req(swap_toggle), .ddr_bank_sel(swap_bank),
			.ddr_coded_width(geometry_width), .ddr_coded_height(geometry_height),
			.ddr_crop_left(geometry_left), .ddr_crop_right(geometry_right),
			.ddr_crop_top(geometry_top), .ddr_crop_bottom(geometry_bottom),
			.ddr_status_osd(16'd0), .ddr_input_cmd_valid(1'b0), .ddr_input_cmd(8'd0),
			.ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_dout(8'd0), .ioctl_index(16'd0),
			.ddr_sdram_test_state(4'd0), .ddr_sdram_size_code(4'd0), .ddr_sdram_error_count(16'd0),
			.clk_ddr(clk_ddr), .DDRAM_BUSY(s_busy), .DDRAM_BURSTCNT(s_burst),
			.DDRAM_ADDR(s_addr), .DDRAM_DOUT(s_dout), .DDRAM_DOUT_READY(s_ready),
			.DDRAM_RD(s_rd), .DDRAM_DIN(s_din), .DDRAM_BE(s_be), .DDRAM_WE(s_we),
			.ddr_frames_done(frames_done), .af_wr_en(1'b0), .af_wr_data(32'd0),
			.af_wr_flush(1'b0), .ce_pix(native_ce), .de_pix(pixel_de),
			.HSync(native_hs), .VSync(native_vs),
			.r(pixel_rgb[23:16]), .g(pixel_rgb[15:8]), .b(pixel_rgb[7:0]),
			.stat_has_frame(has_frame), .stat_swap_pending(swap_pending)
		);
		assign native_frame_start = presenter.frame_start;
		assign pending_ready = presenter.fstore.pending_ready_ddr;
		assign active_coded_width = presenter.fstore.active_coded_width;
		assign active_coded_height = presenter.fstore.active_coded_height;
		assign active_visible_width = presenter.fstore.visible_width;
		assign active_visible_height = presenter.fstore.visible_height;
	end else
`endif
	begin : sampled_output
	ddr_frame_store #(
		.FRAME_W(320), .FRAME_H(240), .FRAME_STRIDE(320),
		.CODED_W(320), .CODED_H(240), .DISPLAY_W(320), .DISPLAY_H(240),
		.HPS_BANK_STRIDE_BYTES(524288), .LINE_COUNT(8),
		.STRICT_YUV_DOORBELL(1'b0), .FPGA_PUBLISH_ONLY(1'b1),
		.RUNTIME_GEOMETRY(1'b1),
		.LIMITED_BT601(1'b1),
		.DDR_BURST_MAX(64)
	) store (
		.clk(clk), .clk_ddr(clk_ddr), .reset(reset),
		.generation_clear(source_clear || source_codec_error_pulse), .generation_idle(generation_idle),
		.rd_x(sample_x), .rd_y(sample_y), .rd_active(1'b1),
		.rd_r(pixel_rgb[23:16]), .rd_g(pixel_rgb[15:8]), .rd_b(pixel_rgb[7:0]),
		.rd_de(pixel_de),
		.start_req(swap_toggle), .bank_sel(swap_bank), .status_osd(16'd0),
		.picture_coded_width(geometry_width), .picture_coded_height(geometry_height),
		.picture_crop_left(geometry_left), .picture_crop_right(geometry_right),
		.picture_crop_top(geometry_top), .picture_crop_bottom(geometry_bottom),
		.input_cmd_valid(1'b0), .input_cmd(8'd0), .ioctl_download(1'b0),
		.ioctl_wr(1'b0), .ioctl_dout(8'd0), .ioctl_index(16'd0),
		.sdram_test_state(4'd0), .sdram_size_code(4'd0), .sdram_error_count(16'd0),
		.DDRAM_CLK(), .DDRAM_BUSY(s_busy), .DDRAM_BURSTCNT(s_burst),
		.DDRAM_ADDR(s_addr), .DDRAM_DOUT(s_dout), .DDRAM_DOUT_READY(s_ready),
		.DDRAM_RD(s_rd), .DDRAM_DIN(s_din), .DDRAM_BE(s_be), .DDRAM_WE(s_we),
		.vsync_pulse(vsync), .has_frame(has_frame), .swap_pending(swap_pending),
		.underrun_count(), .frames_done(frames_done), .doorbell_ok(), .debug_state()
	);
	assign active_coded_width = store.active_coded_width;
	assign active_coded_height = store.active_coded_height;
	assign active_visible_width = store.visible_width;
	assign active_visible_height = store.visible_height;
	assign pending_ready = store.pending_ready_ddr;
	assign native_ce = 1'b0;
	assign native_frame_start = 1'b0;
	assign native_hs = 1'b0, native_vs = vsync;
	end
	endgenerate
	playback_overlay_plane overlay_timing (
		.clk_sys(clk), .clk_pix(clk), .reset(reset),
		.session_active(observed_session != 0 && !stream_reset_pending && !source_clear),
		.session_epoch(observed_session), .session_nonce(source_nonce),
		.ioctl_download(1'b0), .ioctl_index(16'd6), .ioctl_wr(1'b0),
		.ioctl_addr(27'd0), .ioctl_dout(8'd0), .ioctl_wait(),
		.accepted_sequence(), .rejected_packets(),
		.ce_in(native_ce), .r_in(pixel_rgb[23:16]), .g_in(pixel_rgb[15:8]), .b_in(pixel_rgb[7:0]),
		.hs_in(native_hs), .vs_in(native_vs), .de_in(pixel_de),
		.ce_out(overlay_ce), .r_out(overlay_rgb[23:16]), .g_out(overlay_rgb[15:8]), .b_out(overlay_rgb[7:0]),
		.hs_out(overlay_hs), .vs_out(overlay_vs), .de_out(overlay_de), .visible()
	);
	ddr_bus_arbiter #(.M1_HELD_REQUESTS(1'b1)) arb (
		.clk(clk_ddr), .clk_m1(clk), .reset(reset), .m1_want(t_want),
		.m0_busy(s_busy), .m0_burstcnt(s_burst), .m0_addr(s_addr),
		.m0_dout(s_dout), .m0_dout_ready(s_ready), .m0_rd(s_rd),
		.m0_din(s_din), .m0_be(s_be), .m0_we(s_we),
		.m1_busy(t_busy), .m1_burstcnt(8'd1), .m1_addr(t_addr),
		.m1_dout(t_dout), .m1_dout_ready(t_ready), .m1_rd(t_rd),
		.m1_din(t_din), .m1_be(t_be), .m1_we(t_we),
		.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
	);
endmodule
