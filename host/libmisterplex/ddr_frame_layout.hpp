#pragma once

#include "libmisterplex/geometry_units.hpp"
#include "libmisterplex/ddr_mem_map_policy.hpp"
#include "libmisterplex/mailbox_abi_spec.hpp"
#include "libmisterplex/plxg_record.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace misterplex {

// Product max-tier presented (ascal_true_de_960 ceiling). Runtime DE tracks
// delivered content; 960×540 is maximum not a fixed raster. Mirrors
// DDR_FRAME_PRESENTED_* in ddr_frame_layout_params.svh (dual-header lockstep).
constexpr PresentedWidth kDdrFramePresentedWidth{960};
constexpr PresentedHeight kDdrFramePresentedHeight{540};

// 480p geometry contract (coded / display-cropped / presented are NOT interchangeable):
//   coded 624x480  — H.264 payload and DDR bank layout
//   display 618x480 — after right crop of 6
//   presented 640x480 — VGA scanout after 11+11 pillarbox (legacy silicon)
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

// Compressed bitstream ring (fabric-decode ingest) — mirror ddr_bitstream_ring.hpp
// and ddr_frame_layout_params.svh. Collision fence vs Option-C + PL330.
constexpr uint32_t kDdrBitstreamRingDataPhys = 0x30100000u;
constexpr uint32_t kDdrBitstreamRingBytes = 262144u;
constexpr uint32_t kDdrBitstreamRingCtrlPhys = 0x30140000u;
constexpr uint32_t kDdrBitstreamRingReadPhys = 0x30140008u;
constexpr uint32_t kDdrBitstreamRingErrPhys = 0x30140010u;
constexpr uint32_t kDdrPl330ScratchPhys = 0x30600000u;
constexpr int kDdrBitstreamRecordHeaderBytes = 32;

// Parent-measured AU sizes (real720p_2600k.mp4, 1440 frames) — ring headroom SoT.
constexpr uint32_t kDdrBitstreamMeasuredMeanAuBytes = 13507u;
constexpr uint32_t kDdrBitstreamMeasuredMinAuBytes = 413u;
constexpr uint32_t kDdrBitstreamMeasuredWorstAuBytes = 60915u;
constexpr uint32_t kDdrBitstreamMinWorstAuSlots = 3u;
constexpr uint32_t kDdrBitstreamWorstAuRecordBytes =
    static_cast<uint32_t>(kDdrBitstreamRecordHeaderBytes) + kDdrBitstreamMeasuredWorstAuBytes;
static_assert(kDdrBitstreamRingBytes >=
                  kDdrBitstreamMinWorstAuSlots * kDdrBitstreamWorstAuRecordBytes,
              "256 KiB ring must hold >=3 worst-case AUs (60915+32)");
constexpr uint8_t kDdrBitstreamProfileIdcBaseline = 66u;
constexpr uint8_t kDdrBitstreamCodecFlagConstraintSet1 = 1u;
constexpr uint8_t kDdrBitstreamCodecFlagCabac = 2u;

// H.264 level request vs delivery (DPB sizing — see h264_level_limits.hpp).
constexpr int kDdrH264RequestedLevel = 30;
constexpr int kDdrH264DeliveredLevel720p = 31;
constexpr uint32_t kDdrH264720pFrameSizeMbs = 3600u;
constexpr uint32_t kDdrH264L31MaxDpbFrames720p = 5u;
constexpr uint32_t kDdrH264OptionCPresentBanks = 2u;
constexpr int kDdr720pOutputSourceWidth = 960;
constexpr int kDdr720pOutputSourceHeight = 540;
constexpr int kDdr720pOutputSourceBytes = 777600;





// Parent-verified 2026-08-02 on device: cmdline mem=511M memmap=513M$511M
// reserves 0x1FF00000..0x40000000; /proc/iomem claims nothing in 0x3xxxxxxx.
// Option-C base/doorbell/end all inside reserved → treat as confirmed free.
// Headroom doorbell→0x40000000 ≈ 251.5 MB — take triple-buffer/prefetch freely.
constexpr uint32_t kPlexDdrReservedWindowStart = 0x1FF00000u;
constexpr uint32_t kPlexDdrReservedWindowEnd = 0x40000000u;

static_assert(kDdrBitstreamRingDataPhys + kDdrBitstreamRingBytes == kDdrBitstreamRingCtrlPhys,
              "PLXB sits at ring data end");
static_assert(kDdrBitstreamRingDataPhys + kDdrBitstreamRingBytes <= kPlex720pDdrFramePhysBase,
              "bitstream ring must not overlap Option-C banks");
static_assert(kDdrBitstreamRingCtrlPhys + 0x50u <= kPlex720pDdrFramePhysBase,
              "PLXB mailbox page must not overlap Option-C");
static_assert(kPlex720pYuv420pDoorbellPhys + 0x1000u <= kDdrPl330ScratchPhys,
              "doorbell page must not reach PL330");
static_assert(kDdrBitstreamRingDataPhys >= kPlexDdrReservedWindowStart &&
                  kDdrBitstreamRingCtrlPhys + 0x50u <= kPlexDdrReservedWindowEnd,
              "bitstream ring inside reserved window");

constexpr uint32_t kPlex720pMapBytes2Bank = 0x00300000u; // 2 * 0x180000
constexpr uint32_t kPlex720pMapBytes3Bank = 0x00480000u; // 3 * 0x180000
// Candidate only: base + 3*stride - 0x1000. Not product until bank field >1 bit.
constexpr uint32_t kPlex720pTripleDoorbellPhys = 0x305FF000u;
// PLXG — FIXED wire ABI at doorbell+0x800 (parent freeze). Literals here so
// source-text invariant parsers resolve them; static_assert ties to mailbox_abi
// (reachable compile-time guard — not test-only). Never re-derive from MAX_CMDS.
// PLXC owns +0x130 on the *control bootstrap* page (product 0x300FF000), not on
// the Option-C frame doorbell — list +0x140.. must not grow into PLXG.
constexpr uint32_t kDdrFramePlxgOffset = 0x800u;
constexpr uint32_t kDdrFramePlxgMagic = 0x504C5847u; // "PLXG"
constexpr uint32_t kDdrFramePlxgQwords = 6u;
constexpr uint32_t kDdrFramePlxgBytes = 48u; // q0..q5
constexpr uint32_t kDdrFramePlxgQ5Offset = 0x828u;
constexpr uint32_t kDdrFramePlxgBootstrapPhys = 0x300FF800u;
// PLXC/PLXO/list bootstrap (lockstep mailbox_abi) — chrome never tracks frame map.
constexpr uint32_t kDdrFrameControlBootstrapDoorbellPhys = 0x300FF000u;
constexpr uint32_t kDdrFramePlxcBootstrapPhys = 0x300FF130u;
constexpr uint32_t kDdrFramePlxoBootstrapPhys = 0x300FF138u;
constexpr uint32_t kDdrFramePlxlBootstrapPhys = 0x300FF140u;
static_assert(kDdrFrameControlBootstrapDoorbellPhys ==
                  mailbox_abi::kControlBootstrapDoorbellPhys,
              "control bootstrap doorbell lockstep");
static_assert(kDdrFramePlxcBootstrapPhys == mailbox_abi::kPlxcBootstrapPhys,
              "PLXC bootstrap phys lockstep");
static_assert(kDdrFramePlxoBootstrapPhys == mailbox_abi::kPlxoBootstrapPhys,
              "PLXO bootstrap phys lockstep");
static_assert(kDdrFramePlxlBootstrapPhys == mailbox_abi::kPlxlBootstrapPhys,
              "PLXL bootstrap phys lockstep");
static_assert(kDdrFramePlxgOffset == mailbox_abi::kPlxgOffset,
              "ddr_frame_layout PLXG offset must equal mailbox_abi (reachable guard)");
static_assert(kDdrFramePlxgMagic == mailbox_abi::kPlxgMagic,
              "PLXG magic must match mailbox_abi");
static_assert(kDdrFramePlxgBytes == mailbox_abi::kPlxgBytes,
              "PLXG size must match mailbox_abi (5 qwords)");
static_assert(kDdrFramePlxgQ5Offset == mailbox_abi::kPlxgQ5Offset,
              "PLXG q5 offset lockstep (+0x828)");
static_assert(kDdrFramePlxgQwords == mailbox_abi::kPlxgQwords,
              "PLXG qword count lockstep");
static_assert(kDdrFramePlxgQ5Offset == 0x828u, "PLXG q5 FIXED at +0x828");

static_assert(kDdrFramePlxgBootstrapPhys == mailbox_abi::kPlxgBootstrapPhys,
              "PLXG bootstrap phys must match mailbox_abi");
static_assert(kDdrFramePlxgOffset == 0x800u, "PLXG wire ABI FIXED at +0x800");
static_assert(kDdrFramePlxgOffset != mailbox_abi::kPlxcOffset,
              "PLXG must not collide with PLXC +0x130");
