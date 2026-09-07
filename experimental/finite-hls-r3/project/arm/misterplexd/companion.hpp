#pragma once
// Plex GDM + companion HTTP for MiSTerPlex Phase 2/4.
// Lessons from mistercast-linux: prePlayHold, castBound, play-queue bind,
// async playMedia ACK, viewOffset ms, resume-dialog hold after stop.

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

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
    uint64_t dispatchGeneration = 0;
};

enum class TransportCommand { Pause, Resume, Stop, Seek, Previous };

struct TransportRequest {
    uint64_t generation = 0;
    uint64_t originGeneration = 0;
    uint64_t seekGeneration = 0;
    uint64_t epoch = 0;
    int64_t positionMs = 0;
    PlayRequest media;
};

class Companion {
public:
    using LogFn = std::function<void(const std::string&)>;
    using PlayFn = std::function<void(const PlayRequest&)>;
    using PlayQueuedFn = std::function<uint64_t()>;
    using CtrlFn = std::function<void()>;
    using TransportFn = std::function<void(const TransportRequest&)>;
    using TransportQueuedFn = std::function<TransportRequest(TransportCommand)>;
    using StepFn = std::function<void(int64_t deltaMs, const TransportRequest&)>;
    // Guards execute under mu_; they must not acquire locks or re-enter Companion.
    using CurrentFn = std::function<bool()>;

    void setName(std::string n) { name_ = std::move(n); }
    void setMachineId(std::string id) { machineId_ = std::move(id); }
    void setPort(uint16_t p) { port_ = p; }
    void setLog(LogFn f) { log_ = std::move(f); }
    void setPlay(PlayFn f) { onPlay_ = std::move(f); }
    // Fired on the HTTP thread as soon as playMedia plants scrubber state (before
    // the async onPlay_ thread). Its generation follows that exact request into
    // the detached handler so an older thread can never promote itself later.
    void setPlayQueued(PlayQueuedFn f) { onPlayQueued_ = std::move(f); }
    // Cast may present a fresher X-Plex-Token / token= on later player requests
    // (seek, second playMedia, some polls). Forward to PMS timeline session.
    using TokenFn = std::function<void(const std::string& token)>;
    void setTokenUpdate(TokenFn f) { onTokenUpdate_ = std::move(f); }
    // Called under the state lock; the hook may perform only nonblocking atomic work.
    void setTransportQueued(TransportQueuedFn f) { onTransportQueued_ = std::move(f); }
    void setPause(TransportFn f) { onPause_ = std::move(f); }
    void setResume(TransportFn f) { onResume_ = std::move(f); }
    void setStop(TransportFn f) { onStop_ = std::move(f); }
    void setSeek(TransportFn f) { onSeek_ = std::move(f); }
    // Relative scrubber step (stepForward/stepBack); deltaMs may be negative.
    void setStep(StepFn f) { onStep_ = std::move(f); }
    void setSkipNext(CtrlFn f) { onSkipNext_ = std::move(f); }
    void setSkipPrevious(TransportFn f) { onSkipPrevious_ = std::move(f); }
    void setPlexTvEnabled(bool) {}
    void setPlexTvToken(const std::string&) {}
    void setPlexTvLinkPath(const std::string&) {}
    void setPlexTvPersist(std::function<void(const std::string&)>) {}
    void closedStop(int64_t timeMs, int64_t durationMs, bool terminal = false) {
        setState("stopped", timeMs, durationMs, terminal);
    }

    bool start();
    void stop();
    bool running() const { return running_.load(); }
    bool httpReady() const { return httpReady_.load(); }

    // Update playback clock (ms) + state for timeline polls.
    void setState(const std::string& state, int64_t timeMs, int64_t durationMs,
                  bool terminal = false, const CurrentFn& current = {});

    // Bind media identity for scrubber (call after resolve / on playMedia).
    // Returns false if session already stopped (late async playMedia after stop)
    // or if a newer cast already planted a different pendingKey (stale resolve).
    bool bindMedia(const PlayRequest& req, int64_t durationMs);

    // Plant scrubber bind for a queue step / skipNext without waiting for resolve.
    // Ensures bindMedia key-match accepts the upcoming doPlay for this key.
    bool stagePlay(const PlayRequest& req, const CurrentFn& current = {});

