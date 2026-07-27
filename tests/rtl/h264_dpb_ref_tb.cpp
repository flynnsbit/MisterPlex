#include "Vh264_dpb_ref_tb_top.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {
constexpr uint32_t kBase = 0x30200000u;
constexpr uint32_t kBankStride = 0x80000u;
constexpr int kLumaW = 624;
constexpr int kLumaH = 480;
constexpr int kChromaW = 312;
constexpr int kChromaH = 240;
constexpr int kUOff = 299520;
constexpr int kVOff = 374400;
constexpr int kFrameBytes = 449280;
int fails = 0;

#define CHECK_MSG(cond, msg)                                                                       \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg);                   \
            ++fails;                                                                               \
        }                                                                                          \
    } while (0)

void tick(Vh264_dpb_ref_tb_top& top) {
    top.clk = 0;
    top.eval();
    top.clk = 1;
    top.eval();
}

int floorDivPow2(int v, int sh) {
    const int d = 1 << sh;
    if (v >= 0)
        return v / d;
    return -(((-v) + d - 1) / d);
}

int clampi(int v, int lo, int hi) { return std::max(lo, std::min(hi, v)); }

uint32_t addrFor(int bank, int plane, int x, int y) {
    uint32_t off = 0;
    if (plane == 0)
        off = static_cast<uint32_t>(y * kLumaW + x);
    else if (plane == 1)
        off = static_cast<uint32_t>(kUOff + y * kChromaW + x);
    else
        off = static_cast<uint32_t>(kVOff + y * kChromaW + x);
    return kBase + (bank ? kBankStride : 0) + off;
}

uint8_t refPixel(int plane, int x, int y, uint8_t seed) {
    if (plane == 0)
        return static_cast<uint8_t>(x * 3 + y * 5 + seed);
    if (plane == 1)
        return static_cast<uint8_t>(x * 7 + y * 11 + seed + 17);
    return static_cast<uint8_t>(x * 13 + y * 3 + seed + 29);
}

