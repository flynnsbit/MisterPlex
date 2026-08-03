`timescale 1ps/1ps
// COLLISION #7: elaborate full beam port list. PINNOTFOUND if merge drops ports.
`default_nettype none
module beam_port_contract_tb;
	reg clk = 0, reset = 1;
	always #12500 clk = ~clk;

	wire ce, hb, hs, vb, vs, fstart;
	wire [10:0] hc, vc, hde_a, htot_a, vact_a, vtot_a;

	present_beam_content_de #(
		.H_DE(960), .V_ACTIVE(540), .H_TOTAL(1182), .V_TOTAL(564)
	) u_beam (
		.clk(clk),
		.reset(reset),
		.use_rt_vtotal(1'b1),
		.rt_vtotal(11'd564),
		.use_rt_geom(1'b1),
		.rt_h_de(11'd320),
		.rt_h_total(11'd1182),
		.rt_v_active(11'd240), .rt_de_apply(1'b1),
		.ce_pix(ce),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.frame_start(fstart),
		.hc_out(hc),
		.vc_out(vc),
		.hde_active(hde_a),
		.htot_active(htot_a),
		.vact_active(vact_a),
		.vtot_active(vtot_a)
	);

	initial begin
		repeat (8) @(posedge clk);
		reset = 0;
		repeat (1182 * 10) @(posedge clk);
		#1;
		if (htot_a !== 11'd1182) begin
			$display("FAIL htot_active=%0d want 1182", htot_a); $fatal(1);
		end
		if (hde_a !== 11'd320) begin
			$display("FAIL hde_active=%0d want 320", hde_a); $fatal(1);
		end
		if (vact_a !== 11'd240) begin
			$display("FAIL vact_active=%0d want 240", vact_a); $fatal(1);
		end
		$display("OK beam_port_contract elab htot_active=%0d hde=%0d vact=%0d",
			htot_a, hde_a, vact_a);
		$display("PASS beam_port_contract_tb");
		$finish;
	end
endmodule
`default_nettype wire
