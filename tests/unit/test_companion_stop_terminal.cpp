// Intended contract for stop + cast hold (parent retraction 2026-08-01).
//
// NOT a defect: after stop, internal state_ is "stopped" (idle/STOPPED on glass)
// while the timeline WIRE reports buffering@navigation when castBound_/prePlayHold_
// so Plex Web keeps the Resume dialog without a fresh mirror.
//   clearMediaLocked: state_="stopped"; if (castBound_) prePlayHold_=true;
//   timelineXml holdIdle: !wantPlay_ && (prePlayHold_ || castBound_) → wire buffering
//
// A gate that demanded wire state=stopped after stop would FAIL on correct code
// and tempt "fixing" a real UX feature. This gate encodes the intended contract.
//
// castBound_ release: cleared on /player/timeline/unsubscribe (and then prePlayHold_
// clears when !wantPlay). No idle timeout in-tree — sticky until unsubscribe or
// a new playMedia (which sets wantPlay and clears prePlayHold). Documented, not
// filed as a bug without a failing product scenario.
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>

#define private public
#include "companion.hpp"
#undef private

namespace {

void require(bool ok, const std::string& msg) {
    if (!ok) {
        std::cerr << "FAIL: " << msg << "\n";
        std::exit(1);
    }
}

bool has(const std::string& s, const std::string& needle) {
    return s.find(needle) != std::string::npos;
}

misterplex::PlayRequest episodeRequest() {
    misterplex::PlayRequest req;
    req.key = "/library/metadata/9";
    req.ratingKey = "9";
    req.playQueueItemId = "9";
    req.address = "192.168.1.41";
    req.protocol = "http";
    req.port = "32400";
    req.serverMachineId = "plex-server";
    req.offsetMs = 0;
    req.offsetPresent = true;
    return req;
}

} // namespace

int main() {
    misterplex::Companion comp;
    comp.setMachineId("misterplex-dev");

    auto req = episodeRequest();
    comp.stagePlay(req);
    require(comp.bindMedia(req, 600000), "bindMedia rejected");
    {
        std::lock_guard<std::mutex> lock(comp.mu_);
        comp.wantPlay_ = true;
        comp.prePlayHold_ = false;
        comp.touchCastBoundLocked(); // refresh liveness clock (not bare castBound_=true)
        comp.castHoldTtlMs_ = 600000; // hold must outlive this test
    }
    comp.setState("playing", 12000, 600000);

    // Explicit stop (clearMedia) while cast-bound.
    comp.clearMedia();
    {
        std::lock_guard<std::mutex> lock(comp.mu_);
        require(comp.state_ == "stopped",
                "internal state_ must be stopped after clearMedia, got " + comp.state_);
        require(comp.prePlayHold_,
                "prePlayHold_ must stick when castBound after clearMedia");
        require(comp.castBound_, "castBound_ still true after stop (no unsubscribe yet)");
        require(!comp.wantPlay_, "wantPlay_ false after clearMedia");
    }
    const std::string wire = comp.timelineXml("after-stop");
    require(has(wire, "location=\"navigation\""),
            "stop wire location navigation: " + wire);
    require(has(wire, "state=\"buffering\""),
            "intended wire hold is buffering@navigation: " + wire);
    require(has(wire, "duration=\"0\""), "stop retained duration: " + wire);
    require(!has(wire, "key=\"/library/metadata/9\""),
            "stop must drop media key: " + wire);

    // Unsubscribe releases the hold → pure stopped on the wire.
    {
        std::lock_guard<std::mutex> lock(comp.mu_);
        comp.castBound_ = false;
        if (!comp.wantPlay_)
            comp.prePlayHold_ = false;
    }
    const std::string released = comp.timelineXml("after-unsub");
    require(has(released, "state=\"stopped\""),
            "after unsubscribe wire must be stopped: " + released);
    require(!has(released, "state=\"buffering\""),
            "after unsubscribe must not hold buffering: " + released);

    // Re-arm cast hold without media — wire buffering again (Resume UX).
    {
        std::lock_guard<std::mutex> lock(comp.mu_);
        comp.state_ = "stopped";
        comp.wantPlay_ = false;
        comp.touchCastBoundLocked();
        comp.prePlayHold_ = true;
        comp.castHoldTtlMs_ = 600000;
    }
    const std::string rehold = comp.timelineXml("rehold");
    require(has(rehold, "state=\"buffering\""),
            "castBound+prePlayHold must force wire buffering: " + rehold);

    std::cout << "test_companion_stop_terminal: OK intended contract — "
                 "internal stopped + wire buffering@navigation while castBound; "
                 "unsubscribe → wire stopped\n";
    return 0;
}
