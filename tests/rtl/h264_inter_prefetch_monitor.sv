// Read-only observer for the existing p2 controller bench's synchronous BRAM.
// Not part of QIP/product RTL. Does not drive ready, responses, pixels or timing.
module h264_inter_prefetch_monitor (
	input wire clk, reset, frame_start, frame_done,
	input wire request, response_valid
);
	reg [31:0] requests, responses;
	reg prior_request, frame_done_d;
	always @(posedge clk) begin
		if (reset) begin
			requests<=0; responses<=0; prior_request<=0; frame_done_d<=0;
		end else begin
			prior_request<=request;
			frame_done_d<=frame_done;
			if (prior_request && !response_valid)
				$fatal(1,"controller benchmark BRAM lost an accepted fetch response");
			if (frame_start) begin requests<=0; responses<=0; end
			else begin
				if (request) requests<=requests+1'b1;
				if (prior_request && response_valid) responses<=responses+1'b1;
			end
			if (frame_done && !frame_done_d) begin
				if (requests != responses || prior_request || request)
					$fatal(1,"reference promotion before fetch traffic drained");
				$display("PREFETCH_TRAFFIC requests=%0d responses=%0d",requests,responses);
			end
		end
	end
endmodule

bind h264_dpb_one_ref h264_inter_prefetch_monitor u_prefetch_monitor (
	.clk(clk), .reset(reset), .frame_start(frame_start || idr_start),
	.frame_done(frame_done), .request(mem_rd && mem_rready), .response_valid(mem_rvalid)
);
