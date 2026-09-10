module scaler_palette (
	input wire clk, reset,
	input wire [269:0] cfg_data,
	input wire cfg_req, cfg_ack, cfg_active, hdmi_vs,
	input wire data_ready,
	input wire [6:0] data_index,
	output reg [28:0] address = 0,
	output reg request = 0,
	(* preserve = "true" *) output reg write_bank = 0,
	(* preserve = "true" *) output reg ready_tag = 0,
	(* preserve = "true" *) output reg ready_valid = 0
);
	(* async_reg = "true", preserve = "true" *) reg [1:0] reset_pipe = 2'b11;
	always @(posedge clk or posedge reset)
		if (reset) reset_pipe <= 2'b11;
		else reset_pipe <= {reset_pipe[0],1'b0};

	(* async_reg = "true", preserve = "true" *)
	reg req_meta=0, req_sync=0, ack_meta=0, ack_sync=0;
	(* async_reg = "true", preserve = "true" *)
	reg active_meta=0, active_sync=0, vs_meta=0, vs_sync=0;
	reg vs_last=0;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			req_meta<=0; req_sync<=0; ack_meta<=0; ack_sync<=0;
			active_meta<=0; active_sync<=0; vs_meta<=0; vs_sync<=0; vs_last<=0;
		end else begin
			req_meta<=cfg_req; req_sync<=req_meta;
			ack_meta<=cfg_ack; ack_sync<=ack_meta;
			active_meta<=cfg_active; active_sync<=active_meta;
			vs_meta<=hdmi_vs; vs_sync<=vs_meta; vs_last<=vs_sync;
		end
	end

	localparam [2:0] IDLE=0, CAPTURE=1, CHECK=2, WAIT_FRAME=3, WAIT_DATA=4, WAIT_ACK=5;
	reg [2:0] state=IDLE;
	(* preserve = "true" *) reg [36:0] descriptor=0;
	reg tag=0, publish=0, load_valid=0;
	reg busy=0;
	reg [6:0] words=0;

	// ddr_svc and its persistent RAM2 bridge retain queued/issued ownership.
	// Keep this request phase and debt even when a configuration is cancelled.
	always @(posedge clk) begin
		publish<=0;
		if (reset_pipe[1]) begin
			state<=IDLE; load_valid<=0; ready_tag<=0;
		end else begin
			case (state)
				IDLE: if (!busy && req_sync != ready_tag) state<=CAPTURE;
				CAPTURE: begin
					descriptor<={cfg_data[104],cfg_data[24],cfg_data[76:74],cfg_data[73:42]};
					tag<=req_sync;
					state<=CHECK;
				end
				CHECK: begin
					if (descriptor[36] && !descriptor[35] && descriptor[34:32]==3'b011)
						state<=WAIT_FRAME;
					else begin
						ready_tag<=tag; publish<=1; state<=WAIT_ACK;
					end
				end
				WAIT_FRAME: if (!active_sync || (vs_sync && !vs_last)) begin
					address<=descriptor[31:3]-29'd512;
					request<=~request;
					write_bank<=~write_bank;
					busy<=1; words<=0; load_valid<=1;
					state<=WAIT_DATA;
				end
				WAIT_DATA: ;
				WAIT_ACK: if (ack_sync==tag) state<=IDLE;
				default: state<=IDLE;
			endcase
		end
		if (data_ready && busy) begin
			words<=words+1'b1;
			if (words==127) begin
				busy<=0;
				if (load_valid && !reset_pipe[1]) begin
					ready_tag<=tag; publish<=1; state<=WAIT_ACK;
				end
			end
		end
	end

	// Reset assertion must invalidate a stale completion even if clk is stopped.
	always @(posedge clk or posedge reset)
		if (reset) ready_valid<=0;
		else if (reset_pipe[1]) ready_valid<=0;
		else if (publish) ready_valid<=1;

`ifndef SYNTHESIS
	always @(posedge clk) if (data_ready) begin
		assert(busy) else $fatal(1,"palette response without owned DMA");
		assert(data_index==words) else $fatal(1,"palette DMA word sequence");
	end
`endif
endmodule
