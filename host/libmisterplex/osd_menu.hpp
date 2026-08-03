#pragma once
// Decoding of the core's OSD menu word (status[15:0]) into daemon settings.
//
// Why status[15:0] and nothing above: when the core raises status_set,
// Main_MiSTer *replaces* the whole 128-bit OSD word with status_in. Plex.sv echoes
// only status[15:0] back, so every user-settable menu bit must live down there —
// everything above is Phase-3 telemetry (residual csum, NAL counts) whose byte
// layout is protocol-locked. See Plex.sv "Layout v2 (OSD-safe, 128b)".
//
// Bit budget after reclaiming the debug items (Content FPS / Pattern / Audio tone /
// Force bars), which are obsolete now that the daemon detects the exact rational
// rate itself:
//
//   [0]      Reset            (core)
//   [1]      A/V resync       0=On 1=Off
//   [2]      TV Mode          (core)
//   [3]      Audio clock trim 0=On (685 ppm) 1=Off
//   [5:4]    Content tier     2-bit (v8 ABI; v7 cores only drive bit4, bit5=0):
//                             00 = 240p coded 320x240 (power-on default)
//                             01 = 480p coded 624x480 (menu label may say 640x480
//                                  presented scanout; PMS/decode use 624x480)
//                             10 = 16:9-framed 480p canvas — SAME DDR geometry and
//                                  PMS ladder as 01. Host letterboxes 16:9 into the
//                                  existing 624x480 contract. NOT native 720p and
//                                  MUST NOT be described as 720p to users.
//                             11 = reserved — host falls back to 480p canvas
//   [9:6]    A/V offset       4-bit SIGNED, 20 ms per step -> -160..+140 ms.
//                             Signed (not biased) so the power-on value 0 means
//                             0 ms without needing a non-zero CONF_STR default,
//                             which Main_MiSTer cannot express.
//   [10]     T Flush audio FIFO      (core)
//   [11]     T Flush bitstream FIFO  (core)
//   [12:13]  reserved for HPS DDR kick/bank — never reuse
//   [15:14]  Idle screen      0=Logo 1=Black 2=Screensaver 3=Last frame
//
// Config version: shipping cores use v7 (O[4] only). Staged RTL CONF_STR uses v8
// so Main clears status[5:4] on upgrade (same hazard class as v7 clearing bit4).
// Host decodes both: v7 words have bit5=0 so 00/01 match the old 1-bit map.
//
// Pure decode so it can be unit-tested without an FPGA.
//
// CONF_STR file slots (`F1,raw,...`) and controller labels (`J1,...`) are menu
// metadata only. They do not allocate OSD status bits.

#include <cstdint>

#include "libmisterplex/ddr_frame_layout.hpp"

