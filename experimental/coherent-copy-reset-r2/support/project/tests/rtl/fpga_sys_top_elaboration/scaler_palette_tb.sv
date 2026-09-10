`timescale 1fs/1fs
module scaler_palette_tb;
	parameter integer SYS_MHZ=85;
	parameter integer PHASE=37;
	reg clk=0, source_clk=0, hdmi_clk=0, run_palette=1;
	reg reset=0, cfg_req=0, cfg_ack=0, cfg_active=0, hdmi_vs=0;
	reg [269:0] cfg=0;
	wire [28:0] pal_address;
	wire pal_request,bank,ready,valid,pal_data_ready;
	wire [6:0] pal_index=ram_bcnt[6:0];
	wire [63:0] pal_data;
	wire ram_read,ram_write;
	wire [28:0] ram_address;
	wire [7:0] ram_burst,ram_bcnt,ram_be;
	wire [63:0] ram_wdata;
	reg ram_wait=0,ram_valid=0;
	reg [63:0] ram_data=0;
	reg pause_responses=0,audio_req=0;
	wire audio_ready;
	wire [63:0] audio_data;
	scaler_palette dut(.clk(clk),.reset(reset),.cfg_data(cfg),.cfg_req(cfg_req),
		.cfg_ack(cfg_ack),.cfg_active(cfg_active),.hdmi_vs(hdmi_vs),
		.data_ready(pal_data_ready),.data_index(pal_index),.address(pal_address),.request(pal_request),
		.write_bank(bank),.ready_tag(ready),.ready_valid(valid));
	ddr_svc service(.clk(clk),.ram_waitrequest(ram_wait),.ram_burstcnt(ram_burst),
		.ram_addr(ram_address),.ram_readdata(ram_data),.ram_read_ready(ram_valid),
		.ram_read(ram_read),.ram_writedata(ram_wdata),.ram_byteenable(ram_be),.ram_write(ram_write),
		.ram_bcnt(ram_bcnt),.ch0_addr(29'h100),.ch0_burst(8'd1),.ch0_data(audio_data),
		.ch0_req(audio_req),.ch0_ready(audio_ready),.ch1_addr(pal_address),
		.ch1_burst(8'd128),.ch1_data(pal_data),.ch1_req(pal_request),.ch1_ready(pal_data_ready));
	longint unsigned sf=0,pf=0,hf=0,dt;
	initial forever begin
		dt=(1000000000+sf)/(2*SYS_MHZ); sf=(1000000000+sf)%(2*SYS_MHZ);
		#(dt) source_clk=~source_clk;
	end
	initial begin : pclock
		longint unsigned delay_fs;
		#(PHASE*1000);
		forever begin
			delay_fs=(244140625+pf)/12; pf=(244140625+pf)%12;
			#(delay_fs) if(run_palette) clk=~clk; else clk=0;
		end
	end
	initial begin : hclock
		longint unsigned delay_fs;
		forever begin
			delay_fs=(1000000000+hf)/297; hf=(1000000000+hf)%297;
			#(delay_fs) hdmi_clk=~hdmi_clk;
		end
	end
	integer pending=0, response_index=0, loads=0, words=0,audio_count=0;
	reg [28:0] accepted_address;
	reg active_bank=0;
	always @(negedge clk) begin
		ram_valid=0;
		if (ram_read && !ram_wait && pending==0) begin
			pending=ram_burst; response_index=0; accepted_address=ram_address;
			if(ram_burst==128) begin
				loads++;
				assert(ram_address==pal_address) else $fatal(1,"palette address not held");
			end
		end
		if(pending>0 && !pause_responses) begin
			ram_valid=1; ram_data={28'b0,accepted_address,7'(response_index)};
			pending--; response_index++;
		end
	end
	always @(posedge clk) begin
		if(pal_data_ready) begin
			words++;
			assert(!cfg_active || bank!=active_bank || reset) else $fatal(1,"overwrote active palette");
			assert(pal_data[6:0]==pal_index) else $fatal(1,"palette payload/index changed");
		end
		if(audio_ready) audio_count++;
	end
	task automatic tick(input integer n=1); repeat(n) @(negedge source_clk); endtask
	task automatic submit(input bit indexed, input reg [31:0] base);
		cfg=0; cfg[104]=1; cfg[76:74]=indexed ? 3'b011 : 3'b100;
		cfg[73:42]=base; cfg_req=~cfg_req; tick();
	endtask
	task automatic complete;
		integer n;
		n=0;
		while((!valid || ready!=cfg_req) && n<10000) begin tick(); n++; end
		assert(valid && ready==cfg_req) else $fatal(1,"palette completion deadline");
	endtask
	task automatic apply;
		@(negedge hdmi_clk); cfg_ack=cfg_req; cfg_active=1; active_bank=bank; tick(20);
	endtask
	task automatic vs_edge;
		@(negedge hdmi_clk); hdmi_vs=1; tick(20);
		@(negedge hdmi_clk); hdmi_vs=0;
	endtask
	initial begin : run
		integer before_loads,before_words;
		reg saved_request,saved_bank;
		tick(3); reset=1; tick(5); reset=0; tick(10);
		// No output frame yet: palette initialization must not wait for VS.
		submit(1,32'h102000); complete();
		assert(loads==1 && words==128 && pal_address==29'h20200) else $fatal(1,"startup palette");
		apply();
		submit(1,32'h204000); before_loads=loads; tick(80);
		assert(loads==before_loads && ready!=cfg_req) else $fatal(1,"refresh ignored VS cut");
		pause_responses=1; audio_req=~audio_req; vs_edge();
		tick(100); assert(ready!=cfg_req) else $fatal(1,"premature complete");
		pause_responses=0; complete();
		assert(words==256 && audio_count==1 && pal_address==29'h40600) else $fatal(1,"DMA/audio ownership");
		apply();
		before_loads=loads; submit(0,32'h306000); complete(); apply();
		assert(loads==before_loads) else $fatal(1,"nonindexed configuration launched DMA");

		// A reset invalidates only configuration ownership; old DMA must drain.
		submit(1,32'h408000); pause_responses=1; vs_edge(); tick(100);
		assert(!dut.busy && ready!=cfg_req) else $fatal(1,"late command consumed an earlier VS");
		vs_edge(); tick(100);
		saved_request=pal_request; before_words=words;
		assert(dut.busy) else $fatal(1,"reset case owned no DMA");
		reset=1; cfg_req=0; cfg_ack=0; cfg_active=0; tick(5);
		assert(pal_request==saved_request && !valid) else $fatal(1,"reset reused request phase");
		reset=0; submit(1,32'h50a000); tick(100);
		assert(pal_request==saved_request && !valid) else $fatal(1,"fresh request passed old debt");
		pause_responses=0; complete();
		assert(words==before_words+256 && pal_address==29'ha1200) else $fatal(1,"old/fresh DMA accounting");
		apply();

		// Invalidation is asynchronous even if the palette clock is stopped.
		@(negedge clk); run_palette=0; saved_bank=bank; tick(4);
		reset=1; cfg_req=0; cfg_ack=0; cfg_active=0; #1ns;
		assert(!valid && bank==saved_bank) else $fatal(1,"stopped-clock stale completion");
		tick(3); reset=0; submit(0,32'h60c000); tick(30);
		assert(!valid) else $fatal(1,"completion escaped stopped producer");
		run_palette=1; complete(); apply();
		$display("PASS actual palette/ddr_svc: loads=%0d words=%0d audio=%0d SYS_MHZ=%0d PHASE=%0d",
			loads,words,audio_count,SYS_MHZ,PHASE);
		$finish;
	end
	initial #2ms $fatal(1,"palette test deadline");
endmodule
