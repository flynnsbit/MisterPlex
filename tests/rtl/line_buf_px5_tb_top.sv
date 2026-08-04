// TB top: pack → ram_px5 → stream_rd (+ unpack phase check)
module line_buf_px5_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        clear,
	input  wire        in_valid,
	input  wire [63:0] in_q,
	output wire        pack_out_valid,
	output wire [7:0]  pack_out_addr,
	output wire [39:0] pack_out_data,
	output wire        line_done,
	output wire        busy,
	output wire        skid_overflow,
	// stream
	input  wire        stream_start,
	input  wire        stream_advance,
	output wire        px_valid,
	output wire [15:0] px_bytes, // PPC=2
	output wire        primed,
	// unpack direct
	input  wire        un_valid,
	input  wire [39:0] un_w0,
	input  wire [39:0] un_w1,
	input  wire [2:0]  un_phase,
	output wire        un_out_valid,
	output wire [15:0] un_px
);
	wire [7:0] rd_addr;
	wire [39:0] rd_data;

	line_buf_px5_pack #(.PIXELS(1280), .AW(8), .FIFO_DEPTH(256), .SKID(160)) u_pack (
		.clk(clk), .reset(reset), .clear(clear),
		.in_valid(in_valid), .in_q(in_q),
		.out_valid(pack_out_valid), .out_addr(pack_out_addr), .out_data(pack_out_data),
		.line_done(line_done), .busy(busy), .skid_overflow(skid_overflow)
	);

	line_buf_ram_px5 #(.DEPTH(256), .AW(8)) u_ram (
		.wr_clk(clk), .wr_en(pack_out_valid), .wr_addr(pack_out_addr), .wr_data(pack_out_data),
		.rd_clk(clk), .rd_addr(rd_addr), .rd_data(rd_data)
	);

	line_buf_px5_stream_rd #(.PPC(2), .AW(8), .PIXELS(1280)) u_srd (
		.clk(clk), .reset(reset),
		.start(stream_start), .advance(stream_advance),
		.rd_addr(rd_addr), .rd_data(rd_data),
		.px_valid(px_valid), .px_bytes(px_bytes), .primed(primed)
	);

	line_buf_px5_unpack #(.PPC(2)) u_un (
		.clk(clk), .reset(reset),
		.in_valid(un_valid), .word0(un_w0), .word1(un_w1), .phase(un_phase),
		.out_valid(un_out_valid), .px_bytes(un_px)
	);
endmodule
