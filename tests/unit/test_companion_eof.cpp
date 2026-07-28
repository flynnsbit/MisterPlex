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

} // namespace

int main() {
    misterplex::Companion comp;
    comp.setMachineId("misterplex-dev");

    misterplex::PlayRequest req;
    req.key = "/library/metadata/3";
    req.ratingKey = "3";
    req.playQueueItemId = "3";
    req.address = "192.168.1.41";
    req.protocol = "http";
    req.port = "32400";
    req.serverMachineId = "plex-server";
    req.offsetMs = 0;
    req.offsetPresent = true;

    comp.stagePlay(req);
    require(comp.bindMedia(req, 1286942), "bindMedia rejected staged play");
    comp.setState("playing", 1285862, 1286942);
    const std::string live = comp.timelineXml("live");
    require(has(live, "location=\"fullScreenVideo\""), "live playback not fullScreenVideo: " + live);
    require(has(live, "key=\"/library/metadata/3\""), "live playback lost key: " + live);

    // Regression contract: natural EOF with no auto-next must converge to the same
    // local/companion state as explicit stop. MediaPlayer already paints idle at EOF;
    // the companion must clear the media bind so timeline polls are navigation,
    // duration=0, and contain no stale media key. The old path did
    // buffering@duration while deciding auto-next, then setState("stopped", duration,
    // duration) without clearMedia(), leaving fullScreenVideo/buffering forever.
    comp.setState("buffering", 1286942, 1286942);
    comp.setState("stopped", 1286942, 1286942);
    const std::string eof = comp.timelineXml("eof");
    require(has(eof, "location=\"navigation\""), "EOF did not return to navigation: " + eof);
    require(has(eof, "state=\"buffering\""), "EOF stop hold should be buffering@navigation: " + eof);
    require(has(eof, "duration=\"0\""), "EOF retained stale duration: " + eof);
    require(!has(eof, "key=\"/library/metadata/3\""), "EOF retained stale media key: " + eof);
    require(!has(eof, "fullScreenVideo"), "EOF retained fullScreenVideo: " + eof);

    std::cout << "test_companion_eof: OK\n";
    return 0;
}
