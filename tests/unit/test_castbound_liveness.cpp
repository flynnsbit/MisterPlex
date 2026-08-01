// Gate: castBound_ liveness — not the intentional buffering@navigation report.
//
// Defect (parent 2026-08-01): castBound_ latched on /resources (LAN discovery)
// and never expired without unsubscribe → wire buffering forever after a probe.
// Reporting buffering while cast-bound remains intentional (prePlayHold Resume UX).
//
// Contract under test:
//  1) Source must not latch castBound on /resources (static + behavior).
//  2) Idle cast hold expires after castHoldTtlMs_ without cast traffic.
//  3) Fresh touchCastBound refreshes TTL (poll keeps Resume alive).
//  4) wantPlay_ blocks expiry (active session).
//  5) Mutation: TTL disabled + stale clock → forever buffering is RED for product
//     policy when we require expiry path to exist (we assert expire works).
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>

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
    // --- static: companion.cpp must not set castBound on /resources ---
    {
        // Binary runs from repo root under `make unit`; also try relative to cwd.
        std::ifstream in("arm/misterplexd/companion.cpp");
        if (!in.good())
            in.open("../arm/misterplexd/companion.cpp");
        require(in.good(), "open arm/misterplexd/companion.cpp from repo root");
        std::string all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        // Old defect: if (… /player/ … || … /resources …) castBound_ = true
        require(all.find("/resources") != std::string::npos,
                "expected /resources handling still present");
        require(all.find("/resources is a plain LAN discovery") != std::string::npos,
                "missing /resources must-not-latch documentation");
        // Latch must be player-only: touchCastBoundLocked under /player/, not resources.
        require(all.find("if (req.find(\"/player/\") != std::string::npos)\n"
                         "                touchCastBoundLocked()") != std::string::npos ||
                    all.find("if (req.find(\"/player/\") != std::string::npos)\n"
                             "                touchCastBoundLocked();") != std::string::npos,
                "expected player-only touchCastBoundLocked latch");
        // Forbid assigning castBound from a resources-inclusive condition.
        require(all.find("|| req.find(\"/resources\") != std::string::npos)\n"
                         "                castBound_ = true") == std::string::npos &&
                    all.find("|| req.find(\"/resources\") != std::string::npos)\n"
                             "                touchCastBoundLocked") == std::string::npos,
                "castBound must not latch on resources-inclusive condition");
        require(all.find("maybeExpireCastHoldLocked") != std::string::npos,
                "missing cast hold expiry path");
        require(all.find("touchCastBoundLocked") != std::string::npos,
                "missing touchCastBoundLocked liveness clock");
    }

    misterplex::Companion c;
    c.setMachineId("misterplex-dev");

    // --- TTL expiry: stale castBound + !wantPlay → wire stopped ---
    {
        std::lock_guard<std::mutex> lock(c.mu_);
        c.wantPlay_ = false;
        c.state_ = "stopped";
        c.prePlayHold_ = true;
        c.castBound_ = true;
        c.castHoldTtlMs_ = 50; // 50ms
        c.castBoundAt_ = std::chrono::steady_clock::now() - std::chrono::milliseconds(500);
    }
    const std::string expired = c.timelineXml("expired");
    require(has(expired, "state=\"stopped\""),
            "stale cast hold must expire to stopped: " + expired);
    require(!has(expired, "state=\"buffering\""),
            "stale cast hold must not stay buffering: " + expired);
    {
        std::lock_guard<std::mutex> lock(c.mu_);
        require(!c.castBound_, "castBound_ cleared after TTL");
        require(!c.prePlayHold_, "prePlayHold_ cleared after TTL");
    }

    // --- Fresh touch keeps hold (Resume UX within TTL) ---
    {
        std::lock_guard<std::mutex> lock(c.mu_);
        c.wantPlay_ = false;
        c.state_ = "stopped";
        c.castHoldTtlMs_ = 60000;
        c.touchCastBoundLocked();
        c.prePlayHold_ = true;
    }
    const std::string fresh = c.timelineXml("fresh");
    require(has(fresh, "state=\"buffering\""),
            "fresh cast hold still buffering@navigation: " + fresh);

    // --- wantPlay blocks expiry even if clock is ancient ---
    {
        std::lock_guard<std::mutex> lock(c.mu_);
        c.wantPlay_ = true;
        c.state_ = "playing";
        c.castBound_ = true;
        c.prePlayHold_ = false;
        c.castHoldTtlMs_ = 1;
        c.castBoundAt_ = std::chrono::steady_clock::now() - std::chrono::hours(24);
        c.pendingKey_ = "/library/metadata/1";
        c.durationMs_ = 1000;
        c.timeMs_ = 100;
    }
    const std::string playing = c.timelineXml("playing");
    require(has(playing, "state=\"playing\"") || has(playing, "fullScreenVideo"),
            "active play must not be expired by TTL: " + playing);
    {
        std::lock_guard<std::mutex> lock(c.mu_);
        require(c.castBound_, "castBound_ kept during wantPlay despite ancient clock");
    }

    // --- Mutation class: TTL<=0 disables expiry (document lab only) ---
    {
        std::lock_guard<std::mutex> lock(c.mu_);
        c.wantPlay_ = false;
        c.state_ = "stopped";
        c.pendingKey_.clear();
        c.durationMs_ = 0;
        c.castHoldTtlMs_ = 0; // disable
        c.castBound_ = true;
        c.prePlayHold_ = true;
        c.castBoundAt_ = std::chrono::steady_clock::now() - std::chrono::hours(24);
    }
    const std::string noexp = c.timelineXml("no-expire-lab");
    require(has(noexp, "state=\"buffering\""),
            "TTL=0 lab path keeps hold (control): " + noexp);

    std::cout << "test_castbound_liveness: OK resources-not-latch + TTL expire + "
                 "wantPlay blocks + fresh hold\n";
    return 0;
}
