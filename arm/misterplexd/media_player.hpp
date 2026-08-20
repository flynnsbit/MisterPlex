#pragma once
// Phase 2 media player: single-process FFmpeg → /dev/fb0 + /dev/MrAudio.
// Transitional ARM decode; FPGA owns scanout (MiSTer_fb) + SPI audio (MrAudio).
// STREAM=1: annex-B demux → host I-slice recon → F1 + F3; optional RGB skip.

#include "libmisterplex/osd_menu.hpp"
#include "libmisterplex/present_bank.hpp"
#include "libmisterplex/fabric_direct.hpp"
#include "libmisterplex/library_browser.hpp"

namespace misterplex {

// Content owns DECODE/PMS; Display owns video_mode only (RASTER-CMD).
// persist/doPlay/osdRetarget use GLASS-MAX(content), not Display geom.
// true480 never grows to 1280×720. L4 never shrinks below 1280×720 except
// the P3/P5 960×540 bank (MPX_BUDGET_960, content already 960×540, or a
// PRESENT_BEAM_960 prefix8 — do not snap those stores up to 1280).
inline bool osdRetargetDecodeSizeFromPresented(int& outW, int& outH,
                                               const ContentResolution& content,
                                               LiveGlass glass,
                                               const std::string& prefix8 = std::string()) {
    const ContentResolution bank = glassMax(content.width, content.height, glass, prefix8);
    if (outW == bank.width && outH == bank.height)
        return false;
    outW = bank.width;
    outH = bank.height;
    return true;
}

} // namespace misterplex

#ifndef MPX_OSD_DECODE_SIZE_ONLY

#include "fb_present.hpp"
#include "fpga_spi.hpp"
#include "libmisterplex/cached_src_phys.hpp"
#include "libmisterplex/idle_screen.hpp"
#include "libmisterplex/mraudio_status.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <sys/types.h>

namespace misterplex {

#ifdef MPX_HAVE_LIBAV
class AvInprocDecoder;
#endif

struct PlaybackSummary {
    int64_t rawFrames = 0;
    int64_t presentedFrames = 0;
    int64_t reconFrames = 0;
    int64_t totalBytes = 0;
    bool usedRawVideo = false;
    bool streamEnabled = false;
    bool skipRgb = false;
    bool shortRead = false;
    bool videoEof = false;
    bool true480PipelineAborted = false;
    size_t shortReadGot = 0;
    size_t shortReadWant = 0;

    int64_t deliveredFrames() const {
        return rawFrames > 0 ? rawFrames : (reconFrames > 0 ? reconFrames : presentedFrames);
    }
};

class MediaPlayer {
public:
    ~MediaPlayer() { shutdown(); }

    using LogFn = std::function<void(const std::string&)>;
    using ProgressFn = std::function<void(const std::string& state, int64_t timeMs, int64_t durMs)>;
    // Fired when OSD content-resolution bits change (O[5:4]). Main uses this to
    // re-resolve the PMS weak ladder / restart the session at the same offset.
    using ContentResFn = std::function<void(const ContentResolution& res, bool playing)>;
    // Fired when resolved Display row changes (O[15:14], or Follow + content).
    // Live OSD Display only persists DISPLAY_RES. video_mode is latched at
    // daemon start / core reset (latchAndApplyDisplayRaster).
    using DisplayResFn = std::function<void(const ContentResolution& res)>;
    using LibraryFetchFn = std::function<std::string(const std::string& path)>;
    using LibraryPlayFn = std::function<void(const std::string& ratingKey)>;

