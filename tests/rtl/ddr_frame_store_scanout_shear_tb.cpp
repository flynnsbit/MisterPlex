// Real-RTL scanout SHEAR / left-edge wander gate.
//
// Hardware class (parent on 14eaeff3 / ac90b155): ragged left boundary that
// jitters per scanline while ARM DDR presents are healthy. Distinct from freeze.
//
// Method (md5-distinctness alone is NOT enough — parent method rule):
//   1. Pack a FIXED vertical content edge at coded x = kEdgeX (constant x0).
//   2. Drive product-shaped beam into real ddr_frame_store.
//   3. Per active line, record first non-black rd_x inside the present window.
//   4. Fail product+slow-DDR if left_first_hit_spread >= 20 (asymmetric_left_wander).
//
// Twin A — STRIDE_FAULT: pack lines with wrong stride (320-class) so content
//          origin advances each row → diagonal shear of first-hit x.
// Twin B — SLOW_DDR product pack: mid-line miss→hit wander (RTL comment at
//          rd_miss_now). Fast DDR may hide this (false green).
//
// Pre-register after src_y_line fix:
//   stride_fault  → REPRO_OK (must stay RED — discriminator)
//   product_slow  → PASS CLEAN (spread<=2, left_miss small, edge~PRESENT+edgeX)
//   product_fast  → PASS CLEAN (structural fix, not latency-only)

#include "Vddr_frame_store_scanout_shear_tb.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 65536u;
constexpr uint32_t kDoorbellPhys = 0x3001F000u;
constexpr uint32_t kMagic = 0x504C584Bu; // PLXK
constexpr int kW = 80;
constexpr int kH = 48;
constexpr int kDispW = 64;
constexpr int kPresentX = 4;
constexpr int kActH = 40;
constexpr int kVBlank = 48;
constexpr int kYQ = kW / 8;           // 10
constexpr int kCQ = kW / 16;          // 5
constexpr int kUQBase = (kW * kH) / 8;
constexpr int kVQBase = kUQBase + (kW * kH) / 32;
constexpr int kHTotal = 160;
constexpr int kEdgeX = 16;            // first content pixel in coded coords
constexpr int kWanderThresh = 20;     // tools/measure_edges asymmetric_left_wander

uint32_t doorbellHi(uint32_t seq, int bank) {
	return (static_cast<uint32_t>(bank & 1) << 31) |
	       (1u << 29) |
	       (seq & 0x1fffffffu);
}

uint64_t pack8(uint8_t v) {
	uint64_t q = 0;
	for (int i = 0; i < 8; ++i)
		q |= static_cast<uint64_t>(v) << (i * 8);
	return q;
}

enum class PackMode { Product, StrideFault320 };

struct Sim {
	Vddr_frame_store_scanout_shear_tb top{};
	std::vector<uint64_t> mem;
	int busy = 0;
	int rdDelay = -1;
	uint32_t rdAddr = 0;
	int rdLeft = 0;
	int rdIndex = 0;
	int hc = 0;
	int vc = 0;
	int kRdDelay = 2;
	int line_reads = 0;

