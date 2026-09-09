`timescale 1fs/1fs
module scaler_config_tb;
	parameter integer SYS_MHZ = 85;
	parameter integer PHASE = 37;
	reg clk=0, reset=0, io_uio=0, io_strobe=0;
	reg [15:0] io_din=0;
	reg [11:0] width=1920, height=1080, hset=0, vset=0;
	reg [12:0] source_arx=4, source_ary=3;
	reg repeat_pixel=0, free_scale=0;
	wire [125:0] lfb;
	wire [269:0] data;
	wire req;
	reg ack=0;
	wire [11:0] hdmi_width, hdmi_height, arx, ary;
	wire arxy;
	scaler_config dut(
		.clk(clk), .reset(reset), .io_uio(io_uio), .io_strobe(io_strobe), .io_din(io_din),
		.width(width), .height(height), .hfp(12'd88), .hs(12'd44), .hbp(12'd148),
		.vfp(12'd4), .vs(12'd5), .vbp(12'd36), .pixel_repeat(repeat_pixel), .vrr(1'b0),
		.freescale(free_scale), .hset(hset), .vset(vset),
		.source_arx(source_arx), .source_ary(source_ary),
		.arc1x(13'd16), .arc1y(13'd9), .arc2x(13'h1100), .arc2y(13'h10e0),
		.lowlat(1'b0), .filter(3'd0), .freeze(1'b0), .bob_deint(1'b0),
		.swblack(1'b0), .pal_n(1'b0), .core_fb_en(1'b0), .core_fb_format(6'd4),
		.core_fb_width(12'd320), .core_fb_height(12'd240),
		.core_fb_base(32'h20000000), .core_fb_stride(14'd640),
		.lfb_config(lfb), .hdmi_width(hdmi_width), .hdmi_height(hdmi_height),
		.arx(arx), .ary(ary), .arxy(arxy), .cfg_data(data), .cfg_req(req), .cfg_ack(ack)
	);
	longint unsigned remainder_fs=0, delay_fs;
	always begin
		delay_fs=(1000000000+remainder_fs)/(2*SYS_MHZ);
		remainder_fs=(1000000000+remainder_fs)%(2*SYS_MHZ);
		#(delay_fs) clk=~clk;
	end
	task automatic tick(input integer count=1);
		repeat(count) @(negedge clk);
	endtask
	task automatic word(input reg [15:0] value);
		io_din=value; io_strobe=1; tick(); io_strobe=0; tick();
	endtask
	task automatic begin_command(input reg [7:0] cmd);
		io_uio=1; word({8'b0,cmd});
	endtask
	task automatic end_command;
		io_uio=0; tick(3);
	endtask
	task automatic await_request(input reg prior);
		integer n;
		n=0;
		while(req==prior && n<1000) begin tick(); n=n+1; end
		assert(req!=prior) else $fatal(1,"descriptor did not arrive");
	endtask
	task automatic accept;
		#(PHASE*1000) ack=req; tick(5);
	endtask
	task automatic window(input integer xmin,xmax,ymin,ymax);
		assert(data[221:210]==xmin && data[209:198]==xmax &&
			data[149:138]==ymin && data[137:126]==ymax)
			else $fatal(1,"window got %d..%d,%d..%d expected %d..%d,%d..%d",
				data[221:210],data[209:198],data[149:138],data[137:126],xmin,xmax,ymin,ymax);
	endtask
	task automatic lfb_update(input reg [31:0] base, input reg [5:0] fmt,
		input integer xmin,xmax,ymin,ymax,stride);
		reg [125:0] old_lfb;
		old_lfb=lfb;
		begin_command(8'h2f);
		word(16'h8000 | {10'b0,fmt});
		word(base[15:0]); word(base[31:16]);
		word(16'd320); word(16'd240);
		word(16'(xmin)); word(16'(xmax)); word(16'(ymin)); word(16'(ymax)); word(16'(stride));
		assert(lfb==old_lfb) else $fatal(1,"0x2f escaped before deselection");
		end_command();
	endtask
	initial begin : run
		reg phase_req;
		reg [269:0] held;
		reg [125:0] prior_lfb;
		integer cases;
		cases=0;
		tick(); reset=1; tick(3); reset=0; tick(3);
		await_request(0); window(240,1679,0,1079);
		assert(data[269:258]==2200 && data[197:186]==1125) else $fatal;
		held=data; phase_req=req;
		lfb_update(32'h34567803,6'd5,0,479,0,1079,1024);
		tick(180);
		assert(req==phase_req && data==held) else $fatal(1,"held data changed before ACK");
		accept(); await_request(phase_req); window(0,479,0,1079);
		assert(data[104] && data[79:74]==5 && data[73:42]==32'h34567803 &&
			data[41:28]==1024) else $fatal(1,"format/base/stride tuple");
		cases++;

		held=data; phase_req=req;
		lfb_update(32'h56789006,6'd4,1440,1919,100,339,672);
		assert(data==held && req==phase_req) else $fatal(1,"enabled move tore pending tuple");
		accept(); await_request(phase_req); window(1440,1919,100,339);
		assert(data[79:74]==4 && data[73:42]==32'h56789006 && data[41:28]==672) else $fatal;
		cases++;

		// The display clock can stop indefinitely. Complete pending commands
		// may supersede unsent state, never the already submitted descriptor.
		held=data; phase_req=req;
		lfb_update(32'h6789a003,6'd3,64,383,16,255,320);
		lfb_update(32'h789ab00c,6'd6,32,671,8,487,1280);
		tick(1000); assert(data==held && req==phase_req) else $fatal;
		accept(); await_request(phase_req); window(32,671,8,487);
		assert(data[79:74]==6 && data[73:42]==32'h789ab00c) else $fatal;
		cases++;

		phase_req=req; accept(); prior_lfb=lfb;
		begin_command(8'h2f); word(16'h0006); end_command();
		assert(lfb[117:0]==prior_lfb[117:0] && !lfb[125]) else $fatal(1,"short disable");
		await_request(phase_req); window(240,1679,0,1079);
		phase_req=req; accept();
		begin_command(8'h2f); word(16'h8006); end_command();
		await_request(phase_req); window(32,671,8,487);
		assert(data[73:42]==32'h789ab00c && data[41:28]==1280) else $fatal(1,"short enable");
		cases+=2;

		// Reset cancels a partial command and an unacknowledged request; the
		// latest completed settings are retransmitted with a fresh reset epoch.
		prior_lfb=lfb;
		begin_command(8'h2f); word(16'h8004); word(16'hbeef);
		reset=1; ack=0; tick(2); reset=0;
		word(16'hdead); end_command();
		assert(lfb==prior_lfb) else $fatal(1,"reset committed partial command");
		await_request(0); window(32,671,8,487); accept();
		phase_req=req; prior_lfb=lfb;
		begin_command(8'h2f); end_command(); tick(180);
		assert(lfb==prior_lfb && req==phase_req) else $fatal(1,"empty command");
		cases+=2;

		begin_command(8'h2f); word(16'h0006); end_command();
		await_request(phase_req); phase_req=req; accept();
		// Resolve both custom ratio and explicit-size AR forms, and capture
		// the entire computation before a following command changes inputs.
		source_arx=1; source_ary=0; tick(3);
		await_request(phase_req); window(0,1919,0,1079); phase_req=req; accept();
		source_arx=2; tick(3);
		await_request(phase_req); window(832,1087,428,651); phase_req=req; accept();
		free_scale=1; hset=1280; vset=720; tick(3);
		await_request(phase_req); window(320,1599,180,899); phase_req=req; accept();
		repeat_pixel=1; hset=640; tick(3);
		await_request(phase_req); window(640,1279,180,899); accept();
		cases+=4;
		phase_req=req;
		lfb_update(32'h45678000,6'd3,16,31,8,14,512);
		await_request(phase_req); window(16,31,8,14);
		held=data; phase_req=req; accept(); await_request(phase_req);
		assert(data==held) else $fatal(1,"palette refresh changed its descriptor");
		cases++;
		$display("PASS actual scaler_config: %0d command/AR/held/reset cases, SYS_MHZ=%0d PHASE=%0d",
			cases,SYS_MHZ,PHASE);
		$finish;
	end
	initial begin
		#2ms $fatal(1,"test deadline");
	end
endmodule
