// L4 720p24 beam geometry gate — TB forces L4 constants; product QSF untouched.
// Proves H_TOTAL=1312 V_TOTAL=762 and DE window exactly 1280×720 in ce_pix counts
// at the CURRENT clock (no PLL). Shell drives negative twins (wrong-H / off-by-one DE).

#include "Vpresent_l4_beam_tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

static void tick(Vpresent_l4_beam_tb_top& d) {
	d.clk = 0;
	d.eval();
	d.clk = 1;
	d.eval();
}

static int g_fail = 0;
static void expect(bool cond, const std::string& msg) {
	if (!cond) {
		std::cerr << "FAIL " << msg << "\n";
		++g_fail;
	}
}

struct FrameMeas {
	int cycles = 0;
	int de_pixels = 0;
	int active_lines = 0;
	int hact_stable = -1;
	int htot_stable = -1;
	int hs_edges = 0;
	int vs_high = 0;
	int hde_act = 0;
	int htot_act = 0;
	int vact_act = 0;
	int vtot_act = 0;
};

// frame_start is asserted on the same cycle counters wrap to (0,0) — that cycle
// is the first pixel of the new frame. Count from that beat inclusive until the
// beat before the next frame_start.
static FrameMeas measure_one_frame(Vpresent_l4_beam_tb_top& dut, int exp_htot, int exp_vtot) {
	FrameMeas m;
	int guard = 0;
	const int max_wait = exp_htot * exp_vtot * 4 + 10000;

	while (dut.frame_start == 0 && guard++ < max_wait)
		tick(dut);
	expect(guard < max_wait, "timeout waiting for frame_start (start)");

	m.hde_act = int(dut.hde_active);
	m.htot_act = int(dut.htot_active);
	m.vact_act = int(dut.vact_active);
	m.vtot_act = int(dut.vtot_active);

	bool prev_hs = false;
	int prev_hc = -1;
	int line_hact = 0;
	int line_htot = 0;
	int line_de = 0;
	bool first = true;

	guard = 0;
	while (guard++ < max_wait) {
		if (!first && dut.frame_start) {
			// Next frame begins — stop before counting this beat into prior frame.
			break;
		}
		first = false;

		if (dut.ce_pix) {
			m.cycles++;
			const bool hb = dut.HBlank != 0;
			const bool vb = dut.VBlank != 0;
			const bool hs = dut.HSync != 0;
			if (!hb && !vb)
				m.de_pixels++;
			if (!hb)
				line_hact++;
			line_htot++;
			if (!hb && !vb)
				line_de++;

			if (hs && !prev_hs)
				m.hs_edges++;
			if (dut.VSync)
				m.vs_high = 1;
			prev_hs = hs;

			const int hc = int(dut.hc);
			if (prev_hc > 0 && hc == 0) {
				// Completed prior line; line_* includes new line's hc=0 sample.
				const int done_hact = line_hact - (hb ? 0 : 1);
				const int done_htot = line_htot - 1;
				const int done_de = line_de - ((!hb && !vb) ? 1 : 0);
				if (done_de > 0)
					m.active_lines++;
				if (done_de > 0 && (m.active_lines == 10 || m.hact_stable < 0)) {
					m.hact_stable = done_hact;
					m.htot_stable = done_htot;
				}
				line_hact = hb ? 0 : 1;
				line_htot = 1;
				line_de = (!hb && !vb) ? 1 : 0;
			}
			prev_hc = hc;
		}
		tick(dut);
	}
	expect(guard < max_wait, "timeout waiting for frame_start (end)");
	// Close final line of frame (no wrap before next frame_start)
	if (line_de > 0)
		m.active_lines++;
	if (m.hact_stable < 0 && line_htot > 0) {
		m.hact_stable = line_hact;
		m.htot_stable = line_htot;
	}
	return m;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);

	const int exp_hde = std::getenv("L4_EXP_HDE") ? std::atoi(std::getenv("L4_EXP_HDE")) : 1280;
	const int exp_vact = std::getenv("L4_EXP_VACT") ? std::atoi(std::getenv("L4_EXP_VACT")) : 720;
	const int exp_htot = std::getenv("L4_EXP_HTOT") ? std::atoi(std::getenv("L4_EXP_HTOT")) : 1312;
	const int exp_vtot = std::getenv("L4_EXP_VTOT") ? std::atoi(std::getenv("L4_EXP_VTOT")) : 762;

	Vpresent_l4_beam_tb_top dut;
	dut.reset = 1;
	for (int i = 0; i < 16; ++i)
		tick(dut);
	dut.reset = 0;
	for (int i = 0; i < 4; ++i)
		tick(dut);

	(void)measure_one_frame(dut, exp_htot, exp_vtot);
	FrameMeas a = measure_one_frame(dut, exp_htot, exp_vtot);
	FrameMeas b = measure_one_frame(dut, exp_htot, exp_vtot);

	auto check = [&](const FrameMeas& m, const char* tag) {
		expect(m.hde_act == exp_hde,
			std::string(tag) + " hde_active got=" + std::to_string(m.hde_act) +
				" want=" + std::to_string(exp_hde));
		expect(m.htot_act == exp_htot,
			std::string(tag) + " htot_active got=" + std::to_string(m.htot_act) +
				" want=" + std::to_string(exp_htot));
		expect(m.vact_act == exp_vact,
			std::string(tag) + " vact_active got=" + std::to_string(m.vact_act) +
				" want=" + std::to_string(exp_vact));
		expect(m.vtot_act == exp_vtot,
			std::string(tag) + " vtot_active got=" + std::to_string(m.vtot_act) +
				" want=" + std::to_string(exp_vtot));
		expect(m.cycles == exp_htot * exp_vtot,
			std::string(tag) + " frame_cycles got=" + std::to_string(m.cycles) +
				" want=" + std::to_string(exp_htot * exp_vtot));
		expect(m.de_pixels == exp_hde * exp_vact,
			std::string(tag) + " de_pixels got=" + std::to_string(m.de_pixels) +
				" want=" + std::to_string(exp_hde * exp_vact));
		expect(m.active_lines == exp_vact,
			std::string(tag) + " active_lines got=" + std::to_string(m.active_lines) +
				" want=" + std::to_string(exp_vact));
		expect(m.hact_stable == exp_hde,
			std::string(tag) + " line_hact got=" + std::to_string(m.hact_stable) +
				" want=" + std::to_string(exp_hde));
		expect(m.htot_stable == exp_htot,
			std::string(tag) + " line_htot got=" + std::to_string(m.htot_stable) +
				" want=" + std::to_string(exp_htot));
		expect(m.hs_edges > 0, std::string(tag) + " HSync never edged");
		expect(m.vs_high > 0, std::string(tag) + " VSync never high");
	};

	check(a, "frameA");
	check(b, "frameB");

	if (g_fail) {
		std::cerr << "present_l4_beam RTL check FAILED: " << g_fail << " failures\n";
		return 1;
	}
	std::cout << "present_l4_beam RTL check PASS: DE=" << exp_hde << "x" << exp_vact
			  << " total=" << exp_htot << "x" << exp_vtot
			  << " de_pixels=" << a.de_pixels << " (ce_pix counts, no PLL)\n";
	return 0;
}
