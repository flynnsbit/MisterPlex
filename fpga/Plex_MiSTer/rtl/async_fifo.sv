// Small dual-clock FIFO for clock-domain crossings.
module async_fifo #(
	parameter int WIDTH = 8,
	parameter int AW    = 4
)(
	input  wire             wr_clk,
	input  wire             wr_reset,
	input  wire             wr_en,
	input  wire [WIDTH-1:0] wr_data,
	output wire             wr_full,
	output wire             wr_almost_full,

	input  wire             rd_clk,
	input  wire             rd_reset,
	input  wire             rd_en,
	output wire [WIDTH-1:0] rd_data,
	output wire             rd_empty
);
	localparam int DEPTH = 1 << AW;

	(* ramstyle = "MLAB" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

	reg [AW:0] wr_bin, wr_gray;
	reg [AW:0] rd_bin, rd_gray;
	reg [AW:0] rd_gray_w1, rd_gray_w2;
	reg [AW:0] wr_gray_r1, wr_gray_r2;
	// Registered first-word-fall-through read port: consumers still see
	// rd_empty=0 only when rd_data is valid, but no fast-clock RAM data fans
	// straight into slow-domain logic.
	reg [WIDTH-1:0] rd_data_r;
	reg             rd_valid;
	localparam [AW:0] PTR_ONE = {{AW{1'b0}}, 1'b1};

	function automatic [AW:0] bin2gray(input [AW:0] b);
		bin2gray = (b >> 1) ^ b;
	endfunction

	wire [AW:0] wr_gray_full = {~rd_gray_w2[AW:AW-1], rd_gray_w2[AW-2:0]};
	wire        wr_full_now  = (wr_gray == wr_gray_full);
	wire        wr_accept    = wr_en && !wr_full_now;
	wire [AW:0] wr_bin_next  = wr_bin + (wr_accept ? PTR_ONE : '0);
	wire [AW:0] wr_gray_next = bin2gray(wr_bin_next);
	wire        rd_has_entry = (rd_gray != wr_gray_r2);
	wire        rd_consume   = rd_en && rd_valid;
	wire        rd_prefetch  = rd_has_entry && (!rd_valid || rd_consume);
	wire [AW:0] rd_bin_next  = rd_bin + (rd_prefetch ? PTR_ONE : '0);
	wire [AW:0] rd_gray_next = bin2gray(rd_bin_next);

	assign wr_full = wr_full_now;
	wire [AW:0] wr_bin_plus4_gray = bin2gray(wr_bin + {{AW-2{1'b0}}, 3'd4});
	assign wr_almost_full = wr_full_now || (wr_bin_plus4_gray == wr_gray_full);
	assign rd_empty = !rd_valid;
	assign rd_data = rd_data_r;

	always @(posedge wr_clk) begin
		if (wr_reset) begin
			wr_bin <= '0;
			wr_gray <= '0;
			rd_gray_w1 <= '0;
			rd_gray_w2 <= '0;
		end else begin
			rd_gray_w1 <= rd_gray;
			rd_gray_w2 <= rd_gray_w1;
			if (wr_accept) begin
				mem[wr_bin[AW-1:0]] <= wr_data;
				wr_bin <= wr_bin_next;
				wr_gray <= wr_gray_next;
			end
		end
	end

	always @(posedge rd_clk) begin
		if (rd_reset) begin
			rd_bin <= '0;
			rd_gray <= '0;
			wr_gray_r1 <= '0;
			wr_gray_r2 <= '0;
			rd_data_r <= '0;
			rd_valid <= 1'b0;
		end else begin
			wr_gray_r1 <= wr_gray;
			wr_gray_r2 <= wr_gray_r1;
			if (rd_prefetch) begin
				rd_data_r <= mem[rd_bin[AW-1:0]];
				rd_bin <= rd_bin_next;
				rd_gray <= rd_gray_next;
				rd_valid <= 1'b1;
			end else if (rd_consume)
				rd_valid <= 1'b0;
		end
	end
endmodule
