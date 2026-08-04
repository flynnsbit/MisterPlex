// Tear-free bank-swap gate @ 720p-ratio geometry.
//
// Real 720p24 (parent-fixed, arithmetic not measured on device here):
//   clk_pix = 28.8e6, H_TOTAL=1600, V_TOTAL=750, V_ACTIVE=720
//   line = 1600/28.8e6 = 55.555... us
//   VBlank 30 lines = 1.666... ms safe swap window
//   frame = 41.666... ms = 1/24 s
//
// TB scales linear dims ~10x (H_TOTAL=160, V_TOTAL=75, V_ACTIVE=72) so
// multi-frame sims finish quickly while preserving active:blank = 24:1.
//
// PRE-REGISTER:
//   POS product: every displayed frame is mono-bank (one disp_bank value on
//     all active sample lines); frames_done advances on each on-time publish;
//     mid-frame doorbell does NOT change disp_bank until next vsync.
//   NEG FAULT_MID_FRAME_SWAP: checker DETECTS multi-bank within one active
//     frame (if checker cannot fail, it is tautological — forbidden).
//   producer-late: disp_bank repeats across frames; frames_done stalls then
//     resumes when producer returns; still mono-bank.
//   producer-never: after first swap, has_frame stays 1 (no permanent freeze
//     to bars); frames_done frozen; mono-bank forever.
//
// Quoted product interlock (ddr_frame_store.sv):
//   disp_bank <= pending_bank only when
//     vsync_pulse && swap_pending && pending_ready_s2 && !rd_active
//   (FAULT twin drops the vsync/!rd_active requirement.)

#include "Vddr_frame_store_bank_swap_tear_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 131072u;
constexpr uint32_t kDoorbellPhys = 0x3003F000u;
constexpr uint32_t kMagicK = 0x504C584Bu; // PLXK

// Scaled 720p-ratio raster (see top.sv).
constexpr int kW = 160;
constexpr int kH = 90;
constexpr int kDispW = 128;
constexpr int kPresentX = 16;
constexpr int kActH = 72;     // ~720/10
constexpr int kVBlank = 3;    // ~30/10; active:blank = 24:1 same as 720:30
constexpr int kHTotal = 160;  // ~1600/10
constexpr int kYQ = kW / 8;
constexpr int kCQ = kW / 16;
constexpr int kUQBase = (kW * kH) / 8;
constexpr int kVQBase = kUQBase + (kW * kH) / 32;
constexpr int kRdDelay = 3;

// Real-geometry reference numbers (printed once; not simulated cycle-accurate).
constexpr double kRealClkHz = 28.8e6;
constexpr int kRealHTotal = 1600;
constexpr int kRealVTotal = 750;
constexpr int kRealVActive = 720;
constexpr int kRealVBlank = kRealVTotal - kRealVActive;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (8 * i);
	return q;
}

struct Sim {
	Vddr_frame_store_bank_swap_tear_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	int presents = 0;

	// Per-active-frame bank observations for tear checker.
	bool frame_bank_valid = false;
	int frame_bank = 0;
	int tears = 0;
	int mono_frames = 0;
	int active_frames = 0;
	int banks_seen_this_frame = 0;
	bool saw_bank0 = false;
	bool saw_bank1 = false;
	int last_completed_frame_bank = -1;
	int repeated_bank_frames = 0;

