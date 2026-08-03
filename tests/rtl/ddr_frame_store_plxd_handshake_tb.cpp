// RTL-half DDR handshake gate: PLXK consume + PLXD bank-release under
// sustained back-to-back doorbells (playback-class rate).
//
// Parent hypothesis: if PLXD stops advancing, ARM rewrites the same bank →
// presents climb, HDMI pinned. This TB proves or kills the RTL half.
//
// Quoted ddr_frame_store.sv contracts under test:
//   - db_new_seq / swap_req_t_ddr toggle on new PLXK token (no doorbell ACK write)
//   - PLXD pack at BANK_MAILBOX: free=00 iff swap_pending else ~disp
//   - frames_done is real swap counter (not vsync-only)
//   - bank_mbox_req on vsync edge, swap/disp change, heartbeat
//
// Pre-register:
//   sticky=0: after warm-up, frames_done stalls, last PLXD free_mask=00 +
//             swap_pending=1  → REPRO handshake stall (scanout freeze class)
//   product sticky+recycle: PLXD keeps writing; frames_done tracks rings;
//             free_mask honest when !swap_pending → PASS (PLXD-stop killed)

#include "Vddr_frame_store_plxd_handshake_tb.h"
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
constexpr uint32_t kPlxdPhys = 0x3001F128u;
constexpr uint32_t kMagicK = 0x504C584Bu; // PLXK
constexpr uint32_t kMagicD = 0x504C5844u; // PLXD
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
constexpr int kDisplayFrames = 200;

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) | (1u << 29) | (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (8 * i);
	return q;
}

struct PlxdSample {
	uint16_t frames_done = 0;
	uint8_t free_mask = 0;
	uint8_t disp_bank = 0;
	bool swap_pending = false;
	bool magic_ok = false;
};

PlxdSample decodePlxd(uint64_t w) {
	PlxdSample s;
	s.magic_ok = (static_cast<uint32_t>(w & 0xffffffffu) == kMagicD);
	s.free_mask = static_cast<uint8_t>((w >> 32) & 0x3u);
	s.disp_bank = static_cast<uint8_t>((w >> 34) & 0x1u);
	s.swap_pending = ((w >> 35) & 0x1u) != 0;
	s.frames_done = static_cast<uint16_t>((w >> 48) & 0xffffu);
	return s;
}

// --- Pure protocol model (no DUT): doorbell consume + PLXD pack ------------
struct HandshakeModel {
	// Doorbell side
	uint32_t last_token = 0;
	bool have_seq = false;
	bool swap_req_level = false;
	// Scanout
	bool swap_pending = false;
	bool pending_bank = false;
	bool disp_bank = false;
	bool pending_ready = true; // model product sticky
	uint16_t frames_done = 0;
	// PLXD snapshot (updated on events, not continuous)
	PlxdSample plxd{};
	int plxd_writes = 0;

	void packPlxd() {
		plxd.magic_ok = true;
		plxd.frames_done = frames_done;
		plxd.swap_pending = swap_pending;
		plxd.disp_bank = disp_bank ? 1 : 0;
		// RTL: swap_pending_d2 ? 2'b00 : (disp_bank_d2 ? 2'b01 : 2'b10)
		if (swap_pending)
			plxd.free_mask = 0;
		else
			plxd.free_mask = disp_bank ? 0x1u : 0x2u;
		++plxd_writes;
	}

	// db_new_seq: new token only (same token ignored until stale fallback).
	// No write-back to doorbell — ARM must change token for next ring.
	bool ring(uint32_t token, int bank) {
		if (have_seq && token == last_token)
			return false; // same token: no consume
		last_token = token;
		have_seq = true;
		pending_bank = (bank & 1) != 0;
		swap_req_level = !swap_req_level;
		swap_pending = true;
		// PLXD NOT updated on doorbell edge (matches RTL bank_mbox_req sources).
		return true;
	}

	void vsync() {
		if (swap_pending && pending_ready) {
			disp_bank = pending_bank;
			swap_pending = false;
			frames_done = static_cast<uint16_t>(frames_done + 1u);
		}
		packPlxd(); // vsync edge → bank_mbox_req
	}
};

