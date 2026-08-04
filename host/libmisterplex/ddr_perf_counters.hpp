#pragma once
// PLXP fabric DDR perf counter page — decode helpers (mirror rtl/docs).
#include <cstdint>
#include "mailbox_abi_spec.hpp"

namespace misterplex {
namespace ddr_perf {

inline constexpr uint32_t kMagic = mailbox_abi::kPlxpMagic;
inline constexpr uint8_t kVersion = mailbox_abi::kPlxpVersion;
inline constexpr uint32_t kOffset = mailbox_abi::kPlxpOffset;
inline constexpr unsigned kNumQwords = 16;

inline uint32_t pagePhys(uint32_t doorbell_phys) {
    return doorbell_phys + kOffset;
}

struct Snapshot {
    uint8_t seq = 0;
    uint8_t ver = 0;
    uint16_t sat_flags = 0;
    uint32_t cycles = 0;
    uint32_t wr_beats = 0;
    uint32_t rd_beats = 0;
    uint32_t stall_cyc = 0;
    uint32_t lat_sum = 0;
    uint32_t lat_max = 0;
    uint32_t lat_n = 0;
    uint32_t m0_rd = 0, m0_wr = 0;
    uint32_t m1_rd = 0, m1_wr = 0;
    uint32_t m2_rd = 0, m2_wr = 0;
    bool ok = false;
};

inline uint32_t lo32(uint64_t w) { return static_cast<uint32_t>(w & 0xffffffffu); }

// words[16] little-endian qwords as read from /dev/mem.
inline bool decode(const uint64_t words[kNumQwords], Snapshot& out) {
    out = Snapshot{};
    const uint64_t h = words[0];
    const uint64_t t = words[15];
    if (lo32(h) != kMagic) return false;
    if (lo32(t) != kMagic) return false;
    out.ver = static_cast<uint8_t>((h >> 32) & 0xff);
    out.seq = static_cast<uint8_t>((h >> 40) & 0xff);
    out.sat_flags = static_cast<uint16_t>((h >> 48) & 0xffff);
    if (out.ver != kVersion) return false;
    if (out.seq != static_cast<uint8_t>((t >> 32) & 0xff)) return false;
    out.cycles = lo32(words[1]);
    out.wr_beats = lo32(words[2]);
    out.rd_beats = lo32(words[3]);
    out.stall_cyc = lo32(words[4]);
    out.lat_sum = lo32(words[5]);
    out.lat_max = lo32(words[6]);
    out.lat_n = lo32(words[7]);
    out.m0_rd = lo32(words[8]);
    out.m0_wr = lo32(words[9]);
    out.m1_rd = lo32(words[10]);
    out.m1_wr = lo32(words[11]);
    out.m2_rd = lo32(words[12]);
    out.m2_wr = lo32(words[13]);
    out.ok = true;
    return true;
}

// MB/s from a snapshot assuming clk_ddr_hz (default 90e6).
inline double wr_MBps(const Snapshot& s, double clk_ddr_hz = 90e6) {
    if (!s.ok || s.cycles == 0) return 0.0;
    return (static_cast<double>(s.wr_beats) * 8.0 * clk_ddr_hz) /
           (static_cast<double>(s.cycles) * 1e6);
}
inline double rd_MBps(const Snapshot& s, double clk_ddr_hz = 90e6) {
    if (!s.ok || s.cycles == 0) return 0.0;
    return (static_cast<double>(s.rd_beats) * 8.0 * clk_ddr_hz) /
           (static_cast<double>(s.cycles) * 1e6);
}

} // namespace ddr_perf
} // namespace misterplex
