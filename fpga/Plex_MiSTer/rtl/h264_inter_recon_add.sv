`default_nettype none
// clip(pred + residual) for one sample. Residual is post-IDCT (already >>6).
// FAULT_DROP_RESIDUAL forces recon=pred so a red twin cannot hide behind
// a zero-residual fixture.
module h264_inter_recon_add (
	input  wire [7:0]         pred,
	input  wire signed [15:0] residual,
	output wire [7:0]         recon
);
	function automatic [7:0] clip8;
		input signed [17:0] v;
		begin
			if (v < 18'sd0) clip8 = 8'd0;
			else if (v > 18'sd255) clip8 = 8'd255;
			else clip8 = v[7:0];
		end
	endfunction

`ifdef H264_INTER_RECON_FAULT_DROP_RESIDUAL
	wire signed [17:0] sum = {10'd0, pred};
`else
	wire signed [17:0] sum = {10'd0, pred} + {{2{residual[15]}}, residual};
`endif
	assign recon = clip8(sum);
endmodule

`default_nettype wire