namespace misterplex {

// Step/bias of the video delay list. Kept here so the CONF_STR generator, the
// daemon and the tests cannot disagree about what a menu index means.
constexpr int kOsdAvOffsetSteps = 16;
constexpr int kOsdAvOffsetStepMs = 20;
constexpr int kPlex240pWeakBitrateKbps = 1000;
constexpr int kPlex360pWeakBitrateKbps = 1500;
constexpr int kPlex480pWeakBitrateKbps = 2000;
// Dual 720p bitrate contract (lab PMS + parent device decode, 2026-08-03):
//
// 1) Decode-optimal CONTENT bitrate for already-1280x720 CB (parent device):
//      1500 kbit → 32.427 ms/f (77.8% of 41.667) — **8.65 ms/f** vs 4000.
//    That is the preferred *library / Direct-Play* tier. It is NOT a universal
//    maxVideoBitrate: lab PMS @ maxBR<=3000 delivers coded **720x404**, not 1280x720
//    (daemon URL builder, unique session, rk2/rk7 — see LAB_PMS_720_DAEMON_PATH.md).
//
// 2) Universal maxVideoBitrate floor for genuine 1280x720 (lab coded-size matrix):
//      >=3500 → 1280x720 SAR 1:1; <=3000 → 720x404. Product weak default = 3500
//      (geometry min). Parent decode @3500 = 38.751 ms/f when content is 3500k.
//
// Prefer Path720p Direct Play of ~1500k native 720p assets for ARM budget;
// universal keeps the geometry-safe weak bitrate below.
constexpr int kPlex720pDecodeOptimalBitrateKbps = 1500;
constexpr int kPlex720pWeakBitrateKbps = 3500; // universal maxVideoBitrate pin
// H.264 Level 3.1 is required for general 1280x720 (MaxFS). Lab source is
// oddly tagged L3.0; product ladder requests L3.1 for the 720p tier.
constexpr int kPlex720pH264Level = 31;
static_assert(kPlex720pWeakBitrateKbps >= 3500,
              "universal 720p weak bitrate must stay at geometry floor (lab ≥3500)");
static_assert(kPlex720pDecodeOptimalBitrateKbps < kPlex720pWeakBitrateKbps,
              "decode-optimal content tier is below universal geometry floor");

// Menu index 0 is the power-on default. The present loop waits for the audio
// clock to reach `frameContentMs + avOffsetMs`, so POSITIVE holds the frame back
// and makes video LATER. Raise it when audio sounds late (video running ahead).
//
// The default is 0 and that is now a real claim, not a punt. The latency that
// software CAN see is measured and removed: the MrAudio DMA ring runs ~185 ms
// deep during playback (and varies per session, see mraudio_status.hpp), and the
// pump subtracts it live. What remains is only the difference between the audio
// and video paths downstream of the driver — FPGA output, HDMI, and the
// display's own processing — which is per-display and cannot be measured from
// the ARM. Displays commonly add tens of ms of VIDEO processing, so a negative
// trim is normal here.
//
// Do not bake a non-zero constant in without eyes-on or capture evidence for
// THIS clock; a value tuned against the old submitted-byte clock is not
// comparable, because it silently absorbed that session's ring depth.
constexpr int kOsdAvOffsetDefaultMs = 0;
constexpr uint16_t kOsdIdleMask = 0xC000;
// O[5:4] content tier field.
constexpr unsigned kOsdContentTierShift = 4;
constexpr uint16_t kOsdContentTierMask = 0x0030;

// How the host presents into the current RBF DDR canvas.
// Native720pPresent is path-ready (PMS/vf) but DDR bank present is still w-mem.
enum class ContentPresentPolicy : uint8_t {
    // Coded size == PMS ladder == decode target == canvas (240p or 480p).
    NativeCanvas = 0,
    // Same 624x480 DDR canvas as 480p; 16:9 sources letterbox via host scale/pad.
    // User-facing name must say "16:9-framed 480p", never "720p".
    Widescreen480pCanvas = 1,
    // Path-tier 1280x720. PMS URL + vf identity_skip target. DDR publish still
    // refuses until w-mem remaps banks — do not claim glass-ready.
    Path720p = 2,
};

struct ContentResolution {
    // width/height are *coded* payload size advertised to PMS / decoder, never
    // the presented scanout size (640). Strong types make that substitution fail.
    CodedWidth width{320};
    CodedHeight height{240};
    // PMS videoResolution= query value — MUST stay "WxH" digits only.
    const char* label = "320x240";
    int weakBitrateKbps = 1000;
    ContentPresentPolicy presentPolicy = ContentPresentPolicy::NativeCanvas;
    // Human/log name; may differ from label (e.g. widescreen canvas).
    const char* userLabel = "320x240";
};

// Label for the 480p coded ladder tier. Digits are static_assert-locked to the
// coded constants so a presented-width (640) typo cannot silently ship.
inline const char* plex480pCodedResolutionLabel() {
    static_assert(kPlex480pCodedWidth.get() == 624,
                  "update plex480pCodedResolutionLabel when coded width changes");
    static_assert(kPlex480pCodedHeight.get() == 480,
                  "update plex480pCodedResolutionLabel when coded height changes");
    return "624x480";
}

inline const char* plex720pCodedResolutionLabel() {
    static_assert(kPlex720pCodedWidth.get() == 1280,
                  "update plex720pCodedResolutionLabel when coded width changes");
    static_assert(kPlex720pCodedHeight.get() == 720,
                  "update plex720pCodedResolutionLabel when coded height changes");
    return "1280x720";
}

// Honest product name for tier 10 — never "720p".
inline const char* plexWidescreen480pCanvasUserLabel() {
    return "16:9-framed 480p";
}

struct OsdSettings {
    int avOffsetMs = 0;
    // O[3] is a debug kill-switch for the feed-rate trim, not a value. It used
    // to decode to a hardcoded ppm, which silently overrode AUDIO_CLOCK_PPM the
    // moment the OSD was polled — i.e. always — so the conf key did nothing.
    // The ppm itself belongs to the daemon; the menu only says on or off.
    bool audioClockTrimEnabled = true;
    bool resyncEnabled = true;
    int idleMode = 0; // matches IdleMode enum
    ContentResolution contentResolution;
};

// Signed wrap around the default: index 0 is the default, 1..7 step up and
// 8..15 step down. That keeps the list monotonic across the wrap (index 15 is
// one step BELOW index 0), so right/left on the OSD is a plain up/down knob.
inline int osdAvOffsetMsFromIndex(unsigned idx) {
    int i = static_cast<int>(idx % kOsdAvOffsetSteps);
    if (i >= kOsdAvOffsetSteps / 2)
        i -= kOsdAvOffsetSteps;
    return i * kOsdAvOffsetStepMs + kOsdAvOffsetDefaultMs;
}

inline unsigned osdContentTierFromWord(uint16_t word) {
    return (static_cast<unsigned>(word) >> kOsdContentTierShift) & 3u;
}

inline ContentResolution contentResolutionFor480p() {
    // 624x480 is still the 480p ladder. Default request bitrate is 2000 kbps
    // (kPlex480pWeakBitrateKbps) as a quality/ARM-margin *heuristic* — historically
    // described as a "PMS/validator floor" and incorrectly hard-failed in
    // validateWeakLadder. That hard fail is retired: links below ~2 Mbit/s
    // starve any request near the default. Operator WEAK_BITRATE must win;
    // recommendedMin is advisory only. Raising above 2000 is a separate FEED/
    // ARM-margin question (not gated here).
    return {kPlex480pCodedWidth, kPlex480pCodedHeight, plex480pCodedResolutionLabel(),
            kPlex480pWeakBitrateKbps, ContentPresentPolicy::NativeCanvas,
            plex480pCodedResolutionLabel()};
}

inline ContentResolution contentResolutionFor240p() {
    return {CodedWidth{320}, CodedHeight{240}, "320x240", kPlex240pWeakBitrateKbps,
            ContentPresentPolicy::NativeCanvas, "320x240"};
}

// Same DDR/PMS geometry as 480p. Policy flag only — does not raise coded size.
inline ContentResolution contentResolutionForWidescreen480pCanvas() {
    return {kPlex480pCodedWidth, kPlex480pCodedHeight, plex480pCodedResolutionLabel(),
            kPlex480pWeakBitrateKbps, ContentPresentPolicy::Widescreen480pCanvas,
            plexWidescreen480pCanvasUserLabel()};
}

// Aggressive path target: genuine 1280x720 PMS tier (see p720-path evidence).
inline ContentResolution contentResolutionFor720p() {
    return {kPlex720pCodedWidth, kPlex720pCodedHeight, plex720pCodedResolutionLabel(),
            kPlex720pWeakBitrateKbps, ContentPresentPolicy::Path720p,
            plex720pCodedResolutionLabel()};
}

// Prefer library H.264 Part (transcode=0) vs PMS universal.
// conf_explicit: PREFER_DIRECT_H264 was set (not auto/unset).
// Path720p defaults ON when conf unset — removes PMS transcoder from the ARM
// budget and unlocks direct_play_part identity (ARM scale=0 when file==bank).
// Explicit PREFER_DIRECT_H264=0 still forces universal on Path720p.
inline bool preferDirectH264ForContent(bool conf_explicit, bool conf_prefer,
                                       bool stream_enabled,
                                       ContentPresentPolicy policy) {
    if (conf_explicit)
        return conf_prefer;
    if (policy == ContentPresentPolicy::Path720p)
        return true;
    return stream_enabled;
}

// O[5:4]=11 → Path720p ladder ONLY when enable_tier11_720p is true (conf
// OSD_TIER11_720P=1). Default false: reserved → safe 480p canvas so a v8 menu
// bit cannot ship 720p until fabric (w-mem/w-scaler) is ready.
// Path 720p is also selected via DECODE=1280x720 / TRANSCODE_PROFILE=720p
// (conf path does not need this flag).
inline ContentResolution contentResolutionFromOsdWord(uint16_t word,
                                                      bool enable_tier11_720p = false) {
    switch (osdContentTierFromWord(word)) {
    case 0:
        return contentResolutionFor240p();
    case 1:
        return contentResolutionFor480p();
    case 2:
        return contentResolutionForWidescreen480pCanvas();
    default:
        // case 3 = O[5:4] binary 11
        if (enable_tier11_720p)
            return contentResolutionFor720p();
        return contentResolutionFor480p();
    }
}

// Tier selection from a *coded* size. Presented scanout width must not be
// passed here without an explicit CodedWidth{presented.get()} claim at the
// call site — that claim is the bug we want reviewers to see.
// Exact 1280x720 selects the path-720p ladder. Other at/above-480p sizes keep
// the 480p canvas (including 640x480 presented mistakes mapped via callers).
inline ContentResolution contentResolutionFromCodedSize(CodedWidth w, CodedHeight h) {
    if (w.get() == kPlex720pCodedWidth.get() && h.get() == kPlex720pCodedHeight.get())
        return contentResolutionFor720p();
    if (w.get() >= kPlex480pCodedWidth.get() || h.get() >= kPlex480pCodedHeight.get())
        return contentResolutionFor480p();
    return contentResolutionFor240p();
}

inline ContentResolution contentResolutionFromSize(int w, int h) {
    return contentResolutionFromCodedSize(CodedWidth{w}, CodedHeight{h});
}

inline int weakBitrateKbpsForCodedSize(CodedWidth w, CodedHeight h) {
    if (w.get() == kPlex720pCodedWidth.get() && h.get() == kPlex720pCodedHeight.get())
        return kPlex720pWeakBitrateKbps;
    if (w.get() >= kPlex480pCodedWidth.get() || h.get() >= kPlex480pCodedHeight.get()) {
#ifdef OSD_MENU_FAULT_FALLBACK_624_BITRATE
        return kPlex360pWeakBitrateKbps;
#else
        return contentResolutionFor480p().weakBitrateKbps;
#endif
    }
    if (w.get() >= 480 || h.get() >= 360)
        return kPlex360pWeakBitrateKbps;
    return contentResolutionFor240p().weakBitrateKbps;
}

// Decoder/conf boundary: bare ints are claimed coded at the call edge.
inline int weakBitrateKbpsForCodedSize(int w, int h) {
    return weakBitrateKbpsForCodedSize(CodedWidth{w}, CodedHeight{h});
}

inline OsdSettings decodeOsdWord(uint16_t word, bool enable_tier11_720p = false) {
    OsdSettings s;
    s.contentResolution = contentResolutionFromOsdWord(word, enable_tier11_720p);
    s.resyncEnabled = ((word >> 1) & 1u) == 0u;
    s.audioClockTrimEnabled = ((word >> 3) & 1u) == 0u;
    s.avOffsetMs = osdAvOffsetMsFromIndex((word >> 6) & 0x0Fu);
    s.idleMode = (word >> 14) & 3u;
    return s;
}

// Bits the daemon reacts to. [0] reset, [2] TV mode,
// [10]/[11] flush triggers and [13:12] DDR kick/bank are not user settings and
// toggle constantly during playback. [5:4] content tier is owned (v8; bit5 was
// reserved under v7 and is now part of the tier field).
//
// The daemon NEVER writes these bits. Main_MiSTer owns the OSD word (and saves it
// to config/Plex_vN.CFG); a daemon-side write only fights Main's shadow and makes
// the value flap between the two.
// Was 0xC3DA (v7, bit5 free). v8 adds bit5 → 0xC3FA.
constexpr uint16_t kOsdOwnedMask = 0xC3FA;

inline bool osdChanged(uint16_t a, uint16_t b) {
    return ((a ^ b) & kOsdOwnedMask) != 0;
}

inline bool osdIdleChanged(uint16_t a, uint16_t b) {
    return ((a ^ b) & kOsdIdleMask) != 0;
}

// Idle apply policy (OSD_CONTROL=1):
//   * First successful OSD word = Main's persisted menu (config/Plex_v*.CFG).
//     Apply idle bits so F12 "Idle Screen" survives daemon restart.
//   * Later words: apply idle only when [15:14] change.
// IDLE_SCREEN conf is the pre-OSD fallback (and the only source when
// OSD_CONTROL=0). Once the core OSD word is readable, persisted OSD wins.
inline bool shouldApplyOsdIdle(bool osdSeenBefore, uint16_t previousWord, uint16_t word) {
#ifdef OSD_MENU_FAULT_SKIP_INITIAL_IDLE
    // Fault mutant: old baseline-only behaviour (ignores persisted F12 idle).
    return osdSeenBefore && osdIdleChanged(previousWord, word);
#else
    if (!osdSeenBefore)
        return true;
    return osdIdleChanged(previousWord, word);
#endif
}

} // namespace misterplex