    void setLog(LogFn f) { log_ = std::move(f); }
    void setProgress(ProgressFn f) { onProgress_ = std::move(f); }
    void setOnContentResolutionChanged(ContentResFn f) { onContentRes_ = std::move(f); }
    void setOnDisplayResolutionChanged(DisplayResFn f) { onDisplayRes_ = std::move(f); }
    void setLibraryFetch(LibraryFetchFn f) { libraryFetch_ = std::move(f); }
    void setLibraryPlay(LibraryPlayFn f) { libraryPlay_ = std::move(f); }
    void openLibraryBrowser();
    // Core reset / daemon start: latch Display and write video_mode once.
    void latchAndApplyDisplayRaster(const ContentResolution& display);
    void setFfmpegPath(std::string p) { ffmpeg_ = std::move(p); }
    // Conf FFMPEG_SWS_FLAGS: bicubic (quality) | fast_bilinear (rate ladder) | neighbor |
    // skip|none|off|identity (omit scale) | exact[_fast_bilinear|_neighbor] (force WxH,
    // no foar/pad — size contract for DDR I420 without dual-pass scale+pad).
    void setFfmpegSwsFlags(std::string flags) {
        if (!flags.empty())
            swsFlags_ = std::move(flags);
    }
    // Conf FFMPEG_FPS_FILTER=off: omit fps= filter when content is already CFR at
    // the paced rate (saves dual-A9 filtergraph cost). Default on (safe for VFR).
    void setFfmpegFpsFilter(bool on) { fpsFilter_ = on; }
    // Conf UV_U_BIAS / UV_V_BIAS: add to every chroma sample before DDR present.
    // Lab HDMI@B6 showed systematic U≈−8 vs source (fluorescent green L/R foliage).
    // Positive U bias pulls green toward neutral. Range clamped ±32.
    void setUvBias(int uBias, int vBias) {
        if (uBias < -32) uBias = -32;
        if (uBias > 32) uBias = 32;
        if (vBias < -32) vBias = -32;
        if (vBias > 32) vBias = 32;
        uvUBias_ = uBias;
        uvVBias_ = vBias;
    }
    void setAudioPath(std::string p) { audioDev_ = std::move(p); }
    void setAudioEnabled(bool on) { audioEnabled_ = on; }
    // present: "fb0" (default) and/or "fpga" (DDR YUV420p → frame_store)
    void setPresentMode(std::string mode) { presentMode_ = std::move(mode); }
    void setDdrMemSync(bool on) { fpga_.setDdrMemSync(on); }
    void setDdrMemFlush(bool on) { fpga_.setDdrMemFlush(on); }
    void setDdrFrameFormat(DdrFrameFormat format) { ddrFrameFormat_ = format; }
    void setPresentProfile(bool on) { presentProfile_ = on; }
    // STREAM=1: demux annex-B H.264 → host I-slice recon (I420 → F1) + F3 stub feed
    void setStreamEnabled(bool on) { streamEnabled_ = on; }
    // When STREAM recon owns F1, optionally drop heavy FFmpeg RGB decode (keep audio).
    // "auto" | "1"/"on" = skip RGB from session start when PRESENT=fpga (audio + demux only).
    // PRESENT=both/fb0 always keeps RGB (continuous fb0). CABAC + skip → black F1: set
    // STREAM_SKIP_RGB=0 or PRESENT=both for fb0 fallback.
    // "0"/"off" = always full RGB decode for fb0/diagnostic fallback.
    void setStreamSkipRgb(std::string mode) { streamSkipRgb_ = std::move(mode); }
    // STREAM=0 only: optional FFmpeg subtitles filter for local file paths (see docs/subtitles-burnin.md).
    // "off" | "ffmpeg" — PMS burn-in is handled in resolve (WeakLadder::burnSubtitles).
    void setSubtitleMode(std::string mode) { subtitleMode_ = std::move(mode); }
    void setSubtitleStreamIndex(int idx) { subtitleStreamIndex_ = idx; }
    // Intentional A/V lead compensation via FFmpeg adelay (ms). Default 0.
    // Prefer contentFps wall/audio pacing first; use adelay only for small residual.
    void setAudioDelayMs(int ms) { audioDelayMs_ = ms < 0 ? 0 : ms; }
    int audioDelayMs() const { return audioDelayMs_; }
    // Seed for the feed-rate servo, in ppm, and the open-loop fallback if the
    // driver's ring depth is unreadable. NOT a calibration any more — see
    // feedRateBytesPerSec().
    void setAudioClockPpm(int ppm) {
        if (ppm < -20000)
            ppm = -20000;
        if (ppm > 20000)
            ppm = 20000;
        audioClockPpmConf_ = ppm;
        if (audioClockTrimEnabled_)
            audioClockPpm_ = ppm;
    }
    // OSD O[3]: disable the feed-rate trim entirely (debug). Off means seed the
    // servo at exactly nominal 48 kHz; on restores the configured seed.
    void setAudioClockTrimEnabled(bool en) {
        audioClockTrimEnabled_ = en;
        audioClockPpm_ = en ? audioClockPpmConf_ : 0;
    }
    int audioClockPpm() const { return audioClockPpm_; }
    // Exact content frame rate as a rational (24000/1001 for 23.976 NTSC film).
    // This drives A/V pacing, so it must NOT be bucketed: pacing 23.976 content at 24
    // makes video lead by ~1 ms/s (~234 ms by 3:54, ~5.5 s over a 91-minute episode).
    // 0/0 = unknown → fall back to 24/1 and lean on the drift corrector.
    void setContentFpsRational(int num, int den);
    // Convenience shim for integer rates (12/24/30/60) and tests.
    void setContentFps(int fps) { setContentFpsRational(fps, 1); }
    int contentFpsNum() const { return fpsNum_; }
    int contentFpsDen() const { return fpsDen_; }
    // Present lead (ms) so the vsync path is not starved. Conf AV_PRESENT_LEAD_MS.
    void setPresentLeadMs(int ms) { presentLeadMs_ = ms < 0 ? 0 : ms; }
    // After the first 720p video kick, wait this many ms before the first
    // MrAudio write. Lab d30e7461 + MS2109 @100 ms: HDMI median a−v ≈ +12 ms.
    // Auto 100 on native 1280 inproc only. Conf AV_HDMI_AUDIO_LAG_MS.
    void setAvHdmiAudioLagMs(int ms) { avHdmiAudioLagMs_ = ms; }
    int avHdmiAudioLagMs() const { return avHdmiAudioLagMs_; }
    // Drift (ms) past which a late frame is dropped to re-converge. Conf AV_RESYNC_DROP_MS.
    // 0 disables dropping (hold-only pacing). 720p L4 ignores this and presents
    // every decoded frame; FPGA NACK is a send failure, not an A/V drop.
    void setResyncDropMs(int ms) { resyncDropMs_ = ms < 0 ? 0 : ms; }
    static constexpr int kDefaultResyncDropMs = 80;
    // Signed live A/V trim (ms), applied in the pacing loop rather than via an
    // FFmpeg filter, so the OSD can move it mid-playback with no respawn.
    //   > 0  hold video back  -> audio plays EARLIER relative to picture
    //   < 0  advance video    -> audio plays LATER  ("fixes" lips-ahead)
    void setAvOffsetMs(int ms) {
        if (ms < -1000)
            ms = -1000;
        if (ms > 1000)
            ms = 1000;
        avOffsetMs_.store(ms);
    }
    int avOffsetMs() const { return avOffsetMs_.load(); }
    // Idle/screensaver painting. Without this the frame store keeps the last frame
    // of the previous video on screen forever.
    void setIdleMode(IdleMode m) { idleMode_.store(static_cast<int>(m)); }
    IdleMode idleMode() const { return static_cast<IdleMode>(idleMode_.load()); }
    void startIdle();
    void stopIdle();

