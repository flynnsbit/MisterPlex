`timescale 1ns/1ps
module fpga_audio_routing_tb;
	wire [15:0] left, right;
	wire [12:0] aspect_x, aspect_y;
	emu dut (
		.CLK_50M(1'b0), .RESET(1'b0), .CLK_AUDIO(1'b0),
		.AUDIO_L(left), .AUDIO_R(right),
		.VIDEO_ARX(aspect_x), .VIDEO_ARY(aspect_y)
	);

	initial begin
		// Inject only the legacy F2 contribution; no decoder/ALSA data or ACK is forced.
		force dut.al = 16'h1357;
		force dut.ar_audio = 16'hfedc;
		#1;
`ifdef FPGA_VIDEO_320
		assert(dut.spath.IDR_ONLY_PROFILE && dut.spath.VIDEO_FEATURES == 0 &&
		       dut.spath.ddr_stream.MAX_AU_BYTES == 65536 &&
		       dut.spath.mb_ctrl.RBSP_ADDR_W == 16 &&
		       dut.spath.mb_ctrl.NATIVE_PUBLISH_LEASE)
			else $fatal(1, "candidate profile/capability/capacity/lease mismatch");
		assert(left == 0 && right == 0)
			else $fatal(1, "legacy F2 PCM leaked into DMA-only mode");
		assert(dut.ddr_arb.g_held.m1_commands.USE_BLOCK_RAM == 1 &&
		       dut.ddr_arb.g_held.m1_responses.USE_BLOCK_RAM == 1)
			else $fatal(1, "FPGA transport did not select block RAM");
`else
		assert(left == 16'h1357 && right == 16'hfedc)
			else $fatal(1, "baseline core-audio routing changed");
		assert(dut.ddr_arb.g_held.m1_commands.USE_BLOCK_RAM == 0 &&
		       dut.ddr_arb.g_held.m1_responses.USE_BLOCK_RAM == 0)
			else $fatal(1, "baseline transport storage changed");
`endif
		release dut.al;
		release dut.ar_audio;
		// Inject collected PLXA metadata, exercising the real store/present/emu wiring.
		force dut.status[122:121] = 2'd0;
		force dut.present.has_frame = 1'b1;
		force dut.present.fstore.u_plxa.ack_x = 12'd16;
		force dut.present.fstore.u_plxa.ack_y = 12'd9;
		#1;
`ifdef FPGA_VIDEO_320
		assert(aspect_x == 16 && aspect_y == 9)
			else $fatal(1, "source DAR did not reach the native scaler");
`else
		assert(aspect_x == 4 && aspect_y == 3)
			else $fatal(1, "baseline aspect routing changed");
`endif
		force dut.present.fstore.u_plxa.ack_x = 12'd83;
		force dut.present.fstore.u_plxa.ack_y = 12'd50;
		#1;
`ifdef FPGA_VIDEO_320
		assert(aspect_x == 83 && aspect_y == 50)
			else $fatal(1, "custom source DAR was replaced by a standard ratio");
`else
		assert(aspect_x == 4 && aspect_y == 3)
			else $fatal(1, "custom source DAR changed baseline aspect");
`endif
		force dut.present.has_frame = 1'b0;
		#1;
		assert(aspect_x == 4 && aspect_y == 3)
			else $fatal(1, "idle picture inherited movie aspect");
		force dut.present.has_frame = 1'b1;
		force dut.present.fstore.u_plxa.ack_y = 12'd0;
		#1;
		assert(aspect_x == 4 && aspect_y == 3)
			else $fatal(1, "invalid source aspect reached the scaler");
		force dut.present.fstore.u_plxa.ack_y = 12'd50;
		force dut.present.fstore.u_plxa.ack_x = 12'd0;
		#1;
		assert(aspect_x == 4 && aspect_y == 3)
			else $fatal(1, "zero source aspect numerator reached the scaler");
		force dut.present.fstore.u_plxa.ack_x = 12'd83;
		force dut.status[122:121] = 2'd1;
		#1;
		assert(aspect_x == 0 && aspect_y == 0)
			else $fatal(1, "source aspect overrode fullscreen");
		force dut.status[122:121] = 2'd2;
		#1;
		assert(aspect_x == 1 && aspect_y == 0)
			else $fatal(1, "source aspect overrode custom aspect 1");
		force dut.status[122:121] = 2'd3;
		#1;
		assert(aspect_x == 2 && aspect_y == 0)
			else $fatal(1, "source aspect overrode custom aspect 2");
		release dut.status[122:121];
		release dut.present.has_frame;
		release dut.present.fstore.u_plxa.ack_x;
		release dut.present.fstore.u_plxa.ack_y;
		$display("PASS core audio/aspect routing; no ALSA/clock/hardware qualification");
		$finish;
	end
endmodule
