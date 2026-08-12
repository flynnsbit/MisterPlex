#pragma once

#include "libmisterplex/idle_screen.hpp"

#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace true480 {

constexpr int kOutW = 640;
constexpr int kOutH = 480;
constexpr int kCodedW = 624;
constexpr int kCodedH = 480;
constexpr int kDisplayW = 618;
constexpr int kPillarLeft = 11;
constexpr int kPillarRight = 11;
constexpr uint32_t kBasePhys = 0x30000000u;
constexpr uint32_t kBankStrideBytes = 0x00080000u;
constexpr uint32_t kDoorbellPhys = 0x300ff000u;
constexpr uint32_t kDoorbellMagic = 0x504c584bu;
constexpr uint32_t kYBytes = kCodedW * kCodedH;
constexpr uint32_t kCBytes = kCodedW * kCodedH / 4;
constexpr uint32_t kFrameBytes = kYBytes + 2 * kCBytes;

struct Rgb {
    uint8_t r = 0;
    uint8_t g = 0;
    uint8_t b = 0;
};

inline uint64_t pack8(const uint8_t* p) {
    uint64_t value = 0;
    for (int i = 0; i < 8; ++i)
        value |= static_cast<uint64_t>(p[i]) << (8 * i);
    return value;
}

inline std::vector<uint8_t> makeIdleI420() {
    std::vector<uint8_t> frame(kFrameBytes);
    if (!misterplex::renderIdleYuv420p(
            frame.data(), kCodedW, kCodedH, misterplex::IdleMode::Logo, 0))
        throw std::runtime_error("daemon idle I420 generator rejected 624x480");
    return frame;
}

inline std::vector<uint8_t> makeBlackI420() {
    std::vector<uint8_t> frame(kFrameBytes, 128);
    std::fill(frame.begin(), frame.begin() + kYBytes, 16);
    return frame;
}

inline Rgb rtlRgb(uint8_t y, uint8_t u, uint8_t v) {
    const int us = static_cast<int>(u) - 128;
    const int vs = static_cast<int>(v) - 128;
    const int r = (static_cast<int>(y) * 256 + 359 * vs) >> 8;
    const int g = (static_cast<int>(y) * 256 - 88 * us - 183 * vs) >> 8;
    const int b = (static_cast<int>(y) * 256 + 454 * us) >> 8;
    const auto sat = [](int value) {
        return static_cast<uint8_t>(std::clamp(value, 0, 255));
    };
    return {sat(r), sat(g), sat(b)};
}

inline Rgb expectedAt(const std::vector<uint8_t>& frame, int outX, int outY,
                      bool neutralChroma = false) {
    if (outX < kPillarLeft || outX >= kPillarLeft + kDisplayW ||
        outY < 0 || outY >= kOutH)
        return {};
    const int sx = outX - kPillarLeft;
    const int sy = outY;
    const uint8_t y = frame[sy * kCodedW + sx];
    const int ci = (sy / 2) * (kCodedW / 2) + sx / 2;
    const uint8_t u = neutralChroma ? 128 : frame[kYBytes + ci];
    const uint8_t v = neutralChroma ? 128 : frame[kYBytes + kCBytes + ci];
    return rtlRgb(y, u, v);
}

inline bool near(Rgb got, Rgb want, int tolerance = 2) {
    const auto close = [tolerance](uint8_t a, uint8_t b) {
        return std::abs(static_cast<int>(a) - static_cast<int>(b)) <= tolerance;
    };
    return close(got.r, want.r) && close(got.g, want.g) && close(got.b, want.b);
}

inline bool isOrange(Rgb p) {
    return p.r >= 180 && p.g >= 105 && p.g <= 195 && p.b <= 70;
}

inline bool isDark(Rgb p) {
    return p.r >= 25 && p.r <= 70 && p.g >= 25 && p.g <= 70 &&
           p.b >= 25 && p.b <= 75;
}

inline uint32_t doorbellHigh(uint32_t sequence, int bank) {
    constexpr uint32_t kYuv420pFormat = 1;
    return (static_cast<uint32_t>(bank & 1) << 31) |
           (kYuv420pFormat << 29) | (sequence & 0x1fffffffu);
}

