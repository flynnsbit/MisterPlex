// Placeholder — H264 Expert drops HEVC Main 8-bit I/P RTL here.
// Not instantiated from Plex.sv. No DDRAM m2 ports. DCE until wired.
// CABAC must not run on clk_sys 20 MHz at 720p30 (use clk_ddr 90 MHz later).
module hevc_dpb (
  input wire clk,
  input wire reset
);
endmodule
