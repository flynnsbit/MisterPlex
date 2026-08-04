// Red/green gate: frame-store control mailboxes are doorbell-relative.
//
// Parent bank dump on c5382bee: bank0 U plane @ +0x49200 was 0x04/0x19 (near-zero
// chroma → green cast), bank1 U was 0x82 (neutral). Root cause class: ARM
// readBankRelease used legacy absolute PLXD 0x3007F128 while product RTL writes
// PLXD at doorbell+0x128 = 0x302FF128 (720p). Residue at the legacy address desyncs
// free_bank_mask / bank targeting.
//
// Cases:
//   A) product 720p doorbell → PLXD 0x302FF128 (not 0x3007F128)
//   B) legacy doorbell  → PLXD 0x3007F128 (offset math still holds)
//   C) fpga_spi.cpp must call bankReleaseMailboxPhys / underrunMailboxPhys
//      (static source check via companion shell or this binary's string table)

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/input_mailbox.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>

using namespace misterplex;

static int g_fails = 0;

static void expect(bool cond, const char* msg) {
    if (!cond) {
        std::cerr << "FAIL: " << msg << "\n";
        ++g_fails;
    } else {
        std::cout << "OK: " << msg << "\n";
    }
}

int main() {
    std::cout << "CASE product_plxd_phys EXECUTED\n";

    const DdrFrameLayout product =
        makeDdrFrameLayout(productDdrFrameStoreGeometry(), kDdrFramePhysBase,
                           kDdrFrameStrideAlign, DdrFrameFormat::Yuv420p);
    expect(ddrFrameLayoutMatchesProductSilicon(product),
           "product layout matches silicon contract");
    expect(product.doorbell_phys == kPlex720pYuv420pDoorbellPhys,
           "product doorbell is 0x302FF000");
    expect(product.doorbell_phys == 0x302FF000u, "doorbell literal 0x302FF000");

    const uint32_t plxd = bankReleaseMailboxPhys(product.doorbell_phys);
    const uint32_t plxf = underrunMailboxPhys(product.doorbell_phys);
    const uint32_t plxs = statusMailboxPhys(product.doorbell_phys);

    expect(plxd == 0x302FF128u, "product PLXD phys == 0x302FF128");
    expect(plxd != 0x3007F128u, "product PLXD must NOT be legacy 0x3007F128");
    expect(plxf == 0x302FF118u, "product PLXF phys == 0x302FF118");
    expect(plxs == 0x302FF100u, "product PLXS phys == 0x302FF100");
    expect(plxd == product.doorbell_phys + mailbox_abi::kPlxdOffset,
           "PLXD == doorbell + kPlxdOffset");

    // Legacy example base still maps to historical absolutes.
    std::cout << "CASE legacy_plxd_phys EXECUTED\n";
    const uint32_t leg = bankReleaseMailboxPhys(mailbox_abi::kLegacyFrameStoreDoorbellPhys);
    expect(leg == 0x3007F128u, "legacy doorbell → PLXD 0x3007F128");
    expect(leg == mailbox_abi::kPlxdAddr, "legacy PLXD matches kPlxdAddr example");

    // Offsets match RTL (DOORBELL_PHYS + const).
    std::cout << "CASE offsets EXECUTED\n";
    expect(mailbox_abi::kPlxdOffset == 0x128u, "kPlxdOffset=0x128");
    expect(mailbox_abi::kPlxfOffset == 0x118u, "kPlxfOffset=0x118");
    expect(mailbox_abi::kPlxsOffset == 0x100u, "kPlxsOffset=0x100");

    // Plane offsets (bank dump parent used U at +0x49200).
    expect(product.u_offset == static_cast<uint32_t>(kPlex720pUPlaneOffset),
           "U plane offset 921600 (0xE1000)");
    expect(product.u_offset == 921600u, "U offset literal");

    // Source gate: fpga_spi must not use absolute kBankReleaseMailboxPhys in
    // readBankRelease (legacy residue path).
    std::cout << "CASE fpga_spi_source EXECUTED\n";
    {
        const char* path = "arm/misterplexd/fpga_spi.cpp";
        std::ifstream in(path);
        if (!in) {
            // Allow running from repo root or build dir.
            in.open(std::string("../") + path);
        }
        if (!in) {
            in.open(std::string("../../") + path);
        }
        expect(static_cast<bool>(in), "opened fpga_spi.cpp");
        std::string src((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        expect(src.find("bankReleaseMailboxPhys(ddrLayout_.doorbell_phys)") != std::string::npos,
               "readBankRelease uses bankReleaseMailboxPhys(doorbell)");
        expect(src.find("underrunMailboxPhys(ddrLayout_.doorbell_phys)") != std::string::npos,
               "readFrameStoreStatus uses underrunMailboxPhys(doorbell)");
        // Ban the old absolute form inside the two readers (allow comments).
        const char* ban = "kBankReleaseMailboxPhys - ddrLayout_.phys_base";
        expect(src.find(ban) == std::string::npos,
               "no absolute kBankReleaseMailboxPhys map offset in fpga_spi");
    }

    if (g_fails) {
        std::cerr << "REPRO_OR_FAIL test_ddr_bank_mailbox_phys fails=" << g_fails << "\n";
        return 1;
    }
    std::cout << "PASS test_ddr_bank_mailbox_phys product_PLXD=0x302FF128 "
                 "(legacy 0x3007F128 rejected for product doorbell)\n";
    return 0;
}
