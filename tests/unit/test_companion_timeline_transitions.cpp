// Companion local timeline transitions that Plex Web / Playwright poll via
// /player/timeline/poll. Models the real cast path observed on device:
//   playMedia ACK → buffering time=0 duration=0 (pre-resolve)
//   bindMedia + setState buffering → duration populated
//   playing with advancing time=
//   paused → playing → terminal stop
// Asserts state, time, duration, controllable — not merely "a Timeline exists".
#include <cstdlib>
#include <iostream>
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

// Extract attribute value: name="value"
std::string attr(const std::string& xml, const std::string& name) {
    const std::string key = name + "=\"";
    auto p = xml.find(key);
    if (p == std::string::npos)
        return {};
    p += key.size();
    auto e = xml.find('"', p);
    if (e == std::string::npos)
        return {};
    return xml.substr(p, e - p);
}

// Documentation TEST-NET-3 — not a lab IP (test_no_private_data).
misterplex::PlayRequest rk3Request() {
    misterplex::PlayRequest req;
    req.key = "/library/metadata/3";
    req.ratingKey = "3";
    req.playQueueItemId = "3";
    req.address = "203.0.113.10";
    req.protocol = "http";
    req.port = "32400";
    req.serverMachineId = "plex-local-tests";
    req.offsetMs = 0;
    req.offsetPresent = true;
    return req;
}

constexpr const char* kCtrl =
    "playPause,stop,volume,audioStream,subtitleStream,seekTo,skipPrevious,skipNext,"
    "stepBack,stepForward";

void requireControllable(const std::string& xml, const std::string& where) {
    require(has(xml, std::string("controllable=\"") + kCtrl + "\""),
            where + " missing controllable caps: " + xml);
}

} // namespace

int main() {
    misterplex::Companion comp;
    comp.setMachineId("misterplex-dev");
    comp.setName("MiSTerPlex");

    misterplex::PlayRequest req = rk3Request();

    // --- 1. playMedia ACK equivalent: stage before resolve/bind ---
    // Device log: state="buffering" time="0" duration="0" location=fullScreenVideo
    comp.stagePlay(req);
    {
        const std::string ack = comp.timelineXml("ack");
        require(attr(ack, "state") == "buffering", "ACK state not buffering: " + ack);
        require(attr(ack, "time") == "0", "ACK time not 0: " + ack);
        require(attr(ack, "duration") == "0", "ACK duration not 0 (pre-bind): " + ack);
        require(attr(ack, "location") == "fullScreenVideo", "ACK not fullScreenVideo: " + ack);
        require(has(ack, "key=\"/library/metadata/3\""), "ACK lost key: " + ack);
        requireControllable(ack, "ACK");
    }

    // --- 2. resolve/bind populates duration (still buffering until demux starts) ---
    constexpr int64_t kDur = 30000; // 30s test asset class (RK3)
    require(comp.bindMedia(req, kDur), "bindMedia rejected staged RK3");
    comp.setState("buffering", 0, kDur);
    {
        const std::string buf = comp.timelineXml("bound");
        require(attr(buf, "state") == "buffering", "bound state: " + buf);
        require(attr(buf, "time") == "0", "bound time: " + buf);
        require(attr(buf, "duration") == "30000", "bound duration not populated: " + buf);
        require(has(buf, "seekRange=\"0-30000\""), "bound missing seekRange: " + buf);
        require(attr(buf, "location") == "fullScreenVideo", "bound location: " + buf);
        requireControllable(buf, "bound");
    }

    // --- 3. buffering -> playing with advancing time= (Playwright position source) ---
    comp.setState("playing", 1000, kDur);
    const std::string p1 = comp.timelineXml("p1");
    require(attr(p1, "state") == "playing", "playing@1s state: " + p1);
    require(attr(p1, "time") == "1000", "playing@1s time: " + p1);
    require(attr(p1, "duration") == "30000", "playing@1s duration: " + p1);

    comp.setState("playing", 5000, kDur);
    const std::string p2 = comp.timelineXml("p2");
    require(attr(p2, "state") == "playing", "playing@5s state: " + p2);
    require(attr(p2, "time") == "5000", "playing@5s time: " + p2);
    require(std::stoll(attr(p2, "time")) > std::stoll(attr(p1, "time")),
            "time did not advance 1000->5000: p1=" + p1 + " p2=" + p2);
    require(attr(p2, "duration") == "30000", "playing@5s lost duration: " + p2);
    requireControllable(p2, "playing@5s");

    // --- 4. playing -> paused (UI pause) ---
    comp.setState("paused", 5000, kDur);
    {
        const std::string paused = comp.timelineXml("paused");
        require(attr(paused, "state") == "paused", "paused state: " + paused);
        require(attr(paused, "time") == "5000", "paused time: " + paused);
        require(attr(paused, "duration") == "30000", "paused duration: " + paused);
        requireControllable(paused, "paused");
    }

    // --- 5. paused -> playing resume ---
    comp.setState("playing", 8000, kDur);
    {
        const std::string res = comp.timelineXml("resume");
        require(attr(res, "state") == "playing", "resume state: " + res);
        require(attr(res, "time") == "8000", "resume time: " + res);
        require(std::stoll(attr(res, "time")) > 5000, "resume time not past pause: " + res);
    }

    // --- 6. terminal stop clears bind (navigation, no stale key) ---
    comp.endMediaSession(8000, kDur);
    {
        const std::string stop = comp.timelineXml("stop");
        require(attr(stop, "location") == "navigation", "stop location: " + stop);
        require(attr(stop, "duration") == "0", "stop duration should clear: " + stop);
        require(!has(stop, "key=\"/library/metadata/3\""), "stop retained key: " + stop);
        require(!has(stop, "fullScreenVideo"), "stop retained fullScreenVideo: " + stop);
        requireControllable(stop, "stop");
    }

    // --- 7. mid-play duration stays bound across rebuffer ---
    // stagePlay plants scrubTarget=offset (0). A far jump (playing@12s) is held at
    // the plant until a near-plant playing pulse releases it (kScrubCatchupMs).
    // Model real demux: near pulse first, then advance, then brief rebuffer.
    misterplex::Companion cast2;
    cast2.setMachineId("misterplex-dev");
    auto req2 = rk3Request();
    cast2.stagePlay(req2);
    require(cast2.bindMedia(req2, kDur), "cast2 bind");
    cast2.setState("buffering", 0, kDur);
    cast2.setState("playing", 500, kDur);   // near plant → release scrub hold
    cast2.setState("playing", 12000, kDur); // free-run advance
    {
        const std::string mid = cast2.timelineXml("mid");
        require(attr(mid, "time") == "12000", "free-run time after plant release: " + mid);
    }
    cast2.setState("buffering", 12000, kDur); // brief rebuffer (no scrub plant)
    cast2.setState("playing", 15000, kDur);
    {
        const std::string t = cast2.timelineXml("rebuffer");
        require(attr(t, "state") == "playing", "post-rebuffer state: " + t);
        require(attr(t, "time") == "15000", "post-rebuffer time: " + t);
        require(attr(t, "duration") == "30000", "rebuffer dropped duration: " + t);
        require(has(t, "ratingKey=\"3\""), "rebuffer lost ratingKey: " + t);
    }

    std::cout << "test_companion_timeline_transitions: OK\n";
    return 0;
}
