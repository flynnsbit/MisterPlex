#include "libmisterplex/fabric_bank_credit.hpp"
#include "libmisterplex/input_mailbox.hpp"
#include <cstdio>
#include <cstring>

using namespace misterplex;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#c); ++fails; } } while (0)

int main() {
    CHECK(kFabric720pPhysBase == 0x30180000u);
    CHECK(kFabric720pBankStride == 0x180000u);
    CHECK(kFabric720pDoorbellPhys == 0x3047F000u);
    CHECK(fabric720pBankPhys(0) == 0x30180000u);
    CHECK(fabric720pBankPhys(1) == 0x30300000u);
    CHECK(fabric720pPlxdPhys() == kFabric720pDoorbellPhys + kBankReleaseMailboxOffset);
    CHECK(kBankReleaseMailboxOffset == 0x128u);
    CHECK(fabricBankWritable(0b10, 1));
    CHECK(!fabricBankWritable(0b10, 0));
    CHECK(!fabricBankWritable(0, 0));
    const uint32_t hi = packFabricPlxdHi(2, 0, false, 7);
    CHECK((hi & 3u) == 2u);
    CHECK(((hi >> 16) & 0xffffu) == 7u);
    CHECK(fabricWriterPathIsZeroArmPerPixel());

    FILE* f = std::fopen("fpga/Plex_MiSTer/Plex.sv", "r");
    CHECK(f != nullptr);
    if (f) {
        char buf[1 << 20];
        size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
        buf[n] = 0;
        std::fclose(f);
        CHECK(std::strstr(buf, "DDR_FRAME_720P_PHYS_BASE") != nullptr);
        CHECK(std::strstr(buf, "produce_en") != nullptr);
        CHECK(std::strstr(buf, "fabric_ddr_attach") != nullptr);
    }
    f = std::fopen("fpga/Plex_MiSTer/rtl/fabric_bank_credit.sv", "r");
    CHECK(f != nullptr);
    if (f) {
        char buf[1 << 16];
        size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
        buf[n] = 0;
        std::fclose(f);
        CHECK(std::strstr(buf, "free_mask") != nullptr);
        CHECK(std::strstr(buf, "commit_pulse") != nullptr);
    }
    // Macro default OFF
    f = std::fopen("fpga/Plex_MiSTer/Plex.qsf", "r");
    CHECK(f != nullptr);
    if (f) {
        char buf[1 << 20];
        size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
        buf[n] = 0;
        std::fclose(f);
        CHECK(std::strstr(buf, "#set_global_assignment -name VERILOG_MACRO \"FABRIC_DDR_WRITER=1\"") != nullptr);
    }

    if (fails) {
        std::fprintf(stderr, "test_fabric_bank_credit: %d fails\n", fails);
        return 1;
    }
    std::printf("test_fabric_bank_credit: OK optionc=1 plxd=0x%x zero_arm=1\n",
                fabric720pPlxdPhys());
    return 0;
}
