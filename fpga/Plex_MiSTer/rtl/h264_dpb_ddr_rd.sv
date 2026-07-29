// DDR-resident DPB read path: reference samples for motion compensation.
//
// Motion compensation asks for a rectangle of the reference picture at an
// arbitrary integer + fractional motion-vector offset.  The tap generator walks
// that rectangle row by row, so the byte address stream is strictly sequential
// inside a row and jumps by one picture stride between rows.  That access shape
// is what this cache is built for.
//
// STRUCTURE
//   Two fully-associative 32-byte lines (4 x 64-bit DDR words each), filled by
//   a burst-4 read.  A 21-tap luma row (16 + 5 for the 6-tap filter support)
//   spans at most two lines, so a whole tap row is resident after one demand
//   miss plus the sequential prefetch of the following line.  The steady state
//   is one demand miss per reference row instead of one per sample.
//
// This is the MiSTer PSX_MiSTer/rtl/ddram.sv sliding-window cache idea (serve
// the requested word, keep the next one, slide forward on a consecutive
// address) widened from 2 words to 2 lines so a 2-D window scan stays resident
// across the horizontal span rather than only across a single word.  The
// request handshake follows jtframe's jtframe_romrq/jtframe_ram_rq shape: the
// requester holds its chip-select asserted until the memory answers, and the
// memory answers with a one-cycle data-valid strobe.
//
// PORT CONTRACT (this is what motion compensation codes against)
//   rd_en    : request a byte.  Hold rd_en and rd_addr stable while rd_stall.
//   rd_addr  : byte offset, plane-linear I420, already including the reference
//              bank base.
//   rd_stall : combinational.  High => the request was NOT accepted this cycle.
//   rd_valid : one-cycle strobe, exactly one cycle after an accepted request.
//   rd_data  : the byte, valid with rd_valid.
//   invalidate: drop both lines.  Must be pulsed whenever the reference bank
//              pointer moves, otherwise stale samples from the previous
//              reference picture leak into the new one.
//
// COHERENCE
//   Reads target the reference bank, writes target the current bank, so within
//   a picture the two never alias and no write-through snoop is required.  The
//   only coherence event is the frame swap, which the top level serialises:
//   drain the write FIFO, then invalidate, then move the bank pointers.

