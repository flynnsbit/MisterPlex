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
//   [5:4]    Content res      PMS ladder / DECODE — 0=240p 1=480p 2|3=720p
//                             (v7 only drove O[4] → 240p/480p)
//   [9:6]    A/V offset       4-bit SIGNED, 20 ms/step → -160..+140 ms
//   [10]     T Flush audio FIFO
//   [11]     T Flush bitstream FIFO
//   [12:13]  reserved HPS DDR kick/bank — never reuse
//   [15:14]  Display res (v9) 0=Follow content, 1=240p, 2=480p, 3=720p
//                             Default 0 keeps v8 cores safe (those bits were Idle
//                             logo=0) so PMS 720p is not forced to 240p present.
//                             Idle screen is conf IDLE_SCREEN= only from v9.
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
constexpr int kPlex720pWeakBitrateKbps = 20000;

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
// ABI alias retained for older host callers; these bits are display resolution
// in v9 and must not be applied as idle mode.
constexpr uint16_t kOsdIdleMask = 0xC000;
// O[5:4] content tier field.
constexpr unsigned kOsdContentTierShift = 4;
constexpr uint16_t kOsdContentTierMask = 0x0030;

// How the host presents into the current RBF DDR canvas.
enum class ContentPresentPolicy : uint8_t {
    // Coded size == PMS ladder == decode target == canvas (240p or 480p).
    NativeCanvas = 0,
    // Same 624x480 DDR canvas as 480p; 16:9 sources letterbox via host scale/pad.
    // User-facing name must say "16:9-framed 480p", never "720p".
    Widescreen480pCanvas = 1,
};

struct ContentResolution {
    // Strongly typed request/presentation geometry. The 480p menu tier is the
    // 640x480 presented canvas; ddrFrameGeometryForPresentedSize() maps it to
    // the true480 624-coded/618-visible DDR contract.
    CodedWidth width{320};
    CodedHeight height{240};
    const char* label = "240p";
    int weakBitrateKbps = 1000;
    ContentPresentPolicy presentPolicy = ContentPresentPolicy::NativeCanvas;
    const char* userLabel = "240p";
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
    int idleMode = 0; // conf IDLE_SCREEN from v9; legacy v8 OSD bits ignored
    ContentResolution contentResolution; // O[5:4] → PMS / DECODE
    ContentResolution displayResolution; // O[15:14] → FPGA present bank (v9)
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
    return {CodedWidth{kPlex480pPresentedWidth.get()}, CodedHeight{480}, "480p",
            kPlex480pWeakBitrateKbps, ContentPresentPolicy::NativeCanvas,
            "480p"};
}

inline ContentResolution contentResolutionFor240p() {
    return {CodedWidth{320}, CodedHeight{240}, "240p", kPlex240pWeakBitrateKbps,
            ContentPresentPolicy::NativeCanvas, "240p"};
}

inline ContentResolution contentResolutionFor720p() {
    return {kPlex720pCodedWidth, kPlex720pCodedHeight, "720p",
            kPlex720pWeakBitrateKbps, ContentPresentPolicy::NativeCanvas, "720p"};
}

// Same DDR/PMS geometry as 480p. Policy flag only — does not raise coded size.
inline ContentResolution contentResolutionForWidescreen480pCanvas() {
    return {kPlex480pCodedWidth, kPlex480pCodedHeight, plex480pCodedResolutionLabel(),
            kPlex480pWeakBitrateKbps, ContentPresentPolicy::Widescreen480pCanvas,
            plexWidescreen480pCanvasUserLabel()};
}

inline ContentResolution contentResolutionFromOsdWord(uint16_t word) {
    switch (osdContentTierFromWord(word)) {
    case 0:
        return contentResolutionFor240p();
    case 1:
        return contentResolutionFor480p();
    case 2:
    default:
        return contentResolutionFor720p();
    }
}

inline ContentResolution contentResolutionFromCodedSize(CodedWidth w, CodedHeight h) {
    if (w.get() >= kPlex720pCodedWidth.get() || h.get() >= kPlex720pCodedHeight.get())
        return contentResolutionFor720p();
    if (w.get() >= kPlex480pCodedWidth.get() || h.get() >= kPlex480pCodedHeight.get())
        return contentResolutionFor480p();
    return contentResolutionFor240p();
}

inline ContentResolution contentResolutionFromSize(int w, int h) {
    return contentResolutionFromCodedSize(CodedWidth{w}, CodedHeight{h});
}

inline int weakBitrateKbpsForCodedSize(CodedWidth w, CodedHeight h) {
    if (w.get() >= kPlex720pCodedWidth.get() || h.get() >= kPlex720pCodedHeight.get())
        return contentResolutionFor720p().weakBitrateKbps;
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

inline ContentResolution displayResolutionFromOsdWord(uint16_t word,
                                                      const ContentResolution& content) {
    // O[15:14] v9: 0=Follow content (also v8 idle default), 1=240p, 2=480p, 3=720p.
    switch ((word >> 14) & 3u) {
    case 1:
        return contentResolutionFor240p();
    case 2:
        return contentResolutionFor480p();
    case 3:
        return contentResolutionFor720p();
    default:
        return content;
    }
}

inline OsdSettings decodeOsdWord(uint16_t word) {
    OsdSettings s;
    s.contentResolution = contentResolutionFromOsdWord(word);
    s.displayResolution = displayResolutionFromOsdWord(word, s.contentResolution);
    s.resyncEnabled = ((word >> 1) & 1u) == 0u;
    s.audioClockTrimEnabled = ((word >> 3) & 1u) == 0u;
    s.avOffsetMs = osdAvOffsetMsFromIndex((word >> 6) & 0x0Fu);
    // Idle screen is conf-only from v9 (O[15:14] = display res). Leave 0=logo.
    s.idleMode = 0;
    return s;
}

// Bits the daemon reacts to. [0] reset, [2] TV mode,
// [10]/[11] flush triggers and [13:12] DDR kick/bank are not user settings and
// toggle constantly during playback. O[5] is part of content-res (v8).
//
// The daemon NEVER writes these bits. Main_MiSTer owns the OSD word (and saves it
// to config/Plex_vN.CFG); a daemon-side write only fights Main's shadow and makes
// the value flap between the two.
// Includes O[5] content-res and O[15:14] display-res so 240↔720 are not ignored.
constexpr uint16_t kOsdOwnedMask = 0xC3FA;

inline bool osdChanged(uint16_t a, uint16_t b) {
    return ((a ^ b) & kOsdOwnedMask) != 0;
}

inline bool osdIdleChanged(uint16_t a, uint16_t b) {
    return ((a ^ b) & kOsdIdleMask) != 0;
}

// Since config v9, O[15:14] selects display resolution and idle mode is owned
// exclusively by IDLE_SCREEN in misterplex.conf. Never reinterpret those bits
// as the retired v8 idle selector.
inline bool shouldApplyOsdIdle(bool, uint16_t, uint16_t) {
#ifdef OSD_MENU_FAULT_APPLY_IDLE_BITS
    return true;
#else
    return false;
#endif
}

} // namespace misterplex
