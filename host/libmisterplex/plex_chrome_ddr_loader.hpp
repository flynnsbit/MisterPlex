#pragma once
// Behavioral model of plex_chrome_ddr_loader.sv — lockstep with RTL.
// PLXC seqlock: invalidate magic → body → ctrl; loader re-reads ctrl after body.

#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/plex_chrome_cmds.hpp"

#include <cstdint>
#include <functional>
#include <vector>

namespace misterplex {
namespace plex_chrome_ddr {

inline constexpr uint32_t kDoor = mailbox_abi::kLegacyFrameStoreDoorbellPhys;

struct HostBeat {
    uint8_t addr = 0;
    uint64_t data = 0;
};

struct Model {
    bool enable = false;
    uint16_t last_seq = 0;
    uint32_t cnt_loads = 0;
    uint32_t cnt_plxo = 0;
    uint32_t cnt_bad = 0;
    uint32_t cnt_torn = 0;
    std::vector<HostBeat> beats;
    uint64_t last_plxo = 0;
};

inline uint64_t packPlxo(bool hw, uint16_t w, uint16_t h, uint8_t scale) {
    // Match RTL pack_plxo: [31:0] magic, [32] hw, [44:33] w, [56:45] h, [60:57] sc
    uint64_t q = mailbox_abi::kPlxoMagic;
    if (hw)
        q |= 1ull << 32;
    q |= (static_cast<uint64_t>(w & 0xFFFu) << 33);
    q |= (static_cast<uint64_t>(h & 0xFFFu) << 45);
    q |= (static_cast<uint64_t>(scale & 0xFu) << 57);
    return q;
}

// Host-side seqlock publish into a qword-indexed mailbox image (tests).
inline void hostPublishSeqlock(uint64_t* mem, const uint64_t* cmds, unsigned n, bool enable,
                               uint16_t seq) {
    const size_t c = mailbox_abi::kPlxcOffset / 8;
    const size_t base = mailbox_abi::kPlxlOffset / 8;
    if (n > static_cast<unsigned>(plex_chrome_cmds::kMaxCmds))
        n = static_cast<unsigned>(plex_chrome_cmds::kMaxCmds);
    mem[c] = 0; // invalidate magic first
    for (unsigned i = 0; i < n; ++i)
        mem[base + i] = cmds[i];
    mem[c] = plex_chrome_cmds::packPlxcCtrl(enable, n, seq);
}

// Legacy broken host: body while old ctrl still valid, then new ctrl.
inline void hostPublishUnsafeBodyFirst(uint64_t* mem, const uint64_t* cmds, unsigned n,
                                       bool enable, uint16_t seq) {
    const size_t c = mailbox_abi::kPlxcOffset / 8;
    const size_t base = mailbox_abi::kPlxlOffset / 8;
    if (n > static_cast<unsigned>(plex_chrome_cmds::kMaxCmds))
        n = static_cast<unsigned>(plex_chrome_cmds::kMaxCmds);
    for (unsigned i = 0; i < n; ++i)
        mem[base + i] = cmds[i];
    mem[c] = plex_chrome_cmds::packPlxcCtrl(enable, n, seq);
}

// One-shot load with ctrl re-read (product). Returns true if committed.
// mid_body: optional mutator after body snapshot, before ctrl re-read.
inline bool stepLoad(Model& m, uint64_t* mem, bool write_plxo, bool chrome_hw, uint16_t mon_w,
                     uint16_t mon_h, uint8_t mon_scale,
                     const std::function<void(uint64_t*)>& mid_body = {}) {
    if (!m.enable)
        return false;
    if (write_plxo) {
        const size_t o = mailbox_abi::kPlxoOffset / 8;
        m.last_plxo = packPlxo(chrome_hw, mon_w, mon_h, mon_scale);
        mem[o] = m.last_plxo;
        m.cnt_plxo++;
    }
    const size_t c = mailbox_abi::kPlxcOffset / 8;
    const uint64_t ctrl0 = mem[c];
    if (static_cast<uint32_t>(ctrl0) != mailbox_abi::kPlxcMagic) {
        m.cnt_bad++;
        return false;
    }
    const uint16_t seq = static_cast<uint16_t>(ctrl0 >> 48);
    if (seq == m.last_seq)
        return false;
    unsigned count = static_cast<unsigned>((ctrl0 >> 34) & 0x3FFFu);
    if (count > static_cast<unsigned>(plex_chrome_cmds::kMaxCmds))
        count = static_cast<unsigned>(plex_chrome_cmds::kMaxCmds);
    const size_t base = mailbox_abi::kPlxlOffset / 8;
    std::vector<HostBeat> body;
    body.reserve(count + 1);
    for (unsigned i = 0; i < count; ++i)
        body.push_back(HostBeat{static_cast<uint8_t>(i), mem[base + i]});

    if (mid_body)
        mid_body(mem);

#if defined(PLEX_CHROME_LOADER_FAULT_NO_REREAD)
    // Red twin: commit without re-read (accepts torn body).
#else
    const uint64_t ctrl1 = mem[c];
    if (static_cast<uint32_t>(ctrl1) != mailbox_abi::kPlxcMagic || ctrl1 != ctrl0) {
        m.cnt_torn++;
        return false; // do not update last_seq
    }
#endif

    m.beats = std::move(body);
    m.beats.push_back(HostBeat{0xFF, ctrl0});
    m.last_seq = seq;
    m.cnt_loads++;
    return true;
}

inline bool enableOffIsQuiet(const Model& m) {
    return !m.enable && m.beats.empty() && m.cnt_loads == 0;
}

} // namespace plex_chrome_ddr
} // namespace misterplex
