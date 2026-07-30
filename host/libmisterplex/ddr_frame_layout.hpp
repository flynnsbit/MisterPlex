#pragma once

#include "libmisterplex/geometry_units.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace misterplex {

// 480p geometry contract (coded / display-cropped / presented are NOT interchangeable):
//   coded 624x480  — H.264 payload and DDR bank layout
//   display 618x480 — after right crop of 6
//   presented 640x480 — VGA scanout after 11+11 pillarbox
constexpr CodedWidth kPlex480pCodedWidth{624};
constexpr CodedHeight kPlex480pCodedHeight{480};
constexpr DisplayWidth kPlex480pDisplayWidth{618};
constexpr DisplayHeight kPlex480pDisplayHeight{480};
constexpr PresentedWidth kPlex480pPresentedWidth{640};
constexpr PresentedHeight kPlex480pPresentedHeight{480};
constexpr int kPlex480pCropLeft = 0;
constexpr int kPlex480pCropRight = 6;
constexpr int kPlex480pCropTop = 0;
constexpr int kPlex480pCropBottom = 0;
constexpr int kPlex480pPillarboxLeft = 11;
constexpr int kPlex480pPillarboxRight = 11;
constexpr uint32_t kDdrFramePhysBase = 0x30000000u;
constexpr uint32_t kDdrFrameStrideAlign = 0x40000u;
constexpr int kPlex480pRgb565LineQwords = 156;
constexpr int kPlex480pYuvLumaLineQwords = 78;
constexpr int kPlex480pYuvChromaLineQwords = 39;
constexpr int kPlex480pRgb565Bytes = 599040;
constexpr int kPlex480pYuv420pBytes = 449280;
constexpr int kPlex480pYPlaneOffset = 0;
constexpr int kPlex480pUPlaneOffset = 299520;
constexpr int kPlex480pVPlaneOffset = 374400;
// Stride bytes follow coded width, never presented scanout width.
// Literals kept parseable by scripts/hw_visual_compare.py; locked to coded width.
constexpr int kPlex480pYStrideBytes = 624;
constexpr int kPlex480pChromaStrideBytes = 312;
static_assert(kPlex480pYStrideBytes == kPlex480pCodedWidth.get(),
              "Y stride must equal coded width");
static_assert(kPlex480pChromaStrideBytes == kPlex480pCodedWidth.get() / 2,
              "chroma stride must equal coded width/2");
constexpr uint32_t kPlex480pRgb565BankStride = 0x000C0000u;
constexpr uint32_t kPlex480pYuv420pBankStride = 0x00080000u;
constexpr uint32_t kPlex480pRgb565DoorbellPhys = 0x3017F000u;
constexpr uint32_t kPlex480pYuv420pDoorbellPhys = 0x300FF000u;
constexpr uint32_t kDdrFrameDoorbellMagic = 0x504C584Bu; // PLXK
constexpr uint32_t kDdrFrameDoorbellSeqMask = 0x1FFFFFFFu;
constexpr uint8_t kYuv420BlackY = 16;
constexpr uint8_t kYuv420BlackU = 128;
constexpr uint8_t kYuv420BlackV = 128;

enum class DdrFramePlacement {
    None,
    Pillarbox,
};

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
//
// Doorbell address family (geometry-derived):
//   doorbell_phys = phys_base + bank_stride * 2 - 0x1000
// Fixed mailbox control page (NOT geometry-derived; live silicon ABI):
//   PLXS 0x3007F100, PLXF 0x3007F118, PLXD 0x3007F128 — do not "unify" with doorbell.
enum class DdrFrameFormat {
    Yuv420p,
};

inline uint32_t ddrFrameFormatCode(DdrFrameFormat) {
    return 1;
}

struct DdrFrameGeometry {
    CodedWidth coded_width{};
    CodedHeight coded_height{};
    DisplayWidth display_width{};
    DisplayHeight display_height{};
    PresentedWidth presented_width{};
    PresentedHeight presented_height{};
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
    // width/height are the coded bank payload size as bare ints for buffer math.
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
    CodedWidth coded_width{};
    CodedHeight coded_height{};
    DisplayWidth display_width{};
    DisplayHeight display_height{};
    PresentedWidth presented_width{};
    PresentedHeight presented_height{};
    int crop_left = 0;
    int crop_right = 0;
    int crop_top = 0;
    int crop_bottom = 0;
    int present_x = 0;
    int present_y = 0;
    DdrFramePlacement placement = DdrFramePlacement::None;
    DdrFrameFormat format = DdrFrameFormat::Yuv420p;
};

