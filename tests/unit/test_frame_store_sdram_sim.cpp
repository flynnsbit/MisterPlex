#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {
constexpr int kWidth = 320;
constexpr int kHeight = 240;
constexpr int kLines = 4;
constexpr int kPixels = kWidth * kHeight;

uint32_t word_addr(int bank, int row, int col) {
    return static_cast<uint32_t>(bank * kPixels + row * kWidth + col);
}

uint16_t pattern(int bank, int row, int col) {
    return static_cast<uint16_t>((bank ? 0x8000 : 0x1000) ^ (row * kWidth + col));
}

struct Line {
    bool valid = false;
    int bank = -1;
    int y = -1;
    std::array<uint16_t, kWidth> pix{};
};

using Memory = std::vector<uint16_t>;

void fill_memory(Memory& mem) {
    mem.assign(kPixels * 2, 0);
    for (int bank = 0; bank < 2; ++bank) {
        for (int y = 0; y < kHeight; ++y) {
            for (int x = 0; x < kWidth; ++x) {
                const uint32_t wr = word_addr(bank, y, x);
                const uint32_t rd = static_cast<uint32_t>(bank * kPixels + y * kWidth + x);
                if (wr != rd) {
                    std::fprintf(stderr, "address formula mismatch bank=%d y=%d x=%d wr=%u rd=%u\n",
                                 bank, y, x, wr, rd);
                    std::exit(1);
                }
                mem[wr] = pattern(bank, y, x);
            }
        }
    }
}

void load_line(Line& line, const Memory& mem, int bank, int y) {
    line.valid = true;
    line.bank = bank;
    line.y = y;
    for (int x = 0; x < kWidth; ++x)
        line.pix[x] = mem[word_addr(bank, y, x)];
}

// Models the rejected RTL ownership rule:
//   read_bank_sys = swap_pending ? ~disp_bank : disp_bank
// with one unbanked line-buffer set. As soon as a back buffer completes, the
// prefetcher repurposes the live scanout buffer before the vsync page flip.
int simulate_broken_single_set(const Memory& mem) {
    std::array<Line, kLines> lines;
    int disp_bank = 0;
    bool swap_pending = false;
    int mismatches = 0;

    for (int y = 0; y < kHeight; ++y) {
        if (y == 120) {
            swap_pending = true;
            for (auto& line : lines)
                line.valid = false;
        }
        const int prefetch_bank = swap_pending ? !disp_bank : disp_bank;
        for (int ahead = 0; ahead < kLines; ++ahead) {
            const int ly = (y + ahead < kHeight) ? (y + ahead) : (kHeight - 1);
            load_line(lines[ahead], mem, prefetch_bank, ly);
        }
        for (int x = 0; x < kWidth; ++x) {
            const auto& line = lines[0];
            const uint16_t got = (line.valid && line.y == y) ? line.pix[x] : 0;
            const uint16_t want = pattern(disp_bank, y, x);
            if (got != want)
                ++mismatches;
        }
    }
    return mismatches;
}

int simulate_fixed_dual_set(const Memory& mem) {
    std::array<std::array<Line, kLines>, 2> sets;
    int disp_bank = 0;
    int disp_set = 0;
    bool swap_pending = false;
    int mismatches = 0;

    for (int y = 0; y < kHeight; ++y) {
        if (y == 120)
            swap_pending = true;

        for (int ahead = 0; ahead < kLines; ++ahead) {
            const int ly = (y + ahead < kHeight) ? (y + ahead) : (kHeight - 1);
            load_line(sets[disp_set][ahead], mem, disp_bank, ly);
        }
        if (swap_pending) {
            const int prep_set = !disp_set;
            for (int ahead = 0; ahead < kLines; ++ahead)
                load_line(sets[prep_set][ahead], mem, !disp_bank, ahead);
        }
        for (int x = 0; x < kWidth; ++x) {
            const auto& line = sets[disp_set][0];
            const uint16_t got = (line.valid && line.bank == disp_bank && line.y == y) ? line.pix[x] : 0;
            const uint16_t want = pattern(disp_bank, y, x);
            if (got != want)
                ++mismatches;
        }
    }

    if (swap_pending) {
        disp_bank = !disp_bank;
        disp_set = !disp_set;
        swap_pending = false;
    }

    for (int y = 0; y < kHeight; ++y) {
        for (int ahead = 0; ahead < kLines; ++ahead) {
            const int ly = (y + ahead < kHeight) ? (y + ahead) : (kHeight - 1);
            load_line(sets[disp_set][ahead], mem, disp_bank, ly);
        }
        for (int x = 0; x < kWidth; ++x) {
            const auto& line = sets[disp_set][0];
            const uint16_t got = (line.valid && line.bank == disp_bank && line.y == y) ? line.pix[x] : 0;
            const uint16_t want = pattern(disp_bank, y, x);
            if (got != want)
                ++mismatches;
        }
    }
    return mismatches;
}
} // namespace

int main() {
    Memory mem;
    fill_memory(mem);

    const int broken_mismatches = simulate_broken_single_set(mem);
    const int fixed_mismatches = simulate_fixed_dual_set(mem);
    if (broken_mismatches == 0) {
        std::fprintf(stderr, "expected rejected single-buffer ownership to corrupt scanout\n");
        return 1;
    }
    if (fixed_mismatches != 0) {
        std::fprintf(stderr, "fixed dual-buffer ownership mismatches=%d\n", fixed_mismatches);
        return 1;
    }
    std::printf("test_frame_store_sdram_sim: OK (reproduced %d old-bank/new-bank mismatches; fixed path clean)\n",
                broken_mismatches);
    return 0;
}
