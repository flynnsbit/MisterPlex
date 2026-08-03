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
// Legacy SPI frame-store (320x240 RGB565) bank stride. Named here so ship/rollback
// policy tooling derives the SPI bank-1 base from one source instead of re-hardcoding
// it; a SPI/DDR bank-1 mismatch is the mixed-pair black/green screen failure.
constexpr uint32_t kPlex240pSpiRgb565BankStride = 0x00040000u;
constexpr uint32_t kPlex480pRgb565DoorbellPhys = 0x3017F000u;
constexpr uint32_t kPlex480pYuv420pDoorbellPhys = 0x300FF000u;
constexpr uint32_t kDdrFrameDoorbellMagic = 0x504C584Bu; // PLXK
constexpr uint32_t kDdrFrameDoorbellSeqMask = 0x1FFFFFFFu;
constexpr uint8_t kYuv420BlackY = 16;
constexpr uint8_t kYuv420BlackU = 128;
constexpr uint8_t kYuv420BlackV = 128;

// ---- Aggressive 720p tier (opt-in; mirror ddr_frame_layout_params.svh) ----
// Shipping product remains 480p. 720p requires matching RBF + PLXG handshake so
// core and daemon never disagree on bank stride/doorbell (88509163 class stall).
// Phys base is Option-C (after bitstream ring), NOT 0x30000000 — naive enlarge
// of the 480p window stomps ring @0x30100000 and PLXB @0x30140000.
constexpr CodedWidth kPlex720pCodedWidth{1280};
constexpr CodedHeight kPlex720pCodedHeight{720};
constexpr DisplayWidth kPlex720pDisplayWidth{1280};
constexpr DisplayHeight kPlex720pDisplayHeight{720};
constexpr PresentedWidth kPlex720pPresentedWidth{1280};
constexpr PresentedHeight kPlex720pPresentedHeight{720};
constexpr int kPlex720pCropLeft = 0;
constexpr int kPlex720pCropRight = 0;
constexpr int kPlex720pCropTop = 0;
constexpr int kPlex720pCropBottom = 0;
constexpr int kPlex720pPillarboxLeft = 0;
constexpr int kPlex720pPillarboxRight = 0;
constexpr int kPlex720pYuvLumaLineQwords = 160;
constexpr int kPlex720pYuvChromaLineQwords = 80;
constexpr int kPlex720pYuv420pBytes = 1382400;
constexpr int kPlex720pYPlaneOffset = 0;
constexpr int kPlex720pUPlaneOffset = 921600;
constexpr int kPlex720pVPlaneOffset = 1152000;
constexpr int kPlex720pYStrideBytes = 1280;
constexpr int kPlex720pChromaStrideBytes = 640;
static_assert(kPlex720pYStrideBytes == kPlex720pCodedWidth.get(),
              "720p Y stride must equal coded width");
static_assert(kPlex720pChromaStrideBytes == kPlex720pCodedWidth.get() / 2,
              "720p chroma stride must equal coded width/2");
static_assert(kPlex720pYuv420pBytes == 1280 * 720 * 3 / 2,
              "720p I420 byte count");
// alignUp(1382400, 0x40000) = 0x180000; doorbell = phys + 2*stride - 0x1000.
constexpr uint32_t kPlex720pYuv420pBankStride = 0x00180000u;
constexpr uint32_t kPlex720pDdrFramePhysBase = 0x30180000u;
constexpr uint32_t kPlex720pYuv420pDoorbellPhys = 0x3047F000u;
// Parent-verified 2026-08-02 on device: cmdline mem=511M memmap=513M$511M
// reserves 0x1FF00000..0x40000000; /proc/iomem claims nothing in 0x3xxxxxxx.
// Option-C base/doorbell/end all inside reserved → treat as confirmed free.
// Headroom doorbell→0x40000000 ≈ 251.5 MB — take triple-buffer/prefetch freely.
constexpr uint32_t kPlexDdrReservedWindowStart = 0x1FF00000u;
constexpr uint32_t kPlexDdrReservedWindowEnd = 0x40000000u;
constexpr uint32_t kPlex720pMapBytes2Bank = 0x00300000u; // 2 * 0x180000
constexpr uint32_t kPlex720pMapBytes3Bank = 0x00480000u; // 3 * 0x180000
// Candidate only: base + 3*stride - 0x1000. Not product until bank field >1 bit.
constexpr uint32_t kPlex720pTripleDoorbellPhys = 0x305FF000u;
// PLXG — geometry program mailbox, doorbell-relative (see mailbox_abi_spec).
constexpr uint32_t kDdrFramePlxgOffset = 0x130u;
constexpr uint32_t kDdrFramePlxgMagic = 0x504C5847u; // "PLXG"

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
// Frame-store control page is DOORBELL-RELATIVE (RTL: DOORBELL_PHYS + offset):
//   PLXS +0x100, PLXF +0x118, PLXD +0x128. Product doorbell 0x300FF000 →
//   PLXD 0x300FF128. Legacy example base 0x3007F000 still appears in
//   mailbox_abi_spec as documentation — never hard-read those absolutes against
//   a product doorbell (bank0 padding / residue → false PLXD → bank desync).
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
// Shipping RBFs have no runtime stride/width register the ARM can program.
// DECODE/OSD O[4] only selects the PMS source ladder; the writer must always
// emit this canvas (scale+pad content into it) or the image shears line-to-line.
// 720p tier is opt-in via plex720pDdrFrameGeometry() + matching RBF/PLXG — never
// silently substituted here (would recreate 88509163 bank/doorbell desync).
inline DdrFrameGeometry productDdrFrameStoreGeometry() {
    return plex480pDdrFrameGeometry();
}

