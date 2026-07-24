// misterplexd — ARM-side daemon for MiSTerPlex.
// Phase 2: GDM + companion + FFmpeg → /dev/fb0 (FPGA scanout via MiSTer_fb).
// Phase 4: multi-server conf, auto next-episode, optional subtitle burn-in.

#include "companion.hpp"
#include "media_player.hpp"
#include "plex_resolve.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop.store(true); }

std::string loadConf(const std::string& path, const char* key) {
    std::ifstream in(path);
    if (!in)
        return {};
    const std::string p = std::string(key) + "=";
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#')
            continue;
        if (line.rfind(p, 0) == 0)
            return line.substr(p.size());
    }
    return {};
}

// Collect every KEY= value (for multi-line PLEX_BASE=).
std::vector<std::string> loadConfAll(const std::string& path, const char* key) {
    std::vector<std::string> out;
    std::ifstream in(path);
    if (!in)
        return out;
    const std::string p = std::string(key) + "=";
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#')
            continue;
        if (line.rfind(p, 0) == 0)
            out.push_back(line.substr(p.size()));
    }
    return out;
}

bool confTruthy(const std::string& v) {
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

} // namespace

int main(int argc, char** argv) {
    std::string name = "MiSTerPlex";
    std::string machineId = "misterplex-1";
    int port = 3005;
    std::string ffmpeg = "/media/fat/mistercast/bin/ffmpeg";
    std::string confPath = "/media/fat/misterplex/misterplex.conf";
    std::string confToken;
    int decodeW = 320, decodeH = 240;
    std::string presentMode = "fb0";
    bool streamEnabled = false;
    std::string streamSkipRgb = "auto"; // auto | on | off — skip heavy RGB when PRESENT=fpga
    bool autoNext = true;
    std::string subtitleMode = "off"; // off | burn | ffmpeg
    int subtitleStreamId = -1;
    // Phase 4 match-source-Hz: conf reserved for switchres; Content FPS hint is software-only.
    std::string matchSourceHz = "off";
    std::string sourceFpsConf = "auto";
    misterplex::WeakLadder weak;
    std::vector<std::string> servers;
    std::string defaultPms = "http://192.168.1.41:32400";

    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--name") == 0 && i + 1 < argc)
            name = argv[++i];
        else if (std::strcmp(argv[i], "--id") == 0 && i + 1 < argc)
            machineId = argv[++i];
        else if (std::strcmp(argv[i], "--port") == 0 && i + 1 < argc)
            port = std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--ffmpeg") == 0 && i + 1 < argc)
            ffmpeg = argv[++i];
        else if (std::strcmp(argv[i], "--pms") == 0 && i + 1 < argc)
            defaultPms = argv[++i];
        else if (std::strcmp(argv[i], "--conf") == 0 && i + 1 < argc)
            confPath = argv[++i];
        else if (std::strcmp(argv[i], "--decode") == 0 && i + 1 < argc) {
            int w = 0, h = 0;
            if (std::sscanf(argv[++i], "%dx%d", &w, &h) == 2) {
                decodeW = w;
                decodeH = h;
            }
        } else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("misterplexd [--name N] [--id ID] [--port N] [--ffmpeg PATH] [--pms URL] "
                        "[--conf PATH] [--decode WxH]\n");
            return 0;
        }
    }
    {
        // Multi-server: PLEX_SERVERS=url1,url2 and/or repeated PLEX_BASE= lines.
        auto baseLines = loadConfAll(confPath, "PLEX_BASE");
        auto serversCsv = loadConf(confPath, "PLEX_SERVERS");
        servers = misterplex::mergePlexServers(serversCsv, baseLines);
        auto host = loadConf(confPath, "PLEX_HOST");
        if (!host.empty()) {
            auto hbase = misterplex::normalizePlexBase(host);
            if (!hbase.empty()) {
                bool seen = false;
                for (const auto& s : servers) {
                    if (s == hbase) {
                        seen = true;
                        break;
                    }
                }
                if (!seen)
                    servers.insert(servers.begin(), hbase);
            }
        }
        if (!servers.empty())
            defaultPms = servers.front();
        else {
            auto n = misterplex::normalizePlexBase(defaultPms);
            if (!n.empty()) {
                defaultPms = n;
                servers.push_back(n);
            }
        }

        confToken = loadConf(confPath, "PLEX_TOKEN");
        auto v = loadConf(confPath, "FFMPEG");
        if (!v.empty())
            ffmpeg = v;
        v = loadConf(confPath, "DECODE");
        if (!v.empty()) {
            int w = 0, h = 0;
            if (std::sscanf(v.c_str(), "%dx%d", &w, &h) == 2) {
                decodeW = w;
                decodeH = h;
            }
        }
        v = loadConf(confPath, "WEAK_RES");
        if (!v.empty())
            weak.videoResolution = v;
        v = loadConf(confPath, "WEAK_BITRATE");
        if (!v.empty())
            weak.maxVideoBitrateKbps = std::atoi(v.c_str());
        v = loadConf(confPath, "PRESENT");
        if (!v.empty())
            presentMode = v; // fb0 | fpga | both
        v = loadConf(confPath, "STREAM");
        if (!v.empty())
            streamEnabled = confTruthy(v);
        v = loadConf(confPath, "STREAM_SKIP_RGB");
        if (!v.empty())
            streamSkipRgb = v;
        v = loadConf(confPath, "AUTO_NEXT");
        if (!v.empty())
            autoNext = confTruthy(v);
        // Phase 4 subtitles: off | burn (PMS universal) | ffmpeg (local files, STREAM=0)
        v = loadConf(confPath, "SUBTITLES");
        if (!v.empty()) {
            subtitleMode = v;
            if (v == "burn" || v == "1" || v == "true" || v == "yes" || v == "on") {
                weak.burnSubtitles = true;
                subtitleMode = (v == "ffmpeg") ? "ffmpeg" : "burn";
            } else if (v == "ffmpeg") {
                subtitleMode = "ffmpeg";
            } else {
                subtitleMode = "off";
            }
        }
        v = loadConf(confPath, "SUBTITLE_STREAM");
        if (!v.empty()) {
            subtitleStreamId = std::atoi(v.c_str());
            weak.subtitleStreamId = subtitleStreamId;
        }
        // Phase 4: match-source-Hz / Content FPS (see docs/match-source-hz.md).
        // Conf is applied on each play: SOURCE_FPS selects Content FPS hint from PMS
        // metadata (or forces 12/24/30/60). MATCH_SOURCE_HZ=on still cannot switch
        // modelines without HPS switchres — logs target only.
        v = loadConf(confPath, "MATCH_SOURCE_HZ");
        if (!v.empty())
            matchSourceHz = v;
        v = loadConf(confPath, "SOURCE_FPS");
        if (!v.empty())
            sourceFpsConf = v;
        std::fprintf(stderr,
                     "misterplexd: MATCH_SOURCE_HZ=%s SOURCE_FPS=%s "
                     "(cadence/OSD path; switchres TODO)\n",
                     matchSourceHz.c_str(), sourceFpsConf.c_str());
    }
    // Align weak ladder with decode size when still default
    if (weak.videoResolution == "320x240" && (decodeW != 320 || decodeH != 240)) {
        weak.videoResolution = std::to_string(decodeW) + "x" + std::to_string(decodeH);
        if (decodeW >= 640)
            weak.maxVideoBitrateKbps = 2000;
        else if (decodeW >= 480)
            weak.maxVideoBitrateKbps = 1500;
    }

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    std::signal(SIGCHLD, SIG_DFL);

    misterplex::MediaPlayer player;
    player.setFfmpegPath(ffmpeg);
    player.setDecodeSize(decodeW, decodeH);
    player.setPresentMode(presentMode);
    player.setStreamEnabled(streamEnabled);
    player.setStreamSkipRgb(streamSkipRgb);
    if (subtitleMode == "ffmpeg")
        player.setSubtitleMode("ffmpeg");
    if (subtitleStreamId >= 0)
        player.setSubtitleStreamIndex(subtitleStreamId);
    player.setLog([](const std::string& s) { std::fprintf(stderr, "%s\n", s.c_str()); });
    if (streamEnabled) {
        std::fprintf(stderr,
                     "misterplexd: STREAM=1 (annex-B → host I-recon F1 + F3; preferDirectH264; "
                     "PRESENT=%s STREAM_SKIP_RGB=%s — skip RGB only when PRESENT=fpga)\n",
                     presentMode.c_str(), streamSkipRgb.c_str());
    }
    if (weak.burnSubtitles)
        std::fprintf(stderr, "misterplexd: SUBTITLES=burn (PMS universal)\n");
    else if (subtitleMode == "ffmpeg")
        std::fprintf(stderr, "misterplexd: SUBTITLES=ffmpeg (local files, STREAM=0)\n");
    if (!player.initPresent()) {
        std::fprintf(stderr, "misterplexd: WARNING no present path — companion only\n");
    }

    misterplex::Companion comp;
    comp.setName(name);
    comp.setMachineId(machineId);
    comp.setPort(static_cast<uint16_t>(port));
    comp.setLog([](const std::string& s) { std::fprintf(stderr, "%s\n", s.c_str()); });

    // Session context for multi-base resolve + auto-next.
    std::mutex sessionMu;
    misterplex::PlayRequest lastPlay;
    std::string lastBase = defaultPms;
    std::string lastToken = confToken;
    std::atomic<bool> autoNextInFlight{false};
    // Monotonic play generation: supersede in-flight async resolve when a newer
    // playMedia/auto-next arrives (P4-SCRUB out-of-order bind race).
    std::atomic<uint64_t> playGen{0};

    auto resolveAgainstServers = [&](const misterplex::PlayRequest& req,
                                     const std::string& preferredBase, int64_t off)
        -> std::pair<misterplex::ResolveResult, std::string> {
        std::string token = req.token.empty() ? confToken : req.token;
        // Cast-selected base wins when address present.
        std::string selected =
            misterplex::buildPlexBase(req.protocol, req.address, req.port, preferredBase);
        if (selected.empty())
            selected = preferredBase.empty() ? defaultPms : preferredBase;

        auto tryBase = [&](const std::string& base) -> misterplex::ResolveResult {
            // STREAM=1: prefer direct H.264 Part for CAVLC host recon; still weakAlways for
            // non-H.264. STREAM=0: always weak universal (dual-A9 cast path).
            return misterplex::resolvePlayTarget(req.key, base, token, off, /*weakAlways=*/true,
                                                 weak, /*preferDirectH264=*/streamEnabled);
        };

        auto resolved = tryBase(selected);
        if (resolved.ok)
            return {resolved, selected};

        // Multi-server fallback only when cast did not pin an address.
        if (!req.address.empty())
            return {resolved, selected};

        for (const auto& s : servers) {
            if (s == selected)
                continue;
            auto r = tryBase(s);
            if (r.ok) {
                std::fprintf(stderr, "misterplexd: resolve ok via fallback server %s\n", s.c_str());
                return {r, s};
            }
        }
        return {resolved, selected};
    };

    auto doPlay = [&](const misterplex::PlayRequest& req) {
        const uint64_t gen = ++playGen;
        int64_t off = req.offsetMs;
        auto [resolved, base] = resolveAgainstServers(req, defaultPms, off);

        if (gen != playGen.load()) {
            std::fprintf(stderr, "misterplexd: PLAY superseded during resolve key=%s\n",
                         req.key.c_str());
            return;
        }

        if (!resolved.ok) {
            std::fprintf(stderr, "misterplexd: resolve failed: %s — test pattern\n",
                         resolved.detail.c_str());
            resolved.playable = "testsrc";
            resolved.ok = true;
            resolved.durationMs = 120000;
            resolved.sourceFpsHint = 30; // testsrc default
        } else {
            std::fprintf(stderr, "misterplexd: resolved %s title=%s dur=%lld transcode=%d base=%s\n",
                         resolved.detail.c_str(), resolved.title.c_str(),
                         static_cast<long long>(resolved.durationMs),
                         resolved.transcoded ? 1 : 0, base.c_str());
        }

        // Wire SOURCE_FPS / MATCH_SOURCE_HZ into play path (software Content FPS hint).
        {
            const int effective =
                misterplex::applySourceFpsConf(sourceFpsConf, resolved.sourceFpsHint);
            if (effective > 0) {
                std::fprintf(stderr,
                             "misterplexd: Content FPS hint=%d (SOURCE_FPS=%s pms_vfr=%s "
                             "frameRate=%s resolved=%d) — set OSD Content FPS or wait for "
                             "switchres\n",
                             effective, sourceFpsConf.c_str(),
                             resolved.videoFrameRate.empty() ? "-" : resolved.videoFrameRate.c_str(),
                             resolved.frameRate.empty() ? "-" : resolved.frameRate.c_str(),
                             resolved.sourceFpsHint);
            } else {
                std::fprintf(stderr,
                             "misterplexd: Content FPS hint unknown (SOURCE_FPS=%s)\n",
                             sourceFpsConf.c_str());
            }
            if (confTruthy(matchSourceHz) || matchSourceHz == "on" || matchSourceHz == "1") {
                std::fprintf(stderr,
                             "misterplexd: match-source-Hz ON target≈%dHz — switchres not "
                             "wired (cadence path active; see docs/match-source-hz.md)\n",
                             effective > 0 ? effective : 0);
            }
        }

        if (!req.offsetPresent && resolved.viewOffsetMs > 0)
            off = resolved.viewOffsetMs;

        misterplex::PlayRequest bound = req;
        if (bound.ratingKey.empty())
            bound.ratingKey = resolved.ratingKey;
        if (bound.address.empty() && !base.empty()) {
            auto hostport = base;
            auto p = hostport.find("://");
            if (p != std::string::npos)
                hostport = hostport.substr(p + 3);
            auto slash = hostport.find('/');
            if (slash != std::string::npos)
                hostport = hostport.substr(0, slash);
            auto colon = hostport.rfind(':');
            if (colon != std::string::npos) {
                bound.address = hostport.substr(0, colon);
                bound.port = hostport.substr(colon + 1);
            } else {
                bound.address = hostport;
                bound.port = "32400";
            }
            if (base.rfind("https", 0) == 0)
                bound.protocol = "https";
            else
                bound.protocol = "http";
        }
        if (bound.serverMachineId.empty())
            bound.serverMachineId = "plex-server";

        if (gen != playGen.load() || !comp.wantPlay()) {
            std::fprintf(stderr, "misterplexd: PLAY superseded before bind key=%s\n",
                         bound.key.c_str());
            return;
        }

        if (!comp.bindMedia(bound, resolved.durationMs)) {
            // Stop won the race against async playMedia resolve — do not restart player.
            // Do not write lastPlay here: stop may have cleared it; a failed bind must
            // not resurrect the prior/new queue for a post-stop skipNext race.
            std::fprintf(stderr, "misterplexd: PLAY aborted (stopped during resolve) key=%s\n",
                         bound.key.c_str());
            return;
        }

        // Honor scrubber seeks/steps that landed while resolve was in flight.
        // playMedia seeded timeMs_=req.offsetMs; if the user moved the timeline,
        // start there instead of rewinding to the original cast offset.
        int64_t startAt = off;
        const int64_t scrubT = comp.timelineTimeMs();
        if (scrubT != req.offsetMs)
            startAt = scrubT;
        if (startAt < 0)
            startAt = 0;
        if (resolved.durationMs > 0 && startAt > resolved.durationMs)
            startAt = resolved.durationMs;

        // Stop / newer playMedia may still race after bindMedia: re-check before
        // setState/player.play so we never restart demux on a stopped session.
        if (gen != playGen.load() || !comp.wantPlay()) {
            std::fprintf(stderr, "misterplexd: PLAY aborted after bind key=%s\n",
                         bound.key.c_str());
            return;
        }

        // Ensure timeline immediately reports duration + time for scrubber (seekRange).
        comp.setState("buffering", startAt, resolved.durationMs);

        if (gen != playGen.load() || !comp.wantPlay()) {
            std::fprintf(stderr, "misterplexd: PLAY superseded before player.play key=%s\n",
                         bound.key.c_str());
            return;
        }

        // Commit session context only when we are about to start demux. Writing
        // lastPlay earlier can resurrect a queue bind if stop cleared it mid-flight.
        // setPlay already planted a provisional lastPlay for skip-during-resolve.
        // Final wantPlay/playGen gate under the same critical section as lastPlay
        // so stop cannot clear then get a zombie lastPlay + player.play.
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            if (gen != playGen.load() || !comp.wantPlay()) {
                std::fprintf(stderr, "misterplexd: PLAY superseded before demux key=%s\n",
                             bound.key.c_str());
                return;
            }
            lastPlay = bound;
            lastBase = base;
            lastToken = bound.token.empty() ? confToken : bound.token;
        }

        std::fprintf(stderr, "misterplexd: PLAY %s off=%lld dur=%lld\n", resolved.playable.c_str(),
                     static_cast<long long>(startAt), static_cast<long long>(resolved.durationMs));
        player.play(resolved.playable, startAt, resolved.httpHeaders, resolved.durationMs);
    };

    // Shared play-queue step: delta=+1 (auto-next / skipNext), delta=-1 (skipPrevious).
    // Returns true when a new title was started via doPlay.
    auto tryQueueStep = [&](int delta, const char* tag) -> bool {
        if (delta == 0)
            return false;
        // autoNext conf gates natural-EOF advance only; explicit skipNext/Prev always try.
        misterplex::PlayRequest cur;
        std::string base, token;
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            cur = lastPlay;
            base = lastBase;
            token = lastToken;
        }
        std::string qref = cur.containerKey;
        if (qref.empty() && !cur.playQueueId.empty())
            qref = "/playQueues/" + cur.playQueueId;
        if (qref.empty() || qref.find("/playQueues/") == std::string::npos) {
            std::fprintf(stderr, "misterplexd: %s skip — no playQueue bound\n", tag);
            return false;
        }
        auto q = misterplex::fetchPlayQueue(qref, base, token, cur.key, cur.playQueueItemId);
        if (!q.ok) {
            std::fprintf(stderr, "misterplexd: %s queue fetch failed: %s\n", tag, q.detail.c_str());
            return false;
        }
        const int dest = q.currentIndex + delta;
        if (dest < 0 || dest >= static_cast<int>(q.items.size())) {
            std::fprintf(stderr, "misterplexd: %s — end of queue (index=%d size=%zu delta=%d)\n",
                         tag, q.currentIndex, q.items.size(), delta);
            return false;
        }
        const auto& item = q.items[static_cast<size_t>(dest)];
        misterplex::PlayRequest n = cur;
        n.key = item.key;
        n.ratingKey = item.ratingKey;
        n.playQueueItemId =
            !item.playQueueItemId.empty() ? item.playQueueItemId : item.ratingKey;
        n.playQueueId = !q.playQueueId.empty() ? q.playQueueId : cur.playQueueId;
        n.playQueueVersion =
            !q.playQueueVersion.empty() ? q.playQueueVersion : cur.playQueueVersion;
        n.containerKey = !q.containerKey.empty() ? q.containerKey + "?own=1" : cur.containerKey;
        n.offsetMs = 0;
        n.offsetPresent = true; // do not apply continue-watching on queue step
        n.token = token;
        std::fprintf(stderr, "misterplexd: %s → %s title=%s pqItem=%s\n", tag, n.key.c_str(),
                     item.title.c_str(), n.playQueueItemId.c_str());
        // Stage scrubber key before resolve so bindMedia key-match accepts this
        // item (and Web sees queue advance immediately).
        comp.stagePlay(n);
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            lastPlay = n;
            if (!token.empty())
                lastToken = token;
        }
        doPlay(n);
        return true;
    };

    // Next-episode stub: on natural EOF, if playQueue has a next item, play it.
    auto tryAutoNext = [&]() -> bool {
        if (!autoNext)
            return false;
        return tryQueueStep(+1, "auto-next");
    };

    player.setProgress([&](const std::string& st, int64_t t, int64_t d) {
        if (st == "ended") {
            // Must not call player.play() on the media thread (join self). Schedule async.
            if (autoNextInFlight.exchange(true)) {
                comp.setState("stopped", t, d);
                return;
            }
            // Keep scrubber alive while we decide; queue fetch is network-bound.
            comp.setState("buffering", t, d);
            std::thread([&, t, d]() {
                bool advanced = false;
                try {
                    advanced = tryAutoNext();
                } catch (...) {
                    std::fprintf(stderr, "misterplexd: auto-next exception\n");
                }
                autoNextInFlight.store(false);
                if (!advanced)
                    comp.setState("stopped", t, d);
            }).detach();
            return;
        }
        comp.setState(st, t, d);
    });

    // playMedia HTTP thread: bump playGen immediately so in-flight doPlay aborts
    // before the new onPlay_ thread even schedules (cast A→B race).
    comp.setPlayQueued([&]() { ++playGen; });

    // Plant lastPlay immediately so skipNext/skipPrevious during async resolve use the
    // new cast's queue bind — not the previous title's lastPlay (P4-SCRUB race).
    comp.setPlay([&](const misterplex::PlayRequest& req) {
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            lastPlay = req;
            if (!req.token.empty())
                lastToken = req.token;
            // Prefer cast address as provisional base when present.
            if (!req.address.empty()) {
                const std::string proto = req.protocol.empty() ? "http" : req.protocol;
                const std::string port = req.port.empty() ? "32400" : req.port;
                lastBase = proto + "://" + req.address + ":" + port;
            }
        }
        doPlay(req);
    });

    comp.setPause([&]() { player.pause(); });
    comp.setResume([&]() { player.resume(); });
    comp.setStop([&]() {
        // Invalidate in-flight doPlay (resolve/bind/player.play) so a late
        // playMedia cannot restart demux after stop. clearMedia already cleared
        // wantPlay_; bindMedia and wantPlay re-checks will also abort.
        ++playGen;
        player.stop();
        // Drop session bind so a post-stop skip cannot fetch the old play-queue.
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            lastPlay = misterplex::PlayRequest{};
            lastBase.clear();
        }
    });
    // Async seek: demux restart joins the media thread — never block companion HTTP
    // (Web scrubber thumb / step / skipPrevious restart@0 would otherwise stall ACKs).
    // seekGen drops superseded seeks that queue behind a slow restart.
    std::atomic<uint64_t> seekGen{0};
    auto seekAsync = [&](int64_t ms) {
        const uint64_t g = ++seekGen;
        std::thread([&, ms, g]() {
            if (g != seekGen.load())
                return; // superseded before start
            try {
                player.seekMs(ms);
            } catch (...) {
                std::fprintf(stderr, "misterplexd: seek exception\n");
            }
        }).detach();
    };
    comp.setSeek(seekAsync);
    // Scrubber step ±10s (Web / remote stepForward/stepBack).
    // Companion prefers onSeek_(clamped absolute); this remains a fallback path.
    comp.setStep([&](int64_t deltaMs) {
        int64_t cur = player.positionMs();
        int64_t dur = player.durationMs();
        int64_t target = cur + deltaMs;
        if (target < 0)
            target = 0;
        if (dur > 0 && target > dur)
            target = dur;
        if (target == cur)
            return; // already at boundary
        seekAsync(target);
    });
    // skipNext → play-queue advance (always tries; independent of AUTO_NEXT conf).
    // Empty / unbound queue = no-op log.
    comp.setSkipNext([&]() {
        if (autoNextInFlight.exchange(true))
            return;
        std::thread([&]() {
            try {
                if (!tryQueueStep(+1, "skipNext"))
                    std::fprintf(stderr, "misterplexd: skipNext — no next item\n");
            } catch (...) {
                std::fprintf(stderr, "misterplexd: skipNext exception\n");
            }
            autoNextInFlight.store(false);
        }).detach();
    });
    // skipPrevious — Plex-style:
    //   t > 3s  → restart current title @ 0
    //   t ≤ 3s  → previous playQueue item when bound; else restart @ 0 (if t>0) or no-op
    // Companion fires this *before* optimistic time=0 plant so timelineTimeMs() is real.
    comp.setSkipPrevious([&]() {
        const int64_t t = comp.timelineTimeMs();
        constexpr int64_t kRestartThresholdMs = 3000;
        if (t > kRestartThresholdMs) {
            std::fprintf(stderr, "misterplexd: skipPrevious restart@0 (t=%lld)\n",
                         static_cast<long long>(t));
            seekAsync(0);
            return;
        }
        // Near start: try queue previous (network). Guard concurrent skip/auto-next.
        if (autoNextInFlight.exchange(true))
            return;
        std::thread([&, t]() {
            try {
                if (!tryQueueStep(-1, "skipPrevious")) {
                    if (t > 0) {
                        std::fprintf(stderr,
                                     "misterplexd: skipPrevious no prev — restart@0 (t=%lld)\n",
                                     static_cast<long long>(t));
                        seekAsync(0);
                    } else {
                        std::fprintf(stderr,
                                     "misterplexd: skipPrevious — no previous item (at 0)\n");
                    }
                }
            } catch (...) {
                std::fprintf(stderr, "misterplexd: skipPrevious exception\n");
            }
            autoNextInFlight.store(false);
        }).detach();
    });

    if (!comp.start()) {
        std::fprintf(stderr, "misterplexd: companion start failed\n");
        return 1;
    }

    std::fprintf(stderr,
                 "misterplexd: running name=%s id=%s port=%d pms=%s servers=%zu decode=%dx%d "
                 "weak=%s@%dk present=%s auto_next=%d subs=%s\n",
                 name.c_str(), machineId.c_str(), port, defaultPms.c_str(), servers.size(),
                 decodeW, decodeH, weak.videoResolution.c_str(), weak.maxVideoBitrateKbps,
                 presentMode.c_str(), autoNext ? 1 : 0, subtitleMode.c_str());
    for (size_t i = 0; i < servers.size(); ++i)
        std::fprintf(stderr, "misterplexd:   server[%zu]=%s%s\n", i, servers[i].c_str(),
                     i == 0 ? " (default)" : "");

    while (!g_stop.load())
        std::this_thread::sleep_for(std::chrono::milliseconds(200));

    player.stop();
    comp.stop();
    return 0;
}
