`timescale 1ps/1fs
module video_measurement_event_tb;
  realtime sys_half = 25000;
  integer alias_video = 1, native_ce = 0, vs_delay = 0;
  reg clk_sys = 0, clk_100 = 0, clk_video_free = 0;
  reg pause_sys = 0, pause_100 = 0, pause_video = 0;
  wire clk_video = alias_video ? clk_sys : clk_video_free;
  initial begin
    void'($value$plusargs("SYS_HALF=%f", sys_half));
    void'($value$plusargs("ALIAS_VIDEO=%d", alias_video));
    void'($value$plusargs("NATIVE_CE=%d", native_ce));
    void'($value$plusargs("VS_DELAY=%d", vs_delay));
    #1700;
    forever #(sys_half) if(!pause_sys) clk_sys = ~clk_sys;
  end
  initial begin #1100; forever #5000 if(!pause_100) clk_100 = ~clk_100; end
  initial begin #3200; forever #7000 if(!pause_video) clk_video_free = ~clk_video_free; end
  reg ce = 1, de = 0, hs = 0, vs = 0, hdmi_vs = 0;
  initial begin #3700; forever #2520000 hdmi_vs = ~hdmi_vs; end
  wire [45:0] bus;
  wire [35:0] ext;
  reg enable = 0, strobe = 0;
  reg [15:0] din = 0;
  assign bus[45:38] = {1'b0, hdmi_vs, clk_100, clk_video, ce, de, hs, vs};
  assign bus[35:33] = {1'b0, enable, strobe};
  assign bus[31:16] = din;
  assign ext[32] = 0;
  hps_io #(.CONF_STR("Plex;;")) dut (
    .clk_sys(clk_sys), .HPS_BUS(bus), .EXT_BUS(ext),
    .new_vmode(1'b0), .video_rotated(1'b0), .ioctl_wait(1'b0),
    .status_set(1'b0), .ioctl_upload_req(1'b0), .info_req(1'b0)
  );

  // Sixteen distinguishable real rasters. A configuration is selected at
  // falling VS and remains fixed through the entire following measured frame.
  integer x = 0, y = 0, frame = 0, width = 8, height = 3;
  integer htotal = 48, vtotal = 12, ce_acc = 0;
  integer ended_width = 0, ended_height = 0, ended_frame = -1;
  reg [15:0] configurations_seen = 0;
  reg synthetic_reset = 0;
  always @(negedge clk_video) begin
    if(ce) begin
      if(x == htotal-1) begin
        x = 0;
        if(y == vtotal-1) begin
          ended_frame = frame;
          ended_width = width;
          ended_height = height;
          frame = frame + 1;
          width = 8 + (frame % 16);
          height = 3 + (frame % 4);
          htotal = 48 + 2*(frame % 16);
          vtotal = 12 + (frame % 5);
          configurations_seen[frame % 16] = 1;
          y = 0;
        end else y = y + 1;
      end else x = x + 1;
      vs = y >= vtotal-2;
      hs = x < 4;
      de = y >= 2 && y < 2+height && x >= 8 && x < 8+width;
    end
    // Same4-of17 fractional cadence as the native SYS85 path. Signals are
    // registered after a beat; the next CE samples the registered coordinate.
    if(native_ce) begin
      ce = ce_acc >= 13;
      ce_acc = ce ? ce_acc-13 : ce_acc+4;
    end else ce = 1;
  end

  // Model a bounded late raw-VS synchronizer route to exercise tag-first as
  // well as normal VS-first. Only a one-bit first-stage signal is delayed;
  // no source IDs, held payload, timing values or validity flags are forced.
  reg [63:0] vs_route = 0;
  wire delayed_vs_meta = vs_route[vs_delay];
  always @(posedge clk_100) vs_route <= {vs_route[62:0], vs};
  initial begin
    #1;
    if(vs_delay) force dut.video_calc.timing_counter.vs_meta = delayed_vs_meta;
  end

  typedef struct packed {
    integer frame_number;
    logic [31:0] width, height, htime, vtime, pixels;
  } truth_t;
  truth_t truth[512];
  integer truth_count = 0;
  longint ticks = 0, last_hs_tick = 0, last_vs_tick = 0;
  reg vm = 0, vsync = 0, vold = 0, hm = 0, hsync = 0, hold_hs = 0;
  reg dm = 0, dsync = 0, dold = 0;
  reg first_line = 0;
  integer active_ticks = 0, measured_pixels = 0, measured_h = 0, measured_v = 0;
  integer rising_edges = 0;
  longint cut_tick[512], tag_tick[512];
  reg [31:0] observed_gray = 0;
  integer tag_first = 0, vs_first = 0, coincident = 0, delayed_more_than_one = 0;
  // Independent reference: timestamps of actual synchronized pin edges and
  // a count of high-DE CLK100 samples. Geometry comes from the raster
  // generator's completed frame, never from a DUT ID or assembly equality.
  always @(posedge clk_100) begin
    ticks = ticks + 1;
    if(!vold && vsync) begin
      measured_v = ticks-last_vs_tick-1;
      last_vs_tick = ticks;
      measured_pixels = active_ticks;
      active_ticks = 0;
      rising_edges = rising_edges + 1;
    end
    if(vold && !vsync) begin
      first_line = 1;
      if(ended_frame >= 0) begin
        cut_tick[ended_frame] = ticks;
        if(tag_tick[ended_frame] != 0 && tag_tick[ended_frame] < ticks)
          tag_first = tag_first + 1;
      end
      if(ended_frame >= 1 && rising_edges >= 2 && !synthetic_reset) begin
        truth[truth_count] = '{ended_frame, 32'(ended_width), 32'(ended_height),
                               32'(measured_h), 32'(measured_v), 32'(measured_pixels)};
        truth_count = truth_count + 1;
      end
    end
    if(!hold_hs && hsync) begin
      measured_h = ticks-last_hs_tick-1;
      last_hs_tick = ticks;
    end
    if(first_line && dsync) active_ticks = active_ticks + 1;
    if(dold && !dsync) first_line = 0;
    vm <= vs;
    vsync <= vs_delay ? delayed_vs_meta : vm;
    vold <= vsync;
    hm <= hs;
    hsync <= hm;
    hold_hs <= hsync;
    dm <= de;
    dsync <= dm;
    dold <= dsync;
    #1;
    if(dut.video_calc.frame_gray_sync != observed_gray) begin
      observed_gray = dut.video_calc.frame_gray_sync;
      if(!vs && y < 2 && ended_frame >= 0) begin
        tag_tick[ended_frame] = ticks;
        if(cut_tick[ended_frame] != 0 && ticks > cut_tick[ended_frame]) begin
          vs_first = vs_first + 1;
          if(ticks > cut_tick[ended_frame]+1)
            delayed_more_than_one = delayed_more_than_one + 1;
        end
        if(cut_tick[ended_frame] == ticks) coincident = coincident + 1;
      end
    end
  end

  task automatic sys_cycles(input integer n);
    repeat(n) @(negedge clk_sys);
  endtask
  task automatic word(input [15:0] value, output [15:0] response);
    @(negedge clk_sys); din = value; strobe = 1;
    @(negedge clk_sys); response = bus[15:0]; strobe = 0;
    @(negedge clk_sys);
  endtask
  integer queries = 0, full_observations = 0, partial_queries = 0, last_seen_frame = -1;
  integer pause_round = 0, reset_round = 0, recovery_checks = 0, ack_aborts = 0;
  reg done = 0;
  reg ever_measured = 0;
  reg [287:0] observed_image = 0;
  task automatic read_image(input integer count);
    reg [15:0] response;
    reg [287:0] image;
    integer found;
    enable = 1;
    word(16'h23, response);
    if(response !== 0) $fatal(1, "command response changed");
    image = 0;
    for(integer p = 1; p <= count; p = p+1) begin
      word(0, response);
      if(p <= 18) image[(p-1)*16 +:16] = response;
      else if(response !== 0) $fatal(1, "reserved host parameter changed");
    end
    enable = 0;
    sys_cycles(2);
    queries = queries + 1;
    if(count >= 18 && ever_measured && image == 0)
      $fatal(1, "last complete measurement was discarded during resynchronization");
    if(count < 18) partial_queries = partial_queries + 1;
    else if(image != 0) begin
      found = -1;
      for(integer i = 0; i < truth_count; i = i+1)
        if(image[47:16] == truth[i].width && image[79:48] == truth[i].height &&
           image[111:80] == truth[i].htime && image[143:112] == truth[i].vtime &&
           image[175:144] == truth[i].pixels) found = i;
      if(found < 0) begin
        $display("bad image w=%0d h=%0d ht=%0d vt=%0d px=%0d actual_frame=%0d pause_round=%0d reset_round=%0d truths=%0d",
                 image[47:16], image[79:48], image[111:80], image[143:112],
                 image[175:144], frame, pause_round, reset_round, truth_count);
        for(integer i = (truth_count>5 ? truth_count-5 : 0); i < truth_count; i=i+1)
          $display("truth frame=%0d w=%0d h=%0d ht=%0d vt=%0d px=%0d",
                   truth[i].frame_number, truth[i].width, truth[i].height,
                   truth[i].htime, truth[i].vtime, truth[i].pixels);
        $fatal(1, "PROVENANCE mismatch: host tuple is not any actual completed raster/timing cut");
      end
      last_seen_frame = truth[found].frame_number;
      observed_image = image;
      ever_measured = 1;
      full_observations = full_observations + 1;
    end
  endtask

  initial begin : host
    sys_cycles(3);
    while(!done) begin
      read_image(20);
      if(queries % 7 == 0) read_image(1);
      if(queries % 11 == 0) read_image(6);
      if(queries % 23 == 0) begin
        enable = 1;
        begin reg [15:0] r; word(16'h23, r); word(0, r); end
        wait(dut.video_calc.query_transfer.capture_pending);
        enable = 0;
        sys_cycles(3);
        ack_aborts = ack_aborts + 1;
      end
    end
  end

  task automatic recover_by(input integer after_frame, input integer budget);
    integer stop_frame;
    stop_frame = frame + budget;
    while(last_seen_frame < after_frame && frame < stop_frame) @(negedge clk_video);
    if(last_seen_frame < after_frame)
      $fatal(1, "bounded recovery failed after%0d last_seen=%0d current=%0d",
             after_frame, last_seen_frame, frame);
    recovery_checks = recovery_checks + 1;
  endtask
  task automatic miss_receiver_frames(input integer missed);
    integer start_frame, resumed_frame;
    wait(y == 0 && x >= 12 && !vs);
    @(negedge clk_100);
    pause_100 = 1;
    start_frame = frame;
    wait(frame >= start_frame + missed && y == 0 && x >= 4 && !vs);
    resumed_frame = frame;
    pause_100 = 0;
    pause_round = pause_round + 1;
    recover_by(resumed_frame+2, 7);
    wait(frame >= resumed_frame+8);
  endtask
  initial begin : campaign
    for(integer i=0;i<512;i=i+1) begin cut_tick[i]=0;tag_tick[i]=0;end
    wait(frame >= 6 && last_seen_frame >= 3);
    miss_receiver_frames(1);
    miss_receiver_frames(2);
    miss_receiver_frames(3);
    // Stopped source plus a reset pulse on the video pins, including the
    // actual aliased SYS/video case (the host naturally waits for SYS).
    wait(vs && y == vtotal-2 && x >= 8);
    @(negedge clk_video);
    if(alias_video) pause_sys = 1; else pause_video = 1;
    synthetic_reset = 1;
    force vs = 0;
    #600000;
    force vs = 1;
    #600000;
    release vs;
    synthetic_reset = 0;
    reset_round = reset_round + 1;
    if(alias_video) pause_sys = 0; else pause_video = 0;
    recover_by(frame+3, 8);
    // Simultaneous source/receiver stoppage does not reset either helper.
    @(negedge clk_100); pause_100 = 1;
    @(negedge clk_video);
    if(alias_video) pause_sys = 1; else pause_video = 1;
    #800000;
    if(alias_video) pause_sys = 0; else pause_video = 0;
    #300000; pause_100 = 0;
    recover_by(frame+3, 8);
    wait(frame >= 48);
    if(!partial_queries || !ack_aborts || recovery_checks != 5 ||
       (!vs_delay && alias_video && !vs_first) || (vs_delay && !tag_first) ||
       !(tag_first + vs_first + coincident))
      $fatal(1, "required coverage absent partial=%0d ACK=%0d recovery=%0d tag_first=%0d VS_first=%0d coincident=%0d",
             partial_queries, ack_aborts, recovery_checks, tag_first, vs_first, coincident);
    if(alias_video && !native_ce && !vs_delay && !delayed_more_than_one)
      $fatal(1, "reviewer's delayed-next-tag precondition not exercised");
    done = 1;
    sys_cycles(100);
    $display("PASS EVENT alias=%0d SYS_HALF=%0.6f native_ce=%0d VS_DELAY=%0d raster_configurations=%0d full_tuple_observations=%0d host_queries=%0d partial=%0d receiver_pause_scenarios=%0d reset_scenarios=%0d recovery_checks=%0d ACK_aborts=%0d tag_first_observations=%0d VS_first_observations=%0d coincident_observations=%0d tag_delay_gt1_observations=%0d",
             alias_video, sys_half, native_ce, vs_delay, $countones(configurations_seen),
             full_observations, queries, partial_queries, pause_round, reset_round+1,
             recovery_checks, ack_aborts, tag_first, vs_first, coincident, delayed_more_than_one);
    $finish;
  end
  initial begin #20000000000; $fatal(1, "20ms bounded campaign timeout frame=%0d queries=%0d last_seen=%0d", frame, queries, last_seen_frame); end
endmodule
