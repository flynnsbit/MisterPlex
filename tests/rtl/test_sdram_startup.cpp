#include "Vsdram_startup_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

enum class Cmd {
    CkeLow,
    Deselect,
    Nop,
    Active,
    Read,
    Write,
    Precharge,
    AutoRefresh,
    ModeRegisterSet,
    Other,
};

struct Event {
    uint64_t cycle;
    Cmd cmd;
    bool injected;
};

const char* name(Cmd cmd) {
    switch (cmd) {
    case Cmd::CkeLow: return "CKE_LOW";
    case Cmd::Deselect: return "DESELECT";
    case Cmd::Nop: return "NOP";
    case Cmd::Active: return "ACTIVE";
    case Cmd::Read: return "READ";
    case Cmd::Write: return "WRITE";
    case Cmd::Precharge: return "PRECHARGE";
    case Cmd::AutoRefresh: return "AUTO_REFRESH";
    case Cmd::ModeRegisterSet: return "MODE_REGISTER_SET";
    case Cmd::Other: return "OTHER";
    }
    return "OTHER";
}

Cmd decode(bool cke, bool ncs, bool nras, bool ncas, bool nwe) {
    if (!cke) return Cmd::CkeLow;
    if (ncs) return Cmd::Deselect;
    const unsigned bits = (static_cast<unsigned>(nras) << 2) |
                          (static_cast<unsigned>(ncas) << 1) |
                          static_cast<unsigned>(nwe);
    switch (bits) {
    case 0b111: return Cmd::Nop;
    case 0b011: return Cmd::Active;
    case 0b101: return Cmd::Read;
    case 0b100: return Cmd::Write;
    case 0b010: return Cmd::Precharge;
    case 0b001: return Cmd::AutoRefresh;
    case 0b000: return Cmd::ModeRegisterSet;
    default: return Cmd::Other;
    }
}

bool is_data_command(Cmd cmd) {
    return cmd == Cmd::Active || cmd == Cmd::Read || cmd == Cmd::Write;
}

void tick(Vsdram_startup_top& top, uint64_t& cycle) {
    top.clk = 0;
    top.eval();
    top.clk = 1;
    top.eval();
    ++cycle;
    top.clk = 0;
    top.eval();
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    bool inject_early_read = false;
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--inject-early-read") {
            inject_early_read = true;
        }
    }

    Vsdram_startup_top top;
    uint64_t cycle = 0;
    int64_t reset_release_cycle = -1;
    bool saw_mrs = false;
    bool violation = false;
    uint64_t violation_cycle = 0;
    Cmd violation_cmd = Cmd::Other;
    int64_t first_ready_cycle = -1;
    int64_t first_request_cycle = -1;
    std::vector<Event> events;

    top.reset = 1;
    top.pll_locked = 0;
    for (int i = 0; i < 8; ++i) tick(top, cycle);

    top.reset = 0;
    top.pll_locked = 1;
    reset_release_cycle = static_cast<int64_t>(cycle);

    constexpr uint64_t max_cycles = 13050;
    for (; cycle < max_cycles; ) {
        tick(top, cycle);

        bool cke = top.SDRAM_CKE;
        bool ncs = top.SDRAM_nCS;
        bool nras = top.SDRAM_nRAS;
        bool ncas = top.SDRAM_nCAS;
        bool nwe = top.SDRAM_nWE;
        bool injected = false;

        if (inject_early_read &&
            reset_release_cycle >= 0 &&
            cycle == static_cast<uint64_t>(reset_release_cycle + 10)) {
            ncs = false;
            nras = true;
            ncas = false;
            nwe = true;
            injected = true;
        }

        const Cmd cmd = decode(cke, ncs, nras, ncas, nwe);
        if (first_ready_cycle < 0 && top.sdram_ready) {
            first_ready_cycle = static_cast<int64_t>(cycle);
        }
        if (first_request_cycle < 0 && top.sdram_sel && (top.sdram_rd || top.sdram_wr)) {
            first_request_cycle = static_cast<int64_t>(cycle);
        }
        if (cmd != Cmd::Nop && cmd != Cmd::Deselect) {
            if (events.size() < 40) {
                events.push_back(Event{cycle, cmd, injected});
            }
            if (cmd == Cmd::ModeRegisterSet) {
                saw_mrs = true;
            }
            if (!saw_mrs && is_data_command(cmd) && !violation) {
                violation = true;
                violation_cycle = cycle;
                violation_cmd = cmd;
            }
        }
    }

    std::cout << "SDRAM startup command trace (first " << events.size()
              << " non-NOP/non-DESELECT commands after reset release at cycle "
              << reset_release_cycle << ")\n";
    for (const auto& e : events) {
        std::cout << "  cycle " << e.cycle << ": " << name(e.cmd);
        if (e.injected) std::cout << " [INJECTED]";
        std::cout << "\n";
    }
    std::cout << "First sdram_ready observed at cycle " << first_ready_cycle << "\n";
    std::cout << "First memtest sel+(rd|wr) observed at cycle " << first_request_cycle << "\n";

    if (!saw_mrs) {
        std::cerr << "FAIL: no MODE_REGISTER_SET observed before timeout\n";
        return 2;
    }
    if (violation) {
        std::cerr << "FAIL: " << name(violation_cmd)
                  << " before first MODE_REGISTER_SET at cycle "
                  << violation_cycle << "\n";
        return 1;
    }

    std::cout << "PASS: no ACTIVE/READ/WRITE before first MODE_REGISTER_SET\n";
    return 0;
}
