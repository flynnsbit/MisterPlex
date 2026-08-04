// Bit-exact pipe equivalence for present_content_window.
// Positive: PIPE_DEPTH=2 matches PIPE_DEPTH=1 with latency offset (PIPE_DEPTH_dut - 1).
// Negative: FAULT_DROP_PIPE_BALANCE must break that equivalence.
// Soft-skip≠PASS. Markers required by assert_sim_executed.

#include "Vpresent_content_window_pipe_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <deque>
#include <string>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

struct Sample {
	uint16_t sx;
	uint16_t sy;
	uint8_t de;
	uint8_t past;
};

static void tick(Vpresent_content_window_pipe_tb_top* t) {
	t->clk = 0;
	t->eval();
	main_time++;
	t->clk = 1;
	t->eval();
	main_time++;
}

static void set_geom(Vpresent_content_window_pipe_tb_top* t, int win, int cw, int ch,
                     int x0, int y0, int hde, int vde) {
	t->win_enable = win ? 1 : 0;
	t->content_w = cw;
	t->content_h = ch;
	t->content_x0 = x0;
	t->content_y0 = y0;
	t->h_de = hde;
	t->v_de = vde;
}

// Host mirror of ceil Q16 scale + pixel map (same as fabric math).
static uint32_t ceil_scale(uint32_t c_m1, uint32_t d_m1) {
	if (d_m1 == 0)
		d_m1 = 1;
	const uint64_t num = (static_cast<uint64_t>(c_m1) << 16) + d_m1 - 1;
	return static_cast<uint32_t>(num / d_m1) & 0xfffffu;
}

static Sample host_map(int hc, int py, int win, int cw, int ch, int x0, int y0, int hde,
                       int vde, int frame_w, int frame_h) {
	const int hde_eff = (hde == 0) ? 1280 : hde;
	const int vde_eff = (vde == 0) ? 720 : vde;
	const int cw_eff = win ? ((cw == 0) ? 1 : cw) : frame_w;
	const int ch_eff = win ? ((ch == 0) ? 1 : ch) : frame_h;
	const int x0e = win ? x0 : 0;
	const int y0e = win ? y0 : 0;
	const uint32_t sx = win ? ceil_scale(cw_eff > 0 ? cw_eff - 1 : 0,
	                                     hde_eff > 1 ? hde_eff - 1 : 1)
	                        : static_cast<uint32_t>((frame_w * 39647) / 320);
	const uint32_t sy = win ? ceil_scale(ch_eff > 0 ? ch_eff - 1 : 0,
	                                     vde_eff > 1 ? vde_eff - 1 : 1)
	                        : static_cast<uint32_t>((frame_h * 65536) / 480);
	const int past = (py >= vde_eff) ? 1 : 0;
	const int py_c = past ? (vde_eff > 0 ? vde_eff - 1 : 0) : py;
	const uint32_t xprod = static_cast<uint32_t>(hc) * sx;
	const uint32_t yprod = static_cast<uint32_t>(py_c) * sy;
	int last_x = win ? (x0e + cw_eff - 1) : (frame_w - 1);
	int last_y = win ? (y0e + ch_eff - 1) : (frame_h - 1);
	if (last_x > 1279)
		last_x = 1279;
	if (last_y > 719)
		last_y = 719;
	int xs = x0e + static_cast<int>(xprod >> 16);
	int ys = y0e + static_cast<int>(yprod >> 16);
	if (xs > last_x)
		xs = last_x;
	if (ys > last_y)
		ys = last_y;
	Sample s{};
	s.sx = static_cast<uint16_t>(xs);
	s.sy = static_cast<uint16_t>(ys);
	s.de = 0;
	s.past = static_cast<uint8_t>(past);
	return s;
}

