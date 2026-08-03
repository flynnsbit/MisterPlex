// plex_content_fps_sel — B15 / parent ABI arbitration #2
//
// Consumes PLXG q5 cadence fields only (w-clock). DAR is w-scaler.
// q5 @ doorbell+0x828 (w-mem owns latch/poller/B16 atomic promote):
//   [31:24] content_fps
//   [33]    fps_valid
//   (dar_* / reserved owned elsewhere)
//
// Rules:
//   fps_valid && content_fps != 0 → use content_fps for V_TOTAL class
//   else → UNSPECIFIED: film-class 24 (V=705). Do NOT invent 30.
//   Inventing idle-30 would close B15 by hardcoding the other way (forbidden).
//
// B15 FENCE (rd-duck / w-clock 15a371b4): frozen q5 uint8 cannot distinguish
// exact 24/30 from NTSC 24000/1001,30000/1001; product bresenham picks NTSC.
// Exact source-Hz is ABI-impossible until rational family is transported or
// swaps are source-clocked. This module only selects integer class — it does
// NOT claim source-exact cadence. Keep B15 OPEN for exact match.
//
// FAULT_B15_IGNORE_FPS_VALID: ignore q5, permanent 24 — red twin for
// "30 fps title exposes only 24 unique frames when fps_valid=0".
`default_nettype none
module plex_content_fps_sel (
	input  wire       fps_valid,
	input  wire [7:0] content_fps_q5,
	output wire [7:0] content_fps_eff
);
`ifdef FAULT_B15_IGNORE_FPS_VALID
	assign content_fps_eff = 8'd24;
`else
	assign content_fps_eff =
		(fps_valid && (content_fps_q5 != 8'd0)) ? content_fps_q5 : 8'd24;
`endif
endmodule
`default_nettype wire