static_assert(mailbox_abi::kPlxlOffset + mailbox_abi::kPlxcListMaxCmds * 8u <=
                  kDdrFramePlxgOffset,
              "chrome list must not grow into fixed PLXG +0x800");

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

// Doorbell/control page occupies the final 4 KiB of the two-bank map:
//   doorbell = phys + 2*bank_stride - kDdrBankDoorbellPageBytes
// Bank1 payload must end at or before doorbell, so usable payload per bank is:
//   usable = bank_stride - kDdrBankDoorbellPageBytes
// (rd-duck: full-stride capacity is WRONG — bank1 would overlap the doorbell page.)
constexpr uint32_t kDdrBankDoorbellPageBytes = 0x1000u;
// Literals so rtl_invariants parity parser and static locks match .svh.
constexpr uint32_t kPlex480pYuv420pBankUsableBytes = 520192u;  // 0x80000 - 0x1000
constexpr uint32_t kPlex720pYuv420pBankUsableBytes = 1568768u; // 0x180000 - 0x1000
static_assert(kPlex480pYuv420pBankUsableBytes ==
                  kPlex480pYuv420pBankStride - kDdrBankDoorbellPageBytes,
              "legacy usable = 0x80000-0x1000");
static_assert(kPlex720pYuv420pBankUsableBytes ==
                  kPlex720pYuv420pBankStride - kDdrBankDoorbellPageBytes,
              "Option-C usable = 0x180000-0x1000");
// Edge example (rd-duck): tight 720x482 = 520560 > 520192 → must select Option-C
// even though 520560 < full stride 524288.
constexpr size_t kDdrLegacyUsableEdgeBytes = 520560u; // 720*482*3/2

inline uint32_t ddrBankUsablePayloadBytes(uint32_t bankStride) {
    return (bankStride > kDdrBankDoorbellPageBytes) ? (bankStride - kDdrBankDoorbellPageBytes)
                                                    : 0u;
}

// True when an I420 payload cannot fit the legacy bank's *usable* capacity
// (stride minus doorbell page). Mirrors ddr_frame_store.sv Option-C select.
// Capacity, NOT coded_w>=1280. 624x480 (449280) → false; 720x482 (520560) → true;
// 960x540 (777600) → true; 1280x720 → true.
inline bool ddrI420PayloadNeedsOptionCBank(size_t frameBytes) {
    return frameBytes > static_cast<size_t>(kPlex480pYuv420pBankUsableBytes);
}

// Same predicate from plane geometry (tight or strided). frame_bytes =
// y_stride*h + 2*(chroma_stride*h/2). h must be even (4:2:0).
inline bool ddrI420PlanesNeedOptionCBank(int yStride, int chromaStride, int height) {
    if (yStride <= 0 || chromaStride <= 0 || height <= 0 || (height & 1))
        return false;
    const uint64_t yb = static_cast<uint64_t>(yStride) * static_cast<uint64_t>(height);
    const uint64_t cb =
        static_cast<uint64_t>(chromaStride) * static_cast<uint64_t>(height / 2);
    const uint64_t bytes = yb + 2ull * cb;
    if (bytes > 0xFFFFFFFFull)
        return true;
    return ddrI420PayloadNeedsOptionCBank(static_cast<size_t>(bytes));
}

// Bank map for a content rectangle: Legacy (0x30000000/0x80000) vs Option-C.
enum class DdrBankMap : uint8_t { Legacy480p = 0, OptionC720p = 1 };

inline DdrBankMap ddrSelectBankMapForI420(int yStride, int chromaStride, int height) {
    return ddrI420PlanesNeedOptionCBank(yStride, chromaStride, height)
               ? DdrBankMap::OptionC720p
               : DdrBankMap::Legacy480p;
}

inline DdrBankMap ddrSelectBankMapForContent(int contentW, int contentH) {
    if (contentW <= 0 || contentH <= 0 || (contentW & 1) || (contentH & 1))
        return DdrBankMap::Legacy480p;
    return ddrSelectBankMapForI420(contentW, contentW / 2, contentH);
}

// DE / glass canvas for a bank map tier (scaler output). NOT storage / FFmpeg size.
inline DdrFrameGeometry ddrCanvasGeometryForBankMap(DdrBankMap map) {
    return (map == DdrBankMap::OptionC720p) ? plex720pDdrFrameGeometry()
                                            : productDdrFrameStoreGeometry();
}

// Storage geometry the daemon FFmpeg/rawvideo path must emit (media_player rawW/H).
//
// Ownership: w-path owns this selector's *contract* (68be1bf9). w-mem keeps the
// body lockstep with that contract so merge order cannot silently re-downscale
// 960×540 → 624×480 (parent STOP on c03afc46 item 3).
//
// Rules (strict allowlist — NOT "any even dims"):
//   - 960×540 content → identity STORAGE 960×540 (777600 B). Never 1280 canvas.
//   - 1280×720 content → identity STORAGE 1280×720 (true-720 upgrade path).
//   - 624×480 → product 480p silicon canvas (plex480p).
//   - All other tiers (320×240, …) → product 480p canvas (scale+pad).
//     Identity-320 is the shear defect (line_bytes=320 vs RTL CODED_W=624).
// DE/glass canvas (1280×720 as *output*) is separate — not this function.
inline DdrFrameGeometry ddrStorageGeometryForContent(int contentW, int contentH) {
    if (contentW == kDdr720pOutputSourceWidth && contentH == kDdr720pOutputSourceHeight)
        return makeDdrFrameGeometry(CodedWidth{contentW}, CodedHeight{contentH});
    if (contentW == 1280 && contentH == 720)
        return makeDdrFrameGeometry(CodedWidth{1280}, CodedHeight{720});
    if (contentW == kPlex480pCodedWidth.get() && contentH == kPlex480pCodedHeight.get())
        return plex480pDdrFrameGeometry();
    return productDdrFrameStoreGeometry();
}

inline DdrFrameGeometry ddrStorageGeometryForContent(CodedWidth contentW, CodedHeight contentH) {
    return ddrStorageGeometryForContent(contentW.get(), contentH.get());
}

// FPGA-present geometry for the daemon path: STORAGE, not DE canvas.
// w-path owns this symbol (parent ruling). Delegates to storage allowlist.
// 960×540 → 960×540; 1280×720 → 1280×720; else product 624 canvas.
// MUST NOT ignore decode dims (always-624 was the silent downscale defect).
inline DdrFrameGeometry ddrFrameGeometryForFpgaPresent(CodedWidth decodeWidth,
                                                      CodedHeight decodeHeight) {
    return ddrStorageGeometryForContent(decodeWidth, decodeHeight);
}

inline DdrFrameGeometry ddrFrameGeometryForFpgaPresent(int decodeWidth, int decodeHeight) {
    return ddrFrameGeometryForFpgaPresent(CodedWidth{decodeWidth}, CodedHeight{decodeHeight});
}

// Product intermediate tier (PMS Constrained Baseline 960×540 → fabric upscale).
inline bool ddrIsProduct960x540Content(int w, int h) {
    return w == kDdr720pOutputSourceWidth && h == kDdr720pOutputSourceHeight;
}

// FFmpeg / rawvideo geometry for PRESENT=fpga|both — same storage contract.
// Never returns DE-only canvas sizing that FFmpeg did not decode.
inline DdrFrameGeometry ddrFfmpegGeometryForPresent(int outW, int outH, bool wantFpgaDdrCanvas) {
    if (wantFpgaDdrCanvas)
        return ddrFrameGeometryForFpgaPresent(outW, outH);
    return makeDdrFrameGeometry(outW, outH);
}

// Plane U offset from storage coded dims (I420, stride=width). Red-twin oracle:
// canvas 1280×720 → U@921600; storage 960×540 → U@518400. Conflating them shears.
inline uint32_t ddrI420UPlaneOffset(int codedW, int codedH) {
    if (codedW <= 0 || codedH <= 0 || (codedW & 1) || (codedH & 1))
        return 0;
    return static_cast<uint32_t>(codedW) * static_cast<uint32_t>(codedH);
}
inline bool ddrPlxgStorageNotCanvasUBase(int plxgCodedW, int plxgCodedH, uint32_t uOff) {
    // Product native path: PLXG coded must be storage 960×540 → U@518400.
    if (ddrIsProduct960x540Content(plxgCodedW, plxgCodedH))
        return uOff == static_cast<uint32_t>(kDdr720pOutputSourceWidth) *
                           static_cast<uint32_t>(kDdr720pOutputSourceHeight); // 518400
    return uOff == ddrI420UPlaneOffset(plxgCodedW, plxgCodedH);
}
// Fault twin: programming DE canvas dims into PLXG coded fields.
inline bool ddrPlxgCanvasDimsFault(int plxgCodedW, int plxgCodedH) {
    return plxgCodedW == 1280 && plxgCodedH == 720;
}

