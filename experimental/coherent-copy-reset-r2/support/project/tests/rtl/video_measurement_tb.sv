`timescale 1ps/1fs
module video_measurement_tb;
  realtime sys_half = 25000;
  realtime clk100_phase = 1100;
  reg clk_sys = 0, clk_vid = 0, clk_100 = 0;
  reg pause_vid = 0;
  initial begin
    if (!$value$plusargs("SYS_HALF=%f", sys_half)) sys_half = 25000;
    #1700;
    forever #(sys_half) clk_sys = ~clk_sys;
  end
  initial begin #3200; forever #7000 if(!pause_vid) clk_vid = ~clk_vid; end
  initial begin
    if (!$value$plusargs("CLK100_PHASE=%f", clk100_phase)) clk100_phase = 1100;
    #(clk100_phase);
    forever #5000 clk_100 = ~clk_100;
  end
  reg io_enable = 0, io_strobe = 0;
  reg [15:0] io_din = 0;
  reg de = 0, hs = 0, vs = 0, vs_hdmi = 0, rotated = 0, mode = 0;
  reg field_one = 0, interlaced = 0;
  wire [45:0] bus;
  wire [35:0] ext;
  assign bus[45:38] = {field_one, vs_hdmi, clk_100, clk_vid, 1'b1, de, hs, vs};
  assign bus[35:33] = {1'b0, io_enable, io_strobe};
  assign bus[31:16] = io_din;
  assign ext[32] = 0;
  hps_io #(.CONF_STR("Plex;;")) dut (
    .clk_sys(clk_sys), .HPS_BUS(bus), .EXT_BUS(ext),
    .new_vmode(mode), .video_rotated(rotated), .ioctl_wait(1'b0),
    .status_set(1'b0), .ioctl_upload_req(1'b0), .info_req(1'b0)
  );

  integer x = 0, y = 0, frames = 0, active_w = 8, active_h = 4;
  reg alternate_modes = 0;
  always @(negedge clk_vid) begin
    if(x == 31) begin
      x = 0;
      if(y == 15) begin
        y = 0;
        frames = frames + 1;
        field_one = interlaced && frames[0];
        if(alternate_modes) begin
          active_w = frames[0] ? 12 : 8;
          active_h = frames[0] ? 6 : 4;
          mode = frames[0];
          rotated = frames[0];
        end
      end else y = y + 1;
    end else x = x + 1;
    vs = y < 2;
    hs = x < 4;
    de = y >= 4 && y < 4 + active_h && x >= 8 && x < 8 + active_w;
  end
  initial begin #3700; forever #2520000 vs_hdmi = ~vs_hdmi; end

  task automatic cycles(input integer n);
    repeat(n) @(negedge clk_sys);
  endtask
  task automatic word(input [15:0] value, output [15:0] response);
    @(negedge clk_sys);
    io_din = value;
    io_strobe = 1;
    @(negedge clk_sys);
    response = bus[15:0];
    io_strobe = 0;
    // Matches the existing registered video_calc/IO response pipeline.
    @(negedge clk_sys);
  endtask
  task automatic finish_query;
    io_enable = 0;
    cycles(2);
  endtask
  reg [15:0] response;
  reg [287:0] expected;
  integer queries = 0, producer_publications = 0, frame_mismatch_cycles = 0;
  integer hold_checks = 0, query_checks = 0, ack_abort_checks = 0;
  reg [287:0] previous_hold = 0, previous_query = 0;
  reg [287:0] before_publication, before_query_source;
  reg [169:0] previous_frame_hold = 0;
  reg previous_busy = 0, previous_query_started = 0;
  reg previous_frame_busy = 0, join_allowed;
  reg last_query_start = 0;
  always @(posedge clk_100) begin
    before_publication = dut.video_calc.measurement_100;
    join_allowed = dut.video_calc.frame_100_valid && dut.video_calc.frame_time_valid &&
                   dut.video_calc.frame_100[169:138] == dut.video_calc.frame_id_100;
    #1;
    if(!join_allowed && dut.video_calc.measurement_100 !== before_publication)
      $fatal(1, "unmatched frame was published");
    if(previous_busy && dut.video_calc.query_transfer.src_hold !== previous_hold)
      $fatal(1, "source changed held query data before ACK");
    previous_hold = dut.video_calc.query_transfer.src_hold;
    previous_busy = dut.video_calc.query_transfer.src_req != dut.video_calc.query_transfer.ack_sync;
    hold_checks = hold_checks + 1;
    if(dut.video_calc.frame_100_valid &&
       dut.video_calc.frame_100[169:138] != dut.video_calc.frame_id_100)
      frame_mismatch_cycles = frame_mismatch_cycles + 1;
  end
  always @(posedge clk_vid) begin
    #1;
    if(previous_frame_busy && dut.video_calc.frame_transfer.src_hold !== previous_frame_hold)
      $fatal(1, "source changed held frame descriptor before ACK");
    previous_frame_hold = dut.video_calc.frame_transfer.src_hold;
    previous_frame_busy = dut.video_calc.frame_transfer.src_req != dut.video_calc.frame_transfer.ack_sync;
  end
  always @(posedge clk_sys) begin
    last_query_start = dut.video_calc.query_start;
    before_query_source = dut.video_calc.measurement_sys;
    #1;
    if(last_query_start && dut.video_calc.query_snapshot !== before_query_source)
      $fatal(1, "query did not freeze latest completed publication");
    if(previous_query_started && !last_query_start &&
       dut.video_calc.query_snapshot !== previous_query)
      $fatal(1, "query snapshot changed without command0x23");
    previous_query = dut.video_calc.query_snapshot;
    previous_query_started = 1;
    query_checks = query_checks + 1;
  end

  task automatic start_query;
    io_enable = 1;
    word(16'h23, response);
    expected = dut.video_calc.query_snapshot;
    if(response !== 0) $fatal(1, "command response changed");
    queries = queries + 1;
  endtask
  task automatic read_query(input integer count, input integer slow_at);
    for(integer p = 1; p <= count; p = p + 1) begin
      if(p == slow_at) cycles(1400);
      word(0, response);
      if(p <= 18) begin
        if(response !== expected[(p-1)*16 +: 16])
          $fatal(1, "query%0d param%0d got%04x expected%04x",
                 queries, p, response, expected[(p-1)*16 +: 16]);
      end else if(response !== 0) $fatal(1, "reserved parameter changed");
    end
    finish_query();
  endtask

  reg [169:0] inject_frame;
  reg [127:0] inject_time;
  reg [287:0] inject_expected;
  integer saved_frames;
  reg [7:0] saved_nres;
  reg [31:0] saved_id;
  reg [31:0] saved_completed_id;
  task automatic full_width_epoch(input integer epoch);
    // Stimulate real producer-output registers; exercise both actual CDC
    // instances, assembler, query latch and the actual hps_io host command.
    inject_frame = {32'h87650000 + epoch, 10'h300 | 10'(epoch),
      32'hf1234567 ^ epoch, 32'h8abcdeff ^ epoch, 32'hdcba9876 ^ epoch,
      8'hf3 ^ 8'(epoch), 16'hbeef ^ 16'(epoch), 8'had ^ 8'(epoch)};
    inject_time = {32'h9abc0123 ^ epoch, 32'hcafe2345 ^ epoch,
                   32'habcd1234 ^ epoch, 32'hfedc6789 ^ epoch};
    inject_expected = {
      8'd0, inject_frame[7:0], inject_frame[23:8], 8'd0, inject_frame[31:24],
      inject_frame[63:32], inject_time, inject_frame[95:64],
      inject_frame[127:96], 6'd0, inject_frame[137:128]
    };
    force dut.video_calc.frame_vid = inject_frame;
    force dut.video_calc.frame_vid_valid = 1'b1;
    force dut.video_calc.frame_id_100 = inject_frame[169:138];
    force dut.video_calc.frame_time_100 = inject_time;
    force dut.video_calc.frame_time_valid = 1'b1;
    wait(dut.video_calc.measurement_sys === inject_expected);
    cycles(3);
  endtask

  initial begin
    cycles(3);
    start_query();
    if(expected !== 0) $fatal(1, "startup is not unmeasured zero");
    read_query(20, 0);
    wait(dut.video_calc.measurement_sys_valid);
    cycles(20);
    start_query();
    if(expected[47:16] != 8 || expected[79:48] != 4)
      $fatal(1, "actual producer dimensions mismatch %0d/%0d",
             expected[47:16], expected[79:48]);
    if(expected[111:80] < 43 || expected[111:80] > 45 ||
       expected[143:112] < 715 || expected[143:112] > 718 ||
       expected[175:144] < 10 || expected[175:144] > 12 ||
       expected[207:176] < 502 || expected[207:176] > 504 ||
       expected[239:208] != 8 || expected[255:240] != 1)
      $fatal(1, "actual producer periods/pixels/repeat mismatch %h", expected);
    read_query(20, 7);
    alternate_modes = 1;
    repeat(14) begin
      start_query();
      if(!((expected[47:16] == 8 && expected[79:48] == 4 && !expected[9]) ||
           (expected[47:16] == 12 && expected[79:48] == 6 && expected[9])))
        $fatal(1, "mode/frame identity mixed: %h", expected);
      read_query(20, 7);
      producer_publications = producer_publications + 1;
    end
    alternate_modes = 0;
    saved_frames = frames;
    saved_nres = dut.video_calc.measurement_sys[7:0];
    wait(frames >= saved_frames + 20);
    start_query();
    if(expected[7:0] == saved_nres) $fatal(1, "stable-mode identity timeout never reported");
    read_query(20, 0);

    // Core timing can be reset while its producer clock is stopped; the
    // measurement block itself has no reset port. CLK100 sees this extra VS
    // edge, clk_vid cannot. Recovery must not require equal local counters.
    wait(vs && dut.video_calc.query_transfer.capture_pending);
    @(negedge clk_vid);
    pause_vid = 1;
    saved_id = dut.video_calc.frame_id_vid;
    saved_completed_id = dut.video_calc.frame_vid[169:138];
    force vs = 0;
    cycles(12);
    force vs = 1;
    cycles(12);
    if(dut.video_calc.frame_id_vid != saved_id) $fatal(1, "paused source observed an edge");
    release vs;
    pause_vid = 0;
    // The event ID now advances on both VS transitions. Preserve the old
    // four-completed-field budget, and compare completed-cut identities,
    // not the current (possibly rising-edge) source event ID.
    wait(dut.video_calc.frame_vid[169:138] >= saved_completed_id + 8);
    cycles(30);
    if(!dut.video_calc.frame_time_valid ||
       dut.video_calc.frame_id_100 != dut.video_calc.frame_vid[169:138] ||
       dut.video_calc.frame_100[169:138] != dut.video_calc.frame_vid[169:138])
      $fatal(1, "producer clock/reset edge did not realign frame tags");
    start_query(); read_query(20, 0);
    interlaced = 1;
    saved_frames = frames;
    wait(frames >= saved_frames + 6);
    cycles(30);
    start_query();
    if(!expected[8] || expected[47:16] != active_w ||
       expected[79:48] != active_h*2)
      $fatal(1, "interlaced field identity/geometry mixed %h", expected);
    read_query(20, 0);
    interlaced = 0;
    // Real host's unchanged-resolution poll consumes only parameter1.
    start_query(); read_query(1, 0);
    // Partial low-half read, unrelated command and a fresh back-to-back query.
    start_query(); read_query(6, 0);
    io_enable = 1;
    word(16'h01, response);
    word(16'h0003, response);
    finish_query();
    start_query(); read_query(20, 0);

    for(integer e = 1; e <= 8; e = e + 1) begin
      full_width_epoch(e);
      start_query();
      if(expected !== inject_expected) $fatal(1, "full-width epoch not published");
      word(0, response);
      if(response !== expected[15:0]) $fatal(1, "identity changed");
      word(0, response);
      if(response !== expected[31:16]) $fatal(1, "low word changed");
      full_width_epoch(e + 100);
      for(integer p = 3; p <= 20; p = p + 1) begin
        word(0, response);
        if(p <= 18 && response !== expected[(p-1)*16 +: 16])
          $fatal(1, "full-width torn or mixed epoch at param%0d", p);
        if(p > 18 && response !== 0) $fatal(1, "reserved full-width response");
      end
      finish_query();
      start_query(); read_query(1, 0);
    end

    // Abort the transport exactly while the background channel acknowledges.
    repeat(12) begin
      start_query();
      word(0, response);
      wait(dut.video_calc.query_transfer.capture_pending);
      io_enable = 0;
      cycles(8);
      if(dut.byte_cnt != 0) $fatal(1, "transport abort did not reset counter");
      start_query(); read_query(20, 0);
      ack_abort_checks = ack_abort_checks + 1;
    end
    if(!frame_mismatch_cycles || !ack_abort_checks || queries < 40)
      $fatal(1, "coverage was not exercised");
    $display("PASS video_measurement SYS_HALF=%0.6f CLK100_PHASE=%0.1f queries=%0d producer_modes=%0d mismatch_cycles=%0d hold_checks=%0d query_checks=%0d ack_abort=%0d producer_reset_recovery=1 stable_identity=1 interlaced=1",
             sys_half, clk100_phase, queries, producer_publications, frame_mismatch_cycles,
             hold_checks, query_checks, ack_abort_checks);
    $finish;
  end
  initial begin
    #2000000000;
    $fatal(1, "bounded simulation timeout queries=%0d modes=%0d aborts=%0d",
           queries, producer_publications, ack_abort_checks);
  end
endmodule