struct Case {
	const char* name;
	int win, cw, ch, x0, y0, hde, vde;
	int hc_max, py_max;
};

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	auto* t = new Vpresent_content_window_pipe_tb_top;

	std::printf("present_content_window_pipe: EXECUTED\n");

	t->ce_pix = 1;
	t->hc = 0;
	t->py = 0;
	t->in_content = 0;
	set_geom(t, 0, 1280, 720, 0, 0, 1280, 720);
	t->reset = 1;
	for (int i = 0; i < 8; ++i)
		tick(t);
	t->reset = 0;
	for (int i = 0; i < 4; ++i)
		tick(t);

	if (t->g_pipe_lat != 1 || t->d_pipe_lat != 2 || t->f_pipe_lat != 2) {
		std::fprintf(stderr, "FAIL pipe_latency_ce g=%u d=%u f=%u expected 1/2/2\n",
		             t->g_pipe_lat, t->d_pipe_lat, t->f_pipe_lat);
		return 1;
	}
	std::printf("OK pipe_latency_ce ports: golden=1 dut=2 fault=2\n");

	const int lag = static_cast<int>(t->d_pipe_lat) - static_cast<int>(t->g_pipe_lat);
	if (lag != 1) {
		std::fprintf(stderr, "FAIL unexpected lag %d\n", lag);
		return 1;
	}
	std::printf("OK latency_offset_ce=%d (DUT later than golden)\n", lag);

	const std::vector<Case> cases = {
	    // Legacy full-bank (win_enable=0) — 480p-class constants via FRAME
	    {"legacy_win0_identity_de", 0, 1280, 720, 0, 0, 1280, 720, 64, 8},
	    // 720p window: 1280x720 content across 1280x720 DE (identity stretch)
	    {"win_720_identity", 1, 1280, 720, 0, 0, 1280, 720, 128, 16},
	    // Upscale 320x240 content into 1280x720 DE
	    {"win_320x240_to_720p", 1, 320, 240, 0, 0, 1280, 720, 160, 24},
	    // Offset window (pillar-ish)
	    {"win_offset_640x480", 1, 640, 480, 100, 40, 1280, 720, 96, 12},
	    // 480p-era H_DE=529 stretch of 624x480 bank
	    {"win_624x480_hde529", 1, 624, 480, 0, 0, 529, 480, 80, 10},
	};

	int fails = 0;
	int pos_match_pixels = 0;
	int fault_mismatch_pixels = 0;

	for (const Case& c : cases) {
		set_geom(t, c.win, c.cw, c.ch, c.x0, c.y0, c.hde, c.vde);
		// Scale divider: 2 * 32 steps + margin after geom_change
		t->ce_pix = 0;
		t->in_content = 0;
		for (int i = 0; i < 80; ++i)
			tick(t);
		t->ce_pix = 1;

		std::deque<Sample> g_hist;
		int case_pos_ok = 0;
		int case_fault_diff = 0;
		int case_pos_bad = 0;

		for (int py = 0; py < c.py_max; ++py) {
			for (int hc = 0; hc < c.hc_max; ++hc) {
				t->hc = hc;
				t->py = py;
				t->in_content = (hc < c.hde && py < c.vde) ? 1 : 0;
				tick(t);

				Sample gs{static_cast<uint16_t>(t->g_store_x),
				          static_cast<uint16_t>(t->g_store_y),
				          static_cast<uint8_t>(t->g_de_r),
				          static_cast<uint8_t>(t->g_past_last_row)};
				Sample ds{static_cast<uint16_t>(t->d_store_x),
				          static_cast<uint16_t>(t->d_store_y),
				          static_cast<uint8_t>(t->d_de_r),
				          static_cast<uint8_t>(t->d_past_last_row)};
				Sample fs{static_cast<uint16_t>(t->f_store_x),
				          static_cast<uint16_t>(t->f_store_y),
				          static_cast<uint8_t>(t->f_de_r),
				          static_cast<uint8_t>(t->f_past_last_row)};

				// past_last_row is beam-timed combo — identical all instances, no lag
				if (gs.past != ds.past || gs.past != fs.past) {
					std::fprintf(stderr,
					             "FAIL %s past_last_row g=%u d=%u f=%u hc=%d py=%d\n",
					             c.name, gs.past, ds.past, fs.past, hc, py);
					fails++;
					case_pos_bad++;
				}

				g_hist.push_back(gs);
				if (static_cast<int>(g_hist.size()) <= lag)
					continue;
				Sample g_old = g_hist.front();
				g_hist.pop_front();

				// Positive: DUT == golden delayed by lag
				if (ds.sx != g_old.sx || ds.sy != g_old.sy || ds.de != g_old.de) {
					if (case_pos_bad < 4) {
						std::fprintf(stderr,
						             "FAIL POS %s hc=%d py=%d dut=%u,%u,de%u "
						             "golden@lag=%u,%u,de%u\n",
						             c.name, hc, py, ds.sx, ds.sy, ds.de, g_old.sx,
						             g_old.sy, g_old.de);
					}
					fails++;
					case_pos_bad++;
				} else {
					case_pos_ok++;
					pos_match_pixels++;
				}

				// Negative: fault twin must diverge from golden@lag on some pixels.
				// (Using depth-1 live math → phase/value mismatch vs delayed golden.)
				if (fs.sx != g_old.sx || fs.sy != g_old.sy || fs.de != g_old.de) {
					case_fault_diff++;
					fault_mismatch_pixels++;
				}
			}
		}

		if (case_pos_ok < 8) {
			std::fprintf(stderr, "FAIL %s: too few POS matches (%d)\n", c.name, case_pos_ok);
			fails++;
		}
		if (case_fault_diff == 0) {
			std::fprintf(stderr,
			             "FAIL NEG %s: fault twin never diverged — tautological check\n",
			             c.name);
			fails++;
		} else {
			std::printf("OK NEG %s: fault diverged on %d pixel(s)\n", c.name,
			            case_fault_diff);
		}
		std::printf("OK POS %s: matches=%d bad=%d\n", c.name, case_pos_ok, case_pos_bad);
	}

	// Spot-check host math vs golden after settle on one geometry
	set_geom(t, 1, 320, 240, 0, 0, 1280, 720);
	t->ce_pix = 0;
	for (int i = 0; i < 80; ++i)
		tick(t);
	t->ce_pix = 1;
	t->in_content = 1;
	int host_ok = 0;
	int host_bad = 0;
	for (int n = 0; n < 4; ++n)
		tick(t); // fill golden pipe
	for (int py = 0; py < 5; ++py) {
		for (int hc = 0; hc < 20; ++hc) {
			t->hc = hc;
			t->py = py;
			tick(t);
			Sample exp = host_map(hc, py, 1, 320, 240, 0, 0, 1280, 720, 1280, 720);
			// golden registered output is 1 ce_pix behind inputs — compare next...
			// After tick, outputs reflect this cycle's inputs (depth-1).
			if (t->g_store_x == exp.sx && t->g_store_y == exp.sy) {
				host_ok++;
			} else {
				if (host_bad < 3) {
					std::fprintf(stderr,
					             "HOST mismatch hc=%d py=%d rtl=%u,%u host=%u,%u\n", hc,
					             py, t->g_store_x, t->g_store_y, exp.sx, exp.sy);
				}
				host_bad++;
			}
		}
	}
	if (host_bad != 0) {
		std::fprintf(stderr, "FAIL host_math_mirror bad=%d ok=%d\n", host_bad, host_ok);
		fails++;
	} else {
		std::printf("OK host_math_mirror checks=%d\n", host_ok);
	}

	std::printf("SUMMARY pos_match_pixels=%d fault_mismatch_pixels=%d fails=%d\n",
	            pos_match_pixels, fault_mismatch_pixels, fails);

	if (fails != 0 || pos_match_pixels < 100 || fault_mismatch_pixels < 10) {
		std::fprintf(stderr,
		             "present_content_window_pipe: FAIL fails=%d pos=%d fault_div=%d\n",
		             fails, pos_match_pixels, fault_mismatch_pixels);
		delete t;
		return 1;
	}

	std::printf("present_content_window_pipe: OK bit-exact POS + NEG fault\n");
	delete t;
	return 0;
}
