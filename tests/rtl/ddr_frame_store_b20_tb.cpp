// B20 bank+geometry atomicity.
// 1) Promote PLXG live seq=7, 80x32 — app must stay legacy 64 until bank swap.
// 2) Doorbell with plxg_seq=7, prep, vsync swap — app becomes 80.
// FAULT_B20_FREE_RUN_GEOM: step1 app==80 (REPRO).
#include "Vddr_frame_store_b20_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 65536u;
constexpr uint32_t kDoorbellPhys = 0x3001F000u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kLegacyW = 64;
constexpr int kNewW = 80;
constexpr int kH = 32;

// hi: [31]bank [30:29]fmt=1 [28:16]plxg_seq [15:0]frame_seq
uint32_t doorbellHi(uint32_t frameSeq, int bank, uint16_t plxgSeq) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) |
	       ((static_cast<uint32_t>(plxgSeq) & 0x1FFFu) << 16) |
	       (frameSeq & 0xFFFFu);
}

struct Sim {
	Vddr_frame_store_b20_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int doutGap = 1;
	int gapLeft = 0;
	int frameSeq = 1;
	int dbAccepts = 0;

	Sim() : mem((2 * kBankStrideBytes) / 8, 0) {
		top.clk = 0;
		top.clk_ddr = 0;
		top.reset = 0;
		top.geom_enable = 0;
		top.rt_geom_seq = 0;
		top.rt_geom_live = 0;
		top.rt_coded_w = 0;
		top.rt_coded_h = 0;
		top.rt_y_stride = 0;
		top.rt_chroma_stride = 0;
		top.rt_display_w = 0;
		top.rt_display_h = 0;
		top.vsync_pulse = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;
	}

	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }

	void tick() {
		serviceDdrStart();
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		serviceDdrDrive();
		top.clk = 1;
		top.clk_ddr = 1;
		top.eval();
		top.vsync_pulse = 0;
	}

	void serviceDdrStart() {
		if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			rdIndex = 0;
			rdDelay = doutGap;
			gapLeft = 0;
			busy = rdLeft + rdDelay + 1;
			if (rdAddr == (kDoorbellPhys >> 3))
				++dbAccepts;
		}
		if (top.DDRAM_WE && busy == 0) {
			const uint32_t off = top.DDRAM_ADDR - (kBasePhys >> 3);
			if (off < mem.size())
				mem[off] = top.DDRAM_DIN;
			busy = 2;
		}
	}

	void serviceDdrDrive() {
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;
		if (rdDelay > 0) {
			--rdDelay;
			return;
		}
		if (rdLeft > 0) {
			if (gapLeft > 0) {
				--gapLeft;
				return;
			}
			const uint32_t off = rdAddr + static_cast<uint32_t>(rdIndex) - (kBasePhys >> 3);
			top.DDRAM_DOUT = (off < mem.size()) ? mem[off] : 0;
			top.DDRAM_DOUT_READY = 1;
			++rdIndex;
			--rdLeft;
			if (rdLeft > 0)
				gapLeft = doutGap;
			else
				rdDelay = -1;
		}
	}

	void resetHold() {
		top.reset = 1;
		for (int i = 0; i < 8; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 4; ++i)
			tick();
	}

	void driveGeomLive(int w, int h, uint16_t seq) {
		top.geom_enable = 1;
		top.rt_geom_live = 1;
		top.rt_geom_seq = seq;
		top.rt_coded_w = w;
		top.rt_coded_h = h;
		top.rt_y_stride = w;
		top.rt_chroma_stride = w / 2;
		top.rt_display_w = w;
		top.rt_display_h = h;
		for (int i = 0; i < 8; ++i)
			tick();
	}

	void ring(int bank, uint16_t plxgSeq) {
		mem[offQ(kDoorbellPhys)] =
		    (static_cast<uint64_t>(doorbellHi(frameSeq++, bank, plxgSeq)) << 32) | kMagic;
	}

	void vsync() {
		top.vsync_pulse = 1;
		tick();
	}

	// Run until swap_pending or timeout; pulse vsync periodically so ready can land.
	bool waitSwapPending(int maxCyc) {
		for (int i = 0; i < maxCyc; ++i) {
			if (top.swap_pending)
				return true;
			if ((i % 64) == 63)
				vsync();
			else
				tick();
		}
		return top.swap_pending != 0;
	}

	bool waitHasFrame(int maxCyc) {
		for (int i = 0; i < maxCyc; ++i) {
			if (top.has_frame)
				return true;
			if ((i % 32) == 0)
				vsync();
			else
				tick();
		}
		return top.has_frame != 0;
	}
};