    // Live OSD menu control. Only enable against a core whose CONF_STR uses the
    // v7 bit layout (see libmisterplex/osd_menu.hpp) — older layouts put Pattern
    // and Content FPS on the same bits, which would be read as an A/V offset.
    void setOsdControl(bool on) { osdControl_ = on; }
    void startOsdPoll();
    void stopOsdPoll();
    void setSkipDeltasMs(int64_t forwardMs, int64_t backMs);
    void startInputPoll();
    void stopInputPoll();
    // Layout/DAR commits can replace the shared DDR mapping. Retire every
    // background FPGA user before the commit, then resume pollers after the new
    // playback starts (or restore idle on a failed handoff).
    void suspendFpgaWorkers();
    void resumeFpgaWorkers(bool restoreIdle);
    uint16_t lastOsdWord() const { return lastOsd_.load(); }
    // Paint one idle frame right now (used at session end).
    void paintIdle();
    // Live A/V drift: audio clock − content time of the last presented frame.
    // Negative = video ahead of audio (audio sounds late).
    int64_t avDriftMs() const { return avDriftMs_.load(); }
    int64_t droppedFrames() const { return droppedFrames_.load(); }
    void setDecodeSize(int w, int h);
    void setLiveGlass(LiveGlass glass) { liveGlass_ = glass; }
    void setRbfPrefix8(std::string prefix8) { rbfPrefix8_ = std::move(prefix8); }
    LiveGlass liveGlass() const { return liveGlass_; }
    SourceAspect probeSourceAspect(const std::string& urlOrPath,
                                   const std::string& httpHeaders = {},
                                   std::string* failDetail = nullptr,
                                   int* codedW = nullptr,
                                   int* codedH = nullptr,
                                   int* fpsNum = nullptr,
                                   int* fpsDen = nullptr) const;
    bool setSourceAspect(const SourceAspect& aspect);
    // PMS Media/Stream or local-file coded size (0 = unknown).
    // Identity skip requires probed source == DECODE bank (not bank==coded).
    void setSourceMediaSize(int w, int h) {
        sourceMediaW_ = w > 0 ? w : 0;
        sourceMediaH_ = h > 0 ? h : 0;
    }
    // When false, do not open ffmpeg pipe:3 (source has no audio stream).
    void setSourceHasAudio(bool v) { sourceHasAudio_ = v; }
    bool sourceHasAudio() const { return sourceHasAudio_; }
    int sourceMediaW() const { return sourceMediaW_; }
    int sourceMediaH() const { return sourceMediaH_; }
    // Host recon frames presented this session (I/IDR only)
    int64_t reconFrames() const { return reconFrames_.load(); }
    bool reconPresentOk() const { return reconPresentOk_.load(); }
    PlaybackSummary lastPlaybackSummary() const;

