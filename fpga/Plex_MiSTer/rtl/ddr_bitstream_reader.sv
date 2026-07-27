// HPS DDR compressed-bitstream ring reader.
//
// The ARM daemon writes Annex-B bytes into a power-of-two ring in HPS DDR and
// publishes an absolute write counter in CTRL_PHYS.  The FPGA publishes its
// absolute read counter plus underrun/overrun counters in two DDR mailbox words.
// This is intentionally separate from the MiSTer ioctl file-load path: ioctl F3
// remains the fixture/test injection route, while this module provides the
// continuous playback feed.

module ddr_bitstream_reader #(
	parameter [31:0] DATA_PHYS  = 32'h3010_0000,
	parameter [31:0] CTRL_PHYS  = 32'h3014_0000,
	parameter [31:0] READ_PHYS  = 32'h3014_0008,
	parameter [31:0] ERR_PHYS   = 32'h3014_0010,
	parameter int RING_BYTES    = 262144,
	parameter int POLL_DIV_BITS = 6
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        enable,
	input  wire        flush,

	output reg         out_valid,
	output reg  [7:0]  out_byte,
	output reg         out_flush,
	input  wire        out_full,

	output reg         bus_want,
	input  wire        DDRAM_BUSY,
	output reg   [7:0] DDRAM_BURSTCNT,
	output reg  [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output reg         DDRAM_RD,
	output reg  [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output reg         DDRAM_WE,

	output reg         active,
	output reg  [31:0] bytes_out,
	output reg  [15:0] underrun_count,
	output reg  [15:0] overrun_count,
	output reg  [31:0] host_write_count,
	output reg  [31:0] fpga_read_count
);
	localparam int RING_AW = $clog2(RING_BYTES);
	localparam [28:0] DATA_W = DATA_PHYS[31:3];
	localparam [28:0] CTRL_W = CTRL_PHYS[31:3];
	localparam [28:0] READ_W = READ_PHYS[31:3];
	localparam [28:0] ERR_W  = ERR_PHYS[31:3];
	localparam [31:0] MAGIC_CTRL = 32'h504C_5842; // PLXB
	localparam [31:0] MAGIC_READ = 32'h504C_5852; // PLXR
	localparam [31:0] MAGIC_ERR  = 32'h504C_5845; // PLXE
	localparam [31:0] RING_BYTES_W = 32'(RING_BYTES);

	assign DDRAM_BE = 8'hFF;

	localparam [3:0]
		ST_RESET     = 4'd0,
		ST_IDLE      = 4'd1,
		ST_POLL      = 4'd2,
		ST_READ_WAIT = 4'd3,
		ST_EMIT      = 4'd4,
		ST_PUB_READ  = 4'd5,
		ST_PUB_ERR   = 4'd6;

	reg [3:0] state;
	reg [POLL_DIV_BITS-1:0] poll_div;
	reg [63:0] beat_q;
	reg [2:0] byte_idx;
	reg [3:0] beat_left;
	reg [31:0] write_count;
	reg [31:0] read_count;
	reg reset_seen;
	reg overrun_sticky;
	reg underrun_sticky;
	reg [7:0] telem_seq;
	reg publish_req;
	reg publish_err_req;
	reg have_ctrl;
	reg empty_seen;
	reg seen_data;

	wire ctrl_magic_ok = DDRAM_DOUT[31:0] == MAGIC_CTRL;
	wire ctrl_reset = DDRAM_DOUT[63];
	wire [30:0] ctrl_write_count = DDRAM_DOUT[62:32];
	wire [31:0] avail = write_count - read_count;
	wire ring_has_data = active && (avail != 32'd0) && !overrun_sticky;
	wire [RING_AW-1:0] read_ring_index = read_count[RING_AW-1:0];
	wire [28:0] read_qword_offset = 29'(read_ring_index >> 3);
	wire [2:0] read_byte_index = read_ring_index[2:0];
	wire [31:0] bytes_to_qword_end = 32'd8 - {29'd0, read_byte_index};
	wire [31:0] emit_count_w =
		(avail < bytes_to_qword_end) ? avail : bytes_to_qword_end;
	wire [3:0] emit_count = emit_count_w[3:0];
	wire want_poll = enable && (poll_div == {POLL_DIV_BITS{1'b0}});
	wire want_read = enable && ring_has_data && (beat_left == 4'd0);
	wire want_pub = enable && (publish_req || publish_err_req);

	function automatic [7:0] beat_byte(input [63:0] beat, input [2:0] idx);
		begin
			case (idx)
				3'd0: beat_byte = beat[7:0];
				3'd1: beat_byte = beat[15:8];
				3'd2: beat_byte = beat[23:16];
				3'd3: beat_byte = beat[31:24];
				3'd4: beat_byte = beat[39:32];
				3'd5: beat_byte = beat[47:40];
				3'd6: beat_byte = beat[55:48];
				default: beat_byte = beat[63:56];
			endcase
		end
	endfunction

	always @(*) begin
		bus_want = 1'b0;
		case (state)
			ST_IDLE: bus_want = want_poll || want_read || want_pub;
			ST_POLL, ST_READ_WAIT: bus_want = 1'b1;
			default: bus_want = 1'b0;
		endcase
	end

	always @(posedge clk) begin
		out_valid <= 1'b0;
		out_flush <= 1'b0;
		DDRAM_RD <= 1'b0;
		DDRAM_WE <= 1'b0;

		if (reset) begin
			state <= ST_RESET;
			poll_div <= '0;
			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;
			DDRAM_BURSTCNT <= 8'd1;
			DDRAM_ADDR <= 29'd0;
			DDRAM_DIN <= 64'd0;
			active <= 1'b0;
			bytes_out <= 32'd0;
			underrun_count <= 16'd0;
			overrun_count <= 16'd0;
			host_write_count <= 32'd0;
			fpga_read_count <= 32'd0;
			write_count <= 32'd0;
			read_count <= 32'd0;
			reset_seen <= 1'b0;
			overrun_sticky <= 1'b0;
			underrun_sticky <= 1'b0;
			telem_seq <= 8'd0;
			publish_req <= 1'b1;
			publish_err_req <= 1'b0;
			have_ctrl <= 1'b0;
			empty_seen <= 1'b0;
			seen_data <= 1'b0;
			beat_left <= 4'd0;
			byte_idx <= 3'd0;
		end else if (!enable) begin
			state <= ST_IDLE;
			active <= 1'b0;
			beat_left <= 4'd0;
		end else begin
			poll_div <= poll_div + 1'd1;

			if (flush) begin
				read_count <= write_count;
				fpga_read_count <= write_count;
				beat_left <= 4'd0;
				overrun_sticky <= 1'b0;
				underrun_sticky <= 1'b0;
				seen_data <= 1'b0;
				out_flush <= 1'b1;
				publish_req <= 1'b1;
				state <= ST_IDLE;
			end

			if (avail != 32'd0)
				seen_data <= 1'b1;

			if (active && have_ctrl && seen_data && (avail == 32'd0) && (beat_left == 4'd0) &&
			    !empty_seen) begin
				empty_seen <= 1'b1;
				underrun_sticky <= 1'b1;
				if (underrun_count != 16'hFFFF)
					underrun_count <= underrun_count + 16'd1;
				publish_req <= 1'b1;
			end else if (avail != 32'd0) begin
				empty_seen <= 1'b0;
			end

			if (avail > RING_BYTES_W && !overrun_sticky) begin
				overrun_sticky <= 1'b1;
				if (overrun_count != 16'hFFFF)
					overrun_count <= overrun_count + 16'd1;
				publish_req <= 1'b1;
			end

			case (state)
				ST_RESET: begin
					state <= ST_IDLE;
					publish_req <= 1'b1;
				end

				ST_IDLE: begin
					if (publish_err_req && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= ERR_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {overrun_count[7:0], underrun_count[7:0],
						              active, overrun_sticky, underrun_sticky, 5'd0,
						              telem_seq + 8'd1, MAGIC_ERR};
						DDRAM_WE <= 1'b1;
						telem_seq <= telem_seq + 8'd1;
						publish_err_req <= 1'b0;
					end else if (publish_req && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= READ_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_DIN <= {read_count, MAGIC_READ};
						DDRAM_WE <= 1'b1;
						publish_req <= 1'b0;
						publish_err_req <= 1'b1;
					end else if (want_poll && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= CTRL_W;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						state <= ST_POLL;
					end else if (want_read && !out_full && !DDRAM_BUSY && !DDRAM_RD && !DDRAM_WE) begin
						DDRAM_ADDR <= DATA_W + read_qword_offset;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_RD <= 1'b1;
						byte_idx <= read_byte_index;
						state <= ST_READ_WAIT;
					end
				end

				ST_POLL: begin
					if (DDRAM_DOUT_READY) begin
						if (ctrl_magic_ok) begin
							active <= 1'b1;
							have_ctrl <= 1'b1;
							write_count <= {1'b0, ctrl_write_count};
							host_write_count <= {1'b0, ctrl_write_count};
							if (ctrl_reset != reset_seen) begin
								reset_seen <= ctrl_reset;
								read_count <= {1'b0, ctrl_write_count};
								fpga_read_count <= {1'b0, ctrl_write_count};
								beat_left <= 4'd0;
								overrun_sticky <= 1'b0;
								underrun_sticky <= 1'b0;
								out_flush <= 1'b1;
								publish_req <= 1'b1;
							end
						end
						state <= ST_IDLE;
					end
				end

				ST_READ_WAIT: begin
					if (DDRAM_DOUT_READY) begin
						beat_q <= DDRAM_DOUT;
						beat_left <= emit_count;
						state <= ST_EMIT;
					end
				end

				ST_EMIT: begin
					if (!out_full && beat_left != 4'd0) begin
						out_byte <= beat_byte(beat_q, byte_idx);
						out_valid <= 1'b1;
						byte_idx <= byte_idx + 3'd1;
						beat_left <= beat_left - 4'd1;
						read_count <= read_count + 32'd1;
						fpga_read_count <= read_count + 32'd1;
						bytes_out <= bytes_out + 32'd1;
						if (beat_left == 4'd1) begin
							publish_req <= 1'b1;
							state <= ST_IDLE;
						end
					end else if (beat_left == 4'd0) begin
						state <= ST_IDLE;
					end
				end

				default: state <= ST_IDLE;
			endcase
		end
	end
endmodule
