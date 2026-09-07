// Independent, held-request DDR control lane for the actual MrAudio consumer.
// Bundled CDC payloads are immutable from request through acknowledgement.
module audio_session_mailbox #(
	parameter ENABLE = 1'b0,
	parameter POLL_CYCLES = 1024
) (
	input wire clk,
	input wire reset,
	input wire [63:0] session_epoch,
	input wire [63:0] probe_nonce,
	input wire session_active,
	output wire supported,

	output wire ddr_want,
	input wire ddr_busy,
	output wire [28:0] ddr_addr,
	output wire ddr_rd,
	output wire ddr_we,
	output wire [63:0] ddr_din,
	input wire [63:0] ddr_dout,
	input wire ddr_dout_ready,

	output reg audio_ctrl_toggle = 0,
	output reg [216:0] audio_ctrl_data = 0,
	input wire audio_ctrl_ack_toggle,
	output reg audio_snapshot_toggle = 0,
	input wire audio_snapshot_ack_toggle,
	input wire [447:0] audio_snapshot_data,

	output reg [63:0] clock_epoch = 0,
	output reg [63:0] clock_nonce = 0,
	output reg [63:0] samples_consumed = 0,
	// A current, successful consumer ACK snapshot for this active video
	// identity. Paused audio has a valid frozen clock; reset/inactive does not.
	output reg clock_valid = 0,
	output reg clock_active = 0,
	output reg clock_paused = 1,
	// False until a coherent consumer snapshot proves inactivity and no
	// prefetched/in-flight DMA. A dispatched command revokes this proof.
	output reg consumer_quiescent = 0
);
	`include "audio_session_abi.svh"
	assign supported = ENABLE;
	localparam IDLE=0, READ_FIRST=1, WAIT_FIRST=2, READ_BODY=3, WAIT_BODY=4,
	           CHECK=5, WAIT_ACK=6, SNAPSHOT=7, WAIT_SNAPSHOT=8,
	           INVALIDATE=9, WRITE_BODY=10, COMMIT=11;
	reg [3:0] state = IDLE;
	reg [31:0] poll_count = 0;
	reg [2:0] index = 0;
	reg [63:0] first_commit = 0;
	reg [63:0] request_words [0:5];
	reg [447:0] publication_data = 0;
	reg [31:0] publication = 0;
	reg [216:0] last_command = 0;
	reg have_command = 0;
	reg consumer_identity_valid = 0;
	reg ack_s1 = 0, ack_s2 = 0, snap_s1 = 0, snap_s2 = 0;
	wire reading = state == READ_FIRST || state == READ_BODY;
	wire writing = state == INVALIDATE || state == WRITE_BODY || state == COMMIT;
	assign ddr_want = ENABLE && (reading || writing ||
	                            state == WAIT_FIRST || state == WAIT_BODY);
	assign ddr_rd = ENABLE && reading;
	assign ddr_we = ENABLE && writing;
	wire [31:0] byte_address =
		(state == READ_FIRST) ? AUDIO_CONTROL_COMMIT_ADDR :
		(state == READ_BODY) ? AUDIO_CONTROL_ADDR + {26'd0, index, 3'd0} :
		(state == WRITE_BODY) ? AUDIO_STATUS_ADDR + {26'd0, index, 3'd0} :
		                       AUDIO_STATUS_COMMIT_ADDR;
	assign ddr_addr = byte_address[31:3];
	assign ddr_din = state == WRITE_BODY ? publication_data[index*64 +: 64] :
	                 state == COMMIT ? {publication, AUDIO_STATUS_COMMIT_MAGIC} : 64'd0;
	wire read_arrived = ddr_dout_ready &&
		(state == WAIT_FIRST || state == WAIT_BODY || (reading && !ddr_busy));
	wire [216:0] requested_command =
		{request_words[4][18:2], request_words[0][55:48],
		 request_words[3], request_words[2], request_words[1]};
	wire live_identity = request_words[1] == session_epoch &&
	                     request_words[2] == probe_nonce &&
	                     (session_active || request_words[0][55:48] == 4);
	// Local video reset can clear its identity before the DMA consumer retires.
	// Only Reset may recover the last coherently observed actual audio owner;
	// it must never override a different active video session.
	wire reset_recovery_identity = !session_active && consumer_identity_valid &&
	                               request_words[0][55:48] == 4 &&
	                               request_words[1] == clock_epoch &&
	                               request_words[2] == clock_nonce;
	wire request_valid =
		first_commit == request_words[5] &&
		first_commit[31:0] == AUDIO_CONTROL_COMMIT_MAGIC && first_commit[63:32] != 0 &&
		request_words[0][31:0] == AUDIO_CONTROL_MAGIC &&
		request_words[0][47:32] == AUDIO_ABI_VERSION && request_words[0][63:56] == 0 &&
		request_words[0][55:48] >= 1 && request_words[0][55:48] <= 4 &&
		request_words[1] != 0 && request_words[2] != 0 && request_words[3] != 0 &&
		request_words[4][63:19] == 0 && request_words[4][1:0] == 0 &&
		(live_identity || reset_recovery_identity);

	always @(posedge clk) begin
		ack_s1 <= audio_ctrl_ack_toggle;
		ack_s2 <= ack_s1;
		snap_s1 <= audio_snapshot_ack_toggle;
		snap_s2 <= snap_s1;
		if (reset) consumer_identity_valid <= 0;
		if (reset || !session_active || session_epoch == 0 || probe_nonce == 0 ||
		    clock_epoch != session_epoch || clock_nonce != probe_nonce)
			clock_valid <= 0;
		if (ENABLE) begin
			case (state)
			IDLE: if (poll_count == 0) state <= READ_FIRST;
			      else poll_count <= poll_count - 1'b1;
			READ_FIRST: if (!ddr_busy) state <= WAIT_FIRST;
			WAIT_FIRST: begin end
			READ_BODY: if (!ddr_busy) state <= WAIT_BODY;
			WAIT_BODY: begin end
			CHECK: begin
				if (!reset && request_valid && (!have_command || requested_command != last_command)) begin
					audio_ctrl_data <= requested_command;
					audio_ctrl_toggle <= ~audio_ctrl_toggle;
					clock_valid <= 0;
					consumer_quiescent <= 0;
					consumer_identity_valid <= 0;
					last_command <= requested_command;
					have_command <= 1;
					state <= WAIT_ACK;
				end else state <= SNAPSHOT;
			end
			WAIT_ACK: if (ack_s2 == audio_ctrl_toggle) state <= SNAPSHOT;
			SNAPSHOT: begin
				audio_snapshot_toggle <= ~audio_snapshot_toggle;
				state <= WAIT_SNAPSHOT;
			end
			WAIT_SNAPSHOT: if (snap_s2 == audio_snapshot_toggle) begin
				publication_data <= {audio_snapshot_data[447:40],
				                     AUDIO_ABI_VERSION[7:0], AUDIO_STATUS_MAGIC};
				publication <= (publication == 32'hffffffff) ? 32'd1 : publication + 1'b1;
				clock_epoch <= audio_snapshot_data[127:64];
				clock_nonce <= audio_snapshot_data[191:128];
				consumer_identity_valid <= !reset && audio_snapshot_data[44] &&
				                           audio_snapshot_data[127:64] != 0 &&
				                           audio_snapshot_data[191:128] != 0;
				samples_consumed <= audio_snapshot_data[319:256];
				clock_valid <= !reset && session_active &&
				               session_epoch != 0 && probe_nonce != 0 &&
				               audio_snapshot_data[44] && audio_snapshot_data[40] &&
				               audio_snapshot_data[63:56] == 0 &&
				               audio_snapshot_data[255:192] != 0 &&
				               audio_snapshot_data[127:64] == session_epoch &&
				               audio_snapshot_data[191:128] == probe_nonce &&
				               audio_snapshot_data[383:320] == session_epoch &&
				               audio_snapshot_data[447:384] == probe_nonce;
				clock_active <= audio_snapshot_data[40];
				clock_paused <= audio_snapshot_data[41];
				consumer_quiescent <= audio_snapshot_data[44] &&
				                       !audio_snapshot_data[40] &&
				                       !audio_snapshot_data[42] &&
				                       !audio_snapshot_data[43];
				state <= INVALIDATE;
			end
			INVALIDATE: if (!ddr_busy) begin index <= 0; state <= WRITE_BODY; end
			WRITE_BODY: if (!ddr_busy) begin
				if (index == 6) state <= COMMIT;
				else index <= index + 1'b1;
			end
			COMMIT: if (!ddr_busy) begin
				poll_count <= POLL_CYCLES;
				state <= IDLE;
			end
			default: state <= IDLE;
			endcase
			// Also handles a legal response on the request-acceptance edge.
			if (read_arrived) begin
				if (state == READ_FIRST || state == WAIT_FIRST) begin
					first_commit <= ddr_dout;
					index <= 0;
					state <= (ddr_dout[31:0] == AUDIO_CONTROL_COMMIT_MAGIC &&
					          ddr_dout[63:32] != 0) ? READ_BODY : SNAPSHOT;
				end else begin
					request_words[index] <= ddr_dout;
					if (index == 5) state <= CHECK;
					else begin index <= index + 1'b1; state <= READ_BODY; end
				end
			end
		end
	end
endmodule