    bool initPresent();

    bool play(const std::string& urlOrPath, int64_t startOffsetMs = 0,
              const std::string& httpHeaders = {}, int64_t durationMs = 0);
    void pause();
    void resume();
    void stop();
    // On-screen playback overlay API for input/transport workers.
    // showPlaybackOverlay() only affects visual feedback: it latches the state,
    // progress and a short auto-hide timer. flashPlaybackSkip() adds transient
    // "<< Ns" / "Ns >>" feedback; callers still own the actual seek/skip.
    void showPlaybackOverlay(PlaybackOverlayState state, int64_t positionMs, int64_t durationMs);
    void flashPlaybackSkip(int64_t deltaMs);
    // Process-exit teardown: joins every worker thread without touching the FPGA
    // or reloading Main. A std::thread that is still joinable when ~MediaPlayer
    // runs calls std::terminate(), which is how the daemon used to abort on
    // SIGTERM whenever a session had ended on its own (thread finished but never
    // joined, because only stop()/play() join thr_).
    void shutdown();
    void seekMs(int64_t ms);

    bool playing() const { return playing_.load(); }
    bool audioActive() const { return audioActive_.load(); }
    int64_t positionMs() const { return positionMs_.load(); }
    int64_t durationMs() const {
        std::lock_guard<std::mutex> lock(mu_);
        return durationMs_;
    }
    int decodeW() const { return outW_; }
    int decodeH() const { return outH_; }
    std::string lastError() const;
    std::string currentUrl() const;

private:
    void threadMain(std::string url, int64_t startMs, std::string headers, int64_t durationMs);
    void audioPump(int afd);
    void streamPump(int sfd, bool allowF1Present);
    void killChildren();
    void signalChildren(int sig);
    void dispatchPlaybackInput(PlaybackCommand command);
    void libraryActivate();
    bool libraryHandleInput(PlaybackCommand command);
    // Browse is always-open. If playing, stop+open on a worker — never join OSD/input.
    void requestOpenLibraryBrowser();
    void resetPlaybackPauseClock();
    void transitionPlaybackPause(bool paused, std::chrono::steady_clock::time_point now);
    int64_t playbackPausedUs(std::chrono::steady_clock::time_point now) const;
    // true when STREAM product path may omit heavy RGB video decode (audio + demux only)
    bool wantSkipRgbVideo() const;
    pid_t spawnFfmpeg(const std::vector<std::string>& args, int vWriteFd, int aWriteFd);
    pid_t spawnStreamDemux(const std::string& url, const std::string& headers, int64_t startMs,
                           int writeFd);
    pid_t spawnAudioOnly(const std::string& url, const std::string& headers, int64_t startMs,
                         int aWriteFd);
    pid_t spawnHttpRemuxMpegts(const std::string& url, const std::string& headers, int64_t startMs,
                               const std::string& fifoPath, bool keepAudio = false,
                               const std::string& audioFifo = {});
    pid_t spawnHttpPrefetchTs(const std::string& url, const std::string& headers, int64_t startMs,
                              const std::string& destPath);
    void log(const std::string& s) const;

