// Runtime stride / CODED geometry RBG for ddr_frame_store (w-scaler).
//
// Cases:
//   A) geom_enable=0 → first U/V qword bases == legacy 624×480 (37440 / 46800)
//   B) geom_enable=1, 1280×720 stride=1280 → U/V bases 115200 / 144000
//   C) neg: geom=0 cannot satisfy 720p base expectations
//
// Red twin (+define+DDR_FRAME_STORE_FAULT_IGNORE_GEOM):
//   Case B expectations against DUT that ignores geom → correctly FAIL.
// Soft-skip≠PASS. true rc direct.

#include "Vddr_frame_store_runtime_stride_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 524288u;
constexpr uint32_t kDoorbellPhys = 0x300FF000u;
constexpr uint32_t kMagic = 0x504C584Bu;

constexpr int kLegW = 624;
constexpr int kLegH = 480;
constexpr int kLegUQ = (kLegW * kLegH) / 8;           // 37440
constexpr int kLegVQ = kLegUQ + (kLegW * kLegH) / 32; // 46800
constexpr int kLegYPitchQ = kLegW / 8;                // 78
constexpr int kLegCPitchQ = kLegW / 16;               // 39

constexpr int kRtW = 1280;
constexpr int kRtH = 720;
constexpr int kRtYStride = 1280;
constexpr int kRtCStride = 640;
constexpr int kRtUQ = (kRtYStride * kRtH) / 8;       // 115200
constexpr int kRtCQ = (kRtCStride * (kRtH / 2)) / 8; // 28800
constexpr int kRtVQ = kRtUQ + kRtCQ;                 // 144000
constexpr int kRtYPitchQ = kRtYStride / 8;           // 160
constexpr int kRtCPitchQ = kRtCStride / 8;           // 80

static_assert(kLegUQ == 37440, "legacy U");
static_assert(kLegVQ == 46800, "legacy V");
static_assert(kRtUQ == 115200, "720p U");
static_assert(kRtVQ == 144000, "720p V");

constexpr size_t kMemQ = (4u * 1024u * 1024u) / 8u;
constexpr int kHTotal = 800;
constexpr int kVBlank = 16;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (i * 8);
	return q;
}

struct Sim {
	Vddr_frame_store_runtime_stride_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	int kRdDelay = 0;
	uint64_t y_reads = 0;
	uint64_t u_reads = 0;
	uint64_t v_reads = 0;
	uint64_t first_u_addr = 0;
	uint64_t first_v_addr = 0;
	bool saw_u = false;
	bool saw_v = false;
	int cls_u = kLegUQ;
	int cls_v = kLegVQ;
	int cls_v_end = kLegVQ + (kLegW * kLegH) / 32;
	int frame_w = 640;
	int frame_h = 480;

	Sim() : mem(kMemQ, 0) {
		top.clk = 0;
		top.clk_ddr = 0;
		top.reset = 0;
		top.rd_x = 0;
		top.rd_y = 0;
		top.rd_active = 0;
		top.start_req = 1;
		top.bank_sel = 0;
		top.vsync_pulse = 0;
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
	}

	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

	void clearStats() {
		y_reads = u_reads = v_reads = 0;
		first_u_addr = first_v_addr = 0;
		saw_u = saw_v = false;
	}

	void setGeom(bool en, int cw, int ch, int ys, int cs, int dw, int dh, int px) {
		top.geom_enable = en ? 1 : 0;
		top.rt_coded_w = cw;
		top.rt_coded_h = ch;
		top.rt_y_stride = ys;
		top.rt_chroma_stride = cs;
		top.rt_display_w = dw;
		top.rt_display_h = dh;
		top.rt_present_x = px;
		top.rt_present_y = 0;
		top.rt_crop_left = 0;
		top.rt_crop_top = 0;
	}

	void setClassify(int u, int v, int v_end) {
		cls_u = u;
		cls_v = v;
		cls_v_end = v_end;
	}

