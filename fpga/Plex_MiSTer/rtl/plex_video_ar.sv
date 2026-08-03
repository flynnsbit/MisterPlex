// plex_video_ar — MiSTer VIDEO_ARX/VIDEO_ARY policy for Plex.
//
// Menu (status[122:121] / CONF_STR Aspect ratio):
//   0 Original     → host DAR when valid, else legacy 4:3 (defect if content is 16:9)
//   1 Full Screen  → 0:0 (framework special — fill)
//   2 ARC1         → ARX=1 ARY=0 (framework ARC slot)
//   3 ARC2         → ARX=2 ARY=0
//
// Runtime-DE rule (B9 + parent ABI arbitration #2):
//   Display aspect is NOT inferred from coded WxH. PMS anamorphic titles
//   (e.g. 720×480) prove storage AR ≠ display AR. Daemon publishes DAR on
//   PLXG q5 (dar_x[11:0], dar_y[23:12], dar_valid[32]). Fabric only muxes.
//
// Ports VIDEO_ARX/VIDEO_ARY match emu_ports.vh (12-bit ratio; bit12 scaled-size
// mode is not used here).
`default_nettype none

module plex_video_ar (
	input  wire [1:0]  ar_menu,       // status[122:121]
	input  wire        host_dar_valid, // PLXG DAR present
	input  wire [11:0] host_dar_x,     // e.g. 16
	input  wire [11:0] host_dar_y,     // e.g. 9
	output wire [12:0] VIDEO_ARX,
	output wire [12:0] VIDEO_ARY
);
	wire host_ok = host_dar_valid && (host_dar_x != 12'd0) && (host_dar_y != 12'd0);

	reg [11:0] arx_r;
	reg [11:0] ary_r;

	always @(*) begin
		// Defaults (should be overwritten every branch).
		arx_r = 12'd4;
		ary_r = 12'd3;
		case (ar_menu)
			2'd0: begin
				// Original: prefer host DAR (PMS); legacy 4:3 if absent.
				if (host_ok) begin
					arx_r = host_dar_x;
					ary_r = host_dar_y;
				end else begin
					arx_r = 12'd4;
					ary_r = 12'd3;
				end
			end
			2'd1: begin
				// Full Screen
				arx_r = 12'd0;
				ary_r = 12'd0;
			end
			2'd2: begin
				arx_r = 12'd1;
				ary_r = 12'd0;
			end
			default: begin
				// ARC2
				arx_r = 12'd2;
				ary_r = 12'd0;
			end
		endcase
	end

	assign VIDEO_ARX = {1'b0, arx_r};
	assign VIDEO_ARY = {1'b0, ary_r};
endmodule

`default_nettype wire
