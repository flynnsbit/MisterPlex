// B5: beam + content_window + ddr_frame_store under PRESENT_BEAM_960 geometry.
//
// PRODUCT_LEGACY  — store params from product svh (624×480 / 640 present).
//                   Must FAIL: STORE_LEGACY_SHAPE, accepted != 518400.
// TB_LOCAL_960    — compile-time 960×540 store (NOT product svh). Proves
//                   accepted==518400 + underrun clear when bank is shaped.
// RED_STARVE      — TB_LOCAL shape; service until has_frame then starve DDR.
//                   underrun_count must rise (falsifiable).
//
// Soft-skip ≠ pass. true rc direct.

#include "Vpresent_beam_ddr_store_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static constexpr int kHDe = 960;
static constexpr int kVAct = 540;
static constexpr int kHTot = 1182;
static constexpr int kVTot = 564;
static constexpr int kTarget = kHDe * kVAct; // 518400
static constexpr uint32_t kBasePhys = 0x30000000u;
static constexpr uint32_t kMagic = 0x504C584Bu;

enum class Mode { Legacy, Tb960, Starve };

static Mode parseMode(int argc, char** argv) {
	for (int i = 1; i < argc; ++i) {
		if (!std::strcmp(argv[i], "LEGACY") || !std::strcmp(argv[i], "PRODUCT_LEGACY"))
			return Mode::Legacy;
		if (!std::strcmp(argv[i], "TB960") || !std::strcmp(argv[i], "TB_LOCAL_960"))
			return Mode::Tb960;
		if (!std::strcmp(argv[i], "STARVE") || !std::strcmp(argv[i], "RED_STARVE"))
			return Mode::Starve;
	}
#if defined(BEAM_DDR_STARVE)
	return Mode::Starve;
#elif defined(BEAM_DDR_TB_LOCAL_960)
	return Mode::Tb960;
#else
	return Mode::Legacy;
#endif
}

static uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

static uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (i * 8);
	return q;
}

struct Sim {
	Vpresent_beam_ddr_store_tb top{};
	std::vector<uint64_t> mem;
	uint32_t basePhys = kBasePhys;
	uint32_t doorbellPhys = 0x300FF000u;
	uint32_t bankStride = 0x80000u;
	int codedW = 624;
	int codedH = 480;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int kRdLat = 0; // instant beats (native_480p lesson)
	bool starve = false;
	uint64_t ddr_rd_beats = 0;
	uint64_t ddr_rd_cmds = 0;

	explicit Sim(Mode m) {
		top.clk = 0;
		top.clk_ddr = 0;
		top.reset = 1;
		top.start_req = 0;
		top.bank_sel = 0;
		top.geom_enable = 0;
		top.rt_coded_w = 0;
		top.rt_coded_h = 0;
		top.rt_y_stride = 0;
		top.rt_chroma_stride = 0;
		top.rt_display_w = 0;
		top.rt_display_h = 0;
		top.rt_present_x = 0;
		top.rt_present_y = 0;
		top.rt_crop_left = 0;
		top.rt_crop_top = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;

		if (m == Mode::Legacy) {
			codedW = 624;
			codedH = 480;
			bankStride = 0x80000u;
			doorbellPhys = 0x300FF000u;
		} else {
			// Match TB_LOCAL_960 top params
			codedW = 960;
			codedH = 540;
			bankStride = 0x100000u;
			doorbellPhys = 0x30000000u + (2u * bankStride) - 0x1000u; // 0x301FF000
		}
		// Cover base → doorbell page + slack
		const size_t bytes = static_cast<size_t>(doorbellPhys - basePhys) + 0x2000u;
		mem.assign(bytes / 8, 0);
	}

	uint32_t addrOffQ(uint32_t addr) const { return addr - (basePhys >> 3); }

