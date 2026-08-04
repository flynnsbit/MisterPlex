// ddr_publish_engine — fabric-side DDR publication (w-mem).
//
// Retires ARM /dev/mem whole-frame memcpy (T_copy ~14.978 ms @720p I420) without
// a second A9 core (parent: MiSTer framework owns one core at idle).
//
// cmd_mode:
//   0 DIRECT — payload already at dst bank. Optional doorbell write only.
//   1 COPY   — mem2mem src→dst on f2sdram (fallback; 2× payload traffic).
//
// present_want blocks NEW issues (RD/WE assert). In-flight accepted cmd completes.
// WC present block ≤ 1 beat accept + engine react (see TB G1).
//
// M10K: 0 — bounce forced (* ramstyle="logic" *) MAX_BURST×64; layout N/A (not M10K).
// ALM: ESTIMATE ~250 — UNKNOWN until post-fit.
// Not product-wired; do not files.qip until instantiated.

module ddr_publish_engine #(
	parameter int MAX_BURST = 16,
	parameter int ADDR_W    = 29
)(
	input  wire              clk,
	input  wire              reset,

	input  wire              cmd_start,
	input  wire              cmd_mode,
	input  wire [31:0]       cmd_src_phys,
	input  wire [31:0]       cmd_dst_phys,
	input  wire [31:0]       cmd_bytes,
	input  wire [31:0]       cmd_doorbell_phys,
	input  wire              cmd_ring_doorbell,
	input  wire [63:0]       cmd_doorbell_word,

	output reg               busy,
	output reg               done_pulse,
	output reg               err,
	output reg [31:0]        bytes_copied,
	output reg [15:0]        beats_rd,
	output reg [15:0]        beats_wr,

	input  wire              present_want,

	output reg               bus_want,
	input  wire              DDRAM_BUSY,
	output reg  [7:0]        DDRAM_BURSTCNT,
	output reg  [ADDR_W-1:0] DDRAM_ADDR,
	input  wire [63:0]       DDRAM_DOUT,
	input  wire              DDRAM_DOUT_READY,
	output reg               DDRAM_RD,
	output reg  [63:0]       DDRAM_DIN,
	output wire [7:0]        DDRAM_BE,
	output reg               DDRAM_WE
);
	(* ramstyle = "logic" *) reg [63:0] bounce [0:MAX_BURST-1];

	localparam [2:0]
		ST_IDLE     = 3'd0,
		ST_DB       = 3'd1,
		ST_RD_ISSUE = 3'd2,
		ST_RD_DATA  = 3'd3,
		ST_WR_ISSUE = 3'd4,
		ST_FINISH   = 3'd5;

	reg [2:0] state;
	reg       mode_r, ring_db_r;
	reg [63:0] db_word_r;
	reg [ADDR_W-1:0] src_w, dst_w, db_w;
	reg [31:0] words_left, words_total;
	reg [4:0]  burst_n, got, wr_i;
	reg        hold_present;
	reg        rd_issued, wr_issued;

	assign DDRAM_BE = 8'hFF;

	wire align_ok =
		(cmd_src_phys[2:0] == 3'b0) &&
		(cmd_dst_phys[2:0] == 3'b0) &&
		(cmd_doorbell_phys[2:0] == 3'b0) &&
		(cmd_bytes[2:0] == 3'b0);

	wire [31:0] words_cmd = cmd_bytes >> 3;
	// Accept = command presented while !BUSY (bridge samples and takes).
	wire rd_accept = DDRAM_RD && !DDRAM_BUSY;
	wire wr_accept = DDRAM_WE && !DDRAM_BUSY;
	wire can_start_cmd = !DDRAM_BUSY && !hold_present && !DDRAM_RD && !DDRAM_WE;

	function automatic [4:0] nburst(input [31:0] left);
		begin
			if (left >= 32'(MAX_BURST))
				nburst = 5'(MAX_BURST);
			else if (left == 32'd0)
				nburst = 5'd0;
			else
				nburst = 5'(left[4:0]);
		end
	endfunction

	always @(posedge clk) begin
		if (reset)
			hold_present <= 1'b0;
		else
			hold_present <= present_want;
	end

	always @(posedge clk) begin
		if (reset) begin
			state <= ST_IDLE;
			busy <= 1'b0;
			done_pulse <= 1'b0;
			err <= 1'b0;
			bytes_copied <= 32'd0;
			beats_rd <= 16'd0;
			beats_wr <= 16'd0;
			bus_want <= 1'b0;
			DDRAM_RD <= 1'b0;
			DDRAM_WE <= 1'b0;
			DDRAM_DIN <= 64'd0;
			DDRAM_ADDR <= {ADDR_W{1'b0}};
			DDRAM_BURSTCNT <= 8'd1;
			mode_r <= 1'b0;
			ring_db_r <= 1'b0;
			db_word_r <= 64'd0;
			src_w <= {ADDR_W{1'b0}};
			dst_w <= {ADDR_W{1'b0}};
			db_w <= {ADDR_W{1'b0}};
			words_left <= 32'd0;
			words_total <= 32'd0;
			burst_n <= 5'd0;
			got <= 5'd0;
			wr_i <= 5'd0;
			rd_issued <= 1'b0;
			wr_issued <= 1'b0;
		end else begin
			done_pulse <= 1'b0;

			case (state)
			ST_IDLE: begin
				bus_want <= 1'b0;
				busy <= 1'b0;
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				rd_issued <= 1'b0;
				wr_issued <= 1'b0;
				if (cmd_start) begin
					if (!align_ok || (cmd_mode && words_cmd == 32'd0)) begin
						err <= 1'b1;
						done_pulse <= 1'b1;
					end else begin
						err <= 1'b0;
						busy <= 1'b1;
						mode_r <= cmd_mode;
						ring_db_r <= cmd_ring_doorbell;
						db_word_r <= cmd_doorbell_word;
						src_w <= cmd_src_phys[31:3];
						dst_w <= cmd_dst_phys[31:3];
						db_w  <= cmd_doorbell_phys[31:3];
						words_left <= words_cmd;
						words_total <= words_cmd;
						bytes_copied <= 32'd0;
						beats_rd <= 16'd0;
						beats_wr <= 16'd0;
						if (!cmd_mode) begin
							if (cmd_ring_doorbell) begin
								bus_want <= 1'b1;
								state <= ST_DB;
							end else
								state <= ST_FINISH;
						end else begin
							bus_want <= 1'b1;
							state <= ST_RD_ISSUE;
						end
					end
				end
			end

			ST_DB: begin
				bus_want <= 1'b1;
				if (!wr_issued) begin
					if (can_start_cmd) begin
						DDRAM_WE <= 1'b1;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_ADDR <= db_w;
						DDRAM_DIN <= db_word_r;
						wr_issued <= 1'b1;
					end
				end else if (wr_accept) begin
					DDRAM_WE <= 1'b0;
					wr_issued <= 1'b0;
					beats_wr <= beats_wr + 16'd1;
					state <= ST_FINISH;
				end
			end

			ST_RD_ISSUE: begin
				bus_want <= 1'b1;
				if (words_left == 32'd0) begin
					DDRAM_RD <= 1'b0;
					if (ring_db_r)
						state <= ST_DB;
					else
						state <= ST_FINISH;
				end else if (!rd_issued) begin
					if (can_start_cmd) begin
						burst_n <= nburst(words_left);
						got <= 5'd0;
						DDRAM_RD <= 1'b1;
						DDRAM_BURSTCNT <= 8'(nburst(words_left));
						DDRAM_ADDR <= src_w;
						rd_issued <= 1'b1;
					end
				end else if (rd_accept) begin
					// Command accepted — drop RD, collect data
					DDRAM_RD <= 1'b0;
					rd_issued <= 1'b0;
					state <= ST_RD_DATA;
				end
			end

			ST_RD_DATA: begin
				bus_want <= 1'b1;
				DDRAM_RD <= 1'b0;
				if (DDRAM_DOUT_READY) begin
					bounce[got[3:0]] <= DDRAM_DOUT;
					got <= got + 5'd1;
					beats_rd <= beats_rd + 16'd1;
					src_w <= src_w + 1'b1;
					words_left <= words_left - 32'd1;
					if (got + 5'd1 == burst_n) begin
						wr_i <= 5'd0;
						wr_issued <= 1'b0;
						state <= ST_WR_ISSUE;
					end
				end
			end

			ST_WR_ISSUE: begin
				bus_want <= 1'b1;
				if (!wr_issued) begin
					if (can_start_cmd) begin
						DDRAM_WE <= 1'b1;
						DDRAM_BURSTCNT <= 8'd1;
						DDRAM_ADDR <= dst_w;
						DDRAM_DIN <= bounce[wr_i[3:0]];
						wr_issued <= 1'b1;
					end
				end else if (wr_accept) begin
					DDRAM_WE <= 1'b0;
					wr_issued <= 1'b0;
					beats_wr <= beats_wr + 16'd1;
					dst_w <= dst_w + 1'b1;
					bytes_copied <= bytes_copied + 32'd8;
					if (wr_i + 5'd1 == burst_n)
						state <= ST_RD_ISSUE;
					else
						wr_i <= wr_i + 5'd1;
				end
			end

			ST_FINISH: begin
				bus_want <= 1'b0;
				busy <= 1'b0;
				DDRAM_RD <= 1'b0;
				DDRAM_WE <= 1'b0;
				done_pulse <= 1'b1;
				if (mode_r)
					bytes_copied <= words_total << 3;
				state <= ST_IDLE;
			end

			default: state <= ST_IDLE;
			endcase
		end
	end
endmodule
