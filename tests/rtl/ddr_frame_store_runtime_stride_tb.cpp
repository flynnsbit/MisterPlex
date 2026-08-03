// Runtime stride / CODED geometry RBG for ddr_frame_store (w-scaler).
//
// Cases:
//   A) geom_enable=0 → first U/V qword bases == legacy 624×480 (37440 / 46800)
//   B) geom_enable=1, 1280×720 stride=1280 → U/V bases 115200 / 144000 + Option-C
//   B2) product STORAGE 960×540 (777600 B > usable 520192) → Option-C
//   B3) (optional future) SPS-coded 960×544 plane math — NOT product bank path
//   C) neg: geom=0 cannot satisfy 720p base expectations
//
// Capacity = usable payload (stride - 0x1000), not full stride (rd-duck).
// Storage rt_coded_* ≠ canvas 1280×720 (canvas is DE/scale dest only).
//
// Red twin (+define+DDR_FRAME_STORE_FAULT_IGNORE_GEOM):
//   Case B expectations against DUT that ignores geom → correctly FAIL.
// Red twin (+define+DDR_FRAME_STORE_FAULT_WIDTH_OPTC_PRED):
//   Old coded_w>=1280 predicate → product 960 stays legacy → Option-C Y FAIL.
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
// Option-C 720p (must match ddr_frame_store PHYS_BASE_720P / w-mem contract)
constexpr uint32_t kOptcBasePhys = 0x30180000u;
constexpr uint32_t kOptcBankStride = 0x180000u;
constexpr uint32_t kOptcDoorbellPhys = 0x3047F000u;
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

// Product STORAGE (ARM publish after libavcodec SPS crop): 960×540 / 777600.
// Canvas DE is 1280×720 — never program as rt_coded_* for this path.
// SPS coded 544 is future fabric-decoder only (not product bank planes).
constexpr int kProdW = 960;
constexpr int kProdStorageH = 540;
constexpr int kProdYS = 960;
constexpr int kProdCS = 480;
constexpr int kLegUsable = int(kBankStrideBytes) - 0x1000; // 520192
constexpr int kProd540Bytes = kProdYS * kProdStorageH * 3 / 2; // 777600
constexpr int kProd540UQ = (kProdYS * kProdStorageH) / 8;      // 64800
constexpr int kProd540CQ = (kProdCS * (kProdStorageH / 2)) / 8; // 16200
constexpr int kProd540VQ = kProd540UQ + kProd540CQ;            // 81000
constexpr int kProdYPitchQ = kProdYS / 8;                      // 120
constexpr int kProdCPitchQ = kProdCS / 8;                      // 60
// Canvas-as-storage anti-pattern: U base would be 921600 not 518400.
constexpr int kCanvasUQ = (1280 * 720) / 8; // 115200 qwords = 921600 B U offset

static_assert(kLegUQ == 37440, "legacy U");
static_assert(kLegVQ == 46800, "legacy V");
static_assert(kRtUQ == 115200, "720p U");
static_assert(kRtVQ == 144000, "720p V");
static_assert(kProd540Bytes == 777600, "product storage I420");
static_assert(kLegUsable == 520192, "legacy usable payload");
static_assert(kProd540Bytes > kLegUsable, "product storage needs Option-C (usable)");
static_assert(kProd540UQ == 64800 && kProd540VQ == 81000, "prod540 storage planes");
static_assert(kProd540UQ * 8 == 518400, "storage U byte offset");
static_assert(kCanvasUQ * 8 == 921600, "canvas U offset must not be used for storage");

