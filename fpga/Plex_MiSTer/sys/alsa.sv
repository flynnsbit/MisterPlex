//============================================================================
//
//  ALSA sound support for MiSTer
//  (c)2019,2020 Alexey Melnikov
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module alsa
#(
	parameter CLK_RATE = 24576000,
	parameter SESSION_CONTROL = 1'b0
)
(
	input             reset,
	input             clk,
	
	output reg [31:3] ram_address,
	input      [63:0] ram_data,
	output reg        ram_req = 0,
	input             ram_ready,

	input             spi_ss,
	input             spi_sck,
	input             spi_mosi,
	output            spi_miso,

	output reg [15:0] pcm_l,
	output reg [15:0] pcm_r,

	input             audio_ctrl_toggle,
	input     [216:0] audio_ctrl_data,
	output            audio_ctrl_ack_toggle,
	input             audio_snapshot_toggle,
	output            audio_snapshot_ack_toggle,
	output    [447:0] audio_snapshot_data
);

reg [60:0] buf_info;
reg buf_info_half = 0;
reg buf_info_valid = 0;
reg  [6:0] spicnt = 0;
always @(posedge spi_sck, posedge spi_ss) begin
	reg [95:0] spi_data;

	if(spi_ss) spicnt <= 0;
	else begin
		spi_data[{spicnt[6:3],~spicnt[2:0]}] <= spi_mosi;
		if(&spicnt) begin
			buf_info <= {spi_data[82:67],spi_data[50:35],spi_data[31:3]};
			buf_info_half <= spi_data[66];
			buf_info_valid <= 1;
		end
		spicnt <= spicnt + 1'd1;
	end
end

assign spi_miso = spi_out[{spicnt[4:3],~spicnt[2:0]}];

