// Top-level VIDEO_ARX / VIDEO_ARY pin TB — mirrors Plex.sv B9 wiring.
// Gate B9_NO_AR_TOPLEVEL_TEST: assert real pins, not a fit-card table.
//
// Instantiates plex_video_ar exactly as Plex.sv (u_plex_video_ar), with the
// same port names VIDEO_ARX/VIDEO_ARY as emu_ports.vh.
`default_nettype none

module plex_ar_pins_tb (
	input  wire [1:0]  ar_menu,
	input  wire        host_dar_valid,
	input  wire [11:0] host_dar_x,
	input  wire [11:0] host_dar_y,
	// Real MiSTer core pins (emu_ports.vh width).
	output wire [12:0] VIDEO_ARX,
	output wire [12:0] VIDEO_ARY
);
	// Lockstep with fpga/Plex_MiSTer/Plex.sv u_plex_video_ar.
	plex_video_ar u_plex_video_ar (
		.ar_menu(ar_menu),
		.host_dar_valid(host_dar_valid),
		.host_dar_x(host_dar_x),
		.host_dar_y(host_dar_y),
		.VIDEO_ARX(VIDEO_ARX),
		.VIDEO_ARY(VIDEO_ARY)
	);
endmodule

`default_nettype wire
