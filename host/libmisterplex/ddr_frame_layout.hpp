#pragma once

#include <cstddef>
#include <cstdint>

namespace misterplex {

constexpr uint32_t alignUpU32(uint32_t v, uint32_t align) {
    return align == 0 ? v : static_cast<uint32_t>((v + align - 1u) & ~(align - 1u));
}

constexpr int rgb565FrameBytes(int codedWidth, int codedHeight) {
    return codedWidth * codedHeight * 2;
}

constexpr int yuv420pFrameBytesConst(int codedWidth, int codedHeight) {
    return codedWidth * codedHeight * 3 / 2;
}

constexpr int kPlex480pCodedWidth = 624;
constexpr int kPlex480pCodedHeight = 480;
constexpr int kPlex480pDisplayWidth = 618;
constexpr int kPlex480pDisplayHeight = 480;
constexpr int kPlex480pPresentedWidth = 640;
constexpr int kPlex480pPresentedHeight = 480;
constexpr int kPlex480pCropLeft = 0;
constexpr int kPlex480pCropRight = kPlex480pCodedWidth - kPlex480pDisplayWidth;
constexpr int kPlex480pCropTop = 0;
constexpr int kPlex480pCropBottom = kPlex480pCodedHeight - kPlex480pDisplayHeight;
constexpr int kPlex480pPillarboxLeft =
    (kPlex480pPresentedWidth - kPlex480pDisplayWidth) / 2;
constexpr int kPlex480pPillarboxRight =
    kPlex480pPresentedWidth - kPlex480pDisplayWidth - kPlex480pPillarboxLeft;
constexpr uint32_t kDdrFramePhysBase = 0x30000000u;
constexpr uint32_t kDdrFrameStrideAlign = 0x40000u;
constexpr int kPlex480pRgb565LineQwords = (kPlex480pCodedWidth * 2) / 8;
constexpr int kPlex480pYuvLumaLineQwords = kPlex480pCodedWidth / 8;
constexpr int kPlex480pYuvChromaLineQwords = (kPlex480pCodedWidth / 2) / 8;
constexpr int kPlex480pRgb565Bytes =
    rgb565FrameBytes(kPlex480pCodedWidth, kPlex480pCodedHeight);
constexpr int kPlex480pYuv420pBytes =
    yuv420pFrameBytesConst(kPlex480pCodedWidth, kPlex480pCodedHeight);
constexpr int kPlex480pYPlaneOffset = 0;
constexpr int kPlex480pUPlaneOffset = kPlex480pCodedWidth * kPlex480pCodedHeight;
constexpr int kPlex480pVPlaneOffset =
    kPlex480pUPlaneOffset + (kPlex480pCodedWidth / 2) * (kPlex480pCodedHeight / 2);
constexpr int kPlex480pYStrideBytes = kPlex480pCodedWidth;
constexpr int kPlex480pChromaStrideBytes = kPlex480pCodedWidth / 2;
constexpr uint32_t kPlex480pRgb565BankStride =
    alignUpU32(static_cast<uint32_t>(kPlex480pRgb565Bytes), kDdrFrameStrideAlign);
constexpr uint32_t kPlex480pYuv420pBankStride =
    alignUpU32(static_cast<uint32_t>(kPlex480pYuv420pBytes), kDdrFrameStrideAlign);
constexpr uint32_t kPlex480pRgb565DoorbellPhys =
    kDdrFramePhysBase + kPlex480pRgb565BankStride * 2u - 0x1000u;
constexpr uint32_t kPlex480pYuv420pDoorbellPhys =
    kDdrFramePhysBase + kPlex480pYuv420pBankStride * 2u - 0x1000u;
constexpr uint32_t kDdrFrameDoorbellMagic = 0x504C584Bu; // PLXK
constexpr uint32_t kDdrFrameDoorbellSeqMask = 0x1FFFFFFFu;
constexpr uint8_t kYuv420BlackY = 16;
constexpr uint8_t kYuv420BlackU = 128;
constexpr uint8_t kYuv420BlackV = 128;

enum class DdrFramePlacement {
    None,
    Pillarbox,
};

struct DdrPresentedSize {
    int presented_width = 0;
    int presented_height = 0;
};

constexpr DdrPresentedSize ddrPresentedSize(int presentedWidth, int presentedHeight) {
    return {presentedWidth, presentedHeight};
}

// HPS DDR frame-store contract shared by misterplexd and RTL:
// - Two banks start at phys_base and phys_base+bank_stride.
// - Doorbell is the final 4 KiB page of the mapped window.
// - Banks contain planar I420: Y at y_offset, U at u_offset,
//   V at v_offset. Luma stride is line_bytes; chroma stride is
//   chroma_line_bytes. The RTL reader schedules line_qwords for luma bursts and
//   chroma_line_qwords for U/V bursts.
// - Geometry separates coded pixels in memory from cropped display pixels and
//   the VGA presentation area. The measured 480p PMS stream is coded 624x480,
//   display-cropped to 618x480 (right crop = 6), then pillarboxed into 640x480
//   with 11 black pixels at each side. The stored payload is the coded frame;
//   the reader applies crop + pillarbox at scanout. Pillarbox pixels are not
//   stored in DDR; the RTL reader emits deterministic video black
//   (Y=16,U=128,V=128) for those columns. The ARM writer also clears cropped
//   padding inside the coded frame to the same black.
// - Doorbell high word is [31]=bank, [30:29]=format, [28:0]=sequence.
//   C3 RTL consumes format 1=YUV420p only; the ARM must never ring this doorbell
//   with an RGB565 payload.
enum class DdrFrameFormat {
    Yuv420p,
};

inline uint32_t ddrFrameFormatCode(DdrFrameFormat) {
    return 1;
}

struct DdrFrameGeometry {
    int coded_width = 0;
    int coded_height = 0;
    int display_width = 0;
    int display_height = 0;
    int presented_width = 0;
    int presented_height = 0;
    int crop_left = 0;
    int crop_right = 0;
    int crop_top = 0;
    int crop_bottom = 0;
    int present_x = 0;
    int present_y = 0;
    DdrFramePlacement placement = DdrFramePlacement::None;
};

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
    int coded_width = 0;
    int coded_height = 0;
    int display_width = 0;
    int display_height = 0;
    int presented_width = 0;
    int presented_height = 0;
    int crop_left = 0;
    int crop_right = 0;
    int crop_top = 0;
    int crop_bottom = 0;
    int present_x = 0;
    int present_y = 0;
    DdrFramePlacement placement = DdrFramePlacement::None;
    DdrFrameFormat format = DdrFrameFormat::Yuv420p;
};

