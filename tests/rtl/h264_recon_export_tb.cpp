// h264_recon_export TB — prove pipe + handshake (not product scorer).
//
// Pre-register:
//   A) Feed real host-decoded I420 bytes (fixture prefix) as DPB commits →
//      published bank bit-identical to committed plane.
//   B) Mid-fill PLXO must not present ready on the bank being written.
//   C) frame_abort → torn or !ready; never a plausible complete frame.
//   D) Two frames → published banks alternate; reader never handed wr bank.
//   Mutation FAULT_EARLY_READY forges mid-fill ready → must go RED.
//
// Geometry 16x16 keeps sim short; content bytes come from real 320x240 golden.

#include "Vh264_recon_export_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr int kW = 16;
constexpr int kH = 16;
constexpr size_t kFrameBytes =
    static_cast<size_t>(kW) * static_cast<size_t>(kH) +
    2u * (static_cast<size_t>(kW / 2) * static_cast<size_t>(kH / 2));
constexpr uint32_t kPhysBase = 0x30200000u;
constexpr uint32_t kBankStride = 0x00040000u;
constexpr uint32_t kMboxPhys = 0x3007F130u;
constexpr uint32_t kMagic = 0x504C584Fu;

struct Plxo {
    uint32_t magic = 0;
    bool ready = false;
    bool torn = false;
    bool fmt = false;
    int bank = 0;
    uint16_t seq = 0;
};

class DdrModel {
public:
    void apply(bool we, uint32_t addr_q, uint64_t din, uint8_t be) {
        if (!we)
            return;
        uint64_t& cell = mem_[addr_q];
        for (int i = 0; i < 8; ++i) {
            if (be & (1u << i)) {
                const uint64_t mask = 0xFFull << (8 * i);
                cell = (cell & ~mask) | (din & mask);
            }
        }
    }

    uint64_t readQ(uint32_t addr_q) const {
        auto it = mem_.find(addr_q);
        return it == mem_.end() ? 0 : it->second;
    }

    Plxo readPlxo() const {
        const uint64_t w = readQ(kMboxPhys >> 3);
        Plxo p;
        p.magic = static_cast<uint32_t>(w & 0xffffffffu);
        const uint32_t hi = static_cast<uint32_t>(w >> 32);
        p.ready = (hi & 1u) != 0;
        p.bank = static_cast<int>((hi >> 1) & 1u);
        p.torn = ((hi >> 2) & 1u) != 0;
        p.fmt = ((hi >> 3) & 1u) != 0;
        p.seq = static_cast<uint16_t>((hi >> 16) & 0xffffu);
        return p;
    }

    bool readBank(int bank, uint8_t* dst, size_t n) const {
        if (bank < 0 || bank > 1 || n > kBankStride)
            return false;
        const uint32_t base = kPhysBase + static_cast<uint32_t>(bank) * kBankStride;
        for (size_t i = 0; i < n; ++i) {
            const uint32_t phys = base + static_cast<uint32_t>(i);
            const uint64_t q = readQ(phys >> 3);
            dst[i] = static_cast<uint8_t>((q >> (8 * (phys & 7u))) & 0xffu);
        }
        return true;
    }

    void clear() { mem_.clear(); }

private:
    std::unordered_map<uint32_t, uint64_t> mem_;
};

static void tick(Vh264_recon_export_tb_top& dut, DdrModel& ddr) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();  // posedge NBA: ddr_we/addr/din settle
    ddr.apply(dut.ddr_we, static_cast<uint32_t>(dut.ddr_addr),
              static_cast<uint64_t>(dut.ddr_din), static_cast<uint8_t>(dut.ddr_be));
}

static void idle(Vh264_recon_export_tb_top& dut, DdrModel& ddr, int n = 1) {
    dut.sample_valid = 0;
    dut.frame_start = 0;
    dut.frame_done = 0;
    dut.frame_abort = 0;
    for (int i = 0; i < n; ++i)
        tick(dut, ddr);
}

static bool loadRealDecodedPrefix(const char* path, std::vector<uint8_t>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        return false;
    out.assign(kFrameBytes, 0);
    f.read(reinterpret_cast<char*>(out.data()), static_cast<std::streamsize>(kFrameBytes));
    return static_cast<size_t>(f.gcount()) == kFrameBytes;
}

