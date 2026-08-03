`timescale 1ns/1ps
// First/last coordinate RGB+DE oracle (rd-duck same-clock sync trap).
// INCLUDE_SYNC=1 + PREFILL: DE edges must align with first/last active RGB.
// Encodes x in R, y in G on active groups; blank groups black.
// RED_DIRECT_SYNC=1: ignore FIFO hb/vb and use a leading counter DE — must FAIL.
`default_nettype none
module present_npx_first_last_de_tb #(
	parameter int PX_PER_CLK = 2,
	parameter int H_DE = 32,
	parameter int H_TOTAL = 48,
	parameter int V_ACTIVE = 8,
	parameter int V_TOTAL = 12,
	parameter int PREFILL = 16,
	parameter bit RED_DIRECT_SYNC = 1'b0
);
	reg clk_sys = 0, clk_pix = 0;
	always #25 clk_sys = ~clk_sys; // 20 MHz
	always #25 clk_pix = ~clk_pix; // same-clock (the trap class)

	reg reset_sys = 1, reset_pix = 1;
	reg in_valid = 0;
	reg [PX_PER_CLK*8-1:0] in_r = '0, in_g = '0, in_b = '0;
	reg [PX_PER_CLK-1:0] in_lv = '0;
	reg in_hb = 1, in_hs = 0, in_vb = 1, in_vs = 0, in_fs = 0;
	wire in_ready;
	wire out_ce;
	wire [7:0] out_r, out_g, out_b;
	wire out_hb, out_hs, out_vb, out_vs, out_fs;
	wire wr_full, wr_af, rd_empty, rd_ur;

	present_npx_path #(
		.PX_PER_CLK(PX_PER_CLK),
		.FIFO_AW(6),
		.INCLUDE_SYNC(1'b1),
		.PREFILL_GROUPS(PREFILL)
	) dut (
		.clk_sys(clk_sys), .reset_sys(reset_sys),
		.clk_pix(clk_pix), .reset_pix(reset_pix),
		.in_valid(in_valid), .in_r(in_r), .in_g(in_g), .in_b(in_b),
		.in_lane_valid(in_lv),
		.in_hblank(in_hb), .in_hsync(in_hs), .in_vblank(in_vb), .in_vsync(in_vs),
		.in_fstart(in_fs),
		.in_ready(in_ready),
		.out_ce(out_ce), .out_r(out_r), .out_g(out_g), .out_b(out_b),
		.out_hblank(out_hb), .out_hsync(out_hs), .out_vblank(out_vb), .out_vsync(out_vs),
		.out_fstart(out_fs),
		.wr_full(wr_full), .wr_almost_full(wr_af),
		.rd_underrun(rd_ur), .rd_empty(rd_empty)
	);

	// Producer beam (group steps)
	integer hx, vy, li, frames_sent, stall, timeout;
	integer de_pix, first_ok, last_ok, mism, frames_out;
	reg seen_active, line_active;
	integer exp_x, exp_y;
	reg [7:0] first_r, first_g, last_r, last_g;
	reg got_first, got_last;
	// Leading (unaligned) DE counter for RED_DIRECT_SYNC
	integer lead_x, lead_y;
	reg lead_de, lead_seen;
	wire out_de_fifo = out_ce && !out_hb && !out_vb;
	wire out_de = RED_DIRECT_SYNC ? (out_ce && lead_de) : out_de_fifo;

	task automatic sys_tick;
		begin @(posedge clk_sys); #1; end
	endtask

	// Advance a fake leading DE at pix rate (ignores FIFO) — wrong on purpose.
	always @(posedge clk_pix) begin
		if (reset_pix) begin
			lead_x <= 0; lead_y <= 0; lead_de <= 0; lead_seen <= 0;
		end else if (out_ce) begin
			// Start leading DE as soon as any pixel emerges (too early vs prefill align)
			if (!lead_seen && (out_r != 0 || out_g != 0 || !out_hb))
				lead_seen <= 1;
			if (lead_seen) begin
				lead_de <= (lead_x < H_DE) && (lead_y < V_ACTIVE);
				if (lead_x == H_TOTAL-1) begin
					lead_x <= 0;
					lead_y <= (lead_y == V_TOTAL-1) ? 0 : lead_y+1;
				end else lead_x <= lead_x+1;
			end
		end
	end

	always @(posedge clk_pix) begin
		if (reset_pix) begin
			de_pix <= 0; mism <= 0; frames_out <= 0;
			got_first <= 0; got_last <= 0;
			exp_x <= 0; exp_y <= 0;
			seen_active <= 0;
		end else if (out_ce) begin
			if (out_fs) frames_out <= frames_out + 1;
			if (out_de) begin
				if (!got_first) begin
					got_first <= 1;
					first_r <= out_r;
					first_g <= out_g;
					// first active must be x=0,y=0 → R=0,G=0
					if (out_r !== 8'd0 || out_g !== 8'd0) begin
						mism <= mism + 1;
						$display("FAIL first DE rgb=%02x,%02x want 00,00", out_r, out_g);
					end else first_ok = 1;
				end
				// coordinate check while in frame 0 active
				if (exp_y < V_ACTIVE) begin
					if (out_r !== exp_x[7:0] || out_g !== exp_y[7:0]) begin
						mism <= mism + 1;
						if (mism < 8)
							$display("FAIL coord de_pix=%0d got r=%0d g=%0d exp x=%0d y=%0d",
								de_pix, out_r, out_g, exp_x, exp_y);
					end
				end
				last_r <= out_r;
				last_g <= out_g;
				de_pix <= de_pix + 1;
				if (exp_x == H_DE-1) begin
					exp_x <= 0;
					exp_y <= exp_y + 1;
				end else exp_x <= exp_x + 1;
				seen_active <= 1;
			end else if (seen_active && exp_y >= V_ACTIVE && !got_last) begin
				// just left active region of frame — check last stored
				got_last <= 1;
				if (last_r !== 8'(H_DE-1) || last_g !== 8'(V_ACTIVE-1)) begin
					mism <= mism + 1;
					$display("FAIL last DE rgb=%0d,%0d want %0d,%0d",
						last_r, last_g, H_DE-1, V_ACTIVE-1);
				end else last_ok = 1;
			end
		end
	end

	initial begin
		first_ok = 0; last_ok = 0; frames_sent = 0;
		repeat (8) sys_tick;
		reset_sys = 0; reset_pix = 0;
		repeat (8) sys_tick;

		// Send 2 frames of groups
		for (frames_sent = 0; frames_sent < 2; frames_sent = frames_sent + 1) begin
			for (vy = 0; vy < V_TOTAL; vy = vy + 1) begin
				for (hx = 0; hx < H_TOTAL; hx = hx + PX_PER_CLK) begin
					stall = 0;
					while (!in_ready && stall < 100000) begin sys_tick; stall = stall + 1; end
					if (!in_ready) begin $display("FAIL ready stuck"); $fatal(1); end
					in_hb = (hx >= H_DE);
					in_vb = (vy >= V_ACTIVE);
					in_hs = (hx >= H_DE+2) && (hx < H_DE+6);
					in_vs = (vy >= V_ACTIVE+1) && (vy < V_ACTIVE+3);
					in_fs = (hx == 0 && vy == 0);
					in_r = '0; in_g = '0; in_b = '0;
					in_lv = {PX_PER_CLK{1'b1}};
					for (li = 0; li < PX_PER_CLK; li = li + 1) begin
						if (hx + li < H_DE && vy < V_ACTIVE) begin
							in_r[li*8 +: 8] = (hx + li);
							in_g[li*8 +: 8] = vy[7:0];
							in_b[li*8 +: 8] = 8'hA5;
						end
					end
					in_valid = 1;
					sys_tick;
					in_valid = 0;
					in_fs = 0;
				end
			end
		end

		timeout = 0;
		while ((!got_last || de_pix < H_DE*V_ACTIVE) && timeout < 500000) begin
			sys_tick;
			timeout = timeout + 1;
		end

		$display("ORACLE de_pix=%0d first_ok=%0d last_ok=%0d mism=%0d frames_out=%0d RED=%0d",
			de_pix, first_ok, last_ok, mism, frames_out, RED_DIRECT_SYNC);

		if (RED_DIRECT_SYNC) begin
			// Expect failure: leading DE does not match RGB coords
			if (mism == 0 && first_ok && last_ok) begin
				$display("FAIL RED_DIRECT_SYNC unexpectedly clean");
				$fatal(1);
			end
			$display("PASS present_npx_first_last_de RED_DIRECT_SYNC (caught skew mism=%0d)", mism);
		end else begin
			if (de_pix < H_DE*V_ACTIVE) begin
				$display("FAIL short de_pix=%0d want>=%0d", de_pix, H_DE*V_ACTIVE);
				$fatal(1);
			end
			if (!first_ok || !last_ok || mism != 0) begin
				$display("FAIL alignment first=%0d last=%0d mism=%0d", first_ok, last_ok, mism);
				$fatal(1);
			end
			if (frames_out < 1) begin
				$display("FAIL no out_fstart frames_out=%0d", frames_out);
				$fatal(1);
			end
			$display("PASS present_npx_first_last_de first/last RGB+DE aligned de_pix=%0d", de_pix);
		end
		$finish;
	end
endmodule
`default_nettype wire