int runProduct() {
	Sim sim;
	sim.resetHold();

	// Idle: app = legacy CODED_W=64
	if ((int)sim.top.obs_app_coded_w != kLegacyW) {
		std::cerr << "FAIL product idle app_w=" << (int)sim.top.obs_app_coded_w << "\n";
		return 1;
	}

	// Promote candidate to 80x32 live seq=7 — must NOT move app yet.
	sim.driveGeomLive(kNewW, kH, /*seq*/7);
	std::cout << "MEASURED after_promote eff=" << (int)sim.top.obs_eff_coded_w
	          << " app=" << (int)sim.top.obs_app_coded_w
	          << " atomic=" << (int)sim.top.obs_b20_atomic << "\n";
	if ((int)sim.top.obs_eff_coded_w != kNewW) {
		std::cerr << "FAIL product: eff must track candidate 80\n";
		return 1;
	}
	if ((int)sim.top.obs_app_coded_w != kLegacyW) {
		std::cerr << "FAIL product: app moved to " << (int)sim.top.obs_app_coded_w
		          << " before bank swap (B20)\n";
		return 1;
	}
	if (!sim.top.obs_b20_atomic) {
		std::cerr << "FAIL product: b20_atomic must be 1 when live+seq\n";
		return 1;
	}

	// Doorbell with matching plxg_seq — still hold app through accept.
	sim.ring(/*bank*/1, /*plxg*/7);
	if (!sim.waitSwapPending(50000)) {
		std::cerr << "FAIL product: no swap_pending db_ok=" << (int)sim.top.doorbell_ok
		          << " db_rd=" << sim.dbAccepts << "\n";
		return 1;
	}
	std::cout << "MEASURED after_doorbell app=" << (int)sim.top.obs_app_coded_w
	          << " pend_valid=" << (int)sim.top.obs_pend_app_valid
	          << " swap_pend=" << (int)sim.top.swap_pending << "\n";
	if ((int)sim.top.obs_app_coded_w != kLegacyW) {
		std::cerr << "FAIL product: app changed at doorbell accept\n";
		return 1;
	}
	if (!sim.top.obs_pend_app_valid) {
		std::cerr << "FAIL product: pend_app_valid must set on coupled accept\n";
		return 1;
	}

	// Force pending_ready path: run until has_frame (prep + vsync).
	// Fill empty banks so line prep can complete quickly (zeros OK for geometry).
	if (!sim.waitHasFrame(200000)) {
		std::cerr << "FAIL product: no has_frame after swap window\n";
		return 1;
	}
	// Extra vsyncs to complete swap if pending_ready was late
	for (int i = 0; i < 8; ++i)
		sim.vsync();
	for (int i = 0; i < 16; ++i)
		sim.tick();

	std::cout << "MEASURED after_swap app=" << (int)sim.top.obs_app_coded_w
	          << " disp_bank=" << (int)sim.top.obs_disp_bank
	          << " frames=" << (int)sim.top.frames_done << "\n";
	if ((int)sim.top.obs_app_coded_w != kNewW) {
		std::cerr << "FAIL product: app must become 80 at bank swap got "
		          << (int)sim.top.obs_app_coded_w << "\n";
		return 1;
	}
	if ((int)sim.top.obs_disp_bank != 1) {
		std::cerr << "FAIL product: disp_bank must be 1 after swap\n";
		return 1;
	}
	std::cout << "OK B20 product holds pitch until bank swap\n";
	return 0;
}

int runFault() {
	Sim sim;
	sim.resetHold();
	sim.driveGeomLive(kNewW, kH, 7);
	std::cout << "MEASURED FAULT after_promote eff=" << (int)sim.top.obs_eff_coded_w
	          << " app=" << (int)sim.top.obs_app_coded_w
	          << " atomic=" << (int)sim.top.obs_b20_atomic << "\n";
	if (sim.top.obs_b20_atomic) {
		std::cerr << "FAIL fault twin: b20_atomic must be 0\n";
		return 1;
	}
	if ((int)sim.top.obs_app_coded_w != kNewW) {
		std::cerr << "FAIL fault twin: expected free-run app==80 for REPRO got "
		          << (int)sim.top.obs_app_coded_w << "\n";
		return 1;
	}
	std::cout << "REPRO_OK B20 free-run exposes new pitch before bank swap\n";
	return 0; // REPRO is the expected "success" of the red twin binary
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = std::getenv("B20_MODE");
	if (!mode)
		mode = "product";
	if (std::string(mode) == "fault")
		return runFault();
	return runProduct();
}
