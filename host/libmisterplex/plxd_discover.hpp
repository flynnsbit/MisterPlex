#pragma once
// Runtime PLXD mailbox discovery — removes absolute vs doorbell-relative desync.
//
// Problem class (measured on lab): main RTL publishes PLXD at absolute
// 0x3007F128; integ/product-relative lineage uses DOORBELL+0x128 (0x300FF128 /
// Option-C 0x3047F128). Hardcoding one address makes a live core look "dead".
//
// Contract: scan a small candidate set for magic 0x504C5844 ("PLXD"). First
// stable hit wins. No magic anywhere → discovery FAILS (negative path).
//
// Does NOT edit mailbox_abi_spec.hpp (w-mem owns that file). kPlxdAddr remains
// the preferred/default candidate; discovery only selects among live words.

#include <cstddef>
#include <cstdint>
#include <array>

#include "input_mailbox.hpp"
#include "mailbox_abi_spec.hpp"

namespace misterplex {

// Candidate physical addresses, preference order:
//   0) ABI default (main absolute)
//   1) Product doorbell page + 0x128 (DDR_FRAME_YUV420P_DOORBELL 0x300FF000)
//   2) Option-C / 720p doorbell page + 0x128 (0x3047F000)
//   3) Legacy ABI doorbell page + 0x128 (kPlxkAddr 0x3007F000 + 0x128) — if
//      a core ever co-located mailboxes on the ABI doorbell base.
inline constexpr uint32_t kPlxdDoorbellProduct = 0x300FF000u;
inline constexpr uint32_t kPlxdDoorbellOptionC = 0x3047F000u;

inline constexpr std::array<uint32_t, 4> kPlxdCandidatePhys = {{
    mailbox_abi::kPlxdAddr,                 // 0x3007F128
    kPlxdDoorbellProduct + 0x128u,          // 0x300FF128
    kPlxdDoorbellOptionC + 0x128u,          // 0x3047F128
    mailbox_abi::kPlxkAddr + 0x128u,        // 0x3007F128 duplicate-safe / ABI-rel
}};

struct PlxdDiscoveryResult {
    bool found = false;
    uint32_t phys_addr = 0;
    BankReleaseStatus status{};
    unsigned candidate_index = 0;
};

// mem_read64(phys, &word) must return true on a successful 64-bit LE read.
// Implementations should prefer a stable double-read when the bus can tear.
template <typename Read64>
inline PlxdDiscoveryResult discoverPlxdMailbox(Read64&& mem_read64) {
    PlxdDiscoveryResult out;
    for (unsigned i = 0; i < kPlxdCandidatePhys.size(); ++i) {
        const uint32_t phys = kPlxdCandidatePhys[i];
        uint64_t w0 = 0, w1 = 0;
        if (!mem_read64(phys, w0))
            continue;
        if (!mem_read64(phys, w1))
            continue;
        if (w0 != w1)
            continue; // torn — try next candidate / next call
        BankReleaseStatus st;
        if (!decodeBankReleaseWord(w0, st))
            continue;
        out.found = true;
        out.phys_addr = phys;
        out.status = st;
        out.candidate_index = i;
        return out;
    }
    return out;
}

// Non-template helper for tests: table-driven memory image.
inline PlxdDiscoveryResult discoverPlxdInImage(
    const uint64_t* words, const uint32_t* addrs, std::size_t n) {
    return discoverPlxdMailbox([&](uint32_t phys, uint64_t& word) -> bool {
        for (std::size_t i = 0; i < n; ++i) {
            if (addrs[i] == phys) {
                word = words[i];
                return true;
            }
        }
        return false; // unmapped → treated as absent
    });
}

} // namespace misterplex
