// PLXD unconditional first-publish gate (parent HW: 0x3007F128 stayed 0).
//
// Scenario D: reset → release → many cycles, NEVER ring PLXK doorbell.
// PASS only if a write hits BANK_MAILBOX_PHYS=0x3007F128 with MAGIC_D and
// free_bank_mask != 0 (ARM can learn a writable bank without a prior frame).
//
// Negatives a wrong impl fails:
//   - magic missing / free_mask==0 while !swap_pending
//   - write only after a doorbell (this TB never rings one)
//   - write to doorbell-relative 0x300FF128 instead of the BANK param under test

#include "Vddr_frame_store_plxd_init_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <iostream>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kPlxdPhysMain = 0x3007F128u;   // main BANK_MAILBOX_PHYS
constexpr uint32_t kPlxdPhysDoorbellRel = 0x300FF128u; // product tip slot
constexpr uint32_t kMagicD = 0x504C5844u;
constexpr int kCycles = 200000; // >> 2^18 heartbeat and poll_div

struct Plxd {
	bool seen = false;
	uint8_t free_mask = 0;
	uint8_t disp = 0;
	bool swap_pending = false;
	uint16_t frames_done = 0;
};

Plxd decode(uint64_t w) {
	Plxd s;
	s.seen = (static_cast<uint32_t>(w & 0xffffffffu) == kMagicD);
	s.free_mask = static_cast<uint8_t>((w >> 32) & 0x3u);
	s.disp = static_cast<uint8_t>((w >> 34) & 0x1u);
	s.swap_pending = ((w >> 35) & 0x1u) != 0;
	s.frames_done = static_cast<uint16_t>((w >> 48) & 0xffffu);
	return s;
}

struct Sim {
	Vddr_frame_store_plxd_init_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int plxd_main_writes = 0;
	int plxd_rel_writes = 0;
	int any_we = 0;
	Plxd last_main{};
	int vs_div = 0;

	Sim() : mem((0x200000) / 8, 0) {
		top.clk = 0;
		top.clk_ddr = 0;
		top.reset = 1;
		top.vsync_pulse = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;
	}

	uint32_t addrOffQ(uint32_t addr29) const {
		// DDRAM_ADDR is phys[31:3]
		return addr29 - (kBasePhys >> 3);
	}

	void service() {
		if (top.DDRAM_RD && busy == 0 && rdDelay < 0 && rdLeft == 0) {
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			rdIndex = 0;
			rdDelay = 2;
			busy = rdLeft + rdDelay + 2;
		}
		if (top.DDRAM_WE && busy == 0) {
			++any_we;
			const uint32_t off = addrOffQ(top.DDRAM_ADDR);
			if (off < mem.size())
				mem[off] = top.DDRAM_DIN;
			if (top.DDRAM_ADDR == (kPlxdPhysMain >> 3)) {
				const Plxd s = decode(top.DDRAM_DIN);
				if (s.seen) {
					++plxd_main_writes;
					last_main = s;
				}
			}
			if (top.DDRAM_ADDR == (kPlxdPhysDoorbellRel >> 3)) {
				const Plxd s = decode(top.DDRAM_DIN);
				if (s.seen)
					++plxd_rel_writes;
			}
			busy = 3;
		}
	}

	void driveDdr() {
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;
		top.DDRAM_BUSY = (busy > 0);
		if (rdDelay >= 0) {
			if (rdDelay > 0) {
				--rdDelay;
			} else if (rdLeft > 0) {
				const uint32_t off = addrOffQ(rdAddr + rdIndex);
				// Doorbell page empty (no PLXK) — core must still publish PLXD.
				top.DDRAM_DOUT = (off < mem.size()) ? mem[off] : 0;
				top.DDRAM_DOUT_READY = 1;
				++rdIndex;
				--rdLeft;
				if (rdLeft == 0)
					rdDelay = -1;
			}
		}
	}

	void tick(bool release_reset) {
		if (release_reset)
			top.reset = 0;
		// Occasional vsync so vsync_toggle path can also arm bank_mbox_req.
		// Not required if heartbeat alone works; still not a doorbell.
		++vs_div;
		top.vsync_pulse = (vs_div % 4000 == 0) ? 1 : 0;

		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		driveDdr();
		top.clk = 1;
		top.clk_ddr = 1;
		top.eval();
		service();
		top.clk = 0;
		top.clk_ddr = 0;
		top.eval();
		top.vsync_pulse = 0;
	}
};

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	std::cout << "PRE-REGISTER was: FAIL on main if no unconditional PLXD publish; "
	             "PASS requires write @ 0x3007F128 magic+free!=0 with zero doorbells\n";

	Sim sim;
	for (int i = 0; i < 64; ++i)
		sim.tick(false); // hold reset
	for (int i = 0; i < kCycles; ++i)
		sim.tick(true);

	std::cout << "summary plxd_init: cycles=" << kCycles
	          << " any_we=" << sim.any_we
	          << " plxd_main_wr=" << sim.plxd_main_writes
	          << " plxd_rel_wr=" << sim.plxd_rel_writes
	          << " last_free=" << int(sim.last_main.free_mask)
	          << " last_disp=" << int(sim.last_main.disp)
	          << " last_sp=" << int(sim.last_main.swap_pending)
	          << " last_fd=" << sim.last_main.frames_done
	          << " has_frame=" << int(sim.top.has_frame)
	          << "\n";

	// Negative: must not require a doorbell — we never wrote PLXK.
	if (sim.plxd_main_writes == 0) {
		std::cerr << "FAIL plxd_init: no PLXD write at 0x3007F128 after reset "
		             "(unconditional first-publish missing — parent HW class)\n";
		if (sim.plxd_rel_writes > 0) {
			std::cerr << "NOTE: saw " << sim.plxd_rel_writes
			          << " PLXD writes at 0x300FF128 instead (address desync path)\n";
		}
		return 1;
	}

	if (!sim.last_main.seen) {
		std::cerr << "FAIL plxd_init: PLXD write without MAGIC_D\n";
		return 1;
	}

	// Idle after reset: disp=0, !swap → free_mask must be 0b10 (bank1 free).
	if (sim.last_main.swap_pending) {
		std::cerr << "FAIL plxd_init: unexpected swap_pending with no doorbell\n";
		return 1;
	}
	if (sim.last_main.free_mask == 0) {
		std::cerr << "FAIL plxd_init: free_bank_mask=0 with no swap — ARM cannot pick a bank\n";
		return 1;
	}
	if (sim.last_main.free_mask != 0x2u || sim.last_main.disp != 0) {
		std::cerr << "FAIL plxd_init: expected disp=0 free=0x2 got disp="
		          << int(sim.last_main.disp) << " free=" << int(sim.last_main.free_mask) << "\n";
		return 1;
	}
	if (sim.top.has_frame) {
		std::cerr << "FAIL plxd_init: has_frame set without doorbell (false frame)\n";
		return 1;
	}

	std::cout << "PASS plxd_init: unconditional PLXD @ 0x3007F128 writes="
	          << sim.plxd_main_writes << " free_mask=" << int(sim.last_main.free_mask) << "\n";
	return 0;
}
