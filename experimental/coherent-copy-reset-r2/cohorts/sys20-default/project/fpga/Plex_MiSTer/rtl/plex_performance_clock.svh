`ifndef PLEX_PERFORMANCE_CLOCK_SVH
`define PLEX_PERFORMANCE_CLOCK_SVH

// Experimental whole-SYS clock. Pixel cadence stays at its approved 20 MHz
// timebase; DDR, SDRAM and the framework's audio/HDMI PLLs are not accelerated.
`ifdef PLEX_CLK_SYS_85
`define PLEX_PERF_SYS_HZ 85_000_000
`define PLEX_PERF_SYS_MULT 17
`define PLEX_PERF_SYS_DEN 4
`define PLEX_PERF_SYS_PLL "85.000000 MHz"
`elsif PLEX_CLK_SYS_180
`define PLEX_PERF_SYS_HZ 180_000_000
`define PLEX_PERF_SYS_MULT 9
`define PLEX_PERF_SYS_DEN 1
`define PLEX_PERF_SYS_PLL "180.000000 MHz"
`elsif PLEX_CLK_SYS_120
`define PLEX_PERF_SYS_HZ 120_000_000
`define PLEX_PERF_SYS_MULT 6
`define PLEX_PERF_SYS_DEN 1
`define PLEX_PERF_SYS_PLL "120.000000 MHz"
`else
`define PLEX_PERF_SYS_HZ 20_000_000
`define PLEX_PERF_SYS_MULT 1
`define PLEX_PERF_SYS_DEN 1
`define PLEX_PERF_SYS_PLL "20.000000 MHz"
`endif

// Round up only when the original duration is not representable in SYS cycles.
`define PLEX_PERF_SYS_CYCLES(cycles) (((cycles) * `PLEX_PERF_SYS_MULT + `PLEX_PERF_SYS_DEN - 1) / `PLEX_PERF_SYS_DEN)

`endif
