#include "Vh264_decode_core_wb_tb.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>
#include <vector>

namespace {

constexpr int FRAME_W = 64;
constexpr int FRAME_H = 32;
constexpr int MB_W = FRAME_W / 16;
constexpr int MB_H = FRAME_H / 16;
constexpr int Y_BYTES = FRAME_W * FRAME_H;
constexpr int C_W = FRAME_W / 2;
constexpr int C_BYTES = C_W * (FRAME_H / 2);
constexpr uint32_t BASE = 0x1000;

struct Write {
    uint32_t addr = 0;
    uint8_t data = 0;
};

struct Sim {
    Vh264_decode_core_wb_tb top{};
    uint64_t cycles = 0;
    std::vector<Write> writes;
    bool frameDoneSeen = false;

    void tick() {
        top.clk = 0;
        top.eval();
        top.clk = 1;
        top.eval();
        if (top.dpb_wr_en) {
            writes.push_back({top.dpb_wr_addr, static_cast<uint8_t>(top.dpb_wr_data)});
        }
        if (top.frame_done) frameDoneSeen = true;
        top.clk = 0;
        top.eval();
        ++cycles;
    }
};

uint8_t ySample(int i) { return static_cast<uint8_t>((0x61 + i * 3) & 0xff); }
uint8_t uSample(int i) { return static_cast<uint8_t>((0xa0 + i * 5) & 0xff); }
uint8_t vSample(int i) { return static_cast<uint8_t>((0x30 + i * 7) & 0xff); }

uint32_t expectedAddr(int mbX, int mbY, int idx) {
    if (idx < 256) {
        const int sx = idx & 15;
        const int sy = idx >> 4;
        return BASE + static_cast<uint32_t>((mbY * 16 + sy) * FRAME_W + (mbX * 16 + sx));
    }
    if (idx < 320) {
        const int rel = idx - 256;
        const int sx = rel & 7;
        const int sy = rel >> 3;
        return BASE + Y_BYTES + static_cast<uint32_t>((mbY * 8 + sy) * C_W + (mbX * 8 + sx));
    }
    const int rel = idx - 320;
    const int sx = rel & 7;
    const int sy = rel >> 3;
    return BASE + Y_BYTES + C_BYTES +
           static_cast<uint32_t>((mbY * 8 + sy) * C_W + (mbX * 8 + sx));
}

uint8_t expectedData(int idx) {
    if (idx < 256) return ySample(idx);
    if (idx < 320) return uSample(idx - 256);
    return vSample(idx - 320);
}

void reset(Sim& s) {
    s.top.reset = 1;
    s.top.slice_start = 0;
    s.top.recon_mb_valid = 0;
    s.top.recon_mb_x = 0;
    s.top.recon_mb_y = 0;
    s.top.recon_mb_is_ref = 0;
    s.top.dpb_write_base = BASE;
    for (int i = 0; i < 256; ++i) s.top.recon_y[i] = 0;
    for (int i = 0; i < 64; ++i) {
        s.top.recon_u[i] = 0;
        s.top.recon_v[i] = 0;
    }
    s.tick();
    s.tick();
    s.top.reset = 0;
    s.tick();
}

void driveMb(Sim& s, int mbX, int mbY, bool isRef) {
    for (int i = 0; i < 256; ++i) s.top.recon_y[i] = ySample(i);
    for (int i = 0; i < 64; ++i) {
        s.top.recon_u[i] = uSample(i);
        s.top.recon_v[i] = vSample(i);
    }
    s.top.recon_mb_x = mbX;
    s.top.recon_mb_y = mbY;
    s.top.recon_mb_is_ref = isRef ? 1 : 0;
    s.top.dpb_write_base = BASE;
    s.top.recon_mb_valid = 1;
    s.tick();
    s.top.recon_mb_valid = 0;
}

bool waitForIdle(Sim& s) {
    for (int i = 0; i < 4000; ++i) {
        if (!s.top.busy && !s.top.recon_mb_valid) return true;
        s.tick();
    }
    return false;
}

// Deblock identity path emits AFTER the core leaves ST_WRITE (and often after
// busy clears for non-terminal MBs). Wait for the DPB write count, not busy.
bool waitForWrites(Sim& s, std::size_t want) {
    for (int i = 0; i < 8000; ++i) {
        if (s.writes.size() >= want) return true;
        s.tick();
    }
    return false;
}

int checkMbWrites(const std::vector<Write>& writes, std::size_t start, int mbX, int mbY) {
    if (writes.size() < start + 384) {
        std::cerr << "FAIL h264_decode_core writeback scoreboard: write count "
                  << (writes.size() - start) << " < 384\n";
        return 1;
    }
    for (int i = 0; i < 384; ++i) {
        const Write& w = writes.at(start + static_cast<std::size_t>(i));
        const uint32_t wantAddr = expectedAddr(mbX, mbY, i);
        const uint8_t wantData = expectedData(i);
        if (w.addr != wantAddr || w.data != wantData) {
            std::cerr << "FAIL h264_decode_core writeback scoreboard: idx=" << i
                      << " got_addr=0x" << std::hex << w.addr
                      << " want_addr=0x" << wantAddr << std::dec
                      << " got_data=" << int(w.data)
                      << " want_data=" << int(wantData) << "\n";
            return 1;
        }
    }
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Sim s;
    reset(s);

    driveMb(s, 1, 0, true);
    if (!waitForWrites(s, 384)) {
        std::cerr << "FAIL h264_decode_core writeback scoreboard: first MB write count "
                  << s.writes.size() << " < 384 (busy=" << int(s.top.busy) << ")\n";
        return 1;
    }
    if (!waitForIdle(s)) {
        std::cerr << "FAIL h264_decode_core writeback scoreboard: first MB did not return idle\n";
        return 1;
    }
    int rc = checkMbWrites(s.writes, 0, 1, 0);
    if (rc) return rc;
    if (s.frameDoneSeen) {
        std::cerr << "FAIL h264_decode_core writeback scoreboard: nonterminal MB asserted frame_done\n";
        return 1;
    }

    const std::size_t secondStart = s.writes.size();
    driveMb(s, MB_W - 1, MB_H - 1, true);
    if (!waitForWrites(s, secondStart + 384)) {
        std::cerr << "FAIL h264_decode_core writeback scoreboard: second MB write count "
                  << (s.writes.size() - secondStart) << " < 384\n";
        return 1;
    }
    for (int i = 0; i < 4000 && !s.frameDoneSeen; ++i) s.tick();
    rc = checkMbWrites(s.writes, secondStart, MB_W - 1, MB_H - 1);
    if (rc) return rc;
    if (!s.frameDoneSeen) {
        std::cerr << "FAIL h264_decode_core writeback scoreboard: terminal MB did not assert frame_done\n";
        return 1;
    }
    if (s.top.frame_mb_count != 2) {
        std::cerr << "FAIL h264_decode_core writeback scoreboard: frame_mb_count="
                  << int(s.top.frame_mb_count) << " want=2\n";
        return 1;
    }
    std::cout << "Scope: decode_core_writeback_mbs=2/" << (MB_W * MB_H)
              << " samples=768 frame_done_seen=1\n";
    std::cout << "OK h264_decode_core writeback scoreboard: 2 MBs, 768 native-I420 samples "
              << "landed at DPB addresses; terminal frame_done observed\n";
    return 0;
}
