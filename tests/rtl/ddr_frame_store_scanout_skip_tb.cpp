// Post-present scanout SKIP identity gate (w-geom / glass +2 residual).
//
// Parent HW: 22 glass skips / 1429 source (1.54%, ~1/65) with daemon
//   frames-presents-drops identity closed, publish_misses=0 → ARM believes every
//   present landed in DDR. Question: can scanout fail to display a published frame?
//
// Prove-or-kill from RTL (quoted ddr_frame_store.sv):
//   - doorbell edge always latches pending_bank + swap_pending (no free check in RTL)
//   - free_bank_mask = 0 while swap_pending (PLXD ARM contract only)
//   - swap on vsync_pulse && swap_pending && pending_ready_s2
//   - SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC (product=1) retains pending across
//     same-cycle vsync+new doorbell; holds=0 clears pending (907e5950 class)
//
// Pre-register:
//   H1 beat: pure 1-cycle vsync∩doorbell coincidence at 24-in/60-out CANNOT make
//            1.54% (window too narrow) — kill as sole mechanism if math holds.
//   H2 free-gated product (ARM-like: doorbell only when !swap_pending): 0 identity
//      skips over long run on product holds=1 sticky=1.
//   H3 pending overwrite (doorbell while swap_pending): identity skip of the
//      displaced pending frame on product RTL — REPRO scanout skip class.
//   H4 holds=0 same-cycle: displaced/lost pending without second doorbell edge
//      (legacy) — skip or freeze class.
//
// Soft-skip never used. COMPILE FAIL is RED via run_verilator.sh.

#include "Vddr_frame_store_scanout_skip_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <set>
#include <string>
#include <vector>

namespace {

// --- H1: beat arithmetic (no DUT) ------------------------------------------
// Product display: parent glass soak uses 60 Hz class output; source frameRate=24.000.
// Capture 30 fps is parent instrument — not modeled here.
//
// Same-cycle collision: vsync_pulse is 1 sys-clk wide (colorbars frame_start).
// Publish edge becomes 1-cycle new_req after CDC (swap_req_s2 != swap_req_seen).
// Cycles per display frame in THIS TB geometry (matches product shape, not exact
// MiSTer pixel clock): HTotal * (ActH+VBlank).

constexpr int kHTotal = 160;
constexpr int kActH = 40;
constexpr int kVBlank = 48;
constexpr int kCycPerDisp = kHTotal * (kActH + kVBlank); // 14080
constexpr int kSrcFps = 24;
constexpr int kDispFps = 60;

struct BeatMath {
	double p_same_cycle_per_publish = 0;
	double expected_skip_frac_if_one_cycle = 0;
	double parent_skip_frac = 22.0 / 1429.0; // measured by parent, caller-supplied
	bool kills_one_cycle_beat = false;
};

BeatMath compute_beat() {
	BeatMath m;
	// If publish instant is phase-uniform over a display period, P(land on the
	// single vsync_pulse cycle) = 1 / cyc_per_disp per publish.
	m.p_same_cycle_per_publish = 1.0 / double(kCycPerDisp);
	// Even if EVERY same-cycle event skipped one published frame:
	m.expected_skip_frac_if_one_cycle = m.p_same_cycle_per_publish;
	// Parent 1.54% is ~217x larger than 1/14080.
	m.kills_one_cycle_beat = (m.expected_skip_frac_if_one_cycle * 50.0) < m.parent_skip_frac;
	return m;
}

int run_beat_math() {
	const BeatMath m = compute_beat();
	std::cout << "PRE-REGISTER H1 beat math (TB geometry; shape not pixel-clock exact):\n"
	          << "  cyc_per_disp=" << kCycPerDisp
	          << " src_fps=" << kSrcFps << " disp_fps=" << kDispFps << "\n"
	          << "  P(same_cycle|uniform_publish)=" << m.p_same_cycle_per_publish
	          << " expected_skip_frac_if_every_collide_skips="
	          << m.expected_skip_frac_if_one_cycle << "\n"
	          << "  parent_skip_frac_caller_supplied=" << m.parent_skip_frac
	          << " ratio_parent/one_cycle="
	          << (m.parent_skip_frac / m.expected_skip_frac_if_one_cycle) << "\n"
	          << "  kills_one_cycle_beat_as_sole_cause=" << m.kills_one_cycle_beat << "\n";
	if (!m.kills_one_cycle_beat) {
		std::cerr << "FAIL H1: one-cycle beat not ruled out by arithmetic\n";
		return 1;
	}
	// 24/60 exact beat period = 2 source frames = 5 display frames (phase lattice),
	// not 65. 1/65 is NOT the 24-vs-60 rational beat.
	const bool beat_2_5 = (2 * kDispFps == 5 * kSrcFps);
	std::cout << "  rational_beat_2src_per_5disp=" << beat_2_5
	          << " (1/65 is NOT this lattice)\n";
	if (!beat_2_5) {
		std::cerr << "FAIL H1: 24/60 lattice check broken\n";
		return 1;
	}
	std::cout << "PASS H1: pure 1-cycle vsync∩doorbell cannot explain 1.54%; "
	          << "1/65 ≠ 24/60 lattice\n";
	return 0;
}

// --- Pure double-buffer identity model (no DUT) ----------------------------
// Models only swap_pending / pending_bank / disp_bank / free contract.
struct BufModel {
	bool holds = true;
	bool swap_pending = false;
	bool pending_bank = false;
	bool disp_bank = false;
	bool req_level = false;
	bool req_seen = false;
	int frames_done = 0;
	int bank_seq[2] = {-1, -1};
	std::vector<int> published;
	std::vector<int> swapped; // seq that became disp on each frames_done++