// Mirror ddr_frame_store rt_raw_window / rt_raw_ok crop bounds (rd-duck).
// display_w/h 0 → coded (RTL rt_dw_nz). Widened sums; sum==coded PASS, +1 FAIL.
// maxRdW/H default product MAX_CODED / FRAME max (1280×720).
inline bool ddrRtRawWindowOk(int codedW, int codedH, int displayW, int displayH,
                             int cropLeft, int cropTop, int presentX = 0,
                             int presentY = 0, int maxRdW = 1280, int maxRdH = 720) {
    if (codedW <= 0 || codedH <= 0)
        return false;
    const int dw = (displayW == 0) ? codedW : displayW;
    const int dh = (displayH == 0) ? codedH : displayH;
    if (dw <= 0 || dh <= 0 || dw > codedW || dh > codedH)
        return false;
    if (cropLeft < 0 || cropTop < 0 || presentX < 0 || presentY < 0)
        return false;
    // 12-bit widened path in RTL — use 32-bit here for host.
    if (static_cast<int64_t>(cropLeft) + dw > codedW)
        return false;
    if (static_cast<int64_t>(cropTop) + dh > codedH)
        return false;
    if (static_cast<int64_t>(presentX) + dw > maxRdW)
        return false;
    if (static_cast<int64_t>(presentY) + dh > maxRdH)
        return false;
    return true;
}