inline size_t yuv420pFrameBytes(int width, int height) {
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1))
        return 0;
    return static_cast<size_t>(width) * static_cast<size_t>(height) * 3u / 2u;
}

inline DdrFrameGeometry makeDdrFrameGeometry(int codedWidth, int codedHeight,
                                             int displayWidth = 0, int displayHeight = 0,
                                             int presentedWidth = 0, int presentedHeight = 0,
                                             DdrFramePlacement placement =
                                                 DdrFramePlacement::None) {
    DdrFrameGeometry g{};
    g.coded_width = codedWidth;
    g.coded_height = codedHeight;
    g.display_width = displayWidth > 0 ? displayWidth : codedWidth;
    g.display_height = displayHeight > 0 ? displayHeight : codedHeight;
    g.presented_width = presentedWidth > 0 ? presentedWidth : g.display_width;
    g.presented_height = presentedHeight > 0 ? presentedHeight : g.display_height;
    g.crop_left = 0;
    g.crop_top = 0;
    g.crop_right = codedWidth - g.display_width;
    g.crop_bottom = codedHeight - g.display_height;
    g.placement = placement;
    if (placement == DdrFramePlacement::Pillarbox) {
        g.present_x = (g.presented_width - g.display_width) / 2;
        g.present_y = (g.presented_height - g.display_height) / 2;
    }
    return g;
}

