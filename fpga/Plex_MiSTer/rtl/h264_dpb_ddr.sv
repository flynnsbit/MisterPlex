// DDR-resident decoded picture buffer (+ optional on-chip BRAM reference).
//
// Owns:
//   1. write path  (h264_dpb_ddr_wr) : post-deblock samples -> DDR3
//   2. read path   (h264_dpb_ddr_rd) : DDR3 -> MC (chroma always; luma if !BRAM_REF)
//   3. frame swap  + optional BRAM reload of the picture that becomes reference
//   4. optional h264_dpb_bram_ref : deterministic fixed-latency luma (or full YUV) ref
//
// WHY DDR FOR TWO BANKS, BRAM FOR ONE REF
//   One I420 624x480 = 449280 B = 3.59 Mbits ~ 351 M10K.
//   Dual-bank on-chip = 127% of device bits — does not fit.
//   max_num_ref_frames=1 needs only ONE reference for MC. Writes stay in DDR
//   (two banks). After each frame drains, the completed picture is copied into
//   a single on-chip BRAM bank that subsequent MC reads with 1-cycle latency
//   and mem_stall=0 — deleting the variable-DDR-latency hang class on the
//   luma reference path. Chroma can stay on DDR (BRAM_LUMA_ONLY=1, default)
//   so the block cost is ~234 M10K instead of ~351.
//
// BRAM_REF=0 keeps the legacy pure-DDR behaviour (parameter fallback).
//
// PORT CONTRACT (unchanged for consumers)
//   ref_rd_*: hold en/addr while stall; valid strobes one cycle after accept
//             (registered response — matches h264_dpb_one_ref pending_d1).
//   rec_wr_*: POST-deblock only; do not fire while full.
//   frame_done_req/ack, swap_busy, ref_ready, idr_start, bases.