	void cycle(bool vsync, bool ready, bool do_req, bool req_bank, int seq) {
		const bool seen0 = req_seen;
		const bool pend0 = pending_bank;
		const bool sp0 = swap_pending;
		bool new_req = false;
		if (do_req) {
			req_level = !req_level;
			new_req = (req_level != seen0);
			bank_seq[req_bank ? 1 : 0] = seq;
			published.push_back(seq);
		} else {
			new_req = false;
		}

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
			disp1 = pend0;
			swapped.push_back(bank_seq[pend0 ? 1 : 0]);
			fd1 += 1;
			if (holds && new_req)
				sp1 = true;
			else
				sp1 = false;
		}
		req_seen = seen1;
		pending_bank = pend1;
		swap_pending = sp1;
		disp_bank = disp1;
		frames_done = fd1;
	}

	// free contract mirrors PLXD: free_mask=0 while pending
	bool any_free() const { return !swap_pending; }
	int free_bank() const {
		if (swap_pending)
			return -1;
		return disp_bank ? 0 : 1;
	}
};

int count_never_swapped(const BufModel& m) {
	std::set<int> got(m.swapped.begin(), m.swapped.end());
	int never = 0;
	// Last publish may still be pending or on display without a further swap of a
	// later frame — count only publishes that are not last-in-flight.
	for (size_t i = 0; i + 1 < m.published.size(); ++i) {
		if (!got.count(m.published[i]))
			++never;
	}
	return never;
}