static void commitPlane(Vh264_recon_export_tb_top& dut, DdrModel& ddr,
                        const std::vector<uint8_t>& plane, bool abort_mid,
                        size_t abort_after, bool* mid_ready_on_wr_bank) {
    if (mid_ready_on_wr_bank)
        *mid_ready_on_wr_bank = false;

    dut.frame_start = 1;
    tick(dut, ddr);
    dut.frame_start = 0;

    for (size_t i = 0; i < plane.size(); ++i) {
        if (abort_mid && i == abort_after) {
            dut.frame_abort = 1;
            tick(dut, ddr);
            dut.frame_abort = 0;
        }
        dut.sample_valid = 1;
        dut.sample_off = static_cast<uint32_t>(i);
        dut.sample_data = plane[i];
        tick(dut, ddr);
        dut.sample_valid = 0;

        if (mid_ready_on_wr_bank && i == plane.size() / 2) {
            // Drain a few cycles so any forged mbox write lands.
            idle(dut, ddr, 4);
            const Plxo m = ddr.readPlxo();
            const int wr = dut.dbg_wr_bank ? 1 : 0;
            if (m.magic == kMagic && m.ready && !m.torn && m.bank == wr)
                *mid_ready_on_wr_bank = true;
        }
        // Occasional idle to let DDR drain pending beats under backpressure=0
        if ((i & 7u) == 7u)
            idle(dut, ddr, 1);
    }

    dut.frame_done = 1;
    tick(dut, ddr);
    dut.frame_done = 0;

    // Drain flush + mailbox
    for (int guard = 0; guard < 100000; ++guard) {
        tick(dut, ddr);
        if (!dut.busy && !dut.ddr_want)
            break;
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const char* golden_path =
        "tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv";
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--golden" && i + 1 < argc)
            golden_path = argv[++i];
    }

    std::vector<uint8_t> plane;
    if (!loadRealDecodedPrefix(golden_path, plane)) {
        std::cerr << "FAIL recon_export: cannot load real decoded prefix from " << golden_path
                  << "\n";
        return 2;
    }
    // Second frame: invert luma-ish bytes so bank contents differ (still real-derived).
    std::vector<uint8_t> plane2 = plane;
    for (size_t i = 0; i < plane2.size(); ++i)
        plane2[i] = static_cast<uint8_t>(plane2[i] ^ 0x5Au);

    Vh264_recon_export_tb_top dut;
    DdrModel ddr;

    dut.ddr_busy = 0;
    dut.ddr_dout = 0;
    dut.ddr_dout_ready = 0;
    dut.reset = 1;
    idle(dut, ddr, 4);
    dut.reset = 0;
    idle(dut, ddr, 4);

    int failures = 0;
    auto fail = [&](const char* msg) {
        std::cerr << "FAIL recon_export: " << msg << "\n";
        ++failures;
    };

    // --- A + B: commit real decoded bytes; mid-fill must not ready wr bank ---
    bool mid_bad = false;
    commitPlane(dut, ddr, plane, /*abort_mid=*/false, 0, &mid_bad);
    if (mid_bad)
        fail("mid-fill PLXO ready on wr bank (torn-frame hole)");

    Plxo m0 = ddr.readPlxo();
    if (m0.magic != kMagic)
        fail("frame0 PLXO magic");
    if (!m0.ready || m0.torn)
        fail("frame0 expected ready=1 torn=0");
    if (!m0.fmt)
        fail("frame0 fmt_yuv");

    std::vector<uint8_t> got(kFrameBytes);
    if (!ddr.readBank(m0.bank, got.data(), got.size()))
        fail("frame0 bank read");
    else if (std::memcmp(got.data(), plane.data(), kFrameBytes) != 0)
        fail("frame0 bank != DPB-committed real decoded bytes");

    const int bank0 = m0.bank;
    const uint16_t seq0 = m0.seq;
    if (dut.frames_exported < 1)
        fail("frames_exported not advanced");

    // --- D start: second frame must use the other bank; mid-fill keeps pub bank ---
    mid_bad = false;
    const int wr_before = dut.dbg_wr_bank ? 1 : 0;
    commitPlane(dut, ddr, plane2, /*abort_mid=*/false, 0, &mid_bad);
    if (mid_bad)
        fail("frame1 mid-fill PLXO ready on wr bank");

    Plxo m1 = ddr.readPlxo();
    if (!m1.ready || m1.torn)
        fail("frame1 expected ready=1 torn=0");
    if (m1.bank == bank0)
        fail("bank alternation broken (same pub bank twice)");
    if (m1.seq == seq0)
        fail("seq did not advance");
    if (!ddr.readBank(m1.bank, got.data(), got.size()) ||
        std::memcmp(got.data(), plane2.data(), kFrameBytes) != 0)
        fail("frame1 bank != committed plane2");
    // Old bank must still hold plane0 (not overwritten while writing plane2)
    if (!ddr.readBank(bank0, got.data(), got.size()) ||
        std::memcmp(got.data(), plane.data(), kFrameBytes) != 0)
        fail("previous bank corrupted during alternate fill");
    (void)wr_before;

    // --- C: abort mid-frame must not publish a plausible complete frame ---
    ddr.clear();
    // Re-init mailbox empty after clear — reset DUT lightly via abort path only
    bool mid_unused = false;
    commitPlane(dut, ddr, plane, /*abort_mid=*/true, kFrameBytes / 4, &mid_unused);
    Plxo ma = ddr.readPlxo();
    if (ma.magic == kMagic && ma.ready && !ma.torn) {
        // If ready, bank must NOT be bit-identical to full plane (would be silent-wrong).
        if (ddr.readBank(ma.bank, got.data(), got.size()) &&
            std::memcmp(got.data(), plane.data(), kFrameBytes) == 0) {
            fail("abort path published ready complete frame (silent wrong)");
        } else {
            fail("abort path published ready=1 torn=0 (reader could accept torn frame)");
        }
    }
    // Product expectation: torn sticky publish or !ready
    if (ma.magic == kMagic && ma.ready && !ma.torn)
        ; // already failed
    else if (ma.magic == kMagic && ma.torn && ma.ready)
        fail("abort: torn=1 must not set ready=1");
    // Acceptable: magic missing, or ready=0, or torn=1 && ready=0
    if (ma.magic == kMagic && !ma.ready && ma.torn) {
        // good
    } else if (ma.magic != kMagic) {
        // good — never published
    } else if (ma.magic == kMagic && !ma.ready) {
        // good
    }

    if (failures) {
        std::cerr << "FAIL h264_recon_export: " << failures << " check(s)\n";
        return 1;
    }
    std::cout << "OK h264_recon_export: bit_identical_real_decoded=1 "
              << "mid_fill_guard=1 bank_alt=1 abort_fail_closed=1 "
              << "bytes=" << kFrameBytes << " bank0=" << bank0 << " bank1=" << m1.bank
              << " seq=" << seq0 << "->" << m1.seq << "\n";
    return 0;
}
