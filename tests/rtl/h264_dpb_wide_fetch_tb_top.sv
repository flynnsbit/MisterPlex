`default_nettype none
module h264_dpb_wide_fetch_tb_top (
	input  wire clk,
	input  wire reset,
	// budget
	output wire [31:0] samples_per_p16_mb,
	output wire [31:0] byte_cycles_frame_p16,
	output wire [31:0] wide_beats_per_p16_mb,
	output wire [31:0] wide_cycles_frame_p16,
	output wire [31:0] frame_budget_cycles,
	output wire        byte_serial_meets_24fps,
	output wire        wide_beat_meets_24fps,
	output wire [31:0] i420_write_byte_cycles,
	output wire        i420_write_byte_meets_24fps,
	// part window
	input  wire [4:0]  part_w,
	input  wire [4:0]  part_h,
	output wire [15:0] part_total_samples,
	// wide fetch
	input  wire        start_w,
	output wire        done_w,
	output wire        busy_w,
	output wire [15:0] beats_w,
	output wire        luma_v_w,
	output wire [8:0]  luma_i_w,
	output wire [7:0]  luma_s_w,
	// fault byte-serial fetch
	input  wire        start_f,
	output wire        done_f,
	output wire        busy_f,
	output wire [15:0] beats_f
);
	h264_dpb_fetch_cycle_budget u_bud (
		.samples_per_p16_mb(samples_per_p16_mb),
		.byte_cycles_frame_p16(byte_cycles_frame_p16),
		.wide_beats_per_p16_mb(wide_beats_per_p16_mb),
		.wide_cycles_frame_p16(wide_cycles_frame_p16),
		.frame_budget_cycles(frame_budget_cycles),
		.byte_serial_meets_24fps(byte_serial_meets_24fps),
		.wide_beat_meets_24fps(wide_beat_meets_24fps),
		.i420_write_byte_cycles(i420_write_byte_cycles),
		.i420_write_byte_meets_24fps(i420_write_byte_meets_24fps)
	);

	h264_dpb_part_window_samples u_part (
		.part_w(part_w), .part_h(part_h),
		.luma_samples(), .chroma_plane_samples(),
		.total_samples(part_total_samples)
	);

	// simple mem model
	reg [7:0] mem [0:65535];
	wire mem_rd_w, mem_rd_f;
	wire [31:0] mem_ra_w, mem_ra_f;
	reg [63:0] mem_rd_data_w, mem_rd_data_f;
	reg mem_rv_w, mem_rv_f;
	reg pend_w, pend_f;
	reg [31:0] ra_w_q, ra_f_q;

	integer mi;
	always @(posedge clk) begin
		if (reset) begin
			for (mi = 0; mi < 65536; mi = mi + 1) mem[mi] = mi[7:0];
			mem_rv_w <= 1'b0;
			mem_rv_f <= 1'b0;
			pend_w <= 1'b0;
			pend_f <= 1'b0;
		end else begin
			mem_rv_w <= 1'b0;
			mem_rv_f <= 1'b0;
			if (mem_rd_w) begin
				pend_w <= 1'b1;
				ra_w_q <= mem_ra_w;
			end else if (pend_w) begin
				mem_rd_data_w <= {
					mem[(ra_w_q+7) & 32'hffff],
					mem[(ra_w_q+6) & 32'hffff],
					mem[(ra_w_q+5) & 32'hffff],
					mem[(ra_w_q+4) & 32'hffff],
					mem[(ra_w_q+3) & 32'hffff],
					mem[(ra_w_q+2) & 32'hffff],
					mem[(ra_w_q+1) & 32'hffff],
					mem[(ra_w_q+0) & 32'hffff]
				};
				mem_rv_w <= 1'b1;
				pend_w <= 1'b0;
			end
			if (mem_rd_f) begin
				pend_f <= 1'b1;
				ra_f_q <= mem_ra_f;
			end else if (pend_f) begin
				mem_rd_data_f <= {56'd0, mem[ra_f_q & 32'hffff]};
				mem_rv_f <= 1'b1;
				pend_f <= 1'b0;
			end
		end
	end

	h264_dpb_wide_window_fetch #(.FRAME_W(64), .FRAME_H(64), .FAULT_BYTE_SERIAL(1'b0)) u_w (
		.clk(clk), .reset(reset), .start(start_w),
		.ref_base(32'd0),
		.luma_ox(16'sd10), .luma_oy(16'sd10),
		.chroma_ox(16'sd5), .chroma_oy(16'sd5),
		.mem_rd(mem_rd_w), .mem_raddr(mem_ra_w),
		.mem_rdata(mem_rd_data_w), .mem_rvalid(mem_rv_w),
		.done(done_w), .busy(busy_w),
		.luma_window_valid(luma_v_w), .luma_window_idx(luma_i_w), .luma_window_sample(luma_s_w),
		.chroma_u_window_valid(), .chroma_v_window_valid(),
		.chroma_window_idx(), .chroma_window_sample(),
		.beats_issued(beats_w)
	);

	h264_dpb_wide_window_fetch #(.FRAME_W(64), .FRAME_H(64), .FAULT_BYTE_SERIAL(1'b1)) u_f (
		.clk(clk), .reset(reset), .start(start_f),
		.ref_base(32'd0),
		.luma_ox(16'sd10), .luma_oy(16'sd10),
		.chroma_ox(16'sd5), .chroma_oy(16'sd5),
		.mem_rd(mem_rd_f), .mem_raddr(mem_ra_f),
		.mem_rdata(mem_rd_data_f), .mem_rvalid(mem_rv_f),
		.done(done_f), .busy(busy_f),
		.luma_window_valid(), .luma_window_idx(), .luma_window_sample(),
		.chroma_u_window_valid(), .chroma_v_window_valid(),
		.chroma_window_idx(), .chroma_window_sample(),
		.beats_issued(beats_f)
	);
endmodule
`default_nettype wire
