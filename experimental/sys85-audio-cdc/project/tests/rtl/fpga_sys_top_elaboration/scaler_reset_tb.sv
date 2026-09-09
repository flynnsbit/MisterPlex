`timescale 1ps/1ps
module scaler_reset_tb;
  reg iclk=0,oclk=0,aclk=0, reset_n=0, output_run=1;
  realtime sys_half=5882.352941176471;
  initial void'($value$plusargs("SYS_HALF=%f",sys_half));
  always #(sys_half) iclk=~iclk;
  always #3367.003367003367 if(output_run) oclk=~oclk; else oclk=0;
  always #5000 aclk=~aclk;
  reg reset0=1,reset1=1;
  always @(posedge aclk) begin reset0<=!reset_n; reset1<=reset0; end
  reg [269:0] cfg=0;
  reg req=0;
  wire ack,active;
  wire [7:0] red,green,blue;
  wire hs,vs,de,vbl,brd;
  wire [27:0] address,m_address;
  wire [127:0] data,wdata,m_wdata;
  wire [7:0] burst,m_burst;
  wire [15:0] be,m_be;
  wire read_cmd,write_cmd,wait_req,data_valid,m_read,m_write;
  reg [127:0] memory_data=0;
  reg memory_valid=0, manual_wait=0;
  integer accept_delay=0,return_delay=0,accept_left=0,return_left=0;
  integer accept_stalls=0,return_stalls=0,unready_pixels=0;
  reg delayed_offer_seen=0,delayed_return_seen=0;
  wire memory_wait=manual_wait || accept_left>0;
  reg hold_returns=0;
  integer scenario=0;
  integer window_y=8,window_height=7,aligned=0;
  initial begin
    void'($value$plusargs("WINDOW_Y=%d",window_y));
    void'($value$plusargs("WINDOW_HEIGHT=%d",window_height));
    void'($value$plusargs("ALIGNED=%d",aligned));
    void'($value$plusargs("ACCEPT_DELAY=%d",accept_delay));
    void'($value$plusargs("RETURN_DELAY=%d",return_delay));
  end
  ascal dut(.i_r(8'b0),.i_g(8'b0),.i_b(8'b0),.i_hs(1'b0),.i_vs(1'b0),
    .i_fl(1'b0),.i_de(1'b0),.i_ce(1'b1),.i_clk(iclk),
    .o_r(red),.o_g(green),.o_b(blue),.o_hs(hs),.o_vs(vs),.o_de(de),.o_vbl(vbl),.o_brd(brd),
    .o_clk(oclk),.o_ce(1'b1),.cfg_data(cfg),.cfg_req(req),.cfg_ack(ack),
    .cfg_pal_ready(req),.cfg_pal_valid(1'b1),.cfg_pal_bank(1'b0),.cfg_active(active),
    .o_border(24'b0),.o_fb_ena(1'b0),.o_fb_hsize(12'b0),.o_fb_vsize(12'b0),
    .o_fb_format(6'b000100),.o_fb_base(32'b0),.o_fb_stride(14'b0),
    .pal1_clk(iclk),.pal1_dw(48'b0),.pal1_a(7'b0),.pal1_wr(1'b0),.pal1_bank(1'b0),
    .pal_n(1'b0),.pal2_clk(iclk),.pal2_dw(24'b0),.pal2_a(8'b0),.pal2_wr(1'b0),
    .iauto(1'b1),.himin(12'b0),.himax(12'b0),.vimin(12'b0),.vimax(12'b0),
    .run(1'b1),.freeze(1'b0),.mode(5'b0),.bob_deint(1'b0),
    .htotal(12'b0),.hsstart(12'b0),.hsend(12'b0),.hdisp(12'b0),.hmin(12'b0),.hmax(12'b0),
    .vtotal(12'b0),.vsstart(12'b0),.vsend(12'b0),.vdisp(12'b0),.vmin(12'b0),.vmax(12'b0),
    .vrr(1'b0),.vrrmax(12'b0),.swblack(1'b0),.format(2'b01),
    .poly_clk(iclk),.poly_a(12'b0),.poly_dw(10'b0),.poly_wr(1'b0),
    .avl_clk(aclk),.avl_address(address),.avl_read(read_cmd),.avl_write(write_cmd),
    .avl_waitrequest(wait_req),.avl_readdata(data),.avl_readdatavalid(data_valid),
    .avl_burstcount(burst),.avl_writedata(wdata),.avl_byteenable(be),.reset_na(reset_n));
`ifdef RESET_PERSISTENT_MASTER
  f2sdram_safe_terminator #(128,8,1) bridge(
