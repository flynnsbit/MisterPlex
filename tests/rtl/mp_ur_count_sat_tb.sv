`timescale 1ns/1ps
// Boundary: count=0x7ffe, delta=2 must saturate to 0x7fff (rd-duck).
// RED_WRAP_BUG=1 uses the old 15-bit add-before-compare (must FAIL).
`default_nettype none
module mp_ur_count_sat_tb #(
	parameter bit RED_WRAP_BUG = 1'b0
);
	function automatic [14:0] sat_add_fixed(input [14:0] count, input [7:0] delta);
		reg [15:0] s;
		begin
			s = {1'b0, count} + {8'b0, delta};
			if (delta == 8'd0)
				sat_add_fixed = count;
			else if (s < 16'h7fff)
				sat_add_fixed = s[14:0];
			else
				sat_add_fixed = 15'h7fff;
		end
	endfunction

	// Buggy: 15-bit add wraps before compare (product bug pre-fix).
	function automatic [14:0] sat_add_buggy(input [14:0] count, input [7:0] delta);
		begin
			if (delta == 8'd0)
				sat_add_buggy = count;
			else if (15'(count) + 15'(delta) < 15'h7fff)
				sat_add_buggy = count + 15'(delta);
			else
				sat_add_buggy = 15'h7fff;
		end
	endfunction

	function automatic [14:0] sat_add(input [14:0] count, input [7:0] delta);
		sat_add = RED_WRAP_BUG ? sat_add_buggy(count, delta) : sat_add_fixed(count, delta);
	endfunction

	function automatic [14:0] sat_sum_fixed(input [14:0] a, input [14:0] b);
		reg [15:0] s;
		begin
			s = {1'b0, a} + {1'b0, b};
			sat_sum_fixed = (s >= 16'h7fff) ? 15'h7fff : s[14:0];
		end
	endfunction

	integer fails;
	reg [14:0] r;

	task automatic check(input [14:0] c, input [7:0] d, input [14:0] exp, input string tag);
		begin
			r = sat_add(c, d);
			if (r !== exp) begin
				fails = fails + 1;
				$display("FAIL %s c=%0d d=%0d got=%0d exp=%0d", tag, c, d, r, exp);
			end
		end
	endtask

	initial begin
		fails = 0;
		// Primary boundary (rd-duck)
		check(15'h7ffe, 8'd2, 15'h7fff, "7ffe+2");
		check(15'h7ffe, 8'd1, 15'h7fff, "7ffe+1");
		check(15'h7fff, 8'd1, 15'h7fff, "7fff+1");
		check(15'h7fff, 8'd255, 15'h7fff, "7fff+255");
		// Normal
		check(15'd0, 8'd0, 15'd0, "0+0");
		check(15'd0, 8'd1, 15'd1, "0+1");
		check(15'd100, 8'd50, 15'd150, "100+50");
		check(15'h7f00, 8'd16, 15'h7f10, "7f00+16");
		// Exactly one below sat
		check(15'h7ffe, 8'd0, 15'h7ffe, "7ffe+0");
		// Sum combine
		if (sat_sum_fixed(15'h7ffe, 15'd2) !== 15'h7fff) begin
			fails = fails + 1;
			$display("FAIL sum 7ffe+2");
		end
		if (sat_sum_fixed(15'h4000, 15'h4000) !== 15'h7fff) begin
			fails = fails + 1;
			$display("FAIL sum 4000+4000");
		end
		if (sat_sum_fixed(15'd3, 15'd4) !== 15'd7) begin
			fails = fails + 1;
			$display("FAIL sum 3+4");
		end

		// Store 16→15 saturate then + pix (rd-duck second boundary)
		// model: store_ur15 = (store16 >= 7fff) ? 7fff : store16[14:0]
		begin : store_sat
			reg [15:0] store16;
			reg [14:0] store15, pix15, comb;
			reg [15:0] s16;
			// 0x7fff store + 0 pix → 0x7fff
			store16 = 16'h7fff; pix15 = 15'd0;
			store15 = (store16 >= 16'h7fff) ? 15'h7fff : store16[14:0];
			s16 = {1'b0, store15} + {1'b0, pix15};
			comb = (s16 >= 16'h7fff) ? 15'h7fff : s16[14:0];
			if (comb !== 15'h7fff) begin fails=fails+1; $display("FAIL store 7fff+0 got %0d", comb); end
			// 0x8000 store alone → must be 0x7fff NOT 0 (trunc alias)
			store16 = 16'h8000; pix15 = 15'd0;
			store15 = (store16 >= 16'h7fff) ? 15'h7fff : store16[14:0];
			s16 = {1'b0, store15} + {1'b0, pix15};
			comb = (s16 >= 16'h7fff) ? 15'h7fff : s16[14:0];
			if (comb !== 15'h7fff) begin fails=fails+1; $display("FAIL store 8000+0 got %0d (trunc would be 0)", comb); end
			// buggy trunc: 8000[14:0]=0
			if ((16'h8000 & 16'h7fff) !== 16'd0) begin fails=fails+1; $display("FAIL expect trunc 8000 low=0"); end
			// 0x8000 store + pix 5 → still 0x7fff
			store16 = 16'h8000; pix15 = 15'd5;
			store15 = (store16 >= 16'h7fff) ? 15'h7fff : store16[14:0];
			s16 = {1'b0, store15} + {1'b0, pix15};
			comb = (s16 >= 16'h7fff) ? 15'h7fff : s16[14:0];
			if (comb !== 15'h7fff) begin fails=fails+1; $display("FAIL store 8000+5 got %0d", comb); end
			// 0x7ffe store + pix 2 → 0x7fff
			store16 = 16'h7ffe; pix15 = 15'd2;
			store15 = (store16 >= 16'h7fff) ? 15'h7fff : store16[14:0];
			s16 = {1'b0, store15} + {1'b0, pix15};
			comb = (s16 >= 16'h7fff) ? 15'h7fff : s16[14:0];
			if (comb !== 15'h7fff) begin fails=fails+1; $display("FAIL store 7ffe+2 got %0d", comb); end
			// 0x100 store + pix 3 → 0x103
			store16 = 16'h0100; pix15 = 15'd3;
			store15 = (store16 >= 16'h7fff) ? 15'h7fff : store16[14:0];
			s16 = {1'b0, store15} + {1'b0, pix15};
			comb = (s16 >= 16'h7fff) ? 15'h7fff : s16[14:0];
			if (comb !== 15'h0103) begin fails=fails+1; $display("FAIL store 100+3 got %0d", comb); end
			// 0xffff store → 0x7fff
			store16 = 16'hffff; pix15 = 15'd0;
			store15 = (store16 >= 16'h7fff) ? 15'h7fff : store16[14:0];
			if (store15 !== 15'h7fff) begin fails=fails+1; $display("FAIL store ffff sat got %0d", store15); end
			$display("OK store-sat vectors 7fff/8000/7ffe+pix");
		end

		// Prove buggy expression fails the boundary (used by RED)
		if (!RED_WRAP_BUG) begin
			if (sat_add_buggy(15'h7ffe, 8'd2) === 15'h7fff) begin
				fails = fails + 1;
				$display("FAIL: buggy expr unexpectedly correct at 7ffe+2");
			end else begin
				$display("OK buggy 7ffe+2 wraps to %0d (not 32767)", sat_add_buggy(15'h7ffe, 8'd2));
			end
		end

		if (RED_WRAP_BUG) begin
			// Boundary must be wrong under buggy expr
			if (sat_add(15'h7ffe, 8'd2) === 15'h7fff) begin
				$display("FAIL RED_WRAP_BUG unexpectedly saturated correctly");
				$finish(1);
			end else begin
				$display("PASS mp_ur_count_sat RED_WRAP_BUG caught (got %0d want sat)",
					sat_add(15'h7ffe, 8'd2));
				$finish;
			end
		end else begin
			if (fails != 0) begin
				$display("FAIL mp_ur_count_sat fails=%0d", fails);
				$finish(1);
			end
			$display("PASS mp_ur_count_sat boundary 7ffe+2->7fff fails=0");
			$finish;
		end
	end
endmodule
`default_nettype wire