std::vector<uint8_t> readFile(const char* path) {
    std::ifstream in(path, std::ios::binary);
    CHECK_MSG(in.good(), "shared multi-NAL fixture missing");
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

size_t countAnnexBNals(const std::vector<uint8_t>& bytes) {
    size_t nals = 0;
    for (size_t i = 0; i + 3 < bytes.size(); ++i) {
        if (bytes[i] == 0 && bytes[i + 1] == 0 &&
            (bytes[i + 2] == 1 || (i + 3 < bytes.size() && bytes[i + 2] == 0 && bytes[i + 3] == 1))) {
            ++nals;
            if (bytes[i + 2] == 0)
                ++i;
        }
    }
    return nals;
}

void resetTop(Vh264_dpb_ref_tb_top& top) {
    top.reset = 1;
    top.wr_start = 0;
    top.fetch_start = 0;
    top.sample_valid = 0;
    tick(top);
    tick(top);
    top.reset = 0;
    tick(top);
}

void fillReference(std::vector<uint8_t>& mem, int bank, uint8_t seed) {
    const uint32_t bankOff = bank ? kBankStride : 0;
    for (int y = 0; y < kLumaH; ++y)
        for (int x = 0; x < kLumaW; ++x)
            mem[bankOff + y * kLumaW + x] = refPixel(0, x, y, seed);
    for (int y = 0; y < kChromaH; ++y) {
        for (int x = 0; x < kChromaW; ++x) {
            mem[bankOff + kUOff + y * kChromaW + x] = refPixel(1, x, y, seed);
            mem[bankOff + kVOff + y * kChromaW + x] = refPixel(2, x, y, seed);
        }
    }
}

bool expectedFetch(int index, int lqX, int lqY, int cqX, int cqY, int& plane, int& x, int& y) {
    if (index < 441) {
        plane = 0;
        const int local = index;
        x = clampi(floorDivPow2(lqX, 2) - 2 + (local % 21), 0, kLumaW - 1);
        y = clampi(floorDivPow2(lqY, 2) - 2 + (local / 21), 0, kLumaH - 1);
    } else if (index < 522) {
        plane = 1;
        const int local = index - 441;
        x = clampi(floorDivPow2(cqX, 3) + (local % 9), 0, kChromaW - 1);
        y = clampi(floorDivPow2(cqY, 3) + (local / 9), 0, kChromaH - 1);
    } else if (index < 603) {
        plane = 2;
        const int local = index - 522;
        x = clampi(floorDivPow2(cqX, 3) + (local % 9), 0, kChromaW - 1);
        y = clampi(floorDivPow2(cqY, 3) + (local / 9), 0, kChromaH - 1);
    } else {
        return false;
    }
    return true;
}

void runWriterCheck(Vh264_dpb_ref_tb_top& top, std::vector<uint8_t>& mem) {
    std::fill(mem.begin(), mem.end(), 0xA5);
    top.bank = 1;
    top.mb_x = 38;
    top.mb_y = 29;
    top.wr_start = 1;
    tick(top);
    top.wr_start = 0;

    int writes = 0;
    for (int cyc = 0; cyc < 600 && !top.wr_done; ++cyc) {
        tick(top);
        if (top.wr_valid) {
            CHECK_MSG(top.wr_addr >= kBase + kBankStride, "writer bank1 address below bank");
            const uint32_t off = top.wr_addr - kBase;
            CHECK_MSG(off < mem.size(), "writer address out of DPB range");
            mem[off] = top.wr_data;
            ++writes;
        }
    }
    CHECK_MSG(top.wr_done, "writer did not complete");
    CHECK_MSG(writes == 384, "writer did not emit 384 I420 samples");
    CHECK_MSG(mem[(kBankStride + addrFor(1, 0, 38 * 16, 29 * 16) - kBase) - kBankStride] != 0xA5,
              "writer left first luma sample stale");
    CHECK_MSG(mem[addrFor(1, 0, 623, 479) - kBase] != 0xA5, "writer missed bottom-right luma edge");
    CHECK_MSG(mem[addrFor(1, 1, 304, 232) - kBase] != 0xA5, "writer missed U plane");
    CHECK_MSG(mem[addrFor(1, 2, 311, 239) - kBase] != 0xA5, "writer missed V plane edge");
    CHECK_MSG(mem[addrFor(1, 0, 0, 0) - kBase] == 0xA5, "writer touched unrelated stale-poison area");
}

void runFetchCheck(Vh264_dpb_ref_tb_top& top, std::vector<uint8_t>& mem, bool edge) {
    const int bank = edge ? 0 : 1;
    const uint8_t seed = edge ? 0x31 : 0x5A;
    fillReference(mem, bank, seed);
    const int lqX = edge ? -3 : (123 * 4 + 2);
    const int lqY = edge ? -5 : (77 * 4 + 1);
    const int cqX = edge ? -7 : (61 * 8 + 3);
    const int cqY = edge ? -1 : (38 * 8 + 6);
    top.bank = bank;
    top.luma_x_qpel = lqX;
    top.luma_y_qpel = lqY;
    top.chroma_x_epel = cqX;
    top.chroma_y_epel = cqY;
    top.fetch_start = 1;
    top.sample_valid = 0;
    tick(top);
    top.fetch_start = 0;

    bool havePending = false;
    uint8_t pending = 0;
    int reqs = 0;
    int outs = 0;
    for (int cyc = 0; cyc < 5000 && !top.fetch_done; ++cyc) {
        top.sample_valid = havePending ? 1 : 0;
        top.sample_data = pending;
        havePending = false;
        tick(top);
        if (top.out_valid) {
            int plane = 0, x = 0, y = 0;
            CHECK_MSG(expectedFetch(top.out_index, lqX, lqY, cqX, cqY, plane, x, y), "bad output index");
            const uint8_t want = refPixel(plane, x, y, seed);
            if (top.out_sample != want) {
                std::fprintf(stderr, "FAIL fetch sample index=%u plane=%u got=%u want=%u (%s clamp)\n",
                             top.out_index, top.out_plane, top.out_sample, want,
                             edge ? "edge" : "center");
                ++fails;
            }
            ++outs;
        }
        if (top.req_valid) {
            int plane = 0, x = 0, y = 0;
            CHECK_MSG(expectedFetch(top.req_index, lqX, lqY, cqX, cqY, plane, x, y), "bad req index");
            const uint32_t wantAddr = addrFor(bank, plane, x, y);
            if (top.req_addr != wantAddr) {
                std::fprintf(stderr, "FAIL fetch addr index=%u plane=%u got=0x%08x want=0x%08x (%s clamp)\n",
                             top.req_index, top.req_plane, top.req_addr, wantAddr,
                             edge ? "edge" : "center");
                ++fails;
            }
            const uint32_t off = top.req_addr - kBase;
            CHECK_MSG(off < mem.size(), "fetch address out of DPB range");
            pending = (off < mem.size()) ? mem[off] : 0;
            havePending = true;
            ++reqs;
        }
    }
    top.sample_valid = havePending ? 1 : 0;
    top.sample_data = pending;
    tick(top);
    if (top.out_valid)
        ++outs;
    if (!top.fetch_done) {
        std::fprintf(stderr, "FAIL fetch did not complete reqs=%d outs=%d (%s clamp)\n",
                     reqs, outs, edge ? "edge" : "center");
        ++fails;
    }
    CHECK_MSG(reqs == 603, "fetch did not request 603 bordered samples");
    CHECK_MSG(outs >= 602, "fetch did not return bordered samples");
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const auto fixture = readFile("tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264");
    const size_t nals = countAnnexBNals(fixture);
    CHECK_MSG(nals >= 2, "DPB RTL gate requires a shared >=2-NAL fixture");
    const uint8_t seed = fixture.empty() ? 0 : fixture[fixture.size() / 2];
    (void)seed;

    Vh264_dpb_ref_tb_top top;
    std::vector<uint8_t> mem(kBankStride * 2, 0xA5);
    resetTop(top);
    runWriterCheck(top, mem);
    runFetchCheck(top, mem, false);
    runFetchCheck(top, mem, true);

    if (fails) {
        std::fprintf(stderr, "h264_dpb_ref RTL check FAILED: %d failures\n", fails);
        return 1;
    }
    std::printf("h264_dpb_ref RTL check PASS: fixture_nals=%zu writer_bytes=384 fetch_samples=603 edge_clamp=1 layout=I420_624x480\n",
                nals);
    return 0;
}
