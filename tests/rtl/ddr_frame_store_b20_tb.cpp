// B20 bank+geometry atomicity.
// 0) Delayed-promotion (rd-duck): before live geom matches, doorbell+SPI
//    produce ZERO bank swaps (no stale 960 vs native corruption).
// 1) Promote PLXG live seq=7, 80x32 — app must stay legacy 64 until bank swap.
// 2) Doorbell with plxg_seq=7, prep, vsync swap — app becomes 80.
// FAULT_B20_FREE_RUN_GEOM: step1 app==80 (REPRO).
// FAULT_SPI_UNGATED: SPI swaps before promote (REPRO).
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
		top.start_req = 0;
		top.bank_sel = 0;
		top.rd_x = 0;
		top.rd_y = 0;
		top.rd_active = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;
	}

	// Pack 8 identical luma/chroma bytes into a qword.
	static uint64_t pack8(uint8_t v) {
		uint64_t q = 0;
		for (int i = 0; i < 8; ++i)
			q |= (static_cast<uint64_t>(v) << (8 * i));
		return q;
	}

	// Paint I420 bank: Y=yVal, U=V=128 (neutral). Covers legacy 64 and native 80.
	void paintBank(int bank, int w, int h, uint8_t yVal) {
		const uint32_t base = kBasePhys + static_cast<uint32_t>(bank) * kBankStrideBytes;
		const int yPlane = w * h;
		const int cPlane = (w / 2) * (h / 2);
		for (int row = 0; row < h; ++row) {
			for (int x = 0; x < w; x += 8) {
				const uint32_t phys = base + static_cast<uint32_t>(row * w + x);
				mem[offQ(phys)] = pack8(yVal);
			}
		}
		const uint32_t uBase = base + static_cast<uint32_t>(yPlane);
		const uint32_t vBase = uBase + static_cast<uint32_t>(cPlane);
		for (int i = 0; i < cPlane; i += 8) {
			mem[offQ(uBase + static_cast<uint32_t>(i))] = pack8(128);
			mem[offQ(vBase + static_cast<uint32_t>(i))] = pack8(128);
		}
	}

	// Scan a few visible pixels; return max(R+G+B) seen while active.
	int scanMaxLumaRgb(int frames) {
		int maxSum = 0;
		const int aw = (int)top.obs_app_disp_w;
		const int ah = (int)top.obs_app_disp_h;
		const int w = aw > 0 ? aw : kLegacyW;
		const int h = ah > 0 ? ah : kH;
		for (int f = 0; f < frames; ++f) {
			vsync();
			for (int y = 0; y < h; ++y) {
				for (int x = 0; x < w; ++x) {
					top.rd_x = x & 0x7f;
					top.rd_y = y & 0x3f;
					top.rd_active = 1;
					tick();
					tick(); // pipeline
					if (top.rd_active && top.has_frame) {
						const int sum = (int)top.rd_r + (int)top.rd_g + (int)top.rd_b;
						if (sum > maxSum)
							maxSum = sum;
					}
				}
			}
			top.rd_active = 0;
			for (int i = 0; i < 8; ++i)
				tick();
		}
		return maxSum;
	}

	// Pulse SPI start_req edge (bank_sel-only path).
	void pulseSpi(int bank) {
		top.bank_sel = bank & 1;
		top.start_req = 0;
		tick();
		top.start_req = 1;
		for (int i = 0; i < 8; ++i)
			tick();
		top.start_req = 0;
		for (int i = 0; i < 16; ++i)
			tick();
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

	// Mode-exit disable: geom_enable=0 (eff→LEG) but latch still live+seq
	// so b20_atomic stays 1 — must NOT free-run app_* (rd-duck).
	void driveGeomDisableLive(uint16_t seq) {
		top.geom_enable = 0;
		top.rt_geom_live = 1;
		top.rt_geom_seq = seq;
		top.rt_coded_w = 0;
		top.rt_coded_h = 0;
		top.rt_y_stride = 0;
		top.rt_chroma_stride = 0;
		top.rt_display_w = 0;
		top.rt_display_h = 0;
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

	// ---- Delayed-promotion (rd-duck): ZERO swaps before matching live geom ----
	// Host wrote PLXG body + may ring doorbell, but latch has not promoted
	// (rt_geom_live=0). Product store must not free-run candidate dims until
	// live (present_core ties geom dims to latch outputs); TB keeps
	// geom_enable=0 here so !b20_atomic free-run cannot poison app_*. Coupled
	// doorbell field!=0 with !live must reject; SPI must not swap.
	const int frames0 = (int)sim.top.frames_done;
	sim.top.geom_enable = 0;
	sim.top.rt_geom_live = 0;
	sim.top.rt_geom_seq = 7;
	for (int i = 0; i < 32; ++i)
		sim.tick();
	if ((int)sim.top.obs_app_coded_w != kLegacyW) {
		std::cerr << "FAIL delayed-promo: app left legacy before live\n";
		return 1;
	}
	sim.ring(/*bank*/1, /*plxg*/7);
	for (int i = 0; i < 4000; ++i) {
		if (sim.top.swap_pending) {
			std::cerr << "FAIL delayed-promo: doorbell swapped before live geom\n";
			return 1;
		}
		sim.tick();
	}
	sim.pulseSpi(/*bank*/1);
	for (int i = 0; i < 2000; ++i) {
		if (sim.top.swap_pending) {
			std::cerr << "FAIL delayed-promo: SPI swapped before live geom\n";
			return 1;
		}
		sim.tick();
	}
	if ((int)sim.top.frames_done != frames0) {
		std::cerr << "FAIL delayed-promo: frames_done advanced before promote\n";
		return 1;
	}
	if ((int)sim.top.obs_disp_bank != 0) {
		std::cerr << "FAIL delayed-promo: disp_bank moved before promote\n";
		return 1;
	}
	std::cout << "OK delayed-promotion: zero swap before matching live geom "
	          << "(doorbell+SPI)\n";

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

	// ---- Mode-exit under live seq: must NOT free-run app to LEG ----
	// app is 80; disable geom_enable while live+seq remains → b20_atomic.
	// Free-run would snap app→64 immediately (624-in-960 class with mux DE).
	// Paint BOTH banks so post-disable legacy bank can produce non-black RGB.
	sim.paintBank(/*bank*/0, kLegacyW, kH, /*Y*/220);
	sim.paintBank(/*bank*/1, kNewW, kH, /*Y*/220);

	sim.driveGeomDisableLive(/*seq*/7);
	std::cout << "MEASURED mode_exit_drop eff=" << (int)sim.top.obs_eff_coded_w
	          << " app=" << (int)sim.top.obs_app_coded_w
	          << " atomic=" << (int)sim.top.obs_b20_atomic
	          << " hollow=" << (int)sim.top.obs_geom_hollow << "\n";
	if (!sim.top.obs_b20_atomic) {
		std::cerr << "FAIL mode-exit: b20_atomic must stay 1 under live+seq disable\n";
		return 1;
	}
	if ((int)sim.top.obs_eff_coded_w != kLegacyW) {
		std::cerr << "FAIL mode-exit: eff must be LEG after geom_enable=0 got "
		          << (int)sim.top.obs_eff_coded_w << "\n";
		return 1;
	}
	if ((int)sim.top.obs_app_coded_w != kNewW) {
		std::cerr << "FAIL mode-exit: app free-ran to " << (int)sim.top.obs_app_coded_w
		          << " before bank swap (expected hold " << kNewW << ")\n";
		return 1;
	}
	// Intentional disable must NOT sticky-hollow (rd-duck permanent black).
	if (sim.top.obs_geom_hollow) {
		std::cerr << "FAIL mode-exit: geom_hollow sticky on intentional disable "
		          << "(would force permanent RGB black)\n";
		return 1;
	}
	// Doorbell accept snapshots LEG into pend; app still holds 80.
	// has_frame is already 1 — wait on frames_done advance, not has_frame.
	const int framesAtDisable = (int)sim.top.frames_done;
	sim.ring(/*bank*/0, /*plxg*/7);
	if (!sim.waitSwapPending(50000)) {
		std::cerr << "FAIL mode-exit: no swap_pending on disable doorbell\n";
		return 1;
	}
	if ((int)sim.top.obs_app_coded_w != kNewW) {
		std::cerr << "FAIL mode-exit: app changed at disable doorbell accept\n";
		return 1;
	}
	if (!sim.top.obs_pend_app_valid) {
		std::cerr << "FAIL mode-exit: pend_app_valid must set on disable accept\n";
		return 1;
	}
	if (sim.top.obs_geom_hollow) {
		std::cerr << "FAIL mode-exit: hollow set at disable doorbell\n";
		return 1;
	}
	bool swapped = false;
	for (int i = 0; i < 200000; ++i) {
		if ((int)sim.top.frames_done > framesAtDisable &&
		    (int)sim.top.obs_app_coded_w == kLegacyW) {
			swapped = true;
			break;
		}
		if ((i % 32) == 0)
			sim.vsync();
		else
			sim.tick();
	}
	std::cout << "MEASURED mode_exit_swap app=" << (int)sim.top.obs_app_coded_w
	          << " disp_w=" << (int)sim.top.obs_app_disp_w
	          << " disp_bank=" << (int)sim.top.obs_disp_bank
	          << " geom_en=" << (int)sim.top.obs_app_geom_en
	          << " hollow=" << (int)sim.top.obs_geom_hollow
	          << " hold_blk=" << (int)sim.top.obs_geom_hold_black
	          << " frames=" << (int)sim.top.frames_done
	          << " (was " << framesAtDisable << ")\n";
	if (!swapped) {
		std::cerr << "FAIL mode-exit: app must become LEG at bank swap got "
		          << (int)sim.top.obs_app_coded_w
		          << " frames_done=" << (int)sim.top.frames_done << "\n";
		return 1;
	}
	if ((int)sim.top.obs_app_geom_en != 0) {
		std::cerr << "FAIL mode-exit: app_geom_en must be 0 after disable swap\n";
		return 1;
	}
	if (sim.top.obs_geom_hollow) {
		std::cerr << "FAIL mode-exit: hollow after disable bank swap\n";
		return 1;
	}
	// Drain B16 hold-black (2 vsyncs on layout change) then demand non-black
	// legacy 64-wide frame (pixel-extent oracle, not just geom_enable/map).
	for (int i = 0; i < 16; ++i)
		sim.vsync();
	for (int i = 0; i < 64; ++i)
		sim.tick(); // allow line refill from painted bank0
	if (sim.top.obs_geom_hold_black) {
		// one more drain
		for (int i = 0; i < 8; ++i)
			sim.vsync();
	}
	if (sim.top.obs_geom_hollow) {
		std::cerr << "FAIL mode-exit: hollow still set during legacy scan\n";
		return 1;
	}
	const int maxRgb = sim.scanMaxLumaRgb(/*frames*/4);
	std::cout << "MEASURED mode_exit_scan maxRGB=" << maxRgb
	          << " app_w=" << (int)sim.top.obs_app_coded_w
	          << " hollow=" << (int)sim.top.obs_geom_hollow
	          << " hold_blk=" << (int)sim.top.obs_geom_hold_black << "\n";
	if ((int)sim.top.obs_app_coded_w != kLegacyW ||
	    (int)sim.top.obs_app_disp_w != kLegacyW) {
		std::cerr << "FAIL mode-exit: legacy pixel extent expected "
		          << kLegacyW << "x" << kH << " got w="
		          << (int)sim.top.obs_app_coded_w << " disp="
		          << (int)sim.top.obs_app_disp_w << "\n";
		return 1;
	}
	// Y=220 neutral chroma → RGB well above black. Hollow old bug → maxRGB=0.
	if (maxRgb < 40) {
		std::cerr << "FAIL mode-exit: expected non-black legacy frame after disable "
		          << "got maxRGB=" << maxRgb
		          << " (hollow/hold stuck or no fill)\n";
		return 1;
	}
	std::cout << "OK B20 mode-exit holds pitch until bank swap (no free-run)\n";
	std::cout << "OK B20 mode-exit pixel oracle nonblack legacy (no hollow black)\n";
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

// FAULT_SPI_UNGATED: SPI before promote must swap (REPRO corruption class).
// Built under -DDDR_FRAME_STORE_FAULT_SPI_UNGATED; exit 2 on REPRO.
// STRICT_YUV still needs have_seq: prime with one ungated (field-0) doorbell,
// drain that swap, then SPI under !live — product would refuse; FAULT swaps.
int runSpiFault() {
	Sim sim;
	sim.resetHold();
	sim.top.geom_enable = 0;
	sim.top.rt_geom_live = 0;
	sim.top.rt_geom_seq = 0;
	for (int i = 0; i < 32; ++i)
		sim.tick();
	// Prime have_seq via legacy ungated doorbell; drain swap so SPI can edge.
	sim.ring(/*bank*/0, /*plxg*/0);
	if (!sim.waitSwapPending(50000)) {
		std::cerr << "FAIL spi fault twin: ungated prime did not swap\n";
		return 1;
	}
	// Complete prime swap so swap_pending clears.
	if (!sim.waitHasFrame(200000)) {
		std::cerr << "FAIL spi fault twin: prime swap never ready\n";
		return 1;
	}
	for (int i = 0; i < 8; ++i)
		sim.vsync();
	for (int i = 0; i < 64; ++i)
		sim.tick();
	if (sim.top.swap_pending) {
		std::cerr << "FAIL spi fault twin: prime swap_pending stuck\n";
		return 1;
	}
	// Pre-promote SPI under FAULT — must accept bank_sel-only.
	sim.pulseSpi(/*bank*/1);
	bool saw = false;
	for (int i = 0; i < 4000; ++i) {
		if (sim.top.swap_pending) {
			saw = true;
			break;
		}
		sim.tick();
	}
	if (!saw) {
		std::cerr << "FAIL spi fault twin: SPI did not swap before promote "
		          << "(cannot see defect)\n";
		return 1;
	}
	std::cout << "REPRO spi-before-promote swap_pending=1 (corruption class)\n";
	return 2;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = std::getenv("B20_MODE");
	if (!mode)
		mode = "product";
	if (std::string(mode) == "fault")
		return runFault();
	if (std::string(mode) == "spi_fault")
		return runSpiFault();
	return runProduct();
}
