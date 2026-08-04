// Pulse CDC: src single-cycle pulse → dst single-cycle pulse via toggle.
// Safe for clk_src and clk_dst asynchronous (dedicated clk_pix PLL case).
//
// Protocol: src toggles a level on each accepted pulse; dst 2FF-syncs the
// level and edges to regenerate a 1-cycle pulse. Lost if src pulses faster
// than ~3 dst periods (caller must rate-limit — frame_start is fine).

module cdc_pulse_toggle #(
	parameter int STAGES = 2
)(
	input  wire clk_src,
	input  wire rst_src,
	input  wire pulse_src,

	input  wire clk_dst,
	input  wire rst_dst,
	output reg  pulse_dst
);
	(* preserve *) (* noprune *) reg toggle_src;
	always @(posedge clk_src) begin
		if (rst_src)
			toggle_src <= 1'b0;
		else if (pulse_src)
			toggle_src <= ~toggle_src;
	end

	wire toggle_dst;
	cdc_sync_bit #(.STAGES(STAGES)) u_sync (
		.clk_dst(clk_dst),
		.rst_dst(rst_dst),
		.d_src(toggle_src),
		.q_dst(toggle_dst)
	);

	(* preserve *) (* noprune *) reg toggle_dst_d;
	always @(posedge clk_dst) begin
		if (rst_dst) begin
			toggle_dst_d <= 1'b0;
			pulse_dst    <= 1'b0;
		end else begin
			toggle_dst_d <= toggle_dst;
			pulse_dst    <= (toggle_dst ^ toggle_dst_d);
		end
	end
endmodule