// Exact boundary oracles for unit tests / twin docs.
inline bool ddrRtRawWindowBoundaryEqCodedPass() {
    // crop_l=10, display=614, coded=624 → sum 624
    return ddrRtRawWindowOk(624, 480, 614, 480, 10, 0);
}
inline bool ddrRtRawWindowBoundaryPlus1Fail() {
    return !ddrRtRawWindowOk(624, 480, 615, 480, 10, 0);
}
inline bool ddrRtRawWindowCropTopPlus1Fail() {
    return !ddrRtRawWindowOk(624, 480, 624, 480, 0, 1);
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

// Doorbell hi packing (rd-duck PLXG↔bank coupling):
//   [31]     bank
//   [30:29]  format
//   [28:16]  plxg_seq (13b) — 0 = ungated legacy (no geom coupling)
//   [15:0]   frame_seq (16b)
// Full 29-bit seq mask retained as (plxg_seq<<16)|frame_seq for token identity.
// plxgNextSeq skips full seqs whose low-13 field is 0 (8192, 16384, …) so a
// valid coupled publish never collapses to ungated.
constexpr uint32_t kDdrDoorbellFrameSeqMask = 0xFFFFu;
constexpr uint32_t kDdrDoorbellPlxgSeqMask = 0x1FFFu; // == kPlxgDoorbellSeqFieldMask
constexpr unsigned kDdrDoorbellPlxgSeqShift = 16u;

inline uint32_t ddrDoorbellHi(uint32_t seq, int bank, DdrFrameFormat format,
                              uint16_t plxgSeq = 0) {
    const uint32_t frameSeq = seq & kDdrDoorbellFrameSeqMask;
    // Field is low-13 of full PLXG seq; 0 only for intentional ungated (caller
    // passes 0) or FAULT allocator that emitted 8192/16384/….
    const uint32_t ps = static_cast<uint32_t>(plxgSeqDoorbellField(plxgSeq));
    return (static_cast<uint32_t>(bank & 1) << 31) |
           ((ddrFrameFormatCode(format) & 0x3u) << 29) |
           (ps << kDdrDoorbellPlxgSeqShift) | frameSeq;
}

inline uint16_t ddrDoorbellPlxgSeq(uint32_t hi) {
    return static_cast<uint16_t>((hi >> kDdrDoorbellPlxgSeqShift) & kDdrDoorbellPlxgSeqMask);
}

inline uint16_t ddrDoorbellFrameSeq(uint32_t hi) {
    return static_cast<uint16_t>(hi & kDdrDoorbellFrameSeqMask);
}

inline bool decodeDdrDoorbell(uint32_t lo, uint32_t hi, DdrFrameFormat expectedFormat,
                              uint32_t& seq, int& bank, uint16_t* plxgSeqOut = nullptr) {
    if (lo != kDdrFrameDoorbellMagic)
        return false;
    const uint32_t format = (hi >> 29) & 0x3u;
    if (format != ddrFrameFormatCode(expectedFormat))
        return false;
    bank = static_cast<int>((hi >> 31) & 0x1u);
    // Token identity remains full low-29 for have_seq compare.
    seq = hi & kDdrFrameDoorbellSeqMask;
    if (plxgSeqOut)
        *plxgSeqOut = ddrDoorbellPlxgSeq(hi);
    return true;
}

// Bank accept under geom coupling: doorbell field 0 → legacy ungated; else must
// match live PLXG seq low-13 (RTL: db_plxg_seq == d_geom_seq[12:0]).
inline bool ddrDoorbellGeomCoupledOk(uint16_t doorbellPlxgSeq, uint16_t livePlxgSeq,
                                     bool liveValid, bool faultIgnoreCoupling = false) {
    if (faultIgnoreCoupling)
        return true;
    if (doorbellPlxgSeq == 0)
        return true; // legacy ungated
    if (!liveValid)
        return false;
    return doorbellPlxgSeq == plxgSeqDoorbellField(livePlxgSeq);
}

// Doorbell PLXG field for a publish (rd-duck mode-exit hole):
//   program_plxg=false → 0 (true legacy, no PLXG programmed this frame)
//   program_plxg=true  → *committed* writePlxg useSeq (enable OR disable)
// Never pass plan.plxg_seq: full-canvas disable plans used to seed 0, which
// is the ungated encoding and lets bank swap before disable promotes.
inline uint16_t ddrDoorbellPlxgSeqForPublish(bool programPlxg, uint16_t committedSeq) {
    if (!programPlxg)
        return 0;
    return committedSeq;
}

// True when a program_plxg publish would illegally pack doorbell field 0.
inline bool ddrDoorbellPlxgSeqPublishIllegalUngated(bool programPlxg,
                                                    uint16_t doorbellPlxgSeq) {
    return programPlxg && plxgSeqDoorbellFieldIsReservedUngated(doorbellPlxgSeq);
}

// rd-duck: independent PLXG vs doorbell observers without generation coupling.
struct DdrGeomBankCouplingModel {
    bool geom_live = false;
    uint16_t geom_seq = 0;
    bool bank_pending = false;
    bool bank_displayed = false;
    int bank = 0;
    uint16_t bank_req_plxg_seq = 0;
    bool fault_ignore_coupling = false;

    void observePlxgPromote(uint16_t seq) {
        geom_live = true;
        geom_seq = seq;
        tryAcceptBank();
    }

    bool observeDoorbell(int b, uint16_t plxgSeq) {
        bank = b;
        bank_req_plxg_seq = plxgSeq;
        bank_pending = true;
        return tryAcceptBank();
    }

    bool tryAcceptBank() {
        if (!bank_pending)
            return false;
        if (!ddrDoorbellGeomCoupledOk(bank_req_plxg_seq, geom_seq, geom_live,
                                      fault_ignore_coupling))
            return false;
        bank_pending = false;
        bank_displayed = true;
        return true;
    }
};

inline bool ddrCouplingFaultAcceptsBankBeforeGeom() {
    DdrGeomBankCouplingModel m;
    m.fault_ignore_coupling = true;
    m.observeDoorbell(/*bank*/1, /*plxgSeq*/7);
    return m.bank_displayed && !m.geom_live;
}

inline bool ddrCouplingProductHoldsBankUntilGeom() {
    DdrGeomBankCouplingModel m;
    if (m.observeDoorbell(1, 7))
        return false;
    if (m.bank_displayed)
        return false;
    m.observePlxgPromote(7);
    return m.bank_displayed && m.geom_seq == 7;
}

// B20: bank+geometry atomic apply. Coupling alone is not enough — free-running
// store pitch after PLXG promote still reads the old bank with the new stride.
// Applied geometry must promote with the bank swap, not with PLXG live.
struct DdrBankGeomAtomicModel {
    bool geom_live = false;
    uint16_t geom_seq = 0;
    int cand_w = 624;   // free-running candidate after PLXG promote
    int app_w = 624;    // applied display pitch width
    int pend_w = 624;
    bool bank_pending = false;
    bool bank_displayed = false;
    int disp_bank = 0;
    int pend_bank = 0;
    uint16_t pend_plxg_seq = 0;
    bool fault_free_run_geom = false; // FAULT: app tracks cand immediately

    void promoteGeom(int w, uint16_t seq) {
        geom_live = true;
        geom_seq = seq;
        cand_w = w;
        if (fault_free_run_geom)
            app_w = w; // B20 defect: pitch changes before bank swap
    }

    // Returns true if doorbell accepted (coupled). Does NOT apply geometry.
    bool observeDoorbell(int b, uint16_t plxgSeq) {
        if (!ddrDoorbellGeomCoupledOk(plxgSeq, geom_seq, geom_live, false))
            return false;
        bank_pending = true;
        pend_bank = b;
        pend_plxg_seq = plxgSeq;
        pend_w = cand_w; // snapshot at accept
        return true;
    }

    // Frame-boundary bank swap — only place product applies geometry under B20.
    void frameSwap() {
        if (!bank_pending)
            return;
        disp_bank = pend_bank;
        bank_displayed = true;
        bank_pending = false;
        if (!fault_free_run_geom)
            app_w = pend_w;
    }

    // True if display path would use new cand pitch on old bank (mixed frame).
    bool mixedPitchOnOldBank() const {
        return geom_live && bank_displayed && app_w != cand_w && disp_bank != pend_bank;
    }
    bool displayUsesCandBeforeSwap() const {
        return geom_live && bank_pending && (app_w == cand_w) && (app_w != 624);
    }
};

inline bool ddrB20FaultFreeRunExposesNewPitchBeforeSwap() {
    DdrBankGeomAtomicModel m;
    m.fault_free_run_geom = true;
    m.promoteGeom(/*w*/320, /*seq*/7);
    // No doorbell yet — defect already moved app
    return m.app_w == 320 && !m.bank_displayed;
}

inline bool ddrB20ProductHoldsPitchUntilBankSwap() {
    DdrBankGeomAtomicModel m;
    m.promoteGeom(320, 7);
    if (m.app_w != 624)
        return false; // must hold legacy until swap
    if (!m.observeDoorbell(/*bank*/1, /*plxg*/7))
        return false;
    if (m.app_w != 624 || !m.bank_pending)
        return false; // still hold through accept
    m.frameSwap();
    return m.app_w == 320 && m.disp_bank == 1 && m.bank_displayed;
}

// Independent observers: PLXG promote then delayed doorbell then swap.
inline bool ddrB20IndependentObserversNoMix() {
    DdrBankGeomAtomicModel m;
    m.promoteGeom(960, 3);
    // Simulate slow doorbell (many "cycles" with cand live, app held)
    if (m.app_w != 624)
        return false;
    if (!m.observeDoorbell(1, 3))
        return false;
    if (m.app_w != 624)
        return false;
    m.frameSwap();
    return m.app_w == 960 && m.disp_bank == 1;
}

// rd-duck: writePlxgRecord computes useSeq but sendDdrFrame used plan.plxg_seq
// (native plans seed seq=1 every construction). Second publish commits seq=2
// while doorbell still carries 1 → db_geom_coupled rejects forever.
// Model: commit PLXG → kick doorbell; product embeds committed seq.
struct DdrPlxgDoorbellSeqModel {
    uint16_t software_last = 0;
    uint16_t retained_seq = 0;
    bool retained_valid = false;
    uint16_t last_committed = 0;
    uint16_t last_doorbell_plxg = 0;
    bool fault_embed_plan_seq = false; // REPRO: kick with advisory plan seq

    // Returns committed useSeq (mirrors writePlxgRecord).
    uint16_t writePlxg(uint16_t /*advisoryPlanSeq*/) {
        const uint16_t use = plxgNextSeq(software_last, retained_valid, retained_seq);
        software_last = use;
        last_committed = use;
        retained_seq = use;
        retained_valid = true;
        return use;
    }

    void kickDoorbell(uint16_t planSeq, uint16_t committedSeq, bool programPlxg) {
        if (!programPlxg) {
            last_doorbell_plxg = 0; // ungated legacy
            return;
        }
        last_doorbell_plxg = fault_embed_plan_seq ? planSeq : committedSeq;
    }

    // Fabric coupling after both observers: doorbell plxg must match live geom seq.
    bool coupledOk(uint16_t liveGeomSeq, bool live) const {
        return ddrDoorbellGeomCoupledOk(last_doorbell_plxg, liveGeomSeq, live, false);
    }
};

// FAULT REPRO: two publishes with sticky plan.seq=1 — second doorbell stays 1.
inline bool ddrPlxgDoorbellFaultSecondPublishMismatches() {
    DdrPlxgDoorbellSeqModel m;
    m.fault_embed_plan_seq = true;
    constexpr uint16_t kPlanSeq = 1; // native plan seed every construction
    const uint16_t c1 = m.writePlxg(kPlanSeq);
    m.kickDoorbell(kPlanSeq, c1, true);
    if (c1 != 1 || m.last_doorbell_plxg != 1)
        return false; // first may still match
    const uint16_t c2 = m.writePlxg(kPlanSeq);
    m.kickDoorbell(kPlanSeq, c2, true);
    // Defect: doorbell=1, committed=2
    return c2 == 2 && m.last_doorbell_plxg == 1 && !m.coupledOk(/*live*/2, true);
}

// PRODUCT: two sequential publishes embed exact committed generations.
inline bool ddrPlxgDoorbellProductTwoPublishesMatch() {
    DdrPlxgDoorbellSeqModel m;
    constexpr uint16_t kPlanSeq = 1;
    const uint16_t c1 = m.writePlxg(kPlanSeq);
    m.kickDoorbell(kPlanSeq, c1, true);
    if (c1 != 1 || m.last_doorbell_plxg != 1 || !m.coupledOk(c1, true))
        return false;
    const uint16_t c2 = m.writePlxg(kPlanSeq);
    m.kickDoorbell(kPlanSeq, c2, true);
    return c2 == 2 && m.last_doorbell_plxg == 2 && m.coupledOk(c2, true);
}

// PRODUCT: daemon restart (software_last=0) with retained DDR q0=N.
inline bool ddrPlxgDoorbellProductDaemonRestartMatches() {
    DdrPlxgDoorbellSeqModel m;
    m.retained_valid = true;
    m.retained_seq = 7; // prior process left seq=7 in DDR
    m.software_last = 0; // new FpgaSpi object
    constexpr uint16_t kPlanSeq = 1;
    const uint16_t c = m.writePlxg(kPlanSeq);
    m.kickDoorbell(kPlanSeq, c, true);
    // plxgNextSeq(0, retained=7) → 8
    return c == 8 && m.last_doorbell_plxg == 8 && m.coupledOk(8, true);
}

// FAULT under restart: plan seq=1 embedded while committed=8.
inline bool ddrPlxgDoorbellFaultDaemonRestartMismatches() {
    DdrPlxgDoorbellSeqModel m;
    m.fault_embed_plan_seq = true;
    m.retained_valid = true;
    m.retained_seq = 7;
    m.software_last = 0;
    constexpr uint16_t kPlanSeq = 1;
    const uint16_t c = m.writePlxg(kPlanSeq);
    m.kickDoorbell(kPlanSeq, c, true);
    return c == 8 && m.last_doorbell_plxg == 1 && !m.coupledOk(8, true);
}

// rd-duck: full-canvas/mode-exit plans set program_plxg=true but used to leave
// plxg_seq=0. Embedding that 0 ungates the doorbell so legacy bank can swap
// while old runtime pitch is still live (B20 bank+geom mix).
// Model: native geom live at seq=5; disable commits seq=6.
struct DdrModeExitDoorbellModel {
    uint16_t live_geom_seq = 5;
    bool live_geom = true; // still native Option-C until disable promotes
    uint16_t software_last = 5;
    uint16_t bank_req_plxg = 0;
    bool bank_accepted = false;
    bool fault_embed_plan_zero = false; // REPRO: plan.plxg_seq=0 on disable

    uint16_t publishDisable() {
        // writePlxg bumps regardless of advisory plan seed
        const uint16_t committed =
            plxgNextSeq(software_last, /*ret*/ true, live_geom_seq);
        software_last = committed;
        const uint16_t planSeq = 0; // historical full-canvas seed
        const uint16_t door = fault_embed_plan_zero
                                  ? planSeq
                                  : ddrDoorbellPlxgSeqForPublish(/*program*/ true, committed);
        bank_req_plxg = door;
        // Bank accept under current live geom (disable not yet promoted).
        bank_accepted =
            ddrDoorbellGeomCoupledOk(bank_req_plxg, live_geom_seq, live_geom, false);
        return committed;
    }

    void promoteDisable(uint16_t committed) {
        live_geom_seq = committed;
        live_geom = true; // disable is still a live PLXG record (geom_enable=0)
        bank_accepted =
            ddrDoorbellGeomCoupledOk(bank_req_plxg, live_geom_seq, live_geom, false);
    }
};

// FAULT REPRO: plan.plxg_seq=0 on mode-exit → doorbell ungated → bank accepts
// under still-live native seq=5 before disable promotes.
inline bool ddrModeExitDoorbellFaultPlanZeroUngates() {
    DdrModeExitDoorbellModel m;
    m.fault_embed_plan_zero = true;
    const uint16_t c = m.publishDisable();
    if (c != 6)
        return false;
    if (m.bank_req_plxg != 0)
        return false;
    if (!ddrDoorbellPlxgSeqPublishIllegalUngated(true, m.bank_req_plxg))
        return false;
    // Defect: bank accepted while live is still native seq=5
    return m.bank_accepted;
}

// PRODUCT: mode-exit embeds committed disable seq; bank held until promote.
inline bool ddrModeExitDoorbellProductCoupledUntilPromote() {
    DdrModeExitDoorbellModel m;
    const uint16_t c = m.publishDisable();
    if (c != 6 || m.bank_req_plxg != 6)
        return false;
    if (ddrDoorbellPlxgSeqPublishIllegalUngated(true, m.bank_req_plxg))
        return false;
    // Held: live still 5, doorbell wants 6
    if (m.bank_accepted)
        return false;
    m.promoteDisable(c);
    return m.bank_accepted && m.live_geom_seq == 6;
}

// True legacy (no PLXG this frame): ungated is legal.
inline bool ddrModeExitDoorbellLegacyNoPlxgUngatedOk() {
    const uint16_t door = ddrDoorbellPlxgSeqForPublish(/*program*/ false, /*committed*/ 99);
    return door == 0 && !ddrDoorbellPlxgSeqPublishIllegalUngated(false, door) &&
           ddrDoorbellGeomCoupledOk(door, /*live*/ 5, true, false);
}

// rd-duck: SPI kick is bank_sel-only (no PLXG gen). Product fabric never
// accepts SPI (pre-promote !live used to swap native under idle 960). Host
// must not fall back to SPI for program_plxg. FAULT restores always-allow.
inline bool ddrSpiSwapOkUnderGeom(bool /*geomLive*/, uint16_t /*geomSeq*/,
                                  bool faultAllowSpiUngated = false) {
    if (faultAllowSpiUngated)
        return true;
    return false; // product: spi_swap_ok=0
}

// Host first-kick policy model (sendDdrFrame).
struct DdrCoupledKickPolicyModel {
    bool program_plxg = false;
    bool doorbell_acked = false; // busy/pending/has_frame within wait
    bool used_spi = false;
    bool refused = false;
    int wait_us = 0;
    bool fault_short_wait_spi = false; // REPRO: 23ms + SPI fallback

    void runFirstKick() {
        // One content frame @ 24.0007 Hz ≈ 41666 us; product pads to 50ms.
        constexpr int kCoupledUs = 50000;
        constexpr int kLegacyUs = 23000;
        wait_us = fault_short_wait_spi ? kLegacyUs
                                       : (program_plxg ? kCoupledUs : kLegacyUs);
        if (!doorbell_acked) {
            if (program_plxg && !fault_short_wait_spi) {
                refused = true; // product: no SPI under program_plxg
                used_spi = false;
                return;
            }
            // FAULT or legacy: SPI
            used_spi = true;
            refused = false;
            return;
        }
        used_spi = false;
        refused = false;
    }
};

// FAULT: short wait + SPI under program_plxg while live geom seq=5.
// SPI accepts bank under old pitch (fabric FAULT_SPI_UNGATED).
inline bool ddrCoupledKickFaultShortWaitSpiUngates() {
    DdrCoupledKickPolicyModel m;
    m.program_plxg = true;
    m.doorbell_acked = false; // publish just after boundary — ack after ~40ms
    m.fault_short_wait_spi = true;
    m.runFirstKick();
    if (!m.used_spi || m.refused || m.wait_us >= 41666)
        return false;
    // Fabric FAULT: SPI swap ok under live geom
    if (!ddrSpiSwapOkUnderGeom(/*live*/ true, /*seq*/ 5, /*fault*/ true))
        return false;
    return true; // REPRO path taken
}

// PRODUCT: program_plxg + no ack → refuse SPI; wait >= one frame.
inline bool ddrCoupledKickProductRefusesSpi() {
    DdrCoupledKickPolicyModel m;
    m.program_plxg = true;
    m.doorbell_acked = false;
    m.runFirstKick();
    if (!m.refused || m.used_spi)
        return false;
    if (m.wait_us < 41666)
        return false;
    // Fabric product: SPI never swaps (incl. pre-promote !live)
    if (ddrSpiSwapOkUnderGeom(true, 5, false))
        return false;
    if (ddrSpiSwapOkUnderGeom(false, 0, false))
        return false;
    return true;
}

// Delayed-promotion model: live=0, doorbell field!=0 → no bank accept;
// SPI → no accept. After live+match → doorbell may accept.
inline bool ddrDelayedPromotionNoSwapBeforeLive() {
    // Before live: coupled doorbell rejects (field!=0 && !live)
    if (ddrDoorbellGeomCoupledOk(/*db*/7, /*liveSeq*/7, /*live*/false, false))
        return false;
    if (ddrSpiSwapOkUnderGeom(false, 0, false))
        return false;
    // After live match: doorbell couples
    if (!ddrDoorbellGeomCoupledOk(7, 7, true, false))
        return false;
    return true;
}

// PRODUCT: program_plxg + ack within window → doorbell path, no SPI.
inline bool ddrCoupledKickProductDoorbellAck() {
    DdrCoupledKickPolicyModel m;
    m.program_plxg = true;
    m.doorbell_acked = true;
    m.runFirstKick();
    return !m.refused && !m.used_spi && m.wait_us >= 41666;
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

// 720p-tier acceptance for MB-aligned *coded canvas* sizes on Option-C map.
// 960x540 display content is NOT accepted here (540 not MB-aligned) — use
// ddrFrameStoreAcceptsOptionCContent / native_push into 1280x720 canvas.
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

// Option-C *content* acceptance (native_push display geometry).
// Width must be 16-aligned (chroma fetch = w>>4 qwords). Height even only —
// MB-align not required (540 is a valid display height). Capacity must need
// Option-C or explicitly fit under Option-C stride, and reject legacy-only path
// when payload overruns 512 KiB.
inline bool ddrFrameStoreAcceptsOptionCContent(int contentW, int contentH) {
    if (contentW <= 0 || contentH <= 0 || (contentW & 15) || (contentH & 1))
        return false;
    if (contentW > kDdrFrameStore720pMaxWidth.get() ||
        contentH > kDdrFrameStore720pMaxHeight.get())
        return false;
    const size_t frameBytes = yuv420pFrameBytes(contentW, contentH);
    if (frameBytes == 0)
        return false;
    if (frameBytes > static_cast<size_t>(kPlex720pYuv420pBankUsableBytes))
        return false;
    // Must actually need Option-C OR be placed on Option-C canvas deliberately.
    // Oversize-for-legacy is the product 960x540 case.
    return true;
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
// Archive pure-fill (p480-bandwidth.md) — superseded for 720p budget by parent
// 2026-08-03 ddr_write_bench mapped-bank measure (kept for comparison only).
constexpr double kDdrArchiveNoSyncMibps = 59.521;
// Parent mapped-bank / host-copy rates: ddr_mem_map_policy.hpp
// Default budget projection uses mapped-bank rate (proven on device).
constexpr double kParentDdrMappedBankMibps = kParentDdrMappedBank720pMibps;
constexpr double kDdrBudgetCopyMibps = kParentDdrMappedBank720pMibps;
// FEED archive scale-stage wall bucket (ms/f) — recovered only when ARM stops vf scale.
constexpr double kFeedArchiveScaleMs = 2.95;
// FEED archive product present wall mean (ms/f) — not equal to pure copy.
constexpr double kFeedArchivePresentMs = 10.41;
// FEED non-decode ARM buckets @480p (present+pipe+scale), quoted parent rollup.
constexpr double kFeedArchiveNonDecodeMs = 10.411 + 5.263 + 2.954; // 18.628
// Parent device real-content 720p decode-only (both cores), ms/f.
// Cross-session archive (2026-08-02, do not interpolate across sessions):
//   1500k 32.427 | 2500k 36.845 | 3500k 38.751 | 4000k 41.073
// In-session product-tier re-anchor (parent HW evidence #3, 2026-08-03):
//   maxBR geometry floor = 3100 kbit (w-path d273d6f8; below → 720x404)
//   server content ~2585k at maxBR=3100; controlled 2600k asset mean 36.27 ms/f
//   same-session 2500k re-measure 35.87 ms/f (not archive 36.845)
//   margin @24fps = 41.667-36.27 = 5.40 ms. Serial+copy still FAIL (~51.55).
// Candidate pin: maxBR 3100 / content-rate decode 36.27 ms/f.
// Headroom is jitter/overlap margin ONLY — not permission for ARM memcpy.
constexpr double kParent720pDecodeMs1500k = 32.427;
constexpr double kParent720pDecodeMs2500kArchive = 36.845; // cross-session archive
constexpr double kParent720pDecodeMs2500k = 35.87;         // in-session re-anchor
constexpr double kParent720pDecodeMs2600k = 36.27;         // product-tier content
constexpr double kParent720pDecodeMs3500k = 38.751;        // archive
constexpr double kParent720pDecodeMs4000k = 41.073;
// Default keeps the 4000k figure for conservative residual.
constexpr double kParent720pDecodeMsDefaultThreads = kParent720pDecodeMs4000k;
constexpr double kParent480pDecodeMsDefaultThreads = 15.969;
constexpr double kFrameBudget24fpsMs = 41.667;

// ---- Product path: 720p OUTPUT from intermediate source (parent 2026-08-03) ----
// Measured proxies (Constrained Baseline, real PMS content re-encode), 300 frames,
// instrument control 1280x720 proxy within 0.4% of genuine PMS decode. 5/5 HIT.
// This is 720p *output* (fabric upscale to Option-C 1280x720 canvas). NOT 720p source.
// DMA (w-path) remains the upgrade to true 1280x720 source (~kill 14.97 ms copy).
// Caveat (parent): -f null is decode-only upper bound on headroom — not E2E promise.
//
// Coded vs display (H.264 16×16 MB grid):
//   Display / PMS picture   : 960×540  (540 & 15 == 12 — NOT MB-aligned)
//   MB-aligned coded size   : 960×544  (ceil(540/16)*16) — bitstream/DPB only
//   Bank canvas (Option-C)  : 1280×720 — MB-aligned; PLXG geometry beat
//   native_push payload     : DISPLAY 960×540 tight I420 = 777600 B
//   Fabric reader strides   : DISPLAY (960/480); plane offs from display dims
//   783360 (960×544 I420) must NOT be used as native_push publish_bytes.
constexpr int kPlex720pOutputSourceWidth = 960;          // display (= coded W)
constexpr int kPlex720pOutputSourceHeight = 540;         // display
constexpr int kPlex720pOutputSourceDisplayWidth = 960;
constexpr int kPlex720pOutputSourceDisplayHeight = 540;
constexpr int kPlex720pOutputSourceCodedWidth = 960;
constexpr int kPlex720pOutputSourceCodedHeight = 544; // MB-align 540
// Literals so rtl_invariants parity parser matches .svh.
constexpr int kPlex720pOutputSourceBytes = 777600; // DISPLAY tight I420
constexpr int kPlex720pOutputSourceDisplayBytes = 777600;
constexpr int kPlex720pOutputSourceCodedBytes = 783360; // 960*544*3/2 — not native_push
// Tight native I420 plane contract (mirror ddr_frame_layout_params.svh).
// Fabric reader MUST use these when PLXG native_push=1 — not canvas 1280/640.
constexpr int kPlex720pOutputYStrideBytes = 960;
constexpr int kPlex720pOutputChromaStrideBytes = 480;
constexpr int kPlex720pOutputYPlaneOffset = 0;
constexpr int kPlex720pOutputUPlaneOffset = 518400;
constexpr int kPlex720pOutputVPlaneOffset = 648000;
constexpr int kPlex720pOutputYLineQwords = 120;
constexpr int kPlex720pOutputChromaLineQwords = 60;
// Parent wall ms — corrected 2026-08-03 (decode+sws, not -f null alone).
// Sweep-18 proxy decode-only 22.75 was optimistic by ~3.33 ms on product total.
// Device conf: FFMPEG_SWS_FLAGS=fast_bilinear, DDR_YUV_FORCE_SCALE=1.
constexpr double kParent960x540DecodeOnlyMs = 22.51;          // -f null remeasure
constexpr double kParent960x540DecodeOnlyMsProxyArchive = 22.75; // sweep-18 proxy
constexpr double kParent960x540DecodeSwsOutMs = 26.08;        // decode+sws+rawvideo
constexpr double kParent960x540SwsOverheadMs = 3.57;          // 26.08 - 22.51
// Alias: product path MUST budget sws/out, not decode-only.
constexpr double kParent960x540DecodeMs = kParent960x540DecodeSwsOutMs;
constexpr double kParent960x540CopyMs = 8.42; // native I420 @ structural ~88 MiB/s
constexpr double kParent960x540TotalMs = 34.50;   // 26.08 + 8.42 product
constexpr double kParent960x540MarginMs = 7.16;   // vs 41.667 — PASS, not +10.49
constexpr double kParent960x540DecodeOnlyTotalMs = 31.17; // archive decode-only+copy
constexpr double kParent960x540DecodeOnlyMarginMs = 10.49; // retracted as ship figure
// Sibling probes (decode-only proxy table) — 1024x576 still too thin.
constexpr double kParent1024x576DecodeMs = 26.03;
constexpr double kParent1024x576CopyMs = 9.58;
constexpr double kParent1024x576TotalMs = 35.61;
constexpr double kParent1024x576MarginMs = 6.05;
constexpr double kParent854x480DecodeMs = 20.70;
constexpr double kParent854x480CopyMs = 6.66;
constexpr double kParent854x480TotalMs = 27.36;
constexpr double kParent854x480MarginMs = 14.31;
// True 720p source still FAIL with CPU copy (control + PMS):
constexpr double kParent720pSourceDecodeProxyMs = 35.33;
constexpr double kParent720pSourceCopyMs = 14.97;
constexpr double kParent720pSourceTotalMs = 50.31;
constexpr double kParent720pSourceMarginMs = -8.64;
// TRAP: fetch 720p and ARM-downscale (parent arms C/D) — FAIL before copy.
constexpr double kParent720pArmDownscaleTo960Ms = 51.78;
constexpr double kParent720pArmDownscaleTo624Ms = 44.95;
// Product margin floor = measured +7.16 path (not the retracted +10.49 decode-only).
// Concurrent peer still dangerous; E2E cast is parent-only proof.
constexpr double kPlex720pOutputMinMarginMs = 7.0;

static_assert(kPlex720pOutputSourceBytes == 777600, "960x540 I420 bytes");
static_assert(kPlex720pOutputSourceDisplayBytes == kPlex720pOutputSourceBytes, "display alias");
static_assert(kPlex720pOutputSourceCodedBytes == 783360, "MB-coded 960x544 I420");
static_assert(kPlex720pOutputSourceCodedBytes != kPlex720pOutputSourceDisplayBytes,
              "coded vs display must not be conflated");
static_assert((kPlex720pOutputSourceDisplayHeight & 15) != 0, "540 is not MB-aligned");
static_assert((kPlex720pOutputSourceCodedHeight & 15) == 0, "544 is MB-aligned");
static_assert(kPlex720pOutputSourceWidth < 1280 && kPlex720pOutputSourceHeight < 720,
              "source is intermediate; canvas is 720p");
static_assert(kPlex720pOutputUPlaneOffset == 518400, "960x540 U plane");
static_assert(kPlex720pOutputVPlaneOffset == 648000, "960x540 V plane");
static_assert(kPlex720pOutputYStrideBytes != kPlex720pYStrideBytes,
              "native content stride must differ from canvas 1280");
static_assert(kPlex720pOutputSourceBytes < kPlex720pYuv420pBankUsableBytes,
              "960x540 must fit Option-C usable capacity (stride-4KiB)");
static_assert(kPlex720pOutputSourceBytes > kPlex480pYuv420pBankUsableBytes,
              "960x540 must NOT fit legacy usable capacity — forces Option-C");
static_assert(kDdrLegacyUsableEdgeBytes > kPlex480pYuv420pBankUsableBytes &&
                  kDdrLegacyUsableEdgeBytes < kPlex480pYuv420pBankStride,
              "rd-duck edge: 720x482 fits full stride but not usable");

// Tight native I420 layout for a content rectangle (native_push=1).
// Planes are contiguous with content strides — NOT canvas line_bytes.
// Fabric reader MUST use these strides when native_push is set; using canvas
// 1280-stride on a 960-wide tight payload shears the image (88509163-class).
struct DdrNativeContentLayout {
    int width = 0;
    int height = 0;
    int y_stride = 0;      // == width
    int chroma_stride = 0; // == width/2
    uint32_t y_offset = 0;
    uint32_t u_offset = 0;
    uint32_t v_offset = 0;
    size_t frame_bytes = 0;
    int y_line_qwords = 0;
    int chroma_line_qwords = 0;
    bool valid = false;
};

inline DdrNativeContentLayout makeDdrNativeContentLayout(int w, int h) {
    DdrNativeContentLayout c{};
    // w%16: fabric chroma fetch is w>>4 qwords; w%2 alone is not enough (968 trap).
    if (w <= 0 || h <= 0 || (w & 15) || (h & 1))
        return c;
    c.width = w;
    c.height = h;
    c.y_stride = w;
    c.chroma_stride = w / 2;
    c.y_offset = 0;
    const uint32_t y_bytes = static_cast<uint32_t>(w) * static_cast<uint32_t>(h);
    const uint32_t c_bytes = static_cast<uint32_t>(c.chroma_stride) * static_cast<uint32_t>(h / 2);
    c.u_offset = y_bytes;
    c.v_offset = y_bytes + c_bytes;
    c.frame_bytes = static_cast<size_t>(y_bytes + 2u * c_bytes);
    c.y_line_qwords = w / 8;
    c.chroma_line_qwords = c.chroma_stride / 8; // == w/16 when w%16==0
    c.valid = (c.frame_bytes == yuv420pFrameBytes(w, h)) && (c.y_line_qwords * 8 == w) &&
              (c.chroma_line_qwords * 8 == c.chroma_stride) &&
              (c.chroma_line_qwords == (w >> 4)) && ((c.chroma_stride % 8) == 0);
    return c;
}

inline DdrNativeContentLayout plex960x540NativeContentLayout() {
    return makeDdrNativeContentLayout(kPlex720pOutputSourceWidth, kPlex720pOutputSourceHeight);
}

// Tight content must fit bank *usable* payload (stride − doorbell page), matching
// ddrFrameLayoutValid's bank1End <= doorbell rule. Full-stride compare is wrong.
inline bool ddrNativeContentFitsBank(const DdrNativeContentLayout& c, uint32_t bank_stride) {
    const uint32_t usable = ddrBankUsablePayloadBytes(bank_stride);
    return c.valid && c.frame_bytes > 0 && c.frame_bytes <= static_cast<size_t>(usable);
}

// PMS maxBR floor for real 1280x720 (w-path). Content bitrate ~2600k class.
constexpr int kPlex720pCandidateBitrateKbit = 3100;
constexpr int kPlex720pCandidateContentBitrateKbit = 2600;
constexpr double kParent720pDecodeMsCandidateTier = kParent720pDecodeMs2600k;
// Alias kept for older call sites that said "3500 floor".
constexpr double kParent720pDecodeMsPmsFloorArchive = kParent720pDecodeMs3500k;
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

// Accept 720p-OUTPUT product path: native push of intermediate source into Option-C
// canvas with fabric scale. Distinct from ddr720p24ShipAcceptsZeroArmPerPixel (true
// 720p source / FPGA-written banks).
// armNonCopyMs MUST include sws/output when that work is on the ARM (parent 26.08),
// not decode-only -f null (22.51). Default = kParent960x540DecodeSwsOutMs.
inline bool ddr720pOutputProductPathAccepts(
    const DdrArmPresentBudget& b, double armNonCopyMs = kParent960x540DecodeSwsOutMs,
    double marginFloorMs = kPlex720pOutputMinMarginMs) {
    if (!b.valid || !b.arm_still_pushes_pixels || b.arm_push_bytes == 0)
        return false;
    if (!b.fabric_owned)
        return false; // must not ARM scale/pad into canvas
    // Refuse the trap path: ARM downscale-from-720p already exceeds the deadline.
    if (armNonCopyMs >= kFrameBudget24fpsMs)
        return false;
    const double total = armNonCopyMs + b.arm_copy_ms;
    const double margin = kFrameBudget24fpsMs - total;
    return margin >= marginFloorMs;
}

// Explicit reject: fetch 720p and shrink on ARM (parent 51.78 / 44.95 ms).
inline bool ddr720pArmDownscalePathRejected(double armDownscaleMs) {
    return armDownscaleMs >= kFrameBudget24fpsMs ||
           armDownscaleMs >= kParent720pArmDownscaleTo960Ms - 0.01;
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


// Build the fabric-owned present contract for a content rectangle inside a tier
// canvas. publish_bytes == native I420 only; PLXG must carry the window.
//
// B14 policy (w-mem, library N=142): coded_w MUST be %16==0 (RTL rt_raw_aligned).
// Live PMS has 4 titles at 426×240 (426%16=10). Host PADS storage coded_w up
// (426→432), keeps display_w=source, crop_right=pad. Guard stays loud reject
// if unaligned storage ever reaches fabric — never weaken B14.
struct DdrFabricOwnedPresentPlan {
    DdrNativePushPlan native{};
    DdrArmPresentBudget budget{};
    DdrPresentOffload offload = DdrPresentOffload::None;
    // Bank geometry (tier) — fabric still double-buffers at this stride.
    DdrFrameGeometry canvas{};
    DdrFrameLayout canvas_layout{};
    // Tight content plane layout (strides/offsets) — NOT canvas line_bytes.
    // Uses *storage* coded dims after B14 pad (y_stride == content_w).
    DdrNativeContentLayout content_layout{};
    // Storage rectangle ARM writes (16-aligned coded; may exceed display).
    int content_w = 0;
    int content_h = 0;
    // Visible source before B14 right-pad (display_*); crop_right = content_w - display_w.
    int display_w = 0;
    int display_h = 0;
    int crop_right = 0;
    int content_x0 = 0; // even-aligned; fabric placement
    int content_y0 = 0;
    // Bytes ARM may memcpy — NEVER canvas frame_bytes on this path.
    size_t publish_bytes = 0;
    // Atomic 5-qword PLXG record (present_geom_latch). NOT three temporal beats.
    // q[0..4] written contiguously at bootstrap phys 0x300FF800 before doorbell.
    uint64_t plxg_q[6]{};
    uint16_t plxg_seq = 1;
    // Legacy single-word fields retained for tests that decode Q0/window-shaped
    // views — populated as aliases of the atomic record, not separate wire beats.
    uint64_t plxg_word = 0;
    uint64_t plxg_window_word = 0;
    uint64_t plxg_origin_word = 0;
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
        armPushesPixels ? ddrPushMsAtRate(native.native_bytes, kDdrBudgetCopyMibps) : 0.0;
    b.canvas_copy_ms = ddrPushMsAtRate(native.canvas_bytes, kDdrBudgetCopyMibps);
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

// Fabric-owned present plan.
//   contentW/H  = requested visible source (may be unaligned, e.g. 426×240).
//                 B14 pad promotes STORAGE coded_w = align16(contentW); display
//                 stays contentW; crop_right absorbs the pad columns.
//   canvasGeom  = DE/glass canvas (scaler output) — e.g. 1280x720; NOT storage
//   bank map    = capacity-selected from *padded* content payload
// PLXG: q1 content window = display; q2 coded = storage; q3 display+storage strides.
// Plane bases follow STORAGE so U/V match native_push (rd-duck #3).
inline DdrFabricOwnedPresentPlan makeDdrFabricOwnedPresentPlan(
    int contentW, int contentH, const DdrFrameGeometry& canvasGeom,
    uint32_t canvasPhysBase = kDdrFramePhysBase, int contentX0 = 0, int contentY0 = 0,
    bool countFeedScaleRemoval = true) {
    DdrFabricOwnedPresentPlan p{};
    p.canvas = canvasGeom;
    // B14: never program unaligned coded_w. Pad storage; keep display = source.
    const DdrNativePaddedLayout pad = makeDdrNativePaddedLayout(contentW, contentH);
    if (!pad.valid)
        return p;
    const int storW = pad.coded_w;
    const int storH = pad.coded_h;
    const int dispW = pad.display_w;
    const int dispH = pad.display_h;
    p.content_w = storW;
    p.content_h = storH;
    p.display_w = dispW;
    p.display_h = dispH;
    p.crop_right = pad.crop_right;
    p.content_x0 = contentX0 & ~1;
    p.content_y0 = contentY0 & ~1;
    p.offload = kDdrPresentOffloadFabricOwned;
    // native_bytes / plane layout use STORAGE (padded) dims.
    p.native = makeDdrNativePushPlan(storW, storH, canvasGeom);
    if (!p.native.valid)
        return p;
    if (p.content_x0 < 0 || p.content_y0 < 0)
        return p;
    // Storage rectangle must fit inside the DE canvas, not redefine it.
    if (p.content_x0 + storW > canvasGeom.coded_width.get() ||
        p.content_y0 + storH > canvasGeom.coded_height.get())
        return p;
    // Map tier from padded storage usable capacity; phys base must match the map.
    const DdrBankMap map = ddrSelectBankMapForContent(storW, storH);
    const uint32_t mapBase = (map == DdrBankMap::OptionC720p) ? kPlex720pDdrFramePhysBase
                                                              : kDdrFramePhysBase;
    // If caller passed a canvas phys base, prefer it only when it matches the map
    // (Option-C callers pass kPlex720pDdrFramePhysBase). Mismatch → reject.
    if (canvasPhysBase != mapBase && canvasPhysBase != kDdrFramePhysBase &&
        canvasPhysBase != kPlex720pDdrFramePhysBase)
        return p;
    const uint32_t phys = (map == DdrBankMap::OptionC720p)
                              ? ((canvasPhysBase == kPlex720pDdrFramePhysBase ||
                                  canvasPhysBase == kDdrFramePhysBase)
                                     ? kPlex720pDdrFramePhysBase
                                     : canvasPhysBase)
                              : kDdrFramePhysBase;
    // canvas_layout describes the *bank window* (stride/doorbell/map) for the tier.
    // Use fixed product/Option-C layout geometry for the map, not content dims.
    const DdrFrameGeometry mapGeom = ddrCanvasGeometryForBankMap(map);
    p.canvas_layout = makeDdrFrameLayout(mapGeom, phys, kDdrFrameStrideAlign);
    // For Option-C product, pin fixed stride/doorbell even if alignUp would differ.
    if (map == DdrBankMap::OptionC720p) {
        p.canvas_layout.phys_base = kPlex720pDdrFramePhysBase;
        p.canvas_layout.bank_stride = kPlex720pYuv420pBankStride;
        p.canvas_layout.doorbell_phys = kPlex720pYuv420pDoorbellPhys;
        p.canvas_layout.map_bytes = kPlex720pYuv420pBankStride * 2u;
    }
    if (!ddrFrameLayoutValid(p.canvas_layout))
        return p;
    p.publish_bytes = pad.payload_bytes;
    p.content_layout = makeDdrNativeContentLayout(storW, storH);
    if (!p.content_layout.valid || p.content_layout.frame_bytes != p.publish_bytes)
        return p;
    if (!ddrNativeContentFitsBank(p.content_layout, p.canvas_layout.bank_stride))
        return p;
    // Content strides must not silently equal canvas when geometry differs.
    if (p.content_w != mapGeom.coded_width.get() &&
        p.content_layout.y_stride == p.canvas_layout.line_bytes)
        return p;
    // native_push publish length must be display storage, never MB-coded 544 path.
    // Compare against *requested* source (pre-pad) identity for the 960×540 product.
    if (contentW == kPlex720pOutputSourceWidth && contentH == kPlex720pOutputSourceHeight &&
        p.publish_bytes != static_cast<size_t>(kPlex720pOutputSourceDisplayBytes))
        return p;
    p.budget = makeDdrArmPresentBudget(p.native, p.offload, countFeedScaleRemoval,
                                       /*armPushesPixels=*/true);
    // Atomic 6-qword PLXG. STORAGE coded/stride; DISPLAY in content+display fields.
    const int deW = canvasGeom.presented_width.get() > 0 ? canvasGeom.presented_width.get()
                                                         : canvasGeom.coded_width.get();
    const int deH = canvasGeom.presented_height.get() > 0 ? canvasGeom.presented_height.get()
                                                          : canvasGeom.coded_height.get();
    // Non-zero seed for host latch models; writePlxgRecord always advances past last.
    p.plxg_seq = 1;
    p.plxg_q[0] = packPlxgQ0(/*win*/ true, /*geom*/ true, /*seq*/ 1);
    // q1 content window = visible display (scaler input), not padded storage.
    p.plxg_q[1] = packPlxgQ1(dispW, dispH, p.content_x0, p.content_y0);
    p.plxg_q[2] = packPlxgQ2(deW, deH, storW, storH);
    p.plxg_q[3] = packPlxgQ3(p.content_layout.y_stride, p.content_layout.chroma_stride,
                             dispW, dispH);
    // crop_left=0; crop_right implied as coded_w - display_w (pad columns).
    p.plxg_q[4] = packPlxgQ4(0, 0, /*crop_left*/ 0, /*crop_top*/ 0);
    p.plxg_q[5] = packPlxgQ5(/*dar_x*/0, /*dar_y*/0, /*fps*/0,
                           /*dar_valid*/false, /*fps_valid*/false);
    // Aliases for older tests (not separate wire beats).
    p.plxg_word = p.plxg_q[0];
    p.plxg_window_word = p.plxg_q[1];
    p.plxg_origin_word = packPlxgQ1(0, 0, p.content_x0, p.content_y0); // x0/y0 view
    p.valid = p.budget.valid && p.plxg_q[0] != 0 &&
              plxgGeomDimsOk(storW, storH, p.content_layout.y_stride,
                             p.content_layout.chroma_stride) &&
              (storW == dispW + p.crop_right) &&
              ddrRtRawWindowOk(storW, storH, dispW, dispH, /*crop_l*/ 0, /*crop_t*/ 0);
    return p;
}


// Product 720p-OUTPUT plan: ARM decodes 960x540 tight I420, native-pushes into
// Option-C 1280x720 bank; fabric scales (w-scaler). publish_bytes = 777600.
inline DdrFabricOwnedPresentPlan makePlex720pOutputFrom540pSourcePlan(
    uint32_t canvasPhysBase = kPlex720pDdrFramePhysBase, bool countFeedScaleRemoval = false) {
    return makeDdrFabricOwnedPresentPlan(
        kPlex720pOutputSourceWidth, kPlex720pOutputSourceHeight, plex720pDdrFrameGeometry(),
        canvasPhysBase, 0, 0, countFeedScaleRemoval);
}

// FPGA-written banks: ARM publishes **zero** pixel bytes. Fabric decode/MC/IDCT
// (or other fabric producer) fills Option-C / product banks; ARM only programs
// PLXG + rings doorbell / feeds bitstream ring. This is the only present path
// that can meet ddr720p24ShipAcceptsZeroArmPerPixel. Serial ARM decode+bank
// copy is DEAD at every tier (Sweep-3 best bank 15.283 ms; product 2600k
// decode 36.27 → serial sum ~51.55). Host-copy ordinary RAM is unreachable.
// Fabric publish_bytes=0 is the only ship path; PL330 overlap unproven concurrent.
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
// Default decodeMs is 4000k (worst archive). Pass kParent720pDecodeMsCandidateTier
// (2600k product content / maxBR 3100) for delivery residual (~5.40 ms).
inline double ddr720p24ResidualMsAfterDecodeOnly(
    double decodeMs = kParent720pDecodeMsDefaultThreads,
    double budgetMs = kFrameBudget24fpsMs) {
    return budgetMs - decodeMs;
}

// True when a projected ARM copy term alone would blow residual at the given tier.
inline bool ddr720p24ArmCopyExceedsDecodeMarginAt(size_t armPushBytes, double decodeMs) {
    const double copyMs = ddrPushMsAtRate(armPushBytes, kDdrBudgetCopyMibps);
    return copyMs > ddr720p24ResidualMsAfterDecodeOnly(decodeMs);
}

// Conservative: exceeds even the 4000k residual (0.59 ms).
inline bool ddr720p24ArmCopyExceedsDecodeMargin(size_t armPushBytes) {
    return ddr720p24ArmCopyExceedsDecodeMarginAt(armPushBytes,
                                                 kParent720pDecodeMsDefaultThreads);
}

// Candidate product tier: full 720p ARM bank copy ~15.28 ms >> residual ~5.40 ms.
// Ship gate remains publish_bytes=0 (serial still fails by ~9.9 ms).
inline bool ddr720p24ArmCopyExceedsCandidateTierMargin(size_t armPushBytes) {
    return ddr720p24ArmCopyExceedsDecodeMarginAt(armPushBytes,
                                                 kParent720pDecodeMsCandidateTier);
}

// Jobs fabric-owned present **forbids** on ARM (compile-time documentation via
// tests). Returning true means the named ARM helper must not run on this path.
inline bool fabricOwnedForbidsArmCanvasPack() { return true; }
inline bool fabricOwnedForbidsArmFfmpegScalePad() { return true; }
inline bool fabricOwnedForbidsArmClearYuvCropPad() { return true; }

inline uint32_t plxgMailboxPhys(uint32_t doorbellPhys) {
    return doorbellPhys + kDdrFramePlxgOffset;
}

// PLXC/PLXO/list — always control bootstrap page (not active frame doorbell).
// Option-C frame doorbell 0x3047F000 + 0x130 is a FAULT write target (rd-duck).
inline uint32_t plxcControlPhys() { return mailbox_abi::plxcControlPhys(); }
inline uint32_t plxoControlPhys() { return mailbox_abi::plxoControlPhys(); }
inline uint32_t plxlControlPhys() { return mailbox_abi::plxlControlPhys(); }

// Product host policy: ignore active frame map when publishing chrome.
inline uint32_t plxcPhysForActiveFrameDoorbell(uint32_t /*active_frame_doorbell*/) {
    return plxcControlPhys();
}
// FAULT twin: follow active frame doorbell (splits under Option-C / example base).
inline uint32_t plxcPhysFaultFollowFrameDoorbell(uint32_t active_frame_doorbell) {
    return mailbox_abi::plxcPhysFaultFromActiveDoorbell(active_frame_doorbell);
}
// Loader default phys (module param DOORBELL_PHYS + 0x130).
inline uint32_t plxcProductLoaderPhys() {
    return kDdrFramePlxcBootstrapPhys;
}
// Legacy↔Option-C transition: host+loader stay on bootstrap while frame db moves.
inline bool plxcMapStableAcrossFrameDoorbellChange(uint32_t leg_db, uint32_t optc_db) {
    const uint32_t h_leg = plxcPhysForActiveFrameDoorbell(leg_db);
    const uint32_t h_opt = plxcPhysForActiveFrameDoorbell(optc_db);
    return h_leg == h_opt && h_leg == plxcProductLoaderPhys() &&
           mailbox_abi::plxcPhysMatchesProductLoader(h_leg);
}
// FAULT: following frame doorbell diverges loader vs host under Option-C.
inline bool plxcMapFaultFollowFrameDivergesUnderOptionC(uint32_t leg_db, uint32_t optc_db) {
    const uint32_t loader = plxcProductLoaderPhys();
    const uint32_t host_opt = plxcPhysFaultFollowFrameDoorbell(optc_db);
    const uint32_t host_leg = plxcPhysFaultFollowFrameDoorbell(leg_db);
    // Under legacy product db, fault may still match loader; under Option-C it must not.
    return host_leg == loader && host_opt != loader;
}

} // namespace misterplex
