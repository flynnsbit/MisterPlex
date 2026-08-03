// Prove residual_csum equivalence: full-16 XOR sat8(placed) == XOR of non-zero
// levels only (running csum_acc model). FAIL if golden drifts or if a wrong
// fold (arith sum) is accepted as the product checksum.
//
// Positive: kCoeffScan → 0x14 via residual_gold::coeffCsum8 and via level-only XOR.
// Negative: arith-sum fold must NOT equal 0x14 (stale anti-golden 0xEC).
#include <cstdio>
#include <cstdint>
#include "libmisterplex/h264_residual_gold.hpp"

using misterplex::residual_gold::kCoeffScan;
using misterplex::residual_gold::kCsum8;
using misterplex::residual_gold::kStaleSumAsU8;
using misterplex::residual_gold::coeffCsum8;
using misterplex::residual_gold::satS8;

static int g_fails = 0;

static void expect(bool cond, const char *msg) {
	if (!cond) {
		std::printf("FAIL %s\n", msg);
		++g_fails;
	}
}

int main() {
	// Full-16 fold (host / historical ST_PLACE combo path)
	const uint8_t full = coeffCsum8(kCoeffScan);
	expect(full == 0x14, "full-16 fold of kCoeffScan must be 0x14");
	expect(full == kCsum8, "kCsum8 constexpr must match coeffCsum8(kCoeffScan)");

	// Running-acc model: XOR sat8 of non-zero entries only (zeros free under XOR)
	uint8_t acc = 0;
	int nz = 0;
	for (int i = 0; i < 16; ++i) {
		if (kCoeffScan[i] != 0) {
			acc ^= static_cast<uint8_t>(satS8(kCoeffScan[i]));
			++nz;
		}
	}
	expect(nz == 8, "Baseline kTc=8 non-zero scan slots");
	expect(acc == full, "running level-XOR must equal full-16 fold (zeros free)");
	expect(acc == 0x14, "running acc golden 0x14");

	// NEGATIVE: arithmetic sum fold is the forbidden stale class — must not be 0x14
	int sum = 0;
	for (int i = 0; i < 16; ++i)
		sum += static_cast<int>(satS8(kCoeffScan[i]));
	const auto sum_u8 = static_cast<uint8_t>(sum);
	expect(sum_u8 == kStaleSumAsU8, "arith sum must be locked anti-golden 0xEC");
	expect(sum_u8 != 0x14, "arith sum must NOT equal product residual_csum 0x14");

	// NEGATIVE twin of FAULT_RES_CSUM_XOR1: acc^1 must not pass as golden
	expect(static_cast<uint8_t>(acc ^ 0x01) != 0x14, "acc^1 must fail 0x14 golden");

	if (g_fails != 0) {
		std::printf("test_residual_csum_acc_math: %d FAIL(s)\n", g_fails);
		return 1;
	}
	std::printf("test_residual_csum_acc_math: PASS full=0x%02x acc=0x%02x nz=%d\n",
	            full, acc, nz);
	return 0;
}