reg [31:0] spi_out = 0;
always @(posedge clk) if(spi_ss) spi_out <= {buf_rptr, hurryup, 8'h00};


reg [31:3] buf_addr;
reg [18:3] buf_len;
reg [18:3] buf_wptr = 0;

always @(posedge clk) begin
	reg [60:0] data1,data2;

	data1 <= buf_info;
	data2 <= data1;
	if(data2 == data1) {buf_wptr,buf_len,buf_addr} <= data2;
end

reg  [2:0] hurryup = 0;
reg [18:3] buf_rptr = 0;

generate
if (!SESSION_CONTROL) begin : g_legacy
assign audio_ctrl_ack_toggle = 1'b0;
assign audio_snapshot_ack_toggle = 1'b0;
assign audio_snapshot_data = 448'd0;

always @(posedge clk) begin
	reg [18:3] len = 0;
	reg  [1:0] ready = 0;
	reg [63:0] readdata;
	reg        got_first = 0;
	reg  [7:0] ce_cnt = 0;
	reg  [1:0] state = 0;

	if(reset) begin
		ready     <= 0;
		ce_cnt    <= 0;
		state     <= 0;
		got_first <= 0;
		len       <= 0;
	end
	else begin

		//ramp up
		if(len[18:14] && (hurryup < 1)) hurryup <= 1;
		if(len[18:16] && (hurryup < 2)) hurryup <= 2;
		if(len[18:17] && (hurryup < 4)) hurryup <= 4;

		//ramp down
		if(!len[18:15] && (hurryup > 2)) hurryup <= 2;
		if(!len[18:13] && (hurryup > 1)) hurryup <= 1;
		if(!len[18:10]) hurryup <= 0;

		if(ce_sample && ~&ce_cnt) ce_cnt <= ce_cnt + 1'd1;

		case(state)
		0: if(!ce_sample) begin
				if(ready) begin
					if(ce_cnt) begin
						{readdata[31:0],pcm_r,pcm_l} <= readdata;
						ready <= ready - 1'd1;
						ce_cnt <= ce_cnt - 1'd1;
					end
				end
				else if(buf_rptr != buf_wptr) begin
					if(~got_first) begin
						buf_rptr <= buf_wptr;
						got_first <= 1;
					end
					else begin
						ram_address <= buf_addr + buf_rptr;
						ram_req <= ~ram_req;
						buf_rptr <= buf_rptr + 1'd1;
						len <= (buf_wptr < buf_rptr) ? (buf_len + buf_wptr - buf_rptr) : (buf_wptr - buf_rptr);
						state <= 1;
					end
				end
				else begin
					len     <= 0;
					ce_cnt  <= 0;
					hurryup <= 0;
				end
			end
		1: if(ram_ready) begin
				ready <= 2;
				readdata <= ram_data;
				if(buf_rptr >= buf_len) buf_rptr <= buf_rptr - buf_len;
				state <= 0;
			end
		endcase
	end
end

reg ce_sample;
always @(posedge clk) begin
	reg [31:0] acc = 0;

	ce_sample <= 0;
	acc <= acc + 48000 + {hurryup,6'd0};
	if(acc >= CLK_RATE) begin
		acc <= acc - CLK_RATE;
		ce_sample <= 1;
	end
end

end else begin : g_session
	reg ctrl_s1 = 0, ctrl_s2 = 0, ctrl_ack = 0;
	reg snapshot_s1 = 0, snapshot_s2 = 0, snapshot_ack = 0;
	reg [62:0] info_data1 = 0, info_data2 = 0;
	reg [28:0] session_addr = 0;
	reg [15:0] session_len = 0, session_wptr = 0;
	reg session_wptr_half = 0, read_half = 0, response_upper = 0;
	reg session_info_valid = 0;
	reg [1:0] response_pairs = 0;
	reg [447:0] snapshot = 0;
	assign audio_ctrl_ack_toggle = ctrl_ack;
	assign audio_snapshot_ack_toggle = snapshot_ack;
	assign audio_snapshot_data = snapshot;

	reg active = 0, paused = 1;
	reg [63:0] epoch = 0, nonce = 0, consumed = 0;
	reg [63:0] ack_epoch = 0, ack_nonce = 0, ack_token = 0;
	reg [63:0] last_token = 0;
	reg [7:0] ack_opcode = 0, ack_error = 0;
	reg pending = 0, pending_toggle = 0;
	reg [216:0] command = 0;
	wire [63:0] cmd_epoch = command[63:0];
	wire [63:0] cmd_nonce = command[127:64];
	wire [63:0] cmd_token = command[191:128];
	wire [7:0] cmd_opcode = command[199:192];
	wire [16:0] cmd_producer_cursor = command[216:200];
	reg [3:0] stable_cycles = 0;
	reg [16:0] previous_wptr = 0;
	reg read_pending = 0;
	reg reset_draining = 0;
	reg [1:0] reset_settle = 0;
	reg [1:0] ready = 0;
	reg [63:0] readdata = 0;
	reg [31:0] phase = 0;
	wire sample_boundary = phase >= CLK_RATE - 48000;
	wire command_valid = cmd_epoch != 0 && cmd_nonce != 0 && cmd_token != 0 &&
	                     cmd_opcode >= 1 && cmd_opcode <= 4 &&
	                     ((cmd_opcode == 1 && (!active ||
	                        (cmd_epoch == epoch && cmd_nonce == nonce))) ||
	                      (cmd_opcode != 1 && (cmd_opcode == 4 || active) &&
	                       cmd_epoch == epoch && cmd_nonce == nonce)) &&
	                     (cmd_nonce != nonce || cmd_token > last_token);
	wire discard_command = cmd_opcode == 1 || cmd_opcode == 4;
	wire [7:0] flags = {3'd0, 1'b1, (ready != 0), read_pending, paused, active};

	always @(posedge clk) begin
		ctrl_s1 <= audio_ctrl_toggle;
		ctrl_s2 <= ctrl_s1;
		snapshot_s1 <= audio_snapshot_toggle;
		snapshot_s2 <= snapshot_s1;
		info_data1 <= {buf_info_valid, buf_info_half, buf_info};
		info_data2 <= info_data1;
		if (info_data2 == info_data1)
			{session_info_valid, session_wptr_half, session_wptr,
			 session_len, session_addr} <= info_data2;

		// The snapshot bus remains held until the next synchronized request.
		if (snapshot_s2 != snapshot_ack) begin
			snapshot <= {ack_nonce, ack_epoch, consumed, ack_token, nonce, epoch,
			             ack_error, ack_opcode, flags, 40'd0};
			snapshot_ack <= snapshot_s2;
		end

		// Never cancel a toggled DDR request: its response belongs to this
		// consumer even if Pause, Reset, or system reset arrives meanwhile.
		if (read_pending && ram_ready) begin
			read_pending <= 0;
			readdata <= response_upper ? {32'd0, ram_data[63:32]} : ram_data;
			ready <= response_pairs;
		end

		if (sample_boundary)
			phase <= phase + 48000 - CLK_RATE;
		else
			phase <= phase + 48000;
		hurryup <= 0;

		if (!reset && (!reset_draining || audio_ctrl_data[199:192] == 8'd4) &&
		    !pending && ctrl_s2 != ctrl_ack) begin
			command <= audio_ctrl_data;
			pending_toggle <= ctrl_s2;
			pending <= 1;
			stable_cycles <= 0;
			previous_wptr <= {session_wptr, session_wptr_half};
		end
		if (pending) begin
			previous_wptr <= {session_wptr, session_wptr_half};
			if (previous_wptr != {session_wptr, session_wptr_half} ||
			    info_data1 != info_data2)
				stable_cycles <= 0;
			else if (!(&stable_cycles))
				stable_cycles <= stable_cycles + 1'b1;

			if (!command_valid) begin
				ack_epoch <= cmd_epoch;
				ack_nonce <= cmd_nonce;
				ack_token <= cmd_token;
				ack_opcode <= cmd_opcode;
				ack_error <= 1;
				ctrl_ack <= pending_toggle;
				pending <= 0;
			end else if (!reset && !reset_draining && !read_pending && sample_boundary &&
			             (cmd_opcode != 3 || ((&stable_cycles) && session_info_valid &&
			              {session_wptr, session_wptr_half} == cmd_producer_cursor))) begin
				ack_epoch <= cmd_epoch;
				ack_nonce <= cmd_nonce;
				ack_token <= cmd_token;
				ack_opcode <= cmd_opcode;
				ack_error <= 0;
				last_token <= cmd_token;
				ctrl_ack <= pending_toggle;
				pending <= 0;
				pcm_l <= 0;
				pcm_r <= 0;
				if (discard_command) begin
					epoch <= cmd_epoch;
					nonce <= cmd_nonce;
					active <= cmd_opcode == 1;
					paused <= 1;
					// The quiesced kernel pointer is authoritative even
					// immediately after a core load, before any SPI packet.
					buf_rptr <= cmd_producer_cursor[16:1];
					read_half <= cmd_producer_cursor[0];
					response_pairs <= 0;
					response_upper <= 0;
					ready <= 0;
					readdata <= 0;
					consumed <= 0;
					phase <= 0;
				end else begin
					paused <= cmd_opcode == 2;
				end
			end
		end

		if (sample_boundary) begin
			if (!reset && active && !paused && !pending && ctrl_s2 == ctrl_ack && ready != 0) begin
				{pcm_r, pcm_l} <= readdata[31:0];
				readdata <= {32'd0, readdata[63:32]};
				ready <= ready - 1'b1;
				consumed <= consumed + 1'b1;
			end else begin
				pcm_l <= 0;
				pcm_r <= 0;
			end
		end
		if (!reset && active && !paused && !pending && ctrl_s2 == ctrl_ack &&
		    !read_pending && ready == 0 &&
		    {buf_rptr, read_half} != {session_wptr, session_wptr_half}) begin
			ram_address <= session_addr + {13'd0, buf_rptr};
			ram_req <= ~ram_req;
			response_upper <= read_half;
			if (!read_half && buf_rptr == session_wptr && session_wptr_half) begin
				// The producer published just one stereo pair. Never consume
				// the unwritten upper half; reread it after its later write.
				response_pairs <= 1;
				read_half <= 1;
			end else begin
				response_pairs <= read_half ? 2'd1 : 2'd2;
				read_half <= 0;
				// A 512-KiB ring encodes 65536 qwords as length zero.
				buf_rptr <= (session_len != 0 && buf_rptr + 16'd1 >= session_len) ?
				            16'd0 : buf_rptr + 16'd1;
			end
			read_pending <= 1;
		end
		if (reset_draining && !read_pending && reset_settle == 0) begin
			ready <= 0;
			readdata <= 0;
			response_pairs <= 0;
			response_upper <= 0;
			reset_draining <= 0;
		end
		if (reset || reset_draining) begin
			active <= 0;
			paused <= 1;
			pcm_l <= 0;
			pcm_r <= 0;
			phase <= 0;
			// A new Reset received after reset release may wait for real
			// DDR retirement. Other commands crossing reset are rejected.
			if ((pending || ctrl_s2 != ctrl_ack) &&
			    (reset || (pending ? cmd_opcode : audio_ctrl_data[199:192]) != 8'd4)) begin
				ack_epoch <= pending ? cmd_epoch : audio_ctrl_data[63:0];
				ack_nonce <= pending ? cmd_nonce : audio_ctrl_data[127:64];
				ack_token <= pending ? cmd_token : audio_ctrl_data[191:128];
				ack_opcode <= pending ? cmd_opcode : audio_ctrl_data[199:192];
				ack_error <= 1;
				ctrl_ack <= pending ? pending_toggle : ctrl_s2;
				pending <= 0;
			end
		end
		if (reset) begin
			reset_draining <= 1;
			reset_settle <= 3;
		end else if (reset_settle != 0) reset_settle <= reset_settle - 1'b1;
	end
end
endgenerate

endmodule
