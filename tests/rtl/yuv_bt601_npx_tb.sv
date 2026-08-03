// Cosim testbench: yuv_bt601_npx N=1 must match ddr_frame_store BT.601 integer math.
// N=4 solid grey must produce identical lanes. Red injects wrong coeff expectation.
`default_nettype none

module yuv_bt601_npx_tb #(
	parameter bit RED_WRONG_R_COEFF = 1'b0
);
	reg clk = 1'b0;
	always #5 clk = ~clk;

	reg reset = 1'b1;
	reg in_valid = 1'b0;
	reg [11:0] src_x0 = 12'd0;
	reg [63:0] y_q = 64'd0;
	reg [63:0] u_q = 64'd0;
	reg [63:0] v_q = 64'd0;

	wire out_valid;
	wire [7:0] r1, g1, b1;
	wire lane1;

	yuv_bt601_npx #(.PX_PER_CLK(1), .X_W(12)) dut1 (
		.clk(clk), .reset(reset), .in_valid(in_valid), .src_x0(src_x0),
		.y_qword(y_q), .u_qword(u_q), .v_qword(v_q),
		.y_qword_hi(64'd0), .y_hi_valid(1'b0),
		.out_valid(out_valid), .out_r(r1), .out_g(g1), .out_b(b1),
		.out_lane_valid(lane1)
	);

	wire out_valid4;
	wire [31:0] r4, g4, b4;
	wire [3:0] lane4;
	yuv_bt601_npx #(.PX_PER_CLK(4), .X_W(12)) dut4 (
		.clk(clk), .reset(reset), .in_valid(in_valid), .src_x0(src_x0),
		.y_qword(y_q), .u_qword(u_q), .v_qword(v_q),
		.y_qword_hi(64'd0), .y_hi_valid(1'b0),
		.out_valid(out_valid4), .out_r(r4), .out_g(g4), .out_b(b4),
		.out_lane_valid(lane4)
	);

	// Golden BT.601 (same as ddr_frame_store)
	function automatic [7:0] sat8(input integer v);
		if (v < 0) sat8 = 8'd0;
		else if (v > 255) sat8 = 8'd255;
		else sat8 = v[7:0];
	endfunction

	function automatic void yuv_to_rgb(
		input [7:0] y, input [7:0] u, input [7:0] v,
		output [7:0] r, output [7:0] g, output [7:0] b
	);
		integer ys, us, vs, rcoeff;
		integer rw, gw, bw;
		begin
			ys = y;
			us = integer'(u) - 128;
			vs = integer'(v) - 128;
			rcoeff = RED_WRONG_R_COEFF ? 300 : 359;
			rw = (ys <<< 8) + (rcoeff * vs);
			gw = (ys <<< 8) - (88 * us) - (183 * vs);
			bw = (ys <<< 8) + (454 * us);
			r = sat8(rw >>> 8);
			g = sat8(gw >>> 8);
			b = sat8(bw >>> 8);
		end
	endfunction

	integer errors;
	reg [7:0] er, eg, eb;
	integer i;

	task automatic tick;
		begin
			@(posedge clk);
			#1;
		end
	endtask

	initial begin
		errors = 0;
		repeat (4) tick;
		reset = 1'b0;
		tick;

		// Case A: neutral grey Y=128 U=128 V=128 → RGB 128
		y_q = {8{8'd128}};
		u_q = {8{8'd128}};
		v_q = {8{8'd128}};
		src_x0 = 12'd0;
		in_valid = 1'b1;
		tick;
		tick; // registered output
		yuv_to_rgb(8'd128, 8'd128, 8'd128, er, eg, eb);
		if (!out_valid || r1 !== er || g1 !== eg || b1 !== eb) begin
			$display("FAIL grey N=1 got %0d,%0d,%0d want %0d,%0d,%0d", r1, g1, b1, er, eg, eb);
			errors = errors + 1;
		end
		for (i = 0; i < 4; i = i + 1) begin
			if (r4[i*8 +: 8] !== er || g4[i*8 +: 8] !== eg || b4[i*8 +: 8] !== eb) begin
				$display("FAIL grey N=4 lane %0d", i);
				errors = errors + 1;
			end
		end

		// Case B: pure luma ramp byte0=Y=16, chroma mid — known blackish
		y_q = 64'h00_00_00_00_00_00_00_10; // little-endian byte0=16
		u_q = {8{8'd128}};
		v_q = {8{8'd128}};
		src_x0 = 12'd0;
		tick;
		tick;
		yuv_to_rgb(8'd16, 8'd128, 8'd128, er, eg, eb);
		if (r1 !== er || g1 !== eg || b1 !== eb) begin
			$display("FAIL Y16 got %0d,%0d,%0d want %0d,%0d,%0d", r1, g1, b1, er, eg, eb);
			errors = errors + 1;
		end

		// Case C: moderate V push that does NOT saturate R for either 359 or
		// the red-injected 300 coeff — grey/V=240 both mask the difference.
		// Y=16 U=128 V=160 → R_359=60, R_300=53 (distinct).
		y_q = {8{8'd16}};
		u_q = {8{8'd128}};
		v_q = {8{8'd160}};
		src_x0 = 12'd3;
		tick;
		tick;
		yuv_to_rgb(8'd16, 8'd128, 8'd160, er, eg, eb);
		if (r1 !== er || g1 !== eg || b1 !== eb) begin
			$display("FAIL v-push got %0d,%0d,%0d want %0d,%0d,%0d", r1, g1, b1, er, eg, eb);
			errors = errors + 1;
		end

		in_valid = 1'b0;
		tick;

		if (RED_WRONG_R_COEFF) begin
			if (errors == 0) begin
				$display("FAIL: red wrong-coeff run should have mismatched");
				$fatal(1);
			end
			// $fatal (not $finish): some Verilator --binary builds continue past $finish.
			$display("PASS yuv_bt601_npx RED: wrong coeff detected errors=%0d", errors);
			$fatal(1);
		end else if (errors != 0) begin
			$display("FAIL yuv_bt601_npx errors=%0d", errors);
			$fatal(1);
		end else begin
			$display("PASS yuv_bt601_npx N=1 matches BT.601 golden; N=4 lanes coherent");
			$finish;
		end
	end
endmodule

`default_nettype wire
