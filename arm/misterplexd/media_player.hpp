#pragma once
// Phase 2 media player: single-process FFmpeg → /dev/fb0 + /dev/MrAudio.
// Transitional ARM decode; FPGA owns scanout (MiSTer_fb) + SPI audio (MrAudio).
// STREAM=1: annex-B demux → host I-slice recon → F1 + F3; optional RGB skip.

#include "fb_present.hpp"
#include "fpga_spi.hpp"
#include "libmisterplex/idle_screen.hpp"
#include "libmisterplex/mraudio_status.hpp"
#include "libmisterplex/osd_menu.hpp"
#include "libmisterplex/playback_overlay.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <sys/types.h>

namespace misterplex {

class MediaPlayer {
public:
    ~MediaPlayer() { shutdown(); }

    using LogFn = std::function<void(const std::string&)>;
    using ProgressFn = std::function<void(const std::string& state, int64_t timeMs, int64_t durMs)>;

    void setLog(LogFn f) { log_ = std::move(f); }
    void setProgress(ProgressFn f) { onProgress_ = std::move(f); }
    void setFfmpegPath(std::string p) { ffmpeg_ = std::move(p); }
    void setAudioPath(std::string p) { audioDev_ = std::move(p); }
    void setAudioEnabled(bool on) { audioEnabled_ = on; }
    // present: "fb0" (default) and/or "fpga" (SPI ioctl → frame_store)
    void setPresentMode(std::string mode) { presentMode_ = std::move(mode); }
    void setDdrMemSync(bool on) { fpga_.setDdrMemSync(on); }
    void setDdrMemFlush(bool on) { fpga_.setDdrMemFlush(on); }
    void setPresentProfile(bool on) { presentProfile_ = on; }
    // STREAM=1: demux annex-B H.264 → host I-slice recon (RGB565 → F1) + F3 stub feed
    void setStreamEnabled(bool on) { streamEnabled_ = on; }
    // When STREAM recon owns F1, optionally drop heavy FFmpeg RGB decode (keep audio).
    // "auto" | "1"/"on" = skip RGB from session start when PRESENT=fpga (audio + demux only).
    // PRESENT=both/fb0 always keeps RGB (continuous fb0). CABAC + skip → black F1: set
    // STREAM_SKIP_RGB=0 or PRESENT=both for FFmpeg RGB fallback.
    // "0"/"off" = always full RGB (STREAM=0-compatible fallback path)
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
    // Drift (ms) past which a late frame is dropped to re-converge. Conf AV_RESYNC_DROP_MS.
    // 0 disables dropping (hold-only pacing).
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
    uint16_t lastOsdWord() const { return lastOsd_.load(); }
    // Paint one idle frame right now (used at session end).
    void paintIdle();
    // Live A/V drift: audio clock − content time of the last presented frame.
    // Negative = video ahead of audio (audio sounds late).
    int64_t avDriftMs() const { return avDriftMs_.load(); }
    int64_t droppedFrames() const { return droppedFrames_.load(); }
    void setDecodeSize(int w, int h);
    // Host recon frames presented this session (I/IDR only)
    int64_t reconFrames() const { return reconFrames_.load(); }
    bool reconPresentOk() const { return reconPresentOk_.load(); }

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
    void streamPump(int sfd);
    void killChildren();
    void signalChildren(int sig);
    void dispatchPlaybackInput(PlaybackCommand command);
    // true when STREAM product path may omit heavy RGB video decode (audio + demux only)
    bool wantSkipRgbVideo() const;
    pid_t spawnFfmpeg(const std::vector<std::string>& args, int vWriteFd, int aWriteFd);
    pid_t spawnStreamDemux(const std::string& url, const std::string& headers, int64_t startMs,
                           int writeFd);
    pid_t spawnAudioOnly(const std::string& url, const std::string& headers, int64_t startMs,
                         int aWriteFd);
    void log(const std::string& s) const;

    LogFn log_;
    ProgressFn onProgress_;
    std::string ffmpeg_ = "/media/fat/mistercast/bin/ffmpeg";
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
    // Snapshot the MrAudio ring occupancy. Returns bytes queued, or -1 if the
    // driver does not expose it. Cheap: one open/read/close, no allocation.
    int64_t readMrAudioQueuedBytes();

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
    int presentLeadMs_ = 40;
    int resyncDropMs_ = 80;

    FbPresent fb_;
    FpgaSpi fpga_;
    bool presentProfile_ = false;
    bool useDdrF1_ = true; // prefer DDR bulk (3.1b); cleared on first failure
    int ddrBank_ = 0;      // ping-pong 0/1 @ 0x30000000 / 0x30040000
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
    int64_t presentCount_ = 0;
    mutable std::mutex mu_;
    std::mutex lifeMu_; // serializes play/stop thr_ join + spawn
    std::thread thr_;
    std::thread audioThr_;
    std::thread streamThr_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> playing_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> audioActive_{false};
    std::atomic<bool> streamActive_{false};
    std::atomic<int64_t> reconFrames_{0};
    std::atomic<bool> reconPresentOk_{false}; // at least one recon → F1/fb0 this session
    // Sticky: PPS entropy_coding_mode=1 or recon fail_reason=cabac; cleared only on
    // CAVLC PPS or new play() — not on every in-band SPS (would defeat sticky).
    std::atomic<bool> cabacSkip_{false};
    std::atomic<int64_t> seekReqMs_{-1};
    std::atomic<int64_t> positionMs_{0};
    PlaybackOverlay overlay_;
    std::atomic<pid_t> childPid_{-1};
    std::atomic<pid_t> streamPid_{-1};
    std::string lastError_;
    std::string currentUrl_;
    std::string currentHeaders_;
    int64_t durationMs_ = 0;
    int outW_ = 320;
    int outH_ = 240;
};

} // namespace misterplex
