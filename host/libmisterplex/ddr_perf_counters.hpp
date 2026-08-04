#pragma once
// PLXP fabric DDR perf counter page — decode helpers (mirror rtl/docs).
// Version 2: latency histogram + efficiency/fragmentation fields.
#include <cstdint>
#include "mailbox_abi_spec.hpp"

namespace misterplex {
namespace ddr_perf {

inline constexpr uint32_t kMagic = mailbox_abi::kPlxpMagic;
inline constexpr uint8_t kVersion = mailbox_abi::kPlxpVersion;
inline constexpr uint32_t kOffset = mailbox_abi::kPlxpOffset;
inline constexpr unsigned kNumQwords = 24;

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
    // Latency bins (cmd→first-data cycles): 0-7,8-15,16-31,32-63,64-127,128+
    uint32_t lat_bin[6] = {};
    uint32_t rd_cmds = 0;
    uint32_t burst_sum = 0;
    uint32_t single_cmds = 0;
    uint32_t issue_cyc = 0;
    bool ok = false;
};

inline uint32_t lo32(uint64_t w) { return static_cast<uint32_t>(w & 0xffffffffu); }
inline uint32_t hi32(uint64_t w) { return static_cast<uint32_t>((w >> 32) & 0xffffffffu); }

// words[24] little-endian qwords as read from /dev/mem.
inline bool decode(const uint64_t words[kNumQwords], Snapshot& out) {
    out = Snapshot{};
    const uint64_t h = words[0];
    const uint64_t t = words[23];
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
    for (int i = 0; i < 6; ++i)
        out.lat_bin[i] = lo32(words[14 + i]);
    out.rd_cmds = lo32(words[20]);
    out.burst_sum = lo32(words[21]);
    out.single_cmds = lo32(words[22]);
    out.issue_cyc = hi32(words[22]);
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
// Mean cmd→first-data latency in cycles (0 if no samples).
inline double lat_mean(const Snapshot& s) {
    if (!s.ok || s.lat_n == 0) return 0.0;
    return static_cast<double>(s.lat_sum) / static_cast<double>(s.lat_n);
}
// Mean burst length in beats (useful vs fragmentation).
inline double mean_burst(const Snapshot& s) {
    if (!s.ok || s.rd_cmds == 0) return 0.0;
    return static_cast<double>(s.burst_sum) / static_cast<double>(s.rd_cmds);
}
// Bus efficiency: data beats * 8 / (issue_cyc * 8) = beats/issue_cyc when issue>0.
inline double beat_efficiency(const Snapshot& s) {
    if (!s.ok || s.issue_cyc == 0) return 0.0;
    return static_cast<double>(s.wr_beats + s.rd_beats) /
           static_cast<double>(s.issue_cyc);
}

} // namespace ddr_perf
} // namespace misterplex
