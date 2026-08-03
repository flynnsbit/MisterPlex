// test_ddr_720p_abi — PLXG / chrome-list wire ABI freeze (w-osd lane).
//
// Parent freeze: kPlxgOffset is FIXED 0x800, independent of MAX_CMDS.
// Cross-header: kDdrFramePlxgOffset == mailbox_abi::kPlxgOffset (compile-time
// reachable via ddr_frame_layout.hpp including mailbox_abi_spec.hpp).
//
// Full Option-C geometry matrix lives in w-mem; this lane must still *build and
// run* the ABI guard whenever it defines either constant.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/plex_chrome_cmds.hpp"

#include <cstdio>

static int fails = 0;
#define CHECK(cond)                                                                            \
    do {                                                                                       \
        if (!(cond)) {                                                                         \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);               \
            ++fails;                                                                           \
        }                                                                                      \
    } while (0)

int main() {
    using misterplex::kDdrFramePlxgBootstrapPhys;
    using misterplex::kDdrFramePlxgMagic;
    using misterplex::kDdrFramePlxgOffset;
    using misterplex::kPlex480pYuv420pDoorbellPhys;

    // --- FIXED wire ABI ---
    CHECK(mailbox_abi::kPlxgOffset == 0x800u);
    CHECK(kDdrFramePlxgOffset == 0x800u);
    CHECK(kDdrFramePlxgOffset == mailbox_abi::kPlxgOffset);
    CHECK(kDdrFramePlxgMagic == mailbox_abi::kPlxgMagic);
    CHECK(kDdrFramePlxgMagic == 0x504C5847u);

    // --- Must not collide with PLXC ---
    CHECK(kDdrFramePlxgOffset != mailbox_abi::kPlxcOffset);
    CHECK(kDdrFramePlxgOffset != 0x130u);
    CHECK(mailbox_abi::kPlxcOffset == 0x130u);

    // --- List bound (not equality-to-list-end) ---
    const uint32_t list_end =
        mailbox_abi::kPlxlOffset + mailbox_abi::kPlxcListMaxCmds * 8u;
    CHECK(list_end <= mailbox_abi::kPlxgOffset);
    CHECK(list_end == 0x140u + 112u * 8u); // 0x4C0
    CHECK(list_end == 0x4C0u);
    // Hole is intentional: UI budget may grow without moving PLXG.
    CHECK(list_end < mailbox_abi::kPlxgOffset);

    // --- Host chrome depth matches ABI list depth ---
    CHECK(misterplex::plex_chrome_cmds::kMaxCmds ==
          static_cast<int>(mailbox_abi::kPlxcListMaxCmds));
    CHECK(misterplex::plex_chrome_cmds::kHitScan ==
          misterplex::plex_chrome_cmds::kMaxCmds);

    // --- Product doorbell + FIXED offset ---
    CHECK(kPlex480pYuv420pDoorbellPhys == 0x300FF000u);
    CHECK(kDdrFramePlxgBootstrapPhys == 0x300FF000u + 0x800u);
    CHECK(kDdrFramePlxgBootstrapPhys == 0x300FF800u);
    CHECK(mailbox_abi::frameStoreMailboxPhys(kPlex480pYuv420pDoorbellPhys,
                                             mailbox_abi::kPlxgOffset) == 0x300FF800u);

    // --- Legacy example absolute matches FIXED offset ---
    CHECK(mailbox_abi::kPlxgAddr ==
          mailbox_abi::kLegacyFrameStoreDoorbellPhys + mailbox_abi::kPlxgOffset);

    // --- NEG: forbidden historical collisions ---
    CHECK(kDdrFramePlxgOffset != 0x2C0u); // old 48-cmd packing
    CHECK(kDdrFramePlxgOffset != 0x4C0u); // brief MAX_CMDS-derived value — frozen off

    if (fails) {
        std::fprintf(stderr, "test_ddr_720p_abi: %d FAIL(s)\n", fails);
        return 1;
    }
    std::printf("test_ddr_720p_abi: OK (PLXG FIXED 0x800, list_end=0x%X <= PLXG)\n",
                list_end);
    return 0;
}
