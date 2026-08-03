#pragma once

#include "libmisterplex/geometry_units.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"

#include <cstddef>
#include <cstdint>
#include "libmisterplex/mailbox_abi_spec.hpp"
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
// Path-tier 720p (PMS/vf ladder). DDR bank acceptance remains w-mem owned —
// ddrFrameStoreAcceptsResolution still rejects until the ABI remap lands.
constexpr CodedWidth kPlex720pCodedWidth{1280};
constexpr CodedHeight kPlex720pCodedHeight{720};
// YUV420p bytes = 1280*720*3/2 = 1_382_400 (host push arithmetic).
constexpr int kPlex720pYuv420pBytes = 1382400;
static_assert(kPlex720pYuv420pBytes ==
                  kPlex720pCodedWidth.get() * kPlex720pCodedHeight.get() * 3 / 2,
              "720p I420 byte count");
// Shippable "720p glass" source tier (parent 2026-08-03 proxy ladder, 5/5 HIT):
// ARM decode+copy of 960x540 fits deadline; fabric upscales to 1280x720 raster.
// NOT true 720p source — never label as such. I420 = 960*540*3/2 = 777_600.
//
// PMS delivery (measured local docker PMS, daemon URL, HD 16:9 rk2/rk7, maxBR≥2000):
//   ffprobe width=height=coded_width=coded_height=960x540, SAR 1:1, CB L3.1.
// SPS (trace_headers): pic_width_in_mbs=60 → 960; pic_height_in_map_units=34 → 544;
//   frame_crop_bottom_offset=2 → 4 luma lines cropped → **display 540**.
// ARM publishes **display** planes after ffmpeg crop (777600 B), never the 544-line
// MB buffer (783360 B). Fabric content window + bank payload = 960x540 / 777600.
// maxBR=1500 on same request → 720x404 (bitrate ceiling trap — not genuine 540p).
constexpr CodedWidth kPlex540pCodedWidth{960};
constexpr CodedHeight kPlex540pCodedHeight{540};
constexpr int kPlex540pYuv420pBytes = 777600;
// H.264 MB grid before crop (SPS only; not the DDR publish size).
constexpr int kPlex540pSpsMbHeight = 544;
constexpr int kPlex540pSpsCropBottomLuma = 4; // frame_crop_bottom_offset=2 × 2
constexpr int kPlex540pSpsMbYuv420pBytes = 960 * 544 * 3 / 2; // 783360 — do NOT size banks to this
static_assert(kPlex540pYuv420pBytes ==
                  kPlex540pCodedWidth.get() * kPlex540pCodedHeight.get() * 3 / 2,
              "540p I420 byte count");
static_assert(kPlex540pSpsMbHeight - kPlex540pSpsCropBottomLuma == kPlex540pCodedHeight.get(),
              "SPS MB height minus crop must equal display 540");
static_assert(kPlex540pSpsMbYuv420pBytes == 783360, "SPS MB I420");
// Fits inside Option-C 720p bank stride (1.5 MiB) with headroom — w-mem owns ABI.
static_assert(kPlex540pYuv420pBytes < kPlex720pYuv420pBytes, "540p smaller than 720p bank");
static_assert(kPlex540pYuv420pBytes != kPlex540pSpsMbYuv420pBytes,
              "display I420 must differ from uncropped MB I420");

// 640x360 motion tier for 29.97/30 → exact 2× fabric double to 1280x720 glass.
// PMS (lab 2026-08-03): ceiling 640x360 + maxBR≥1000 → display 640x360 SAR 1:1 CB;
// maxBR=750 → 480x270; maxBR=400 → 320x180. Uncapped rate pass-through on rk142.
// SPS: pic_width_mbs=40 → 640; pic_height_map=23 → 368; crop_bottom_offset=4 →
// CropUnitY=2 → 8 luma lines cropped → **display 360**. ARM I420 = 345600 after crop.
// 360 is NOT MB-aligned (360&15=8) — do not use display height in MB-only guards.
constexpr CodedWidth kPlex360pCodedWidth{640};
constexpr CodedHeight kPlex360pCodedHeight{360};
constexpr int kPlex360pYuv420pBytes = 345600;
constexpr int kPlex360pSpsMbHeight = 368;
constexpr int kPlex360pSpsCropBottomLuma = 8; // frame_crop_bottom_offset=4 × 2
constexpr int kPlex360pSpsMbYuv420pBytes = 640 * 368 * 3 / 2; // 353280
static_assert(kPlex360pYuv420pBytes ==
                  kPlex360pCodedWidth.get() * kPlex360pCodedHeight.get() * 3 / 2,
              "360p I420 byte count");
