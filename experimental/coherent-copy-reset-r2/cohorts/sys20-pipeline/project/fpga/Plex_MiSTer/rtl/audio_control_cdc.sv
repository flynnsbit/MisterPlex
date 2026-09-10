// Held-data/request/ACK pattern used by video_measurement_cdc, with explicit
// reset-intent retention and a separate, ordinary-timed active control bank.
module audio_control_cdc #(parameter WIDTH = 179) (
	input wire src_clk,
	input wire src_valid,
	input wire [WIDTH-1:0] src_data,
	input wire src_reset_event,
	input wire async_reset,
	input wire dst_clk,
	output reg [WIDTH-1:0] dst_data = 0,
	output reg dst_valid = 0,
	output wire dst_reset
);
	(* preserve = "true" *) reg [WIDTH:0] src_hold = 0, dst_capture = 0;
	(* preserve = "true" *) reg src_req = 0, dst_ack = 0;
	(* async_reg = "true", preserve = "true" *)
	reg ack_meta = 0, ack_sync = 0, req_meta = 0, req_sync = 0;
	(* async_reg = "true", preserve = "true" *) reg [1:0] reset_pipe = 2'b11;
	reg sent = 0, reset_pending = 1;
	reg pending = 0, apply_pending = 0, reset_event = 0;

	always @(posedge dst_clk or posedge async_reset)
		if (async_reset) reset_pipe <= 2'b11;
		else reset_pipe <= {reset_pipe[0],1'b0};
	assign dst_reset = reset_pipe[1] || !dst_valid || reset_event;

	// Runtime resets must not abandon an outstanding transfer or wrap its
	// phase. Multiple unsubmitted reset requests coalesce, never cancel.
	always @(posedge src_clk) begin
		ack_meta <= dst_ack;
		ack_sync <= ack_meta;
		if (src_valid && src_req == ack_sync &&
		    (!sent || reset_pending || src_reset_event || src_data != src_hold[WIDTH-1:0])) begin
			src_hold <= {reset_pending | src_reset_event,src_data};
			src_req <= ~src_req;
			sent <= 1;
			reset_pending <= 0;
		end else if (src_reset_event) reset_pending <= 1;
	end

	always @(posedge dst_clk) begin
		req_meta <= src_req;
		req_sync <= req_meta;
		reset_event <= 0;
		if (apply_pending) begin
			dst_data <= dst_capture[WIDTH-1:0];
			dst_valid <= 1;
			reset_event <= dst_capture[WIDTH];
			dst_ack <= req_sync;
			apply_pending <= 0;
		end else if (pending) begin
			dst_capture <= src_hold;
			pending <= 0;
			apply_pending <= 1;
		end else if (req_sync != dst_ack) pending <= 1;
	end
endmodule
