// Sustained high-rate DDR scanout freeze gate (playback-class pressure).
//
// Parent HW: idle animates on same RBF+daemon; playback freezes (byte-identical
// HDMI) while ARM presents keep advancing. w-fit owns ARM bank/PLXD; this TB
// owns scanout under continuous alternating-bank doorbells.
//
// Mechanisms under test (quoted ddr_frame_store.sv):
//   1) vsync_pulse && swap_pending && pending_ready_s2 — 1-cycle swap window
//   2) PENDING_READY_STICKY_PREP / PREP_SLOT_RECYCLE under every-frame churn
//   3) SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC — same-cycle doorbell+vsync must not
//      drop the newly accepted pending bank (legacy NBA clear won).
//
// Pre-register:
//   holds=0 + sticky=1 + high-rate collide → REPRO freeze/lost swaps
//   holds=1 + sticky=1 + high-rate → PASS motion, frames_done tracks presents
// Pure C++ race model runs first (no Verilator) then real RTL sustained sim.

#include "Vddr_frame_store_scanout_sustained_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <set>
#include <string>
#include <vector>

namespace {

// --- Pure sys-clk race model (no DUT) ---------------------------------------
// NBA model: pending_bank update is simultaneous; disp_bank reads old pending.
struct SwapSysNba {
	bool swap_pending = false;
	bool pending_bank = false;
	bool disp_bank = false;
	bool swap_req_s2 = false;
	bool swap_req_seen = false;
	int frames_done = 0;
	bool holds = true;

	void cycle(bool vsync, bool ready, bool req_level, bool req_bank) {
		const bool seen0 = swap_req_seen;
		const bool pend0 = pending_bank;
		const bool sp0 = swap_pending;
		const bool new_req = (req_level != seen0);

		bool seen1 = seen0;
		bool pend1 = pend0;
		bool sp1 = sp0;
		bool disp1 = disp_bank;
		int fd1 = frames_done;

		if (new_req) {
			seen1 = req_level;
			pend1 = req_bank;
			if (!(holds && vsync && sp0 && ready))
				sp1 = true;
		}
		if (vsync && sp0 && ready) {
			disp1 = pend0; // pre-NBA pending_bank
			fd1 += 1;
			if (holds && new_req)
				sp1 = true;
			else
				sp1 = false;
		}

		swap_req_seen = seen1;
		pending_bank = pend1;
		swap_pending = sp1;
		disp_bank = disp1;
		frames_done = fd1;
		swap_req_s2 = req_level;
	}
};

int run_race_model() {
	std::cout << "PRE-REGISTER race model:\n"
	          << "  holds=0 same-cycle req+vsync → lost pending (swap_pending=0, frames+1 once)\n"
	          << "  holds=1 same-cycle req+vsync → keep swap_pending for new bank\n";

	// Sequence: establish pending bank0 ready, then same-cycle vsync swap + new bank1 req.
	SwapSysNba leg;
	leg.holds = false;
	leg.swap_pending = true;
	leg.pending_bank = false; // bank0 pending
	leg.disp_bank = true;
	leg.swap_req_seen = false;
	leg.cycle(/*vsync=*/true, /*ready=*/true, /*req_level=*/true, /*req_bank=*/true);
	const bool leg_lost = (!leg.swap_pending) && (leg.frames_done == 1) && (leg.pending_bank == true)
	                      && (leg.disp_bank == false);
	// Legacy: swapped to bank0 (old pending), pending_bank=bank1, but swap_pending cleared
	// → bank1 never displays without another doorbell edge that sets pending again.
	// Next vsync without new req: nothing to swap.
	leg.cycle(true, true, true, true); // same req level → no new_req
	const bool leg_stuck = (leg.frames_done == 1) && !leg.swap_pending;

	SwapSysNba fix;
	fix.holds = true;
	fix.swap_pending = true;
	fix.pending_bank = false;
	fix.disp_bank = true;
	fix.swap_req_seen = false;
	fix.cycle(true, true, true, true);
	const bool fix_keep = fix.swap_pending && (fix.frames_done == 1) && (fix.pending_bank == true)
	                      && (fix.disp_bank == false);
	// Next vsync with ready should swap bank1
	fix.cycle(true, true, true, true);
	const bool fix_second = (fix.frames_done == 2) && (fix.disp_bank == true);

	std::cout << "race legacy lost=" << leg_lost << " stuck=" << leg_stuck
	          << "  fix keep=" << fix_keep << " second_swap=" << fix_second << "\n";

	if (!(leg_lost && leg_stuck)) {
		std::cerr << "FAIL race model: legacy did not drop same-cycle pending\n";
		return 1;
	}
	if (!(fix_keep && fix_second)) {
		std::cerr << "FAIL race model: holds=1 did not retain pending across vsync\n";
		return 1;
	}
	std::cout << "PASS race model: holds=0 drops, holds=1 retains across vsync\n";
	return 0;
}

// --- Real RTL sustained sim -------------------------------------------------
constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 65536u;
constexpr uint32_t kDoorbellPhys = 0x3001F000u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kW = 80;
constexpr int kH = 48;
constexpr int kDispW = 64;
constexpr int kPresentX = 4;
constexpr int kActH = 40;
constexpr int kVBlank = 48;
constexpr int kYQ = kW / 8;
constexpr int kCQ = kW / 16;
constexpr int kUQBase = (kW * kH) / 8;
constexpr int kVQBase = kUQBase + (kW * kH) / 32;
constexpr int kHTotal = 160;
constexpr int kRdDelay = 3;
// Hundreds of display frames at playback-class present rate (every frame).
constexpr int kDisplayFrames = 240;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (8 * i);
	return q;
}