static_assert(kPlex360pSpsMbHeight - kPlex360pSpsCropBottomLuma == kPlex360pCodedHeight.get(),
              "SPS MB height minus crop must equal display 360");
static_assert(kPlex360pSpsMbYuv420pBytes == 353280, "360p SPS MB I420");
static_assert(kPlex360pYuv420pBytes < kPlex540pYuv420pBytes, "360p smaller than 540p");
static_assert(kPlex360pYuv420pBytes != kPlex360pSpsMbYuv420pBytes,
              "360p display I420 must differ from uncropped MB I420");
// Fits legacy 480p bank usable (520192) — no Option-C required for 345600 payload.
static_assert(kPlex360pYuv420pBytes < 520192, "360p fits legacy bank usable");

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
// Shipping product remains 480p. 720p requires matching RBF + PLXG handshake.
// Phys base is Option-C (after bitstream ring), NOT 0x30000000.
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
constexpr uint32_t kPlex720pYuv420pBankStride = 0x00180000u;
constexpr uint32_t kPlex720pDdrFramePhysBase = 0x30180000u;
constexpr uint32_t kPlex720pYuv420pDoorbellPhys = 0x3047F000u;
constexpr uint32_t kPlexDdrReservedWindowStart = 0x1FF00000u;
constexpr uint32_t kPlexDdrReservedWindowEnd = 0x40000000u;
constexpr uint32_t kPlex720pMapBytes2Bank = 0x00300000u;
// PLXG — ABI FREEZE (parent 2026-08-03): FIXED doorbell+0x800.
// Independent of MAX_CMDS / chrome list length. Never 0x130 (PLXC).
// Single source: mailbox_abi::kPlxgOffset; duplicate is compile-checked below.
constexpr uint32_t kDdrFramePlxgOffset = 0x800u;
constexpr uint32_t kDdrFramePlxgMagic = 0x504C5847u; // "PLXG"
constexpr uint32_t kDdrFramePlxgBytes = 40u;
constexpr uint32_t kDdrFramePlxgBootstrapPhys = 0x300FF800u;
static_assert(kDdrFramePlxgOffset == mailbox_abi::kPlxgOffset,
              "kDdrFramePlxgOffset must equal mailbox_abi::kPlxgOffset (ABI freeze)");
static_assert(kDdrFramePlxgMagic == mailbox_abi::kPlxgMagic,
              "PLXG magic must match mailbox_abi_spec");
static_assert(kDdrFramePlxgOffset != mailbox_abi::kPlxcOffset,
              "PLXG must not collide with PLXC +0x130");
static_assert(kDdrFramePlxgOffset == 0x800u, "PLXG offset is ABI-frozen at 0x800");
static_assert(kDdrFramePlxgBootstrapPhys == mailbox_abi::kPlxgBootstrapPhys,
              "PLXG bootstrap phys must match mailbox_abi_spec");
inline constexpr uint32_t plxgMailboxPhys(uint32_t doorbell_phys) {
    return doorbell_phys + kDdrFramePlxgOffset;
}

