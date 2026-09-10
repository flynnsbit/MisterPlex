// Fair clk_sys sub-arbiter: paused/full video ingress cannot hide audio control.
// Both clients use held, single-qword DDR requests; accepted reads retain their
// response owner across reset. Reset is not an asynchronous transaction cancel.
module audio_session_ddr_mux (
	input wire clk,
	input wire reset,
	input wire [28:0] video_addr,
	input wire video_rd, video_we,
	input wire [63:0] video_din,
	output wire video_busy,
	output wire [63:0] video_dout,
	output wire video_dout_ready,
	input wire [28:0] audio_addr,
	input wire audio_rd, audio_we,
	input wire [63:0] audio_din,
	output wire audio_busy,
	output wire [63:0] audio_dout,
	output wire audio_dout_ready,
	output wire ddr_want,
	output wire [28:0] ddr_addr,
	output wire ddr_rd, ddr_we,
	output wire [63:0] ddr_din,
	input wire ddr_busy,
	input wire [63:0] ddr_dout,
	input wire ddr_dout_ready
);
	reg prefer_audio = 0;
	reg outstanding = 0, response_audio = 0;
	reg stalled = 0, stalled_audio = 0;
	reg [94:0] stalled_command = 0;
	wire video_valid = video_rd || video_we;
	wire audio_valid = audio_rd || audio_we;
	wire select_audio = stalled ? stalled_audio :
	                    audio_valid && (prefer_audio || !video_valid);
	wire may_issue = !outstanding && (!reset || stalled);
	wire [94:0] command = stalled ? stalled_command :
	                     select_audio ? {audio_rd, audio_we, audio_addr, audio_din} :
	                                    {video_rd, video_we, video_addr, video_din};
	assign ddr_addr = command[92:64];
	assign ddr_din = command[63:0];
	assign ddr_rd = may_issue && command[94];
	assign ddr_we = may_issue && command[93];
	assign ddr_want = ddr_rd || ddr_we || outstanding;
	assign video_busy = !may_issue || select_audio || ddr_busy;
	assign audio_busy = !may_issue || !select_audio || ddr_busy;
	wire accepted = !ddr_busy && (ddr_rd || ddr_we);
	wire accepted_read = !ddr_busy && ddr_rd;
	wire valid_response = ddr_dout_ready && (outstanding || accepted_read);
	wire owner_audio = outstanding ? response_audio : select_audio;
	assign video_dout = ddr_dout;
	assign audio_dout = ddr_dout;
	assign video_dout_ready = valid_response && !owner_audio;
	assign audio_dout_ready = valid_response && owner_audio;
	always @(posedge clk) begin
		if (!stalled && (ddr_rd || ddr_we) && ddr_busy) begin
			stalled <= 1;
			stalled_audio <= select_audio;
			stalled_command <= command;
		end
		if (valid_response) outstanding <= 0;
		if (accepted) begin
			prefer_audio <= !select_audio;
			stalled <= 0;
		end
		if (accepted_read) begin
			response_audio <= select_audio;
			outstanding <= !ddr_dout_ready;
		end
	end
endmodule
