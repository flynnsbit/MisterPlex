`timescale 1ns/1ps
module terminator_reset_tb;
  reg clk=0,reset=1,wait_m=0,read_s=0,write_s=0;
  reg [7:0] burst_s=1,be_s=8'hff;
  reg [28:0] address_s=0;
  reg [63:0] wdata_s=0,rdata_m=0;
  reg valid_m=0;
  wire wait_s,read_m,write_m,valid_s;
  wire [7:0] burst_m,be_m;
  wire [28:0] address_m;
  wire [63:0] wdata_m,rdata_s;
  always #5 clk=~clk;
  f2sdram_safe_terminator #(64,8,1) dut(
    .clk(clk),.rst_req_sync(reset),
    .waitrequest_slave(wait_s),.burstcount_slave(burst_s),.address_slave(address_s),
    .readdata_slave(rdata_s),.readdatavalid_slave(valid_s),.read_slave(read_s),
    .writedata_slave(wdata_s),.byteenable_slave(be_s),.write_slave(write_s),
    .waitrequest_master(wait_m),.burstcount_master(burst_m),.address_master(address_m),
    .readdata_master(rdata_m),.readdatavalid_master(valid_m),.read_master(read_m),
    .writedata_master(wdata_m),.byteenable_master(be_m),.write_master(write_m));
  integer client_reads=0,memory_reads=0,client_writes=0,memory_writes=0;
  always @(posedge clk) begin
    if(read_s&&!wait_s) client_reads++;
    if(read_m&&!wait_m) memory_reads++;
    if(write_s&&!wait_s) client_writes++;
    if(write_m&&!wait_m) memory_writes++;
    assert(client_reads==memory_reads && client_writes==memory_writes)
      else $fatal(1,"phantom acceptance at persistent bridge");
    assert(!valid_m || (valid_s && rdata_s==rdata_m))
      else $fatal(1,"isolated/stalled return was masked");
    if(read_m||write_m)
      assert(address_m==address_s && burst_m==burst_s && be_m==be_s && wdata_m==wdata_s)
        else $fatal(1,"retained command payload/byteenable corrupted");
  end
  task automatic tick(input integer n=1);repeat(n) @(negedge clk);#0.1;endtask
  initial begin
    tick(3); read_s=1;burst_s=16;address_s=29'h1234;tick(3);
    assert(wait_s && !read_m) else $fatal(1,"unready bridge accepted new offer");
    reset=0; wait_m=1;tick(3);
    assert(read_m && wait_s) else $fatal(1,"bridge did not offer stalled read");
    reset=1;tick(3);
    assert(read_m && burst_m==16 && address_m=='h1234) else $fatal(1,"reset dropped stalled read");
    reset=0;tick(2);reset=1;tick(2);
    assert(read_m) else $fatal(1,"repeated reset dropped stalled read");
    wait_m=0;tick();read_s=0;tick();
    assert(memory_reads==1 && wait_s) else $fatal(1,"stalled read accounting");
    valid_m=1;rdata_m=64'h12345678;wait_m=1;tick(4);valid_m=0;wait_m=0;
    reset=0;tick(3);
    for(integer length=1;length<=16;length*=4) begin
      burst_s=8'(length);address_s+=29'h100;write_s=1;wait_m=1;tick(2);
      reset=1;tick(3);wait_m=0;
      for(integer beat=0;beat<length;beat++) begin
        wdata_s=64'(beat+'h1000*length);be_s=8'(beat+1);tick();
        if(beat+1<length) begin wait_m=1;tick(2);wait_m=0;end
      end
      write_s=0;tick(2);
      assert(wait_s && !write_m) else $fatal(1,"write did not quiesce after final beat");
      reset=0;tick(3);
    end
    assert(memory_writes==21) else $fatal(1,"write burst beat count");
    $display("PASS persistent terminator: read=1 write=21 held/repeated-reset/stalls/returns");
    $finish;
  end
  initial #10000 $fatal(1,"terminator deadline");
endmodule
