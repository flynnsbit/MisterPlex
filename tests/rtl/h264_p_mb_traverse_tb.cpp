// Verilator TB for h264_p_mb_traverse — full P-slice MB walk + mutations.
// Pre-register:
//   all-skip pic_mbs=6 → mb_count=6 order 0..5
//   mixed 2skip+1coded+3skip → mb_count=6 coded=1
//   all-skip 300 (20x15) → mb_count=300  (headline 320x240 grid)
// Falsify: mb_count < pic_mbs, wrong order, mutation stays green.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "Vh264_p_mb_traverse_tb_top.h"
#include "verilated.h"

static void append_ue(std::vector<int>& bits, unsigned v) {
	unsigned x = v + 1;
	int lz = 0;
	unsigned t = x;
	while (t > 1) {
		t >>= 1;
		lz++;
	}
	for (int i = 0; i < lz; i++) bits.push_back(0);
	for (int i = lz; i >= 0; i--) bits.push_back((x >> i) & 1);
}

static void append_se0(std::vector<int>& bits) { bits.push_back(1); }

static void pack_bits(std::vector<uint8_t>& bytes, const std::vector<int>& bits) {
	bytes.clear();
	uint8_t cur = 0;
	int n = 0;
	for (int b : bits) {
		cur = (uint8_t)((cur << 1) | (b & 1));
		n++;
		if (n == 8) {
			bytes.push_back(cur);
			cur = 0;
			n = 0;
		}
	}
	if (n) {
		cur = (uint8_t)(cur << (8 - n));
		bytes.push_back(cur);
	}
}

// P slice header (non-IDR, nal_ref=0, deblock off, log2_max_frame_num=4, poc_type=2)
static void append_p_header(std::vector<int>& bits) {
	append_ue(bits, 0); // first_mb_in_slice
	append_ue(bits, 0); // slice_type = P
	append_ue(bits, 0); // pic_parameter_set_id
	for (int i = 0; i < 4; i++) bits.push_back(0); // frame_num
	bits.push_back(0); // num_ref_idx_active_override_flag
	bits.push_back(0); // ref_pic_list_modification_flag_l0
	// nal_ref_idc=0 → no dec_ref_pic_marking
	append_se0(bits); // slice_qp_delta = 0
}

static std::vector<uint8_t> build_all_skip_rbsp(unsigned pic_mbs) {
	std::vector<int> bits;
	append_p_header(bits);
	append_ue(bits, pic_mbs);
	for (int i = 0; i < 16; i++) bits.push_back(0);
	std::vector<uint8_t> bytes;
	pack_bits(bytes, bits);
	return bytes;
}

// se(v) for signed value: codeNum = 2*|v|-(v>0?1:0), then ue(codeNum).
static void append_se(std::vector<int>& bits, int v) {
	unsigned code = (v > 0) ? (unsigned)(2 * v - 1) : (unsigned)(-2 * v);
	append_ue(bits, code);
}

static std::vector<uint8_t> build_mixed_rbsp() {
	std::vector<int> bits;
	append_p_header(bits);
	append_ue(bits, 2);
	append_ue(bits, 0);
	append_se0(bits);
	append_se0(bits);
	append_ue(bits, 0);
	append_ue(bits, 3);
	for (int i = 0; i < 16; i++) bits.push_back(0);
	std::vector<uint8_t> bytes;
	pack_bits(bytes, bits);
	return bytes;
}

struct RunResult {
	int mb_count = 0;
	int skip_count = 0;
	int coded_count = 0;
	int done = 0;
	int error = 0;
	int unsupported = 0;
	int mvd_valid_count = 0;
	int mvd_nonzero_count = 0;
	int first_coded_mvd_x = 0;
	int first_coded_mvd_y = 0;
	int first_coded_mvd_valid = 0;
	std::vector<int> addrs;
	std::vector<int> skips;
};

// 1 skip + 1 coded P_L0_16x16 with mvd=(1,0) + cbp=0 + 1 skip → pic_mbs=3
static std::vector<uint8_t> build_mvd_nonzero_rbsp() {
	std::vector<int> bits;
	append_p_header(bits);
	append_ue(bits, 1); // skip_run
	append_ue(bits, 0); // mb_type = P_L0_16x16
	append_se(bits, 1); // mvd_x = 1
	append_se(bits, 0); // mvd_y = 0
	append_ue(bits, 0); // cbp = 0
	append_ue(bits, 1); // trailing skip_run
	for (int i = 0; i < 16; i++) bits.push_back(0);
	std::vector<uint8_t> bytes;
	pack_bits(bytes, bits);
	return bytes;
}

struct Dut {
	std::unique_ptr<VerilatedContext> ctx;
	std::unique_ptr<Vh264_p_mb_traverse_tb_top> top;
	explicit Dut() {
		ctx = std::make_unique<VerilatedContext>();
		top = std::make_unique<Vh264_p_mb_traverse_tb_top>(ctx.get());
	}
	void tick() {
		top->clk = 0;
		top->eval();
		ctx->timeInc(1);
		top->clk = 1;
		top->eval();
		ctx->timeInc(1);
	}
};

