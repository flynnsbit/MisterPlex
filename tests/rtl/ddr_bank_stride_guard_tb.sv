// Standalone elab/sim oracle for ddr_bank_stride_guard (no #delay — pure t=0).
// GREEN: product CODED 624 + MAX 1280 + OPTC 0x180000; optional FRAME 1280.
// FAULT+SOFT: landmine MAX/FRAME 1280 with OPTC=LEG → overflow_fault=1.
// FAULT hard: generate $error fails compile.

module ddr_bank_stride_guard_tb;

`ifdef DDR_BANK_STRIDE_FAULT_720P_ON_LEGACY
	wire fault_landmine;
	ddr_bank_stride_guard #(
		.FRAME_W(1280),
		.FRAME_H(720),
		.CODED_W(624),
		.CODED_H(480),
		.MAX_W(1280),
		.MAX_H(720),
		.LEG_STRIDE(32'h0008_0000),
		.OPTC_STRIDE(32'h0008_0000)
	) u_landmine (
		.overflow_fault(fault_landmine)
	);

	initial begin
`ifdef DDR_BANK_STRIDE_GUARD_SOFT
		if (fault_landmine !== 1'b1) begin
			$display("FAIL landmine FAULT twin did not raise overflow_fault=%b", fault_landmine);
			$fatal(1);
		end
		$display("REPRO_OK silent_720p_on_512kib overflow_fault=1");
		$display("ARITH i420_720p=%0d leg_stride=%0d ratio_x100=%0d",
			1280*720*3/2, 32'h0008_0000, (1280*720*3/2 * 100) / 32'h0008_0000);
		$display("PASS ddr_bank_stride_guard_tb");
		$finish;
`else
		$display("FAIL hard FAULT reached sim without \$error");
		$fatal(1);
`endif
	end

`else
	wire fault_product;
	ddr_bank_stride_guard #(
		.FRAME_W(640),
		.FRAME_H(480),
		.CODED_W(624),
		.CODED_H(480),
		.MAX_W(1280),
		.MAX_H(720),
		.LEG_STRIDE(32'h0008_0000),
		.OPTC_STRIDE(32'h0018_0000)
	) u_product (
		.overflow_fault(fault_product)
	);

`ifdef DDR_BANK_STRIDE_TB_720P_FRAME
	wire fault_720_ok;
	ddr_bank_stride_guard #(
		.FRAME_W(1280),
		.FRAME_H(720),
		.CODED_W(624),
		.CODED_H(480),
		.MAX_W(1280),
		.MAX_H(720),
		.LEG_STRIDE(32'h0008_0000),
		.OPTC_STRIDE(32'h0018_0000)
	) u_720_ok (
		.overflow_fault(fault_720_ok)
	);
`endif

	initial begin
		if (fault_product !== 1'b0) begin
			$display("FAIL product dual-map guard raised overflow_fault=%b", fault_product);
			$fatal(1);
		end
`ifdef DDR_BANK_STRIDE_TB_720P_FRAME
		if (fault_720_ok !== 1'b0) begin
			$display("FAIL 1280x720 FRAME with 0x180000 raised overflow_fault=%b", fault_720_ok);
			$fatal(1);
		end
		$display("PASS_720P_FRAME stride=0x180000 fault=0");
`endif
		$display("PASS_PRODUCT dual_map fault=0");
		$display("ARITH i420_720p=%0d leg_usable=%0d optc_usable=%0d ratio_x100=%0d",
			1280*720*3/2, 32'h0007_F000, 32'h0017_F000,
			(1280*720*3/2 * 100) / 32'h0008_0000);
		$display("PASS ddr_bank_stride_guard_tb");
		$finish;
	end
`endif

endmodule