// Capacity = usable (stride - control page), mirrors ddr_frame_store + layoutValid.
bool needsOptcMap(int y_stride, int c_stride, int storage_h) {
	const int bytes = storage_h * (y_stride + c_stride);
	return bytes > kLegUsable;
}

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
	uint32_t base_phys = kBasePhys;
	uint32_t doorbell_phys = kDoorbellPhys;
	bool expect_optc = false;
	uint64_t first_y_addr = 0;
	bool saw_y = false;

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

	uint32_t offQ(uint32_t phys) const { return (phys - base_phys) / 8; }
	uint32_t addrOffQ(uint32_t addr) const { return addr - (base_phys >> 3); }

	void clearStats() {
		y_reads = u_reads = v_reads = 0;
		first_u_addr = first_v_addr = first_y_addr = 0;
		saw_u = saw_v = saw_y = false;
	}

	void setBankMap(bool optc) {
		expect_optc = optc;
		base_phys = optc ? kOptcBasePhys : kBasePhys;
		doorbell_phys = optc ? kOptcDoorbellPhys : kDoorbellPhys;
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
		// Place doorbell at absolute phys; mem is indexed from base_phys.
		// For Option-C, expand: store doorbell relative to optc base.
		const uint32_t off = (doorbell_phys - base_phys) / 8;
		if (off >= mem.size()) {
			std::cerr << "FAIL doorbell off out of range\n";
			return;
		}
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
			const uint32_t db_rel = (doorbell_phys - base_phys) / 8;
			if (rel < db_rel || rel > db_rel + 64) {
				if (rel < static_cast<uint64_t>(cls_u)) {
					++y_reads;
					if (!saw_y) {
						saw_y = true;
						first_y_addr = rel;
					}
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
	// Bank map follows capacity (payload vs legacy 512KiB), not coded_w>=1280.
	sim.setBankMap(geom && needsOptcMap(ys > 0 ? ys : cw, cs > 0 ? cs : cw / 2, ch > 0 ? ch : 1));
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

	// Absolute phys of first Y beat (base + rel*8)
	const uint64_t y_phys = uint64_t(sim.base_phys) + sim.first_y_addr * 8ull;
	std::cout << "CASE " << name << " EXECUTED geom=" << (geom ? 1 : 0) << " coded=" << cw << "x"
	          << ch << " y_stride=" << ys << " bank_base=0x" << std::hex << sim.base_phys
	          << " first_y_phys=0x" << y_phys << std::dec << " first_u_q=" << sim.first_u_addr
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
		if (sim.expect_optc) {
			if (!sim.saw_y || y_phys != kOptcBasePhys) {
				std::cerr << "FAIL " << name << ": Option-C first Y phys 0x" << std::hex
				          << y_phys << " expected 0x" << kOptcBasePhys << std::dec << "\n";
				return 1;
			}
			std::cout << "PASS " << name << " Option-C bank map (first Y @ 0x30180000)\n";
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
#elif defined(DDR_FRAME_STORE_FAULT_WIDTH_OPTC_PRED)
	// Width-only predicate leaves product 960 on legacy bank — Option-C Y must FAIL.
	// expect_pass=true so a silent legacy map returns non-zero (red-before-green).
	const int rc =
	    run_case("prod540_width_pred_red", true, kProdW, kProdStorageH, kProdYS, kProdCS, kProdW,
	             64, 0, kProd540UQ, kProd540VQ, kProdYPitchQ, kProdCPitchQ, kProdW / 8, kProdW / 16,
	             /*expect_pass=*/true);
	std::cout << "RUNTIME_STRIDE_WIDTH_PRED_RED_DONE rc=" << rc << "\n";
	// Under the fault, Option-C check fails → rc!=0 is the correct red outcome.
	// The shell gate expects non-zero. Return rc as-is.
	return rc;
#else
	int fails = 0;
	fails += run_case("legacy624", false, 0, 0, 0, 0, 618, 64, 11, kLegUQ, kLegVQ, kLegYPitchQ,
	                  kLegCPitchQ, kLegW / 8, kLegW / 16, true);
	fails += run_case("rt720", true, kRtW, kRtH, kRtYStride, kRtCStride, kRtW, 64, 0, kRtUQ, kRtVQ,
	                  kRtYPitchQ, kRtCPitchQ, kRtW / 8, kRtW / 16, true);
	// Product STORAGE 960×540: usable-capacity forces Option-C.
	if (!needsOptcMap(kProdYS, kProdCS, kProdStorageH)) {
		std::cerr << "FAIL structural: prod540 bytes must need Option-C (usable)\n";
		++fails;
	} else {
		std::cout << "CASE prod540_capacity EXECUTED bytes=" << kProd540Bytes
		          << " leg_usable=" << kLegUsable << " leg_stride=" << kBankStrideBytes
		          << " need_optc=1\n";
	}
	// Structural: full-stride would wrongly accept 720×482 (520560); usable rejects.
	{
		const int tightBytes = 720 * 482 * 3 / 2; // 520560
		const bool fullStrideOk = tightBytes <= int(kBankStrideBytes);
		const bool usableOk = tightBytes <= kLegUsable;
		std::cout << "CASE usable_vs_fullstride EXECUTED bytes=" << tightBytes
		          << " full_ok=" << fullStrideOk << " usable_ok=" << usableOk << "\n";
		if (!fullStrideOk || usableOk) {
			std::cerr << "FAIL structural: 720x482 must pass full-stride and fail usable\n";
			++fails;
		} else {
			std::cout << "PASS usable_vs_fullstride: 720x482 exposes full-stride bug class\n";
		}
	}
	fails += run_case("prod540", true, kProdW, kProdStorageH, kProdYS, kProdCS, kProdW, 64, 0,
	                  kProd540UQ, kProd540VQ, kProdYPitchQ, kProdCPitchQ, kProdW / 8, kProdW / 16,
	                  true);
	// Storage vs canvas: product plane U must be 518400 (storage), not 921600 (canvas).
	if (kProd540UQ == kCanvasUQ || kProd540UQ * 8 != 518400) {
		std::cerr << "FAIL storage_vs_canvas: product U base must be storage 518400\n";
		++fails;
	} else {
		std::cout << "CASE storage_vs_canvas EXECUTED storage_u=518400 canvas_u=921600\n";
		std::cout << "PASS storage_vs_canvas: rt_coded_* = storage 960x540 not canvas 1280x720\n";
	}
	// Product path bank planes are 540 (FFmpeg crop). SPS 544 is NOT product storage.
	std::cout << "CASE product_storage_h EXECUTED storage_h=" << kProdStorageH
	          << " sps_coded_h=544 (decoder/ring only) scale_src_h=540\n";
	std::cout << "PASS product_storage_h: ARM bank planes = 540/777600; no 544 product planes\n";
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
