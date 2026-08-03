#pragma once
// Behavioral model of plex_chrome_ddr_loader.sv — lockstep with RTL.

#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/plex_chrome_cmds.hpp"

#include <cstdint>
#include <cstring>
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

// One-shot: if mem[PLXC] has new seq+magic, emit host beats (list then ctrl).
// Also writes PLXO into mem when requested.
inline void stepLoad(Model& m, uint64_t* mem /* sparse qword array indexed by offset/8 */,
                     bool write_plxo, bool chrome_hw, uint16_t mon_w, uint16_t mon_h,
                     uint8_t mon_scale) {
    if (!m.enable)
        return;
    if (write_plxo) {
        const size_t o = mailbox_abi::kPlxoOffset / 8;
        m.last_plxo = packPlxo(chrome_hw, mon_w, mon_h, mon_scale);
        mem[o] = m.last_plxo;
        m.cnt_plxo++;
    }
    const size_t c = mailbox_abi::kPlxcOffset / 8;
    const uint64_t ctrl = mem[c];
    if (static_cast<uint32_t>(ctrl) != mailbox_abi::kPlxcMagic) {
        m.cnt_bad++;
        return;
    }
    const uint16_t seq = static_cast<uint16_t>(ctrl >> 48);
    if (seq == m.last_seq)
        return;
    unsigned count = static_cast<unsigned>((ctrl >> 34) & 0x3FFFu);
    if (count > static_cast<unsigned>(plex_chrome_cmds::kMaxCmds))
        count = static_cast<unsigned>(plex_chrome_cmds::kMaxCmds);
    const size_t base = mailbox_abi::kPlxlOffset / 8;
    m.beats.clear();
    for (unsigned i = 0; i < count; ++i)
        m.beats.push_back(HostBeat{static_cast<uint8_t>(i), mem[base + i]});
    m.beats.push_back(HostBeat{0xFF, ctrl});
    m.last_seq = seq;
    m.cnt_loads++;
}

// Red case: ENABLE=0 must never emit beats even if PLXC changes.
inline bool enableOffIsQuiet(const Model& m) { return !m.enable && m.beats.empty() && m.cnt_loads == 0; }

} // namespace plex_chrome_ddr
} // namespace misterplex
