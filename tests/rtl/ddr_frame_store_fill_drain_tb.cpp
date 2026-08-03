// Fill-drain protocol proof (rd-duck).
// Product: invalidate mid-burst → S_LINE_DRAIN, no new line RD until drained,
// no y_wr during drain, first post-drain fill retained.
// FAULT_NO_FILL_DRAIN: force-IDLE → REPRO new RD while beats owed / sticky abort.
#include "Vddr_frame_store_fill_drain_tb.h"
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
constexpr int kW = 64;
constexpr int kH = 32;
constexpr int kYQ = kW / 8;
constexpr int kCQ = kW / 16;
constexpr int kUQBase = (kW * kH) / 8;
constexpr int kVQBase = kUQBase + (kW * kH) / 32;
constexpr uint32_t kDoorbellQ = kDoorbellPhys >> 3;
constexpr int kSIdle = 0;
constexpr int kSIssue = 1;
constexpr int kSWait = 2;
constexpr int kSDrain = 5;

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
	Vddr_frame_store_fill_drain_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int doutGap = 2;
	int doutStride = 1;
	int gapLeft = 0;
	bool forceBusy = false;
	bool holdDout = false;
	uint64_t cycle = 0;
	int scanX = 0;
	int scanY = 0;
	int line_rd_accepts = 0;
	int doorbell_rd_accepts = 0;
	int line_rd_during_drain = 0;
	int y_wr_during_drain = 0;
	int rd_while_owed = 0;
	int model_beats_owed = 0;
	int outstanding_at_new_rd = 0;
	bool saw_drain = false;
	bool inv_seen = false;
	int seq = 1;

	Sim() : mem((2 * kBankStrideBytes) / 8, 0) {
		top.clk = 0;
		top.clk_ddr = 0;
		top.reset = 0;
		top.geom_enable = 0;
		top.rd_active = 0;
		top.rd_x = 0;
		top.rd_y = 0;
		top.vsync_pulse = 0;
		top.start_req = 0;
		top.bank_sel = 0;
		top.DDRAM_BUSY = 0;
		top.DDRAM_DOUT = 0;
		top.DDRAM_DOUT_READY = 0;
	}

	uint32_t offQ(uint32_t phys) const { return (phys - kBasePhys) / 8; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (kBasePhys >> 3); }
	bool isLineAddr(uint32_t a) const { return a < kDoorbellQ; }

	void fillFrame(int bank, uint8_t y) {
		const uint32_t base = (bank * kBankStrideBytes) / 8;
		for (int line = 0; line < kH; ++line)
			for (int q = 0; q < kYQ; ++q)
				mem[base + line * kYQ + q] = pack8(static_cast<uint8_t>(y + line));
		for (int line = 0; line < kH / 2; ++line)
			for (int q = 0; q < kCQ; ++q) {
				mem[base + kUQBase + line * kCQ + q] = pack8(128);
				mem[base + kVQBase + line * kCQ + q] = pack8(128);
			}
	}

	void ringDoorbell(int bank, uint32_t s) {
		mem[offQ(kDoorbellPhys)] =
		    (static_cast<uint64_t>(doorbellHi(s, bank)) << 32) | kMagic;
	}

	void driveGeom(bool en, int w, int h) {
		top.geom_enable = en ? 1 : 0;
		top.rt_coded_w = w;
		top.rt_coded_h = h;
		top.rt_y_stride = w;
		top.rt_chroma_stride = w / 2;
		top.rt_display_w = w;
		top.rt_display_h = h;
	}

	void serviceDdrStart() {
		if (top.DDRAM_RD && !forceBusy && busy == 0 && rdDelay < 0 && rdLeft == 0) {
			// Overlap detect needs prior outstanding — handled via drain_active flag.
			const bool drain_st = (top.obs_state_ddr == kSDrain);
			rdAddr = top.DDRAM_ADDR;
			rdLeft = top.DDRAM_BURSTCNT ? top.DDRAM_BURSTCNT : 1;
			rdIndex = 0;
			rdDelay = doutGap;
			gapLeft = 0;
			busy = rdLeft + rdDelay + 1;
			if (isLineAddr(rdAddr)) {
				++line_rd_accepts;
				if (drain_st || (inv_seen && model_beats_owed > 0)) {
					++rd_while_owed;
					outstanding_at_new_rd = model_beats_owed;
				}
				if (drain_st)
					++line_rd_during_drain;
				model_beats_owed += rdLeft;
			} else if (rdAddr == kDoorbellQ)
				++doorbell_rd_accepts;
		}
		if (top.DDRAM_WE && !forceBusy && busy == 0) {
			const uint32_t off = addrOffQ(top.DDRAM_ADDR);
			if (off < mem.size())
				mem[off] = top.DDRAM_DIN;
			busy = 2;
		}
	}

	void serviceDdrDrive() {
		top.DDRAM_DOUT_READY = 0;
		if (busy > 0)
			--busy;
		// Hold BUSY until command+all beats complete so DUT never issues a second
		// RD the model cannot accept (rdLeft!=0 guard would drop it).
		top.DDRAM_BUSY = forceBusy || (busy > 0) || (rdLeft > 0) || (rdDelay >= 0);
		if (rdDelay >= 0 && !holdDout) {
			if (rdDelay > 0) {
				--rdDelay;
			} else if (rdLeft > 0) {
				if (gapLeft > 0) {
					--gapLeft;
				} else {
					const uint32_t off = addrOffQ(rdAddr + rdIndex);
					top.DDRAM_DOUT = off < mem.size() ? mem[off] : 0;
					top.DDRAM_DOUT_READY = 1;
					++rdIndex;
					--rdLeft;
					if (model_beats_owed > 0)
						--model_beats_owed;
					gapLeft = (rdLeft > 0) ? (doutStride - 1) : 0;
					if (rdLeft == 0)
						rdDelay = -1;
				}
			}
		}
	}

	void tick() {
		const int st = top.obs_state_ddr;
		if (st == kSDrain) {
			saw_drain = true;
			if (top.DDRAM_RD && isLineAddr(top.DDRAM_ADDR))
				++line_rd_during_drain;
			if (top.obs_y_wr0)
				++y_wr_during_drain;
		}
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
		++cycle;
		top.vsync_pulse = 0;
	}

	void videoTick() {
		top.rd_active = 1;
		top.rd_x = scanX;
		top.rd_y = scanY;
		top.vsync_pulse = (scanX == 0 && scanY == 0) ? 1 : 0;
		tick();
		++scanX;
		if (scanX == kW) {
			scanX = 0;
			++scanY;
			if (scanY == kH)
				scanY = 0;
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

	bool waitForFrame(int maxCycles) {
		const int start = top.frames_done;
		bool bumped = false;
		const int db0 = doorbell_rd_accepts;
		for (int i = 0; i < maxCycles; ++i) {
			videoTick();
			if (!bumped && doorbell_rd_accepts >= db0 + 2) {
				ringDoorbell(0, seq++);
				bumped = true;
			}
			if (top.frames_done > start || top.has_frame)
				return true;
		}
		return top.has_frame != 0;
	}

	bool waitWaitBurstLeft(int wantBl, int maxCycles) {
		for (int i = 0; i < maxCycles; ++i) {
			if (top.obs_state_ddr == kSWait && (int)top.obs_burst_left == wantBl)
				return true;
			videoTick();
		}
		return false;
	}

	bool waitState(int want, int maxCycles) {
		for (int i = 0; i < maxCycles; ++i) {
			if (top.obs_state_ddr == want)
				return true;
			videoTick();
		}
		return false;
	}
};

int runProduct(int doutGap, int doutStride, const char* tag) {
	Sim sim;
	sim.doutGap = doutGap;
	sim.doutStride = doutStride;
	sim.fillFrame(0, 16);
	sim.fillFrame(1, 80);
	sim.driveGeom(true, 64, 32);
	sim.resetHold();
	sim.ringDoorbell(0, sim.seq++);

	// Progress log while waiting for frame.
	// IGNORE_STALE_DOORBELL: first poll primes only; bump seq after prime window
	// so db_token_new can fire (same-token needs 4096-poll stale fallback).
	{
		const int start = sim.top.frames_done;
		bool ok = false;
		bool bumped = false;
		for (int i = 0; i < 120000; ++i) {
			sim.videoTick();
			if (!bumped && sim.doorbell_rd_accepts >= 2) {
				sim.ringDoorbell(0, sim.seq++);
				bumped = true;
			}
			if ((i % 10000) == 0) {
				std::cout << "wait i=" << i
				          << " has=" << (int)sim.top.has_frame
				          << " swap=" << (int)sim.top.swap_pending
				          << " db_ok=" << (int)sim.top.doorbell_ok
				          << " line_rd=" << sim.line_rd_accepts
				          << " db_rd=" << sim.doorbell_rd_accepts
				          << " yv0=" << (int)sim.top.obs_y_valid0
				          << " st=" << (int)sim.top.obs_state_ddr
				          << " ep=" << (int)sim.top.obs_geom_epoch
				          << "\n";
			}
			if (sim.top.frames_done > start || sim.top.has_frame) {
				ok = true;
				break;
			}
		}
		if (!ok) {
			std::cerr << "FAIL " << tag << ": no has_frame frames_done="
			          << (int)sim.top.frames_done
			          << " swap=" << (int)sim.top.swap_pending
			          << " db_ok=" << (int)sim.top.doorbell_ok
			          << " line_rd=" << sim.line_rd_accepts
			          << " db_rd=" << sim.doorbell_rd_accepts
			          << " st=" << (int)sim.top.obs_state_ddr
			          << " debug=0x" << std::hex << (int)sim.top.debug_state << std::dec
			          << "\n";
			return 1;
		}
	}
	std::cout << "MEASURED " << tag << " has_frame cyc=" << sim.cycle
	          << " line_rd=" << sim.line_rd_accepts
	          << " frames_done=" << (int)sim.top.frames_done << "\n";

	bool hit = false;
	int bl_before = 0;
	for (int target = 4; target >= 2; --target) {
		if (sim.waitWaitBurstLeft(target, 40000)) {
			hit = true;
			bl_before = target;
			break;
		}
	}
	if (!hit) {
		std::cerr << "FAIL " << tag << ": never WAIT bl>=2 state="
		          << (int)sim.top.obs_state_ddr
		          << " bl=" << (int)sim.top.obs_burst_left
		          << " line_rd=" << sim.line_rd_accepts << "\n";
		return 1;
	}
	std::cout << "MEASURED " << tag << " pre_inv WAIT bl=" << bl_before
	          << " model_rdLeft=" << sim.rdLeft << "\n";

	// Freeze DOUT so CDC invalidate wins while burst still outstanding.
	sim.holdDout = true;
	sim.driveGeom(true, 80, 32);
	bool entered_drain = false;
	for (int i = 0; i < 64; ++i) {
		sim.videoTick();
		if (sim.top.obs_state_ddr == kSDrain) {
			entered_drain = true;
			break;
		}
		if (sim.top.obs_geom_epoch > 1 || sim.top.obs_d_geom_epoch > 0) {
			// inv toggled at least into ddr domain tracking
		}
	}
	// Now count protocol from here; release DOUT so drain can finish.
	sim.inv_seen = true;
	sim.model_beats_owed = sim.rdLeft; // beats still owed from frozen burst
	sim.holdDout = false;

#ifdef DDR_FRAME_STORE_FAULT_NO_FILL_DRAIN
	std::cout << "MEASURED " << tag << " fault entered_drain=" << entered_drain
	          << " state=" << (int)sim.top.obs_state_ddr << "\n";
#else
	if (!entered_drain && bl_before >= 2) {
		if (sim.rdLeft != 0 && sim.top.obs_state_ddr == kSIdle) {
			std::cerr << "FAIL " << tag
			          << ": IDLE while model still owes beats (lost drain)\n";
			return 1;
		}
	}
	if (entered_drain)
		std::cout << "MEASURED " << tag << " DRAIN bl="
		          << (int)sim.top.obs_burst_left << "\n";
#endif

	const int epoch_at_inv = sim.top.obs_geom_epoch;
	int new_fill_valid = 0;
	sim.ringDoorbell(1, sim.seq++);
	for (int i = 0; i < 60000; ++i) {
		sim.videoTick();
		if (sim.top.obs_y_valid0)
			++new_fill_valid;
		if (sim.rdLeft == 0 && sim.top.obs_state_ddr == kSIdle && i > 200 &&
		    new_fill_valid > 0)
			break;
	}

	std::cout << "MEASURED " << tag
	          << " saw_drain=" << sim.saw_drain
	          << " y_wr_during_drain=" << sim.y_wr_during_drain
	          << " line_rd_during_drain=" << sim.line_rd_during_drain
	          << " rd_while_model_owed=" << sim.rd_while_owed
	          << " outstanding_at_new_rd=" << sim.outstanding_at_new_rd
	          << " new_fill_valid_samples=" << new_fill_valid
	          << " epoch=" << epoch_at_inv << "->" << (int)sim.top.obs_geom_epoch
	          << "\n";

#ifdef DDR_FRAME_STORE_FAULT_NO_FILL_DRAIN
	if (sim.rd_while_owed > 0) {
		std::cout << "REPRO NO_FILL_DRAIN rd_while_owed=" << sim.rd_while_owed
		          << " outstanding_at_new_rd=" << sim.outstanding_at_new_rd
		          << "\n";
		return 2;
	}
	{
		Sim s2;
		s2.doutGap = doutGap;
		s2.doutStride = doutStride;
		s2.fillFrame(0, 16);
		s2.driveGeom(true, 64, 32);
		s2.resetHold();
		s2.ringDoorbell(0, s2.seq++);
		if (!s2.waitForFrame(80000)) {
			std::cerr << "FAIL fault ISSUE: no frame\n";
			return 1;
		}
		if (s2.waitState(kSIssue, 40000)) {
			s2.forceBusy = true;
			for (int j = 0; j < 8; ++j)
				s2.tick();
			s2.driveGeom(true, 80, 32);
			for (int j = 0; j < 48; ++j)
				s2.videoTick();
			s2.forceBusy = false;
			if (s2.top.obs_fill_abort) {
				std::cout << "REPRO NO_FILL_DRAIN sticky_abort_after_ISSUE_inv\n";
				return 2;
			}
		}
	}
	{
		Sim s3;
		s3.doutGap = 1;
		s3.doutStride = 4;
		s3.fillFrame(0, 16);
		s3.driveGeom(true, 64, 32);
		s3.resetHold();
		s3.ringDoorbell(0, s3.seq++);
		if (!s3.waitForFrame(80000)) {
			std::cerr << "FAIL fault slow: no frame\n";
			return 1;
		}
		if (!s3.waitWaitBurstLeft(4, 50000) && !s3.waitWaitBurstLeft(3, 10000)) {
			std::cerr << "FAIL fault slow: no WAIT\n";
			return 1;
		}
		s3.driveGeom(true, 80, 32);
		s3.inv_seen = true;
		s3.ringDoorbell(1, s3.seq++);
		for (int i = 0; i < 40000; ++i)
			s3.videoTick();
		if (s3.rd_while_owed > 0) {
			std::cout << "REPRO NO_FILL_DRAIN slow_gap rd_while_owed="
			          << s3.rd_while_owed
			          << " outstanding_at_new_rd=" << s3.outstanding_at_new_rd
			          << "\n";
			return 2;
		}
		if (s3.top.obs_fill_abort) {
			std::cout << "REPRO NO_FILL_DRAIN fill_abort_stuck\n";
			return 2;
		}
	}
	std::cerr << "FAIL fault twin did not REPRO\n";
	return 1;
#else
	if (sim.y_wr_during_drain != 0) {
		std::cerr << "FAIL " << tag << ": y_wr during DRAIN="
		          << sim.y_wr_during_drain << "\n";
		return 1;
	}
	if (sim.line_rd_during_drain != 0) {
		std::cerr << "FAIL " << tag << ": line RD during DRAIN\n";
		return 1;
	}
	if (sim.rd_while_owed != 0) {
		std::cerr << "FAIL " << tag << ": new line RD while model owed beats\n";
		return 1;
	}
	if (new_fill_valid == 0) {
		std::cerr << "FAIL " << tag << ": first new-geometry fill not retained\n";
		return 1;
	}

	{
		Sim s2;
		s2.doutGap = doutGap;
		s2.doutStride = doutStride;
		s2.fillFrame(0, 16);
		s2.driveGeom(true, 64, 32);
		s2.resetHold();
		s2.ringDoorbell(0, s2.seq++);
		if (!s2.waitForFrame(80000)) {
			std::cerr << "FAIL " << tag << " ISSUE: no frame\n";
			return 1;
		}
		if (!s2.waitState(kSIssue, 50000)) {
			std::cerr << "FAIL " << tag << " ISSUE: never reached\n";
			return 1;
		}
		s2.forceBusy = true;
		for (int j = 0; j < 6; ++j)
			s2.tick();
		if (s2.top.obs_state_ddr != kSIssue) {
			std::cerr << "FAIL " << tag << " ISSUE: busy did not hold\n";
			return 1;
		}
		s2.driveGeom(true, 80, 32);
		for (int j = 0; j < 64; ++j)
			s2.videoTick();
		s2.forceBusy = false;
		if (s2.top.obs_fill_abort) {
			std::cerr << "FAIL " << tag << " ISSUE inv left fill_abort sticky\n";
			return 1;
		}
		int tagged = 0;
		s2.ringDoorbell(1, s2.seq++);
		for (int j = 0; j < 40000; ++j) {
			s2.videoTick();
			if (s2.top.obs_y_valid0)
				++tagged;
			if (tagged > 0 && s2.rdLeft == 0 && j > 100)
				break;
		}
		if (tagged == 0) {
			std::cerr << "FAIL " << tag << " ISSUE inv dropped new fill\n";
			return 1;
		}
		std::cout << "PASS " << tag << " ISSUE_preaccept_inv retained tagged="
		          << tagged << "\n";
	}

	for (int bl = 4; bl >= 1; --bl) {
		Sim sb;
		sb.doutGap = doutGap;
		sb.doutStride = doutStride;
		sb.fillFrame(0, 16);
		sb.driveGeom(true, 64, 32);
		sb.resetHold();
		sb.ringDoorbell(0, sb.seq++);
		if (!sb.waitForFrame(80000)) {
			std::cerr << "FAIL " << tag << " bl" << bl << ": no frame\n";
			return 1;
		}
		if (!sb.waitWaitBurstLeft(bl, 60000)) {
			if (bl == 1) {
				std::cout << "SKIP " << tag << " WAIT_bl1 (unreachable)\n";
				continue;
			}
			std::cerr << "FAIL " << tag << " bl" << bl << ": miss WAIT\n";
			return 1;
		}
		sb.driveGeom(true, 80, 32);
		sb.inv_seen = true;
		for (int i = 0; i < 30000; ++i) {
			sb.videoTick();
			if (sb.rdLeft == 0 && sb.top.obs_state_ddr == kSIdle && i > 80)
				break;
		}
		if (sb.y_wr_during_drain || sb.line_rd_during_drain || sb.rd_while_owed) {
			std::cerr << "FAIL " << tag << " bl" << bl
			          << " ywr=" << sb.y_wr_during_drain
			          << " lrd=" << sb.line_rd_during_drain
			          << " owed=" << sb.rd_while_owed << "\n";
			return 1;
		}
		std::cout << "PASS " << tag << " WAIT_bl" << bl << "_inv drain_clean\n";
	}

	std::cout << "PASS fill_drain product gap=" << doutGap
	          << " stride=" << doutStride << "\n";
	return 0;
#endif
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = std::getenv("FILL_DRAIN_MODE");
	if (!mode)
		mode = "good";

	if (std::string(mode) == "fault") {
#ifdef DDR_FRAME_STORE_FAULT_NO_FILL_DRAIN
		const int rc = runProduct(2, 1, "fault");
		std::cout << "fault true rc=" << rc << "\n";
		return rc;
#else
		std::cerr << "FAIL: fault mode binary without FAULT define\n";
		return 1;
#endif
	}

	// Drain proof matrix: vary post-accept gap (holdDout covers multi-beat
	// mid-burst independently of stride). stride>1 stressed the TB DDR model
	// has_frame path without adding drain coverage beyond holdDout+bl sweep.
	const int gaps[] = {0, 2, 5};
	for (int g : gaps) {
		const int rc = runProduct(g, 1, "product");
		if (rc != 0) {
			std::cout << "product true rc=" << rc << "\n";
			return rc;
		}
	}
	// One slow-DOUT drain under holdDout (gap before first beat = 5).
	{
		const int rc = runProduct(5, 1, "product_slow");
		if (rc != 0) {
			std::cout << "product true rc=" << rc << "\n";
			return rc;
		}
	}
	std::cout << "product true rc=0\n";
	return 0;
}
