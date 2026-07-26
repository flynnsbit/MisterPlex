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
//   [5:4]    Content FPS      dead: it only fed present_cadence, which now only
//                             drives the disabled pattern generator. Left in the
//                             RTL but removed from the menu.
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
// adding J1 names does not change this v3/v6 bit layout.

#include <cstdint>

namespace misterplex {

// Step/bias of the video delay list. Kept here so the CONF_STR generator, the
// daemon and the tests cannot disagree about what a menu index means.
constexpr int kOsdAvOffsetSteps = 16;
constexpr int kOsdAvOffsetStepMs = 20;

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

struct OsdSettings {
    int avOffsetMs = 0;
    // O[3] is a debug kill-switch for the feed-rate trim, not a value. It used
    // to decode to a hardcoded ppm, which silently overrode AUDIO_CLOCK_PPM the
    // moment the OSD was polled — i.e. always — so the conf key did nothing.
    // The ppm itself belongs to the daemon; the menu only says on or off.
    bool audioClockTrimEnabled = true;
    bool resyncEnabled = true;
    int idleMode = 0; // matches IdleMode enum
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

inline OsdSettings decodeOsdWord(uint16_t word) {
    OsdSettings s;
    s.resyncEnabled = ((word >> 1) & 1u) == 0u;
    s.audioClockTrimEnabled = ((word >> 3) & 1u) == 0u;
    s.avOffsetMs = osdAvOffsetMsFromIndex((word >> 6) & 0x0Fu);
    s.idleMode = (word >> 14) & 3u;
    return s;
}

// Bits the daemon reacts to. [0] reset, [2] TV mode, [5:4] dead content FPS,
// [10]/[11] flush triggers and [13:12] DDR kick/bank are not user settings and
// toggle constantly during playback.
//
// The daemon NEVER writes these bits. Main_MiSTer owns the OSD word (and saves it
// to config/Plex_v3.CFG); a daemon-side write only fights Main's shadow and makes
// the value flap between the two.
constexpr uint16_t kOsdOwnedMask = 0xC3CA;

inline bool osdChanged(uint16_t a, uint16_t b) {
    return ((a ^ b) & kOsdOwnedMask) != 0;
}

} // namespace misterplex
