// Dual-instance TB: PIPE_DEPTH=1 golden vs PIPE_DEPTH=2 DUT (+ fault twin).
// Bit-exact store_x/y/de_r with explicit latency offset.
// Quartus 17: no default port values.
`default_nettype none

module present_content_window_pipe_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	input  wire [10:0] hc,
	input  wire [10:0] py,
	input  wire        in_content,
	input  wire        win_enable,
	input  wire [10:0] content_w,
	input  wire [10:0] content_h,
	input  wire [10:0] content_x0,
	input  wire [10:0] content_y0,
	input  wire [10:0] h_de,
	input  wire [10:0] v_de,

	output wire [10:0] g_store_x,
	output wire [9:0]  g_store_y,
	output wire        g_de_r,
	output wire        g_past_last_row,
	output wire [3:0]  g_pipe_lat,

	output wire [10:0] d_store_x,
	output wire [9:0]  d_store_y,
	output wire        d_de_r,
	output wire        d_past_last_row,
	output wire [3:0]  d_pipe_lat,

	output wire [10:0] f_store_x,
	output wire [9:0]  f_store_y,
	output wire        f_de_r,
	output wire        f_past_last_row,
	output wire [3:0]  f_pipe_lat
);
	// Golden: original 1-stage pixel latency
	present_content_window #(
		.FRAME_W(1280),
		.FRAME_H(720),
		.STORE_W(1280),
		.STORE_H(720),
		.H_DE_DEFAULT(1280),
		.V_DE_DEFAULT(720),
		.PIPE_DEPTH(1),
		.FAULT_DROP_PIPE_BALANCE(1'b0)
	) u_golden (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix),
		.hc(hc),
		.py(py),
		.in_content(in_content),
		.win_enable(win_enable),
		.content_w(content_w),
		.content_h(content_h),
		.content_x0(content_x0),
		.content_y0(content_y0),
		.h_de(h_de),
		.v_de(v_de),
		.store_x(g_store_x),
		.store_y(g_store_y),
		.de_r(g_de_r),
		.past_last_row(g_past_last_row),
		.pipe_latency_ce(g_pipe_lat)
	);

	// DUT: pipelined default
	present_content_window #(
		.FRAME_W(1280),
		.FRAME_H(720),
		.STORE_W(1280),
		.STORE_H(720),
		.H_DE_DEFAULT(1280),
		.V_DE_DEFAULT(720),
		.PIPE_DEPTH(2),
		.FAULT_DROP_PIPE_BALANCE(1'b0)
	) u_dut (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix),
		.hc(hc),
		.py(py),
		.in_content(in_content),
		.win_enable(win_enable),
		.content_w(content_w),
		.content_h(content_h),
		.content_x0(content_x0),
		.content_y0(content_y0),
		.h_de(h_de),
		.v_de(v_de),
		.store_x(d_store_x),
		.store_y(d_store_y),
		.de_r(d_de_r),
		.past_last_row(d_past_last_row),
		.pipe_latency_ce(d_pipe_lat)
	);

	// Fault twin: claims depth 2 but drops balance → must NOT match golden@lag
	present_content_window #(
		.FRAME_W(1280),
		.FRAME_H(720),
		.STORE_W(1280),
		.STORE_H(720),
		.H_DE_DEFAULT(1280),
		.V_DE_DEFAULT(720),
		.PIPE_DEPTH(2),
		.FAULT_DROP_PIPE_BALANCE(1'b1)
	) u_fault (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix),
		.hc(hc),
		.py(py),
		.in_content(in_content),
		.win_enable(win_enable),
		.content_w(content_w),
		.content_h(content_h),
		.content_x0(content_x0),
		.content_y0(content_y0),
		.h_de(h_de),
		.v_de(v_de),
		.store_x(f_store_x),
		.store_y(f_store_y),
		.de_r(f_de_r),
		.past_last_row(f_past_last_row),
		.pipe_latency_ce(f_pipe_lat)
	);
endmodule

`default_nettype wire