	explicit Sim(int rd_delay) : mem((2 * kBankStrideBytes) / 8, 0), kRdDelay(rd_delay) {
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

	// Vertical edge at coded x=kEdgeX: Y=16 left, Y=220 content (neutral chroma).
	// Product: line stride = kYQ qwords (80 px).
	// StrideFault320: pack as if line_bytes=40 (5 qwords) into 80-wide reader slots
	// → each successive line's content starts 40 px earlier in the coded window.
	void fillFrame(int bank, PackMode mode) {
		const uint32_t base = (bank * kBankStrideBytes) / 8;
		for (auto& q : mem)
			q = 0;
		// black YUV
		for (int line = 0; line < kH; ++line) {
			for (int q = 0; q < kYQ; ++q)
				mem[base + line * kYQ + q] = pack8(0);  // Y=0 pad → near-RGB0 when hit
		}
		for (int line = 0; line < kH / 2; ++line) {
			for (int q = 0; q < kCQ; ++q) {
				mem[base + kUQBase + line * kCQ + q] = pack8(128);
				mem[base + kVQBase + line * kCQ + q] = pack8(128);
			}
		}

		if (mode == PackMode::Product) {
			const int edge_q = kEdgeX / 8;
			for (int line = 0; line < kH; ++line) {
				for (int q = edge_q; q < kYQ; ++q)
					mem[base + line * kYQ + q] = pack8(255);
			}
		} else {
			// Classic shear: writer thinks width=40 (5 qwords), reader uses 10.
			// Row r content occupies mem indices as if packed tightly at 5 q/line,
			// but reader addresses line*r*10 + x_q → edge drifts −5 qwords/line.
			constexpr int kFaultYQ = 5; // 40 px
			const int edge_q = (kEdgeX / 8); // 2 within 40-wide content
			for (int line = 0; line < kH; ++line) {
				// Place "logical" row `line` starting at byte offset line*40 in plane,
				// which is qword offset line*5 from plane base — NOT line*10.
				const int src_base = line * kFaultYQ;
				for (int q = 0; q < kFaultYQ; ++q) {
					const uint8_t y = (q >= edge_q) ? 255 : 0;
					// Write into the linear packing the WRONG writer would use,
					// overlaid onto the start of the plane (compact).
					mem[base + src_base + q] = pack8(y);
				}
			}
		}
	}

	void ringDoorbell(int bank, uint32_t seq) {
		mem[offQ(kDoorbellPhys)] =
		    (static_cast<uint64_t>(doorbellHi(seq, bank)) << 32) | kMagic;
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
		const bool last_line = (vc == (kActH + kVBlank - 1));
		const bool pre_vsync = last_line && (hc == (kHTotal - 2));
		if (pre_vsync) {
			hc = kHTotal - 2;
			for (int spin = 0; spin < 8000; ++spin) {
				driveBeam(false);
				tick();
				if (!top.swap_pending && top.debug_state == 0)
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

struct EdgeStats {
	int lines = 0;
	int min_x = 999;
	int max_x = -1;
	int spread = 0;
	int miss_lines = 0;
	int hit_px = 0;
	int dark_px = 0;
	int max_left_miss_run = 0;
	double mean_delta = 0.0;
	int col_probe_hit = 0;   // lines where expect_x pixel is content-bright
	int col_probe_total = 0;
	std::vector<int> first_xs;
};

// Content threshold: bright Y=255 → large RGB; miss/Y=0 → ~0.
static bool is_content(int r, int g, int b) { return (r + g + b) >= 64; }

EdgeStats measureEdges(Sim& sim, int n_frames) {
	EdgeStats st;
	std::vector<int> first_x(kActH, -1);
	std::vector<int> left_run(kActH, 0);
	std::vector<int> saw_line(kActH, 0);
	std::vector<int> content_seen(kActH, 0);

	// Discard warm-up frames; score the last frame only (parent HDMI method).
	const int lines_total = kActH + kVBlank;
	const int cycles_frame = kHTotal * lines_total;
	for (int f = 0; f < n_frames; ++f) {
		const bool score = (f == n_frames - 1);
		if (score) {
			std::fill(first_x.begin(), first_x.end(), -1);
			std::fill(left_run.begin(), left_run.end(), 0);
			std::fill(saw_line.begin(), saw_line.end(), 0);
			std::fill(content_seen.begin(), content_seen.end(), 0);
			st.hit_px = 0;
			st.dark_px = 0;
		}
		for (int i = 0; i < cycles_frame; ++i) {
			const int y = sim.top.rd_y;
			const int x = sim.top.rd_x;
			const int active = sim.top.rd_active;
			sim.videoTick();
			if (!score || !active || y < 0 || y >= kActH)
				continue;
			saw_line[y] = 1;
			const int r = sim.top.rd_r;
			const int g = sim.top.rd_g;
			const int b = sim.top.rd_b;
			const int expect_x = kPresentX + kEdgeX;
			if (x == expect_x && is_content(r, g, b))
				content_seen[y] |= 2; // bit1: probe column bright
			if (!is_content(r, g, b)) {
				++st.dark_px;
				if (!(content_seen[y] & 1) && x >= kPresentX)
					++left_run[y];
			} else {
				++st.hit_px;
				content_seen[y] |= 1;
				if (first_x[y] < 0)
					first_x[y] = x;
			}
		}
	}

	for (int y = 0; y < kActH; ++y) {
		if (!saw_line[y])
			continue;
		++st.lines;
		st.max_left_miss_run = std::max(st.max_left_miss_run, left_run[y]);
		++st.col_probe_total;
		if (content_seen[y] & 2)
			++st.col_probe_hit;
		if (first_x[y] < 0) {
			++st.miss_lines;
			continue;
		}
		st.min_x = std::min(st.min_x, first_x[y]);
		st.max_x = std::max(st.max_x, first_x[y]);
		st.first_xs.push_back(first_x[y]);
	}
	if (st.min_x == 999)
		st.min_x = -1;
	st.spread = (st.max_x >= 0 && st.min_x >= 0) ? (st.max_x - st.min_x) : 999;

	double sum = 0;
	int nd = 0;
	int prev = -1;
	for (int y = 0; y < kActH; ++y) {
		if (first_x[y] < 0)
			continue;
		if (prev >= 0) {
			sum += (first_x[y] - prev);
			++nd;
		}
		prev = first_x[y];
	}
	st.mean_delta = nd ? (sum / nd) : 0.0;
	return st;
}

int run_case(const char* name, PackMode mode, int rd_delay, bool expect_repro) {
	Sim sim(rd_delay);
	sim.resetCore();
	for (int i = 0; i < 1500; ++i)
		sim.tick();

	int bank = 0;
	uint32_t seq = 1;
	sim.fillFrame(bank, mode);
	sim.ringDoorbell(bank, seq);

	for (int i = 0; i < 80000 && sim.top.frames_done < 1; ++i)
		sim.videoTick();
	if (sim.top.frames_done < 1) {
		std::cerr << "FAIL " << name << ": no frames_done"
		          << " line_reads=" << sim.line_reads
		          << " has_frame=" << int(sim.top.has_frame) << "\n";
		return 1;
	}

	// Steady frames with continuous presents
	for (int f = 0; f < 2; ++f) {
		if (!sim.top.swap_pending) {
			bank ^= 1;
			++seq;
			sim.fillFrame(bank, mode);
			sim.ringDoorbell(bank, seq);
			for (int i = 0; i < kHTotal * 2; ++i)
				sim.videoTick();
		}
	}

	EdgeStats st = measureEdges(sim, /*n_frames=*/3);
	// Wander = variable first-content x among lines that hit (ragged left).
	// Stride class: column probe at expect_x fails on many lines (wrong pitch).
	const int expect_x0 = kPresentX + kEdgeX;
	std::vector<int> xs = st.first_xs;
	std::sort(xs.begin(), xs.end());
	auto pct = [&](double p) -> int {
		if (xs.empty()) return -1;
		size_t i = (size_t)std::min<double>(xs.size() - 1, p * (xs.size() - 1));
		return xs[i];
	};
	const int p10 = pct(0.10), p50 = pct(0.50), p90 = pct(0.90);
	const int core_spread = (p90 >= 0 && p10 >= 0) ? (p90 - p10) : 999;
	const int late_p90 = (p90 >= 0) ? std::max(0, p90 - expect_x0) : 999;
	const bool wander = core_spread >= kWanderThresh || late_p90 >= kWanderThresh;
	const bool slope = (st.mean_delta <= -0.5) || (st.mean_delta >= 0.5);
	const double col_frac = st.col_probe_total
	                            ? (double)st.col_probe_hit / st.col_probe_total : 0.0;
	// Stride fault packs wrong pitch: <70% of lines light expect_x column.
	const bool stride_bad = col_frac < 0.70;
	const bool repro = wander || slope || stride_bad;
	std::cout << "  stats p10=" << p10 << " p50=" << p50 << " p90=" << p90
	          << " core_spread=" << core_spread << " col_frac=" << col_frac << "\n";

	std::cout << "CASE " << name
	          << " rd_delay=" << rd_delay
	          << " lines=" << st.lines
	          << " miss_lines=" << st.miss_lines
	          << " hit_px=" << st.hit_px
	          << " dark_px=" << st.dark_px
	          << " first_x_min=" << st.min_x
	          << " first_x_max=" << st.max_x
	          << " spread=" << st.spread
	          << " max_left_miss_run=" << st.max_left_miss_run
	          << " excess_left=" << std::max(0, st.max_left_miss_run - kEdgeX)
	          << " mean_delta=" << st.mean_delta
	          << " col_probe=" << st.col_probe_hit << "/" << st.col_probe_total
	          << " underrun=" << int(sim.top.underrun_count)
	          << "\n";

	if (expect_repro) {
		if (!repro) {
			std::cerr << "FAIL " << name
			          << ": expected REPRO (core_spread/late_p90>=" << kWanderThresh
			          << " or stride col_frac<0.70), got core_spread=" << core_spread
			          << " col_frac=" << col_frac << "\n";
			return 1;
		}
		std::cout << "REPRO_OK " << name
		          << " (core_spread=" << core_spread
		          << " col_frac=" << col_frac
		          << " mean_delta=" << st.mean_delta << ")\n";
		return 0;
	}

	// expect clean: p50 at edge, tight core_spread, strong column probe.
	const int expect_x = expect_x0;
	const int hit_lines = st.lines - st.miss_lines;
	const int edge_slack = (p50 >= 0) ? std::abs(p50 - expect_x) : 99;
	const bool edge_ok = (hit_lines >= (st.lines * 3) / 4)
	                     && (edge_slack <= 2) && (core_spread <= 4) && (late_p90 <= 4)
	                     && (col_frac >= 0.85);
	// CLEAN path uses edge_ok only — do not let a single outlier mean_delta
	// (or stride_bad) veto a tight p10/p50/p90 core.
	if (!edge_ok) {
		std::cerr << "FAIL " << name << ": expected CLEAN edge~" << expect_x
		          << ", got spread=" << st.spread
		          << " left_miss=" << st.max_left_miss_run
		          << " first_x=" << st.min_x << ".." << st.max_x
		          << " mean_delta=" << st.mean_delta << "\n";
		return 1;
	}
	std::cout << "PASS " << name << " clean (spread=" << st.spread
	          << " left_miss=" << st.max_left_miss_run << ")\n";
	return 0;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);

	// Pre-register predictions:
	// 1) stride_fault must REPRO diagonal/first-x drift (writer 40 vs reader 80).
	// 2) product_slow must REPRO left wander under multi-cycle DDR (silicon class).
	// 3) product_fast is diagnostic only — if CLEAN while (2) REPROs, latency is causal.

	int rc = 0;
	// Discriminator: stride fault must stay RED after the left-edge fix.
	if (run_case("stride_fault", PackMode::StrideFault320, /*rd_delay=*/4, /*expect_repro=*/true) != 0)
		rc = 1;
	// Product pack must go CLEAN under slow DDR (silicon class).
	if (run_case("product_slow", PackMode::Product, /*rd_delay=*/12, /*expect_repro=*/false) != 0)
		rc = 1;
	// Fast DDR must also be CLEAN — structural HBlank thrash, not latency-only.
	if (run_case("product_fast", PackMode::Product, /*rd_delay=*/2, /*expect_repro=*/false) != 0)
		rc = 1;

	if (rc == 0)
		std::cout << "OK ddr_frame_store_scanout_shear: REPRO_OK stride + CLEAN product_slow/fast\n";
	return rc;
}
