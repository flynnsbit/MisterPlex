`timescale 1ps/1ps
module native_reset_tb;
  reg iclk=0,oclk=0,aclk=0,reset_n=0,input_run=1,output_run=1,send_input=1;
  reg pclk=0,palette_run=1,hold_tag=0,hold_valid=0;
  realtime sys_half=5882.352941176471;
  integer sys85=1,width=32,height=24,case_id=0,lowlat=0,packing=1;
  initial begin
    void'($value$plusargs("SYS_HALF=%f",sys_half));
    void'($value$plusargs("SYS85=%d",sys85));
    void'($value$plusargs("WIDTH=%d",width));
    void'($value$plusargs("HEIGHT=%d",height));
    void'($value$plusargs("CASE=%d",case_id));
    void'($value$plusargs("LOWLAT=%d",lowlat));
    void'($value$plusargs("PACKING=%d",packing));
  end
  always #(sys_half) if(input_run) iclk=~iclk; else iclk=0;
  always #3367.003367003367 if(output_run) oclk=~oclk;else oclk=0;
  always #5000 aclk=~aclk;
  always #20345.052083333333 if(palette_run) pclk=~pclk; else pclk=0;
  reg reset0=1,reset1=1;
  always @(posedge aclk) begin reset0<=!reset_n;reset1<=reset0;end
  reg [269:0] cfg=0;
  reg req=0,ice=0,ide=0,ihs=0,ivs=0;
  reg [7:0] ir=0,ig=0,ib=0;
  wire ack,active,hs,vs,de,vbl,brd;
  wire [7:0] red,green,blue,burst,m_burst;
  wire [27:0] address,m_address;
  wire [127:0] data,wdata,m_wdata;
  wire [15:0] be,m_be;
  wire read_cmd,write_cmd,wait_req,data_valid,m_read,m_write;
  reg [127:0] memory_data=0;
  reg memory_valid=0,memory_wait=0,manual_wait=0,hold_returns=0,case_done=0;
  integer input_x=0,input_y=0,input_frame=1,completed_inputs=0,fraction=0,total_inputs=0;
  bit completed_tag[int];
  integer paint_epoch=1,min_display_tag=1,pause_at_frame=3,vrr_override=0;
  wire controlled_input=(case_id==26 || case_id==30 || case_id==31 || case_id==32);
  wire vrr_enabled=(vrr_override || case_id==26 || case_id==30 || case_id==32);
  integer vrr_front=800,vrr_back=16;
  wire palette_tag,palette_valid,palette_bank,palette_request;
  wire [28:0] palette_address;
  scaler_palette palette(.clk(pclk),.reset(!reset_n),.cfg_data(cfg),
    .cfg_req(req),.cfg_ack(ack),.cfg_active(active),.hdmi_vs(vs),
    .data_ready(1'b0),.data_index(7'b0),.address(palette_address),
    .request(palette_request),.write_bank(palette_bank),
    .ready_tag(palette_tag),.ready_valid(palette_valid));
  wire ready_tag=hold_tag?!req:palette_tag;
  wire ready_valid=hold_valid?1'b0:palette_valid;
  function automatic [23:0] pixel(input integer x,y,k);
    return {8'(x+17*k),8'(y+29*k),8'((x^y)^(43*k))};
  endfunction
  always @(negedge iclk) begin
    ice=0;ide=0;ihs=0;ivs=0;
    if(reset_n && send_input) begin
      fraction+=4;
      if(!sys85 || fraction>=17) begin
        integer iw,iv,paint;
        fraction=fraction%17;ice=1;
        iw=(case_id==10 && input_frame>=4)?width/2:width;
        iv=(case_id==10 && input_frame>=4)?height/2:height;
        paint=(lowlat && case_id!=26 && case_id!=30 && case_id!=31)?paint_epoch:input_frame;
        ihs=(input_x>=iw+8 && input_x<iw+16);
        ivs=(input_y<3);
        ide=(input_x<iw && input_y>=8 && input_y<iv+8);
        {ir,ig,ib}=pixel(input_x,input_y-8,paint);
        if(input_x==iw+63) begin
          input_x=0;
          if(input_y==iv+15) begin
            input_y=0;completed_inputs=input_frame;completed_tag[paint]=1;input_frame++;total_inputs++;
          end else input_y++;
        end else input_x++;
        if(controlled_input && input_y==0 && input_x==8 && input_frame>=pause_at_frame)
          send_input=0;
      end
    end
  end
  ascal dut(.i_r(ir),.i_g(ig),.i_b(ib),.i_hs(ihs),.i_vs(ivs),
    .i_fl(1'b0),.i_de(ide),.i_ce(ice),.i_clk(iclk),
    .o_r(red),.o_g(green),.o_b(blue),.o_hs(hs),.o_vs(vs),.o_de(de),.o_vbl(vbl),.o_brd(brd),
    .o_clk(oclk),.o_ce(1'b1),.cfg_data(cfg),.cfg_req(req),.cfg_ack(ack),
    .cfg_pal_ready(ready_tag),.cfg_pal_valid(ready_valid),.cfg_pal_bank(palette_bank),.cfg_active(active),
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
  f2sdram_safe_terminator #(128,8,1) bridge(.clk(aclk),.rst_req_sync(reset1),
    .waitrequest_slave(wait_req),.burstcount_slave(burst),.address_slave(address),
    .readdata_slave(data),.readdatavalid_slave(data_valid),.read_slave(read_cmd),
    .writedata_slave(wdata),.byteenable_slave(be),.write_slave(write_cmd),
    .waitrequest_master(memory_wait),.burstcount_master(m_burst),.address_master(m_address),
    .readdata_master(memory_data),.readdatavalid_master(memory_valid),.read_master(m_read),
    .writedata_master(m_wdata),.byteenable_master(m_be),.write_master(m_write));
  reg [127:0] memory[longint unsigned];
`ifdef NATIVE_OWNERSHIP_PROBES
  wire native_owned=dut.o_native_valid;
  wire input_write_idle=dut.i_write_done_sync==dut.i_write && !dut.i_wreq_mem && !dut.i_wreq;
  wire context_pending=dut.i_native_req!=dut.o_native_ack;
  wire stream_seen=dut.i_stream_sync;