module h264_dpb_ddr_rd #(
	parameter [31:0] DDR_BASE = 32'h3040_0000,
	// 1 = rd_valid/rd_data are registered and strobe one cycle after an
	//     accepted request (matches the decode_stub SRAM contract).
	// 0 = rd_valid/rd_data are combinational on the accepted cycle, for
	//     integrations that already carry an external skid stage on the
	//     response path (h264_decode_core does).
	parameter bit    REG_RESPONSE = 1'b1
) (
	input  wire        clk,
	input  wire        reset,

	// Byte-granular reference read port.
	input  wire        rd_en,
	input  wire [31:0] rd_addr,
	output wire        rd_stall,
	output wire  [7:0] rd_data,
	output wire        rd_valid,

	input  wire        invalidate,

	// DDR master (read-only side of the shared port).
	input  wire        ddr_busy,
	output reg   [7:0] ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output reg         ddr_rd,
	output wire        ddr_req,
	input  wire        ddr_grant
);
	localparam [28:0] BASE_W = DDR_BASE[31:3];
	localparam int TAGW = 27; // rd_addr[31:5]

	// ---------------------------------------------------------------- cache
	reg [TAGW-1:0] tag  [0:1];
	reg            vld  [0:1];
	reg [255:0]    line [0:1];
	reg            lru;             // slot to evict next

	wire [TAGW-1:0] req_tag  = rd_addr[31:5];
	wire      [4:0] req_byte = rd_addr[4:0];

	wire hit0 = vld[0] && (tag[0] == req_tag);
	wire hit1 = vld[1] && (tag[1] == req_tag);
	wire hit  = hit0 || hit1;

	wire [255:0] hit_line = hit0 ? line[0] : line[1];
	wire   [7:0] hit_byte = hit_line[8*req_byte +: 8];

	wire accept = rd_en && hit;
	assign rd_stall = rd_en && !hit;

	// Response staging.  REG_RESPONSE selects between the registered
	// (decode_stub-equivalent) contract and a combinational one for
	// integrations that already own a skid stage.
	reg [7:0] rd_data_q;
	reg       rd_valid_q;
	assign rd_data  = REG_RESPONSE ? rd_data_q  : hit_byte;
	assign rd_valid = REG_RESPONSE ? rd_valid_q : accept;

	// ------------------------------------------------------------------ fsm
	localparam [1:0] S_IDLE = 2'd0;
	localparam [1:0] S_REQ  = 2'd1;
	localparam [1:0] S_FILL = 2'd2;

	reg  [1:0]      state;
	reg [TAGW-1:0]  fill_tag;
	reg             fill_slot;
	reg  [1:0]      fill_beat;
	reg [255:0]     fill_buf;
	reg             fill_is_pf;   // this fill is a speculative prefetch

	// A prefetch is wanted when a demand line has just landed and the following
	// line is not already resident.  It is always dropped in favour of a demand
	// miss.
	reg             pf_pending;
	reg [TAGW-1:0]  pf_tag;
	wire pf_resident = (vld[0] && tag[0] == pf_tag) || (vld[1] && tag[1] == pf_tag);
	wire pf_go = pf_pending && !pf_resident;

	// The DDR port is only requested for the duration of an actual burst, so
	// the arbiter can round-robin at transaction granularity and the posted
	// write queue can never be starved by a long run of reference misses.
	assign ddr_req = (state != S_IDLE);

	always @(posedge clk) begin
		if (reset) begin
			vld[0]       <= 1'b0;
			vld[1]       <= 1'b0;
			tag[0]       <= '0;
			tag[1]       <= '0;
			line[0]      <= '0;
			line[1]      <= '0;
			lru          <= 1'b0;
			state        <= S_IDLE;
			fill_tag     <= '0;
			fill_slot    <= 1'b0;
			fill_beat    <= 2'd0;
			fill_buf     <= '0;
			fill_is_pf   <= 1'b0;
			pf_pending   <= 1'b0;
			pf_tag       <= '0;
			rd_valid_q   <= 1'b0;
			rd_data_q    <= 8'd0;
			ddr_rd       <= 1'b0;
			ddr_addr     <= 29'd0;
			ddr_burstcnt <= 8'd4;
		end else begin
			ddr_rd     <= 1'b0;
			rd_valid_q <= 1'b0;

			if (accept) begin
				rd_valid_q <= 1'b1;
				rd_data_q  <= hit_byte;
				// The hit slot becomes the most recently used one.
				lru <= hit0 ? 1'b1 : 1'b0;
			end

			if (invalidate) begin
				vld[0]     <= 1'b0;
				vld[1]     <= 1'b0;
				pf_pending <= 1'b0;
			end

			case (state)
			S_IDLE: begin
				if (rd_stall && !invalidate) begin
					fill_tag   <= req_tag;
					fill_slot  <= lru;
					fill_is_pf <= 1'b0;
					fill_beat  <= 2'd0;
					state      <= S_REQ;
				end else if (pf_go && !invalidate) begin
					fill_tag   <= pf_tag;
					fill_slot  <= lru;
					fill_is_pf <= 1'b1;
					fill_beat  <= 2'd0;
					pf_pending <= 1'b0;
					state      <= S_REQ;
				end
			end

			S_REQ: begin
				// Every command is gated on the shared port being granted and
				// the controller not being busy, per the MiSTer ddram contract.
				if (ddr_grant && !ddr_busy) begin
					ddr_addr     <= BASE_W + {fill_tag, 2'b00};
					ddr_burstcnt <= 8'd4;
					ddr_rd       <= 1'b1;
					state        <= S_FILL;
				end
			end

			S_FILL: begin
				if (ddr_dout_ready) begin
					fill_buf[64*fill_beat +: 64] <= ddr_dout;
					fill_beat <= fill_beat + 2'd1;
					if (fill_beat == 2'd3) begin
						state <= S_IDLE;
						if (!invalidate) begin
							// Commit the whole line.  The last beat is taken
							// from the bus directly because fill_buf has not
							// been updated yet at this point in the cycle.
							line[fill_slot] <= {ddr_dout, fill_buf[191:0]};
							tag [fill_slot] <= fill_tag;
							vld [fill_slot] <= 1'b1;
							// Keep the freshly filled line; evict the other.
							lru <= ~fill_slot;
							if (!fill_is_pf) begin
								pf_pending <= 1'b1;
								pf_tag     <= fill_tag + 1'b1;
							end
						end
					end
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end
endmodule
