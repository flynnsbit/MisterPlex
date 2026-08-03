// Host probe: drive buildUniversalTranscodeUrl + plexFfmpegHeaders exactly as daemon.
// Does not print token. Usage:
//   pms_720_daemon_path_probe BASE KEY OUT_PREFIX CONF [maxBR] [vres]
#include "plex_resolve.hpp"
#include "libmisterplex/osd_menu.hpp"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>

static std::string loadConf(const std::string& path, const char* key) {
    std::ifstream in(path);
    std::string line;
    const std::string prefix = std::string(key) + "=";
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        if (line.rfind(prefix, 0) == 0)
            return line.substr(prefix.size());
    }
    return {};
}

int main(int argc, char** argv) {
    if (argc < 5) {
        std::fprintf(stderr, "usage: %s BASE KEY OUT_PREFIX CONF [maxBR] [vres]\n", argv[0]);
        return 2;
    }
    const std::string base = argv[1];
    const std::string key = argv[2];
    const std::string outp = argv[3];
    const std::string conf = argv[4];
    const int maxBr = (argc >= 6) ? std::atoi(argv[5]) : misterplex::kPlex720pWeakBitrateKbps;
    const std::string vres = (argc >= 7) ? argv[6] : std::string("1280x720");
    const std::string token = loadConf(conf, "PLEX_TOKEN");
    if (token.empty()) {
        std::fprintf(stderr, "FAIL: no PLEX_TOKEN in conf\n");
        return 2;
    }

    misterplex::WeakLadder weak;
    // Match plexTranscodeProfiles()["720p"] product defaults unless overridden.
    weak.videoResolution = vres;
    weak.maxVideoBitrateKbps = maxBr;
    weak.videoQuality = 70;
    weak.h264Profile = "baseline";
    weak.h264Level = misterplex::kPlex720pH264Level;
    weak.clientProfileName = "MiSTerPlex";
    weak.videoCodec = "h264";
    weak.audioCodec = "aac";

    const std::string session = "w-path-daemon-720p";
    const std::string url =
        misterplex::buildUniversalTranscodeUrl(base, key, token, session, 0, weak);
    const std::string hdrs = misterplex::plexFfmpegHeaders(session, token, weak);

    std::string url_scrub = url;
    const std::string tokq = "X-Plex-Token=" + token;
    auto p = url_scrub.find(tokq);
    if (p != std::string::npos)
        url_scrub.replace(p, tokq.size(), "X-Plex-Token=<redacted>");

    {
        std::ofstream o(outp + "_url_scrubbed.txt");
        o << url_scrub << "\n";
        o << "videoResolution=" << weak.videoResolution << "\n";
        o << "maxVideoBitrate=" << weak.maxVideoBitrateKbps << "\n";
        o << "videoQuality=" << weak.videoQuality << "\n";
        o << "videoLevel=" << weak.h264Level << "\n";
        o << "videoProfile=" << weak.h264Profile << "\n";
        o << "clientProfile=" << weak.clientProfileName << "\n";
    }
    {
        std::ofstream o(outp + "_curl.secret.cfg");
        o << "silent\nshow-error\ngloboff\ninsecure\nlocation\nhttp1.1\n";
        o << "connect-timeout = 8\nmax-time = 30\n";
        o << "write-out = \"http_code=%{http_code} size_download=%{size_download}\\n\"\n";
        o << "header = \"Accept: */*\"\n";
        std::string h = hdrs;
        size_t i = 0;
        while (i < h.size()) {
            auto e = h.find("\r\n", i);
            if (e == std::string::npos) e = h.size();
            std::string line = h.substr(i, e - i);
            if (!line.empty())
                o << "header = \"" << line << "\"\n";
            i = (e == h.size()) ? e : e + 2;
        }
        o << "url = \"" << url << "\"\n";
        o << "output = \"" << outp << "_body.bin\"\n";
    }
    // Decision URL (same path, decision endpoint) for coded size without full stream
    {
        std::string dec = url;
        auto pos = dec.find("/start.mp4");
        if (pos != std::string::npos)
            dec.replace(pos, std::string("/start.mp4").size(), "/decision");
        std::ofstream o(outp + "_decision.secret.cfg");
        o << "silent\nshow-error\ngloboff\ninsecure\nlocation\nhttp1.1\n";
        o << "connect-timeout = 8\nmax-time = 15\n";
        o << "write-out = \"http_code=%{http_code} size_download=%{size_download}\\n\"\n";
        o << "header = \"Accept: application/xml\"\n";
        std::string h = hdrs;
        size_t i = 0;
        while (i < h.size()) {
            auto e = h.find("\r\n", i);
            if (e == std::string::npos) e = h.size();
            std::string line = h.substr(i, e - i);
            if (!line.empty())
                o << "header = \"" << line << "\"\n";
            i = (e == h.size()) ? e : e + 2;
        }
        o << "url = \"" << dec << "\"\n";
        o << "output = \"" << outp << "_decision.xml\"\n";
    }
    std::fprintf(stderr, "OK probe cfg token_len=%zu maxBR=%d vres=%s\n", token.size(), maxBr,
                 vres.c_str());
    return 0;
}
