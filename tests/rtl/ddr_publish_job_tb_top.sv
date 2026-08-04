// TB: geom-bound publish job for 480p + 720p; negative 720p-on-480p stride.
module ddr_publish_job_tb_top (
	output wire [31:0] p480_dst0,
	output wire [31:0] p480_dst1,
	output wire [31:0] p480_fb,
	output wire        p480_legal,
	output wire [31:0] p720_dst0,
	output wire [31:0] p720_fb,
	output wire        p720_legal,
	output wire        p720_src_aligned,
	output wire        neg_legal
);
	ddr_publish_job #(
		.CODED_W(624), .CODED_H(480),
		.PHYS_BASE(32'h3000_0000),
		.BANK_STRIDE_BYTES(32'h0008_0000),
		.DOORBELL_PHYS(32'h300F_F000)
	) u480 (
		.bank_sel(1'b0), .src_phys(32'h3100_0000),
		.dst_bank_phys(p480_dst0), .frame_bytes(p480_fb),
		.doorbell_phys(), .job_legal(p480_legal), .src_aligned()
	);
	ddr_publish_job #(
		.CODED_W(624), .CODED_H(480),
		.PHYS_BASE(32'h3000_0000),
		.BANK_STRIDE_BYTES(32'h0008_0000),
		.DOORBELL_PHYS(32'h300F_F000)
	) u480b1 (
		.bank_sel(1'b1), .src_phys(32'h3100_0000),
		.dst_bank_phys(p480_dst1), .frame_bytes(),
		.doorbell_phys(), .job_legal(), .src_aligned()
	);
	ddr_publish_job #(
		.CODED_W(1280), .CODED_H(720),
		.PHYS_BASE(32'h3018_0000),
		.BANK_STRIDE_BYTES(32'h0018_0000),
		.DOORBELL_PHYS(32'h3047_F000)
	) u720 (
		.bank_sel(1'b0), .src_phys(32'h3060_1000), // staging-aligned
		.dst_bank_phys(p720_dst0), .frame_bytes(p720_fb),
		.doorbell_phys(), .job_legal(p720_legal), .src_aligned(p720_src_aligned)
	);
	// NEGATIVE: 720p geom on 480p stride → job_legal must be 0
	ddr_publish_job #(
		.CODED_W(1280), .CODED_H(720),
		.PHYS_BASE(32'h3000_0000),
		.BANK_STRIDE_BYTES(32'h0008_0000),
		.DOORBELL_PHYS(32'h0)
	) uneg (
		.bank_sel(1'b0), .src_phys(32'h3100_0000),
		.dst_bank_phys(), .frame_bytes(),
		.doorbell_phys(), .job_legal(neg_legal), .src_aligned()
	);
endmodule
