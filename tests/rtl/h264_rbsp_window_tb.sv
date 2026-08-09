module h264_rbsp_window_tb (
  input  wire clk,
  input  wire reset,
  input  wire wr_clear,
  input  wire wr_en,
  input  wire [7:0] wr_data,
  input  wire wr_end,
  input  wire req_valid,
  input  wire [15:0] req_offset,
  output wire [7:0] window0,
  output wire [7:0] window1,
  output wire [7:0] window2,
  output wire [7:0] window3,
  output wire [7:0] window16,
  output wire [7:0] window63,
  output wire [15:0] window_base,
  output wire [15:0] length,
  output wire window_valid
);
  wire [7:0] window [0:63];
  wire [15:0] window_avail;
  wire complete, overflow;
  h264_rbsp_window #(.DEPTH_BYTES(256), .WINDOW_BYTES(64)) dut (
    .clk(clk), .reset(reset),
    .wr_clear(wr_clear), .wr_en(wr_en), .wr_data(wr_data), .wr_end(wr_end),
    .req_valid(req_valid), .req_offset(req_offset),
    .window(window), .window_base(window_base), .window_avail(window_avail),
    .length(length), .complete(complete), .overflow(overflow),
    .window_valid(window_valid)
  );
  assign window0 = window[0];
  assign window1 = window[1];
  assign window2 = window[2];
  assign window3 = window[3];
  assign window16 = window[16];
  assign window63 = window[63];
endmodule
