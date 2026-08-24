`default_nettype none
module h264_inter_recon_add_tb (
	input  wire [7:0]         pred,
	input  wire signed [15:0] residual,
	output wire [7:0]         recon
);
	h264_inter_recon_add dut (
		.pred(pred),
		.residual(residual),
		.recon(recon)
	);
endmodule
`default_nettype wire