module h264_dpb_ddr #(
	parameter int    FRAME_W     = 624,
	parameter int    FRAME_H     = 480,
	parameter [31:0] DDR_BASE    = 32'h3040_0000,
	parameter int    BANK_STRIDE = 449280,
	parameter int    WR_FIFO_DEPTH = 64,
	// Legacy pin: responses are always registered (+1) so decode_core needs
	// no extra skid. Kept so stream_path's .REG_RESPONSE(...) still elaborates.
	parameter bit    REG_RESPONSE  = 1'b1,
	// 1 = serve reference (luma or full) from on-chip BRAM after first frame.
	parameter bit    BRAM_REF      = 1'b1,
	// 1 = BRAM holds Y only (234 M10K); chroma ref still uses DDR cache.
	// 0 = full I420 in BRAM (~351 M10K; needs free-block headroom).
	parameter bit    BRAM_LUMA_ONLY = 1'b1
) (
	input  wire        clk,
	input  wire        reset,

	input  wire        idr_start,
	input  wire        frame_done_req,
	output reg         frame_done_ack,
	output wire        swap_busy,
	output reg         ref_ready,
	output reg  [31:0] current_base,
	output reg  [31:0] reference_base,

	input  wire        rec_wr_en,
	input  wire [31:0] rec_wr_addr,
	input  wire  [7:0] rec_wr_data,
	output wire        rec_wr_full,

	input  wire        ref_rd_en,
	input  wire [31:0] ref_rd_addr,
	output wire        ref_rd_stall,
	output wire  [7:0] ref_rd_data,
	output wire        ref_rd_valid,

	input  wire        ddr_busy,
	output reg   [7:0] ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output reg         ddr_rd,
	output reg  [63:0] ddr_din,
	output reg   [7:0] ddr_be,
	output reg         ddr_we,
	output wire        ddr_req
);
	localparam [31:0] BANK0_BASE = 32'd0;
	localparam [31:0] BANK1_BASE = BANK_STRIDE[31:0];
	localparam int Y_BYTES = FRAME_W * FRAME_H;
	localparam int BRAM_BYTES = BRAM_LUMA_ONLY ? Y_BYTES : BANK_STRIDE;
	localparam int BRAM_AW = $clog2((BRAM_BYTES > 1) ? BRAM_BYTES : 2);
	localparam [28:0] BASE_W = DDR_BASE[31:3];

	// ------------------------------------------------------------ write path
	wire        wr_flush;
	wire        wr_idle;
	wire  [7:0] w_burstcnt;
	wire [28:0] w_addr;
	wire [63:0] w_din;
	wire  [7:0] w_be;
	wire        w_we;
	wire        w_req;
	reg         w_grant;

	h264_dpb_ddr_wr #(
		.DDR_BASE(DDR_BASE),
		.FIFO_DEPTH(WR_FIFO_DEPTH)
	) u_wr (
		.clk(clk),
		.reset(reset),
		.wr_en(rec_wr_en),
		.wr_addr(rec_wr_addr),
		.wr_data(rec_wr_data),
		.wr_full(rec_wr_full),
		.flush(wr_flush),
		.wr_idle(wr_idle),
		.ddr_busy(ddr_busy),
		.ddr_burstcnt(w_burstcnt),
		.ddr_addr(w_addr),
		.ddr_din(w_din),
		.ddr_be(w_be),
		.ddr_we(w_we),
		.ddr_req(w_req),
		.ddr_grant(w_grant)
	);

	// -------------------------------------------------------------- swap/load
	localparam [2:0] SW_IDLE   = 3'd0;
	localparam [2:0] SW_FLUSH  = 3'd1;
	localparam [2:0] SW_DRAIN  = 3'd2;
	localparam [2:0] SW_LOAD   = 3'd3;
	localparam [2:0] SW_COMMIT = 3'd4;

	reg [2:0] swap_state;
	assign swap_busy = (swap_state != SW_IDLE);
	reg  swap_flush_r;
	assign wr_flush = swap_flush_r;

	reg         cache_invalidate;
	reg [31:0]  load_src_base;
	reg [31:0]  load_off;
	reg         load_start; // 1-cycle pulse from swap FSM
	reg         load_issue;
	reg         load_wait_data;
	reg         load_shift;
	reg [2:0]   load_byte_idx;
	reg [63:0]  load_word;
	reg         bram_we;
	reg [BRAM_AW-1:0] bram_waddr;
	reg [7:0]   bram_wdata;
	reg         bram_loaded;

	wire load_busy = BRAM_REF && (swap_state == SW_LOAD);

	// --------------------------------------------------------------- BRAM
	wire [31:0] ref_off_full = ref_rd_addr - reference_base;
	wire        bram_range = BRAM_REF && bram_loaded && ref_ready &&
	                        (ref_off_full < BRAM_BYTES[31:0]);
	wire [BRAM_AW-1:0] bram_raddr = ref_off_full[BRAM_AW-1:0];
	wire [7:0] bram_rdata;

	generate
		if (BRAM_REF) begin : g_bram
			h264_dpb_bram_ref #(
				.DEPTH(BRAM_BYTES),
				.AW(BRAM_AW)
			) u_bram_ref (
				.clk(clk),
				.we(bram_we),
				.waddr(bram_waddr),
				.wdata(bram_wdata),
				.raddr(bram_raddr),
				.rdata(bram_rdata)
			);
		end else begin : g_no_bram
			assign bram_rdata = 8'd0;
		end
	endgenerate

	// ----------------------------------------------- DDR ref cache
	wire        cache_rd_stall;
	wire  [7:0] cache_rd_data;
	wire        cache_rd_valid;
	wire        cache_rd_en = ref_rd_en && !swap_busy && !bram_range;
	wire  [7:0] r_burstcnt;
	wire [28:0] r_addr;
	wire        r_rd;
	wire        r_req;
	reg         r_grant;

	// own forward-decl for dout steering
	reg [1:0] own;
	wire own_is_rd   = (own == 2'd1);
	wire own_is_load = (own == 2'd3);

	h264_dpb_ddr_rd #(
		.DDR_BASE(DDR_BASE),
		.REG_RESPONSE(1'b1)
	) u_rd (
		.clk(clk),
		.reset(reset),
		.rd_en(cache_rd_en),
		.rd_addr(ref_rd_addr),
		.rd_stall(cache_rd_stall),
		.rd_data(cache_rd_data),
		.rd_valid(cache_rd_valid),
		.invalidate(cache_invalidate),
		.ddr_busy(ddr_busy),
		.ddr_burstcnt(r_burstcnt),
		.ddr_addr(r_addr),
		.ddr_dout(ddr_dout),
		.ddr_dout_ready(ddr_dout_ready && !own_is_load),
		.ddr_rd(r_rd),
		.ddr_req(r_req),
		.ddr_grant(r_grant)
	);

	wire bram_accept = ref_rd_en && bram_range && !swap_busy;
	reg  bram_accept_d1;
	always @(posedge clk) begin
		if (reset)
			bram_accept_d1 <= 1'b0;
		else
			bram_accept_d1 <= bram_accept;
	end

	assign ref_rd_stall = (ref_rd_en && swap_busy) ||
	                      (ref_rd_en && !bram_range && cache_rd_stall);
	assign ref_rd_valid = bram_accept_d1 | (cache_rd_valid && !bram_accept_d1);
	assign ref_rd_data  = bram_accept_d1 ? bram_rdata : cache_rd_data;

	// ---------------------------------------------------------- arbitration
	localparam [1:0] OWN_NONE = 2'd0;
	localparam [1:0] OWN_RD   = 2'd1;
	localparam [1:0] OWN_WR   = 2'd2;
	localparam [1:0] OWN_LOAD = 2'd3;

	reg       last_rd;
	wire      load_req = load_busy && (load_issue || load_wait_data || load_shift);

	always @(posedge clk) begin
		if (reset) begin
			own     <= OWN_NONE;
			last_rd <= 1'b0;
		end else begin
			case (own)
			OWN_NONE: begin
				if (load_req)                          own <= OWN_LOAD;
				else if (r_req && !(last_rd && w_req)) own <= OWN_RD;
				else if (w_req)                        own <= OWN_WR;
				else if (r_req)                        own <= OWN_RD;
			end
			OWN_RD: if (!r_req) begin
				own     <= OWN_NONE;
				last_rd <= 1'b1;
			end
			OWN_WR: if (!w_req) begin
				own     <= OWN_NONE;
				last_rd <= 1'b0;
			end
			OWN_LOAD: if (!load_req) begin
				own     <= OWN_NONE;
				last_rd <= 1'b1;
			end
			default: own <= OWN_NONE;
			endcase
		end
	end

	always @* begin
		r_grant = (own == OWN_RD);
		w_grant = (own == OWN_WR);
	end

	assign ddr_req = (own != OWN_NONE) || r_req || w_req || load_req;

	reg  [7:0] l_burstcnt;
	reg [28:0] l_addr;
	reg        l_rd;

	always @* begin
		if (own == OWN_RD) begin
			ddr_burstcnt = r_burstcnt;
			ddr_addr     = r_addr;
			ddr_rd       = r_rd;
			ddr_din      = 64'd0;
			ddr_be       = 8'hFF;
			ddr_we       = 1'b0;
		end else if (own == OWN_WR) begin
			ddr_burstcnt = w_burstcnt;
			ddr_addr     = w_addr;
			ddr_rd       = 1'b0;
			ddr_din      = w_din;
			ddr_be       = w_be;
			ddr_we       = w_we;
		end else if (own == OWN_LOAD) begin
			ddr_burstcnt = l_burstcnt;
			ddr_addr     = l_addr;
			ddr_rd       = l_rd;
			ddr_din      = 64'd0;
			ddr_be       = 8'hFF;
			ddr_we       = 1'b0;
		end else begin
			ddr_burstcnt = 8'd1;
			ddr_addr     = 29'd0;
			ddr_rd       = 1'b0;
			ddr_din      = 64'd0;
			ddr_be       = 8'hFF;
			ddr_we       = 1'b0;
		end
	end

	// ------------------------------------------------------ BRAM load engine
	always @(posedge clk) begin
		bram_we    <= 1'b0;
		l_rd       <= 1'b0;
		l_burstcnt <= 8'd1;

		if (reset) begin
			load_issue     <= 1'b0;
			load_wait_data <= 1'b0;
			load_shift     <= 1'b0;
			load_byte_idx  <= 3'd0;
			load_off       <= 32'd0;
			load_word      <= 64'd0;
			bram_waddr     <= {BRAM_AW{1'b0}};
			bram_wdata     <= 8'd0;
			l_addr         <= 29'd0;
		end else begin
			if (load_start) begin
				load_off       <= 32'd0;
				load_issue     <= 1'b1;
				load_wait_data <= 1'b0;
				load_shift     <= 1'b0;
				load_byte_idx  <= 3'd0;
			end else if (swap_state == SW_LOAD) begin
				if (load_shift) begin
					bram_we    <= 1'b1;
					bram_waddr <= load_off[BRAM_AW-1:0];
					bram_wdata <= load_word[7:0];
					load_word  <= {8'd0, load_word[63:8]};
					load_off   <= load_off + 32'd1;
					if (load_byte_idx == 3'd7) begin
						load_byte_idx <= 3'd0;
						load_shift    <= 1'b0;
					end else begin
						load_byte_idx <= load_byte_idx + 3'd1;
					end
				end else if (load_wait_data) begin
					if (own_is_load && ddr_dout_ready) begin
						load_word      <= ddr_dout;
						load_wait_data <= 1'b0;
						load_shift     <= 1'b1;
						load_byte_idx  <= 3'd0;
					end
				end else if (load_issue) begin
					l_addr <= BASE_W + load_src_base[31:3] + load_off[31:3];
					if (own_is_load && !ddr_busy) begin
						l_rd           <= 1'b1;
						load_issue     <= 1'b0;
						load_wait_data <= 1'b1;
					end
				end else if (load_off < BRAM_BYTES[31:0]) begin
					load_issue <= 1'b1;
				end
			end else begin
				load_issue     <= 1'b0;
				load_wait_data <= 1'b0;
				load_shift     <= 1'b0;
				load_byte_idx  <= 3'd0;
			end
		end
	end

	wire load_done = (swap_state == SW_LOAD) &&
	                 (load_off >= BRAM_BYTES[31:0]) &&
	                 !load_issue && !load_wait_data && !load_shift && !l_rd;

	// ------------------------------------------------------------ frame swap
	always @(posedge clk) begin
		if (reset) begin
			swap_state       <= SW_IDLE;
			swap_flush_r     <= 1'b0;
			cache_invalidate <= 1'b0;
			frame_done_ack   <= 1'b0;
			ref_ready        <= 1'b0;
			bram_loaded      <= 1'b0;
			current_base     <= BANK0_BASE;
			reference_base   <= BANK1_BASE;
			load_src_base    <= 32'd0;
			load_start       <= 1'b0;
		end else begin
			swap_flush_r     <= 1'b0;
			cache_invalidate <= 1'b0;
			frame_done_ack   <= 1'b0;
			load_start       <= 1'b0;

			if (idr_start) begin
				ref_ready        <= 1'b0;
				bram_loaded      <= 1'b0;
				cache_invalidate <= 1'b1;
			end
			if (frame_done_req) cache_invalidate <= 1'b1;

			case (swap_state)
			SW_IDLE: begin
				if (frame_done_req) begin
					swap_flush_r <= 1'b1;
					swap_state   <= SW_FLUSH;
				end
			end
			SW_FLUSH: begin
				swap_state <= SW_DRAIN;
			end
			SW_DRAIN: begin
				if (wr_idle) begin
					cache_invalidate <= 1'b1;
					if (BRAM_REF) begin
						load_src_base <= current_base;
						load_start    <= 1'b1;
						swap_state    <= SW_LOAD;
					end else begin
						swap_state <= SW_COMMIT;
					end
				end
			end
			SW_LOAD: begin
				if (load_done) begin
					bram_loaded <= 1'b1;
					swap_state  <= SW_COMMIT;
				end
			end
			SW_COMMIT: begin
				reference_base <= current_base;
				current_base   <= (current_base == BANK0_BASE) ? BANK1_BASE : BANK0_BASE;
				ref_ready      <= 1'b1;
				frame_done_ack <= 1'b1;
				swap_state     <= SW_IDLE;
			end
			default: swap_state <= SW_IDLE;
			endcase
		end
	end
endmodule
