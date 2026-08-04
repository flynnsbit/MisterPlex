// Prove shared 720p DDR ABI selection (rd-duck BLOCKING / w-clock).
// Two probes: 640x480 → 480p bank; 1280x720 → 720p bank (no L4 macro).

module abi_probe_480 (
	output wire        use_720,
	output wire [31:0] phys,
	output wire [31:0] doorbell,
	output wire [31:0] stride,
	output wire [15:0] coded_w,
	output wire [15:0] line_count
);
	localparam int FRAME_W = 640;
	localparam int FRAME_H = 480;
	localparam int FRAME_LINE_COUNT = 8;
`include "ddr_frame_layout_params.svh"
`define DDR_FS_APPLY_LINE_FLOOR
`include "ddr_frame_abi_select.svh"
	assign use_720    = DDR_FS_USE_720P_ABI;
	assign phys       = DDR_FS_PHYS_BASE;
	assign doorbell   = DDR_FS_DOORBELL;
	assign stride     = 32'(DDR_FS_BANK_STRIDE);
	assign coded_w    = 16'(DDR_FS_CODED_W);
	assign line_count = 16'(DDR_FS_LINE_COUNT);
endmodule

module abi_probe_720 (
	output wire        use_720,
	output wire [31:0] phys,
	output wire [31:0] doorbell,
	output wire [31:0] stride,
	output wire [15:0] coded_w,
	output wire [15:0] line_count
);
	localparam int FRAME_W = 1280;
	localparam int FRAME_H = 720;
	localparam int FRAME_LINE_COUNT = 8;
`include "ddr_frame_layout_params.svh"
`define DDR_FS_APPLY_LINE_FLOOR
`include "ddr_frame_abi_select.svh"
	assign use_720    = DDR_FS_USE_720P_ABI;
	assign phys       = DDR_FS_PHYS_BASE;
	assign doorbell   = DDR_FS_DOORBELL;
	assign stride     = 32'(DDR_FS_BANK_STRIDE);
	assign coded_w    = 16'(DDR_FS_CODED_W);
	assign line_count = 16'(DDR_FS_LINE_COUNT);
endmodule

module ddr_frame_abi_select_tb_top (
	output wire        p480_use_720,
	output wire [31:0] p480_phys,
	output wire [31:0] p480_doorbell,
	output wire [31:0] p480_stride,
	output wire [15:0] p480_coded_w,
	output wire [15:0] p480_lines,
	output wire        p720_use_720,
	output wire [31:0] p720_phys,
	output wire [31:0] p720_doorbell,
	output wire [31:0] p720_stride,
	output wire [15:0] p720_coded_w,
	output wire [15:0] p720_lines
);
	abi_probe_480 u480 (
		.use_720(p480_use_720),
		.phys(p480_phys),
		.doorbell(p480_doorbell),
		.stride(p480_stride),
		.coded_w(p480_coded_w),
		.line_count(p480_lines)
	);
	abi_probe_720 u720 (
		.use_720(p720_use_720),
		.phys(p720_phys),
		.doorbell(p720_doorbell),
		.stride(p720_stride),
		.coded_w(p720_coded_w),
		.line_count(p720_lines)
	);
endmodule