int run_protocol_model() {
	std::cout << "PRE-REGISTER protocol model:\n"
	          << "  same PLXK token twice → second ignored (no consume ack)\n"
	          << "  free_mask=00 while swap_pending; ~disp when free\n"
	          << "  PLXD pack on vsync, not on doorbell edge\n";

	HandshakeModel m;
	// First ring bank0
	if (!m.ring(0x100u, 0)) {
		std::cerr << "FAIL model: first ring rejected\n";
		return 1;
	}
	if (!(m.swap_pending && m.plxd_writes == 0)) {
		std::cerr << "FAIL model: doorbell must not pack PLXD\n";
		return 1;
	}
	// Same token again — ignored
	if (m.ring(0x100u, 1)) {
		std::cerr << "FAIL model: same token must not re-consume\n";
		return 1;
	}
	m.vsync();
	if (!(m.frames_done == 1 && !m.swap_pending && m.plxd.free_mask == 0x2u
	      && m.plxd.disp_bank == 0)) {
		std::cerr << "FAIL model: after swap0 free should be bank1 mask=0x2 "
		          << "fd=" << m.frames_done << " free=" << int(m.plxd.free_mask)
		          << " disp=" << int(m.plxd.disp_bank) << "\n";
		return 1;
	}
	// Back-to-back: ring bank1, swap_pending → free 00 on next pack
	if (!m.ring(0x101u, 1)) {
		std::cerr << "FAIL model: second distinct token rejected\n";
		return 1;
	}
	m.packPlxd(); // model ownership edge refresh
	if (!(m.plxd.swap_pending && m.plxd.free_mask == 0)) {
		std::cerr << "FAIL model: swap_pending must force free_mask=00\n";
		return 1;
	}
	// If pending never becomes ready, free stays 00 and frames_done stalls
	m.pending_ready = false;
	const uint16_t fd0 = m.frames_done;
	m.vsync();
	m.vsync();
	if (!(m.frames_done == fd0 && m.swap_pending && m.plxd.free_mask == 0)) {
		std::cerr << "FAIL model: not-ready must stall frames_done + free=00\n";
		return 1;
	}
	std::cout << "PASS protocol model: token-edge consume, free=00 while pending, "
	             "stall when !ready\n";
	return 0;
}

// --- Real RTL ---------------------------------------------------------------
struct Sim {
	Vddr_frame_store_plxd_handshake_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	int presents = 0;
	int plxd_writes = 0;
	int plxd_writes_late = 0;
	std::vector<PlxdSample> plxd_log;
	PlxdSample last_plxd{};

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
		    (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagicK;
		++presents;
	}