int run_pure_identity() {
	std::cout << "PRE-REGISTER pure identity model:\n"
	          << "  free_gated holds=1 @24-in/60-out → never_swapped==0\n"
	          << "  overwrite_while_pending holds=1 → never_swapped>0\n"
	          << "  holds=0 same-cycle new_req → never_swapped>0 or stuck\n";

	// --- free-gated 24/60 ---
	BufModel fg;
	fg.holds = true;
	int seq = 0;
	// seed first frame
	fg.cycle(false, true, true, /*bank*/1, ++seq);
	for (int d = 0; d < 600; ++d) {
		const bool vs = true;
		const bool ready = true;
		// publish cadence: floor targets
		const int target = ((d + 1) * kSrcFps) / kDispFps;
		if (static_cast<int>(fg.published.size()) < target && fg.any_free()) {
			const int b = fg.free_bank();
			fg.cycle(vs, ready, true, b != 0, ++seq);
		} else {
			fg.cycle(vs, ready, false, false, 0);
		}
	}
	// drain a few vsyncs
	for (int i = 0; i < 10; ++i)
		fg.cycle(true, true, false, false, 0);
	const int fg_never = count_never_swapped(fg);
	std::cout << "pure free_gated pubs=" << fg.published.size()
	          << " swaps=" << fg.swapped.size()
	          << " never_swapped=" << fg_never << "\n";

	// --- overwrite while pending ---
	BufModel ow;
	ow.holds = true;
	seq = 0;
	ow.cycle(false, true, true, 1, ++seq); // pend bank1
	// before swap, overwrite with bank0 (ARM would need stale free — model hostile)
	ow.cycle(false, true, true, 0, ++seq);
	ow.cycle(true, true, false, false, 0); // swap once → shows seq2, seq1 never
	for (int i = 0; i < 5; ++i)
		ow.cycle(true, true, false, false, 0);
	const int ow_never = count_never_swapped(ow);
	std::cout << "pure overwrite pubs=" << ow.published.size()
	          << " swaps=" << ow.swapped.size()
	          << " never_swapped=" << ow_never << "\n";

	// --- holds=0 same-cycle ---
	BufModel leg;
	leg.holds = false;
	seq = 0;
	leg.swap_pending = true;
	leg.pending_bank = false;
	leg.bank_seq[0] = ++seq; // seq1 pending bank0
	leg.published.push_back(seq);
	leg.disp_bank = true;
	// same-cycle vsync swap + new req bank1 seq2
	leg.cycle(true, true, true, true, ++seq);
	// no new edge; next vsync cannot swap (swap_pending cleared)
	leg.cycle(true, true, false, false, 0);
	// third publish sets pending again — seq2 was in pending_bank but may never have swapped
	const int leg_never = count_never_swapped(leg);
	const bool leg_stuck = (leg.frames_done == 1) && !leg.swap_pending && (leg.pending_bank == true);
	std::cout << "pure holds0 samecycle fd=" << leg.frames_done
	          << " sp=" << leg.swap_pending << " never_swapped=" << leg_never
	          << " stuck_pending_no_sp=" << leg_stuck << "\n";

	if (fg_never != 0) {
		std::cerr << "FAIL pure free_gated: unexpected never_swapped=" << fg_never << "\n";
		return 1;
	}
	if (ow_never <= 0) {
		std::cerr << "FAIL pure overwrite: expected identity skip\n";
		return 1;
	}
	if (!(leg_stuck || leg_never > 0)) {
		std::cerr << "FAIL pure holds0: expected lost pending class\n";
		return 1;
	}
	std::cout << "PASS pure identity: free_gated clean; overwrite+holds0 skip class\n";
	return 0;
}

// --- Real RTL identity sim -------------------------------------------------
constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 65536u;
constexpr uint32_t kDoorbellPhys = 0x3001F000u;
constexpr uint32_t kMagic = 0x504C584Bu;
constexpr int kW = 80;
constexpr int kH = 48;
constexpr int kDispW = 64;
constexpr int kPresentX = 4;
constexpr int kYQ = kW / 8;
constexpr int kCQ = kW / 16;
constexpr int kUQBase = (kW * kH) / 8;
constexpr int kVQBase = kUQBase + (kW * kH) / 32;
constexpr int kRdDelay = 3;
constexpr int kDisplayFrames = 300; // 5 s at 60 Hz class

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
	Vddr_frame_store_scanout_skip_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	int presents = 0;
	int bank_seq[2] = {-1, -1};
	std::vector<int> published;
	std::vector<int> swapped_on_fd;

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
			const uint8_t y = yBase; // solid identity
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
		bank_seq[bank & 1] = static_cast<int>(seq);
		published.push_back(static_cast<int>(seq));
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

	void noteFdEdge(uint16_t& prev_fd) {
		const uint16_t fd = top.frames_done;
		if (fd != prev_fd) {
			// disp_bank already updated to the bank that just became visible
			const int b = top.debug_disp_bank ? 1 : 0;
			swapped_on_fd.push_back(bank_seq[b]);
			prev_fd = fd;
		}
	}
};