// ---- Product ship path: STORAGE vs CANVAS (must not conflate) ----
//
// Three independent fields (rd-duck):
//   1) STORAGE  — bank payload / plane bases / rt_coded_* / y_stride
//                 Product ARM path: **960×540**, strides 960/480, **777600 B**
//                 (libavcodec already applied SPS crop; FFmpeg owns 544→540)
//   2) CANVAS   — glass DE / OSD / present scale destination: **1280×720**
//   3) MAP TIER — phys/stride/doorbell: Option-C when storage does not fit
//                 *usable* legacy bank payload (see below)
//
// ddr_frame_store derives U/V bases from rt_coded_w/h + strides (= STORAGE).
// Passing canvas 1280×720 as rt_coded_* yields U base 921600 and 1280-wide
// fetches against a 960-wide tight payload → shear. PLXG may still describe
// canvas tier separately from content window; do not overload coded_* with DE.
//
// ddrFrameGeometryForFpgaPresent() remains the **product 480p silicon canvas**
// for daemon rawW/H today — do NOT repoint it at 960×540 (would force FFmpeg
// output/copy to the wrong size and kill the measured budget).
//
// SPS (bitstream, fabric-decoder/ring only): coded 544, crop_bottom 4 → 540.
// Product bank planes use **540**, never 544. See ddr_bitstream_ring.hpp.
//
// Bank usable payload (rd-duck; **w-mem owns** RTL Option-C predicate):
//   doorbell = phys + 2*stride - 0x1000
//   usable   = stride - 0x1000   (legacy: 524288-4096 = 520192)
// Full-stride compare is WRONG: 720×482 = 520560 < 524288 but overlaps doorbell.
// w-scaler does NOT land the ddr_frame_store map select — coordinate with w-mem.
constexpr uint32_t kDdrFrameControlPageBytes = 0x1000u;
constexpr uint32_t kPlex480pYuv420pUsablePayloadBytes =
    kPlex480pYuv420pBankStride - kDdrFrameControlPageBytes; // 520192
constexpr uint32_t kPlex720pYuv420pUsablePayloadBytes =
    kPlex720pYuv420pBankStride - kDdrFrameControlPageBytes; // 1572864

constexpr int kPlexProductStorageW = 960;
constexpr int kPlexProductStorageH = 540;
constexpr int kPlexProductCanvasW = 1280;
constexpr int kPlexProductCanvasH = 720;
constexpr int kPlexProductSrcW = kPlexProductStorageW; // alias: scale source
constexpr int kPlexProductDisplayH = kPlexProductStorageH;
constexpr int kPlexProductSpsCodedH = 544; // bitstream only — not bank planes
constexpr int kPlexProductSpsCropBottomLines = 4;
constexpr int kPlexProductYStrideBytes = 960;
constexpr int kPlexProductChromaStrideBytes = 480;
constexpr int kPlexProductStorageI420Bytes = 960 * 540 * 3 / 2; // 777600
constexpr int kPlexProductDisplayI420Bytes = kPlexProductStorageI420Bytes;
constexpr int kPlexProductSpsCodedI420Bytes = 960 * 544 * 3 / 2; // 783360 future
// Plane offsets for tight 960×540 storage (NOT canvas 1280×720 offsets).
constexpr uint32_t kPlexProductStorageUPlaneOffset = 518400u; // 960*540
constexpr uint32_t kPlexProductStorageVPlaneOffset = 648000u; // 518400+129600
// Deprecated name kept for one cycle of callers; means SPS coded bytes only.
constexpr int kPlexProductCodedHMbAligned = kPlexProductSpsCodedH;
constexpr int kPlexProductCodedMbI420Bytes = kPlexProductSpsCodedI420Bytes;

static_assert(kPlex480pYuv420pUsablePayloadBytes == 520192u, "legacy usable");
static_assert(kPlexProductStorageI420Bytes == 777600, "product storage I420");
static_assert(kPlexProductSpsCodedI420Bytes == 783360, "SPS coded I420");
static_assert(kPlexProductSpsCodedH - kPlexProductSpsCropBottomLines ==
                  kPlexProductStorageH,
              "SPS crop: 544-4=540");
static_assert(kPlexProductStorageI420Bytes > int(kPlex480pYuv420pUsablePayloadBytes),
              "product storage must not fit legacy usable → Option-C");
