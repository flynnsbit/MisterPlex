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
    bool autoNext = true;
    std::string subtitleMode = "off"; // off | burn | ffmpeg
    int subtitleStreamId = -1;
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
        // Phase 4: match-source-Hz reserved (see docs/match-source-hz.md).
        v = loadConf(confPath, "MATCH_SOURCE_HZ");
        if (!v.empty())
            std::fprintf(stderr,
                         "misterplexd: MATCH_SOURCE_HZ=%s noted (cadence-only until switchres)\n",
                         v.c_str());
        v = loadConf(confPath, "SOURCE_FPS");
        if (!v.empty())
            std::fprintf(stderr, "misterplexd: SOURCE_FPS=%s noted (OSD Content FPS is authoritative)\n",
                         v.c_str());
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
    if (subtitleMode == "ffmpeg")
        player.setSubtitleMode("ffmpeg");
    if (subtitleStreamId >= 0)
        player.setSubtitleStreamIndex(subtitleStreamId);
    player.setLog([](const std::string& s) { std::fprintf(stderr, "%s\n", s.c_str()); });
    if (streamEnabled)
        std::fprintf(stderr, "misterplexd: STREAM=1 (annex-B → host I-recon F1 + F3)\n");
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
            return misterplex::resolvePlayTarget(req.key, base, token, off, /*weakAlways=*/true,
                                                 weak);
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
        int64_t off = req.offsetMs;
        auto [resolved, base] = resolveAgainstServers(req, defaultPms, off);

        if (!resolved.ok) {
            std::fprintf(stderr, "misterplexd: resolve failed: %s — test pattern\n",
                         resolved.detail.c_str());
            resolved.playable = "testsrc";
            resolved.ok = true;
            resolved.durationMs = 120000;
        } else {
            std::fprintf(stderr, "misterplexd: resolved %s title=%s dur=%lld transcode=%d base=%s\n",
                         resolved.detail.c_str(), resolved.title.c_str(),
                         static_cast<long long>(resolved.durationMs),
                         resolved.transcoded ? 1 : 0, base.c_str());
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

        {
            std::lock_guard<std::mutex> lock(sessionMu);
            lastPlay = bound;
            lastBase = base;
            lastToken = bound.token.empty() ? confToken : bound.token;
        }

        comp.bindMedia(bound, resolved.durationMs);

        std::fprintf(stderr, "misterplexd: PLAY %s off=%lld\n", resolved.playable.c_str(),
                     static_cast<long long>(off));
        player.play(resolved.playable, off, resolved.httpHeaders, resolved.durationMs);
    };

    // Next-episode stub: on natural EOF, if playQueue has a next item, play it.
    auto tryAutoNext = [&]() -> bool {
        if (!autoNext)
            return false;
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
            std::fprintf(stderr, "misterplexd: auto-next skip — no playQueue bound\n");
            return false;
        }
        auto q = misterplex::fetchPlayQueue(qref, base, token, cur.key, cur.playQueueItemId);
        if (!q.ok) {
            std::fprintf(stderr, "misterplexd: auto-next queue fetch failed: %s\n",
                         q.detail.c_str());
            return false;
        }
        const int next = q.currentIndex + 1;
        if (next < 0 || next >= static_cast<int>(q.items.size())) {
            std::fprintf(stderr, "misterplexd: auto-next — end of queue (index=%d size=%zu)\n",
                         q.currentIndex, q.items.size());
            return false;
        }
        const auto& item = q.items[static_cast<size_t>(next)];
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
        n.offsetPresent = true; // do not apply continue-watching on auto-next
        n.token = token;
        std::fprintf(stderr, "misterplexd: auto-next → %s title=%s pqItem=%s\n", n.key.c_str(),
                     item.title.c_str(), n.playQueueItemId.c_str());
        doPlay(n);
        return true;
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

    comp.setPlay([&](const misterplex::PlayRequest& req) { doPlay(req); });

    comp.setPause([&]() { player.pause(); });
    comp.setResume([&]() { player.resume(); });
    comp.setStop([&]() {
        player.stop();
        // clearMedia already called by companion stop path after onStop
    });
    comp.setSeek([&](int64_t ms) { player.seekMs(ms); });

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