	void notePlxdWrite(uint64_t din) {
		const PlxdSample s = decodePlxd(din);
		if (!s.magic_ok)
			return;
		++plxd_writes;
		last_plxd = s;
		plxd_log.push_back(s);
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
			if (top.DDRAM_ADDR == (kPlxdPhys >> 3))
				notePlxdWrite(top.DDRAM_DIN);
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
		const bool last_line = (vc == (kActH + kVBlank - 1));
		const bool pre_vsync = last_line && (hc == (kHTotal - 2));
		if (pre_vsync) {
			for (int spin = 0; spin < 8000; ++spin) {
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

int run_rtl(const char* label, bool expect_pass, bool sticky, bool recycle) {
	std::cout << "build: sticky=" << sticky << " recycle=" << recycle
	          << " label=" << label << "\n";

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
		std::cerr << "FAIL " << label << ": never got first swap\n";
		return 1;
	}

	const uint16_t fd_start = sim.top.frames_done;
	const int plxd_at_start = sim.plxd_writes;
	int rings_while_pending = 0;

	for (int f = 0; f < kDisplayFrames; ++f) {
		if (!sim.top.swap_pending) {
			bank ^= 1;
			++seq;
			sim.fillFrame(bank, static_cast<uint8_t>(30 + seq * 3));
			sim.ringDoorbell(bank, seq);
			for (int i = 0; i < kHTotal / 2; ++i)
				sim.videoTick();
		} else if ((f % 17) == 0) {
			// Back-to-back new token while pending (overwrites pending_bank).
			bank ^= 1;
			++seq;
			sim.fillFrame(bank, static_cast<uint8_t>(90 + seq));
			sim.ringDoorbell(bank, seq);
			++rings_while_pending;
		}

		const int total = kHTotal * (kActH + kVBlank);
		for (int i = 0; i < total; ++i)
			(void)sim.videoTick();

		if (f >= 40)
			sim.plxd_writes_late = sim.plxd_writes - plxd_at_start;
		if ((f % 40) == 0) {
			std::cout << "raw " << label << " f=" << f
			          << " fd=" << sim.top.frames_done
			          << " presents=" << sim.presents
			          << " plxd_wr=" << sim.plxd_writes
			          << " sp=" << int(sim.top.swap_pending)
			          << " last_free=" << int(sim.last_plxd.free_mask)
			          << " last_fd=" << sim.last_plxd.frames_done
			          << " last_sp=" << int(sim.last_plxd.swap_pending)
			          << "\n";
		}
	}

	const uint16_t fd_end = sim.top.frames_done;
	const int fd_delta = int(fd_end) - int(fd_start);
	const bool plxd_live = sim.plxd_writes > 10 && sim.last_plxd.magic_ok;
	uint16_t fd_mid = 0;
	if (sim.plxd_log.size() > 20)
		fd_mid = sim.plxd_log[sim.plxd_log.size() / 2].frames_done;
	const int late_fd_delta = int(sim.last_plxd.frames_done) - int(fd_mid);
	const bool fd_stalled =
	    (fd_delta < 5) || (sim.plxd_log.size() > 30 && late_fd_delta < 2);
	// Live scanout stall (sticky=0 class): frames_done frozen with swap_pending.
	const bool live_swap_stall = fd_stalled && (sim.top.swap_pending != 0);
	// PLXD snapshot can lag: last written word shows !swap_pending/free!=0 while
	// live swap_pending=1 (bank_mbox loses to continuous refill when
	// bank_mbox_valid && poll_div!=160). That is the ARM-visible stale-free class.
	const bool plxd_stale_vs_live =
	    live_swap_stall &&
	    (!sim.last_plxd.swap_pending || sim.last_plxd.free_mask != 0);
	const bool free_stuck_zero =
	    sim.last_plxd.swap_pending && sim.last_plxd.free_mask == 0 && fd_stalled;

	int free_ok = 0, free_bad = 0, free_zero_idle = 0;
	for (const auto& s : sim.plxd_log) {
		if (s.swap_pending) {
			if (s.free_mask != 0)
				++free_bad;
		} else {
			const uint8_t expect = s.disp_bank ? 0x1u : 0x2u;
			if (s.free_mask == 0)
				++free_zero_idle;
			else if (s.free_mask == expect)
				++free_ok;
			else
				++free_bad;
		}
	}

	std::cout << "summary " << label
	          << " fd_delta=" << fd_delta
	          << " presents=" << sim.presents
	          << " plxd_writes=" << sim.plxd_writes
	          << " late_plxd=" << sim.plxd_writes_late
	          << " rings_while_pending=" << rings_while_pending
	          << " free_ok=" << free_ok << " free_bad=" << free_bad
	          << " free_zero_idle=" << free_zero_idle
	          << " fd_stalled=" << fd_stalled
	          << " live_swap_stall=" << live_swap_stall
	          << " plxd_stale_vs_live=" << plxd_stale_vs_live
	          << " free_stuck_zero=" << free_stuck_zero
	          << " live_sp=" << int(sim.top.swap_pending)
	          << " last_free=" << int(sim.last_plxd.free_mask)
	          << " last_sp=" << int(sim.last_plxd.swap_pending)
	          << " last_fd=" << sim.last_plxd.frames_done
	          << "\n";

	if (!plxd_live) {
		std::cerr << "FAIL " << label << ": PLXD never written (magic live)\n";
		return 1;
	}

	if (expect_pass) {
		if (fd_stalled || live_swap_stall) {
			std::cerr << "FAIL " << label
			          << ": product PLXD/handshake stalled under back-to-back rings\n";
			return 1;
		}
		if (free_ok < 5) {
			std::cerr << "FAIL " << label << ": too few honest free_mask samples\n";
			return 1;
		}
		if (free_bad > free_ok / 2) {
			std::cerr << "FAIL " << label << ": free_mask packing frequently wrong\n";
			return 1;
		}
		if (sim.plxd_writes_late < 5) {
			std::cerr << "FAIL " << label << ": PLXD write starved late window\n";
			return 1;
		}
		std::cout << "PASS " << label
		          << ": PLXD live+advancing free honest fd_delta=" << fd_delta
		          << " plxd_writes=" << sim.plxd_writes << "\n";
		return 0;
	}

	// Broken: frames_done stall with live swap_pending. Often accompanied by
	// stale PLXD (last free!=00 while live pending) — ARM would see a free bank.
	if (!(live_swap_stall || free_stuck_zero)) {
		std::cerr << "FAIL " << label
		          << ": expected handshake stall REPRO (fd stall + live swap_pending)\n";
		return 1;
	}
	// If PLXD packs bank_vsync_count, last_fd keeps climbing while swaps freeze —
	// ARM liveness cannot detect the stall (c5382bee class). Require field stall.
	if (int(sim.last_plxd.frames_done) - int(fd_start) > 5) {
		std::cerr << "FAIL " << label
		          << ": PLXD frames_done field advanced while swaps stalled "
		          << "(likely packing vsync, not real frames_done)\n";
		return 1;
	}
	std::cout << "REPRO_OK " << label
	          << ": handshake stall free_mask=00-or-stale frames_done frozen "
	          << "fd_delta=" << fd_delta << " plxd_writes=" << sim.plxd_writes
	          << " plxd_stale_vs_live=" << plxd_stale_vs_live << "\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	if (run_protocol_model() != 0)
		return 1;

	Vddr_frame_store_plxd_handshake_tb probe{};
	probe.eval();
	const bool sticky = probe.debug_sticky_prep != 0;
	const bool recycle = probe.debug_prep_recycle != 0;

	if (!sticky || !recycle)
		return run_rtl("plxd_nosticky", /*expect_pass=*/false, sticky, recycle);
	return run_rtl("plxd_product", /*expect_pass=*/true, sticky, recycle);
}