inline DdrFrameGeometry plex480pDdrFrameGeometry() {
    DdrFrameGeometry g = makeDdrFrameGeometry(
        kPlex480pCodedWidth, kPlex480pCodedHeight, kPlex480pDisplayWidth,
        kPlex480pDisplayHeight, kPlex480pPresentedWidth, kPlex480pPresentedHeight,
        DdrFramePlacement::Pillarbox);
    g.crop_left = kPlex480pCropLeft;
    g.crop_right = kPlex480pCropRight;
    g.crop_top = kPlex480pCropTop;
    g.crop_bottom = kPlex480pCropBottom;
    g.present_x = kPlex480pPillarboxLeft;
    g.present_y = 0;
    return g;
}

inline DdrFrameGeometry ddrFrameGeometryForPresentedSize(DdrPresentedSize presented) {
    if (presented.presented_width == kPlex480pPresentedWidth &&
        presented.presented_height == kPlex480pPresentedHeight)
        return plex480pDdrFrameGeometry();
    return makeDdrFrameGeometry(presented.presented_width, presented.presented_height);
}

inline DdrFrameLayout makeDdrFrameLayout(const DdrFrameGeometry& geom,
                                         uint32_t physBase = kDdrFramePhysBase,
                                         uint32_t strideAlign = kDdrFrameStrideAlign,
                                         DdrFrameFormat format = DdrFrameFormat::Yuv420p) {
    DdrFrameLayout out{};
    if (geom.coded_width <= 0 || geom.coded_height <= 0 || geom.display_width <= 0 ||
        geom.display_height <= 0 || geom.presented_width <= 0 || geom.presented_height <= 0)
        return out;
    if (geom.display_width + geom.crop_left + geom.crop_right != geom.coded_width)
        return out;
    if (geom.display_height + geom.crop_top + geom.crop_bottom != geom.coded_height)
        return out;
    if (geom.presented_width < geom.display_width || geom.presented_height < geom.display_height)
        return out;

    if ((geom.coded_width & 1) || (geom.coded_height & 1))
        return out;
    const uint64_t lineBytes = static_cast<uint64_t>(geom.coded_width);
    const uint64_t frameBytes = static_cast<uint64_t>(geom.coded_width) *
                                static_cast<uint64_t>(geom.coded_height) * 3u / 2u;
    const uint64_t chromaLineBytes = static_cast<uint64_t>(geom.coded_width / 2);
    if (lineBytes > 0xFFFFFFFFull || frameBytes > 0xFFFFFFFFull)
        return out;

    out.phys_base = physBase;
    out.format = format;
    out.doorbell_format = ddrFrameFormatCode(format);
    out.width = geom.coded_width;
    out.height = geom.coded_height;
    out.coded_width = geom.coded_width;
    out.coded_height = geom.coded_height;
    out.display_width = geom.display_width;
    out.display_height = geom.display_height;
    out.presented_width = geom.presented_width;
    out.presented_height = geom.presented_height;
    out.crop_left = geom.crop_left;
    out.crop_right = geom.crop_right;
    out.crop_top = geom.crop_top;
    out.crop_bottom = geom.crop_bottom;
    out.present_x = geom.present_x;
    out.present_y = geom.present_y;
    out.placement = geom.placement;
    out.line_bytes = static_cast<int>(lineBytes);
    out.line_qwords = static_cast<int>(lineBytes / 8u);
    out.chroma_line_bytes = static_cast<int>(chromaLineBytes);
    out.chroma_line_qwords = static_cast<int>(chromaLineBytes / 8u);
    out.frame_bytes = static_cast<size_t>(frameBytes);
    const uint32_t yBytes = static_cast<uint32_t>(geom.coded_width * geom.coded_height);
    const uint32_t cBytes = yBytes / 4u;
    out.y_offset = 0;
    out.u_offset = yBytes;
    out.v_offset = yBytes + cBytes;
    out.bank_stride = alignUpU32(static_cast<uint32_t>(frameBytes), strideAlign);
    out.doorbell_phys = physBase + out.bank_stride * 2u - 0x1000u;
    out.map_bytes = out.bank_stride * 2u;
    return out;
}

