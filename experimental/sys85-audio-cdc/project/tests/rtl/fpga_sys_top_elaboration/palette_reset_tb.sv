`timescale 1ps/1ps
module palette_reset_tb;
  reg clk=0, reset=1, req=0, ack=0, active=0, clock_run=1;
  integer scenario=0;
  reg [269:0] cfg=0;
  reg audio_req=0;
  reg pause_returns=1, memory_wait=0;
  wire [28:0] pal_address, address, m_address;
  wire pal_request, bank, ready, valid, pal_valid, audio_valid;
  wire [63:0] pal_data, audio_data, data, wdata, m_wdata;
  wire [7:0] burst, index, be, m_burst, m_be;
  wire read_cmd, write_cmd, wait_req, m_read, m_write, data_valid;
  reg [63:0] memory_data=0;
  reg memory_valid=0;
  reg reset0=1, reset1=1;
  always #20345.052083 if(clock_run) clk=~clk; else clk=0;
  always @(posedge clk) begin reset0<=reset; reset1<=reset0; end
  scaler_palette palette(.clk(clk),.reset(reset),.cfg_data(cfg),.cfg_req(req),
    .cfg_ack(ack),.cfg_active(active),.hdmi_vs(1'b0),
    .data_ready(pal_valid),.data_index(index[6:0]),.address(pal_address),
    .request(pal_request),.write_bank(bank),.ready_tag(ready),.ready_valid(valid));
  ddr_svc service(.clk(clk),.ram_waitrequest(wait_req),.ram_burstcnt(burst),
    .ram_addr(address),.ram_readdata(data),.ram_read_ready(data_valid),
    .ram_read(read_cmd),.ram_writedata(wdata),.ram_byteenable(be),.ram_write(write_cmd),
    .ram_bcnt(index),.ch0_addr(29'h100),.ch0_burst(8'd4),.ch0_data(audio_data),
    .ch0_req(audio_req),.ch0_ready(audio_valid),.ch1_addr(pal_address),
    .ch1_burst(8'd128),.ch1_data(pal_data),.ch1_req(pal_request),.ch1_ready(pal_valid));
`ifdef RESET_PERSISTENT_MASTER
  f2sdram_safe_terminator #(64,8,1) bridge(
`else
  f2sdram_safe_terminator #(64,8) bridge(
`endif
    .clk(clk),.rst_req_sync(reset1),
    .waitrequest_slave(wait_req),.burstcount_slave(burst),.address_slave(address),
    .readdata_slave(data),.readdatavalid_slave(data_valid),.read_slave(read_cmd),
    .writedata_slave(wdata),.byteenable_slave(be),.write_slave(write_cmd),
    .waitrequest_master(memory_wait),.burstcount_master(m_burst),.address_master(m_address),
    .readdata_master(memory_data),.readdatavalid_master(memory_valid),.read_master(m_read),
    .writedata_master(m_wdata),.byteenable_master(m_be),.write_master(m_write));
  integer pending=0, word_index=0, issued=0, accepted=0, returned=0;
  integer palette_words=0, audio_words=0, loads=0;
  reg [28:0] saved_address;
  always @(posedge clk) begin
    if(read_cmd && !wait_req) accepted++;
    if(m_read && !memory_wait) begin
      assert(pending==0) else $fatal(1,"overlapping unowned memory command");
      pending=m_burst; saved_address=m_address; word_index=0; issued++;
      if(m_burst==128) loads++;
    end
    if(memory_valid) returned++;
    if(pal_valid) begin
      palette_words++;
      assert(pal_data[6:0]==index[6:0]) else $fatal(1,"palette content/index");
      assert(pal_data[35:7]==saved_address) else $fatal(1,"palette descriptor/content");
    end
    if(audio_valid) audio_words++;
  end
  // Accepted commands and data survive framework reset and isolation.
  always @(negedge clk) begin
    memory_valid=0;
    if(pending && !pause_returns) begin
      memory_valid=1; memory_data={28'b0,saved_address,7'(word_index)};
      pending--; word_index++;
    end
  end
  task automatic tick(input integer n=1); repeat(n) @(negedge clk); #1; endtask
  task automatic submit(input reg [31:0] base);
    cfg=0; cfg[104]=1; cfg[76:74]=3'b011; cfg[73:42]=base; req=~req;
  endtask
  initial begin
    void'($value$plusargs("CASE=%d",scenario));
    tick(5); reset=0; tick(8);
    if(scenario==0) begin
      audio_req=1; tick(8);
      assert(issued==1 && pending==4) else $fatal(1,"audio not accepted");
      submit(32'h102000); tick(12);
      assert(palette.busy && loads==0) else $fatal(1,"palette not queued behind audio");
    end else begin
      submit(32'h102000);
      if(scenario==1) begin
        wait(read_cmd); @(negedge clk); #1; memory_wait=1; tick(8);
        assert(m_read && pending==0) else $fatal(1,"palette held-offer setup");
      end else begin
        tick(15); assert(pending==128) else $fatal(1,"palette accepted setup");
        if(scenario==2) begin
          pause_returns=0; tick(32);pause_returns=1;
          assert(pending>0 && pending<128) else $fatal(1,"palette split setup");
        end
      end
    end
    reset=1; req=0; ack=0; active=0; tick(8);
    if(scenario==0) begin
      pause_returns=0; tick(24); pause_returns=1;
      assert(audio_words==4) else $fatal(1,"RESET OWNERSHIP audio response lost in isolation");
    end
    if(scenario==1) begin
      memory_wait=0; pause_returns=0; tick(140); pause_returns=1;
      assert(palette_words==128 && !valid) else $fatal(1,"RESET OWNERSHIP held palette lost during reset");
    end
    if(scenario==3) begin
      @(negedge clk); clock_run=0;
      #100000 reset=0; #100000 reset=1; #100000;
      assert(!valid) else $fatal(1,"stopped-clock palette stale readiness");
      clock_run=1;tick(5);
    end
    reset=0; submit(32'h204000); tick(20); pause_returns=0;
    if(scenario==2) begin
      pause_returns=1;reset=1;req=0;tick(6);reset=0;req=1;tick(20);pause_returns=0;
    end
    for(integer n=0;n<1000 && !(valid && ready==req);n++) tick();
    $display("WITNESS palette accepted=%0d issued=%0d returned=%0d words=%0d audio=%0d ready=%0b busy=%0b",
      accepted,issued,returned,palette_words,audio_words,valid,palette.busy);
    assert(valid && ready==req && palette_words==256 && loads==2)
      else $fatal(1,"RESET OWNERSHIP palette bounded replacement readiness/content failure");
    assert(accepted==issued && returned==(scenario==0?260:256) && !pending)
      else $fatal(1,"RESET OWNERSHIP palette bridge acceptance mismatch");
    $display("PASS palette actual RAM2 isolation retained traffic case=%0d",scenario);
    $finish;
  end
  initial #100000000 $fatal(1,"palette global deadline");
endmodule
