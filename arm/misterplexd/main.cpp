// misterplexd — ARM-side daemon for MiSTerPlex.
// Phase 2: GDM + companion + FFmpeg → /dev/fb0 (FPGA scanout via MiSTer_fb).

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
#include <string>
#include <thread>

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
        if (line.rfind(p, 0) == 0)
            return line.substr(p.size());
    }
    return {};
}

} // namespace

int main(int argc, char** argv) {
    std::string name = "MiSTerPlex";
    std::string machineId = "misterplex-1";
    int port = 3005;
    std::string ffmpeg = "/media/fat/mistercast/bin/ffmpeg";
    std::string defaultPms = "http://192.168.1.41:32400";
    std::string confPath = "/media/fat/misterplex/misterplex.conf";
    std::string confToken;
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
        else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("misterplexd [--name N] [--id ID] [--port N] [--ffmpeg PATH] [--pms URL] "
                        "[--conf PATH]\n");
            return 0;
        }
    }
    {
        auto v = loadConf(confPath, "PLEX_BASE");
        if (!v.empty())
            defaultPms = v;
        v = loadConf(confPath, "PLEX_HOST");
        if (!v.empty())
            defaultPms = "http://" + v + ":32400";
        confToken = loadConf(confPath, "PLEX_TOKEN");
        v = loadConf(confPath, "FFMPEG");
        if (!v.empty())
            ffmpeg = v;
    }

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    // Avoid zombies from detached play threads' children if any leak
    std::signal(SIGCHLD, SIG_DFL);

    misterplex::MediaPlayer player;
    player.setFfmpegPath(ffmpeg);
    player.setLog([](const std::string& s) { std::fprintf(stderr, "%s\n", s.c_str()); });
    if (!player.initPresent()) {
        std::fprintf(stderr, "misterplexd: WARNING fb present unavailable — companion only\n");
    }

    misterplex::Companion comp;
    comp.setName(name);
    comp.setMachineId(machineId);
    comp.setPort(static_cast<uint16_t>(port));
    comp.setLog([](const std::string& s) { std::fprintf(stderr, "%s\n", s.c_str()); });

    player.setProgress([&](const std::string& st, int64_t t, int64_t d) {
        comp.setState(st, t, d);
    });

    comp.setPlay([&](const misterplex::PlayRequest& req) {
        std::string base =
            misterplex::buildPlexBase(req.protocol, req.address, req.port, defaultPms);
        if (base.empty())
            base = defaultPms;

        int64_t off = req.offsetMs;
        std::string token = req.token.empty() ? confToken : req.token;
        auto resolved =
            misterplex::resolvePlayTarget(req.key, base, token, off, /*weakAlways=*/true);

        if (!resolved.ok) {
            std::fprintf(stderr, "misterplexd: resolve failed: %s — test pattern\n",
                         resolved.detail.c_str());
            resolved.playable = "testsrc";
            resolved.ok = true;
            resolved.durationMs = 120000;
        } else {
            std::fprintf(stderr, "misterplexd: resolved %s title=%s dur=%lld transcode=%d\n",
                         resolved.detail.c_str(), resolved.title.c_str(),
                         static_cast<long long>(resolved.durationMs),
                         resolved.transcoded ? 1 : 0);
        }

        // Continue-watching: only when cast omitted offset
        if (!req.offsetPresent && resolved.viewOffsetMs > 0)
            off = resolved.viewOffsetMs;

        misterplex::PlayRequest bound = req;
        if (bound.ratingKey.empty())
            bound.ratingKey = resolved.ratingKey;
        // Ensure address fields for timeline scrubber
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

        comp.bindMedia(bound, resolved.durationMs);

        std::fprintf(stderr, "misterplexd: PLAY %s off=%lld\n", resolved.playable.c_str(),
                     static_cast<long long>(off));
        player.play(resolved.playable, off, resolved.httpHeaders, resolved.durationMs);
    });

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

    std::fprintf(stderr, "misterplexd: running name=%s id=%s port=%d pms=%s\n", name.c_str(),
                 machineId.c_str(), port, defaultPms.c_str());

    while (!g_stop.load())
        std::this_thread::sleep_for(std::chrono::milliseconds(200));

    player.stop();
    comp.stop();
    return 0;
}