static_assert(kPlexProductStorageI420Bytes <= int(kPlex720pYuv420pUsablePayloadBytes),
              "product storage fits Option-C usable");
static_assert(kPlexProductStorageUPlaneOffset == 518400u, "storage U");
static_assert(kPlexProductStorageVPlaneOffset == 648000u, "storage V");
static_assert(kPlexProductStorageW * 4 == kPlexProductCanvasW * 3, "W exact 4/3");
static_assert(kPlexProductStorageH * 4 == kPlexProductCanvasH * 3, "H exact 4/3");
static_assert((kPlexProductStorageH & 15) == 12, "540 not MB-aligned");
static_assert((kPlexProductSpsCodedH & 15) == 0, "544 is MB-aligned");

// Usable payload bytes inside one bank (control page reserved at end of bank1).
inline uint32_t ddrBankUsablePayloadBytes(uint32_t bankStride) {
    if (bankStride <= kDdrFrameControlPageBytes)
        return 0;
    return bankStride - kDdrFrameControlPageBytes;
}

// True when frame_bytes fit without overlapping the doorbell control page.
// Mirrors ddrFrameLayoutValid: bank1 + frame_bytes <= doorbell.
inline bool ddrFramePayloadFitsBankUsable(size_t frameBytes, uint32_t bankStride) {
    return frameBytes > 0 && frameBytes <= ddrBankUsablePayloadBytes(bankStride);
}

// Tight native I420 storage layout (native_push). Planes use content strides —
// NOT canvas line_bytes. Fabric READ must use these when storage ≠ canvas.
struct DdrNativeContentLayout {
    int width = 0;
    int height = 0;
    int y_stride = 0;
    int chroma_stride = 0;
    uint32_t y_offset = 0;
    uint32_t u_offset = 0;
    uint32_t v_offset = 0;
    size_t frame_bytes = 0;
    bool valid = false;
};

inline DdrNativeContentLayout makeDdrNativeContentLayout(int w, int h) {
    DdrNativeContentLayout c{};
    if (w <= 0 || h <= 0 || (w & 1) || (h & 1))
        return c;
    c.width = w;
    c.height = h;
    c.y_stride = w;
    c.chroma_stride = w / 2;
    const uint32_t yBytes = static_cast<uint32_t>(w) * static_cast<uint32_t>(h);
    const uint32_t cBytes =
        static_cast<uint32_t>(c.chroma_stride) * static_cast<uint32_t>(h / 2);
    c.y_offset = 0;
    c.u_offset = yBytes;
    c.v_offset = yBytes + cBytes;
    c.frame_bytes = static_cast<size_t>(yBytes + 2u * cBytes);
    c.valid = (c.frame_bytes == size_t(w) * size_t(h) * 3u / 2u);
    return c;
}

inline DdrNativeContentLayout plexProduct960x540StorageLayout() {
    return makeDdrNativeContentLayout(kPlexProductStorageW, kPlexProductStorageH);
}

// Fits bank *usable* payload (not full stride). rd-duck: disagreeing with
// ddrFrameLayoutValid here is a contract bug.
inline bool ddrNativeContentFitsBank(const DdrNativeContentLayout& c, uint32_t bankStride) {
    return c.valid && ddrFramePayloadFitsBankUsable(c.frame_bytes, bankStride);
}

// I420 bytes from storage strides/height. Mirror ddr_frame_store plane math.
inline size_t ddrI420BytesFromStrides(int yStrideBytes, int chromaStrideBytes, int storageH) {
    if (yStrideBytes <= 0 || chromaStrideBytes <= 0 || storageH <= 0)
        return 0;
    return size_t(storageH) * size_t(yStrideBytes) +
           size_t(storageH / 2) * size_t(chromaStrideBytes) * 2u;
}

