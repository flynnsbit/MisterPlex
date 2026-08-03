// Product mailbox addresses must be doorbell-relative (parent 2026-08-03).
//
// Defect class: kPlxdAddr hardcoded to legacy absolute 0x3007F128 while product
// RTL publishes PLXD at DOORBELL_PHYS+0x128. Product doorbell is 0x300FF000 →
// live PLXD 0x300FF128 (delta 0x80000). 720p has its OWN doorbell 0x3047F000;
// absolute PLXD cannot express two resolutions — relative is forced.
//
// NEGATIVE: if any product-canonical k*Addr stops equaling
//   product_doorbell + k*Offset, FAIL.
// RED against broken tree: kPlxdAddr==0x3007F128 fails product equality.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/input_mailbox.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdio>
#include <cstdlib>

using namespace misterplex;
namespace mabi = mailbox_abi;

static int g_fails = 0;

static void expect(bool cond, const char* msg) {
    if (!cond) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        ++g_fails;
    } else {
        std::printf("OK: %s\n", msg);
    }
}

int main() {
    // Product 480p control-page doorbell (RTL DDR_FRAME_YUV420P_DOORBELL_PHYS /
    // mailbox bootstrap). Prefer named product constant when present.
#if defined(MISTERPLEX_HAS_PRODUCT_DOORBELL_CONST)
    const uint32_t product_door = mabi::kProductFrameStoreDoorbellPhys;
#else
    // Pre-fix / RED path: bootstrap doorbell is the product page.
    const uint32_t product_door = mabi::kPlxgBootstrapDoorbellPhys;
#endif
    expect(product_door == 0x300FF000u, "product doorbell 0x300FF000");
    expect(product_door == kPlex480pYuv420pDoorbellPhys,
           "product doorbell matches ddr_frame_layout 480p YUV doorbell");

    // Canonical k*Addr MUST equal product_doorbell + offset.
    expect(mabi::kPlxkAddr == product_door + mabi::kPlxkOffset,
           "kPlxkAddr == product_doorbell + 0x000");
    expect(mabi::kPlxsAddr == product_door + mabi::kPlxsOffset,
           "kPlxsAddr == product_doorbell + 0x100");
    expect(mabi::kPlxiAddr == product_door + mabi::kPlxiOffset,
           "kPlxiAddr == product_doorbell + 0x108");
    expect(mabi::kPlxmAddr == product_door + mabi::kPlxmOffset,
           "kPlxmAddr == product_doorbell + 0x110");
    expect(mabi::kPlxfAddr == product_door + mabi::kPlxfOffset,
           "kPlxfAddr == product_doorbell + 0x118");
    expect(mabi::kSdramDiagAddr == product_door + mabi::kSdramDiagOffset,
           "kSdramDiagAddr == product_doorbell + 0x120");
    expect(mabi::kPlxdAddr == product_door + mabi::kPlxdOffset,
           "kPlxdAddr == product_doorbell + 0x128");
    expect(mabi::kPlxcAddr == product_door + mabi::kPlxcOffset,
           "kPlxcAddr == product_doorbell + 0x130");
    expect(mabi::kPlxoAddr == product_door + mabi::kPlxoOffset,
           "kPlxoAddr == product_doorbell + 0x138");
    expect(mabi::kPlxgAddr == product_door + mabi::kPlxgOffset,
           "kPlxgAddr == product_doorbell + 0x800");

    // Teeth: product live PLXD is 0x300FF128 — legacy absolute is NOT canonical.
    expect(mabi::kPlxdAddr == 0x300FF128u, "product kPlxdAddr literal 0x300FF128");
    expect(mabi::kPlxdAddr != 0x3007F128u,
           "kPlxdAddr must not be legacy absolute 0x3007F128 (NEG teeth)");
    expect(kBankReleaseMailboxPhys == mabi::kPlxdAddr,
           "input_mailbox re-export tracks product kPlxdAddr");

    // Legacy example page (if symbols exist post-fix).
#ifdef MISTERPLEX_HAS_LEGACY_PLXD_CONST
    expect(mabi::kLegacyPlxdAddr ==
               mabi::kLegacyFrameStoreDoorbellPhys + mabi::kPlxdOffset,
           "kLegacyPlxdAddr == legacy_doorbell + 0x128");
    expect(mabi::kLegacyPlxdAddr == 0x3007F128u, "legacy PLXD example 0x3007F128");
    expect(mabi::kLegacyPlxdAddr != mabi::kPlxdAddr,
           "legacy and product PLXD must differ (0x80000 gap)");
#else
    // RED path: prove legacy math still holds as example only.
    const uint32_t legacy_plxd =
        mabi::kLegacyFrameStoreDoorbellPhys + mabi::kPlxdOffset;
    expect(legacy_plxd == 0x3007F128u, "legacy doorbell+offset still 0x3007F128");
    expect(legacy_plxd != mabi::kPlxdAddr,
           "product kPlxdAddr must leave legacy example behind");
#endif

    // --- 720p arm: mailboxes follow the 720p doorbell ---
    expect(kPlex720pYuv420pDoorbellPhys == 0x3047F000u, "720p doorbell 0x3047F000");
    const uint32_t plxd720 = bankReleaseMailboxPhys(kPlex720pYuv420pDoorbellPhys);
    const uint32_t plxs720 = statusMailboxPhys(kPlex720pYuv420pDoorbellPhys);
    const uint32_t plxg720 = plxgMailboxPhys(kPlex720pYuv420pDoorbellPhys);
    expect(plxd720 == 0x3047F128u, "720p PLXD == 0x3047F128");
    expect(plxs720 == 0x3047F100u, "720p PLXS == 0x3047F100");
    expect(plxg720 == 0x3047F800u, "720p PLXG == 0x3047F800");
    expect(plxd720 == kPlex720pYuv420pDoorbellPhys + mabi::kPlxdOffset,
           "720p PLXD == 720p_doorbell + kPlxdOffset");
    expect(plxd720 != mabi::kPlxdAddr,
           "720p PLXD must not collapse to 480p product PLXD");

    expect(bankReleaseMailboxPhys(kPlex480pYuv420pDoorbellPhys) == mabi::kPlxdAddr,
           "480p bankReleaseMailboxPhys matches kPlxdAddr");

    if (g_fails) {
        std::fprintf(stderr,
                     "REPRO_OR_FAIL test_mailbox_product_relative fails=%d "
                     "(kPlxdAddr still legacy absolute?)\n",
                     g_fails);
        return 1;
    }
    std::printf("PASS test_mailbox_product_relative product_PLXD=0x%08X "
                "720p_PLXD=0x%08X\n",
                static_cast<unsigned>(mabi::kPlxdAddr),
                static_cast<unsigned>(plxd720));
    return 0;
}
