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
//   [4]      Content res      0=320x240 (proven default), 1=480p path.
//                             Main's CONF_STR still labels this 640x480 because
//                             that is the presented scanout size; the payload
//                             advertised to PMS and decoded by the daemon is
//                             the DDR contract's coded 624x480 frame.
//   [5]      reserved         do not reuse without a config-version bump
//   [9:6]    A/V offset       4-bit SIGNED, 20 ms per step -> -160..+140 ms.
//                             Signed (not biased) so the power-on value 0 means
//                             0 ms without needing a non-zero CONF_STR default,
//                             which Main_MiSTer cannot express.
//   [10]     T Flush audio FIFO      (core)
//   [11]     T Flush bitstream FIFO  (core)
//   [12:13]  reserved for HPS DDR kick/bank — never reuse
//   [15:14]  Idle screen      0=Logo 1=Black 2=Screensaver 3=Last frame
//
// Pure decode so it can be unit-tested without an FPGA.
//
// CONF_STR file slots (`F1,raw,...`) and controller labels (`J1,...`) are menu
// metadata only. They do not allocate OSD status bits, so fixing F labels or
// adding J1 names does not change this v7 bit layout.

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

struct ContentResolution {
    // width/height are *coded* payload size advertised to PMS / decoder, never
    // the presented scanout size (640). Strong types make that substitution fail.
    CodedWidth width{320};
    CodedHeight height{240};
    const char* label = "320x240";
    int weakBitrateKbps = 1000;
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

inline ContentResolution contentResolutionFor480p() {
    // 624x480 is still the 480p ladder. Use the 2000 kbps PMS/validator floor
    // until W-FEED (or equivalent ARM-boundary profiling) proves a higher
    // bitrate safe; this path has only millisecond-scale decode margin.
    return {kPlex480pCodedWidth, kPlex480pCodedHeight, plex480pCodedResolutionLabel(),
            kPlex480pWeakBitrateKbps};
}

inline ContentResolution contentResolutionFor240p() {
    return {CodedWidth{320}, CodedHeight{240}, "320x240", kPlex240pWeakBitrateKbps};
}

inline ContentResolution contentResolutionFromOsdWord(uint16_t word) {
    if ((word >> 4) & 1u)
        return contentResolutionFor480p();
    return contentResolutionFor240p();
}

// Tier selection from a *coded* size. Presented scanout width must not be
// passed here without an explicit CodedWidth{presented.get()} claim at the
// call site — that claim is the bug we want reviewers to see.
inline ContentResolution contentResolutionFromCodedSize(CodedWidth w, CodedHeight h) {
    if (w.get() >= kPlex480pCodedWidth.get() || h.get() >= kPlex480pCodedHeight.get())
        return contentResolutionFor480p();
    return contentResolutionFor240p();
}

inline ContentResolution contentResolutionFromSize(int w, int h) {
    return contentResolutionFromCodedSize(CodedWidth{w}, CodedHeight{h});
}

inline int weakBitrateKbpsForCodedSize(CodedWidth w, CodedHeight h) {
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

inline OsdSettings decodeOsdWord(uint16_t word) {
    OsdSettings s;
    s.contentResolution = contentResolutionFromOsdWord(word);
    s.resyncEnabled = ((word >> 1) & 1u) == 0u;
    s.audioClockTrimEnabled = ((word >> 3) & 1u) == 0u;
    s.avOffsetMs = osdAvOffsetMsFromIndex((word >> 6) & 0x0Fu);
    s.idleMode = (word >> 14) & 3u;
    return s;
}

// Bits the daemon reacts to. [0] reset, [2] TV mode, [5] reserved,
// [10]/[11] flush triggers and [13:12] DDR kick/bank are not user settings and
// toggle constantly during playback.
//
// The daemon NEVER writes these bits. Main_MiSTer owns the OSD word (and saves it
// to config/Plex_v7.CFG); a daemon-side write only fights Main's shadow and makes
// the value flap between the two.
constexpr uint16_t kOsdOwnedMask = 0xC3DA;

inline bool osdChanged(uint16_t a, uint16_t b) {
    return ((a ^ b) & kOsdOwnedMask) != 0;
}

inline bool osdIdleChanged(uint16_t a, uint16_t b) {
    return ((a ^ b) & kOsdIdleMask) != 0;
}

// Idle apply policy (OSD_CONTROL=1):
//   * First successful OSD word = Main's persisted menu (config/Plex_v7.CFG).
//     Apply idle bits so F12 "Idle Screen" survives daemon restart / menu reset.
//   * Later words: apply idle only when [15:14] change (av-offset-only edits
//     must not re-paint).
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
