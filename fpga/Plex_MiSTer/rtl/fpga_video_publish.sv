// Native I420 copy -> ordered DDR fence -> safe-boundary swap -> MVPS.
// A decoded frame is not a presentation. Only the display acknowledgement
// advances presentation_count and permits a committed feedback record.
module fpga_video_publish #(
	parameter int PICTURE_BYTES = 115200,
	parameter int STORAGE_WIDTH = 320,
	parameter int STORAGE_HEIGHT = 240,
	parameter bit RUNTIME_GEOMETRY = 1'b0,
	parameter [31:0] FRAME_BASE = 32'h3000_0000,
	parameter [31:0] BANK_STRIDE = 32'h0008_0000,
	parameter [31:0] FEEDBACK_BASE = 32'h3014_0090,
	parameter bit ENABLE_AUDIO_CLOCK = 1'b0
) (
	input wire clk,
	input wire reset,
	input wire clear,
	input wire [63:0] video_nonce,
	input wire frame_valid,
	output wire frame_ready,
	input wire frame_bank,
	input wire [63:0] frame_session_id,
	input wire [31:0] frame_seq,
	input wire signed [63:0] frame_pts,
	input wire [31:0] frame_timebase_num,
	input wire [31:0] frame_timebase_den,
	input wire [15:0] frame_coded_width, frame_coded_height,
	input wire [15:0] frame_crop_left, frame_crop_right,
	input wire [15:0] frame_crop_top, frame_crop_bottom,
	// Held through the swap acknowledgement; the store commits this tuple with
	// the bank, never when reconstruction or the DDR copy merely completes.
	output reg [15:0] display_coded_width = 16'(STORAGE_WIDTH),
	output reg [15:0] display_coded_height = 16'(STORAGE_HEIGHT),
	output reg [15:0] display_crop_left = 0, display_crop_right = 0,
	output reg [15:0] display_crop_top = 0, display_crop_bottom = 0,
	output wire mem_rd,
	output wire [17:0] mem_addr,
	input wire mem_ready,
	input wire [7:0] mem_data,
	input wire mem_valid,
	output reg swap_toggle = 1'b0,
	output reg swap_bank = 1'b0,
	input wire display_has_frame,
	input wire [15:0] display_frames_done,
	input wire display_swap_pending,
	input wire display_clear_idle,
	input wire audio_clock_valid,
	input wire [63:0] audio_clock_epoch,
	input wire [63:0] audio_clock_nonce,
	input wire [63:0] audio_samples_consumed,
	output wire idle,
	output reg error = 1'b0,
	output reg [31:0] presentation_count = 32'd0,
	output wire bus_want,
	output wire bus_rd,
	output wire bus_we,
	output wire [28:0] bus_addr,
	output wire [63:0] bus_din,
	input wire bus_busy,
	input wire [63:0] bus_dout,
	input wire bus_dout_ready
);
	localparam [31:0] MVPS = 32'h4D56_5053, MVPC = 32'h4D56_5043;
	localparam [4:0] IDLE = 0, INVALIDATE = 1, INVALIDATE_FENCE = 2,
		INVALIDATE_WAIT = 3, RAM_REQ = 4, RAM_WAIT = 5, WRITE_WORD = 6,
		FRAME_FENCE = 7, FRAME_WAIT = 8, SWAP = 9, DISPLAY_WAIT = 10,
		STATUS_INVALIDATE = 11, STATUS_BODY = 12, STATUS_COMMIT = 13,
		STATUS_FENCE = 14, STATUS_WAIT = 15, FAILED = 16;
	reg [4:0] state = IDLE;
	reg reset_pending = 1'b1;
	reg [63:0] nonce_seen = 64'd0;
	reg [63:0] nonce_hold = 64'd0;
	reg [63:0] session_hold, pts_hold;
	reg [31:0] seq_hold, num_hold, den_hold;
	reg native_bank;
	reg displayed_bank = 1'b0;
	reg [17:0] byte_index;
	reg [15:0] copy_x, copy_y;
	reg [1:0] copy_plane;
	wire [15:0] copy_width = copy_plane == 0 ? 16'(STORAGE_WIDTH) : 16'(STORAGE_WIDTH/2);
	wire [15:0] copy_height = copy_plane == 0 ? 16'(STORAGE_HEIGHT) : 16'(STORAGE_HEIGHT/2);
	wire copy_padding = RUNTIME_GEOMETRY &&
	                    (copy_x >= (copy_plane == 0 ? display_coded_width : display_coded_width >> 1) ||
	                     copy_y >= (copy_plane == 0 ? display_coded_height : display_coded_height >> 1));
	wire [7:0] padding_byte = copy_plane == 0 ? 8'd16 : 8'd128;
	wire [16:0] crop_w = {1'b0, frame_crop_left} + {1'b0, frame_crop_right};
	wire [16:0] crop_h = {1'b0, frame_crop_top} + {1'b0, frame_crop_bottom};
	wire geometry_ok = !RUNTIME_GEOMETRY ||
	                   (PICTURE_BYTES == STORAGE_WIDTH*STORAGE_HEIGHT*3/2 &&
	                    frame_coded_width != 0 && frame_coded_width <= 16'(STORAGE_WIDTH) &&
	                    frame_coded_height != 0 && frame_coded_height <= 16'(STORAGE_HEIGHT) &&
	                    frame_coded_width[3:0] == 0 && frame_coded_height[3:0] == 0 &&
	                    crop_w < {1'b0, frame_coded_width} &&
	                    crop_h < {1'b0, frame_coded_height} &&
	                    !(frame_crop_left[0] || frame_crop_right[0] ||
	                      frame_crop_top[0] || frame_crop_bottom[0]));
	reg [63:0] word_data;
	reg [63:0] final_word;
	reg [15:0] display_before;
	reg [3:0] status_index;
	// Snapshot identity must survive functional clears, even within one epoch.
	reg [31:0] publication = 32'd0;
	reg audio_clock_hold = 1'b0;
	reg [63:0] audio_samples_hold = 64'd0;
	wire matching_audio_clock = ENABLE_AUDIO_CLOCK && audio_clock_valid &&
	                            audio_clock_epoch == session_hold &&
	                            audio_clock_nonce == nonce_hold;
	wire [31:0] next_publication = publication == 32'hffff_ffff ?
	                              32'd1 : publication + 32'd1;
	wire [31:0] frame_base = FRAME_BASE + (swap_bank ? BANK_STRIDE : 32'd0);
	wire [31:0] frame_word_addr = frame_base + {14'd0, byte_index[17:3], 3'd0};
	wire [31:0] final_addr = frame_base + PICTURE_BYTES - 8;
	wire [31:0] commit_addr = FEEDBACK_BASE + 32'd64;
	reg [63:0] status_word;
	always @* begin
		case (status_index)
			0: status_word = {audio_clock_hold ? 32'd19 : 32'd3, MVPS};
			1: status_word = session_hold;
			2: status_word = pts_hold;
			3: status_word = {den_hold, num_hold};
			4: status_word = {presentation_count, seq_hold};
			5: status_word = audio_samples_hold;
			6: status_word = nonce_hold;
			default: status_word = 64'd0; // error/reserved
		endcase
	end
	assign frame_ready = state == IDLE && !reset && !clear && !reset_pending &&
	                     video_nonce != 64'd0 && nonce_seen == video_nonce && !error &&
	                     display_clear_idle;
	assign idle = state == IDLE && !reset && !clear && !reset_pending &&
	              nonce_seen == video_nonce && display_clear_idle;
	assign mem_rd = state == RAM_REQ && !reset_pending && !reset && !clear && !copy_padding;
	assign mem_addr = (native_bank ? 18'(PICTURE_BYTES) : 18'd0) + byte_index;
	assign bus_rd = state == INVALIDATE_FENCE || state == FRAME_FENCE ||
	                state == STATUS_FENCE;
	assign bus_we = state == INVALIDATE || state == WRITE_WORD ||
	                state == STATUS_INVALIDATE || state == STATUS_BODY ||
	                state == STATUS_COMMIT;
	assign bus_want = bus_rd || bus_we || state == INVALIDATE_WAIT ||
	                  state == FRAME_WAIT || state == STATUS_WAIT;
	wire [31:0] address = state == WRITE_WORD ? frame_word_addr :
	                     state == FRAME_FENCE ? final_addr :
	                     state == STATUS_BODY ? FEEDBACK_BASE + {25'd0, status_index, 3'd0} :
	                     commit_addr;
	assign bus_addr = address[31:3];
	assign bus_din = state == WRITE_WORD ? word_data :
	                 state == STATUS_BODY ? status_word :
	                 state == STATUS_COMMIT ? {next_publication, MVPC} : 64'd0;
	wire cancel = reset || clear || reset_pending;
	wire copy_advance = !cancel &&
	                    (((state == RAM_WAIT && mem_valid) ||
	                      (state == RAM_REQ && copy_padding)) && byte_index[2:0] != 3'd7 ||
	                     (state == WRITE_WORD && !bus_busy &&
	                      byte_index != 18'(PICTURE_BYTES - 1)));

	always @(posedge clk) begin
		if (copy_advance) begin
			if (copy_x == copy_width - 1'b1) begin
				copy_x <= 0;
				if (copy_y == copy_height - 1'b1) begin
					copy_y <= 0;
					copy_plane <= copy_plane + 1'b1;
				end else copy_y <= copy_y + 1'b1;
			end else copy_x <= copy_x + 1'b1;
		end
		if (clear) reset_pending <= 1'b1;
		if (reset) begin
			reset_pending <= 1'b1;
			swap_toggle <= 1'b0;
			displayed_bank <= 1'b0;
		end
		case (state)
			IDLE: begin
				if (!reset && (clear || reset_pending || nonce_seen != video_nonce)) begin
					nonce_hold <= video_nonce;
					state <= INVALIDATE;
				end else if (frame_valid && frame_ready) begin
					if (frame_session_id == 0 || frame_timebase_num == 0 ||
					    frame_timebase_den == 0 || !geometry_ok) begin
						error <= 1'b1;
						state <= FAILED;
					end else begin
						session_hold <= frame_session_id;
						seq_hold <= frame_seq;
						pts_hold <= frame_pts;
						num_hold <= frame_timebase_num;
						den_hold <= frame_timebase_den;
						nonce_hold <= video_nonce;
						native_bank <= frame_bank;
						swap_bank <= !displayed_bank;
						byte_index <= 18'd0;
						copy_x <= 0; copy_y <= 0; copy_plane <= 0;
						display_coded_width <= RUNTIME_GEOMETRY ? frame_coded_width : 16'(STORAGE_WIDTH);
						display_coded_height <= RUNTIME_GEOMETRY ? frame_coded_height : 16'(STORAGE_HEIGHT);
						display_crop_left <= RUNTIME_GEOMETRY ? frame_crop_left : 16'd0;
						display_crop_right <= RUNTIME_GEOMETRY ? frame_crop_right : 16'd0;
						display_crop_top <= RUNTIME_GEOMETRY ? frame_crop_top : 16'd0;
						display_crop_bottom <= RUNTIME_GEOMETRY ? frame_crop_bottom : 16'd0;
						word_data <= 64'd0;
						display_before <= display_frames_done;
						audio_clock_hold <= 1'b0;
						audio_samples_hold <= 64'd0;
						state <= RAM_REQ;
					end
				end
			end
			INVALIDATE: if (!bus_busy) state <= INVALIDATE_FENCE;
			INVALIDATE_FENCE: if (!bus_busy) state <= INVALIDATE_WAIT;
			INVALIDATE_WAIT: if (bus_dout_ready) begin
				if (bus_dout != 64'd0) begin error <= 1'b1; state <= FAILED; end
				else begin
					nonce_seen <= nonce_hold;
					if (!reset && !clear) reset_pending <= 1'b0;
					if (reset_pending) begin
						presentation_count <= 0;
						error <= 0;
					end
					state <= IDLE;
				end
			end
			RAM_REQ: begin
				if (cancel) state <= IDLE;
				else if (copy_padding) begin
					// Allocation padding is not decoder output or a reference.
					// Do not read unwritten BRAM outside the coded rectangle.
					word_data[byte_index[2:0]*8 +: 8] <= padding_byte;
					if (byte_index[2:0] == 3'd7) state <= WRITE_WORD;
					else byte_index <= byte_index + 18'd1;
				end
				else if (mem_ready) state <= RAM_WAIT;
			end
			RAM_WAIT: if (mem_valid) begin
				if (cancel) state <= IDLE;
				else begin
					word_data[byte_index[2:0]*8 +: 8] <= mem_data;
					if (byte_index[2:0] == 3'd7) state <= WRITE_WORD;
					else begin byte_index <= byte_index + 18'd1; state <= RAM_REQ; end
				end
			end
			WRITE_WORD: if (!bus_busy) begin
				if (cancel) state <= INVALIDATE;
				else if (byte_index == 18'(PICTURE_BYTES - 1)) begin
					final_word <= word_data;
					state <= FRAME_FENCE;
				end else begin byte_index <= byte_index + 18'd1; state <= RAM_REQ; end
			end
			FRAME_FENCE: if (!bus_busy) state <= FRAME_WAIT;
			FRAME_WAIT: if (bus_dout_ready) begin
				if (cancel) state <= IDLE;
				else if (bus_dout != final_word) begin error <= 1'b1; state <= FAILED; end
				else state <= SWAP;
			end
			SWAP: begin
				if (cancel) state <= IDLE;
				else begin swap_toggle <= !swap_toggle; state <= DISPLAY_WAIT; end
			end
			DISPLAY_WAIT: begin
				if (reset) state <= IDLE;
				else if (cancel) begin
					if (display_clear_idle) state <= INVALIDATE;
				end else if (display_has_frame && !display_swap_pending &&
				         display_frames_done == display_before + 16'd1) begin
					displayed_bank <= swap_bank;
					presentation_count <= presentation_count + 32'd1;
					// Bind the clock to the actual display pickup, not the AU/copy.
					audio_clock_hold <= matching_audio_clock;
					audio_samples_hold <= matching_audio_clock ? audio_samples_consumed : 64'd0;
					state <= STATUS_INVALIDATE;
				end
			end
			STATUS_INVALIDATE: if (!bus_busy) begin
				status_index <= 0;
				state <= cancel ? INVALIDATE : STATUS_BODY;
			end
			STATUS_BODY: if (!bus_busy) begin
				if (cancel) state <= INVALIDATE;
				else if (status_index == 7) state <= STATUS_COMMIT;
				else status_index <= status_index + 1'd1;
			end
			STATUS_COMMIT: if (!bus_busy) begin
				publication <= next_publication;
				state <= STATUS_FENCE;
			end
			STATUS_FENCE: if (!bus_busy) state <= STATUS_WAIT;
			STATUS_WAIT: if (bus_dout_ready) begin
				if (cancel) state <= INVALIDATE;
				else if (bus_dout != {publication, MVPC}) begin error <= 1'b1; state <= FAILED; end
				else state <= IDLE;
			end
			FAILED: if (reset) state <= IDLE;
			default: state <= FAILED;
		endcase
	end
endmodule
