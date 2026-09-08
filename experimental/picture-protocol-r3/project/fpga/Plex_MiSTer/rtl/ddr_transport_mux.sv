module ddr_transport_mux (
	input wire clk,
	input wire reset,
	input wire a_want,
	input wire a_rd,
	input wire a_we,
	input wire [28:0] a_addr,
	input wire [63:0] a_din,
	input wire [7:0] a_be,
	output wire a_busy,
	output wire [63:0] a_dout,
	output wire a_dout_ready,
	input wire b_want,
	input wire b_rd,
	input wire b_we,
	input wire [28:0] b_addr,
	input wire [63:0] b_din,
	input wire [7:0] b_be,
	output wire b_busy,
	output wire [63:0] b_dout,
	output wire b_dout_ready,
	output wire want,
	output wire rd,
	output wire we,
	output wire [28:0] addr,
	output wire [63:0] din,
	output wire [7:0] be,
	input wire busy,
	input wire [63:0] dout,
	input wire dout_ready
);
	reg prefer_b = 1'b0;
	reg locked = 1'b0, locked_b = 1'b0;
	reg response_pending = 1'b0, response_b = 1'b0;
	wire choose_b = locked ? locked_b :
	                ((b_rd || b_we) && (prefer_b || !(a_rd || a_we)));
	wire fire = !busy && (rd || we);
	wire read_fire = fire && rd;
	wire response_valid = dout_ready && (response_pending || read_fire);
	wire to_b = response_pending ? response_b : choose_b;

	assign want = a_want || b_want || locked || response_pending;
	assign rd = !response_pending && (choose_b ? b_rd : a_rd);
	assign we = !response_pending && (choose_b ? b_we : a_we);
	assign addr = choose_b ? b_addr : a_addr;
	assign din = choose_b ? b_din : a_din;
	assign be = choose_b ? b_be : a_be;
	assign a_busy = busy || response_pending || choose_b;
	assign b_busy = busy || response_pending || !choose_b;
	assign a_dout = dout;
	assign b_dout = dout;
	assign a_dout_ready = response_valid && !to_b;
	assign b_dout_ready = response_valid && to_b;

	always @(posedge clk) begin
		// The clients retire accepted transactions during reset. Do not lose a
		// held request or response tag when a new session is being established.
		if (reset && !locked && !response_pending) prefer_b <= 1'b0;
		if (!locked && busy && (rd || we)) begin
			locked <= 1'b1;
			locked_b <= choose_b;
		end
		if (response_valid) response_pending <= 1'b0;
		if (fire) begin
			locked <= 1'b0;
			prefer_b <= !choose_b;
			if (rd) begin
				response_b <= choose_b;
				response_pending <= !dout_ready;
			end
		end
	end
endmodule