    LogFn log_;
    ProgressFn onProgress_;
    ContentResFn onContentRes_;
    DisplayResFn onDisplayRes_;
    LibraryFetchFn libraryFetch_;
    LibraryPlayFn libraryPlay_;
    LibraryBrowser library_;
    std::mutex libraryMu_;
    std::atomic<bool> browseOpenBusy_{false};
    std::mutex browseThrMu_;
    std::thread browseThr_;
    ContentResolution lastContentRes_{};
    ContentResolution lastDisplayRes_{};
    ContentResolution latchedDisplayRes_{1280, 720, "720p", 1500};
    bool displayRasterLatched_ = false;
    bool osdResSeeded_ = false;
    LiveGlass liveGlass_ = LiveGlass::True480;
    std::string rbfPrefix8_;
    std::string lastVideoModeCmd_;
    std::string ffmpeg_ = "/media/fat/mistercast/bin/ffmpeg";
    // Default bicubic: soft 480p→720 skies without vertical banding (see SCORE_BANDING_FIX).
    // Light present-rate ladder overrides via setFfmpegSwsFlags / FFMPEG_SWS_FLAGS.
    std::string swsFlags_ = "bicubic";
    bool fpsFilter_ = true;
    int uvUBias_ = 0;
    int uvVBias_ = 0;
    int sourceMediaW_ = 0;
    int sourceMediaH_ = 0;
    SourceAspect sourceAspect_{};
    bool sourceHasAudio_ = true; // fail-open until resolve says otherwise
    std::string audioDev_ = "/dev/MrAudio";
    std::string presentMode_ = "fb0"; // "fb0", "fpga", "both"
    bool audioEnabled_ = true;
    bool streamEnabled_ = false; // annex-B → host recon F1 + F3 stub
    std::string streamSkipRgb_ = "auto"; // auto | on | off
    std::string subtitleMode_ = "off"; // off | ffmpeg
    int subtitleStreamIndex_ = 0;
    // Conf AUDIO_DELAY_MS — default 0. Applied as FFmpeg adelay on product path.
    int audioDelayMs_ = 0;
    // Starting point for the feed-rate servo, and the open-loop rate if the ring
    // depth cannot be read. Derived from the servo itself: seeded at the old
    // +685 ppm the loop settled holding a 254 B/s correction, so the FPGA's real
    // audio clock is 685 - 1323 = ~-638 ppm off nominal 48 kHz. (It plays
    // *slower* than nominal; the old +685 had the sign inverted because it was
    // measured when a growing ring looked identical to a fast playback clock.)
    // Seeding the truth means the ring settles on the target depth immediately
    // instead of being dragged there. Override with AUDIO_CLOCK_PPM.
    int audioClockPpm_ = -638;
    int audioClockPpmConf_ = -638;
    bool audioClockTrimEnabled_ = true;
    // Seeded with the calibrated default so the first frames of a session are
    // already in sync; the OSD poller overwrites it within ~100 ms.
    std::atomic<int> avOffsetMs_{misterplex::kOsdAvOffsetDefaultMs};
    std::atomic<int> idleMode_{static_cast<int>(IdleMode::Logo)};
    std::atomic<bool> idleRun_{false};
    // Latched by shutdown() so threadMain's session-end startIdle() cannot spawn
    // a fresh painter after we have already joined the old one.
    std::atomic<bool> shuttingDown_{false};
    std::atomic<int> idlePhase_{0};
    std::thread idleThr_;
    std::atomic<bool> idleWarned_{false};
    std::atomic<bool> idleLogged_{false};
    std::mutex idleMu_;
    std::mutex osdMu_; // same for osdThr_ // serialises idleThr_ create/join (play thread vs companion)
    std::mutex presentMu_;
    void applyOsd(uint16_t word);
    void applyDisplayRaster(const ContentResolution& display, bool force = false);
    void applyLiveDisplayRaster(const ContentResolution& osdDisplay, bool force = false);
    // Snapshot the MrAudio ring pointers and occupancy. Cheap: one
    // open/read/close, no allocation.
    MrAudioStatus readMrAudioStatus();

    static std::string hex16(uint16_t v);

    bool osdControl_ = false;
    std::atomic<bool> osdRun_{false};
    std::atomic<uint16_t> lastOsd_{0};
    std::atomic<bool> osdSeen_{false};
    std::thread osdThr_;
    std::mutex inputMu_;
    std::atomic<bool> inputRun_{false};
    std::thread inputThr_;
    int64_t skipForwardMs_ = 30000;
    int64_t skipBackMs_ = 10000;
    std::atomic<int64_t> ignoreInputUntilMs_{0};
    // Present pacing: keep video from free-running ahead of wall/audio (lipsync).
    // Exact rational content rate; 0/0 → treat as 24/1 when pacing with audio.
    int fpsNum_ = 0;
    int fpsDen_ = 0;
    // v0.3/v0.4 lock: 40 ms lead. 0 starves vsync (HEAD log-lie).
    int presentLeadMs_ = 40;
    int avHdmiAudioLagMs_ = -1;
    int resyncDropMs_ = 80;