template <class Top>
class DdrModel {
public:
    explicit DdrModel(Top& topRef)
        : top(topRef), memory((2 * kBankStrideBytes) / 8, 0) {}

    void loadBank(int bank, const std::vector<uint8_t>& frame) {
        if (bank < 0 || bank > 1 || frame.size() != kFrameBytes)
            throw std::runtime_error("invalid true480 DDR bank load");
        const size_t baseQword = static_cast<size_t>(bank) * kBankStrideBytes / 8;
        for (size_t byte = 0; byte < frame.size(); byte += 8)
            memory[baseQword + byte / 8] = pack8(frame.data() + byte);
    }

    void ringDoorbell(int bank, uint32_t sequence) {
        const size_t qword = (kDoorbellPhys - kBasePhys) / 8;
        memory[qword] =
            (static_cast<uint64_t>(doorbellHigh(sequence, bank)) << 32) |
            kDoorbellMagic;
    }

    uint64_t readPhys(uint32_t phys) const {
        return readQword(phys / 8u);
    }

    void setHangY(bool value) { hangY = value; }
    void setHangC(bool value) { hangC = value; }
    bool sawHungYRead() const { return sawHangY; }
    bool sawHungCRead() const { return sawHangC; }

    void drive() {
        top.DDRAM_DOUT_READY = 0;
        if (busy > 0)
            --busy;
        top.DDRAM_BUSY = busy > 0;
        if (readDelay >= 0) {
            if (readDelay > 0) {
                --readDelay;
            } else if (readLeft > 0) {
                top.DDRAM_DOUT = readQword(readAddr + readIndex);
                top.DDRAM_DOUT_READY = 1;
                ++readIndex;
                --readLeft;
                if (readLeft == 0)
                    readDelay = -1;
            }
        }
    }

    void startRequests() {
        if (top.DDRAM_RD && busy == 0 && readDelay < 0 && readLeft == 0) {
            if (shouldHang(top.DDRAM_ADDR))
                return;
            readAddr = top.DDRAM_ADDR;
            readLeft = top.DDRAM_BURSTCNT;
            readIndex = 0;
            readDelay = 2;
            busy = readLeft + readDelay + 1;
        }
        if (top.DDRAM_WE && busy == 0) {
            writeQword(top.DDRAM_ADDR, top.DDRAM_DIN);
            busy = 2;
        }
    }

private:
    Top& top;
    std::vector<uint64_t> memory;
    int busy = 0;
    int readDelay = -1;
    uint32_t readAddr = 0;
    int readLeft = 0;
    int readIndex = 0;
    bool hangY = false;
    bool hangC = false;
    bool sawHangY = false;
    bool sawHangC = false;

    bool shouldHang(uint32_t qwordAddr) {
        const uint64_t byteAddr = static_cast<uint64_t>(qwordAddr) * 8;
        if (byteAddr < kBasePhys || byteAddr >= kBasePhys + 2ull * kBankStrideBytes)
            return false;
        const uint32_t bankOffset =
            static_cast<uint32_t>((byteAddr - kBasePhys) % kBankStrideBytes);
        if (hangY && bankOffset < kYBytes) {
            sawHangY = true;
            return true;
        }
        if (hangC && bankOffset >= kYBytes && bankOffset < kFrameBytes) {
            sawHangC = true;
            return true;
        }
        return false;
    }

    uint64_t readQword(uint32_t qwordAddr) const {
        const uint64_t byteAddr = static_cast<uint64_t>(qwordAddr) * 8;
        if (byteAddr < kBasePhys)
            return 0;
        const size_t offset = static_cast<size_t>((byteAddr - kBasePhys) / 8);
        return offset < memory.size() ? memory[offset] : 0;
    }

    void writeQword(uint32_t qwordAddr, uint64_t value) {
        const uint64_t byteAddr = static_cast<uint64_t>(qwordAddr) * 8;
        if (byteAddr < kBasePhys)
            return;
        const size_t offset = static_cast<size_t>((byteAddr - kBasePhys) / 8);
        if (offset < memory.size())
            memory[offset] = value;
    }
};

} // namespace true480
