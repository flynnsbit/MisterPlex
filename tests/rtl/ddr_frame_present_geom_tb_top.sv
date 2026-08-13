// Dual-geometry present-window probe:
//   u480 — legacy 480p helper layout (hardcoded; product silicon is now 720p identity)
//   u720 — product/L4 720p layout from ddr_frame_layout_params.svh
//   u240 — 320x240 presented with identity coded/display (working glass path dims)
`include "ddr_frame_layout_params.svh"

module ddr_frame_present_geom_tb_top (
	input  wire [10:0] rd_x,
	input  wire [10:0] rd_y,
	input  wire  [2:0] fault_mode,
	// 480p product
	output wire        v480,
	output wire [15:0] s480_x,
	output wire [15:0] s480_y,
	output wire [31:0] b480_0,
	output wire [31:0] b480_1,
	output wire [31:0] b480_end,
	output wire [31:0] f480,
	output wire [31:0] d480,
	output wire [15:0] pe480_x,
	output wire [15:0] pe480_y,
	output wire [15:0] yq480,
	output wire [15:0] cq480,
	output wire [31:0] yoff480,
	output wire [31:0] uoff480,
	output wire [31:0] voff480,
	output wire [15:0] ys480,
	output wire [15:0] cs480,
	// 720p L4
	output wire        v720,
	output wire [15:0] s720_x,
	output wire [15:0] s720_y,
	output wire [31:0] b720_0,
	output wire [31:0] b720_1,
	output wire [31:0] b720_end,
	output wire [31:0] f720,
	output wire [31:0] d720,
	output wire [15:0] pe720_x,
	output wire [15:0] pe720_y,
	output wire [15:0] yq720,
	output wire [15:0] cq720,
	// 320x240 identity (glass-working dims)
	output wire        v240,
	output wire [15:0] pe240_x,
	output wire [15:0] pe240_y,
	output wire [31:0] f240,
	output wire [31:0] b240_end
);
	localparam [2:0] FAULT_NONE       = 3'd0;
	localparam [2:0] FAULT_CODED_640  = 3'd1;
	localparam [2:0] FAULT_PILLAR_10  = 3'd2;
	localparam [2:0] FAULT_PILLAR_12  = 3'd3;
	localparam [2:0] FAULT_LOST_ROW   = 3'd4;
	localparam [2:0] FAULT_EVEN_ROWS  = 3'd5;
	localparam [2:0] FAULT_DDR_DRIFT  = 3'd6;

	wire [9:0]  x480 = rd_x[9:0];
	wire [8:0]  y480 = rd_y[8:0];
	wire [10:0] x720 = rd_x;
	wire [9:0]  y720 = rd_y[9:0];
	wire [8:0]  x240 = rd_x[8:0];
	wire [7:0]  y240 = rd_y[7:0];

	wire        v480_good;
	wire        v480_p10;
	wire        v480_p12;
	wire [$clog2(624)-1:0] srcx480_good;
	wire [$clog2(480)-1:0] srcy480_good;
	wire [$clog2(624)-1:0] srcx480_p10;
	wire [$clog2(480)-1:0] srcy480_p10;
	wire [$clog2(624)-1:0] srcx480_p12;
	wire [$clog2(480)-1:0] srcy480_p12;
	wire [31:0] b480_0_good;
	wire [31:0] b480_1_good;
	wire [31:0] b480_end_good;
	wire [31:0] f480_good;
	wire [31:0] d480_good;
	wire [15:0] pe480_x_good;
	wire [15:0] pe480_y_good;
	wire [15:0] yq480_good;
	wire [15:0] cq480_good;
	wire [31:0] f480_c640;
	wire [31:0] yplane480_c640;
	wire [15:0] yq480_c640;
	wire [15:0] cq480_c640;
	wire [$clog2(1280)-1:0] srcx720;
	wire [$clog2(720)-1:0] srcy720;
	wire [$clog2(320)-1:0] srcx240;
	wire [$clog2(240)-1:0] srcy240;

	// Legacy 480p constants (not DDR_FRAME_* — those are product 1280×720).
	ddr_frame_present_geom #(
		.FRAME_W(640), .FRAME_H(480),
		.CODED_W(624),
		.CODED_H(480),
		.DISPLAY_W(618),
		.DISPLAY_H(480),
		.CROP_LEFT(0),
		.CROP_TOP(0),
		.PRESENT_X(11),
		.PRESENT_Y(0),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(32'h0008_0000),
		.DOORBELL_PHYS(32'h300F_F000)
	) u480 (
		.rd_x(x480), .rd_y(y480),
		.rd_visible(v480_good), .src_x(srcx480_good), .src_y(srcy480_good),
		.bank0_base_bytes(b480_0_good), .bank1_base_bytes(b480_1_good),
		.bank0_end_bytes(b480_end_good), .frame_bytes(f480_good),
		.y_plane_bytes(), .doorbell_bytes(d480_good),
		.present_end_x(pe480_x_good), .present_end_y(pe480_y_good),
		.y_line_qwords(yq480_good), .c_line_qwords(cq480_good)
	);

	ddr_frame_present_geom #(
		.FRAME_W(640), .FRAME_H(480),
		.CODED_W(DDR_FRAME_CODED_WIDTH), .CODED_H(DDR_FRAME_CODED_HEIGHT),
		.DISPLAY_W(DDR_FRAME_DISPLAY_WIDTH), .DISPLAY_H(DDR_FRAME_DISPLAY_HEIGHT),
		.CROP_LEFT(DDR_FRAME_CROP_LEFT), .CROP_TOP(DDR_FRAME_CROP_TOP),
		.PRESENT_X(10), .PRESENT_Y(0)
	) u480_pillar10 (
		.rd_x(x480), .rd_y(y480),
		.rd_visible(v480_p10), .src_x(srcx480_p10), .src_y(srcy480_p10),
		.bank0_base_bytes(), .bank1_base_bytes(), .bank0_end_bytes(), .frame_bytes(),
		.y_plane_bytes(), .doorbell_bytes(), .present_end_x(), .present_end_y(),
		.y_line_qwords(), .c_line_qwords()
	);

	ddr_frame_present_geom #(
		.FRAME_W(640), .FRAME_H(480),
		.CODED_W(DDR_FRAME_CODED_WIDTH), .CODED_H(DDR_FRAME_CODED_HEIGHT),
		.DISPLAY_W(DDR_FRAME_DISPLAY_WIDTH), .DISPLAY_H(DDR_FRAME_DISPLAY_HEIGHT),
		.CROP_LEFT(DDR_FRAME_CROP_LEFT), .CROP_TOP(DDR_FRAME_CROP_TOP),
		.PRESENT_X(12), .PRESENT_Y(0)
	) u480_pillar12 (
		.rd_x(x480), .rd_y(y480),
		.rd_visible(v480_p12), .src_x(srcx480_p12), .src_y(srcy480_p12),
		.bank0_base_bytes(), .bank1_base_bytes(), .bank0_end_bytes(), .frame_bytes(),
		.y_plane_bytes(), .doorbell_bytes(), .present_end_x(), .present_end_y(),
		.y_line_qwords(), .c_line_qwords()
	);

	ddr_frame_present_geom #(
		.FRAME_W(640), .FRAME_H(480),
		.CODED_W(640), .CODED_H(480),
		.DISPLAY_W(618), .DISPLAY_H(480),
		.CROP_LEFT(0), .CROP_TOP(0),
		.PRESENT_X(11), .PRESENT_Y(0)
	) u480_coded640 (
		.rd_x(x480), .rd_y(y480),
		.rd_visible(), .src_x(), .src_y(),
		.bank0_base_bytes(), .bank1_base_bytes(), .bank0_end_bytes(),
		.frame_bytes(f480_c640), .y_plane_bytes(yplane480_c640), .doorbell_bytes(),
		.present_end_x(), .present_end_y(),
		.y_line_qwords(yq480_c640), .c_line_qwords(cq480_c640)
	);

	wire select_p10 = (fault_mode == FAULT_PILLAR_10);
	wire select_p12 = (fault_mode == FAULT_PILLAR_12);
	wire select_c640 = (fault_mode == FAULT_CODED_640);
	wire select_ddr_drift = (fault_mode == FAULT_DDR_DRIFT);
	wire v480_selected = select_p10 ? v480_p10 : select_p12 ? v480_p12 : v480_good;
	wire [15:0] sx480_selected =
		select_p10 ? 16'(srcx480_p10) : select_p12 ? 16'(srcx480_p12) : 16'(srcx480_good);
	wire [15:0] sy480_selected =
		select_p10 ? 16'(srcy480_p10) : select_p12 ? 16'(srcy480_p12) : 16'(srcy480_good);
	assign v480 = (fault_mode == FAULT_LOST_ROW && rd_y == 11'd479) ? 1'b0 :
	              v480_selected;
	assign s480_x = sx480_selected;
	assign s480_y = (fault_mode == FAULT_EVEN_ROWS) ?
	                {sy480_selected[15:1], 1'b0} : sy480_selected;
	assign b480_0 = b480_0_good;
	assign b480_1 = select_ddr_drift ? b480_1_good + 32'd8 : b480_1_good;
	assign b480_end = b480_end_good;
	assign f480 = select_c640 ? f480_c640 : f480_good;
	assign d480 = select_ddr_drift ? d480_good + 32'd8 : d480_good;
	assign pe480_x = pe480_x_good;
	assign pe480_y = pe480_y_good;
	assign yq480 = select_c640 ? yq480_c640 : yq480_good;
	assign cq480 = select_c640 ? cq480_c640 : cq480_good;
	// The primary DDR_FRAME_* block is the 720p product layout. Keep this
	// legacy true480 probe explicit so changing the product default cannot
	// silently rewrite the 624x480 plane contract under test.
	assign yoff480 = 32'd0;
	assign uoff480 = select_c640 ? yplane480_c640 :
	                 select_ddr_drift ? 32'd299528 : 32'd299520;
	assign voff480 = select_c640 ? yplane480_c640 + (640 * 480 / 4) :
	                 32'd374400;
	assign ys480 = select_c640 || select_ddr_drift ? 16'd640 :
	               16'd624;
	assign cs480 = select_c640 || select_ddr_drift ? 16'd320 :
	               16'd312;

	ddr_frame_present_geom #(
		.FRAME_W(1280), .FRAME_H(720),
		.CODED_W(DDR_FRAME_720P_CODED_WIDTH),
		.CODED_H(DDR_FRAME_720P_CODED_HEIGHT),
		.DISPLAY_W(DDR_FRAME_720P_DISPLAY_WIDTH),
		.DISPLAY_H(DDR_FRAME_720P_DISPLAY_HEIGHT),
		.CROP_LEFT(0), .CROP_TOP(0),
		.PRESENT_X(DDR_FRAME_720P_PILLARBOX_LEFT),
		.PRESENT_Y(0),
		.PHYS_BASE(DDR_FRAME_720P_PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(DDR_FRAME_720P_YUV420P_BANK_STRIDE),
		.DOORBELL_PHYS(DDR_FRAME_720P_YUV420P_DOORBELL_PHYS)
	) u720 (
		.rd_x(x720), .rd_y(y720),
		.rd_visible(v720), .src_x(srcx720), .src_y(srcy720),
		.bank0_base_bytes(b720_0), .bank1_base_bytes(b720_1),
		.bank0_end_bytes(b720_end), .frame_bytes(f720),
		.y_plane_bytes(), .doorbell_bytes(d720),
		.present_end_x(pe720_x), .present_end_y(pe720_y),
		.y_line_qwords(yq720), .c_line_qwords(cq720)
	);
	assign s720_x = 16'(srcx720);
	assign s720_y = 16'(srcy720);

	// 320x240 identity: coded=display=presented, no pillar/crop (glass path dims)
	ddr_frame_present_geom #(
		.FRAME_W(320), .FRAME_H(240),
		.CODED_W(320), .CODED_H(240),
		.DISPLAY_W(320), .DISPLAY_H(240),
		.CROP_LEFT(0), .CROP_TOP(0),
		.PRESENT_X(0), .PRESENT_Y(0),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(32'h0004_0000),
		.DOORBELL_PHYS(32'h3007_F000)
	) u240 (
		.rd_x(x240), .rd_y(y240),
		.rd_visible(v240), .src_x(srcx240), .src_y(srcy240),
		.bank0_base_bytes(), .bank1_base_bytes(),
		.bank0_end_bytes(b240_end), .frame_bytes(f240),
		.y_plane_bytes(), .doorbell_bytes(),
		.present_end_x(pe240_x), .present_end_y(pe240_y),
		.y_line_qwords(), .c_line_qwords()
	);
endmodule