`else
  // The immutable a519 baseline has no new ownership observer registers.
  // Its required witness is the unchanged real RGB/write/read/ACK deadline.
  wire native_owned=0,input_write_idle=!write_cmd,context_pending=0,stream_seen=0;
`endif
  integer published_cycle=0,published_frame=0;
  always @(posedge context_pending) begin
    published_cycle=output_cycles;published_frame=completed_inputs;
  end
  longint unsigned write_base=0,read_queue[4];
  integer write_word=0,write_length=0,writes=0,write_bursts=0;
  integer head=0,tail=0,used=0,read_word=0,reads=0,returns=0,cycle=0,client_reads=0;
  reg stalled_write=0;
  reg [127:0] held_wdata;
  reg [15:0] held_be;
  reg [27:0] held_address;
  always @(posedge aclk) begin
    if(lowlat && (m_write || m_read)) assert(m_address>=28'h2000000 && m_address<28'h2080000)
      else $fatal(1,"native low-latency mode changed its single-buffer address contract");
    if(m_write && native_owned && !dut.c_fb_ena && !lowlat)
      assert((m_address-28'h2000000)/28'h80000!=dut.o_obuf0)
        else $fatal(1,"native writer overwrote the displayed/priming owned buffer");
    if(m_write && lowlat && dut.i_native_delivered && !stream_seen && reset_n)
      $fatal(1,"bank0 first context was overwritten before actual stream authorization");
    if(stalled_write) assert(m_write && m_wdata==held_wdata && m_be==held_be && m_address==held_address)
      else $fatal(1,"native held write data/address changed before acceptance");
    stalled_write=m_write && memory_wait;
    held_wdata=m_wdata;held_be=m_be;held_address=m_address;
    if(read_cmd && !wait_req) client_reads++;
    if(m_write && !memory_wait) begin
      if(write_word==0) begin write_base=m_address;write_length=m_burst;write_bursts++;end
      assert(m_address==write_base && m_burst==write_length)
        else $fatal(1,"native input write burst address/count changed");
      if(!memory.exists(write_base+write_word)) memory[write_base+write_word]=0;
      for(integer lane=0;lane<16;lane++)
        if(m_be[lane]) memory[write_base+write_word][8*lane+:8]=m_wdata[8*lane+:8];
      writes++;write_word++;
      if(write_word==write_length) write_word=0;
    end
    if(m_read && !memory_wait) begin
      assert(used<3 && m_burst==16) else $fatal(1,"native read ownership overflow");
      read_queue[tail]=m_address;tail=(tail+1)%4;used++;reads++;
    end
    if(memory_valid) returns++;
  end
  always @(negedge aclk) begin
    cycle++;memory_wait=manual_wait || (cycle%31<3);memory_valid=0;
    if(used && !hold_returns && cycle%11!=3) begin
      memory_valid=1;
      if(memory.exists(read_queue[head]+read_word)) memory_data=memory[read_queue[head]+read_word];
      else memory_data=0;
      read_word++;
      if(read_word==16) begin read_word=0;head=(head+1)%4;used--;end
    end
  end
  function automatic [269:0] descriptor;
    reg [269:0] d;
    d=0;d[269:258]=width+80;d[257:246]=width+16;d[245:234]=width+32;d[233:222]=width;
    d[221:210]=0;d[209:198]=width-1;
    d[197:186]=height+32;d[185:174]=height+12;d[173:162]=height+16;d[161:150]=height;
    d[149:138]=0;d[137:126]=height-1;
    d[125:121]=lowlat?0:8;d[120:119]=packing;d[118]=1;
    if(case_id>=30 || vrr_enabled) begin
      d[197:186]=height+vrr_front+4+vrr_back;
      d[185:174]=height+vrr_front;d[173:162]=height+vrr_front+4;
      d[117]=vrr_enabled;d[116:105]=height+vrr_back+4+1;
    end
    // Default native/input RGB mode: bit104 and all external-FB dimensions stay zero.
    return d;
  endfunction
  integer x=0,y=-1,tag=0,pixels=0,frames=0,frame_pixels=0,identities=0,last_tag=0;
  integer lifetime_pixels=0,session=0,last_vs_cycle=0,output_cycles=0,partial_reset_pixels=0;
  integer first_de_cycle=0,hs_cycle=0,availability_events=0,last_event_cycle=0;
  integer last_interval_lines=0,vrr_checks=0;
  integer minimum_periods=0,maximum_periods=0,vrr_position=0;
  integer hs_edges=0,event_hs=0,target_display_tag=0;
  reg interval_valid=0;
  reg old_de=0,old_vs=0,old_hs=0,seen_video=0;
  always @(posedge oclk) begin
    output_cycles++;
    if(hs && !old_hs && active) begin
      hs_edges++;
      if(hs_cycle && reset_n)
        assert(output_cycles-hs_cycle==width+80) else $fatal(1,"native irregular HS");
      hs_cycle=output_cycles;
    end
    old_hs=hs;
    if(dut.o_isync2) begin
      last_interval_lines=dut.o_vcpt_sync2;
      if(interval_valid && reset_n) begin
        integer observed;
        observed=hs_edges-event_hs;
        if(observed>4095) observed=4095;
        assert(last_interval_lines>=observed-1 && last_interval_lines<=observed+1)
          else $fatal(1,"VRR source-availability interval disagrees with real HS intervals");
      end
      interval_valid=1;event_hs=hs_edges;
      last_event_cycle=output_cycles;availability_events++;
      $display("NATIVE_AVAILABLE cycle=%0d interval_lines=%0d output_row=%0d",output_cycles,last_interval_lines,dut.o_vcpt);
    end
    // Returned-but-not-copied credits are a subset of read ownership.
    assert(dut.o_readlev<=2 && dut.o_copylev<=dut.o_readlev)
      else $fatal(1,"native read/copy ownership credit underflow or overflow");
    if(!reset_n) begin
      if(frame_pixels>0 && frame_pixels<width*height) partial_reset_pixels+=frame_pixels;
      x=0;y=-1;frames=0;pixels=0;frame_pixels=0;identities=0;last_tag=0;
      old_de=0;old_vs=0;seen_video=0;last_vs_cycle=0;
      hs_cycle=0;
      interval_valid=0;
    end else begin
    if(vbl) y=-1;
    if(de) begin
      assert(active && !dut.o_bootstrap) else $fatal(1,"native visible output before context-ready bootstrap");
      if(!old_de) begin x=0;y++;end else x++;
      if(x==0 && y==0) begin
        tag=(int'(red)*241)%256;frame_pixels=0;seen_video=1;first_de_cycle=output_cycles;
        assert(tag>=min_display_tag && completed_tag.exists(tag))
          else $fatal(1,"native selected unfinished/unknown input frame tag=%0d complete=%0d",tag,completed_inputs);
        if(tag!=last_tag) begin
          if(case_id!=8) assert(tag>last_tag) else $fatal(1,"native buffer identity went backwards");
          identities++;last_tag=tag;
        end
      end
      begin
        integer px,py;
        px=(case_id==10 && tag>=4)?x/2:x;py=(case_id==10 && tag>=4)?y/2:y;
        assert({red,green,blue}==pixel(px,py,tag))
          else $fatal(1,"RESET OWNERSHIP native RGB mixed/stale pixel frame=%0d xy=%0d,%0d got=%h expected=%h",tag,x,y,{red,green,blue},pixel(px,py,tag));
      end
      frame_pixels++;pixels++;lifetime_pixels++;
    end
    if(old_vs && !vs && seen_video) begin
      assert(frame_pixels==width*height) else $fatal(1,"native complete-frame budget %0d",frame_pixels);
      if(last_vs_cycle && !vrr_enabled && case_id<30 && case_id!=8 && case_id!=6)
        assert(output_cycles-last_vs_cycle==(width+80)*(height+32))
          else $fatal(1,"native continuous raster period changed");
      if(last_vs_cycle && (case_id>=30 || vrr_enabled)) begin
        integer period_clocks,minimum_clocks,maximum_clocks;
        period_clocks=output_cycles-last_vs_cycle;
        minimum_clocks=(height+vrr_back+4+1)*(width+80);
        maximum_clocks=(height+vrr_front+4+vrr_back)*(width+80);
        assert(period_clocks>=minimum_clocks && period_clocks<=maximum_clocks)
          else $fatal(1,"VRR frame outside minimum/maximum interval bounds");
        if(!vrr_enabled) assert(period_clocks==maximum_clocks)
          else $fatal(1,"VRR disabled changed fixed refresh");
        if(period_clocks==minimum_clocks) minimum_periods++;
        if(period_clocks==maximum_clocks) maximum_periods++;
        $display("VRR_PERIOD clocks=%0d minimum=%0d maximum=%0d",period_clocks,minimum_clocks,maximum_clocks);
      end
      last_vs_cycle=output_cycles;
      frames++;$display("NATIVE_FRAME session=%0d frame=%0d tag=%0d pixels=%0d writes=%0d reads=%0d",session,frames,tag,frame_pixels,writes,reads);
      if(frames>=4 && identities>=(lowlat?1:3) && case_done &&
          (case_id!=10 || tag>=5) && write_word==0 && !m_write &&
          input_write_idle && (case_id!=26 && case_id!=30 && case_id!=31 || tag==completed_inputs) &&
          (target_display_tag==0 || tag==target_display_tag)) begin
        assert(client_reads==reads && returns==16*reads && used==0 &&
               dut.o_readlev==0 && dut.o_copylev==0)
          else $fatal(1,"native orphan request/return/copy at complete frame");
        $display("PASS native scaler real RGB -> accepted DDR writes -> first/continuous RGB SYS85=%0d case=%0d geometry=%0dx%0d frames=%0d identities=%0d pixels=%0d lifetime_pixels=%0d partial_reset_pixels=%0d packing=%0d",sys85,case_id,width,height,frames,identities,pixels,lifetime_pixels,partial_reset_pixels,packing);
        $display("NATIVE_MODE readiness=%b/%b config_active=%b lowlat=%0d vrr=%b porch_checks=%0d minimum_periods=%0d maximum_periods=%0d",ready_tag,ready_valid,active,lowlat,vrr_enabled,vrr_checks,minimum_periods,maximum_periods);
        $finish;
      end
    end
    old_de=de;old_vs=vs;
    end
  end
  task automatic tick(input integer n=1);repeat(n) @(negedge iclk);#1;endtask
  task automatic replace(input integer next_tag);
    reset_n=0;req=0;cfg=0;session++;tick(15);
    input_x=0;input_y=0;input_frame=next_tag;
    if(lowlat) paint_epoch=next_tag;
    min_display_tag=next_tag;
    reset_n=1;cfg=descriptor();req=1;
  endtask
  initial begin
    if(case_id==20 || case_id==25 || case_id==26) palette_run=0;
    if(case_id==22) hold_valid=1;
    if(case_id==23) hold_tag=1;
    if(case_id==24) send_input=0;
    if(case_id==32) begin vrr_back=400;pause_at_frame=1000;end
    void'($value$plusargs("VRR_POSITION=%d",vrr_position));
    void'($value$plusargs("VRR_ENABLE=%d",vrr_override));
    if(case_id==1) send_input=0;
    if(case_id==4) hold_returns=1;
    tick(8);reset_n=1;cfg=descriptor();req=1;
    case(case_id)
      0,10: case_done=1;
      20,22,23: begin
        wait(total_inputs>=3);tick(100);
        assert(!ack && writes>0) else $fatal(1,"independent readiness setup missing");
        palette_run=1;hold_tag=0;hold_valid=0;
        if(lowlat) begin
          wait(stream_seen);wait(write_bursts>=3*(height*((width*(packing==1?3:4)+255)/256)+1));
        end
        case_done=1;
      end
      21: begin
        wait(frames>=4);@(negedge pclk);palette_run=0;replace(21);
        wait(completed_inputs>=23);tick(100);
        assert(!ack && !ready_valid) else $fatal(1,"warm palette pause setup missing");
        palette_run=1;case_done=1;
      end
      24: begin
        wait(ready_valid && ready_tag==req);tick(10000);
        assert(!ack && writes==0) else $fatal(1,"readiness substituted for actual input");
        send_input=1;case_done=1;
      end
      25: begin
        wait(context_pending);@(negedge iclk);input_run=0;
        reset_n=0;req=0;cfg=0;session++;repeat(40) @(negedge aclk);
        reset_n=1;cfg=descriptor();req=1;repeat(100) @(negedge aclk);
        reset_n=0;req=0;repeat(40) @(negedge aclk);
        reset_n=1;req=1;repeat(100) @(negedge aclk);
        input_x=0;input_y=0;input_frame=100;paint_epoch=100;min_display_tag=100;input_run=1;
        wait(completed_inputs>=102);tick(100);palette_run=1;case_done=1;
      end
      26,30,31: begin
        integer target_row,launch_row,available,events_before,frame_start,observed_vs,bank_before;
        wait(!send_input);
        if(case_id==26) begin
          tick(10000);assert(!ack);palette_run=1;wait(ack);
          if(lowlat) begin
            // The first bank0 frame must finish before streaming may start.
            // Two real porch-only input images then establish an in-range
            // availability interval without forcing VRR history or state.
            wait(frames==1);@(posedge de);repeat(40) @(posedge hs);
            pause_at_frame=input_frame+2;send_input=1;wait(!send_input);
            wait(frames>=3);
          end
        end else wait(frames==1);
        for(integer position=vrr_position;position<3;position++) begin
          @(posedge de);frame_start=output_cycles;
          @(negedge oclk);
          assert({red,green,blue}==pixel(0,0,completed_inputs))
            else $fatal(1,"VRR next frame did not use the available completed image");
          bank_before=dut.o_obuf0;
          target_row=position==0?300:position==1?500:780;
          launch_row=target_row-$rtoi(((width+64)*(height+16)-8)*50000.0/((width+80)*6734.006734));
          repeat(launch_row) @(posedge hs);
          events_before=availability_events;pause_at_frame=input_frame+1;send_input=1;
          wait(!send_input);wait(context_pending);
          available=published_cycle;
          assert(published_frame==completed_inputs) else $fatal(1,"VRR observation is not this real completed image");
          $display("VRR_WITNESS position=%0d completed=%0d available_row=%0d events=%0d",position,completed_inputs,(available-frame_start)/(width+80),availability_events);
          if(vrr_enabled) begin
            for(integer n=0;n<8*(width+80) && !vs;n++) @(negedge oclk);
            assert(vs) else $fatal(1,"RESET OWNERSHIP VRR current porch did not respond to completed native image");
            assert(availability_events==events_before+1 && last_event_cycle>=available &&
                   last_event_cycle-available<16)
              else $fatal(1,"VRR availability was missing, duplicated or tied to later adoption");
          end else begin
            @(posedge vs);
            assert(output_cycles-frame_start==(height+vrr_front)*(width+80)+width+16)
              else $fatal(1,"VRR-off fixed porch changed");
          end
          observed_vs=output_cycles;
          assert(dut.o_obuf0==bank_before && dut.o_native_pending)
            else $fatal(1,"VRR availability improperly adopted the bank before safe VS boundary");
          assert((available-frame_start)/(width+80)>=target_row-3 &&
                 (available-frame_start)/(width+80)<=target_row+3)
            else $fatal(1,"requested adjustable-porch position not exercised");
          assert(observed_vs-frame_start>=(height+1)*(width+80) &&
                 observed_vs-frame_start<=(height+vrr_front+1)*(width+80))
            else $fatal(1,"VRR porch bounds violated");
          vrr_checks++;
          $display("VRR_RESPONSE position=%0d available_cycle=%0d vs_cycle=%0d interval_lines=%0d checks=%0d",position,available,observed_vs,last_interval_lines,vrr_checks);
          @(negedge vs);
          assert(!context_pending && !dut.o_native_pending)
            else $fatal(1,"VRR safe boundary failed to adopt/acknowledge the completed context");
        end
        case_done=1;
      end
      32: begin
        integer events_before;
        wait(minimum_periods>=2 && frames>=4);
        pause_at_frame=input_frame+1;wait(!send_input);
        wait(input_write_idle && !context_pending && !dut.o_native_pending && !dut.i_frame_drain);
        repeat(4) @(negedge vs);
        events_before=availability_events;
        pause_at_frame=input_frame+1;send_input=1;wait(!send_input);
        wait(availability_events>events_before);
        assert(last_interval_lines>=height+vrr_front+4+vrr_back)
          else $fatal(1,"slow VRR source-interval setup missing");
        target_display_tag=lowlat?paint_epoch:completed_inputs;
        wait(maximum_periods>=1);case_done=1;
      end
      9: begin
        wait(frames>=4);
        wait(write_bursts>=3*(height*((width*(packing==1?3:4)+255)/256)+1));
        assert(stream_seen) else $fatal(1,"native low-latency streaming never resumed");
        case_done=1;
      end
      1: begin
        tick(20000);
        assert(!ack && writes==0 && reads==0) else $fatal(1,"native guessed readiness before input");
        send_input=1;case_done=1;
      end
      2,3: begin
        wait(input_frame>=2 && write_word==7);@(negedge aclk);manual_wait=1;
        if(case_id==2) begin
          tick((width+64)*(height+16)*5);
          assert(!ack) else $fatal(1,"native incomplete stalled image acknowledged");
        end else begin
          replace(20);tick(40);
          assert(!ack && write_word!=0) else $fatal(1,"native reset lost held input write");
        end
        manual_wait=0;case_done=1;
      end
      4: begin
        wait(used==2);@(negedge aclk);hold_returns=0;
        wait(returns==7);@(negedge aclk);hold_returns=1;
        assert(!ack && used>0 && read_word>0) else $fatal(1,"native prime split setup missing");
        reset_n=0;req=0;cfg=0;session++;tick(15);
        @(negedge oclk);output_run=0;hold_returns=0;tick(80);
        assert(used==0 && returns==32) else $fatal(1,"native stopped-output old returns lost");
        input_x=0;input_y=0;input_frame=40;
        min_display_tag=40;
        reset_n=1;cfg=descriptor();req=1;tick(30);output_run=1;case_done=1;
      end
      5: begin
        wait(context_pending);@(negedge iclk);input_run=0;
        wait(frames==2);repeat(20) @(negedge aclk);input_run=1;case_done=1;
      end
      6: begin
        wait(context_pending);@(negedge oclk);output_run=0;
        tick((width+64)*(height+16)*5);
        assert(!ack) else $fatal(1,"native clock-stopped context acknowledged");
        output_run=1;case_done=1;
      end
      7: begin
        wait(identities>=2 && frames>=4);@(negedge iclk);
        reset_n=0;req=0;cfg=0;session++;tick(15);
        width=48;height=40;input_x=0;input_y=0;input_frame=60;
        min_display_tag=60;
        reset_n=1;cfg=descriptor();req=1;case_done=1;
      end
      8: begin
        reg [269:0] external_cfg;
        integer saved_frames;
        wait(identities>=2 && frames>=4);
        wait(input_x==0 && input_y==0);@(negedge iclk);send_input=0;tick(10);
        external_cfg=descriptor();external_cfg[104]=1;
        external_cfg[103:92]=width;external_cfg[91:80]=height;external_cfg[79:74]=4+packing;
        external_cfg[73:42]=32'h20000100+32'h800000*dut.o_obuf0;
        external_cfg[41:28]=((width*(packing==1?3:4)+255)/256)*256;
        cfg=external_cfg;req=0;wait(ack==0);saved_frames=frames;
        wait(frames>=saved_frames+2);@(negedge iclk);
        cfg=descriptor();req=1;tick(20000);
        assert(!ack) else $fatal(1,"native reentry reused stale context with input paused");
        send_input=1;case_done=1;
      end
      11: begin
        wait(context_pending);@(negedge iclk);input_run=0;
        reset_n=0;req=0;cfg=0;session++;repeat(40) @(negedge aclk);
        reset_n=1;cfg=descriptor();req=1;repeat(100) @(negedge aclk);
        reset_n=0;req=0;repeat(40) @(negedge aclk);
        reset_n=1;req=1;repeat(100) @(negedge aclk);
        assert(!ack) else $fatal(1,"native repeated reset accepted pre-reset held context");
        input_x=0;input_y=0;input_frame=80;input_run=1;case_done=1;
        min_display_tag=80;
      end
      default:$fatal(1,"unknown native scenario");
    endcase
  end
  initial begin
    wait(total_inputs>=16);
    // A legal VRR frame can be much longer than the input raster. Preserve
    // the four complete-frame budget, allowing its configured worst-case
    // duration after the input/capture deadline, not the short VRR-off raster.
    if(vrr_enabled)
      repeat(4*(height+vrr_front+4+vrr_back)*(width+80)) @(negedge oclk);
    repeat(10000) @(negedge aclk);
    $display("NATIVE_WITNESS input_frames=%0d writes=%0d bursts=%0d reads=%0d returns=%0d ACK=%b o_size=%0d,%0d ready_tag=%b ready_valid=%b config_active=%b stream=%b",completed_inputs,writes,write_bursts,reads,returns,ack,dut.o_ihsize,dut.o_ivsize,ready_tag,ready_valid,active,stream_seen);
    assert(ack && seen_video && frames>=4 && identities>=(lowlat?1:3) && case_done)
      else $fatal(1,"RESET OWNERSHIP native bootstrap stalled despite real completed input frames and DDR returns");
  end
  initial #100000000000 $fatal(1,"native global deadline");
endmodule