enum class Mode {
	FreeGated24,     // product ARM contract
	OverwritePending, // hostile: doorbell while swap_pending
	Holds0Collide     // legacy holds + collide on vsync
};

struct RunResult {
	int presents = 0;
	int fd_delta = 0;
	int never_swapped = 0;
	int glass_plus2 = 0; // adjacent display samples where source seq jumps by >=2
	int display_samples = 0;
	bool holds = false;
};

RunResult run_rtl(const char* label, Mode mode) {
	Sim sim;
	sim.resetCore();
	for (int i = 0; i < 1500; ++i)
		sim.tick();

	int bank = 0;
	uint32_t seq = 1;
	sim.fillFrame(bank, static_cast<uint8_t>(40 + seq));
	sim.ringDoorbell(bank, seq);

	for (int i = 0; i < 80000 && sim.top.frames_done < 1; ++i)
		sim.videoTick();

	RunResult rr;
	rr.holds = sim.top.debug_holds_pending != 0;
	if (sim.top.frames_done < 1) {
		std::cerr << "FAIL " << label << ": no first frames_done\n";
		rr.never_swapped = 9999;
		return rr;
	}

	uint16_t prev_fd = sim.top.frames_done;
	// Record first swap identity
	sim.swapped_on_fd.push_back(sim.bank_seq[sim.top.debug_disp_bank ? 1 : 0]);
	const int fd0 = sim.top.frames_done;
	int last_disp_seq = sim.swapped_on_fd.back();
	int pubs_target_base = static_cast<int>(sim.published.size());

	int overwrites = 0;
	int samecycle_collides = 0;

	for (int f = 0; f < kDisplayFrames; ++f) {
		const int target = pubs_target_base + ((f + 1) * kSrcFps) / kDispFps;

		if (mode == Mode::FreeGated24) {
			if (static_cast<int>(sim.published.size()) < target && !sim.top.swap_pending) {
				bank ^= 1;
				++seq;
				sim.fillFrame(bank, static_cast<uint8_t>(40 + (seq % 200)));
				sim.ringDoorbell(bank, seq);
				for (int i = 0; i < kHTotal / 2; ++i) {
					sim.videoTick();
					sim.noteFdEdge(prev_fd);
				}
			}
		} else if (mode == Mode::OverwritePending) {
			// Hostile ARM: free-gated first present, then second doorbell WHILE
			// swap_pending still high (RTL has no free check — pending_bank moves).
			if (static_cast<int>(sim.published.size()) < target && !sim.top.swap_pending) {
				bank ^= 1;
				++seq;
				const int first_seq = static_cast<int>(seq);
				sim.fillFrame(bank, static_cast<uint8_t>(40 + (seq % 200)));
				sim.ringDoorbell(bank, seq);
				// Spin until doorbell CDC accepts (swap_pending rises).
				bool accepted = false;
				for (int i = 0; i < kHTotal * 4; ++i) {
					sim.videoTick();
					sim.noteFdEdge(prev_fd);
					if (sim.top.swap_pending) {
						accepted = true;
						break;
					}
				}
				// Every 3rd accepted present: overwrite pending with other bank.
				if (accepted && (overwrites < 40) && ((first_seq % 3) == 0)) {
					bank ^= 1;
					++seq;
					sim.fillFrame(bank, static_cast<uint8_t>(40 + (seq % 200)));
					sim.ringDoorbell(bank, seq);
					++overwrites;
					for (int i = 0; i < kHTotal / 2; ++i) {
						sim.videoTick();
						sim.noteFdEdge(prev_fd);
					}
				}
			}
		} else { // Holds0Collide — force new doorbell on the vsync_pulse cycle
			if (static_cast<int>(sim.published.size()) < target && !sim.top.swap_pending) {
				bank ^= 1;
				++seq;
				sim.fillFrame(bank, static_cast<uint8_t>(40 + (seq % 200)));
				sim.ringDoorbell(bank, seq);
				for (int i = 0; i < kHTotal * 4 && !sim.top.swap_pending; ++i) {
					sim.videoTick();
					sim.noteFdEdge(prev_fd);
				}
			}
			// Advance to just before frame_start vsync, then collide doorbell+vsync.
			if (sim.top.swap_pending && (f % 4) == 0 && samecycle_collides < 50) {
				const int total_pre = kHTotal * (kActH + kVBlank) - 2;
				for (int i = 0; i < total_pre; ++i) {
					(void)sim.videoTick();
					sim.noteFdEdge(prev_fd);
				}
				// One tick before vsync_pulse: plant new doorbell token in mem.
				bank ^= 1;
				++seq;
				sim.fillFrame(bank, static_cast<uint8_t>(40 + (seq % 200)));
				sim.ringDoorbell(bank, seq);
				++samecycle_collides;
				// Next two videoTicks include the vsync_pulse edge window.
				for (int i = 0; i < 4; ++i) {
					(void)sim.videoTick();
					sim.noteFdEdge(prev_fd);
				}
				// Remainder of this display frame already consumed — skip bulk loop.
				const int b = sim.top.debug_disp_bank ? 1 : 0;
				const int cur = sim.bank_seq[b];
				if (rr.display_samples > 0 && cur >= 0 && last_disp_seq >= 0) {
					const int delta = cur - last_disp_seq;
					if (delta >= 2)
						++rr.glass_plus2;
				}
				if (cur >= 0)
					last_disp_seq = cur;
				++rr.display_samples;
				if ((f % 60) == 0) {
					std::cout << "raw " << label << " f=" << f
					          << " fd=" << sim.top.frames_done
					          << " presents=" << sim.presents
					          << " sp=" << int(sim.top.swap_pending)
					          << " collides=" << samecycle_collides
					          << " never_pending_track=" << sim.swapped_on_fd.size()
					          << "\n";
				}
				continue; // next f
			}
		}

		const int total = kHTotal * (kActH + kVBlank);
		for (int i = 0; i < total; ++i) {
			(void)sim.videoTick();
			sim.noteFdEdge(prev_fd);
		}

		// Glass-style adjacent sample: one sample per display frame of current
		// disp bank identity (seq last written to that bank).
		const int b = sim.top.debug_disp_bank ? 1 : 0;
		const int cur = sim.bank_seq[b];
		if (rr.display_samples > 0 && cur >= 0 && last_disp_seq >= 0) {
			const int delta = cur - last_disp_seq;
			if (delta >= 2)
				++rr.glass_plus2;
		}
		if (cur >= 0)
			last_disp_seq = cur;
		++rr.display_samples;

		if ((f % 60) == 0) {
			std::cout << "raw " << label << " f=" << f
			          << " fd=" << sim.top.frames_done
			          << " presents=" << sim.presents
			          << " sp=" << int(sim.top.swap_pending)
			          << " db=" << int(sim.top.debug_disp_bank)
			          << " pb=" << int(sim.top.debug_pending_bank)
			          << " pubs=" << sim.published.size()
			          << " swaps_tracked=" << sim.swapped_on_fd.size()
			          << "\n";
		}
	}

	// Drain pending
	for (int f = 0; f < 30; ++f) {
		const int total = kHTotal * (kActH + kVBlank);
		for (int i = 0; i < total; ++i) {
			(void)sim.videoTick();
			sim.noteFdEdge(prev_fd);
		}
	}

	rr.presents = sim.presents;
	rr.fd_delta = int(sim.top.frames_done) - fd0;

	std::set<int> got;
	for (int s : sim.swapped_on_fd) {
		if (s >= 0)
			got.insert(s);
	}
	// Count published identities never observed on a frames_done edge, excluding
	// the final in-flight publish if still pending at end.
	for (size_t i = 0; i < sim.published.size(); ++i) {
		const int s = sim.published[i];
		if (got.count(s))
			continue;
		// allow last published still pending
		if (i + 1 == sim.published.size() && sim.top.swap_pending)
			continue;
		// allow last published already on display without a later swap edge after fill
		if (i + 1 == sim.published.size())
			continue;
		++rr.never_swapped;
	}

	std::cout << "summary " << label
	          << " holds=" << rr.holds
	          << " presents=" << rr.presents
	          << " fd_delta=" << rr.fd_delta
	          << " never_swapped=" << rr.never_swapped
	          << " glass_plus2=" << rr.glass_plus2
	          << " display_samples=" << rr.display_samples
	          << " swapped_n=" << sim.swapped_on_fd.size()
	          << " overwrites=" << overwrites
	          << " samecycle_collides=" << samecycle_collides
	          << "\n";
	return rr;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);

	int rc = 0;
	if (run_beat_math() != 0)
		rc = 1;
	if (run_pure_identity() != 0)
		rc = 1;

	const char* mode_env = std::getenv("SKIP_TB_MODE");
	const std::string mode = mode_env ? mode_env : "product";

	if (mode == "product" || mode == "all") {
		std::cout << "build: holds=" << "runtime"
		          << " mode=FreeGated24+OverwritePending\n";
		// Free-gated must be clean on product DUT (holds baked at compile).
		const RunResult fg = run_rtl("rtl_free_gated_24in60", Mode::FreeGated24);
		if (fg.never_swapped != 0 || fg.glass_plus2 != 0) {
			std::cerr << "FAIL rtl_free_gated: never_swapped=" << fg.never_swapped
			          << " glass_plus2=" << fg.glass_plus2 << "\n";
			rc = 1;
		} else {
			std::cout << "PASS rtl_free_gated_24in60: never_swapped=0 glass_plus2=0 "
			          << "presents=" << fg.presents << "\n";
		}

		// Overwrite must REPRO identity skip on the SAME product DUT.
		const RunResult ow = run_rtl("rtl_overwrite_pending", Mode::OverwritePending);
		if (ow.never_swapped <= 0 && ow.glass_plus2 <= 0) {
			std::cerr << "FAIL rtl_overwrite: expected skip REPRO, got never="
			          << ow.never_swapped << " glass_plus2=" << ow.glass_plus2 << "\n";
			rc = 1;
		} else {
			std::cout << "REPRO_OK rtl_overwrite_pending: never_swapped="
			          << ow.never_swapped << " glass_plus2=" << ow.glass_plus2
			          << " (scanout CAN skip if doorbell while pending)\n";
		}
	}

	if (mode == "holds0" || mode == "all") {
		// 907e5950 same-cycle lost-pending is scored by pure identity (stuck_pending)
		// above and by tests/unit/test_ddr_frame_store_scanout_sustained.sh freeze
		// REPRO. This holds=0 DUT still must REPRO the overwrite skip class — RTL
		// accepts doorbell while swap_pending regardless of HOLDS.
		const RunResult ow = run_rtl("rtl_holds0_overwrite", Mode::OverwritePending);
		if (ow.never_swapped <= 0 && ow.glass_plus2 <= 0) {
			std::cerr << "FAIL rtl_holds0_overwrite: expected skip REPRO\n";
			rc = 1;
		} else {
			std::cout << "REPRO_OK rtl_holds0_collide: overwrite never_swapped="
			          << ow.never_swapped << " glass_plus2=" << ow.glass_plus2
			          << " (holds=0 DUT; pure model covers same-cycle lost-pending)\n";
		}
	}

	if (rc == 0)
		std::cout << "OK ddr_frame_store_scanout_skip: TB executed all scored paths\n";
	return rc;
}
