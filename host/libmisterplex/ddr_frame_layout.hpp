#pragma once

#include <cstddef>
#include <cstdint>

namespace misterplex {

// HPS DDR frame-store contract shared by misterplexd and RTL:
// - Two banks start at phys_base and phys_base+bank_stride.
// - Doorbell is the final 4 KiB page of the mapped window.
// - RGB565 banks contain one packed little-endian plane at offset 0.
// - YUV420p banks contain planar I420: Y at y_offset, U at u_offset,
//   V at v_offset. Luma stride is line_bytes; chroma stride is
//   chroma_line_bytes. The RTL reader schedules line_qwords for luma bursts and
//   chroma_line_qwords for U/V bursts.
// - Doorbell high word is [31]=bank, [30:29]=format, [28:0]=sequence.
//   Format 0=RGB565, 1=YUV420p. RGB565 preserves the historical bank bit and
//   still presents a monotonically changing sequence to older readers.
enum class DdrFrameFormat {
    Rgb565,
    Yuv420p,
};

inline uint32_t ddrFrameFormatCode(DdrFrameFormat f) {
    switch (f) {
    case DdrFrameFormat::Yuv420p:
        return 1;
    case DdrFrameFormat::Rgb565:
    default:
        return 0;
    }
}

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
    int chroma_line_bytes = 0;
    int chroma_line_qwords = 0;
    uint32_t y_offset = 0;
    uint32_t u_offset = 0;
    uint32_t v_offset = 0;
    uint32_t doorbell_format = 0;
    DdrFrameFormat format = DdrFrameFormat::Rgb565;
};

inline uint32_t alignUpU32(uint32_t v, uint32_t align) {
    return align == 0 ? v : static_cast<uint32_t>((v + align - 1u) & ~(align - 1u));
}

inline size_t yuv420pFrameBytes(int width, int height) {
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1))
        return 0;
    return static_cast<size_t>(width) * static_cast<size_t>(height) * 3u / 2u;
}

inline DdrFrameLayout makeDdrFrameLayout(int width, int height,
                                         uint32_t physBase = 0x30000000u,
                                         uint32_t strideAlign = 0x40000u,
                                         DdrFrameFormat format = DdrFrameFormat::Rgb565) {
    DdrFrameLayout out{};
    if (width <= 0 || height <= 0)
        return out;

    uint64_t lineBytes = 0;
    uint64_t frameBytes = 0;
    uint64_t chromaLineBytes = 0;
    if (format == DdrFrameFormat::Yuv420p) {
        if ((width & 1) || (height & 1))
            return out;
        lineBytes = static_cast<uint64_t>(width);
        chromaLineBytes = static_cast<uint64_t>(width / 2);
        frameBytes = static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 3u / 2u;
    } else {
        lineBytes = static_cast<uint64_t>(width) * 2u;
        frameBytes = lineBytes * static_cast<uint64_t>(height);
    }
    if (lineBytes > 0xFFFFFFFFull || frameBytes > 0xFFFFFFFFull)
        return out;

    out.phys_base = physBase;
    out.format = format;
    out.doorbell_format = ddrFrameFormatCode(format);
    out.width = width;
    out.height = height;
    out.line_bytes = static_cast<int>(lineBytes);
    out.line_qwords = static_cast<int>(lineBytes / 8u);
    out.chroma_line_bytes = static_cast<int>(chromaLineBytes);
    out.chroma_line_qwords = static_cast<int>(chromaLineBytes / 8u);
    out.frame_bytes = static_cast<size_t>(frameBytes);
    if (format == DdrFrameFormat::Yuv420p) {
        const uint32_t yBytes = static_cast<uint32_t>(width * height);
        const uint32_t cBytes = yBytes / 4u;
        out.y_offset = 0;
        out.u_offset = yBytes;
        out.v_offset = yBytes + cBytes;
    }
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

inline uint32_t ddrDoorbellHi(uint32_t seq, int bank, DdrFrameFormat format) {
    return (static_cast<uint32_t>(bank & 1) << 31) |
           ((ddrFrameFormatCode(format) & 0x3u) << 29) | (seq & 0x1FFFFFFFu);
}

} // namespace misterplex
