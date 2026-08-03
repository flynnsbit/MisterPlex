#pragma once
// w-path public symbol roll-call — single greppable SSoT for merge-drop detection.
//
// Parent 2026-08-03: first integration merge silently dropped
// ddrStorageGeometryForContent / ddrFfmpegGeometryForPresent / 360p symbols
// while git recorded a clean merge. This header + test_path_public_symbols
// fail loudly if any required symbol disappears.
//
// Do NOT remove entries without parent arbitration. Add new path ABI exports here.

#include "libmisterplex/ddr_frame_layout.hpp"
#include "libmisterplex/h264_fabric_stream_gate.hpp"
#include "libmisterplex/plxg_q5_aspect_cadence.hpp"
#include "libmisterplex/pms_delivery_geom.hpp"

#include <type_traits>

namespace misterplex {
namespace path_symbols {

// --- Geometry / bank (ddr_frame_layout.hpp) ---
static_assert(kPlex360pCodedWidth.get() == 640, "360p width symbol");
static_assert(kPlex360pCodedHeight.get() == 360, "360p height symbol");
static_assert(kPlex540pCodedWidth.get() == 960, "540p width symbol");
static_assert(kPlex540pCodedHeight.get() == 540, "540p height symbol");
static_assert(kPlex720pCodedWidth.get() == 1280, "720p width symbol");
static_assert(kPlex720pCodedHeight.get() == 720, "720p height symbol");

using DdrStorageGeometryForContentFn = DdrFrameGeometry (*)(int, int);
using DdrFfmpegGeometryForPresentFn = DdrFrameGeometry (*)(int, int);
using DdrFrameGeometryForFpgaPresentFn = DdrFrameGeometry (*)(int, int);

inline constexpr DdrStorageGeometryForContentFn kSymDdrStorageGeometryForContent =
    &ddrStorageGeometryForContent;
inline constexpr DdrFfmpegGeometryForPresentFn kSymDdrFfmpegGeometryForPresent =
    &ddrFfmpegGeometryForPresent;
inline constexpr DdrFrameGeometryForFpgaPresentFn kSymDdrFrameGeometryForFpgaPresent =
    &ddrFrameGeometryForFpgaPresent;

// --- PLXG q5 aspect/cadence (path ABI #2 publish) ---
static_assert(kPlxgQ5ByteOffset == 0x828u, "PLXG q5 offset");
static_assert(kPlxgRecordQwordsAspectCadence == 6u, "PLXG 6-qword record");

// --- Source-aware PMS request + DP native store ---
// selectSourceAwarePmsRequest / selectDirectPartStoreGeometry must remain
// greppable in pms_delivery_geom.hpp (rd-duck: DP early-return bank).

inline const char* pathPublicSymbolRollCall() {
    // Touch every symbol so -O2 cannot DCE the references in the unit test TU.
    const auto g1 = kSymDdrStorageGeometryForContent(640, 360);
    const auto g2 = kSymDdrFfmpegGeometryForPresent(960, 540);
    const auto g3 = kSymDdrFrameGeometryForFpgaPresent(624, 480);
    (void)g1;
    (void)g2;
    (void)g3;
    (void)kPlex360pCodedWidth;
    (void)kPlex360pCodedHeight;
    PlxgAspectCadence c{};
    uint64_t q = 0;
    (void)packPlxgQ5(c, &q);
    (void)selectPlxgAspectCadence(0, 0, "", "", 0, 0);
    (void)selectSourceAwarePmsRequest(624, 480, 960, 540);
    (void)selectDirectPartStoreGeometry(320, 240);
    (void)classifyPathScaleClass("transcode_request", false, true, false);
    (void)pathScaleClassName(PathScaleClass::ArmScaleFallback);
    uint8_t fps = 0;
    bool f1001 = false;
    (void)contentFpsForPlxg(24000, 1001, &fps, &f1001);
    (void)kPlxgQ5Fps1001Bit;
    // Fabric bitstream gate disposition (Refuse* → ARM fallback, not outage).
    FabricStreamGateResult gr;
    gr.ok = false;
    gr.verdict = FabricStreamVerdict::RefuseProfile;
    (void)fabricDecodeRoute(gr);
    (void)fabricDecodeRouteStr(FabricDecodeRoute::ArmFfmpegFallback);
    (void)armFfmpegDecodeRequired(gr);
    (void)fabricBitstreamPathOpen(gr);
    // miss #15: xcode never fabric-eligible (lying CB metadata).
    (void)fabricDecodeRouteForPmsDecision(true, "constrained baseline");
    (void)gateFabricFromPmsDelivery(true, "constrained baseline");
    (void)fabricBitstreamPathOpenForPmsDelivery(true, gr);
    return "path_public_symbols_ok";
}

} // namespace path_symbols
} // namespace misterplex