inline DdrFrameLayout makeDdrFrameLayout(int width, int height,
                                         uint32_t physBase = kDdrFramePhysBase,
                                         uint32_t strideAlign = kDdrFrameStrideAlign,
                                         DdrFrameFormat format = DdrFrameFormat::Yuv420p) {
    return makeDdrFrameLayout(makeDdrFrameGeometry(width, height), physBase, strideAlign, format);
}

inline bool ddrFrameLayoutValid(const DdrFrameLayout& l) {
    if (l.phys_base == 0 || l.width <= 0 || l.height <= 0 || l.frame_bytes == 0)
        return false;
    if (l.coded_width != l.width || l.coded_height != l.height)
        return false;
    if (l.display_width <= 0 || l.display_height <= 0 || l.presented_width <= 0 ||
        l.presented_height <= 0)
        return false;
    if (l.crop_left + l.display_width + l.crop_right != l.coded_width)
        return false;
    if (l.crop_top + l.display_height + l.crop_bottom != l.coded_height)
        return false;
    if (l.present_x < 0 || l.present_y < 0 ||
        l.present_x + l.display_width > l.presented_width ||
        l.present_y + l.display_height > l.presented_height)
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
           ((ddrFrameFormatCode(format) & 0x3u) << 29) | (seq & kDdrFrameDoorbellSeqMask);
}

inline bool decodeDdrDoorbell(uint32_t lo, uint32_t hi, DdrFrameFormat expectedFormat,
                              uint32_t& seq, int& bank) {
    if (lo != kDdrFrameDoorbellMagic)
        return false;
    const uint32_t format = (hi >> 29) & 0x3u;
    if (format != ddrFrameFormatCode(expectedFormat))
        return false;
    bank = static_cast<int>((hi >> 31) & 0x1u);
    seq = hi & kDdrFrameDoorbellSeqMask;
    return true;
}

// Maximum coded width the RTL frame store can present (ddr_frame_store.sv FRAME_W).
constexpr int kDdrFrameStoreMaxWidth = 640;
constexpr int kDdrFrameStoreMaxHeight = 480;

// Check whether a decoded frame resolution is acceptable for the DDR frame store.
// Requirements:
//   1. MB-aligned (width and height are multiples of 16)
//   2. Width <= RTL FRAME_W (640) and Height <= RTL FRAME_H (480)
//   3. YUV420p payload fits within bank stride (currently 512 KiB)
// This replaces the old hardcoded equality check against 624x480 and accepts
// any valid resolution the frame store can handle, including 640x480 streams.
inline bool ddrFrameStoreAcceptsResolution(int codedWidth, int codedHeight) {
    if (codedWidth <= 0 || codedHeight <= 0)
        return false;
    if ((codedWidth & 15) != 0 || (codedHeight & 15) != 0)
        return false; // not MB-aligned
    if (codedWidth > kDdrFrameStoreMaxWidth || codedHeight > kDdrFrameStoreMaxHeight)
        return false;
    const size_t frameBytes = yuv420pFrameBytes(codedWidth, codedHeight);
    if (frameBytes == 0)
        return false;
    const uint32_t bankStride = alignUpU32(static_cast<uint32_t>(frameBytes), kDdrFrameStrideAlign);
    return bankStride <= kPlex480pYuv420pBankStride;
}

} // namespace misterplex