	void fillSparse(int y_pitch_q, int c_pitch_q, int u_base_q, int v_base_q, int y_fetch_q,
	                int c_fetch_q, int lines_y) {
		for (size_t i = 0; i < mem.size(); ++i)
			mem[i] = 0;
		for (int line = 0; line < lines_y; ++line) {
			for (int q = 0; q < y_fetch_q; ++q) {
				const size_t a = static_cast<size_t>(line * y_pitch_q + q);
				if (a < mem.size())
					mem[a] = pack8(static_cast<uint8_t>(40 + (line & 7)));
			}
		}
		const int lines_c = (lines_y + 1) / 2;
		for (int line = 0; line < lines_c; ++line) {
			for (int q = 0; q < c_fetch_q; ++q) {
				const size_t ua = static_cast<size_t>(u_base_q + line * c_pitch_q + q);
				const size_t va = static_cast<size_t>(v_base_q + line * c_pitch_q + q);
				if (ua < mem.size())
					mem[ua] = pack8(128);
				if (va < mem.size())
					mem[va] = pack8(128);
			}
		}
	}

	void ringDoorbell(int bank, uint32_t seq) {
		const uint32_t off = offQ(kDoorbellPhys);
		mem[off] = (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
	}

	void ddrStep() {
		top.DDRAM_BUSY = busy > 0 ? 1 : 0;
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;

		if (rdDelay > 0) {
			--rdDelay;
		} else if (rdDelay == 0 && rdLeft > 0) {
			const uint32_t idx = addrOffQ(rdAddr) + static_cast<uint32_t>(rdIndex);
			top.DDRAM_DOUT = (idx < mem.size()) ? mem[idx] : 0;
			top.DDRAM_DOUT_READY = 1;
			const uint64_t rel = idx;
			const uint32_t db_rel = offQ(kDoorbellPhys);
			if (rel < db_rel || rel > db_rel + 64) {
				if (rel < static_cast<uint64_t>(cls_u)) {
					++y_reads;
				} else if (rel < static_cast<uint64_t>(cls_v)) {
					++u_reads;
					if (!saw_u) {
						saw_u = true;
						first_u_addr = rel;
					}
				} else if (rel < static_cast<uint64_t>(cls_v_end)) {
					++v_reads;
					if (!saw_v) {
						saw_v = true;
						first_v_addr = rel;
					}
				}
			}
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
			rdDelay = kRdDelay;
			busy = 1;
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
		const bool active = (hc < frame_w) && (vc < frame_h);
		top.rd_active = active ? 1 : 0;
		top.rd_x = (hc < frame_w) ? hc : (frame_w - 1);
		top.rd_y = (vc < frame_h) ? vc : (frame_h - 1);
		const bool at_frame_start = (hc == 0 && vc == 0);
		top.vsync_pulse = at_frame_start ? 1 : 0;

		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		top.clk = 1;
		top.clk_ddr = 1;
		top.eval();

		++hc;
		if (hc >= kHTotal) {
			hc = 0;
			++vc;
			if (vc >= frame_h + kVBlank)
				vc = 0;
		}
	}

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 16; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 8; ++i)
			tick();
	}
};