	void fillI420(int bank, uint8_t yv, uint8_t uv) {
		const uint32_t baseQ = (static_cast<uint32_t>(bank) * bankStride) / 8;
		const int yStride = codedW;
		const int cStride = codedW / 2;
		const int yBytes = yStride * codedH;
		const int cBytes = cStride * (codedH / 2);
		const int frameBytes = yBytes + 2 * cBytes;
		const int planeQ = frameBytes / 8;
		for (int i = 0; i < planeQ; ++i) {
			const size_t a = baseQ + static_cast<uint32_t>(i);
			if (a < mem.size())
				mem[a] = 0;
		}
		// Y
		for (int y = 0; y < codedH; ++y) {
			for (int x = 0; x < codedW; x += 8) {
				const int linear = y * yStride + x;
				const size_t a = baseQ + static_cast<size_t>(linear / 8);
				if (a < mem.size())
					mem[a] = pack8(yv);
			}
		}
		const int uBaseQ = yBytes / 8;
		const int vBaseQ = uBaseQ + cBytes / 8;
		for (int y = 0; y < codedH / 2; ++y) {
			for (int x = 0; x < cStride; x += 8) {
				size_t ua = baseQ + static_cast<size_t>(uBaseQ + (y * cStride + x) / 8);
				size_t va = baseQ + static_cast<size_t>(vBaseQ + (y * cStride + x) / 8);
				if (ua < mem.size())
					mem[ua] = pack8(uv);
				if (va < mem.size())
					mem[va] = pack8(uv);
			}
		}
	}

	void ringDoorbell(int bank, uint32_t seq) {
		const uint32_t off = (doorbellPhys - basePhys) / 8;
		if (off >= mem.size()) {
			std::fprintf(stderr, "FAIL doorbell OOR off=%u memQ=%zu\n", off, mem.size());
			return;
		}
		mem[off] = (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void ddrStep() {
		top.DDRAM_BUSY = busy > 0 ? 1 : 0;
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;

		if (starve) {
			// Accept no new commands' data; still clear BUSY so fabric can re-issue.
			if (top.DDRAM_RD && busy == 0) {
				// swallow command without returning beats
				busy = 1;
				rdDelay = -1;
				rdLeft = 0;
			}
			if (top.DDRAM_WE && busy == 0)
				busy = 1;
			return;
		}

		if (rdDelay > 0) {
			--rdDelay;
		} else if (rdDelay == 0 && rdLeft > 0) {
			const uint32_t idx = addrOffQ(rdAddr) + static_cast<uint32_t>(rdIndex);
			top.DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
			top.DDRAM_DOUT_READY = 1;
			++ddr_rd_beats;
			++rdIndex;
			--rdLeft;
			if (rdLeft == 0)
				rdDelay = -1;
			else
				rdDelay = 0;
		}

		if (top.DDRAM_RD && busy == 0 && rdDelay < 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			rdIndex = 0;
			rdDelay = kRdLat;
			busy = 1;
			++ddr_rd_cmds;
		}
		if (top.DDRAM_WE && busy == 0) {
			const uint32_t idx = addrOffQ(top.DDRAM_ADDR);
			if (idx < mem.size())
				mem[idx] = top.DDRAM_DIN;
			busy = 1;
		}
	}

	void tick() {
		ddrStep();
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		++main_time;
		top.clk = 1;
		top.clk_ddr = 1;
		top.eval();
		++main_time;
	}

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 32; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 16; ++i)
			tick();
	}
};

struct FrameScore {
	uint64_t de_pixels = 0;
	uint64_t store_req = 0;
	uint64_t store_accepted = 0; // delayed rd_active && non-black RGB (store hit)
	uint64_t store_visible_req = 0;
	int de_w_min = 1 << 30, de_w_max = 0, de_lines = 0;
	int line_req_min = 1 << 30, line_req_max = 0;
	int line_acc_min = 1 << 30, line_acc_max = 0;
	uint16_t ur0 = 0, ur1 = 0;
};