	Sim() : mem((2 * kBankStrideBytes) / 8, 0) {
		top.clk = 0;
		top.clk_ddr = 0;
		top.reset = 0;
		top.rd_x = 0;
		top.rd_y = 0;
		top.rd_active = 0;
		top.start_req = 0;
		top.bank_sel = 0;
		top.vsync_pulse = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;
	}

	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }

	// Encode bank id in luma so content is bank-distinct (Y=0x40 bank0, 0xC0 bank1).
	void fillFrame(int bank) {
		const uint32_t base = (bank * kBankStrideBytes) / 8;
		const uint8_t y = (bank & 1) ? 0xC0u : 0x40u;
		for (int line = 0; line < kH; ++line) {
			for (int q = 0; q < kYQ; ++q)
				mem[base + line * kYQ + q] = pack8(y);
		}
		for (int line = 0; line < kH / 2; ++line) {
			for (int q = 0; q < kCQ; ++q) {
				mem[base + kUQBase + line * kCQ + q] = pack8(128);
				mem[base + kVQBase + line * kCQ + q] = pack8(128);
			}
		}
	}

	void ringDoorbell(int bank, uint32_t seq) {
		mem[offQ(kDoorbellPhys)] =
		    (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagicK;
		++presents;
	}

	void serviceDdrStart() {
		if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT;
			rdIndex = 0;
			rdDelay = kRdDelay;
			busy = rdLeft + rdDelay + 2;
		}
		if (top.DDRAM_WE && busy == 0) {
			const uint32_t off = addrOffQ(top.DDRAM_ADDR);
			if (off < mem.size())
				mem[off] = top.DDRAM_DIN;
			busy = 3;
		}
	}

	void serviceDdrDrive() {
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;
		top.DDRAM_BUSY = (busy > 0);
		if (rdDelay >= 0) {
			if (rdDelay > 0) {
				--rdDelay;
			} else if (rdLeft > 0) {
				const uint32_t off = addrOffQ(rdAddr + rdIndex);
				top.DDRAM_DOUT = off < mem.size() ? mem[off] : 0;
				top.DDRAM_DOUT_READY = 1;
				++rdIndex;
				--rdLeft;
				if (rdLeft == 0)
					rdDelay = -1;
			}
		}
	}

	void tick() {
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		serviceDdrDrive();
		top.clk = 1;
		top.clk_ddr = 1;
		top.eval();
		serviceDdrStart();
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		top.vsync_pulse = 0;
	}

	void noteActiveSample() {
		if (!top.rd_active || !top.has_frame)
			return;
		const int b = top.debug_disp_bank ? 1 : 0;
		if (!frame_bank_valid) {
			frame_bank_valid = true;
			frame_bank = b;
			saw_bank0 = (b == 0);
			saw_bank1 = (b == 1);
			banks_seen_this_frame = 1;
		} else if (b != frame_bank) {
			// Tear: disp_bank changed mid-active-frame.
			++tears;
			frame_bank = b;
			if (b == 0)
				saw_bank0 = true;
			else
				saw_bank1 = true;
			banks_seen_this_frame = (saw_bank0 && saw_bank1) ? 2 : 1;
		}
	}

	void closeFrameIfNeeded(bool at_frame_start) {
		// frame_start is at end of last VBlank line — close the *previous*
		// active frame's observation window just before the new one begins.
		if (!at_frame_start)
			return;
		if (frame_bank_valid) {
			++active_frames;
			if (banks_seen_this_frame <= 1 && tears == 0 /* cumulative check below */)
				++mono_frames;
			// Per-frame mono: only one bank observed during that active region.
			const bool mono = !(saw_bank0 && saw_bank1);
			if (!mono) {
				// already counted in tears via mid-frame changes; ensure flag
			}
			if (last_completed_frame_bank == frame_bank)
				++repeated_bank_frames;
			last_completed_frame_bank = frame_bank;
		}
		frame_bank_valid = false;
		saw_bank0 = false;
		saw_bank1 = false;
		banks_seen_this_frame = 0;
	}

	void driveBeam(bool with_vsync) {
		const int last_y = kActH - 1;
		const bool in_vblank = (vc >= kActH);
		const int rd_y = in_vblank ? last_y : vc;
		const bool x_de = (hc >= kPresentX) && (hc < kPresentX + kDispW);
		const bool y_de = !in_vblank;
		top.rd_y = rd_y;
		top.rd_active = (x_de && y_de) ? 1 : 0;
		top.rd_x = (hc >= kW) ? (kW - 1) : hc;
		top.vsync_pulse = with_vsync ? 1 : 0;
	}

	// Returns true on the vsync (frame_start) cycle.
	bool videoTick() {
		// Allow prep to drain near end of VBlank before commit edge.
		const bool last_line = (vc == (kActH + kVBlank - 1));
		const bool pre_vsync = last_line && (hc == (kHTotal - 2));
		if (pre_vsync) {
			for (int spin = 0; spin < 12000; ++spin) {
				driveBeam(false);
				tick();
				if (!top.swap_pending)
					break;
				if (top.swap_pending && top.debug_pending_ready)
					break;
			}
			++hc;
		}
		const bool at_frame_start =
		    (hc == (kHTotal - 1)) && (vc == (kActH + kVBlank - 1));
		closeFrameIfNeeded(at_frame_start);
		driveBeam(at_frame_start);
		tick();
		noteActiveSample();
		++hc;
		if (hc == kHTotal) {
			hc = 0;
			++vc;
			if (vc == kActH + kVBlank)
				vc = 0;
		}
		return at_frame_start;
	}

	void runRasterCycles(int n) {
		for (int i = 0; i < n; ++i)
			(void)videoTick();
	}

	void runOneFrame() {
		runRasterCycles(kHTotal * (kActH + kVBlank));
	}

	void resetCore() {
		top.reset = 1;
		for (int i = 0; i < 16; ++i)
			tick();
		top.reset = 0;
		for (int i = 0; i < 8; ++i)
			tick();
	}

	// Warm until first swap commits (frames_done>=1) or timeout.
	bool awaitFirstSwap(int max_frames) {
		int bank = 0;
		uint32_t seq = 1;
		fillFrame(bank);
		ringDoorbell(bank, seq);
		for (int f = 0; f < max_frames && top.frames_done < 1; ++f)
			runOneFrame();
		return top.frames_done >= 1;
	}
};