static RunResult run_once(const std::vector<uint8_t>& rbsp, int mw, int mh,
                          int max_cycles = 200000) {
	Dut dut;
	auto* top = dut.top.get();
	top->reset = 1;
	top->clear = 0;
	top->start = 0;
	top->in_valid = 0;
	top->in_byte = 0;
	top->in_last = 0;
	top->mb_ready = 1;
	top->mb_width = mw;
	top->mb_height = mh;

	for (int i = 0; i < 4; i++) dut.tick();
	top->reset = 0;
	dut.tick();

	for (size_t i = 0; i < rbsp.size(); i++) {
		int spins = 0;
		while (!top->in_ready && spins++ < 100) dut.tick();
		top->in_valid = 1;
		top->in_byte = rbsp[i];
		top->in_last = (i + 1 == rbsp.size()) ? 1 : 0;
		dut.tick();
		top->in_valid = 0;
		top->in_last = 0;
	}
	dut.tick();
	top->start = 1;
	dut.tick();
	top->start = 0;

	RunResult r;
	for (int c = 0; c < max_cycles; c++) {
		dut.tick();
		if (top->mb_valid && top->mb_ready) {
			r.addrs.push_back((int)top->mb_addr);
			r.skips.push_back((int)top->mb_skip);
			if (top->mvd_valid) {
				r.mvd_valid_count++;
				if (top->mvd_x != 0 || top->mvd_y != 0)
					r.mvd_nonzero_count++;
			}
			if (top->mb_skip) {
				r.skip_count++;
			} else {
				r.coded_count++;
				if (r.coded_count == 1) {
					r.first_coded_mvd_x = (int)top->mvd_x;
					r.first_coded_mvd_y = (int)top->mvd_y;
					r.first_coded_mvd_valid = (int)top->mvd_valid;
				}
			}
		}
		if (top->slice_done) {
			r.done = 1;
			r.mb_count = (int)top->mb_count;
			r.error = (int)top->error;
			r.unsupported = (int)top->unsupported;
			for (int k = 0; k < 4; k++) dut.tick();
			break;
		}
		if (top->error && !top->busy) {
			r.error = 1;
			r.mb_count = (int)top->mb_count;
			break;
		}
	}
	if (!r.done && !r.error)
		r.mb_count = (int)top->mb_count;
	top->final();
	return r;
}