static FrameScore measureOneFrame(Sim& sim, int pres_x, int disp_w, int pres_y, int disp_h) {
	FrameScore s;
	// Sample ur0 *before* align ticks so STARVE's first miss frame is not
	// excluded from delta (16-bit underrun saturates in <1 frame when cold).
	s.ur0 = sim.top.underrun_count;
	// Align to frame_start
	const int align_max = kHTot * kVTot * 3;
	bool aligned = false;
	for (int i = 0; i < align_max; ++i) {
		if (sim.top.frame_start) {
			aligned = true;
			break;
		}
		sim.tick();
	}
	if (!aligned)
		return s;
	int line_de = 0, line_req = 0, line_acc = 0;
	int hc_prev = static_cast<int>(sim.top.hc);
	// RGB lags rd_active by ~2 (store pipeline)
	uint8_t ra_d0 = 0, ra_d1 = 0;
	uint8_t vis_d0 = 0, vis_d1 = 0;
	int lines = 0;
	const int expect_vt = kVTot;

	// Count until next frame_start after nearly full frame (true_de_count style)
	while (true) {
		const int hc = static_cast<int>(sim.top.hc);
		const uint8_t de = sim.top.de_out;
		const uint8_t rda = sim.top.rd_active_w;
		const int sx = static_cast<int>(sim.top.store_x);
		const int sy = static_cast<int>(sim.top.store_y);
		const bool vis = (sx >= pres_x) && (sx < pres_x + disp_w) && (sy >= pres_y) &&
		                 (sy < pres_y + disp_h);
		const uint8_t fs = sim.top.frame_start;

		if (hc_prev > hc) {
			// line wrap
			if (line_de > 0) {
				s.de_lines++;
				if (line_de < s.de_w_min)
					s.de_w_min = line_de;
				if (line_de > s.de_w_max)
					s.de_w_max = line_de;
			}
			if (line_req > 0) {
				if (line_req < s.line_req_min)
					s.line_req_min = line_req;
				if (line_req > s.line_req_max)
					s.line_req_max = line_req;
			}
			if (line_acc > 0) {
				if (line_acc < s.line_acc_min)
					s.line_acc_min = line_acc;
				if (line_acc > s.line_acc_max)
					s.line_acc_max = line_acc;
			}
			line_de = line_req = line_acc = 0;
			lines++;
		}

		if (de) {
			line_de++;
			s.de_pixels++;
		}
		if (rda) {
			line_req++;
			s.store_req++;
			if (vis)
				s.store_visible_req++;
		}

		if (ra_d1 && sim.top.has_frame) {
			const int rgb = static_cast<int>(sim.top.rd_r) | static_cast<int>(sim.top.rd_g) |
			                static_cast<int>(sim.top.rd_b);
			if (vis_d1 && rgb != 0) {
				s.store_accepted++;
				line_acc++;
			}
		}
		ra_d1 = ra_d0;
		vis_d1 = vis_d0;
		ra_d0 = rda;
		vis_d0 = vis ? 1 : 0;

		hc_prev = hc;
		sim.tick();
		if (fs && lines >= expect_vt - 1)
			break;
		if (lines > expect_vt + 2)
			break;
	}
	if (line_de > 0) {
		s.de_lines++;
		if (line_de < s.de_w_min)
			s.de_w_min = line_de;
		if (line_de > s.de_w_max)
			s.de_w_max = line_de;
	}
	if (line_req > 0) {
		if (line_req < s.line_req_min)
			s.line_req_min = line_req;
		if (line_req > s.line_req_max)
			s.line_req_max = line_req;
	}
	if (line_acc > 0) {
		if (line_acc < s.line_acc_min)
			s.line_acc_min = line_acc;
		if (line_acc > s.line_acc_max)
			s.line_acc_max = line_acc;
	}
	if (s.de_w_min > s.de_w_max)
		s.de_w_min = 0;
	if (s.line_req_min > s.line_req_max)
		s.line_req_min = 0;
	if (s.line_acc_min > s.line_acc_max)
		s.line_acc_min = 0;
	// Drain store RGB pipeline so last active pixels are scored.
	for (int d = 0; d < 4; ++d) {
		if (ra_d1 && sim.top.has_frame) {
			const int rgb = static_cast<int>(sim.top.rd_r) | static_cast<int>(sim.top.rd_g) |
			                static_cast<int>(sim.top.rd_b);
			if (vis_d1 && rgb != 0)
				s.store_accepted++;
		}
		ra_d1 = ra_d0;
		vis_d1 = vis_d0;
		ra_d0 = 0;
		vis_d0 = 0;
		sim.tick();
	}
	s.ur1 = sim.top.underrun_count;
	return s;
}

