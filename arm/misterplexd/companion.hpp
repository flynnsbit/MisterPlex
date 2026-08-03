#pragma once
// Plex GDM + companion HTTP for MiSTerPlex Phase 2/4.
// Lessons from mistercast-linux: prePlayHold, castBound, play-queue bind,
// async playMedia ACK, viewOffset ms, resume-dialog hold after stop.

#include "player_identity.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace misterplex {

struct PlayRequest {
    std::string key;
    std::string containerKey;
    std::string playQueueId;
    std::string playQueueItemId;
    std::string playQueueVersion;
    std::string ratingKey;
    std::string address;
    std::string protocol;
    std::string port;
    std::string token;
    std::string serverMachineId;
    int64_t offsetMs = 0;
    bool offsetPresent = false;
};

class Companion {
public:
    using LogFn = std::function<void(const std::string&)>;
    using PlayFn = std::function<void(const PlayRequest&)>;
    using CtrlFn = std::function<void()>;
    using SeekFn = std::function<void(int64_t ms)>;
    using StepFn = std::function<void(int64_t deltaMs)>;

    void setName(std::string n) { name_ = std::move(n); }
    void setMachineId(std::string id) { machineId_ = std::move(id); }
    void setPort(uint16_t p) { port_ = p; }
    void setLog(LogFn f) { log_ = std::move(f); }
    void setPlay(PlayFn f) { onPlay_ = std::move(f); }
    // Fired on the HTTP thread as soon as playMedia plants scrubber state (before
    // the async onPlay_ thread). Used to ++playGen and kill in-flight resolve.
    void setPlayQueued(CtrlFn f) { onPlayQueued_ = std::move(f); }
    void setPause(CtrlFn f) { onPause_ = std::move(f); }
    void setResume(CtrlFn f) { onResume_ = std::move(f); }
    void setStop(CtrlFn f) { onStop_ = std::move(f); }
    void setSeek(SeekFn f) { onSeek_ = std::move(f); }
    // Relative scrubber step (stepForward/stepBack); deltaMs may be negative.
    void setStep(StepFn f) { onStep_ = std::move(f); }
    void setSkipNext(CtrlFn f) { onSkipNext_ = std::move(f); }
    void setSkipPrevious(CtrlFn f) { onSkipPrevious_ = std::move(f); }

    bool start();
    void stop();
    bool running() const { return running_.load(); }

    // Bind one GDM UDP listen socket (SO_REUSEADDR + SO_BROADCAST + CLOEXEC).
    // Used by gdmLoop for every entry in kGdmListenPorts; unit tests call it
    // to prove 32412 and 32414 both bind. Returns fd or -1 (err filled).
    static int openGdmListenFd(uint16_t port, std::string* err = nullptr);

    // Update playback clock (ms) + state for timeline polls.
    void setState(const std::string& state, int64_t timeMs, int64_t durationMs);

    // Converge a real terminal media-session transition (natural EOF / terminal
    // source end after content) onto the same local idle state as explicit stop.
    void endMediaSession(int64_t timeMs, int64_t durationMs);

    // Bind media identity for scrubber (call after resolve / on playMedia).
    // Returns false if session already stopped (late async playMedia after stop)
    // or if a newer cast already planted a different pendingKey (stale resolve).
    bool bindMedia(const PlayRequest& req, int64_t durationMs);

    // Plant scrubber bind for a queue step / skipNext without waiting for resolve.
    // Ensures bindMedia key-match accepts the upcoming doPlay for this key.
    void stagePlay(const PlayRequest& req);

    // Clear media bind (after stop finishes).
    void clearMedia();

    // True while a playMedia session is live (false after stop/clearMedia).
    bool wantPlay() const {
        std::lock_guard<std::mutex> lock(mu_);
        return wantPlay_;
    }

    // Current scrubber timeline position (ms). Used by doPlay to honor seeks
    // that happen while async resolve is still in flight.
    int64_t timelineTimeMs() const {
        std::lock_guard<std::mutex> lock(mu_);
        return timeMs_;
    }

private:
    void gdmLoop();
    void httpLoop();
    std::string gdmPayload() const;
    std::string resourcesXml() const;
    std::string timelineXml(const std::string& commandId) const;
    std::string lanIp() const;
    void log(const std::string& s) const;
    void clearMediaLocked();
    void setStateLocked(const std::string& state, int64_t timeMs, int64_t durationMs,
                        bool terminalSession);
    static std::string xmlEsc(const std::string& s);

    std::string name_ = kPlayerDefaultName;
    std::string machineId_ = kPlayerDefaultMachineId;
    uint16_t port_ = kPlayerDefaultPort;
    LogFn log_;
    PlayFn onPlay_;
    CtrlFn onPlayQueued_;
    CtrlFn onPause_;
    CtrlFn onResume_;
    CtrlFn onStop_;
    SeekFn onSeek_;
    StepFn onStep_;
    CtrlFn onSkipNext_;
    CtrlFn onSkipPrevious_;

    std::atomic<bool> running_{false};
    std::thread gdmThr_;
    std::thread httpThr_;

    mutable std::mutex mu_;
    std::string state_ = "stopped";
    int64_t timeMs_ = 0;
    int64_t durationMs_ = 0;
    // After seek/step plant: pin scrubber to this target until demux playing/
    // paused/ended is within catchup. Buffering never releases (plant itself is
    // buffering@target). Async race — early/stale playing@0 must not rewind.
    // -1 = no hold.
    int64_t scrubTargetMs_ = -1;
    bool wantPlay_ = false;
    bool prePlayHold_ = false;
    bool castBound_ = false;

    // Active / staged media for Web scrubber
    std::string pendingKey_;
    std::string pendingContainerKey_;
    std::string pendingPlayQueueId_;
    std::string pendingPlayQueueItemId_;
    std::string pendingPlayQueueVersion_;
    std::string pendingRatingKey_;
    std::string serverMachineId_;
    std::string serverHost_;
    std::string serverPort_;
    std::string serverProto_ = "http";
};

} // namespace misterplex
