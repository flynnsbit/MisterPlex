// test_ddr_720p_abi — PLXG ABI freeze + cross-header guard (w-scaler lane).
//
// Parent ABI FREEZE 2026-08-03:
//   kPlxgOffset / kDdrFramePlxgOffset == FIXED 0x800 (not MAX_CMDS-derived)
//   chrome list bound: kPlxlOffset + MAX_CMDS*8 <= kPlxgOffset
//   never collide with PLXC @ 0x130
//   both headers reachable at compile time via include + static_assert
//
// This lane historically shipped kDdrFramePlxgOffset=0x130 (PLXC collision).
// The test must build in every lane that defines either constant.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdio>
#include <cstdint>

namespace {

int g_fails = 0;

#define CHECK(cond)                                                            \
	do {                                                                   \
		if (!(cond)) {                                                 \
			std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__,     \
				     __LINE__, #cond);                         \
			++g_fails;                                             \
		}                                                              \
	} while (0)

} // namespace

int main() {
	using namespace misterplex;
	using namespace mailbox_abi;

	// --- ABI FREEZE pin ---
	CHECK(kPlxgOffset == 0x800u);
	CHECK(kDdrFramePlxgOffset == 0x800u);
	CHECK(kDdrFramePlxgOffset == kPlxgOffset);
	CHECK(kDdrFramePlxgMagic == kPlxgMagic);
	CHECK(kDdrFramePlxgMagic == 0x504C5847u);
	CHECK(kDdrFramePlxgBytes == 40u);
	CHECK(kDdrFramePlxgBytes == kPlxgBytes);

	// --- PLXC owns +0x130; PLXG must never live there ---
	CHECK(kPlxcOffset == 0x130u);
	CHECK(kDdrFramePlxgOffset != kPlxcOffset);
	CHECK(kDdrFramePlxgOffset != 0x130u);
	CHECK(kPlxgOffset != kPlxcOffset);

	// --- Bound check (list may grow, offset must not move) ---
	CHECK(kPlxlOffset == 0x140u);
	CHECK(kPlxcListMaxCmds == 112u);
	CHECK(kPlxlOffset + kPlxcListMaxCmds * 8u <= kPlxgOffset);
	// Hole is intentional: 0x140+112*8 = 0x4C0 < 0x800
	CHECK(kPlxlOffset + kPlxcListMaxCmds * 8u == 0x4C0u);
	CHECK(0x4C0u < 0x800u);

	// --- Bootstrap phys (product doorbell + fixed offset) ---
	CHECK(kPlxgBootstrapDoorbellPhys == 0x300FF000u);
	CHECK(kPlxgBootstrapPhys == 0x300FF800u);
	CHECK(kDdrFramePlxgBootstrapPhys == kPlxgBootstrapPhys);
	CHECK(kPlxgBootstrapPhys == kPlxgBootstrapDoorbellPhys + kPlxgOffset);
	CHECK(plxgMailboxPhys(kPlex480pYuv420pDoorbellPhys) ==
	      kPlex480pYuv420pDoorbellPhys + 0x800u);
	CHECK(plxgMailboxPhys(kPlex720pYuv420pDoorbellPhys) ==
	      kPlex720pYuv420pDoorbellPhys + 0x800u);
	// Product 480p doorbell bootstrap path
	CHECK(plxgMailboxPhys(0x300FF000u) == 0x300FF800u);

	// --- Collision table includes both PLXC and PLXG ---
	bool saw_plxc = false;
	bool saw_plxg = false;
	for (const auto& m : kAllMailboxes) {
		if (m.magic == kPlxcMagic) {
			saw_plxc = true;
			CHECK(m.phys_addr == kPlxcAddr);
			CHECK(m.phys_addr == kLegacyFrameStoreDoorbellPhys + kPlxcOffset);
		}
		if (m.magic == kPlxgMagic) {
			saw_plxg = true;
			CHECK(m.phys_addr == kPlxgAddr);
			CHECK(m.phys_addr == kLegacyFrameStoreDoorbellPhys + kPlxgOffset);
			CHECK(m.size_bytes == 40u);
		}
	}
	CHECK(saw_plxc);
	CHECK(saw_plxg);
	CHECK(kPlxgAddr != kPlxcAddr);

	// NEG: derived equality (old w-osd style) must NOT be required
	// kPlxgOffset == kPlxlOffset + MAX_CMDS*8 would be 0x4C0 — freeze forbids it
	CHECK(kPlxgOffset != kPlxlOffset + kPlxcListMaxCmds * 8u);

	if (g_fails != 0) {
		std::fprintf(stderr, "test_ddr_720p_abi: %d fails\n", g_fails);
		return 1;
	}
	std::printf("test_ddr_720p_abi: OK plxg=0x%X freeze !=plxc(0x130) list_end=0x%X\n",
		    static_cast<unsigned>(kDdrFramePlxgOffset),
		    static_cast<unsigned>(kPlxlOffset + kPlxcListMaxCmds * 8u));
	return 0;
}
