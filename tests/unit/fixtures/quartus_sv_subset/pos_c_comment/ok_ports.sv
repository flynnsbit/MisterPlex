module ok_ports (
  input  wire clk,
  input  wire [1:0] pattern, // 0=none(black) 1=bars — must not Class-C flag
  input  wire bit_ready,
  output wire q
);
  assign q = bit_ready & |pattern;
endmodule
