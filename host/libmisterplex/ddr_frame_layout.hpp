#pragma once

#include <cstddef>
#include <cstdint>

namespace misterplex {

struct DdrFrameLayout {
    uint32_t phys_base = 0;
    uint32_t bank_stride = 0;
    uint32_t doorbell_phys = 0;
    uint32_t map_bytes = 0;
    size_t frame_bytes = 0;
    int width = 0;
    int height = 0;
    int line_bytes = 0;
    int line_qwords = 0;
};

inline uint32_t alignUpU32(uint32_t v, uint32_t align) {
    return align == 0 ? v : static_cast<uint32_t>((v + align - 1u) & ~(align - 1u));
}

inline DdrFrameLayout makeDdrFrameLayout(int width, int height,
                                         uint32_t physBase = 0x30000000u,
                                         uint32_t strideAlign = 0x40000u) {
    DdrFrameLayout out{};
    if (width <= 0 || height <= 0)
        return out;

    const uint64_t lineBytes = static_cast<uint64_t>(width) * 2u;
    const uint64_t frameBytes = lineBytes * static_cast<uint64_t>(height);
    if (lineBytes > 0xFFFFFFFFull || frameBytes > 0xFFFFFFFFull)
        return out;

    out.phys_base = physBase;
    out.width = width;
    out.height = height;
    out.line_bytes = static_cast<int>(lineBytes);
    out.line_qwords = static_cast<int>(lineBytes / 8u);
    out.frame_bytes = static_cast<size_t>(frameBytes);
    out.bank_stride = alignUpU32(static_cast<uint32_t>(frameBytes), strideAlign);
    out.doorbell_phys = physBase + out.bank_stride * 2u - 0x1000u;
    out.map_bytes = out.bank_stride * 2u;
    return out;
}

inline bool ddrFrameLayoutValid(const DdrFrameLayout& l) {
    if (l.phys_base == 0 || l.width <= 0 || l.height <= 0 || l.frame_bytes == 0)
        return false;
    if (l.bank_stride < l.frame_bytes)
        return false;
    if (l.doorbell_phys < l.phys_base)
        return false;
    const uint32_t bank1 = l.phys_base + l.bank_stride;
    const uint32_t bank0End = l.phys_base + static_cast<uint32_t>(l.frame_bytes);
    const uint32_t bank1End = bank1 + static_cast<uint32_t>(l.frame_bytes);
    return bank0End <= bank1 && bank1End <= l.doorbell_phys && l.doorbell_phys + 0x1000u <=
                                                        l.phys_base + l.map_bytes;
}

} // namespace misterplex