// Host-side usable-capacity helper (spec). RTL map select is **w-mem owned** —
// do not treat this as proof that ddr_frame_store implements it yet.
inline bool ddrFrameNeedsOptionCMap(int yStrideBytes, int chromaStrideBytes, int storageH,
                                    uint32_t legacyBankStride = kPlex480pYuv420pBankStride) {
    const size_t bytes = ddrI420BytesFromStrides(yStrideBytes, chromaStrideBytes, storageH);
    return bytes > 0 && !ddrFramePayloadFitsBankUsable(bytes, legacyBankStride);
}

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
// There is no runtime stride/width register the ARM can program. DECODE/OSD O[4]
// only selects the PMS source ladder; the writer must always emit this canvas
// (scale+pad content into it) or the image shears line-to-line.
inline DdrFrameGeometry productDdrFrameStoreGeometry() {
    return plex480pDdrFrameGeometry();
}

// Storage geometry the daemon FFmpeg/rawvideo path must emit (media_player rawW/H).
//
// rd-duck 2026-08-03: rawW/rawH came solely from this selector. If it always
// returned the 480p canvas, DECODE=960x540 still forced scale+copy into 624x480
// and the measured +7.16 ms tight-540 budget was dead code. If it returned the
// Option-C *DE canvas* 1280x720, FFmpeg would emit 1_382_400 B and kill the
// budget the other way. Both are wrong for the product 540→720-glass path.
//
// Rules:
//   - 960x540 content → identity STORAGE 960x540 (777600 B). Never 1280 canvas.
//   - 640x360 content → identity STORAGE 640x360 (345600 B) for exact-2× glass.
//     Never force 624x480 canvas (would destroy 2× and reintroduce scale).
//   - 1280x720 content → identity STORAGE 1280x720 (true-720 upgrade path).
//   - All other tiers (320x240, 624x480, …) → product 480p silicon canvas
//     (scale+pad). Returning identity-320 is the shear defect (line_bytes=320
//     vs RTL CODED_W=624).
// DE/glass canvas (1280x720) is a separate fabric concept — not this function.
inline DdrFrameGeometry ddrStorageGeometryForContent(CodedWidth contentW,
                                                     CodedHeight contentH) {
    if (contentW.get() == kPlex540pCodedWidth.get() &&
        contentH.get() == kPlex540pCodedHeight.get())
        return makeDdrFrameGeometry(kPlex540pCodedWidth, kPlex540pCodedHeight);
    if (contentW.get() == kPlex360pCodedWidth.get() &&
        contentH.get() == kPlex360pCodedHeight.get())
        return makeDdrFrameGeometry(kPlex360pCodedWidth, kPlex360pCodedHeight);
    if (contentW.get() == kPlex720pCodedWidth.get() &&
        contentH.get() == kPlex720pCodedHeight.get())
        return makeDdrFrameGeometry(kPlex720pCodedWidth, kPlex720pCodedHeight);
    if (contentW.get() == kPlex480pCodedWidth.get() &&
        contentH.get() == kPlex480pCodedHeight.get())
        return plex480pDdrFrameGeometry();
    return productDdrFrameStoreGeometry();
}

inline DdrFrameGeometry ddrStorageGeometryForContent(int contentW, int contentH) {
    return ddrStorageGeometryForContent(CodedWidth{contentW}, CodedHeight{contentH});
}

// FPGA-present geometry for the daemon path: STORAGE, not DE canvas.
// Decode tier selects tight 540/720 identity; everything else stays 480p canvas.
inline DdrFrameGeometry ddrFrameGeometryForFpgaPresent(CodedWidth decodeWidth,
                                                      CodedHeight decodeHeight) {
    return ddrStorageGeometryForContent(decodeWidth, decodeHeight);
}

inline DdrFrameGeometry ddrFrameGeometryForFpgaPresent(int decodeWidth, int decodeHeight) {
    return ddrFrameGeometryForFpgaPresent(CodedWidth{decodeWidth}, CodedHeight{decodeHeight});
}

