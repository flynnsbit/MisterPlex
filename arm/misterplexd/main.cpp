// misterplexd — ARM-side daemon for MiSTerPlex.
// Phase 2 bootstrap: GDM + companion HTTP. Present path is Plex.rbf (FPGA).
// Phase 3+: demux + feed elementary stream into FPGA.

#include "companion.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

namespace {

std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop.store(true); }

} // namespace

int main(int argc, char** argv) {
    std::string name = "MiSTerPlex";
    std::string machineId = "misterplex-1";
    int port = 3005;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--name") == 0 && i + 1 < argc)
            name = argv[++i];
        else if (std::strcmp(argv[i], "--id") == 0 && i + 1 < argc)
            machineId = argv[++i];
        else if (std::strcmp(argv[i], "--port") == 0 && i + 1 < argc)
            port = std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("misterplexd [--name NAME] [--id MACHINE_ID] [--port N]\n");
            return 0;
        }
    }

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    misterplex::Companion comp;
    comp.setName(name);
    comp.setMachineId(machineId);
    comp.setPort(static_cast<uint16_t>(port));
    comp.setLog([](const std::string& s) { std::fprintf(stderr, "%s\n", s.c_str()); });
    comp.setPlay([&](const std::string& key, int64_t off) {
        std::fprintf(stderr, "misterplexd: PLAY key=%s offsetMs=%lld (FPGA present path TBD Phase 2 feed)\n",
                     key.c_str(), static_cast<long long>(off));
        // Simulate timeline advance so scrubber/tests see motion
        comp.setState("playing", off, 600000);
    });

    if (!comp.start()) {
        std::fprintf(stderr, "misterplexd: companion start failed\n");
        return 1;
    }

    std::fprintf(stderr, "misterplexd: running name=%s id=%s port=%d\n", name.c_str(), machineId.c_str(),
                 port);

    // Fake timeline clock while "playing" so polls advance (until real decoder)
    int64_t tick = 0;
    while (!g_stop.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        tick += 250;
        // Only advances if play handler set playing — harmless when stopped
        (void)tick;
    }

    comp.stop();
    return 0;
}