    // Align plant + displayed clock to the demux start about to begin (e.g. PMS
    // viewOffset when cast omitted offset=). Keeps seek-hold semantics: early
    // demux restart behind this target still pins; live time ahead adopts.
    // Port of 0abee0b6 — without this, Web scrubber freezes at 0:00.
    void seedPlaybackPosition(int64_t timeMs, int64_t durationMs);

    // Accept Stop and invalidate queued work before clearing the bind.
    // The caller retires the player only after this state lock is released.
    TransportRequest clearMedia();
    bool seekTo(int64_t ms, const CurrentFn& current = {});

    // True while a playMedia session is live (false after stop/clearMedia).
    bool wantPlay() const {
        std::lock_guard<std::mutex> lock(mu_);
        return wantPlay_;
    }

    bool acceptsPlayRequest(const PlayRequest& req) const {
        std::lock_guard<std::mutex> lock(mu_);
        return wantPlay_ &&
               (pendingKey_.empty() || req.key.empty() || pendingKey_ == req.key);
    }

    // Current scrubber timeline position (ms). Used by doPlay to honor seeks
    // that happen while async resolve is still in flight.
    int64_t timelineTimeMs() const {
        std::lock_guard<std::mutex> lock(mu_);
        return timeMs_;
    }

private:
    struct TimelineSubscriber {
        std::string id;
        std::string host;
        std::string protocol;
        std::string commandId;
        uint16_t port = 0;
        unsigned failures = 0;
    };

    struct ControllerCommand {
        std::string id;
        std::string host;
        std::string commandId;
    };

    void gdmLoop();
    void httpLoop();
    void timelinePushLoop();
    void requestTimelinePush(bool immediate);
    void subscribeTimeline(const std::string& id, const std::string& host,
                           const std::string& protocol, uint16_t port,
                           const std::string& commandId);
    void updateTimelineCommand(const std::string& id, const std::string& host,
                               const std::string& commandId);
    std::string timelineCommandFor(const std::string& id, const std::string& host,
                                   const std::string& commandId);
    bool unsubscribeTimeline(const std::string& id, const std::string& host);
    bool postTimeline(const TimelineSubscriber& subscriber,
                      const std::string& xml) const;
    std::string gdmPayload() const;
    std::string resourcesXml() const;
    std::string timelineXml(const std::string& commandId) const;
    std::string lanIp() const;
    void log(const std::string& s) const;
    TransportRequest transportRequestLocked(TransportCommand command);
    bool acceptSeekLocked(int64_t ms, TransportRequest& request);
    bool acceptPauseResumeLocked(bool pause, TransportRequest& request);
    static std::string xmlEsc(const std::string& s);

    std::string name_ = "MiSTerPlex";
    std::string machineId_ = "misterplex-1";
    uint16_t port_ = 3005;
    LogFn log_;
    PlayFn onPlay_;
    PlayQueuedFn onPlayQueued_;
    TokenFn onTokenUpdate_;
    TransportQueuedFn onTransportQueued_;
    TransportFn onPause_;
    TransportFn onResume_;
    TransportFn onStop_;
    TransportFn onSeek_;
    StepFn onStep_;
    CtrlFn onSkipNext_;
    TransportFn onSkipPrevious_;

    bool openHttpListen();

    std::atomic<bool> running_{false};
    std::atomic<bool> httpReady_{false};
    int httpListenFd_{-1};
    std::thread gdmThr_;
    std::thread httpThr_;
    std::thread timelinePushThr_;

    std::mutex subscriberMu_;
    std::vector<TimelineSubscriber> subscribers_;
    std::vector<ControllerCommand> controllerCommands_;
    std::mutex timelinePushMu_;
    std::condition_variable timelinePushCv_;
    bool timelinePushPending_ = false;
    bool timelinePushImmediate_ = false;

    mutable std::mutex mu_;
    std::string state_ = "stopped";
    bool terminalStop_ = false;
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
    std::string pendingToken_;
    uint64_t pendingGeneration_ = 0;
    std::string serverMachineId_;
    std::string serverHost_;
    std::string serverPort_;
    std::string serverProto_ = "http";
};

} // namespace misterplex