// True when I420 payload cannot fit legacy 480p bank usable capacity
// (stride 0x80000 minus doorbell page 0x1000 = 520192). Mirrors w-mem/capacity
// Option-C select — NOT coded_w>=1280.
constexpr uint32_t kDdrBankDoorbellPageBytes = 0x1000u;
constexpr uint32_t kPlex480pYuv420pBankUsableBytes =
    kPlex480pYuv420pBankStride - kDdrBankDoorbellPageBytes; // 520192
// 720×480 I420 knife-edge (parent 2026-08-04): 518400 vs usable 520192 → 1792 spare.
// Library widths are 8-aligned so product stride==width (no pad). Any future
// stride rounding that eats the 1792 B spare must fail compile, not corrupt DDR.
constexpr uint32_t kPlex720x480Yuv420pBytes = 720u * 480u * 3u / 2u; // 518400
constexpr uint32_t kPlex720x480LegacyBankSpareBytes =
    kPlex480pYuv420pBankUsableBytes - kPlex720x480Yuv420pBytes; // 1792
static_assert(kPlex720x480Yuv420pBytes == 518400u, "720x480 I420 payload bytes");
static_assert(kPlex480pYuv420pBankUsableBytes == 520192u, "legacy bank usable");
static_assert(kPlex720x480LegacyBankSpareBytes == 1792u, "720x480 legacy spare");
static_assert(kPlex720x480Yuv420pBytes <= kPlex480pYuv420pBankUsableBytes,
              "720x480 must fit legacy bank when stride==width");