static int run(Mode mode) {
	const char* name = mode == Mode::Legacy   ? "PRODUCT_LEGACY"
	                   : mode == Mode::Starve ? "RED_STARVE"
	                                          : "TB_LOCAL_960";
	Sim sim(mode);
	sim.resetCore();

	// Idle a bit so geom latches
	for (int i = 0; i < 64; ++i)
		sim.tick();

	// Fill + doorbell (Y=0xB0 so RGB non-black when U=V=128)
	sim.fillI420(/*bank*/ 0, /*yv*/ 0xB0, /*uv*/ 128);
	sim.ringDoorbell(/*bank*/ 0, /*seq*/ 1);

	// Wait for frames_done / has_frame (prep + vsync swap)
	const int max_wait = kHTot * kVTot * 12;
	for (int i = 0; i < max_wait && sim.top.frames_done < 1; ++i)
		sim.tick();

	bool got_frame = sim.top.has_frame && sim.top.frames_done >= 1;

	const int pres_x = static_cast<int>(sim.top.store_param_pres_x);
	const int disp_w = static_cast<int>(sim.top.store_param_disp_w);
	const int pres_y = static_cast<int>(sim.top.store_param_pres_y);
	const int disp_h = static_cast<int>(sim.top.store_param_disp_h);
	const int param_fw = static_cast<int>(sim.top.store_param_w);
	const int param_fh = static_cast<int>(sim.top.store_param_h);
	const int param_cw = static_cast<int>(sim.top.store_param_coded_w);
	const int param_ch = static_cast<int>(sim.top.store_param_coded_h);
	const int svh_cw = static_cast<int>(sim.top.svh_coded_w);
	const int svh_ch = static_cast<int>(sim.top.svh_coded_h);
	const int svh_pw = static_cast<int>(sim.top.svh_presented_w);
	const int svh_ph = static_cast<int>(sim.top.svh_presented_h);

	// Same multi-frame warm for all modes so linebufs settle with underrun==0
	// (TB_LOCAL proves this is reachable). STARVE then cuts DDR *after* settle.
	if (got_frame) {
		for (int i = 0; i < kHTot * kVTot * 3; ++i)
			sim.tick();
	}
	const uint16_t ur_after_warm = sim.top.underrun_count;
	std::printf("  pre_measure underrun=%u has_frame=%d frames_done=%u\n",
	            static_cast<unsigned>(ur_after_warm), sim.top.has_frame ? 1 : 0,
	            static_cast<unsigned>(sim.top.frames_done));

	if (mode == Mode::Starve && got_frame) {
		if (ur_after_warm != 0) {
			std::printf("  WARN starve baseline underrun!=0 (16b may saturate)\n");
		}
		// Cut DDR *immediately before* measureOneFrame samples ur0. Do not tick
		// under starve first — a full align frame would saturate the 16-bit
		// underrun counter and make delta=0 (false "clear").
		sim.starve = true;
		sim.rdDelay = -1;
		sim.rdLeft = 0;
	}

	FrameScore sc = measureOneFrame(sim, pres_x, disp_w, pres_y, disp_h);
	const uint16_t ur_delta = static_cast<uint16_t>(sc.ur1 - sc.ur0);

	const bool shape_960 = (param_cw >= 960 && param_ch >= 540 && param_fw >= 960 && param_fh >= 540);
	const bool svh_legacy = (svh_cw == 624 && svh_ch == 480 && svh_pw == 640 && svh_ph == 480);
	const bool de_ok = (sc.de_pixels == static_cast<uint64_t>(kTarget)) && (sc.de_w_min == kHDe) &&
	                   (sc.de_w_max == kHDe) && (sc.de_lines == kVAct);
	const bool req_full = (sc.store_req == static_cast<uint64_t>(kTarget)) &&
	                      (sc.line_req_min == kHDe) && (sc.line_req_max == kHDe);
	const bool acc_full = (sc.store_accepted == static_cast<uint64_t>(kTarget)) &&
	                      (sc.line_acc_min == kHDe) && (sc.line_acc_max == kHDe);
	const bool underrun_clear = (ur_delta == 0);

	std::printf("CASE %s EXECUTED\n", name);
	std::printf("  svh coded=%dx%d presented=%dx%d legacy_svh=%d\n", svh_cw, svh_ch, svh_pw, svh_ph,
	            svh_legacy ? 1 : 0);
	std::printf("  store_param FRAME=%dx%d CODED=%dx%d DISP=%dx%d PRES=%d,%d shape_960=%d\n",
	            param_fw, param_fh, param_cw, param_ch, disp_w, disp_h, pres_x, pres_y,
	            shape_960 ? 1 : 0);
	std::printf("  has_frame=%d frames_done=%u doorbell_ok=%d debug=0x%02x\n",
	            sim.top.has_frame ? 1 : 0, static_cast<unsigned>(sim.top.frames_done),
	            sim.top.doorbell_ok ? 1 : 0, static_cast<unsigned>(sim.top.debug_state));
	std::printf("  ddr_rd_cmds=%llu ddr_rd_beats=%llu starve=%d\n",
	            static_cast<unsigned long long>(sim.ddr_rd_cmds),
	            static_cast<unsigned long long>(sim.ddr_rd_beats), sim.starve ? 1 : 0);
	std::printf("  de_pixels=%llu de_w=%d..%d de_lines=%d de_ok=%d\n",
	            static_cast<unsigned long long>(sc.de_pixels),
	            sc.de_w_min == (1 << 30) ? -1 : sc.de_w_min, sc.de_w_max, sc.de_lines, de_ok ? 1 : 0);
	std::printf("  store_req=%llu line_req=%d..%d req_full=%d visible_req=%llu\n",
	            static_cast<unsigned long long>(sc.store_req),
	            sc.line_req_min == (1 << 30) ? -1 : sc.line_req_min, sc.line_req_max, req_full ? 1 : 0,
	            static_cast<unsigned long long>(sc.store_visible_req));
	std::printf("  store_accepted=%llu line_acc=%d..%d acc_full=%d\n",
	            static_cast<unsigned long long>(sc.store_accepted),
	            sc.line_acc_min == (1 << 30) ? -1 : sc.line_acc_min, sc.line_acc_max, acc_full ? 1 : 0);
	std::printf("  underrun_start=%u end=%u delta=%u clear=%d\n", static_cast<unsigned>(sc.ur0),
	            static_cast<unsigned>(sc.ur1), static_cast<unsigned>(ur_delta),
	            underrun_clear ? 1 : 0);

	int fails = 0;
	auto expect = [&](bool ok, const char* tag) {
		if (ok)
			std::printf("  PASS %s\n", tag);
		else {
			std::printf("  FAIL %s\n", tag);
			++fails;
		}
	};

	// Beam side always required
	expect(de_ok, "de_raster_960x540");
	expect(req_full, "store_req_full_518400");

	if (mode == Mode::Legacy) {
		expect(svh_legacy, "svh_still_legacy_624x480");
		if (shape_960) {
			std::printf("  FAIL STORE_UNEXPECTED_960 (product path must be legacy-shaped)\n");
			++fails;
		} else {
			std::printf("  PASS STORE_LEGACY_SHAPE coded=%d frame=%d\n", param_cw, param_fw);
		}
		// Must not look product-green
		if (acc_full && underrun_clear && got_frame) {
			std::printf("  FAIL PRODUCT_FALSE_GREEN\n");
			++fails;
		} else {
			std::printf("  PASS PRODUCT_NOT_FALSE_GREEN accepted=%llu ur_d=%u\n",
			            static_cast<unsigned long long>(sc.store_accepted),
			            static_cast<unsigned>(ur_delta));
		}
		std::printf("  STORE_LEGACY_SHAPE=1\n");
		std::printf("  VERDICT B5_PRODUCT_NOT_READY store_accepted=%llu need=%d "
		            "(B1_NO_COMPILE_TIME_OPTC)\n",
		            static_cast<unsigned long long>(sc.store_accepted), kTarget);
		// Product case is an honest FAIL for the fit claim
		if (fails == 0)
			fails = 1;
		std::printf("  OVERALL FAIL fails=%d (expected for PRODUCT_LEGACY)\n", fails);
		return 1;
	}

	if (mode == Mode::Starve) {
		expect(shape_960, "tb_local_960_shape");
		expect(got_frame, "has_frame_before_starve");
		expect(ur_delta > 0, "UNDERRUN_FIRED");
		if (acc_full) {
			std::printf("  FAIL STARVE_STILL_FULL_ACCEPT\n");
			++fails;
		} else {
			std::printf("  PASS STARVE_ACCEPTED_BELOW_FULL accepted=%llu\n",
			            static_cast<unsigned long long>(sc.store_accepted));
		}
		std::printf("  OVERALL %s fails=%d (RED twin expects FAIL exit)\n",
		            fails ? "FAIL" : "PASS_CHECKS_BUT_RED", fails);
		return 1; // red twin always nonzero
	}

	// TB_LOCAL_960 experimental
	std::printf("  NOTE TB_LOCAL_960_NOT_PRODUCT_SVH\n");
	expect(shape_960, "tb_local_960_shape");
	expect(got_frame, "has_frame");
	expect(acc_full, "store_accepted_full_518400");
	expect(underrun_clear, "rd_underrun_clear");
	// Denominator check (parent miss #4 class)
	expect(sc.store_accepted == static_cast<uint64_t>(kTarget), "accepted_N_is_518400");
	std::printf("  OVERALL %s fails=%d\n", fails ? "FAIL" : "PASS", fails);
	return fails ? 1 : 0;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const int rc = run(parseMode(argc, argv));
	std::printf("true_rc_candidate=%d\n", rc);
	return rc;
}