    FbPresent fb_;
    FpgaSpi fpga_;
    // 720p idle: process-lifetime fabric-direct arena (flag-on). Heap yuv is STUB.
    FabricDirectAlloc idleFabric_{};
    DdrFrameFormat ddrFrameFormat_ = DdrFrameFormat::Yuv420p;
    bool presentProfile_ = false;
    bool useDdrF1_ = true; // F1 product presentation attempts DDR YUV420p only.
    int ddrBank_ = 0;      // ping-pong 0/1; stride comes from ddr_frame_layout.hpp
    // Bytes written to MrAudio this session (A/V clock diagnostics)
    std::atomic<int64_t> audioBytes_{0};
    // Bytes sitting in the MrAudio DMA ring, i.e. handed to the driver but not
    // yet played. -1 = unknown (kernel without the status line) and the clock
    // falls back to counting submitted bytes. See libmisterplex/mraudio_status.hpp.
    std::atomic<int64_t> audioQueuedBytes_{-1};
    // Live A/V drift + resync counters (per play/seek session)
    std::atomic<int64_t> avDriftMs_{0};
    std::atomic<int64_t> droppedFrames_{0};
    // FPGA presents this session (wall-clock capped)
    std::atomic<int64_t> presentCount_{0};
    mutable std::mutex mu_;
    mutable std::mutex summaryMu_;
    PlaybackSummary lastSummary_;
    std::mutex lifeMu_; // serializes play/stop thr_ join + spawn
    std::thread thr_;
    std::thread audioThr_;
    std::thread streamThr_;
#ifdef MPX_HAVE_LIBAV
    AvInprocDecoder* inprocPcm_ = nullptr;
#endif
    std::atomic<bool> stop_{false};
    std::atomic<bool> playing_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> audioActive_{false};
    // 720p: MrAudio stays closed-loop silent until warmup decode finishes, then
    // the HDMI lag hold lets it run. Default true so 480p is unchanged.
    std::atomic<bool> audioFeedRelease_{true};
    // 720p pipe: drain ffmpeg audio while unique warms, then start MrAudio at
    // presentCount content time. 0 = 480p / combined 720p (start with video).
    std::atomic<int> audioReleaseAfterPresents_{0};
    // 480p gold: pump waits if submitted audio is ahead of presentCount.
    // 720p inproc+prefill deadlocks; combined 720p matches 480p (true).
    std::atomic<bool> holdAudioToPictures_{true};
    std::atomic<int> audioAfterVideoMs_{0};
    // Extra audio slack vs presented frames (seconds). Native 1280: +0.080.
    // Scaled 240/480: -0.200 so HDMI pictures (later by ~200 ms) meet beeps.
    std::atomic<int> audioHoldSlackMs_{80};
    std::atomic<bool> streamActive_{false};
    std::mutex pauseControlMu_;
    mutable std::mutex pauseClockMu_;
    int64_t pauseClockAccumulatedUs_ = 0;
    bool pauseClockHeld_ = false;
    std::chrono::steady_clock::time_point pauseClockStarted_{};
    std::atomic<int64_t> reconFrames_{0};
    std::atomic<bool> reconPresentOk_{false}; // at least one recon → F1/fb0 this session
    // Sticky: PPS entropy_coding_mode=1 or recon fail_reason=cabac; cleared only on
    // CAVLC PPS or new play() — not on every in-band SPS (would defeat sticky).
    std::atomic<bool> cabacSkip_{false};
    std::atomic<int64_t> seekReqMs_{-1};
    std::atomic<int64_t> positionMs_{0};
    PlaybackOverlay overlay_;
    std::atomic<pid_t> childPid_{-1};
    std::atomic<pid_t> audioPid_{-1};
    std::atomic<pid_t> streamPid_{-1};
    std::string lastError_;
    std::string currentUrl_;
    std::string currentHeaders_;
    int64_t durationMs_ = 0;
    int outW_ = 320;
    int outH_ = 240;
};

} // namespace misterplex

#endif // MPX_OSD_DECODE_SIZE_ONLY