inline uint32_t alignUpU32(uint32_t v, uint32_t align) {
    return align == 0 ? v : static_cast<uint32_t>((v + align - 1u) & ~(align - 1u));
}

inline size_t yuv420pFrameBytes(int width, int height) {
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1))
        return 0;
    return static_cast<size_t>(width) * static_cast<size_t>(height) * 3u / 2u;
}

inline size_t yuv420pFrameBytes(CodedWidth width, CodedHeight height) {
    return yuv420pFrameBytes(width.get(), height.get());
}

// Typed geometry builder — coded / display / presented args cannot be swapped.
inline DdrFrameGeometry makeDdrFrameGeometry(CodedWidth codedWidth, CodedHeight codedHeight,
                                             DisplayWidth displayWidth = DisplayWidth{0},
                                             DisplayHeight displayHeight = DisplayHeight{0},
                                             PresentedWidth presentedWidth = PresentedWidth{0},
                                             PresentedHeight presentedHeight = PresentedHeight{0},
                                             DdrFramePlacement placement =
                                                 DdrFramePlacement::None) {
    DdrFrameGeometry g{};
    g.coded_width = codedWidth;
    g.coded_height = codedHeight;
    g.display_width = displayWidth.get() > 0 ? displayWidth : DisplayWidth{codedWidth.get()};
    g.display_height = displayHeight.get() > 0 ? displayHeight : DisplayHeight{codedHeight.get()};
    g.presented_width =
        presentedWidth.get() > 0 ? presentedWidth : PresentedWidth{g.display_width.get()};
    g.presented_height =
        presentedHeight.get() > 0 ? presentedHeight : PresentedHeight{g.display_height.get()};
    g.crop_left = 0;
    g.crop_top = 0;
    g.crop_right = codedWidth.get() - g.display_width.get();
    g.crop_bottom = codedHeight.get() - g.display_height.get();
    g.placement = placement;
    if (placement == DdrFramePlacement::Pillarbox) {
        g.present_x = (g.presented_width.get() - g.display_width.get()) / 2;
        g.present_y = (g.presented_height.get() - g.display_height.get()) / 2;
    }
    return g;
}