void printRealGeom() {
	const double line_us = 1e6 * double(kRealHTotal) / kRealClkHz;
	const double vblank_ms = line_us * double(kRealVBlank) / 1000.0;
	const double frame_ms = line_us * double(kRealVTotal) / 1000.0;
	std::cout << "REAL_GEOM 720p24: clk_pix=" << kRealClkHz
	          << " H_TOTAL=" << kRealHTotal << " V_TOTAL=" << kRealVTotal
	          << " V_ACTIVE=" << kRealVActive << " VBlank=" << kRealVBlank
	          << " line_us=" << line_us << " vblank_ms=" << vblank_ms
	          << " frame_ms=" << frame_ms << "\n";
	std::cout << "TB_GEOM scaled: H_TOTAL=" << kHTotal << " V_TOTAL="
	          << (kActH + kVBlank) << " V_ACTIVE=" << kActH
	          << " VBlank=" << kVBlank << " (ratio active:blank="
	          << kActH << ":" << kVBlank << ")\n";
}

// POS: on-time alternate-bank publish; every frame mono-bank; frames_done moves.
int run_pos_ontime() {
	std::cout << "=== POS on-time multi-frame (expect mono-bank, fd advances) ===\n";
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 2000; ++i)
		sim.tick();

	if (!sim.awaitFirstSwap(40)) {
		std::cerr << "FAIL pos: never got first swap\n";
		return 1;
	}
	const uint16_t fd0 = sim.top.frames_done;
	// Reset tear accounting after warm-up first frame.
	sim.tears = 0;
	sim.mono_frames = 0;
	sim.active_frames = 0;
	sim.repeated_bank_frames = 0;
	sim.last_completed_frame_bank = -1;
	sim.frame_bank_valid = false;

	int bank = sim.top.debug_disp_bank ? 1 : 0;
	uint32_t seq = 2;
	constexpr int kFrames = 12;
	for (int f = 0; f < kFrames; ++f) {
		// Publish opposite bank early in the frame (adversarial mid-active time).
		// Product must NOT commit until vsync.
		bank ^= 1;
		sim.fillFrame(bank);
		sim.ringDoorbell(bank, seq++);
		// Drive through ~1/3 of active region (mid-frame publish stress).
		sim.runRasterCycles(kHTotal * (kActH / 3));
		// Finish the frame (includes VBlank + vsync commit).
		sim.runRasterCycles(kHTotal * (kActH + kVBlank - kActH / 3));
	}

	const int fd_delta = int(sim.top.frames_done) - int(fd0);
	std::cout << "pos summary: fd_delta=" << fd_delta
	          << " active_frames=" << sim.active_frames
	          << " mono_frames=" << sim.mono_frames
	          << " tears=" << sim.tears
	          << " has_frame=" << int(sim.top.has_frame)
	          << " presents=" << sim.presents << "\n";

	if (sim.tears != 0) {
		std::cerr << "FAIL pos: product tore mid-frame tears=" << sim.tears << "\n";
		return 1;
	}
	if (fd_delta < 8) {
		std::cerr << "FAIL pos: frames_done did not advance enough fd_delta="
		          << fd_delta << "\n";
		return 1;
	}
	if (sim.active_frames < 8) {
		std::cerr << "FAIL pos: too few observed active frames\n";
		return 1;
	}
	if (!sim.top.has_frame) {
		std::cerr << "FAIL pos: has_frame dropped\n";
		return 1;
	}
	std::cout << "PASS pos_ontime: mono-bank frames, frames_done advanced, "
	             "mid-active publish deferred to vsync\n";
	return 0;
}

