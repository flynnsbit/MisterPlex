#pragma once
// Plex GDM + companion HTTP for MiSTerPlex Phase 2/4.
// Lessons from mistercast-linux: prePlayHold, castBound, play-queue bind,
// async playMedia ACK, viewOffset ms, resume-dialog hold after stop.

#include "player_identity.hpp"

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
    uint64_t parentDispatchGeneration = 0;
};

struct TokenUpdate {
    std::string token;
    std::string address;
    std::string protocol;
    std::string port;
    std::string serverMachineId;
};

class Companion {
public:
    using LogFn = std::function<void(const std::string&)>;
    using PlayFn = std::function<void(const PlayRequest&)>;
    using PlayQueuedFn = std::function<uint64_t(const PlayRequest& request)>;
    using CtrlFn = std::function<void()>;
    using SeekFn = std::function<void(int64_t ms)>;
    using StepFn = std::function<void(int64_t deltaMs)>;

    void setName(std::string n) { name_ = std::move(n); }
    void setMachineId(std::string id) { machineId_ = std::move(id); }
    void setPort(uint16_t p) { port_ = p; }
    void setLog(LogFn f) { log_ = std::move(f); }
    void setPlay(PlayFn f) { onPlay_ = std::move(f); }
    // Fired synchronously on the HTTP thread before playMedia ACK and before the
    // async onPlay_ thread. The callback can atomically publish pending identity;
    // its generation follows that exact request into the detached handler.
    void setPlayQueued(PlayQueuedFn f) { onPlayQueued_ = std::move(f); }
    // A later control may present fresher PMS auth. Only identity-qualified
    // updates from the current playMedia command epoch are forwarded.
    using TokenFn = std::function<void(const TokenUpdate& update)>;
    void setTokenUpdate(TokenFn f) { onTokenUpdate_ = std::move(f); }
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
    bool setStateIfGeneration(uint64_t generation, const std::string& state,
                              int64_t timeMs, int64_t durationMs);

    // Converge a real terminal media-session transition (natural EOF / terminal
    // source end after content) onto the same local idle state as explicit stop.
    void endMediaSession(int64_t timeMs, int64_t durationMs);
    bool endMediaSessionIfGeneration(uint64_t generation, int64_t timeMs,
                                     int64_t durationMs);

    // Bind media identity for scrubber (call after resolve / on playMedia).
    // Returns false if session already stopped (late async playMedia after stop)
    // or if a newer cast already planted a different pendingKey (stale resolve).
    bool bindMedia(const PlayRequest& req, int64_t durationMs);

    // Plant scrubber bind for a queue step / skipNext without waiting for resolve.
    // Ensures bindMedia key-match accepts the upcoming doPlay for this key.
    bool stagePlay(const PlayRequest& req);

    // Publish the main-loop generation before a playMedia callback returns or a
    // generated restart stages media. Stale queue work cannot overwrite a newer
    // cast/stop plant even if it reaches Companion after the main handoff.
    void noteDispatchGeneration(uint64_t generation);

    // Align plant + displayed clock to the demux start about to begin (e.g. PMS
    // viewOffset when cast omitted offset=). Keeps seek-hold semantics: early
    // demux restart behind this target still pins; live time ahead adopts.
    // Port of 0abee0b6 — without this, Web scrubber freezes at 0:00.
    void seedPlaybackPosition(int64_t timeMs, int64_t durationMs);

    // Clear media bind (after stop finishes).
    void clearMedia();

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
    void clearMediaLocked();
    void setStateLocked(const std::string& state, int64_t timeMs, int64_t durationMs,
                        bool terminalSession);
    static std::string xmlEsc(const std::string& s);

    std::string name_ = kPlayerDefaultName;
    std::string machineId_ = kPlayerDefaultMachineId;
    uint16_t port_ = kPlayerDefaultPort;
    LogFn log_;
    PlayFn onPlay_;
    PlayQueuedFn onPlayQueued_;
    TokenFn onTokenUpdate_;
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
    std::string playControllerId_;
    std::string playCommandId_;
    uint64_t dispatchGeneration_ = 0;
};

} // namespace misterplex