// Aggressive 720p canvas (identity 16:9). Not product silicon until RBF wires
// DDR_FRAME_720P_* into ddr_frame_store and daemon completes PLXG handshake.
inline DdrFrameGeometry plex720pDdrFrameGeometry() {
    DdrFrameGeometry g = makeDdrFrameGeometry(
        kPlex720pCodedWidth, kPlex720pCodedHeight, kPlex720pDisplayWidth,
        kPlex720pDisplayHeight, kPlex720pPresentedWidth, kPlex720pPresentedHeight,
        DdrFramePlacement::None);
    g.crop_left = kPlex720pCropLeft;
    g.crop_right = kPlex720pCropRight;
    g.crop_top = kPlex720pCropTop;
    g.crop_bottom = kPlex720pCropBottom;
    g.present_x = kPlex720pPillarboxLeft;
    g.present_y = 0;
    return g;
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

// 720p tier layout at Option-C phys base (not product 0x30000000).
inline DdrFrameLayout makePlex720pDdrFrameLayout(
    DdrFrameFormat format = DdrFrameFormat::Yuv420p) {
    return makeDdrFrameLayout(plex720pDdrFrameGeometry(), kPlex720pDdrFramePhysBase,
                              kDdrFrameStrideAlign, format);
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

// True when a layout matches the ratified 720p Option-C tier (not shipping silicon).
inline bool ddrFrameLayoutMatches720pTier(const DdrFrameLayout& l) {
    if (!ddrFrameLayoutValid(l))
        return false;
    if (l.format != DdrFrameFormat::Yuv420p)
        return false;
    if (l.phys_base != kPlex720pDdrFramePhysBase)
        return false;
    if (l.coded_width.get() != kPlex720pCodedWidth.get() ||
        l.coded_height.get() != kPlex720pCodedHeight.get())
        return false;
    if (l.line_bytes != kPlex720pYStrideBytes ||
        l.chroma_line_bytes != kPlex720pChromaStrideBytes)
        return false;
    if (l.line_qwords != kPlex720pYuvLumaLineQwords ||
        l.chroma_line_qwords != kPlex720pYuvChromaLineQwords)
        return false;
    if (l.frame_bytes != static_cast<size_t>(kPlex720pYuv420pBytes))
        return false;
    if (l.y_offset != static_cast<uint32_t>(kPlex720pYPlaneOffset) ||
        l.u_offset != static_cast<uint32_t>(kPlex720pUPlaneOffset) ||
        l.v_offset != static_cast<uint32_t>(kPlex720pVPlaneOffset))
        return false;
    if (l.bank_stride != kPlex720pYuv420pBankStride ||
        l.doorbell_phys != kPlex720pYuv420pDoorbellPhys)
        return false;
    return true;
}

// Origin of a tightly packed srcW×srcH I420 rectangle centered inside dstGeom's
// *display* crop window (not the full coded bank). Offsets are forced even for
// 4:2:0 chroma alignment. Returns false if src cannot fit.
//
// Product pin (320x240 into silicon 624x480 / display 618x480):
//   x0 = crop_left + (618-320)/2 = 149 → 148 after even align
//   y0 = crop_top  + (480-240)/2 = 120
// This origin is CONSTANT for every line — packYuv420pCenteredIntoCodedBank
// cannot produce per-scanline horizontal wander; a ragged left edge on HDMI is
// a scanout/underrun defect, not a writer margin bug.
inline bool codedContentOriginCentered(int srcW, int srcH, const DdrFrameGeometry& dstGeom,
                                        int& x0, int& y0) {
    x0 = 0;
    y0 = 0;
    if (srcW <= 0 || srcH <= 0 || (srcW & 1) || (srcH & 1))
        return false;
    const int dstW = dstGeom.coded_width.get();
    const int dstH = dstGeom.coded_height.get();
    if (dstW <= 0 || dstH <= 0 || (dstW & 1) || (dstH & 1))
        return false;
    if (srcW > dstW || srcH > dstH)
        return false;
    const int boxW = dstGeom.display_width.get() > 0 ? dstGeom.display_width.get() : dstW;
    const int boxH = dstGeom.display_height.get() > 0 ? dstGeom.display_height.get() : dstH;
    int ox = dstGeom.crop_left + (boxW - srcW) / 2;
    int oy = dstGeom.crop_top + (boxH - srcH) / 2;
    if (ox < 0)
        ox = 0;
    if (oy < 0)
        oy = 0;
    ox &= ~1;
    oy &= ~1;
    if (ox + srcW > dstW || oy + srcH > dstH)
        return false;
    x0 = ox;
    y0 = oy;
    return true;
}

// Center-copy a source I420 frame into a destination coded bank (black-filled).
// Used when STREAM recon produces a smaller MB frame than the silicon canvas so
// the publish path still rings the product 624-stride doorbell layout.
// src must be tightly packed srcW×srcH I420; dst must hold dstGeom coded I420.
// Destination X origin is computed ONCE via codedContentOriginCentered and reused
// for every row — no per-line recompute that could accumulate rounding error.
inline bool packYuv420pCenteredIntoCodedBank(const uint8_t* src, int srcW, int srcH,
                                             uint8_t* dst, const DdrFrameGeometry& dstGeom) {
    if (!src || !dst)
        return false;
    int x0 = 0, y0 = 0;
    if (!codedContentOriginCentered(srcW, srcH, dstGeom, x0, y0))
        return false;
    const int dstW = dstGeom.coded_width.get();
    const int dstH = dstGeom.coded_height.get();

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

// Maximum coded width the *shipping* RTL frame store can present (FRAME_W=640).
// Typed as CodedWidth because acceptance checks coded stream size against it.
// Numerically equal to presented 480p width; the type prevents using the
// presented constant by accident in coded-only math without an explicit claim.
// 720p tier raises the ceiling via kDdrFrameStore720pMax* — never silently here.
constexpr CodedWidth kDdrFrameStoreMaxWidth{640};
constexpr CodedHeight kDdrFrameStoreMaxHeight{480};
constexpr CodedWidth kDdrFrameStore720pMaxWidth{1280};
constexpr CodedHeight kDdrFrameStore720pMaxHeight{720};

// Check whether a decoded frame resolution is acceptable for the *product* DDR
// frame store (480p silicon). Requirements:
//   1. MB-aligned (width and height are multiples of 16)
//   2. Width <= RTL FRAME_W (640) and Height <= RTL FRAME_H (480)
//   3. YUV420p payload fits within bank stride (currently 512 KiB)
// 1280x720 is intentionally rejected here — use ddrFrameStoreAccepts720pTier.
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

// 720p-tier acceptance (Option-C map). Not product silicon until RBF+PLXG.
inline bool ddrFrameStoreAccepts720pTier(CodedWidth codedWidth, CodedHeight codedHeight) {
    if (codedWidth.get() <= 0 || codedHeight.get() <= 0)
        return false;
    if ((codedWidth.get() & 15) != 0 || (codedHeight.get() & 15) != 0)
        return false;
    if (codedWidth.get() > kDdrFrameStore720pMaxWidth.get() ||
        codedHeight.get() > kDdrFrameStore720pMaxHeight.get())
        return false;
    const size_t frameBytes = yuv420pFrameBytes(codedWidth, codedHeight);
    if (frameBytes == 0)
        return false;
    const uint32_t bankStride = alignUpU32(static_cast<uint32_t>(frameBytes), kDdrFrameStrideAlign);
    return bankStride <= kPlex720pYuv420pBankStride;
}

inline bool ddrFrameStoreAccepts720pTier(int codedWidth, int codedHeight) {
    return ddrFrameStoreAccepts720pTier(CodedWidth{codedWidth}, CodedHeight{codedHeight});
}

// ---- fab-dma / fabric-owned present (evacuate ARM, not just cheapen it) ----
//
// Mandate: 720p is the reward for moving work into the FPGA. Prefer designs
// where ARM does *none* of scale/pad/pillar/black-fill/centered-pack over
// designs where ARM still does a smaller version of the same job.
//
// Product today (ARM still in the loop):
//   ffmpeg scale+pad → full coded canvas I420 → optional packYuv centered →
//   clearYuv crop pad → memcpy(layout.frame_bytes) → doorbell.
// Fabric-owned present (ARM out of pad/scale/pack):
//   decode (or PMS-native) tight I420 → memcpy(native_bytes only) → PLXG
//   content window + native_push → doorbell. Fabric scales across DE, emits
//   studio black for non-content columns/rows, owns pillar/letterbox.
//
// Measured anchors (do not invent new numbers):
//   FEED archive full-stack (docs/evidence/p480-scale-skip/SCALE_SKIP_PREREG.md):
//     decode_null ~21.56 + scale ~2.95 + pipe ~5.26 + present ~10.41 ms/f
//   DDR pure fill (docs/evidence/p480/p480-bandwidth.md): 59.521 MiB/s no-sync
//   Product present wall mean ~10.41 ms/f includes prep/PLXD/doorbell, not only copy.

// Archive no-sync bank-fill rate used for *copy-term* projections only.
constexpr double kDdrArchiveNoSyncMibps = 59.521;
// FEED archive scale-stage wall bucket (ms/f) — recovered only when ARM stops vf scale.
constexpr double kFeedArchiveScaleMs = 2.95;
// FEED archive product present wall mean (ms/f) — not equal to pure copy.
constexpr double kFeedArchivePresentMs = 10.41;
// FEED non-decode ARM buckets @480p (present+pipe+scale), quoted parent rollup.
constexpr double kFeedArchiveNonDecodeMs = 10.411 + 5.263 + 2.954; // 18.628
// Parent device 2026-08-02 real-content 720p decode-only (both cores), ms/f.
// Source: parent /tmp/misterplex-parent-720p-decode-verdict.txt (device measure).
// Bitrate sweep (Constrained Baseline, 300 frames/arm, exit=0):
//   1500k 32.427 ms/f (headroom 9.24) | 2500k 36.845 (4.82)
//   3500k 38.751 (2.92)               | 4000k 41.073 (0.59)
// Tier choice is worth up to 8.65 ms/f. Candidate pin: 1500 kbit (w-path).
// Headroom is jitter margin ONLY — not permission for ARM memcpy (~22 ms/f).
constexpr double kParent720pDecodeMs1500k = 32.427;
constexpr double kParent720pDecodeMs2500k = 36.845;
constexpr double kParent720pDecodeMs3500k = 38.751;
constexpr double kParent720pDecodeMs4000k = 41.073;
// Default keeps the 4000k figure for conservative residual; prefer 1500k tier APIs.
constexpr double kParent720pDecodeMsDefaultThreads = kParent720pDecodeMs4000k;
constexpr double kParent480pDecodeMsDefaultThreads = 15.969;
constexpr double kFrameBudget24fpsMs = 41.667;
constexpr int kPlex720pCandidateBitrateKbit = 1500;
constexpr double kParent720pDecodeMsCandidateTier = kParent720pDecodeMs1500k;
constexpr double kParent720pDecodeBudgetFraction =
    kParent720pDecodeMsDefaultThreads / kFrameBudget24fpsMs;
constexpr double kParent720pDecodeBudgetFractionCandidate =
    kParent720pDecodeMsCandidateTier / kFrameBudget24fpsMs;

struct DdrNativePushPlan {
    size_t native_bytes = 0;  // tight content I420
    size_t canvas_bytes = 0;  // full coded-bank payload product memcpy uses
    size_t saved_bytes = 0;   // canvas - native (0 if native >= canvas)
    double save_ratio = 0.0;  // saved/canvas in [0,1]
    int content_w = 0;
    int content_h = 0;
    int canvas_w = 0;
    int canvas_h = 0;
    bool valid = false;
};

inline DdrNativePushPlan makeDdrNativePushPlan(int contentW, int contentH,
                                               const DdrFrameGeometry& canvasGeom) {
    DdrNativePushPlan p{};
    p.content_w = contentW;
    p.content_h = contentH;
    p.canvas_w = canvasGeom.coded_width.get();
    p.canvas_h = canvasGeom.coded_height.get();
    p.native_bytes = yuv420pFrameBytes(contentW, contentH);
    p.canvas_bytes = yuv420pFrameBytes(canvasGeom.coded_width, canvasGeom.coded_height);
    if (p.native_bytes == 0 || p.canvas_bytes == 0)
        return p;
    if (contentW > p.canvas_w || contentH > p.canvas_h)
        return p;
    p.saved_bytes = (p.canvas_bytes > p.native_bytes) ? (p.canvas_bytes - p.native_bytes) : 0;
    p.save_ratio = static_cast<double>(p.saved_bytes) / static_cast<double>(p.canvas_bytes);
    p.valid = true;
    return p;
}

// Tight I420 → bank origin. Fabric-owned path: no black-fill of canvas remainder.
inline bool copyYuv420pNativeOrigin(const uint8_t* src, int srcW, int srcH, uint8_t* dst,
                                    size_t dstCap) {
    if (!src || !dst || srcW <= 0 || srcH <= 0 || (srcW & 1) || (srcH & 1))
        return false;
    const size_t need = yuv420pFrameBytes(srcW, srcH);
    if (need == 0 || dstCap < need)
        return false;
    std::memcpy(dst, src, need);
    return true;
}

// Projected wall-ms for a pure DDR bank fill at a measured MiB/s rate.
// rate_mib_s must come from a measured artifact (e.g. kDdrArchiveNoSyncMibps).
inline double ddrPushMsAtRate(size_t bytes, double rate_mib_s) {
    if (bytes == 0 || rate_mib_s <= 0.0)
        return 0.0;
    const double mib = static_cast<double>(bytes) / (1024.0 * 1024.0);
    return (mib / rate_mib_s) * 1000.0;
}

// PLXG geometry-program word (ARM→FPGA). enable=0 keeps synthesis-fixed product
// geometry. When enable=1, fabric latches coded_w/h (tier bank) before doorbell.
// native_push=1 ⇒ payload is tight content I420; window beats supply WxH/x0/y0.
inline uint64_t encodePlxgGeometryWord(int codedW, int codedH, bool enable,
                                       bool nativePush) {
    const uint32_t w = static_cast<uint32_t>(codedW) & 0xFFFu;
    const uint32_t h = static_cast<uint32_t>(codedH) & 0xFFFu;
    const uint64_t hi = (static_cast<uint64_t>(w)) | (static_cast<uint64_t>(h) << 12) |
                        (enable ? (1ull << 24) : 0ull) | (nativePush ? (1ull << 25) : 0ull);
    return (hi << 32) | static_cast<uint64_t>(kDdrFramePlxgMagic);
}

inline bool decodePlxgGeometryWord(uint64_t raw, int& codedW, int& codedH, bool& enable,
                                   bool& nativePush) {
    if (static_cast<uint32_t>(raw) != kDdrFramePlxgMagic)
        return false;
    const uint32_t hi = static_cast<uint32_t>(raw >> 32);
    if ((hi >> 26) & 1u)
        return false; // window/origin beat, not geometry
    codedW = static_cast<int>(hi & 0xFFFu);
    codedH = static_cast<int>((hi >> 12) & 0xFFFu);
    enable = ((hi >> 24) & 1u) != 0;
    nativePush = ((hi >> 25) & 1u) != 0;
    return true;
}

// Which present-path jobs fabric takes so ARM stops doing them.
enum class DdrPresentOffload : uint8_t {
    None = 0,
    // Fabric scales content_w×content_h across DE (w-scaler window). ARM must NOT
    // run ffmpeg scale/pad into the coded canvas for present.
    FabricScale = 1u << 0,
    // Fabric emits studio black outside the content window. ARM must NOT
    // black-fill the coded bank or clearYuv crop padding for present.
    FabricBlackPad = 1u << 1,
    // Fabric places content (x0,y0) / pillar. ARM must NOT packYuv420pCentered.
    FabricPlacement = 1u << 2,
};

inline constexpr DdrPresentOffload operator|(DdrPresentOffload a, DdrPresentOffload b) {
    return static_cast<DdrPresentOffload>(static_cast<uint8_t>(a) | static_cast<uint8_t>(b));
}
inline constexpr bool ddrPresentOffloadHas(DdrPresentOffload set, DdrPresentOffload bit) {
    return (static_cast<uint8_t>(set) & static_cast<uint8_t>(bit)) != 0;
}

// Full fabric-owned present: scale + black + placement — ARM only tight write.
constexpr DdrPresentOffload kDdrPresentOffloadFabricOwned =
    DdrPresentOffload::FabricScale | DdrPresentOffload::FabricBlackPad |
    DdrPresentOffload::FabricPlacement;

// ARM wall-ms budget for one present path choice. Every field is either a
// measured anchor, a rate×bytes projection from a measured rate, or NaN-style
// unknown (negative) with a named settling check in comments/docs.
struct DdrArmPresentBudget {
    // Bytes ARM still memcpy's into the DDR window this path.
    size_t arm_push_bytes = 0;
    // Copy-term ms @ kDdrArchiveNoSyncMibps for arm_push_bytes (projection).
    double arm_copy_ms = 0.0;
    // Copy-term ms if ARM still pushed full canvas (for delta).
    double canvas_copy_ms = 0.0;
    // canvas_copy_ms - arm_copy_ms (pad bytes evacuated). Known projection.
    double copy_ms_removed = 0.0;
    // FEED scale bucket removed when FabricScale is on and ARM skips vf scale.
    // 2.95 ms is the 480p FEED archive figure — NOT remeasured at 720p.
    double scale_ms_removed_feed480 = 0.0;
    // True when path asks fabric to own scale+black+placement.
    bool fabric_owned = false;
    // ARM still participates in pixel push (true until FPGA writes banks).
    bool arm_still_pushes_pixels = true;
    // Hard 720p24 ship gate: arm_push_bytes==0 AND no ARM scale/pad/pack.
    // Parent measure: 4000k decode 41.073 ms/f (0.59 ms); 1500k 32.427 (9.24 ms).
    // Tight 1280x720 memcpy ~22.15 ms exceeds BOTH residuals — unshippable.
    bool zero_arm_per_pixel = false;
    // Sum of *known* removed walls (copy projection + optional FEED scale).
    // Does NOT claim packYuv/clearYuv/PLXD overhead — those are unknown.
    double known_ms_removed_floor = 0.0;
    bool valid = false;
};

// 720p24 ship acceptance for the present/memory plane: ARM does zero per-pixel
// work. Decode may remain on ARM only if every other plane is evacuated AND
// fabric (or non-CPU DMA that ARM does not await per pixel) fills banks.
inline bool ddr720p24ShipAcceptsZeroArmPerPixel(const DdrArmPresentBudget& b) {
    return b.valid && b.zero_arm_per_pixel && b.arm_push_bytes == 0 &&
           b.arm_copy_ms == 0.0 && !b.arm_still_pushes_pixels;
}

// Build the fabric-owned present contract for a content rectangle inside a tier
// canvas. publish_bytes == native I420 only; PLXG must carry the window.
struct DdrFabricOwnedPresentPlan {
    DdrNativePushPlan native{};
    DdrArmPresentBudget budget{};
    DdrPresentOffload offload = DdrPresentOffload::None;
    // Bank geometry (tier) — fabric still double-buffers at this stride.
    DdrFrameGeometry canvas{};
    DdrFrameLayout canvas_layout{};
    // Content rectangle ARM actually writes (tight, origin in bank via PLXG).
    int content_w = 0;
    int content_h = 0;
    int content_x0 = 0; // even-aligned; fabric placement
    int content_y0 = 0;
    // Bytes ARM may memcpy — NEVER canvas frame_bytes on this path.
    size_t publish_bytes = 0;
    // PLXG word to program before doorbell (enable + native_push + coded tier).
    uint64_t plxg_word = 0;
    bool valid = false;
};

inline DdrArmPresentBudget makeDdrArmPresentBudget(const DdrNativePushPlan& native,
                                                   DdrPresentOffload offload,
                                                   bool countFeedScaleRemoval,
                                                   bool armPushesPixels = true) {
    DdrArmPresentBudget b{};
    if (!native.valid)
        return b;
    b.arm_push_bytes = armPushesPixels ? native.native_bytes : 0;
    b.arm_copy_ms =
        armPushesPixels ? ddrPushMsAtRate(native.native_bytes, kDdrArchiveNoSyncMibps) : 0.0;
    b.canvas_copy_ms = ddrPushMsAtRate(native.canvas_bytes, kDdrArchiveNoSyncMibps);
    // When ARM pushes nothing, the entire canvas copy term is evacuated.
    b.copy_ms_removed =
        armPushesPixels ? (b.canvas_copy_ms - b.arm_copy_ms) : b.canvas_copy_ms;
    if (b.copy_ms_removed < 0.0)
        b.copy_ms_removed = 0.0;
    b.fabric_owned = ddrPresentOffloadHas(offload, DdrPresentOffload::FabricScale) &&
                     ddrPresentOffloadHas(offload, DdrPresentOffload::FabricBlackPad) &&
                     ddrPresentOffloadHas(offload, DdrPresentOffload::FabricPlacement);
    if (countFeedScaleRemoval &&
        ddrPresentOffloadHas(offload, DdrPresentOffload::FabricScale))
        b.scale_ms_removed_feed480 = kFeedArchiveScaleMs;
    b.arm_still_pushes_pixels = armPushesPixels;
    b.zero_arm_per_pixel = !armPushesPixels && b.fabric_owned;
    b.known_ms_removed_floor = b.copy_ms_removed + b.scale_ms_removed_feed480;
    b.valid = true;
    return b;
}

// Fabric-owned present plan. canvasGeom is the *tier* bank (480p product or 720p
// Option-C). content is what ARM writes. x0/y0 default to origin; non-zero when
// fabric placement should inset (even-aligned for 4:2:0).
inline DdrFabricOwnedPresentPlan makeDdrFabricOwnedPresentPlan(
    int contentW, int contentH, const DdrFrameGeometry& canvasGeom,
    uint32_t canvasPhysBase = kDdrFramePhysBase, int contentX0 = 0, int contentY0 = 0,
    bool countFeedScaleRemoval = true) {
    DdrFabricOwnedPresentPlan p{};
    p.canvas = canvasGeom;
    p.content_w = contentW;
    p.content_h = contentH;
    p.content_x0 = contentX0 & ~1;
    p.content_y0 = contentY0 & ~1;
    p.offload = kDdrPresentOffloadFabricOwned;
    p.native = makeDdrNativePushPlan(contentW, contentH, canvasGeom);
    if (!p.native.valid)
        return p;
    if (p.content_x0 < 0 || p.content_y0 < 0)
        return p;
    if (p.content_x0 + contentW > canvasGeom.coded_width.get() ||
        p.content_y0 + contentH > canvasGeom.coded_height.get())
        return p;
    p.canvas_layout =
        makeDdrFrameLayout(canvasGeom, canvasPhysBase, kDdrFrameStrideAlign);
    if (!ddrFrameLayoutValid(p.canvas_layout))
        return p;
    p.publish_bytes = p.native.native_bytes;
    p.budget = makeDdrArmPresentBudget(p.native, p.offload, countFeedScaleRemoval,
                                       /*armPushesPixels=*/true);
    // PLXG coded size = tier canvas (bank stride/doorbell family); native_push=1
    // tells fabric the payload is content_w×content_h tight at (x0,y0).
    // Content window words are a second mailbox beat (see encodePlxgContentWindow).
    p.plxg_word = encodePlxgGeometryWord(canvasGeom.coded_width.get(),
                                         canvasGeom.coded_height.get(),
                                         /*enable=*/true, /*nativePush=*/true);
    p.valid = p.budget.valid;
    return p;
}

// FPGA-written banks: ARM publishes **zero** pixel bytes. Fabric decode/MC/IDCT
// (or other fabric producer) fills Option-C / product banks; ARM only programs
// PLXG + rings doorbell / feeds bitstream ring. This is the only present path
// that can meet ddr720p24ShipAcceptsZeroArmPerPixel. Even at candidate 1500k
// (residual ~9.24 ms) a tight 720p memcpy ≈ 22 ms still exceeds — fatal.
// 4000k residual 0.59 ms is worse; tier choice buys jitter, not ARM pixels.
inline DdrFabricOwnedPresentPlan makeDdrFpgaWrittenBankPlan(
    const DdrFrameGeometry& canvasGeom, uint32_t canvasPhysBase = kPlex720pDdrFramePhysBase,
    bool countFeedScaleRemoval = true) {
    // Content == full canvas; producer is fabric, not ARM.
    DdrFabricOwnedPresentPlan p = makeDdrFabricOwnedPresentPlan(
        canvasGeom.coded_width.get(), canvasGeom.coded_height.get(), canvasGeom,
        canvasPhysBase, 0, 0, countFeedScaleRemoval);
    if (!p.valid)
        return p;
    p.publish_bytes = 0; // hard: ARM memcpy length
    p.budget = makeDdrArmPresentBudget(p.native, p.offload, countFeedScaleRemoval,
                                       /*armPushesPixels=*/false);
    // native_push=0: fabric is the pixel producer; window still full-frame.
    p.plxg_word = encodePlxgGeometryWord(canvasGeom.coded_width.get(),
                                         canvasGeom.coded_height.get(),
                                         /*enable=*/true, /*nativePush=*/false);
    p.valid = p.budget.valid && ddr720p24ShipAcceptsZeroArmPerPixel(p.budget);
    return p;
}

// Residual headroom after parent-measured 720p decode if non-decode is fully off ARM.
// Returns budget - decode_ms. Positive means room for jitter only — not for memcpy.
// Default decodeMs is 4000k (worst measured). Pass kParent720pDecodeMsCandidateTier
// (1500k) for the pinned tier residual (~9.24 ms).
inline double ddr720p24ResidualMsAfterDecodeOnly(
    double decodeMs = kParent720pDecodeMsDefaultThreads,
    double budgetMs = kFrameBudget24fpsMs) {
    return budgetMs - decodeMs;
}

// True when a projected ARM copy term alone would blow residual at the given tier.
inline bool ddr720p24ArmCopyExceedsDecodeMarginAt(size_t armPushBytes, double decodeMs) {
    const double copyMs = ddrPushMsAtRate(armPushBytes, kDdrArchiveNoSyncMibps);
    return copyMs > ddr720p24ResidualMsAfterDecodeOnly(decodeMs);
}

// Conservative: exceeds even the 4000k residual (0.59 ms).
inline bool ddr720p24ArmCopyExceedsDecodeMargin(size_t armPushBytes) {
    return ddr720p24ArmCopyExceedsDecodeMarginAt(armPushBytes,
                                                 kParent720pDecodeMsDefaultThreads);
}

// Candidate 1500k tier: still true that a full 720p ARM memcpy does not fit
// (copy ~22.15 ms >> residual ~9.24 ms). Ship gate remains publish_bytes=0.
inline bool ddr720p24ArmCopyExceedsCandidateTierMargin(size_t armPushBytes) {
    return ddr720p24ArmCopyExceedsDecodeMarginAt(armPushBytes,
                                                 kParent720pDecodeMsCandidateTier);
}

// Second PLXG beat: content window inside the tier bank. Magic still PLXG;
// bit26 distinguishes window beat from geometry beat (bit26=1 → window).
inline uint64_t encodePlxgContentWindow(int contentW, int contentH, int x0, int y0) {
    const uint32_t w = static_cast<uint32_t>(contentW) & 0xFFFu;
    const uint32_t h = static_cast<uint32_t>(contentH) & 0xFFFu;
    const uint32_t x = static_cast<uint32_t>(x0) & 0xFFFu;
    const uint32_t y = static_cast<uint32_t>(y0) & 0xFFFu;
    // hi: [11:0]w [23:12]h [24]=0 [25]=0 [26]=1 window [27:28] unused
    // Extended x/y need a third word on wire; pack x in lo magic replacement?
    // Keep lo=magic; put x in hi[27:30] limited — instead use hi fully for w/h
    // and a dedicated packing: hi = w | h<<12 | x<<24 (x only 8 bits) — too small
    // for 1280. Use: hi = w | (h<<12) | (1u<<26); x/y in a *second* uint64 via
    // encodePlxgContentOrigin. Here encode w/h + window flag only.
    const uint64_t hi = static_cast<uint64_t>(w) | (static_cast<uint64_t>(h) << 12) |
                        (1ull << 26);
    (void)x;
    (void)y;
    return (hi << 32) | static_cast<uint64_t>(kDdrFramePlxgMagic);
}

// Origin beat: hi = x0 | (y0<<12) | (1<<26)|(1<<27); lo = PLXG magic.
inline uint64_t encodePlxgContentOrigin(int x0, int y0) {
    const uint32_t x = static_cast<uint32_t>(x0) & 0xFFFu;
    const uint32_t y = static_cast<uint32_t>(y0) & 0xFFFu;
    const uint64_t hi =
        static_cast<uint64_t>(x) | (static_cast<uint64_t>(y) << 12) | (1ull << 26) | (1ull << 27);
    return (hi << 32) | static_cast<uint64_t>(kDdrFramePlxgMagic);
}

inline bool decodePlxgContentWindow(uint64_t raw, int& contentW, int& contentH) {
    if (static_cast<uint32_t>(raw) != kDdrFramePlxgMagic)
        return false;
    const uint32_t hi = static_cast<uint32_t>(raw >> 32);
    if (((hi >> 26) & 1u) == 0 || ((hi >> 27) & 1u) != 0)
        return false; // not window beat
    contentW = static_cast<int>(hi & 0xFFFu);
    contentH = static_cast<int>((hi >> 12) & 0xFFFu);
    return true;
}

inline bool decodePlxgContentOrigin(uint64_t raw, int& x0, int& y0) {
    if (static_cast<uint32_t>(raw) != kDdrFramePlxgMagic)
        return false;
    const uint32_t hi = static_cast<uint32_t>(raw >> 32);
    if (((hi >> 26) & 1u) == 0 || ((hi >> 27) & 1u) == 0)
        return false;
    x0 = static_cast<int>(hi & 0xFFFu);
    y0 = static_cast<int>((hi >> 12) & 0xFFFu);
    return true;
}

// Jobs fabric-owned present **forbids** on ARM (compile-time documentation via
// tests). Returning true means the named ARM helper must not run on this path.
inline bool fabricOwnedForbidsArmCanvasPack() { return true; }
inline bool fabricOwnedForbidsArmFfmpegScalePad() { return true; }
inline bool fabricOwnedForbidsArmClearYuvCropPad() { return true; }

inline uint32_t plxgMailboxPhys(uint32_t doorbellPhys) {
    return doorbellPhys + kDdrFramePlxgOffset;
}

} // namespace misterplex