// NEG: FAULT mid-frame swap must produce tears>0 (checker non-tautological).
int run_neg_midframe_fault() {
	std::cout << "=== NEG mid-frame FAULT (expect TEAR detected) ===\n";
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 2000; ++i)
		sim.tick();

	if (!sim.awaitFirstSwap(40)) {
		std::cerr << "FAIL neg: never got first swap\n";
		return 1;
	}
	sim.tears = 0;
	sim.mono_frames = 0;
	sim.active_frames = 0;
	sim.frame_bank_valid = false;
	sim.saw_bank0 = false;
	sim.saw_bank1 = false;

	int bank = sim.top.debug_disp_bank ? 1 : 0;
	uint32_t seq = 2;
	// Publish during active; FAULT commits immediately → tear inside frame.
	for (int f = 0; f < 6; ++f) {
		bank ^= 1;
		sim.fillFrame(bank);
		// Advance into active region first.
		sim.runRasterCycles(kHTotal * 2);
		sim.ringDoorbell(bank, seq++);
		// Spin while active so FAULT can commit mid-frame.
		sim.runRasterCycles(kHTotal * (kActH / 2));
		// Finish frame.
		sim.runRasterCycles(kHTotal * (kActH + kVBlank - 2 - kActH / 2));
	}

	std::cout << "neg summary: tears=" << sim.tears
	          << " active_frames=" << sim.active_frames
	          << " fd=" << sim.top.frames_done << "\n";

	if (sim.tears <= 0) {
		std::cerr << "FAIL neg: tear checker did not fire under "
		             "FAULT_MID_FRAME_SWAP (tautological checker)\n";
		return 1;
	}
	std::cout << "PASS neg_midframe_fault: checker detected tears="
	          << sim.tears << " (non-tautological)\n";
	return 0;
}

// Producer-late: skip several frames of publish; must repeat bank mono; then recover.
int run_producer_late() {
	std::cout << "=== POS producer-late (expect frame repeat then recover) ===\n";
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 2000; ++i)
		sim.tick();

	if (!sim.awaitFirstSwap(40)) {
		std::cerr << "FAIL late: never got first swap\n";
		return 1;
	}
	const uint16_t fd_after_first = sim.top.frames_done;
	const int bank_held = sim.top.debug_disp_bank ? 1 : 0;
	sim.tears = 0;
	sim.frame_bank_valid = false;
	sim.saw_bank0 = false;
	sim.saw_bank1 = false;
	sim.repeated_bank_frames = 0;
	sim.last_completed_frame_bank = -1;
	sim.active_frames = 0;

	// No publish for 5 frames — must repeat held bank, mono, fd stall.
	for (int f = 0; f < 5; ++f)
		sim.runOneFrame();

	const uint16_t fd_stalled = sim.top.frames_done;
	if (fd_stalled != fd_after_first) {
		std::cerr << "FAIL late: frames_done moved without publish "
		          << fd_after_first << "->" << fd_stalled << "\n";
		return 1;
	}
	if (sim.tears != 0) {
		std::cerr << "FAIL late: tore during starvation tears=" << sim.tears << "\n";
		return 1;
	}
	if ((sim.top.debug_disp_bank ? 1 : 0) != bank_held) {
		std::cerr << "FAIL late: disp_bank changed without publish\n";
		return 1;
	}
	if (!sim.top.has_frame) {
		std::cerr << "FAIL late: has_frame cleared during starvation\n";
		return 1;
	}

	// Producer returns.
	const int new_bank = bank_held ^ 1;
	sim.fillFrame(new_bank);
	sim.ringDoorbell(new_bank, 99);
	for (int f = 0; f < 4 && sim.top.frames_done == fd_stalled; ++f)
		sim.runOneFrame();

	if (sim.top.frames_done <= fd_stalled) {
		std::cerr << "FAIL late: did not recover after producer returned\n";
		return 1;
	}
	if (sim.tears != 0) {
		std::cerr << "FAIL late: tore on recovery\n";
		return 1;
	}
	std::cout << "PASS producer_late: repeated bank mono, fd stalled, then recovered "
	          << "fd=" << sim.top.frames_done << "\n";
	return 0;
}

