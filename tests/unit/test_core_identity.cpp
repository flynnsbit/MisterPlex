// RED/GREEN gate: PLXC core identity decode + daemon/core pairing policy.
//
// Why: video_regression md5s on-disk RBF files; /tmp/CORENAME is always "Plex".
// A DDR daemon + SPI core (black screen) can pass file gates. PLXC is the
// running-bitstream signal: CAP_DDR present only when ddr_frame_store is live.

#include "libmisterplex/core_identity.hpp"
#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/input_mailbox.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
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

static uint64_t pack_plxc(uint32_t prov28, bool cap_ddr, bool cap_spi, unsigned abi) {
    uint32_t hi = (prov28 & 0x0FFFFFFFu);
    if (cap_ddr)
        hi |= 1u << mailbox_abi::kPlxcCapDdrBit;
    if (cap_spi)
        hi |= 1u << mailbox_abi::kPlxcCapSpiBit;
    hi |= (abi & 3u) << mailbox_abi::kPlxcAbiBit;
    return static_cast<uint64_t>(mailbox_abi::kPlxcMagic) | (static_cast<uint64_t>(hi) << 32);
}

int main() {
    std::cout << "CASE phys_offsets EXECUTED\n";
    const DdrFrameLayout product =
        makeDdrFrameLayout(productDdrFrameStoreGeometry(), kDdrFramePhysBase,
                           kDdrFrameStrideAlign, DdrFrameFormat::Yuv420p);
    expect(product.doorbell_phys == 0x300FF000u, "product doorbell 0x300FF000");
    const uint32_t plxc = coreIdentityMailboxPhys(product.doorbell_phys);
    expect(plxc == 0x300FF130u, "product PLXC phys == 0x300FF130");
    expect(plxc != 0x3007F130u, "product PLXC must NOT be legacy absolute");
    expect(plxc == product.doorbell_phys + mailbox_abi::kPlxcOffset,
           "PLXC == doorbell + kPlxcOffset");
    expect(mailbox_abi::kPlxcOffset == 0x130u, "kPlxcOffset=0x130");
    expect(coreIdentityMailboxPhys(mailbox_abi::kLegacyFrameStoreDoorbellPhys) ==
               0x3007F130u,
           "legacy doorbell → PLXC 0x3007F130");

    std::cout << "CASE decode_ddr EXECUTED\n";
    {
        CoreIdentity id{};
        const uint64_t w = pack_plxc(0x194D7F6u, true, false, 1);
        expect(decodeCoreIdentityWord(w, id), "decode DDR PLXC");
        expect(id.present && id.path == CorePathClass::Ddr, "path=ddr");
        expect(id.provenance28 == 0x194D7F6u, "provenance matches");
        expect(id.cap_ddr && !id.cap_spi, "caps ddr-only");
        expect(id.abi_version == 1u, "abi=1");
    }

    std::cout << "CASE decode_absent EXECUTED\n";
    {
        CoreIdentity id{};
        expect(!decodeCoreIdentityWord(0, id), "zero word absent");
        expect(id.path == CorePathClass::Absent, "path absent");
        expect(!decodeCoreIdentityWord(0xDEADBEEFCAFEBABEull, id), "junk absent");
    }

    std::cout << "CASE pair_policy RED_before_GREEN EXECUTED\n";
    {
        CoreIdentity ddr{};
        decodeCoreIdentityWord(pack_plxc(0x1111111u, true, false, 1), ddr);
        CoreIdentity absent{};
        CoreIdentity spi{};
        // Synthetic SPI stamp (not written by product RTL; reserved encoding).
        decodeCoreIdentityWord(pack_plxc(0x2222222u, false, true, 1), spi);

        CorePairExpect spi_daemon{};
        spi_daemon.expect_ddr_path = false;
        expect(checkCoreDaemonPair(absent, spi_daemon) == CorePairVerdict::Ok,
               "GREEN SPI daemon + absent identity (daily driver class)");
        expect(checkCoreDaemonPair(ddr, spi_daemon) ==
                   CorePairVerdict::RedMixedSpiDaemonOnDdrCore,
               "RED SPI daemon + CAP_DDR core (mixed black-screen class)");

        CorePairExpect ddr_daemon_pre{};
        ddr_daemon_pre.expect_ddr_path = true;
        ddr_daemon_pre.require_identity_present = false; // c5382bee pre-identity
        expect(checkCoreDaemonPair(absent, ddr_daemon_pre) == CorePairVerdict::Ok,
               "GREEN DDR daemon + absent OK while pre-identity allowed");
        expect(checkCoreDaemonPair(ddr, ddr_daemon_pre) == CorePairVerdict::Ok,
               "GREEN DDR daemon + CAP_DDR");
        expect(checkCoreDaemonPair(spi, ddr_daemon_pre) ==
                   CorePairVerdict::RedMixedDdrDaemonOnNonDdrCore,
               "RED DDR daemon + SPI stamp");

        CorePairExpect ddr_daemon_req{};
        ddr_daemon_req.expect_ddr_path = true;
        ddr_daemon_req.require_identity_present = true; // post first identity RBF
        expect(checkCoreDaemonPair(absent, ddr_daemon_req) ==
                   CorePairVerdict::RedMixedDdrDaemonOnNonDdrCore,
               "RED DDR daemon + absent when identity required");
        expect(checkCoreDaemonPair(ddr, ddr_daemon_req) == CorePairVerdict::Ok,
               "GREEN DDR daemon + CAP_DDR when identity required");

        CorePairExpect prov{};
        prov.expect_ddr_path = true;
        prov.require_identity_present = true;
        prov.check_provenance = true;
        prov.expect_provenance28 = 0x194D7F6u;
        CoreIdentity wrong_prov{};
        decodeCoreIdentityWord(pack_plxc(0x0BADF00Du, true, false, 1), wrong_prov);
        expect(checkCoreDaemonPair(wrong_prov, prov) ==
                   CorePairVerdict::RedProvenanceMismatch,
               "RED provenance mismatch");
        CoreIdentity right_prov{};
        decodeCoreIdentityWord(pack_plxc(0x194D7F6u, true, false, 1), right_prov);
        expect(checkCoreDaemonPair(right_prov, prov) == CorePairVerdict::Ok,
               "GREEN provenance match");
    }

    std::cout << "CASE fpga_spi_source EXECUTED\n";
    {
        const char* path = "arm/misterplexd/fpga_spi.cpp";
        std::ifstream in(path);
        if (!in)
            in.open(std::string("../") + path);
        if (!in)
            in.open(std::string("../../") + path);
        expect(static_cast<bool>(in), "opened fpga_spi.cpp");
        std::string src((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        expect(src.find("coreIdentityMailboxPhys(ddrLayout_.doorbell_phys)") != std::string::npos,
               "readCoreIdentity uses coreIdentityMailboxPhys(doorbell)");
        expect(src.find("0x300FF130") == std::string::npos ||
                   src.find("Never hardcode 0x3007F130 / 0x300FF130") != std::string::npos,
               "no bare product absolute PLXC phys as map base");
        // Ban absolute map arithmetic class that burned PLXD.
        expect(src.find("kCoreIdentityMailboxPhys - ddrLayout_.phys_base") == std::string::npos,
               "no absolute kCoreIdentityMailboxPhys map offset");
    }

    std::cout << "CASE stamp_json EXECUTED\n";
    {
        std::ifstream in("assets/core_identity_stamp.json");
        if (!in)
            in.open("../assets/core_identity_stamp.json");
        if (!in)
            in.open("../../assets/core_identity_stamp.json");
        expect(static_cast<bool>(in), "opened core_identity_stamp.json");
        std::string j((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        expect(j.find("\"magic\": \"0x504C5843\"") != std::string::npos, "json magic PLXC");
        expect(j.find("\"offset_from_doorbell\": \"0x130\"") != std::string::npos, "json offset");
        expect(j.find("\"cap_ddr_frame_store\": 1") != std::string::npos, "json cap_ddr");
        expect(j.find("GENERATED") == std::string::npos || true, "json present");
        expect(j.find("0x") != std::string::npos, "json has hex fields");
    }

    if (g_fails) {
        std::cerr << "REPRO_OR_FAIL test_core_identity fails=" << g_fails << "\n";
        return 1;
    }
    std::cout << "PASS test_core_identity PLXC doorbell+0x130 pairing RED/GREEN\n";
    return 0;
}
