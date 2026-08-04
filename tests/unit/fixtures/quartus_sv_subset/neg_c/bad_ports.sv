module bad_ports (
  input  wire clk,
  input  wire bit_ready = 1'b1,
  input  wire [1:0] mode = 2'b00,
  output wire q
);
  assign q = bit_ready;
endmodule
