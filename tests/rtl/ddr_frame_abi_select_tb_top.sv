// TB: ddr_frame_abi_select compose — 480p default vs FRAME 1280×720 → 720p ABI.
// Negative: FRAME 640×480 must NOT select 720p banks.
module ddr_frame_abi_select_tb_top (
	output wire        p480_use_720,
	output wire [31:0] p480_phys,
	output wire [31:0] p480_stride,
	output wire [31:0] p480_doorbell,
	output wire [15:0] p480_coded_w,
	output wire        p720_use_720,
	output wire [31:0] p720_phys,
	output wire [31:0] p720_stride,
	output wire [31:0] p720_doorbell,
	output wire [15:0] p720_coded_w,
	output wire [15:0] p720_coded_h,
	output wire        p720_contract_phys_match
);
	// ---- 480p product canvas ----
	if (1) begin : g480
		localparam int FRAME_W = 640;
		localparam int FRAME_H = 480;
		`include "ddr_frame_layout_params.svh"
		`include "ddr_frame_abi_select.svh"
		assign p480_use_720 = DDR_FS_USE_720P_ABI;
		assign p480_phys = DDR_FS_PHYS_BASE;
		assign p480_stride = 32'(DDR_FS_BANK_STRIDE);
		assign p480_doorbell = DDR_FS_DOORBELL;
		assign p480_coded_w = 16'(DDR_FS_CODED_W);
	end

	// ---- 720p native canvas (L4 or MULTI) ----
	if (1) begin : g720
		localparam int FRAME_W = 1280;
		localparam int FRAME_H = 720;
		`include "ddr_frame_layout_params.svh"
		`include "ddr_frame_abi_select.svh"
		`include "plex_720p_bw_contract.svh"
		assign p720_use_720 = DDR_FS_USE_720P_ABI;
		assign p720_phys = DDR_FS_PHYS_BASE;
		assign p720_stride = 32'(DDR_FS_BANK_STRIDE);
		assign p720_doorbell = DDR_FS_DOORBELL;
		assign p720_coded_w = 16'(DDR_FS_CODED_W);
		assign p720_coded_h = 16'(DDR_FS_CODED_H);
		assign p720_contract_phys_match = (DDR_FS_PHYS_BASE == 32'(P720_PHYS_BASE));
	end
endmodule
