#include "fpga_spi.hpp"
#include "libmisterplex/h264_residual_gold.hpp"
#include "libmisterplex/status_telemetry.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>

namespace {

using Raw = std::array<uint8_t, 16>;

void fail(const char* msg) {
    std::fprintf(stderr, "FAIL status telemetry ABI: %s\n", msg);
    std::exit(1);
}

void expect(bool cond, const char* msg) {
    if (!cond)
        fail(msg);
}

void setBit(Raw& raw, int bit, bool value) {
    const int byte = bit / 8;
    const int shift = bit % 8;
    if (value)
        raw[byte] = static_cast<uint8_t>(raw[byte] | (1u << shift));
    else
        raw[byte] = static_cast<uint8_t>(raw[byte] & ~(1u << shift));
}

void setBits(Raw& raw, int lo, int hi, uint32_t value) {
    for (int bit = lo; bit <= hi; ++bit)
        setBit(raw, bit, ((value >> (bit - lo)) & 1u) != 0);
}

Raw packPlexStatus(uint8_t residual_dc, uint8_t residual_csum, uint8_t recon_sig,
                   uint8_t recon_dbg, uint8_t aspect_ratio) {
    using namespace misterplex::status_telemetry;
    Raw raw{};
    setBits(raw, kResidualDcBitLo, kResidualDcBitHi, residual_dc);
    setBits(raw, kResidualCsumBitLo, kResidualCsumBitHi, residual_csum);
    setBits(raw, kReconSigBitLo, kReconSigBitHi, recon_sig);
    setBits(raw, kReconDbgBitLo, kReconDbgBitHi, recon_dbg);
    // Plex.sv status_in preserves OSD aspect ratio bits at [122:121], which are
    // reserved inside recon_dbg. residual_dc/csum/recon_sig must be untouched.
    setBits(raw, 121, 122, aspect_ratio & 0x3);
    return raw;
}

Raw packPre33l1Alias(uint8_t residual_dc, uint32_t stream_bytes) {
    Raw raw{};
    setBits(raw, 96, 103, residual_dc);
    setBits(raw, 104, 127, stream_bytes & 0xFFFFFFu);
    return raw;
}

uintmax_t fileSize(const char* path) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        fail("could not open generated Annex-B vector");
    return static_cast<uintmax_t>(std::distance(std::istreambuf_iterator<char>(f),
                                                std::istreambuf_iterator<char>()));
}

} // namespace

int main(int argc, char** argv) {
    using misterplex::FpgaSpi;
    using namespace misterplex::residual_gold;
    using namespace misterplex::status_telemetry;

    static_assert(kResidualDcByte == 12, "raw[12] residual_dc");
    static_assert(kResidualCsumByte == 13, "raw[13] residual_csum");
    static_assert(kReconSigByte == 14, "raw[14] recon_sig");
    static_assert(kReconDbgByte == 15, "raw[15] recon debug flags");
    static_assert(kCsum8 == 0x14, "residual checksum golden");
    static_assert(kReconSigMb0Block0 == 0x3B, "MB0 block0 recon signature golden");
    static_assert(kReconDbgMb0Block0 == 0xF9, "MB0 block0 recon debug flags golden");

    const auto dc_u8 = static_cast<uint8_t>(kDc);
    for (uint8_t ar = 0; ar < 4; ++ar) {
        const Raw raw =
            packPlexStatus(dc_u8, kCsum8, kReconSigMb0Block0, kReconDbgMb0Block0, ar);
        const FpgaSpi::CoreStatus st = FpgaSpi::parseCoreStatus(raw.data());
        expect(raw[kResidualDcByte] == dc_u8, "Plex.sv model did not put residual_dc at raw[12]");
        expect(raw[kResidualCsumByte] == kCsum8,
               "Plex.sv model did not put residual_csum at raw[13]");
        expect(raw[kReconSigByte] == kReconSigMb0Block0,
               "Plex.sv model did not put recon_sig at raw[14]");
        expect((raw[kReconDbgByte] & ~0x06) == (kReconDbgMb0Block0 & ~0x06),
               "Plex.sv model did not put recon_dbg usable flags at raw[15]");
        expect(st.residual_dc == kDc, "host parser did not decode residual_dc from raw[12]");
        expect(st.residual_csum == kCsum8,
               "host parser did not decode residual_csum from raw[13]");
        expect(st.recon_sig == kReconSigMb0Block0, "host parser did not decode recon_sig");
        expect((st.recon_dbg & ~0x06) == (kReconDbgMb0Block0 & ~0x06),
               "host parser did not decode recon_dbg usable flags");
    }

    const Raw alias = packPre33l1Alias(dc_u8, 0x002A53);
    const FpgaSpi::CoreStatus old = FpgaSpi::parseCoreStatus(alias.data());
    expect(old.residual_dc == kDc, "old alias model should preserve raw[12] residual_dc");
    expect(alias[kResidualCsumByte] == 0x53,
           "old alias model should place stream low byte in raw[13]");
    expect(old.residual_csum != kCsum8,
           "old alias layout was accepted as a hard residual_csum PASS");

    if (argc > 1) {
        const uintmax_t sz = fileSize(argv[1]);
        expect((sz & 0xFFu) == 0x53u,
               "generated Baseline Annex-B size low byte changed; update residual-size RCA notes");
    }

    std::printf("test_status_telemetry: OK raw[12]=dc raw[13]=csum raw[14]=recon_sig raw[15]=recon_dbg; "
                "old raw[13]=0x53 alias rejected\n");
    return 0;
}