// Convenience: a bare WxH is claimed as coded=display=presented (no crop/pillar).
// Prefer the typed overload at any site that already knows which family applies.
inline DdrFrameGeometry makeDdrFrameGeometry(int codedWidth, int codedHeight) {
    return makeDdrFrameGeometry(CodedWidth{codedWidth}, CodedHeight{codedHeight});
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

// Map a *presented* scanout size to DDR geometry. 640x480 presented is the
// plex480p pillarbox contract (coded 624); other sizes fall back to identity.
//
// WARNING: do not pass a DECODE/content tier (e.g. 320x240) here and expect a
// frame the product FPGA can scan out. Product silicon CODED_W/CODED_H are
// compile-time constants (see productDdrFrameStoreGeometry). Use
// ddrFrameGeometryForFpgaPresent() for any FPGA DDR publish path.
inline DdrFrameGeometry ddrFrameGeometryForPresentedSize(PresentedWidth width,
                                                         PresentedHeight height) {
    if (width == kPlex480pPresentedWidth && height == kPlex480pPresentedHeight)
        return plex480pDdrFrameGeometry();
    return makeDdrFrameGeometry(CodedWidth{width.get()}, CodedHeight{height.get()});
}

inline DdrFrameGeometry ddrFrameGeometryForPresentedSize(int width, int height) {
    return ddrFrameGeometryForPresentedSize(PresentedWidth{width}, PresentedHeight{height});
}

// Product FPGA DDR frame-store geometry — a SILICON CONSTANT, not DECODE.
// present_core.sv wires ddr_frame_store with:
//   CODED_W = DDR_FRAME_CODED_WIDTH (624), Y_LINE_QWORDS = CODED_W/8,
//   FRAME_W = 640 presented scanout, bank/doorbell from ddr_frame_layout_params.svh.
// There is no runtime stride/width register the ARM can program. DECODE/OSD O[4]
// only selects the PMS source ladder; the writer must always emit this canvas
// (scale+pad content into it) or the image shears line-to-line.
inline DdrFrameGeometry productDdrFrameStoreGeometry() {
    return plex480pDdrFrameGeometry();
}

// FPGA-present geometry for any content/decode tier. Decode WxH is intentionally
// ignored: a 320x240 source still occupies the 624-byte-stride coded bank after
// force_original_aspect_ratio=decrease + pad. Returning identity-320 here is the
// shear defect (ARM line_bytes=320 vs RTL CODED_W=624).
inline DdrFrameGeometry ddrFrameGeometryForFpgaPresent(CodedWidth /*decodeWidth*/,
                                                      CodedHeight /*decodeHeight*/) {
    return productDdrFrameStoreGeometry();
}

inline DdrFrameGeometry ddrFrameGeometryForFpgaPresent(int decodeWidth, int decodeHeight) {
    return ddrFrameGeometryForFpgaPresent(CodedWidth{decodeWidth}, CodedHeight{decodeHeight});
}

inline DdrFrameLayout makeDdrFrameLayout(const DdrFrameGeometry& geom,
                                         uint32_t physBase = kDdrFramePhysBase,
                                         uint32_t strideAlign = kDdrFrameStrideAlign,
                                         DdrFrameFormat format = DdrFrameFormat::Yuv420p) {
    DdrFrameLayout out{};
    if (geom.coded_width.get() <= 0 || geom.coded_height.get() <= 0 ||
        geom.display_width.get() <= 0 || geom.display_height.get() <= 0 ||
        geom.presented_width.get() <= 0 || geom.presented_height.get() <= 0)
        return out;
    if (geom.display_width.get() + geom.crop_left + geom.crop_right != geom.coded_width.get())
        return out;
    if (geom.display_height.get() + geom.crop_top + geom.crop_bottom != geom.coded_height.get())
        return out;
    if (geom.presented_width.get() < geom.display_width.get() ||
        geom.presented_height.get() < geom.display_height.get())
        return out;

    if ((geom.coded_width.get() & 1) || (geom.coded_height.get() & 1))
        return out;
    const uint64_t lineBytes = static_cast<uint64_t>(geom.coded_width.get());
    const uint64_t frameBytes = static_cast<uint64_t>(geom.coded_width.get()) *
                                static_cast<uint64_t>(geom.coded_height.get()) * 3u / 2u;
    const uint64_t chromaLineBytes = static_cast<uint64_t>(geom.coded_width.get() / 2);
    if (lineBytes > 0xFFFFFFFFull || frameBytes > 0xFFFFFFFFull)
        return out;

    out.phys_base = physBase;
    out.format = format;
    out.doorbell_format = ddrFrameFormatCode(format);
    out.width = geom.coded_width.get();
    out.height = geom.coded_height.get();
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
    const uint32_t yBytes =
        static_cast<uint32_t>(codedPixelCount(geom.coded_width, geom.coded_height));
    const uint32_t cBytes = yBytes / 4u;
    out.y_offset = 0;
    out.u_offset = yBytes;
    out.v_offset = yBytes + cBytes;
    out.bank_stride = alignUpU32(static_cast<uint32_t>(frameBytes), strideAlign);
    // Geometry-derived doorbell: final 4 KiB page of the two-bank map window.
    out.doorbell_phys = physBase + out.bank_stride * 2u - 0x1000u;
    out.map_bytes = out.bank_stride * 2u;
    return out;
}

// Bare WxH → coded identity geometry layout.
inline DdrFrameLayout makeDdrFrameLayout(CodedWidth width, CodedHeight height,
                                         uint32_t physBase = kDdrFramePhysBase,
                                         uint32_t strideAlign = kDdrFrameStrideAlign,
                                         DdrFrameFormat format = DdrFrameFormat::Yuv420p) {
    return makeDdrFrameLayout(makeDdrFrameGeometry(width, height), physBase, strideAlign, format);
}

inline DdrFrameLayout makeDdrFrameLayout(int width, int height,
                                         uint32_t physBase = kDdrFramePhysBase,
                                         uint32_t strideAlign = kDdrFrameStrideAlign,
                                         DdrFrameFormat format = DdrFrameFormat::Yuv420p) {
    return makeDdrFrameLayout(CodedWidth{width}, CodedHeight{height}, physBase, strideAlign,
                              format);
}

inline bool ddrFrameLayoutValid(const DdrFrameLayout& l) {
    if (l.phys_base == 0 || l.width <= 0 || l.height <= 0 || l.frame_bytes == 0)
        return false;
    if (l.coded_width.get() != l.width || l.coded_height.get() != l.height)
        return false;
    if (l.display_width.get() <= 0 || l.display_height.get() <= 0 ||
        l.presented_width.get() <= 0 || l.presented_height.get() <= 0)
        return false;
    if (l.crop_left + l.display_width.get() + l.crop_right != l.coded_width.get())
        return false;
    if (l.crop_top + l.display_height.get() + l.crop_bottom != l.coded_height.get())
        return false;
    if (l.present_x < 0 || l.present_y < 0 ||
        l.present_x + l.display_width.get() > l.presented_width.get() ||
        l.present_y + l.display_height.get() > l.presented_height.get())
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

// True when a layout matches the product silicon frame-store contract (stride,
// bank, doorbell, coded size). Used by unit gates so ARM/RTL divergence fails
// in `make unit` instead of as a sheared picture on HDMI.
inline bool ddrFrameLayoutMatchesProductSilicon(const DdrFrameLayout& l) {
    if (!ddrFrameLayoutValid(l))
        return false;
    if (l.format != DdrFrameFormat::Yuv420p)
        return false;
    if (l.coded_width.get() != kPlex480pCodedWidth.get() ||
        l.coded_height.get() != kPlex480pCodedHeight.get())
        return false;
    if (l.line_bytes != kPlex480pYStrideBytes ||
        l.chroma_line_bytes != kPlex480pChromaStrideBytes)
        return false;
    if (l.line_qwords != kPlex480pYuvLumaLineQwords ||
        l.chroma_line_qwords != kPlex480pYuvChromaLineQwords)
        return false;
    if (l.frame_bytes != static_cast<size_t>(kPlex480pYuv420pBytes))
        return false;
    if (l.y_offset != static_cast<uint32_t>(kPlex480pYPlaneOffset) ||
        l.u_offset != static_cast<uint32_t>(kPlex480pUPlaneOffset) ||
        l.v_offset != static_cast<uint32_t>(kPlex480pVPlaneOffset))
        return false;
    if (l.bank_stride != kPlex480pYuv420pBankStride ||
        l.doorbell_phys != kPlex480pYuv420pDoorbellPhys)
        return false;
    return true;
}

// Center-copy a source I420 frame into a destination coded bank (black-filled).
// Used when STREAM recon produces a smaller MB frame than the silicon canvas so
// the publish path still rings the product 624-stride doorbell layout.
// src must be tightly packed srcW×srcH I420; dst must hold dstGeom coded I420.
inline bool packYuv420pCenteredIntoCodedBank(const uint8_t* src, int srcW, int srcH,
                                             uint8_t* dst, const DdrFrameGeometry& dstGeom) {
    if (!src || !dst || srcW <= 0 || srcH <= 0 || (srcW & 1) || (srcH & 1))
        return false;
    const int dstW = dstGeom.coded_width.get();
    const int dstH = dstGeom.coded_height.get();
    if (dstW <= 0 || dstH <= 0 || (dstW & 1) || (dstH & 1))
        return false;
    if (srcW > dstW || srcH > dstH)
        return false;

    const size_t dstBytes = yuv420pFrameBytes(dstW, dstH);
    if (dstBytes == 0)
        return false;

    // Video black (studio range) for unused coded columns/rows.
    uint8_t* dstY = dst;
    uint8_t* dstU = dst + static_cast<size_t>(dstW) * static_cast<size_t>(dstH);
    uint8_t* dstV = dstU + static_cast<size_t>(dstW / 2) * static_cast<size_t>(dstH / 2);
    std::memset(dstY, kYuv420BlackY, static_cast<size_t>(dstW) * static_cast<size_t>(dstH));
    std::memset(dstU, kYuv420BlackU, static_cast<size_t>(dstW / 2) * static_cast<size_t>(dstH / 2));
    std::memset(dstV, kYuv420BlackV, static_cast<size_t>(dstW / 2) * static_cast<size_t>(dstH / 2));

    // Prefer centering inside the *display* crop window when one is declared so
    // RTL crop+pillarbox still sees content in the visible columns.
    const int boxW = dstGeom.display_width.get() > 0 ? dstGeom.display_width.get() : dstW;
    const int boxH = dstGeom.display_height.get() > 0 ? dstGeom.display_height.get() : dstH;
    const int boxX0 = dstGeom.crop_left;
    const int boxY0 = dstGeom.crop_top;
    int x0 = boxX0 + (boxW - srcW) / 2;
    int y0 = boxY0 + (boxH - srcH) / 2;
    if (x0 < 0)
        x0 = 0;
    if (y0 < 0)
        y0 = 0;
    // Keep even offsets for chroma alignment.
    x0 &= ~1;
    y0 &= ~1;
    if (x0 + srcW > dstW || y0 + srcH > dstH)
        return false;

    const uint8_t* srcY = src;
    const uint8_t* srcU = src + static_cast<size_t>(srcW) * static_cast<size_t>(srcH);
    const uint8_t* srcV = srcU + static_cast<size_t>(srcW / 2) * static_cast<size_t>(srcH / 2);
    for (int y = 0; y < srcH; ++y) {
        std::memcpy(dstY + static_cast<size_t>(y0 + y) * static_cast<size_t>(dstW) +
                        static_cast<size_t>(x0),
                    srcY + static_cast<size_t>(y) * static_cast<size_t>(srcW),
                    static_cast<size_t>(srcW));
    }
    const int cSrcW = srcW / 2;
    const int cSrcH = srcH / 2;
    const int cDstW = dstW / 2;
    const int cx0 = x0 / 2;
    const int cy0 = y0 / 2;
    for (int y = 0; y < cSrcH; ++y) {
        std::memcpy(dstU + static_cast<size_t>(cy0 + y) * static_cast<size_t>(cDstW) +
                        static_cast<size_t>(cx0),
                    srcU + static_cast<size_t>(y) * static_cast<size_t>(cSrcW),
                    static_cast<size_t>(cSrcW));
        std::memcpy(dstV + static_cast<size_t>(cy0 + y) * static_cast<size_t>(cDstW) +
                        static_cast<size_t>(cx0),
                    srcV + static_cast<size_t>(y) * static_cast<size_t>(cSrcW),
                    static_cast<size_t>(cSrcW));
    }
    return true;
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
// Typed as CodedWidth because acceptance checks coded stream size against it.
// Numerically equal to presented 480p width; the type prevents using the
// presented constant by accident in coded-only math without an explicit claim.
constexpr CodedWidth kDdrFrameStoreMaxWidth{640};
constexpr CodedHeight kDdrFrameStoreMaxHeight{480};

// Check whether a decoded frame resolution is acceptable for the DDR frame store.
// Requirements:
//   1. MB-aligned (width and height are multiples of 16)
//   2. Width <= RTL FRAME_W (640) and Height <= RTL FRAME_H (480)
//   3. YUV420p payload fits within bank stride (currently 512 KiB)
// This replaces the old hardcoded equality check against 624x480 and accepts
// any valid resolution the frame store can handle, including 640x480 streams.
inline bool ddrFrameStoreAcceptsResolution(CodedWidth codedWidth, CodedHeight codedHeight) {
    if (codedWidth.get() <= 0 || codedHeight.get() <= 0)
        return false;
    if ((codedWidth.get() & 15) != 0 || (codedHeight.get() & 15) != 0)
        return false; // not MB-aligned
    if (codedWidth.get() > kDdrFrameStoreMaxWidth.get() ||
        codedHeight.get() > kDdrFrameStoreMaxHeight.get())
        return false;
    const size_t frameBytes = yuv420pFrameBytes(codedWidth, codedHeight);
    if (frameBytes == 0)
        return false;
    const uint32_t bankStride = alignUpU32(static_cast<uint32_t>(frameBytes), kDdrFrameStrideAlign);
    return bankStride <= kPlex480pYuv420pBankStride;
}

// Decoder-boundary overload: the caller claims these bare ints are coded size.
inline bool ddrFrameStoreAcceptsResolution(int codedWidth, int codedHeight) {
    return ddrFrameStoreAcceptsResolution(CodedWidth{codedWidth}, CodedHeight{codedHeight});
}

} // namespace misterplex
