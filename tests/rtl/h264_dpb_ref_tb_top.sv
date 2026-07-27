`default_nettype none

module h264_dpb_ref_tb_top #(
	parameter bit FAULT_NO_EDGE_CLAMP = 1'b0,
	parameter bit FAULT_V_OFFSET_U = 1'b0
)(
	input  wire               clk,
	input  wire               reset,
	input  wire               wr_start,
	input  wire               fetch_start,
	input  wire               bank,
	input  wire [5:0]         mb_x,
	input  wire [4:0]         mb_y,
	input  wire signed [15:0] luma_x_qpel,
	input  wire signed [15:0] luma_y_qpel,
	input  wire signed [15:0] chroma_x_epel,
	input  wire signed [15:0] chroma_y_epel,
	input  wire               sample_valid,
	input  wire [7:0]         sample_data,
	output wire               wr_busy,
	output wire               wr_done,
	output wire               wr_valid,
	output wire [31:0]        wr_addr,
	output wire [7:0]         wr_data,
	output wire [1:0]         wr_plane,
	output wire               fetch_busy,
	output wire               fetch_done,
	output wire               req_valid,
	output wire [31:0]        req_addr,
	output wire [1:0]         req_plane,
	output wire [9:0]         req_index,
	output wire               out_valid,
	output wire [1:0]         out_plane,
	output wire [9:0]         out_index,
	output wire [7:0]         out_sample
);
	reg [7:0] y_samples [0:255];
	reg [7:0] u_samples [0:63];
	reg [7:0] v_samples [0:63];

	integer i;
	initial begin
		for (i = 0; i < 256; i = i + 1)
			y_samples[i] = 8'((i * 3 + 17) & 255);
		for (i = 0; i < 64; i = i + 1) begin
			u_samples[i] = 8'((i * 5 + 39) & 255);
			v_samples[i] = 8'((i * 7 + 73) & 255);
		end
	end

	h264_dpb_mb_writer writer (
		.clk(clk), .reset(reset), .start(wr_start), .bank(bank),
		.mb_x(mb_x), .mb_y(mb_y),
		.y_samples(y_samples), .u_samples(u_samples), .v_samples(v_samples),
		.busy(wr_busy), .done(wr_done), .out_valid(wr_valid),
		.out_addr(wr_addr), .out_data(wr_data), .out_plane(wr_plane)
	);

	h264_dpb_ref_fetch #(
		.FAULT_NO_EDGE_CLAMP(FAULT_NO_EDGE_CLAMP),
		.FAULT_V_OFFSET_U(FAULT_V_OFFSET_U)
	) fetch (
		.clk(clk), .reset(reset), .start(fetch_start), .bank(bank),
		.luma_x_qpel(luma_x_qpel), .luma_y_qpel(luma_y_qpel),
		.chroma_x_epel(chroma_x_epel), .chroma_y_epel(chroma_y_epel),
		.busy(fetch_busy), .done(fetch_done), .req_valid(req_valid),
		.req_addr(req_addr), .req_plane(req_plane), .req_index(req_index),
		.sample_valid(sample_valid), .sample_data(sample_data),
		.out_valid(out_valid), .out_plane(out_plane), .out_index(out_index),
		.out_sample(out_sample)
	);
endmodule

`default_nettype wire