// Stride==width for 8-aligned widths (720%8==0): I420 with y_stride=w fits spare.
static_assert((720u % 8u) == 0u, "720 width 8-aligned → stride may equal width");
static_assert((720u % 16u) == 0u, "720 width 16-aligned for rt_raw_ok");
inline bool ddrI420PayloadNeedsOptionCBank(size_t frameBytes) {
    return frameBytes > static_cast<size_t>(kPlex480pYuv420pBankUsableBytes);
}
// True when y_stride==coded_w (no pad). 720×480 only fits legacy under this contract.
inline bool ddrI420StrideEqualsWidthFitsLegacy720x480(int coded_w, int coded_h, int y_stride) {
    if (coded_w != 720 || coded_h != 480)
        return true; // not the knife-edge class
    return y_stride == coded_w &&
           (static_cast<uint32_t>(coded_w) * static_cast<uint32_t>(coded_h) * 3u / 2u) <=
               kPlex480pYuv420pBankUsableBytes;
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

// Aggressive 720p canvas (identity 16:9). Not product silicon until RBF + PLXG.
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

// 720p tier layout at Option-C phys map (not product 0x30000000).
// Bank stride and doorbell are parent-verified fixed ABI — do NOT derive them
// from align(frame_bytes); that yields a different doorbell than 0x3047F000 and
// desyncs w-mem fabric_ddr_writer / fabric READ.
inline DdrFrameLayout makePlex720pDdrFrameLayout(
    DdrFrameFormat format = DdrFrameFormat::Yuv420p) {
    DdrFrameLayout out =
        makeDdrFrameLayout(plex720pDdrFrameGeometry(), kPlex720pDdrFramePhysBase,
                           kDdrFrameStrideAlign, format);
    out.phys_base = kPlex720pDdrFramePhysBase;
    out.bank_stride = kPlex720pYuv420pBankStride;
    out.doorbell_phys = kPlex720pYuv420pDoorbellPhys;
    out.map_bytes = kPlex720pMapBytes2Bank;
    out.format = format;
    out.doorbell_format = ddrFrameFormatCode(format);
    return out;
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

// ---------------------------------------------------------------------------
// Option-C 720p bank window (w-mem ABI) + PL330 scratch (w-path Route A)
// Parent-verified reserved window: memmap=513M$511M → 0x1FF00000..0x40000000.
// Option-C: base 0x30180000, stride 0x180000, doorbell 0x3047F000.
// Triple-buffer map end = base + 3*stride = 0x30600000.
// PL330 ABI starts at that boundary so it never overlaps 2- or 3-bank Option-C.
// ---------------------------------------------------------------------------
constexpr uint32_t kPlexDdrReservedWindowStart = 0x1FF00000u;
constexpr uint32_t kPlexDdrReservedWindowEnd = 0x40000000u;
constexpr uint32_t kPlex720pDdrFramePhysBase = 0x30180000u;
constexpr uint32_t kPlex720pYuv420pBankStride = 0x00180000u;
constexpr uint32_t kPlex720pYuv420pDoorbellPhys = 0x3047F000u;
constexpr uint32_t kPlex720pMapBytes2Bank = 0x00300000u; // 2 * stride
constexpr uint32_t kPlex720pMapBytes3Bank = 0x00480000u; // 3 * stride
// First byte after triple-bank Option-C window (base + 3*stride).
constexpr uint32_t kPlex720pOptionCTripleEndPhys =
    kPlex720pDdrFramePhysBase + kPlex720pMapBytes3Bank; // 0x30600000

// PL330 program scratch + optional contiguous staging (HPS DMA src).
// Mirrored in ddr_frame_layout_params.svh — keep lockstep with w-mem/w-scaler.
constexpr uint32_t kPl330AbiRegionPhys = kPlex720pOptionCTripleEndPhys; // 0x30600000
constexpr uint32_t kPl330ProgScratchPhys = kPl330AbiRegionPhys;
constexpr uint32_t kPl330ProgScratchBytes = 0x1000u; // 4 KiB (program is ~27 B)
constexpr uint32_t kPl330StagingPhys = kPl330ProgScratchPhys + kPl330ProgScratchBytes;
// One 720p I420 frame, stride-aligned — decode/DMA source without pagemap.
constexpr uint32_t kPl330StagingBytes = kPlex720pYuv420pBankStride; // 0x180000
constexpr uint32_t kPl330AbiRegionBytes = kPl330ProgScratchBytes + kPl330StagingBytes;
constexpr uint32_t kPl330AbiRegionEndPhys = kPl330AbiRegionPhys + kPl330AbiRegionBytes;

static_assert(kPl330AbiRegionPhys == 0x30600000u, "PL330 ABI base");
static_assert(kPl330AbiRegionPhys == kPlex720pDdrFramePhysBase + 3u * kPlex720pYuv420pBankStride,
              "PL330 sits exactly after Option-C triple banks");
static_assert(kPl330AbiRegionPhys >= kPlexDdrReservedWindowStart &&
                  kPl330AbiRegionEndPhys <= kPlexDdrReservedWindowEnd,
              "PL330 ABI inside memmap reserved window");
static_assert(kPlex720pYuv420pDoorbellPhys + 0x1000u <= kPl330AbiRegionPhys,
              "PL330 must not overlap Option-C doorbell page");
// 480p product window ends at base+2*yuv_stride = 0x30100000; gap before Option-C.
static_assert(kDdrFramePhysBase + 2u * kPlex480pYuv420pBankStride <= kPlex720pDdrFramePhysBase,
              "480p map must not overlap Option-C base");

inline bool pl330PhysInProgScratch(uint32_t phys, uint32_t len = 1) {
    if (len == 0)
        return false;
    if (phys < kPl330ProgScratchPhys)
        return false;
    return phys + len <= kPl330ProgScratchPhys + kPl330ProgScratchBytes;
}

inline bool pl330PhysInStaging(uint32_t phys, uint32_t len = 1) {
    if (len == 0)
        return false;
    if (phys < kPl330StagingPhys)
        return false;
    return phys + len <= kPl330StagingPhys + kPl330StagingBytes;
}

inline bool pl330AbiOverlapsOptionCBanks(uint32_t phys, uint32_t len) {
    const uint32_t a0 = phys;
    const uint32_t a1 = phys + len;
    const uint32_t b0 = kPlex720pDdrFramePhysBase;
    const uint32_t b1 = kPlex720pOptionCTripleEndPhys;
    return a0 < b1 && b0 < a1;
}

} // namespace misterplex
