#include "pms_timeline.hpp"

#include "log_redact.hpp"
#include "plex_resolve.hpp"
#include "thread_name.hpp"

#include <algorithm>
#include <cstdio>

namespace misterplex {
namespace {

constexpr size_t kMaxQueue = 4;

bool validState(const std::string& state) {
    return state == "playing" || state == "paused" || state == "stopped" ||
           state == "buffering";
}

bool defaultSink(const PmsTimelineHttpRequest& req) {
    return plexHttpGetNoBody(req.url, req.headers, 4);
}

} // namespace

bool buildPmsTimelineHttpRequest(const PmsTimelineSession& session, const std::string& state,
                                 int64_t timeMs, int64_t durationMs,
                                 PmsTimelineHttpRequest& out) {
    out = {};
    if (session.token.empty() || session.ratingKey.empty() || !validState(state))
        return false;

    std::string base = normalizePlexBase(session.baseUrl);
    if (base.empty())
        return false;

    if (timeMs < 0)
        timeMs = 0;
    if (durationMs < 0)
        durationMs = 0;
    if (durationMs > 0 && timeMs > durationMs)
        timeMs = durationMs;

    std::string key = session.key;
    if (key.empty())
        key = "/library/metadata/" + session.ratingKey;

    out.url = base + "/:/timeline?ratingKey=" + urlEncodeQuery(session.ratingKey) +
              "&key=" + urlEncodeQuery(key) + "&state=" + urlEncodeQuery(state) +
              "&time=" + urlEncodeQuery(std::to_string(timeMs)) +
              "&duration=" + urlEncodeQuery(std::to_string(durationMs)) +
              "&identifier=com.plexapp.plugins.library";
    if (!session.playQueueItemId.empty())
        out.url += "&playQueueItemID=" + urlEncodeQuery(session.playQueueItemId);
    if (!session.containerKey.empty())
        out.url += "&containerKey=" + urlEncodeQuery(session.containerKey);

    out.headers = {
        {"X-Plex-Token", session.token},
        {"X-Plex-Client-Identifier", session.clientIdentifier},
        {"X-Plex-Product", session.product},
        {"X-Plex-Version", session.version},
        {"X-Plex-Device-Name", session.deviceName},
        {"X-Plex-Device", "Linux"},
        {"X-Plex-Platform", "Linux"},
        {"X-Plex-Provides", "player"},
        {"Accept", "application/xml"},
    };
    return true;
}

PmsTimelineReporter::PmsTimelineReporter(HttpSink sink, bool async)
    : sink_(std::move(sink)), async_(async) {
    if (!sink_)
        sink_ = defaultSink;
    if (async_) {
        workerStarted_ = true;
        worker_ = std::thread([this] { workerLoop(); });
    }
}

PmsTimelineReporter::~PmsTimelineReporter() { stopAndFlush(); }

void PmsTimelineReporter::beginSession(const PmsTimelineSession& session, int64_t timeMs,
                                       int64_t durationMs) {
    PmsTimelineHttpRequest req;
    {
        std::lock_guard<std::mutex> lock(mu_);
        active_ = true;
        session_ = session;
        lastSentState_.clear();
        lastPlayingSent_ = {};
        if (!buildPmsTimelineHttpRequest(session_, "buffering", timeMs, durationMs, req)) {
            active_ = false;
            return;
        }
        lastSentState_ = "buffering";
        lastPlayingSent_ = {};
    }
    enqueue(std::move(req), "buffering");
}

bool PmsTimelineReporter::shouldSendLocked(const std::string& state) {
    if (state == "stopped")
        return true;
    if (state != lastSentState_)
        return true;
    if (state == "playing") {
        auto now = std::chrono::steady_clock::now();
        return lastPlayingSent_ == std::chrono::steady_clock::time_point{} ||
               now - lastPlayingSent_ >= kPlayingCadence;
    }
    return false;
}

void PmsTimelineReporter::reportState(const std::string& state, int64_t timeMs,
                                      int64_t durationMs) {
    if (state == "ended") {
        endSession(timeMs, durationMs);
        return;
    }
    PmsTimelineHttpRequest req;
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (!active_ || !shouldSendLocked(state))
            return;
        if (!buildPmsTimelineHttpRequest(session_, state, timeMs, durationMs, req))
            return;
        lastSentState_ = state;
        if (state == "playing")
            lastPlayingSent_ = std::chrono::steady_clock::now();
    }
    enqueue(std::move(req), state);
}

void PmsTimelineReporter::endSession(int64_t timeMs, int64_t durationMs) {
    PmsTimelineHttpRequest req;
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (!active_)
            return;
        if (!buildPmsTimelineHttpRequest(session_, "stopped", timeMs, durationMs, req)) {
            active_ = false;
            return;
        }
        lastSentState_ = "stopped";
        active_ = false;
    }
    enqueue(std::move(req), "stopped");
}

void PmsTimelineReporter::enqueue(PmsTimelineHttpRequest request, const std::string& state) {
    Pending pending{std::move(request), state};
    if (!async_) {
        send(pending);
        return;
    }

    {
        std::lock_guard<std::mutex> lock(mu_);
        if (queue_.size() >= kMaxQueue) {
            auto it = std::find_if(queue_.begin(), queue_.end(),
                                   [](const Pending& p) { return p.state != "stopped"; });
            if (it != queue_.end())
                queue_.erase(it);
            else
                queue_.pop_front();
        }
        queue_.push_back(std::move(pending));
    }
    cv_.notify_one();
}

bool PmsTimelineReporter::send(const Pending& pending) {
    bool ok = false;
    try {
        ok = sink_(pending.request);
    } catch (...) {
        ok = false;
    }
    if (log_) {
        // redactSensitive at the sink boundary; request.url stays real for HTTP.
        log_(redactSensitive(std::string("pms timeline: update ") + (ok ? "ok" : "failed") +
                             " state=" + pending.state + " url=" + pending.request.url));
    }
    return ok;
}

void PmsTimelineReporter::workerLoop() {
    setThreadName("mplex-pms-tl");
    for (;;) {
        Pending pending;
        {
            std::unique_lock<std::mutex> lock(mu_);
            cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
            if (queue_.empty()) {
                if (stopping_)
                    break;
                continue;
            }
            pending = std::move(queue_.front());
            queue_.pop_front();
        }
        send(pending);
    }
}

void PmsTimelineReporter::stopAndFlush() {
    if (!async_)
        return;
    {
        std::lock_guard<std::mutex> lock(mu_);
        if (!workerStarted_)
            return;
        stopping_ = true;
    }
    cv_.notify_one();
    if (worker_.joinable())
        worker_.join();
    workerStarted_ = false;
}

} // namespace misterplex