static int expect_eq(const char* name, int got, int want) {
	if (got != want) {
		std::printf("FAIL %s: got %d want %d\n", name, got, want);
		return 1;
	}
	std::printf("PASS %s: %d\n", name, got);
	return 0;
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	const char* mode = "green";
	if (argc > 1) mode = argv[1];

	int fails = 0;
	const int PIC = 6;
	const int MW = 3;
	const int MH = 2;

	if (std::strcmp(mode, "green") == 0) {
		{
			auto rbsp = build_all_skip_rbsp(PIC);
			auto r = run_once(rbsp, MW, MH);
			std::printf("all_skip: done=%d mb_count=%d skip=%d coded=%d err=%d addrs=",
			            r.done, r.mb_count, r.skip_count, r.coded_count, r.error);
			for (int a : r.addrs) std::printf("%d ", a);
			std::printf("\n");
			fails += expect_eq("all_skip.mb_count", r.mb_count, PIC);
			fails += expect_eq("all_skip.skip_count", r.skip_count, PIC);
			fails += expect_eq("all_skip.done", r.done, 1);
			int ord_ok = ((int)r.addrs.size() == PIC);
			for (int i = 0; i < (int)r.addrs.size() && i < PIC; i++)
				if (r.addrs[i] != i) ord_ok = 0;
			fails += expect_eq("all_skip.order", ord_ok, 1);
			std::printf("traversed/total=%d/%d\n", r.mb_count, PIC);
		}
		{
			auto rbsp = build_mixed_rbsp();
			auto r = run_once(rbsp, MW, MH);
			std::printf("mixed: done=%d mb_count=%d skip=%d coded=%d err=%d addrs=",
			            r.done, r.mb_count, r.skip_count, r.coded_count, r.error);
			for (size_t i = 0; i < r.addrs.size(); i++)
				std::printf("%d%s ", r.addrs[i], r.skips[i] ? "s" : "c");
			std::printf("\n");
			fails += expect_eq("mixed.mb_count", r.mb_count, PIC);
			fails += expect_eq("mixed.coded_count", r.coded_count, 1);
			fails += expect_eq("mixed.skip_count", r.skip_count, 5);
			fails += expect_eq("mixed.done", r.done, 1);
			std::printf("traversed/total=%d/%d\n", r.mb_count, PIC);
		}
		{
			const int PIC300 = 300;
			auto rbsp = build_all_skip_rbsp(PIC300);
			auto r = run_once(rbsp, 20, 15, 500000);
			std::printf("all_skip_300: done=%d mb_count=%d skip=%d err=%d traversed/total=%d/%d\n",
			            r.done, r.mb_count, r.skip_count, r.error, r.mb_count, PIC300);
			fails += expect_eq("all_skip_300.mb_count", r.mb_count, PIC300);
			fails += expect_eq("all_skip_300.done", r.done, 1);
			// P_Skip still exports mvd_valid=1 with (0,0)
			fails += expect_eq("all_skip_300.mvd_valid_count", r.mvd_valid_count, PIC300);
		}
		{
			// Pre-register: mvd_parsed fraction = 3/3 (skip+coded+skip all export mvd_valid)
			// nonzero fraction = 1/3 (only coded MB has mvd=(1,0))
			auto rbsp = build_mvd_nonzero_rbsp();
			auto r = run_once(rbsp, 3, 1);
			std::printf("mvd_nz: done=%d mb=%d coded=%d mvd_valid=%d mvd_nz=%d first_mvd=(%d,%d) valid=%d\n",
			            r.done, r.mb_count, r.coded_count, r.mvd_valid_count, r.mvd_nonzero_count,
			            r.first_coded_mvd_x, r.first_coded_mvd_y, r.first_coded_mvd_valid);
			fails += expect_eq("mvd_nz.mb_count", r.mb_count, 3);
			fails += expect_eq("mvd_nz.coded_count", r.coded_count, 1);
			fails += expect_eq("mvd_nz.mvd_valid_count", r.mvd_valid_count, 3);
			fails += expect_eq("mvd_nz.mvd_nonzero_count", r.mvd_nonzero_count, 1);
			fails += expect_eq("mvd_nz.first_coded_mvd_x", r.first_coded_mvd_x, 1);
			fails += expect_eq("mvd_nz.first_coded_mvd_y", r.first_coded_mvd_y, 0);
			std::printf("parsed_mvd_fraction=%d/%d nonzero_mvd_fraction=%d/%d\n",
			            r.mvd_valid_count, r.mb_count, r.mvd_nonzero_count, r.mb_count);
		}
		if (fails) {
			std::printf("RESULT FAIL fails=%d\n", fails);
			return 1;
		}
		std::printf("RESULT PASS\n");
		return 0;
	}

	if (std::strcmp(mode, "fault_zero_mvd") == 0) {
		auto rbsp = build_mvd_nonzero_rbsp();
		auto r = run_once(rbsp, 3, 1);
		std::printf("mut_zero_mvd: first_mvd=(%d,%d) nz=%d valid=%d\n",
		            r.first_coded_mvd_x, r.first_coded_mvd_y, r.mvd_nonzero_count,
		            r.first_coded_mvd_valid);
		// RED when nonzero mvd is forced to zero
		if (r.first_coded_mvd_x == 0 && r.first_coded_mvd_y == 0 &&
		    r.mvd_nonzero_count == 0) {
			std::printf("EXPECTED_RED: FAULT_FORCE_ZERO_MVD dropped mvd=(1,0)\n");
			return 1;
		}
		std::printf("FAIL mutation stayed green\n");
		return 0;
	}

	if (std::strcmp(mode, "fault_bad_skip") == 0) {
		auto rbsp = build_all_skip_rbsp(PIC);
		auto r = run_once(rbsp, MW, MH);
		std::printf("mut_bad_skip: done=%d mb_count=%d skip=%d err=%d\n",
		            r.done, r.mb_count, r.skip_count, r.error);
		if (r.mb_count == PIC && r.skip_count == PIC && r.error == 0) {
			std::printf("FAIL mut_bad_skip: expected RED under-count/fault, got full green\n");
			return 1;
		}
		std::printf("EXPECTED_RED: mut_bad_skip under-count mb_count=%d err=%d\n",
		            r.mb_count, r.error);
		return 1;
	}

	if (std::strcmp(mode, "fault_drop_last") == 0) {
		auto rbsp = build_all_skip_rbsp(PIC);
		auto r = run_once(rbsp, MW, MH);
		std::printf("mut_drop_last: done=%d mb_count=%d addrs=", r.done, r.mb_count);
		for (int a : r.addrs) std::printf("%d ", a);
		std::printf("\n");
		if (r.mb_count == PIC) {
			std::printf("FAIL mut_drop_last: expected under-count, got full %d\n", r.mb_count);
			return 1;
		}
		if (r.mb_count != 4) {
			std::printf("FAIL mut_drop_last: want mb_count=4 got %d\n", r.mb_count);
			return 1;
		}
		for (int a : r.addrs) {
			if (a == 2 || a == 5) {
				std::printf("FAIL mut_drop_last: still emitted last-col MB %d\n", a);
				return 1;
			}
		}
		std::printf("EXPECTED_RED: mut_drop_last under-count mb_count=%d\n",
		            r.mb_count);
		return 1;
	}

	std::printf("FAIL unknown mode %s\n", mode);
	return 2;
}