// Producer-never: after first frame, never publish again — no permanent freeze/bars.
int run_producer_never() {
	std::cout << "=== POS producer-never (expect sticky has_frame, no freeze) ===\n";
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 2000; ++i)
		sim.tick();

	if (!sim.awaitFirstSwap(40)) {
		std::cerr << "FAIL never: never got first swap\n";
		return 1;
	}
	const uint16_t fd0 = sim.top.frames_done;
	sim.tears = 0;

	for (int f = 0; f < 8; ++f)
		sim.runOneFrame();

	if (!sim.top.has_frame) {
		std::cerr << "FAIL never: has_frame dropped (would show bars)\n";
		return 1;
	}
	if (sim.top.frames_done != fd0) {
		std::cerr << "FAIL never: frames_done moved without publish\n";
		return 1;
	}
	if (sim.tears != 0) {
		std::cerr << "FAIL never: tore\n";
		return 1;
	}
	// Still scanning: rd path exercised; underruns may occur if linebufs age out
	// but must not clear has_frame.
	std::cout << "PASS producer_never: has_frame sticky, fd frozen, mono, no bars\n";
	return 0;
}

// No-publish at all: must NOT swap; frames_done stays 0 (negative for "always swap").
int run_neg_no_publish() {
	std::cout << "=== NEG no-publish (expect no swap, fd=0) ===\n";
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 2000; ++i)
		sim.tick();
	for (int f = 0; f < 6; ++f)
		sim.runOneFrame();
	if (sim.top.frames_done != 0) {
		std::cerr << "FAIL no_publish: frames_done advanced without doorbell\n";
		return 1;
	}
	if (sim.top.has_frame) {
		std::cerr << "FAIL no_publish: has_frame set without doorbell\n";
		return 1;
	}
	std::cout << "PASS neg_no_publish: no swap without doorbell\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	printRealGeom();

	std::cout << "PRE-REGISTER:\n"
	          << "  POS on-time: tears=0, fd_delta>=8, mid-active publish deferred\n"
	          << "  NEG mid-frame FAULT: tears>0 (checker must be able to fail)\n"
	          << "  POS late: fd stall then recover, mono, has_frame sticky\n"
	          << "  POS never: has_frame sticky, fd frozen\n"
	          << "  NEG no-publish: fd=0 has_frame=0\n";

	const char* mode = (argc > 1) ? argv[1] : "all_product";
	int rc = 0;
	if (std::string(mode) == "neg_fault") {
		// Built with -DDDR_FRAME_STORE_FAULT_MID_FRAME_SWAP
		rc = run_neg_midframe_fault();
	} else if (std::string(mode) == "pos_ontime") {
		rc = run_pos_ontime();
	} else if (std::string(mode) == "late") {
		rc = run_producer_late();
	} else if (std::string(mode) == "never") {
		rc = run_producer_never();
	} else if (std::string(mode) == "no_publish") {
		rc = run_neg_no_publish();
	} else {
		// Default product suite (no FAULT macro).
		rc = run_pos_ontime();
		if (rc == 0)
			rc = run_producer_late();
		if (rc == 0)
			rc = run_producer_never();
		if (rc == 0)
			rc = run_neg_no_publish();
	}

	if (rc == 0)
		std::cout << "OK ddr_frame_store_bank_swap_tear mode=" << mode << "\n";
	return rc;
}