int run_case(const char* name, bool geom, int cw, int ch, int ys, int cs, int dw, int dh, int px,
             int exp_u, int exp_v, int y_pitch_q, int c_pitch_q, int y_fetch_q, int c_fetch_q,
             bool expect_pass) {
	Sim sim;
	sim.frame_w = std::max(dw + px + 8, 64);
	sim.frame_h = std::min(std::max(dh, 48), 64);
	sim.setGeom(geom, cw, ch, ys, cs, dw, dh, px);
	sim.setClassify(exp_u, exp_v, exp_v + std::max(c_pitch_q * 4, 256));

	sim.resetCore();
	// Warmup so doorbell poll path sets doorbell_primed (same as native_480p).
	for (int i = 0; i < 4000; ++i)
		sim.tick();

	sim.fillSparse(y_pitch_q, c_pitch_q, exp_u, exp_v, y_fetch_q, c_fetch_q, sim.frame_h + 4);
	sim.ringDoorbell(/*bank*/ 0, /*seq*/ 1);
	sim.clearStats();

	const int maxTicks = kHTotal * (sim.frame_h + kVBlank) * 12;
	for (int i = 0; i < maxTicks && int(sim.top.frames_done) < 1; ++i)
		sim.tick();

	for (int i = 0; i < kHTotal * (sim.frame_h + kVBlank) * 3; ++i)
		sim.tick();

	const bool u_ok = sim.saw_u && static_cast<int>(sim.first_u_addr) == exp_u;
	const bool v_ok = sim.saw_v && static_cast<int>(sim.first_v_addr) == exp_v;
	const bool pass = u_ok && v_ok;

	std::cout << "CASE " << name << " EXECUTED geom=" << (geom ? 1 : 0) << " coded=" << cw << "x"
	          << ch << " y_stride=" << ys << " first_u_q=" << sim.first_u_addr
	          << " expect_u_q=" << exp_u << " first_v_q=" << sim.first_v_addr
	          << " expect_v_q=" << exp_v << " y_reads=" << sim.y_reads << " u_reads=" << sim.u_reads
	          << " v_reads=" << sim.v_reads << " frames_done=" << int(sim.top.frames_done)
	          << " has_frame=" << int(sim.top.has_frame) << " debug=0x" << std::hex
	          << int(sim.top.debug_state) << std::dec << "\n";

	if (expect_pass) {
		if (int(sim.top.frames_done) < 1) {
			std::cerr << "FAIL " << name << ": never got frames_done\n";
			return 1;
		}
		if (!pass) {
			std::cerr << "FAIL " << name << ": plane base mismatch u_ok=" << u_ok
			          << " v_ok=" << v_ok << "\n";
			return 1;
		}
		std::cout << "PASS " << name << " plane_bases OK\n";
		return 0;
	}
	if (pass) {
		std::cerr << "FAIL red-check " << name
		          << ": unexpectedly matched runtime bases under fixed path\n";
		return 1;
	}
	std::cout << "PASS red-check " << name << ": fixed-624 path missed runtime bases\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	for (int i = 1; i < argc; ++i)
		(void)argv[i];

#ifdef DDR_FRAME_STORE_FAULT_IGNORE_GEOM
	const int rc = run_case("rt720_against_ignore_geom", true, kRtW, kRtH, kRtYStride, kRtCStride,
	                        kRtW, 64, 0, kRtUQ, kRtVQ, kRtYPitchQ, kRtCPitchQ, kRtW / 8, kRtW / 16,
	                        /*expect_pass=*/false);
	std::cout << "RUNTIME_STRIDE_RED_DONE rc=" << rc << "\n";
	return rc;
#else
	int fails = 0;
	fails += run_case("legacy624", false, 0, 0, 0, 0, 618, 64, 11, kLegUQ, kLegVQ, kLegYPitchQ,
	                  kLegCPitchQ, kLegW / 8, kLegW / 16, true);
	fails += run_case("rt720", true, kRtW, kRtH, kRtYStride, kRtCStride, kRtW, 64, 0, kRtUQ, kRtVQ,
	                  kRtYPitchQ, kRtCPitchQ, kRtW / 8, kRtW / 16, true);
	if (kLegUQ == kRtUQ || kLegVQ == kRtVQ) {
		std::cerr << "FAIL structural: legacy and 720p bases collided\n";
		++fails;
	} else {
		std::cout << "CASE neg_bases_distinct EXECUTED leg_u=" << kLegUQ << " rt_u=" << kRtUQ
		          << "\n";
		std::cout << "PASS neg_bases_distinct: fixed-624 bases cannot satisfy 720p expect\n";
	}
	fails += run_case("neg_geom0_expect720", false, 0, 0, 0, 0, 618, 64, 11, kRtUQ, kRtVQ,
	                  kLegYPitchQ, kLegCPitchQ, kLegW / 8, kLegW / 16, /*expect_pass=*/false);
	std::cout << "RUNTIME_STRIDE_GREEN_DONE fails=" << fails << "\n";
	return fails ? 1 : 0;
#endif
}