uint64_t mix(uint64_t h, uint64_t x) {
	return h ^ (x + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
}

struct Sim {
	Vddr_frame_store_scanout_sustained_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	int line_reads = 0;
	int presents = 0;

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

	void fillFrame(int bank, uint8_t yBase) {
		const uint32_t base = (bank * kBankStrideBytes) / 8;
		for (int line = 0; line < kH; ++line) {
			const uint8_t y = static_cast<uint8_t>(yBase + line * 5 + bank * 40);
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
		    (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
		++presents;
	}

	void serviceDdrStart() {
		if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT;
			rdIndex = 0;
			rdDelay = kRdDelay;
			busy = rdLeft + rdDelay + 2;
			if (rdAddr != (kDoorbellPhys >> 3))
				++line_reads;
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

	bool videoTick() {
		// Give prep time near end-of-frame (product path still must finish under pressure).
		const bool last_line = (vc == (kActH + kVBlank - 1));
		const bool pre_vsync = last_line && (hc == (kHTotal - 2));
		if (pre_vsync) {
			for (int spin = 0; spin < 8000; ++spin) {
				driveBeam(false);
				tick();
				if (!top.swap_pending)
					break;
				if (top.swap_pending && top.debug_pending_ready && top.debug_state_ddr == 0)
					break;
			}
			++hc;
		}
		const bool at_frame_start =
		    (hc == (kHTotal - 1)) && (vc == (kActH + kVBlank - 1));
		driveBeam(at_frame_start);
		tick();
		++hc;
		if (hc == kHTotal) {
			hc = 0;
			++vc;
			if (vc == kActH + kVBlank)
				vc = 0;
		}
		return at_frame_start;
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

struct Stats {
	int frames_done0 = 0;
	int frames_done1 = 0;
	int presents = 0;
	int stalled_vsyncs = 0; // swap_pending && !ready at vsync samples
	int max_swap_stall = 0;
	int swap_stall = 0;
	std::set<uint64_t> late_hashes;
	int late_frames = 0;
};

int run_rtl(const char* label, bool expect_pass, bool collide_on_vsync) {
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 1500; ++i)
		sim.tick();

	int bank = 0;
	uint32_t seq = 1;
	sim.fillFrame(bank, static_cast<uint8_t>(30 + seq));
	sim.ringDoorbell(bank, seq);

	for (int i = 0; i < 80000 && sim.top.frames_done < 1; ++i)
		sim.videoTick();
	if (sim.top.frames_done < 1) {
		std::cerr << "FAIL " << label << ": no first frames_done\n";
		return 1;
	}

	Stats st;
	st.frames_done0 = sim.top.frames_done;
	int swap_stall = 0;

	for (int f = 0; f < kDisplayFrames; ++f) {
		// Playback-class: present a new bank every display frame when free,
		// and optionally collide a fresh doorbell on the vsync edge (high-rate).
		if (!sim.top.swap_pending) {
			bank ^= 1;
			++seq;
			sim.fillFrame(bank, static_cast<uint8_t>(30 + seq * 3));
			sim.ringDoorbell(bank, seq);
			// Allow doorbell poll CDC a few lines of head-start.
			for (int i = 0; i < kHTotal / 2; ++i)
				sim.videoTick();
		} else if (collide_on_vsync) {
			// Overwrite pending while swap still outstanding — stresses hold path.
			bank ^= 1;
			++seq;
			sim.fillFrame(bank, static_cast<uint8_t>(30 + seq * 3));
			sim.ringDoorbell(bank, seq);
		}

		uint64_t hash = 0;
		int hit = 0;
		const int total = kHTotal * (kActH + kVBlank);
		for (int i = 0; i < total; ++i) {
			const int active = sim.top.rd_active;
			const bool vs = sim.videoTick();
			if (vs) {
				if (sim.top.swap_pending && !sim.top.debug_pending_ready) {
					++st.stalled_vsyncs;
					++swap_stall;
					if (swap_stall > st.max_swap_stall)
						st.max_swap_stall = swap_stall;
				} else {
					swap_stall = 0;
				}
			}
			if (active) {
				const int r = sim.top.rd_r, g = sim.top.rd_g, b = sim.top.rd_b;
				if ((r | g | b) != 0) {
					++hit;
					hash = mix(hash, (uint64_t(r) << 16) | (uint64_t(g) << 8) | b);
					hash = mix(hash, uint64_t(sim.top.rd_y));
				}
			}
		}
		if (f >= kDisplayFrames / 4) {
			st.late_hashes.insert(hash);
			++st.late_frames;
		}
		if ((f % 40) == 0) {
			std::cout << "raw " << label << " f=" << f
			          << " frames_done=" << sim.top.frames_done
			          << " presents=" << sim.presents
			          << " swap_pend=" << int(sim.top.swap_pending)
			          << " pend_rdy=" << int(sim.top.debug_pending_ready)
			          << " db=" << int(sim.top.debug_disp_bank)
			          << " pb=" << int(sim.top.debug_pending_bank)
			          << " hit=" << hit
			          << " hash=0x" << std::hex << hash << std::dec
			          << "\n";
		}
	}

	st.frames_done1 = sim.top.frames_done;
	st.presents = sim.presents;
	const int fd_delta = st.frames_done1 - st.frames_done0;
	const bool motion = st.late_hashes.size() >= 8;
	// Freeze class: frames_done barely advances vs presents, or late hashes collapse.
	const bool freeze = (fd_delta < (kDisplayFrames / 4)) || (st.late_hashes.size() <= 2)
	                    || (st.max_swap_stall >= 30);

	std::cout << "summary " << label
	          << " frames_done " << st.frames_done0 << "->" << st.frames_done1
	          << " fd_delta=" << fd_delta
	          << " presents=" << st.presents
	          << " late_hashes=" << st.late_hashes.size()
	          << " stalled_vsyncs=" << st.stalled_vsyncs
	          << " max_swap_stall=" << st.max_swap_stall
	          << " motion=" << motion
	          << " freeze=" << freeze
	          << " holds=" << int(sim.top.debug_holds_pending)
	          << " sticky=" << int(sim.top.debug_sticky_prep)
	          << " line_reads=" << sim.line_reads
	          << "\n";

	if (expect_pass) {
		if (freeze || !motion || fd_delta < (kDisplayFrames / 2)) {
			std::cerr << "FAIL " << label
			          << ": expected sustained motion under high-rate publish"
			          << " fd_delta=" << fd_delta
			          << " late_hashes=" << st.late_hashes.size()
			          << " max_swap_stall=" << st.max_swap_stall << "\n";
			return 1;
		}
		std::cout << "PASS " << label << ": sustained swaps+motion"
		          << " fd_delta=" << fd_delta
		          << " late_hashes=" << st.late_hashes.size() << "\n";
		return 0;
	}

	if (!freeze) {
		std::cerr << "FAIL " << label
		          << ": expected sustained freeze/lost-swap REPRO, looked alive"
		          << " fd_delta=" << fd_delta
		          << " late_hashes=" << st.late_hashes.size() << "\n";
		return 1;
	}
	std::cout << "REPRO_OK " << label << ": freeze-class under high-rate"
	          << " fd_delta=" << fd_delta
	          << " late_hashes=" << st.late_hashes.size()
	          << " max_swap_stall=" << st.max_swap_stall << "\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);

	if (run_race_model() != 0)
		return 1;

	Sim probe;
	probe.resetCore();
	const bool holds = probe.top.debug_holds_pending != 0;
	const bool sticky = probe.top.debug_sticky_prep != 0;
	const bool recycle = probe.top.debug_prep_recycle != 0;

	std::cout << "build: holds=" << holds << " sticky=" << sticky
	          << " recycle=" << recycle << "\n";

	// Broken build: sticky=0 recycle=0 under sustained high-rate → freeze (9eb1431a
	// class still hits when prep never holds ready across the 1-cycle vsync window).
	// Good build: sticky=1 recycle=1 holds=1 → sustained PASS at playback present rate.
	if (!sticky || !recycle) {
		return run_rtl("sustained_nosticky", /*expect_pass=*/false, /*collide=*/false);
	}
	if (!holds) {
		std::cerr << "FAIL: product sticky build expected holds=1 "
		          << "(SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC)\n";
		return 1;
	}
	// Respect free-bank (!swap_pending) presents every frame — playback rate.
	return run_rtl("sustained_product", /*expect_pass=*/true, /*collide=*/false);
}