`else
  f2sdram_safe_terminator #(128,8) bridge(
`endif
    .clk(aclk),.rst_req_sync(reset1),
    .waitrequest_slave(wait_req),.burstcount_slave(burst),.address_slave(address),
    .readdata_slave(data),.readdatavalid_slave(data_valid),.read_slave(read_cmd),
    .writedata_slave(wdata),.byteenable_slave(be),.write_slave(write_cmd),
    .waitrequest_master(memory_wait),.burstcount_master(m_burst),.address_master(m_address),
    .readdata_master(memory_data),.readdatavalid_master(memory_valid),.read_master(m_read),
    .writedata_master(m_wdata),.byteenable_master(m_be),.write_master(m_write));
  function automatic [269:0] descriptor(input integer k);
    reg [269:0] d;
    d=0;
    d[269:258]=160; d[257:246]=136; d[245:234]=144; d[233:222]=128;
    d[221:210]=0; d[209:198]=15;
    d[197:186]=80; d[185:174]=68; d[173:162]=70; d[161:150]=64;
    d[149:138]=window_y; d[137:126]=window_y+window_height-1;
    d[118]=1; d[104]=1; d[116:105]=80;
    d[103:92]=16; d[91:80]=window_height; d[79:74]=6;
    d[73:42]=32'(k*'h1000000+((scenario==90||aligned)?0:12)); d[41:28]=((scenario==90||aligned)?64:80);
    return d;
  endfunction
  function automatic [23:0] pixel(input integer x,y,k);
    return {8'((13*x+7*y+23*k)%256),8'((3*x+19*y+17*k)%256),8'((11*x+5*y+31*k)%256)};
  endfunction
  function automatic [7:0] byte_at(input integer a);
    integer k,off,x,y; reg [23:0] p;
    k=a/'h1000000; off=a%'h1000000;
    if(!(scenario==90||aligned) && off<12) return 8'had;
    off-=((scenario==90||aligned)?0:12);
    y=off/((scenario==90||aligned)?64:80); x=(off%((scenario==90||aligned)?64:80))/4;
    if(x>=16) return 8'he5;
    p=pixel(x,y,k);
    case(off%4)
      0:return p[23:16]; 1:return p[15:8]; 2:return p[7:0]; default:return 8'hcc;
    endcase
  endfunction
  integer queue_addr[4],head=0,tail=0,used=0,word_index=0,cycle=0;
  integer requests=0,responses=0,client_accepts=0;
  always @(posedge aclk) begin
    if(read_cmd && !wait_req) client_accepts++;
    if(m_read && !memory_wait) begin
      assert(used<2 && m_burst==16) else $fatal(1,"orphan/overfull memory request");
      queue_addr[tail]=int'(m_address)*16; tail=(tail+1)%4; used++; requests++;
      if(m_address>='h200000 && !delayed_return_seen) begin
        delayed_return_seen=1;return_left=return_delay;
      end
    end
    if(memory_valid) responses++;
  end
  // There is deliberately no reset clause here: HPS memory retains traffic.
  always @(negedge aclk) begin
    memory_valid=0; cycle++;
    if(read_cmd && address>='h200000 && !delayed_offer_seen) begin
      delayed_offer_seen=1;accept_left=accept_delay;
    end else if(accept_left>0) begin accept_left--;accept_stalls++;end
    if(return_left>0) begin return_left--;return_stalls++;end
    if(used>0 && !hold_returns && return_left==0 && cycle%11!=3) begin
      for(integer lane=0;lane<16;lane++)
        memory_data[8*lane+:8]=byte_at(queue_addr[head]+16*word_index+lane);
      memory_valid=1;
      if(word_index==15) begin word_index=0;head=(head+1)%4;used--;end
      else word_index++;
    end
  end
  reg replacement=0,check_pixels=0,old_de=0,old_vbl=0;
  integer x=0,y=0,checked=0,old_requests=0,old_responses=0,expected_image=2,first_vs_cycle=0;
  integer hcycles=0,last_hcycle=0;
  reg previous_hs=0,valid_hperiod=0;
  always @(posedge oclk) begin
    hcycles++;
    if(!reset_n || !dut.cfg_initialized) valid_hperiod=0;
    else if(hs && !previous_hs) begin
      if(valid_hperiod) assert(hcycles-last_hcycle==160)
        else $fatal(1,"bootstrap changed horizontal timing");
      valid_hperiod=1;last_hcycle=hcycles;
    end
    previous_hs=hs;
    if(replacement && reset_n && !ack) begin
      assert(!de) else $fatal(1,"replacement pixels escaped memory-qualified priming");
      unready_pixels++;
    end
    if($test$plusargs("TRACE_EDGES") && check_pixels && dut.o_sh4 && dut.o_adrs<128)
      $display("TAIL t=%0t acpt=%0d hacpt=%0d last=%b/%b hpix=%h/%h input=%h first=%b adrs=%h",
        $time,dut.o_acpt,dut.o_hacpt,dut.o_last,dut.o_lastt4,dut.o_hpix0,dut.o_hpix1,dut.o_hpixs,dut.o_first,dut.o_adrs);
    if(replacement && reset_n && ack) begin
      assert(used==0 && !memory_valid && !m_read && !read_cmd)
        else $fatal(1,"RESET OWNERSHIP premature replacement ACK with old framebuffer traffic");
      replacement=0;
    end
    if(vbl) y=-1;
    if(de) begin
      if(!old_de) begin x=0;y++;end else x++;
      if(check_pixels) begin
        reg [23:0] expected;
        expected=(x<16 && y>=window_y && y<window_y+window_height)?pixel(x,y-window_y,expected_image):24'b0;
        assert({red,green,blue}==expected)
          else $fatal(1,"RESET OWNERSHIP replacement first-frame pixel x=%0d y=%0d got=%h expected=%h copy=%d debt=%d copies=%d bibu=%b wad=%d h=%d v=%d",x,y,{red,green,blue},expected,dut.o_copy,dut.o_readlev,dut.o_copylev,dut.o_bibu,dut.avl_wad,dut.o_hcpt,dut.o_vcpt);
        checked++;
      end
    end
    old_de=de;old_vbl=vbl;
  end
  task automatic tick(input integer n=1);repeat(n) @(negedge iclk); #1;endtask
  task automatic wait_ack;
    for(integer n=0;n<50000 && ack!=req;n++) tick();
    assert(ack==req) else $fatal(1,"RESET OWNERSHIP scaler bounded restart timeout");
  endtask
  initial begin
    void'($value$plusargs("CASE=%d",scenario));
    tick(5);reset_n=1;tick(8);cfg=descriptor(scenario==90?2:1);req=1;wait_ack();
    if(scenario==90) begin
      repeat(3) @(negedge vs);
      check_pixels=1; @(negedge vs);
      $display("PASS scaler aligned layout no-reset control"); $finish;
    end
    repeat(3) @(negedge vs);
    hold_returns=1;old_requests=requests;old_responses=responses;
    if(scenario==2) begin
      manual_wait=1;
      wait(m_read); tick(5);
      assert(used==0 && read_cmd && m_read) else $fatal(1,"bridge-stalled setup missing");
    end else begin
      for(integer n=0;n<50000 && requests<old_requests+(scenario==3?2:1);n++) tick();
      assert(used==(scenario==3?2:1)) else $fatal(1,"retained burst setup missing");
    end
    if(scenario==1 || scenario==4) begin
      hold_returns=0;
      wait(responses>=old_responses+7); @(negedge aclk); #1;hold_returns=1;
      assert(word_index>0 && word_index<16) else $fatal(1,"split-return setup missing");
    end
    tick(1);reset_n=0;req=0;cfg=0;tick(15);
    if(scenario==3) begin
      @(negedge oclk); output_run=0;
      hold_returns=0; tick(100);
      assert(used==0 && responses==old_responses+32) else $fatal(1,"stopped-output return setup");
    end
    reset_n=1;cfg=descriptor(2);req=1;replacement=1;
    $display("WITNESS retained framebuffer case=%0d outstanding=%0d responses=%0d client_accepts=%0d",
      scenario,used,responses-old_responses,client_accepts);
    tick(100);
    assert(!ack) else $fatal(1,"RESET OWNERSHIP replacement ACK escaped retained burst");
    if(scenario==4) begin reset_n=0;req=0;tick(8);reset_n=1;req=1;tick(50);
      assert(!ack) else $fatal(1,"RESET OWNERSHIP repeated reset ACK escaped old debt"); end
    manual_wait=0;hold_returns=0;output_run=1;
    if(scenario==5) begin
      wait(delayed_return_seen); tick(2);
      assert(!ack && used>0) else $fatal(1,"new-prime reset owned no accepted response");
      reset_n=0;req=0;cfg=0;tick(10);
      @(negedge oclk);output_run=0;tick(30);
      reset_n=1;cfg=descriptor(3);req=1;expected_image=3;tick(30);
      assert(!ack) else $fatal(1,"stopped new-prime reset acknowledged");
      output_run=1;
    end
    wait_ack();
    check_pixels=1;
    @(negedge vs);
    assert(checked==8192) else $fatal(1,"RESET OWNERSHIP first replacement frame budget %0d",checked);
    first_vs_cycle=hcycles;
    @(negedge vs); check_pixels=0;
    assert(checked==16384 && hcycles-first_vs_cycle==160*80)
      else $fatal(1,"continuous replacement frame pixels/timing");
    assert(client_accepts==requests && responses==16*requests && used==0 &&
           dut.o_readlev==0 && dut.o_copylev==0)
      else $fatal(1,"RESET OWNERSHIP orphan command/return/copy at complete frame");
    assert(accept_stalls==accept_delay && return_stalls==return_delay)
      else $fatal(1,"requested replacement service delay was not exercised");
    $display("PASS scaler actual vbuf retained reset case=%0d pixels=8192 continuation_pixels=%0d requests=%0d responses=%0d",scenario,checked-8192,requests,responses);
    $display("EDGE y=%0d height=%0d aligned=%0d accept_stalls=%0d return_stalls=%0d unready_cycles=%0d",window_y,window_height,aligned,accept_stalls,return_stalls,unready_pixels);
    $finish;
  end
  initial #5000000000 $fatal(1,"scaler global deadline");
endmodule
