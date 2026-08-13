#include "Vsource_aspect_ingest_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdio>

namespace {

void tick(Vsource_aspect_ingest_tb_top& top) {
    top.clk = 0;
    top.eval();
    top.clk = 1;
    top.eval();
}

std::array<uint8_t, 9> packet(uint16_t x, uint16_t y, uint8_t token = 1,
                              bool validMagic = true) {
    return {
        static_cast<uint8_t>(validMagic ? 'P' : 'X'),
        static_cast<uint8_t>('L'),
        static_cast<uint8_t>('X'),
        static_cast<uint8_t>('A'),
        static_cast<uint8_t>(x & 0xFF),
        static_cast<uint8_t>(x >> 8),
        static_cast<uint8_t>(y & 0xFF),
        static_cast<uint8_t>(y >> 8),
        token,
    };
}

void send(Vsource_aspect_ingest_tb_top& top, const std::array<uint8_t, 9>& bytes,
          int count = 9, bool enable = true) {
    top.enable = enable;
    top.ioctl_download = 1;
    top.ioctl_wr = 0;
    tick(top);
    for (int i = 0; i < count; ++i) {
        top.ioctl_addr = i;
        top.ioctl_dout = bytes[static_cast<size_t>(i)];
        top.ioctl_wr = 1;
        tick(top);
    }
    top.ioctl_wr = 0;
    top.ioctl_download = 0;
    tick(top);
}

bool expect(const Vsource_aspect_ingest_tb_top& top, bool valid, int x, int y,
            int token, bool commit, const char* label) {
    if (top.aspect_valid == valid && top.aspect_x == x && top.aspect_y == y &&
        top.aspect_token == token && top.aspect_commit == commit)
        return true;
    std::fprintf(stderr, "FAIL %s valid=%d x=%u y=%u token=%u commit=%d\n", label,
                 static_cast<int>(top.aspect_valid), top.aspect_x, top.aspect_y,
                 top.aspect_token, static_cast<int>(top.aspect_commit));
    return false;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vsource_aspect_ingest_tb_top top;
    top.reset = 1;
    top.ioctl_download = 0;
    top.ioctl_wr = 0;
    top.ioctl_addr = 0;
    top.ioctl_dout = 0;
    top.enable = 0;
    tick(top);
    top.reset = 0;
    tick(top);

    bool ok = expect(top, false, 4, 3, 0, false, "reset fallback");

    send(top, packet(16, 9, 7));
    ok &= expect(top, true, 16, 9, 7, true, "16:9 commit");
    tick(top);
    ok &= expect(top, true, 16, 9, 7, false, "commit is one pulse");

    send(top, packet(4, 3, 8), 4);
    ok &= expect(top, true, 16, 9, 7, false, "incomplete packet retained prior DAR");

    send(top, packet(4, 3, 8, false));
    ok &= expect(top, true, 16, 9, 7, false, "bad magic retained prior DAR");

    send(top, packet(0, 9));
    ok &= expect(top, true, 16, 9, 7, false, "zero DAR retained prior DAR");

    send(top, packet(47, 20, 9), 9, false);
    ok &= expect(top, true, 16, 9, 7, false, "disabled index retained prior DAR");

    send(top, packet(47, 20, 9));
    ok &= expect(top, true, 47, 20, 9, true, "custom DAR commit");

    send(top, packet(4095, 1, 10));
    ok &= expect(top, true, 47, 20, 9, false, "extreme DAR rejected");

    if (!ok)
        return 1;
    std::puts("PASS source aspect packets commit atomically and reject invalid updates");
    return 0;
}
