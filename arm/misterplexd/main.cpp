// misterplexd — ARM-side daemon for MiSTerPlex.
// Phase 2: GDM + companion + FFmpeg → /dev/fb0 (FPGA scanout via MiSTer_fb).
// Phase 4: multi-server conf, auto next-episode, optional subtitle burn-in.

#include "companion.hpp"
#include "death_breadcrumb.hpp"
#include "libmisterplex/coded_size.hpp"
#include "libmisterplex/conf_keys.hpp"
#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/frame_ledger.hpp"
#include "libmisterplex/osd_menu.hpp"
#include "libmisterplex/pms_delivery_geom.hpp"
#include "libmisterplex/raw_video_pipe.hpp"
#include "libmisterplex/yuv420p_chroma_health.hpp"
#include "log_redact.hpp"
#include "media_player.hpp"
#include "plextv_device.hpp"
#include "pms_timeline.hpp"
#include "plex_resolve.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <signal.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <pthread.h>
#include <thread>
#include <vector>

namespace {

// Build identity, stamped by the Makefile into a generated header
// (build/generated/misterplex_build_id.h). A deployed daemon was previously
// identifiable only by its binary md5, which git cannot resolve to a commit, so
// nobody could say what source the daily driver was running. Printed by
// --version and in the startup banner.
//
// A generated header, not a bare -D: a -D does not participate in dependency
// tracking, so the binary would silently keep a stale revision across a rebuild.
// "unknown" is the honest answer for a build with no stamp; it must never claim
// a revision it does not have.
#if !defined(MISTERPLEX_GIT_REV) && defined(__has_include)
#  if __has_include("misterplex_build_id.h")
#    include "misterplex_build_id.h"
#  endif
#endif
#ifndef MISTERPLEX_GIT_REV
#define MISTERPLEX_GIT_REV "unknown"
#endif
constexpr const char* kMisterplexGitRev = MISTERPLEX_GIT_REV;

// Product main loop exits ONLY when g_stop is set. The only writers are the
// SIGINT/SIGTERM handlers below (lab --help / --play-file return earlier).
// Handled signals yield process exit status 0 (WIFEXITED), NOT WIFSIGNALED —
// that is why a "clean rc=0" can still be an external SIGTERM. Capture si_*.
std::atomic<bool> g_stop{false};
std::atomic<int> g_stopSig{0};
std::atomic<int> g_stopSiCode{0};
std::atomic<int> g_stopSiPid{0};

void on_signal_info(int sig, siginfo_t* info, void*) {
    g_stopSig.store(sig, std::memory_order_relaxed);
    if (info) {
        g_stopSiCode.store(info->si_code, std::memory_order_relaxed);
        g_stopSiPid.store(static_cast<int>(info->si_pid), std::memory_order_relaxed);
    }
    // Async-signal-safe first witness (write(2) only). Survives if teardown never
    // reaches exitReported (hang in stop/join). Orderly EXIT_REASON overwrites later.
    // SIGKILL cannot run this — supervisor SUPERVISE_EXIT is the only SIGKILL witness.
    if (info)
        misterplex::deathBreadcrumbOnSigInfo(info);
    else
        misterplex::deathBreadcrumbOnSignal(sig);
    g_stop.store(true, std::memory_order_release);
}

// conf dirname for breadcrumb + frame ledger files beside misterplex.conf.
std::string confDirFromPath(const std::string& confPath) {
    std::string confDir = confPath;
    const auto slash = confDir.find_last_of('/');
    if (slash == std::string::npos)
        return ".";
    if (slash == 0)
        return "/";
    confDir.resize(slash);
    return confDir;
}

// Single choke point for every normal termination. Logs reason + site + uptime
// via deathBreadcrumbExit (stderr + misterplexd.death) and frame ledger exit row.
// Call AFTER teardown (player.stop / companion.stop). Returns `code` for main.
int exitReported(int code, const char* siteWhy, misterplex::MediaPlayer* player = nullptr,
                 int64_t uptimeS = -1) {
    int64_t lf = 0, lp = 0, ld = 0, pos = 0;
    if (player) {
        lf = player->lifetimeFrames();
        lp = player->lifetimePresents();
        ld = player->lifetimeDrops();
        pos = player->positionMs();
        misterplex::deathBreadcrumbUpdate(misterplex::DeathState::Stopping, lf, lp, pos,
                                          /*force=*/true);
    }
    // Default was 0 and silently starved frame_ledger process_exit of uptime.
    // Prefer explicit arg; else steady clock since deathBreadcrumbInit.
    if (uptimeS < 0)
        uptimeS = misterplex::deathBreadcrumbUptimeS();
    misterplex::frameLedgerProcessExit(code, siteWhy, lf, lp, ld, uptimeS);
    misterplex::deathBreadcrumbExit(code, siteWhy);
    return code;
}

class FpgaWorkerHandoff {
public:
    explicit FpgaWorkerHandoff(misterplex::MediaPlayer& player) : player_(player) {
        player_.suspendFpgaWorkers();
    }
    ~FpgaWorkerHandoff() {
        if (!completed_)
            player_.resumeFpgaWorkers(true);
    }
    FpgaWorkerHandoff(const FpgaWorkerHandoff&) = delete;
    FpgaWorkerHandoff& operator=(const FpgaWorkerHandoff&) = delete;

    void completePlayback() {
        player_.resumeFpgaWorkers(false);
        completed_ = true;
    }

private:
    misterplex::MediaPlayer& player_;
    bool completed_ = false;
};

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
            return misterplex::trimConfValue(line.substr(p.size()));
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
            out.push_back(misterplex::trimConfValue(line.substr(p.size())));
    }
    return out;
}

// Upsert KEY=value in conf (preserves comments/other keys). Used so F12 OSD
// content/display choices persist into conf the user can inspect.
bool upsertConfKey(const std::string& path, const char* key, const std::string& value) {
    if (path.empty() || !key || !*key)
        return false;
    std::ifstream in(path);
    std::vector<std::string> lines;
    std::string line;
    bool found = false;
    const std::string p = std::string(key) + "=";
    if (in) {
        while (std::getline(in, line)) {
            if (!found && line.rfind(p, 0) == 0) {
                lines.push_back(p + value);
                found = true;
            } else {
                lines.push_back(line);
            }
        }
    }
    if (!found)
        lines.push_back(p + value);
    const std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::trunc);
        if (!out)
            return false;
        for (const auto& l : lines)
            out << l << '\n';
    }
    return ::rename(tmp.c_str(), path.c_str()) == 0;
}

bool confTruthy(const std::string& v) { return misterplex::confTruthy(v); }

// All main-thread diagnostic lines go through here so a forgotten URL/token
// cannot land in misterplexd.log in cleartext.
void logDaemon(const std::string& s) {
    std::fprintf(stderr, "%s\n", misterplex::redactSensitive(s).c_str());
}

int dimensionValue(int value) { return value; }

template <typename T>
auto dimensionValue(const T& value) -> decltype(value.get()) {
    return value.get();
}

// Content tier (OSD O[4] / DECODE) is the product source of truth for the PMS
// ladder on each play. Re-apply the full named profile so profileName, quality,
// bitrate and H.264 caps track the tier — not only videoResolution.
misterplex::WeakLadder weakForContentResolution(const misterplex::WeakLadder& base,
                                                const misterplex::ContentResolution& res,
                                                bool bitrateExplicit,
                                                bool qualityExplicit,
                                                bool h264ProfileExplicit) {
    misterplex::WeakLadder weak = base;
    // Prefer named profile so level/bitrate stay consistent with tier.
    // applyPlexTranscodeProfile always rewrites maxVideoBitrateKbps / videoQuality /
    // h264Profile from the named ladder (e.g. 720p→main@20M@q100). Preserve operator
    // WEAK_BITRATE / WEAK_QUALITY / WEAK_H264_PROFILE when set so the light present-rate
    // ladder can stick (baseline is cheaper to decode on dual-A9).
    const int explicitBitrateKbps = base.maxVideoBitrateKbps;
    const int explicitQuality = base.videoQuality;
    const std::string explicitH264Profile = base.h264Profile;
    const int width = dimensionValue(res.width);
    const int height = dimensionValue(res.height);
    const std::string geomRes = std::to_string(width) + "x" + std::to_string(height);
    // Prefer named product label (240p/480p/720p), then WxH geometry.
    if (!misterplex::applyPlexTranscodeProfile(res.label, weak) &&
        !misterplex::applyPlexTranscodeProfile(geomRes, weak)) {
        weak.profileName = res.label;
        // PMS universal wants WxH in videoResolution=, never the short label alone.
        weak.videoResolution = geomRes;
        if (width >= 1280 || height >= 720) {
            weak.h264Level = 31;
            if (!qualityExplicit)
                weak.videoQuality = 95;
        }
    }
    if (bitrateExplicit)
        weak.maxVideoBitrateKbps = explicitBitrateKbps;
    else
        weak.maxVideoBitrateKbps = res.weakBitrateKbps;
    if (qualityExplicit && explicitQuality >= 1 && explicitQuality <= 100)
        weak.videoQuality = explicitQuality;
    if (h264ProfileExplicit && (explicitH264Profile == "baseline" || explicitH264Profile == "main"))
        weak.h264Profile = explicitH264Profile;
    weak.burnSubtitles = base.burnSubtitles;
    weak.subtitleStreamId = base.subtitleStreamId;
    weak.clientProfileName = base.clientProfileName;
    return weak;
}

} // namespace

namespace {

// MiSTerPlex ships its own static ffmpeg, but installs that predate that (or that
// share a box with mistercast-linux) keep it elsewhere. Probe our own bin first so
// a stock install is self-contained, then fall back rather than hard-failing.
std::string defaultFfmpegPath() {
    for (const char* c : {"/media/fat/misterplex/bin/ffmpeg", "/media/fat/mistercast/bin/ffmpeg"}) {
        if (::access(c, X_OK) == 0)
            return c;
    }
    return "/media/fat/misterplex/bin/ffmpeg";
}

} // namespace

int main(int argc, char** argv) {
#if defined(__linux__)
    pthread_setname_np(pthread_self(), "mpx-main");
#endif

    std::string name = "MiSTerPlex";
    std::string machineId = "misterplex-dev";
    int port = misterplex::kPlayerDefaultPort;
    std::string ffmpeg = defaultFfmpegPath();
    std::string confPath = "/media/fat/misterplex/misterplex.conf";
    std::string confToken;
    // plex.tv player registration: off by default (PLEXTV_ANNOUNCE=1 to enable).
    bool plexTvAnnounce = false;
    misterplex::CodedSize decodeSize = misterplex::kDefaultCodedDecodeSize;
    bool decodeAllowLab480p = false;
    std::string decodeSizeRawCli; // applied after conf so DECODE_ALLOW_LAB_480P is visible
    std::string decodeSizeSource = "default";
    // Product default: FPGA DDR frame store is what the Plex core scans to HDMI.
    // PRESENT=fb0 alone used to skip fpga_.open() and freeze the idle screen
    // (user-reported twice). Conf PRESENT= still overrides.
    std::string presentMode = "fpga";
    misterplex::DdrFrameFormat ddrFrameFormat = misterplex::DdrFrameFormat::Yuv420p;
    bool ddrMemSync = true;
    bool ddrMemFlush = false;
    bool presentProfile = false;
    bool streamEnabled = false;
    std::string streamSkipRgb = "auto"; // auto | on | off — skip heavy RGB when PRESENT=fpga
    // STREAM=0 -vf scale: skip_identity omits scale+pad when expected delivery
    // WxH is known and equals the coded bank (or ASSUME_MATCH). Unknown delivery
    // still scales. Shipping path with matching PMS videoResolution is a no-op
    // omit — do not ship a cosmetic sws default for a filter that is skipped.
    // YUV DDR force-scale is HARD default ON in code (silicon: only FORCE=1 fixed
    // native 480p colour+throughput). Conf DDR_YUV_FORCE_SCALE=0 alone is IGNORED
    // and LOUD-warned — correctness must not depend on a deletable conf key.
    // Lab-only escape: DDR_YUV_FORCE_SCALE_LAB=1 + DDR_YUV_FORCE_SCALE=0.
    std::string ffmpegScaleMode = "skip_identity";
    std::string ffmpegSwsFlags; // empty = ffmpeg default when residual scale runs
    bool ffmpegScaleAssumeMatch = false;
    bool ddrYuvForceScale = true; // product always ON unless LAB escape
    bool ddrYuvForceScaleLab = false;
    bool ddrYuvForceScaleConfOff = false;
    bool autoNext = true;
    std::string subtitleMode = "off"; // off | burn | ffmpeg
    int subtitleStreamId = -1;
    // Phase 4 match-source-Hz: conf reserved for switchres; Content FPS hint is software-only.
    std::string matchSourceHz = "off";
    std::string sourceFpsConf = "auto";
    misterplex::WeakLadder weak;
    std::string cliTranscodeProfile;
    bool transcodeProfileExplicit = false;
    bool weakResExplicit = false;
    bool weakBitrateExplicit = false;
    // When supply_class=STARVED is sustained, apply nextLowerLadderBitrate and
    // restart the same title (geometry unchanged). Default off — log-only is safe.
    bool autoLadderStepdown = false;
    // Optional measured path capacity (kbit/s). 0 = unset — never invent a link speed.
    // When set, maxVideoBitrate is clamped to capacity * headroom/100 before PMS URL.
    int linkCapacityKbps = 0;
    int linkCapacityHeadroomPct = misterplex::kLinkCapacityHeadroomPctDefault;
    bool weakQualityExplicit = false;
    bool weakH264ProfileExplicit = false;
    std::vector<std::string> servers;
    std::string defaultPms;
    int64_t skipForwardMs = 30000;
    int64_t skipBackMs = 10000;
    // Lab: --play-file PATH [--play-seconds N] plays a local file then exits (no GDM).
    std::string playFile;
    int playSeconds = 25;

    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--version") == 0) {
            std::printf("misterplexd git_rev=%s\n", kMisterplexGitRev);
            // Pre-init version query: no confDir yet — still choke-point log to stderr.
            misterplex::deathBreadcrumbExit(0, "site=main.cpp:--version");
            return 0;
        }
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
            // Defer typed adoption until after conf: allow flag may arrive via conf.
            decodeSizeRawCli = argv[++i];
        } else if (std::strcmp(argv[i], "--decode-allow-lab-480p") == 0) {
            decodeAllowLab480p = true;
        } else if (std::strcmp(argv[i], "--transcode-profile") == 0 && i + 1 < argc) {
            cliTranscodeProfile = argv[++i];
        } else if (std::strcmp(argv[i], "--play-file") == 0 && i + 1 < argc) {
            playFile = argv[++i];
        } else if (std::strcmp(argv[i], "--play-seconds") == 0 && i + 1 < argc) {
            playSeconds = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--help") == 0) {
            std::printf("misterplexd [--name N] [--id ID] [--port N] [--ffmpeg PATH] [--pms URL] "
                        "[--conf PATH] [--decode WxH] [--decode-allow-lab-480p] [--transcode-profile 240p|480p] "
                        "[--play-file PATH] [--play-seconds N] [--version]\n");
            // Pre-init help: no confDir yet — still choke-point log to stderr.
            misterplex::deathBreadcrumbExit(0, "site=main.cpp:--help");
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
        {
            auto ann = loadConf(confPath, "PLEXTV_ANNOUNCE");
            if (!ann.empty())
                plexTvAnnounce = confTruthy(ann);
        }
        auto profile = loadConf(confPath, "TRANSCODE_PROFILE");
        if (profile.empty())
            profile = loadConf(confPath, "WEAK_PROFILE");
        if (!profile.empty()) {
            transcodeProfileExplicit = true;
            if (!misterplex::applyPlexTranscodeProfile(profile, weak))
                std::fprintf(stderr, "misterplexd: unknown TRANSCODE_PROFILE=%s (keeping %s)\n",
                             profile.c_str(), weak.profileName.c_str());
        }
        auto v = loadConf(confPath, "FFMPEG");
        if (!v.empty())
            ffmpeg = v;
        v = loadConf(confPath, "DECODE_ALLOW_LAB_480P");
        if (!v.empty())
            decodeAllowLab480p = decodeAllowLab480p || confTruthy(v);
        v = loadConf(confPath, "DECODE");
        if (!v.empty()) {
            // Typed adoption only — bare sscanf into int is the hole that let a
            // stale DECODE=624x480 ship against a 320x240 core.
            const auto adopted = misterplex::adoptExternalCodedSize(v, decodeAllowLab480p);
            if (adopted.ok()) {
                decodeSize = adopted.size;
                decodeSizeSource = "conf:" + confPath;
                std::fprintf(stderr,
                             "misterplexd: DECODE adopted coded %s from conf %s\n",
                             decodeSize.wxh().c_str(), confPath.c_str());
            } else {
                std::fprintf(stderr,
                             "misterplexd: REJECTED DECODE=%s from conf (%s/%s) — keeping "
                             "coded %s\n",
                             v.c_str(), misterplex::codedSizeParseStatusName(adopted.status),
                             adopted.reason, decodeSize.wxh().c_str());
            }
        }
        // CLI --decode wins over conf when both are present, still typed+policy.
        if (!decodeSizeRawCli.empty()) {
            const auto adopted =
                misterplex::adoptExternalCodedSize(decodeSizeRawCli, decodeAllowLab480p);
            if (adopted.ok()) {
                decodeSize = adopted.size;
                decodeSizeSource = "cli:--decode";
                std::fprintf(stderr,
                             "misterplexd: DECODE adopted coded %s from --decode\n",
                             decodeSize.wxh().c_str());
            } else {
                std::fprintf(stderr,
                             "misterplexd: REJECTED --decode=%s (%s/%s) — keeping coded %s\n",
                             decodeSizeRawCli.c_str(),
                             misterplex::codedSizeParseStatusName(adopted.status),
                             adopted.reason, decodeSize.wxh().c_str());
            }
        }
        v = loadConf(confPath, "WEAK_RES");
        if (!v.empty()) {
            weakResExplicit = true;
            if (!misterplex::applyPlexTranscodeProfile(v, weak)) {
                weak.profileName = "custom";
                weak.videoResolution = v;
            }
        }
        v = loadConf(confPath, "WEAK_BITRATE");
        if (!v.empty()) {
            weakBitrateExplicit = true;
            weak.maxVideoBitrateKbps = std::atoi(v.c_str());
        }
        v = loadConf(confPath, "AUTO_LADDER_STEPDOWN");
        if (!v.empty())
            autoLadderStepdown = confTruthy(v);
        // Measured path capacity (parent greedy goodput). Unset = 0 = no clamp.
        v = loadConf(confPath, "LINK_CAPACITY_KBIT");
        if (!v.empty())
            linkCapacityKbps = std::max(0, std::atoi(v.c_str()));
        v = loadConf(confPath, "LINK_CAPACITY_HEADROOM_PCT");
        if (!v.empty()) {
            const int p = std::atoi(v.c_str());
            if (p > 0 && p <= 100)
                linkCapacityHeadroomPct = p;
        }
        v = loadConf(confPath, "WEAK_QUALITY");
        if (!v.empty()) {
            const int q = std::atoi(v.c_str());
            if (q >= 1 && q <= 100) {
                weak.videoQuality = q;
                weakQualityExplicit = true;
            }
        }
        // Lab present-rate ladder: WEAK_H264_PROFILE=baseline (cheaper dual-A9 decode).
        // Default 720p named profile is main (quality path); baseline may band more.
        v = loadConf(confPath, "WEAK_H264_PROFILE");
        if (v.empty())
            v = loadConf(confPath, "H264_PROFILE");
        if (!v.empty()) {
            if (v == "baseline" || v == "main") {
                weak.h264Profile = v;
                weakH264ProfileExplicit = true;
            } else {
                std::fprintf(stderr,
                             "misterplexd: WEAK_H264_PROFILE=%s ignored (use baseline|main)\n",
                             v.c_str());
            }
        }
        v = loadConf(confPath, "PRESENT");
        if (!v.empty())
            presentMode = v; // fb0 | fpga | both | none(test/lab)
        v = loadConf(confPath, "DDR_FRAME_FORMAT");
        if (!v.empty() && v != "yuv420p" && v != "yuv420" && v != "i420") {
            std::fprintf(stderr,
                         "misterplexd: DDR_FRAME_FORMAT=%s ignored; DDR frame store is "
                         "fixed to yuv420p\n",
                         v.c_str());
        }
        v = loadConf(confPath, "DDR_MEM_SYNC");
        if (!v.empty())
            ddrMemSync = confTruthy(v);
        v = loadConf(confPath, "DDR_MEM_FLUSH");
        if (!v.empty())
            ddrMemFlush = confTruthy(v);
        v = loadConf(confPath, "PRESENT_PROFILE");
        if (!v.empty())
            presentProfile = confTruthy(v);
        v = loadConf(confPath, "STREAM");
        if (!v.empty())
            streamEnabled = confTruthy(v);
        v = loadConf(confPath, "STREAM_SKIP_RGB");
        if (!v.empty())
            streamSkipRgb = v;
        // Scale policy: default skip_identity (omit only when expected delivery==coded).
        v = loadConf(confPath, "FFMPEG_SCALE");
        if (!v.empty())
            ffmpegScaleMode = v;
        // Optional residual-scale algo only. Empty product default (omit :flags=).
        v = loadConf(confPath, "FFMPEG_SWS_FLAGS");
        if (!v.empty())
            ffmpegSwsFlags = v;
        v = loadConf(confPath, "FFMPEG_SCALE_ASSUME_MATCH");
        if (!v.empty())
            ffmpegScaleAssumeMatch = confTruthy(v);
        // YUV DDR force-scale: product default ON. Conf=0 only honored with LAB flag.
        v = loadConf(confPath, "DDR_YUV_FORCE_SCALE_LAB");
        if (!v.empty())
            ddrYuvForceScaleLab = confTruthy(v);
        v = loadConf(confPath, "DDR_YUV_FORCE_SCALE");
        if (!v.empty()) {
            const bool want = confTruthy(v);
            if (!want) {
                ddrYuvForceScaleConfOff = true;
                if (ddrYuvForceScaleLab) {
                    ddrYuvForceScale = false;
                } else {
                    // Keep code default ON — conf-only Off is a silent desync footgun
                    // (library_media 624x480 vs measured 624x350 on live PMS).
                    ddrYuvForceScale = true;
                }
            } else {
                ddrYuvForceScale = true;
            }
        }
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
        v = loadConf(confPath, "SKIP_MS");
        if (!v.empty()) {
            const int ms = std::atoi(v.c_str());
            if (ms >= 0) {
                skipForwardMs = ms;
                skipBackMs = ms;
            }
        }
        v = loadConf(confPath, "SKIP_FORWARD_MS");
        if (!v.empty())
            skipForwardMs = std::max(0, std::atoi(v.c_str()));
        v = loadConf(confPath, "SKIP_BACK_MS");
        if (!v.empty())
            skipBackMs = std::max(0, std::atoi(v.c_str()));
        std::fprintf(stderr,
                     "misterplexd: MATCH_SOURCE_HZ=%s SOURCE_FPS=%s "
                     "(cadence/OSD path; switchres TODO)\n",
                     matchSourceHz.c_str(), sourceFpsConf.c_str());
    }
    if (!cliTranscodeProfile.empty()) {
        transcodeProfileExplicit = true;
        if (!misterplex::applyPlexTranscodeProfile(cliTranscodeProfile, weak))
            std::fprintf(stderr, "misterplexd: unknown --transcode-profile=%s (keeping %s)\n",
                         cliTranscodeProfile.c_str(), weak.profileName.c_str());
    }
    // Startup ladder vs DECODE bank.
    // TRANSCODE_PROFILE is a *named ladder entry* (bitrate/quality/H.264 caps +
    // a default videoResolution). It is NOT "delivered geometry by itself".
    // Each play already re-applies the full ladder from the content tier
    // (OSD O[4] or DECODE) via weakForContentResolution — that is what sets
    // videoResolution= on the PMS URL. Startup reconcile only keeps the idle
    // banner / pre-play weak state aligned with DECODE when conf disagrees.
    {
        const std::string decodeRes = decodeSize.wxh();
        const bool ladderMismatch = (weak.videoResolution != decodeRes);
        if (ladderMismatch && (transcodeProfileExplicit || weakResExplicit)) {
            std::fprintf(stderr,
                         "misterplexd: WARN DECODE_bank=%s disagrees with conf ladder "
                         "profile_name=%s conf_videoResolution=%s — startup reconcile to "
                         "DECODE (play path already uses content tier for PMS request)\n",
                         decodeRes.c_str(), weak.profileName.c_str(),
                         weak.videoResolution.c_str());
            if (!misterplex::applyPlexTranscodeProfile(decodeRes, weak)) {
                weak.profileName = "custom";
                weak.videoResolution = decodeRes;
                if (!weakBitrateExplicit) {
                    weak.maxVideoBitrateKbps = misterplex::weakBitrateKbpsForCodedSize(
                        decodeSize.width, decodeSize.height);
                }
            }
        } else if (!transcodeProfileExplicit && !weakResExplicit &&
                   weak.videoResolution == "320x240" &&
                   decodeSize != misterplex::kDefaultCodedDecodeSize) {
            if (!misterplex::applyPlexTranscodeProfile(decodeRes, weak)) {
                weak.profileName = "custom";
                weak.videoResolution = decodeRes;
                if (!weakBitrateExplicit) {
                    weak.maxVideoBitrateKbps = misterplex::weakBitrateKbpsForCodedSize(
                        decodeSize.width, decodeSize.height);
                }
            }
        }
        // Greppable GEOMETRY line: what PMS will be asked for at play (subject to
        // OSD O[4] override) vs the coded decode bank. profile_name is the ladder
        // label only — not a second geometry.
        std::fprintf(stderr,
                     "misterplexd: GEOMETRY decode_bank=%s decode_source=%s "
                     "pms_request_geometry=%s pms_bitrate_kbps=%d profile_name=%s "
                     "TRANSCODE_explicit=%d scale_mode=%s sws_flags=%s "
                     "(play may override via OSD O[4]; profile_name≠delivered WxH)\n",
                     decodeRes.c_str(), decodeSizeSource.c_str(),
                     weak.videoResolution.c_str(), weak.maxVideoBitrateKbps,
                     weak.profileName.c_str(),
                     (transcodeProfileExplicit || weakResExplicit) ? 1 : 0,
                     ffmpegScaleMode.c_str(),
                     ffmpegSwsFlags.empty() ? "(ffmpeg_default)" : ffmpegSwsFlags.c_str());
    }
    auto applyLinkCapacityToWeak = [&](misterplex::WeakLadder& w, const char* where) {
        if (linkCapacityKbps <= 0)
            return;
        const int before = w.maxVideoBitrateKbps;
        const int after = misterplex::applyLinkCapacityCapKbps(before, linkCapacityKbps,
                                                              linkCapacityHeadroomPct);
        if (after != before) {
            w.maxVideoBitrateKbps = after;
            std::fprintf(stderr,
                         "misterplexd: WARN link_capacity_clamp where=%s "
                         "requested_kbps=%d capacity_kbps=%d headroom_pct=%d "
                         "applied_kbps=%d tag=caller_supplied_capacity "
                         "(not a hardcoded floor; unset LINK_CAPACITY_KBIT to disable)\n",
                         where ? where : "?", before, linkCapacityKbps, linkCapacityHeadroomPct,
                         after);
        } else {
            std::fprintf(stderr,
                         "misterplexd: link_capacity_ok where=%s requested_kbps=%d "
                         "capacity_kbps=%d headroom_pct=%d applied_kbps=%d\n",
                         where ? where : "?", before, linkCapacityKbps, linkCapacityHeadroomPct,
                         after);
        }
    };

    std::string weakWhy;
    if (!misterplex::validateWeakLadder(weak, &weakWhy)) {
        std::fprintf(stderr, "misterplexd: invalid transcode profile (%s); falling back to 240p\n",
                     weakWhy.c_str());
        misterplex::applyPlexTranscodeProfile("240p", weak);
    } else {
        // Bitrate-below-recommended is advisory only. A hard 2000 kbps 480p floor
        // used to reject explicit WEAK_BITRATE and silently fall back to 240p.
        // Log the advisory; do not rewrite the ladder.
        std::string brAdv;
        if (misterplex::weakLadderBitrateBelowRecommended(weak, &brAdv)) {
            std::fprintf(stderr,
                         "misterplexd: WARN bitrate_below_recommended %s "
                         "WEAK_BITRATE_explicit=%d tag=caller_supplied_or_default\n",
                         brAdv.c_str(), weakBitrateExplicit ? 1 : 0);
        }
    }
    applyLinkCapacityToWeak(weak, "startup");
    if (linkCapacityKbps > 0) {
        std::fprintf(stderr,
                     "misterplexd: LINK_CAPACITY_KBIT=%d HEADROOM_PCT=%d "
                     "(optional physical cap; 0/unset = no clamp)\n",
                     linkCapacityKbps, linkCapacityHeadroomPct);
    }

    // SA_SIGINFO so si_pid/si_code survive into EXIT_REASON (who sent the kill).
    {
        struct sigaction sa {};
        sa.sa_sigaction = on_signal_info;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO;
        sigaction(SIGINT, &sa, nullptr);
        sigaction(SIGTERM, &sa, nullptr);
    }
    std::signal(SIGCHLD, SIG_DFL);
    // Session handoff (seek / new playMedia) calls killChildren() while the audio
    // and STREAM pump threads may still be writing to the ffmpeg pipes. The default
    // SIGPIPE action terminates the process *silently* — no log line, no dmesg entry
    // — and it is not in installCrashGuard()'s list, so Main is left SIGSTOPped and
    // F12/OSD die with us. Ignoring it turns those writes into a normal EPIPE that
    // the pump loops already treat as end-of-stream.
    std::signal(SIGPIPE, SIG_IGN);

    // An SPI critical section SIGSTOPs Main for a few microseconds. If a previous
    // misterplexd died inside that window, Main is still stopped right now and
    // F12/OSD/MiSTer_cmd are all dead — resume it before we do anything else,
    // then arm the crash guard so we cannot strand it again.
    misterplex::FpgaSpi::resumeStrandedMain();
    misterplex::FpgaSpi::installCrashGuard();

    // Death breadcrumb + frame ledger live beside conf (survives restarts).
    {
        const std::string confDir = confDirFromPath(confPath);
        misterplex::deathBreadcrumbInit(confDir);
        misterplex::deathBreadcrumbUpdate(misterplex::DeathState::Boot, 0, 0, 0, /*force=*/true);
        misterplex::frameLedgerInit(confDir);
        misterplex::frameLedgerProcessStart(0, 0, 0);
    }

    misterplex::MediaPlayer player;
    {
        // P4 soak identity: process_epoch is unique per daemon life (steady mono_ms).
        // Consumers must invalidate any window that spans a process_epoch change.
        const auto pe = std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now().time_since_epoch())
                            .count();
        player.armProcessEpoch(static_cast<uint64_t>(pe > 0 ? pe : 1));
    }
    player.setFfmpegPath(ffmpeg);
    player.setDecodeSize(decodeSize);
    player.setDecodeSizeSource(decodeSizeSource);
    {
        auto fpsf = loadConf(confPath, "FFMPEG_FPS_FILTER");
        if (!fpsf.empty()) {
            const bool on = confTruthy(fpsf); // off/0/false → omit fps= filter
            player.setFfmpegFpsFilter(on);
            std::fprintf(stderr, "misterplexd: FFMPEG_FPS_FILTER=%s\n", on ? "on" : "off");
        }
        // UV bias: counter fluorescent green (measured U low on HDMI vs source).
        int uBias = 0, vBias = 0;
        auto ub = loadConf(confPath, "UV_U_BIAS");
        auto vb = loadConf(confPath, "UV_V_BIAS");
        if (!ub.empty())
            uBias = std::atoi(ub.c_str());
        if (!vb.empty())
            vBias = std::atoi(vb.c_str());
        if (uBias != 0 || vBias != 0) {
            player.setUvBias(uBias, vBias);
            std::fprintf(stderr, "misterplexd: UV_U_BIAS=%d UV_V_BIAS=%d\n", uBias, vBias);
        }
    }
    player.setPresentMode(presentMode);
    player.setDdrFrameFormat(ddrFrameFormat);
    player.setDdrMemSync(ddrMemSync);
    player.setDdrMemFlush(ddrMemFlush);
    player.setPresentProfile(presentProfile);
    player.setStreamEnabled(streamEnabled);
    player.setStreamSkipRgb(streamSkipRgb);
    player.setFfmpegScaleMode(ffmpegScaleMode);
    player.setFfmpegSwsFlags(ffmpegSwsFlags);
    player.setFfmpegScaleAssumeMatch(ffmpegScaleAssumeMatch);
    player.setDdrYuvForceScale(ddrYuvForceScale);
    player.setSkipDeltasMs(skipForwardMs, skipBackMs);
    std::fprintf(stderr, "misterplexd: SKIP_FORWARD_MS=%lld SKIP_BACK_MS=%lld\n",
                 static_cast<long long>(skipForwardMs), static_cast<long long>(skipBackMs));
    if (subtitleMode == "ffmpeg")
        player.setSubtitleMode("ffmpeg");
    if (subtitleStreamId >= 0)
        player.setSubtitleStreamIndex(subtitleStreamId);
    {

        auto audio = loadConf(confPath, "AUDIO");
        if (!audio.empty())
            player.setAudioEnabled(confTruthy(audio));
        auto audioDev = loadConf(confPath, "AUDIO_DEVICE");
        if (!audioDev.empty())
            player.setAudioPath(audioDev);
        // Default 0 — no hardcoded audio lag. Conf AUDIO_DELAY_MS only.
        int audioDelayMs = 0;
        auto adv = loadConf(confPath, "AUDIO_DELAY_MS");
        if (!adv.empty())
            audioDelayMs = std::atoi(adv.c_str());
        player.setAudioDelayMs(audioDelayMs);
        std::fprintf(stderr, "misterplexd: AUDIO_DELAY_MS=%d (0=fresh, no hardcoded lag)\n",
                     audioDelayMs);
    }
    {
        // A/V pacing knobs. Defaults match the shipped behaviour; conf lets the lab
        // retune without a rebuild.
        auto lead = loadConf(confPath, "AV_PRESENT_LEAD_MS");
        if (!lead.empty())
            player.setPresentLeadMs(std::atoi(lead.c_str()));
        // Env wins over conf so lab can falsify LEAD without editing user-owned conf.
        // Parent must still backup/restore conf if conf is ever written; prefer env.
        const char* leadEnv = std::getenv("MISTERPLEX_AV_PRESENT_LEAD_MS");
        std::string leadSrc = lead.empty() ? "40(default)" : ("conf:" + lead);
        if (leadEnv && leadEnv[0] != '\0') {
            player.setPresentLeadMs(std::atoi(leadEnv));
            leadSrc = std::string("env:") + leadEnv;
            std::fprintf(stderr,
                         "misterplexd: AV_PRESENT_LEAD_MS overridden by "
                         "MISTERPLEX_AV_PRESENT_LEAD_MS=%s (conf not modified)\n",
                         leadEnv);
        }
        auto drop = loadConf(confPath, "AV_RESYNC_DROP_MS");
        if (!drop.empty())
            player.setResyncDropMs(std::atoi(drop.c_str()));
        auto ppm = loadConf(confPath, "AUDIO_CLOCK_PPM");
        if (!ppm.empty())
            player.setAudioClockPpm(std::atoi(ppm.c_str()));
        std::fprintf(stderr, "misterplexd: AUDIO_CLOCK_PPM=%d\n", player.audioClockPpm());
        auto avoff = loadConf(confPath, "AV_OFFSET_MS");
        if (!avoff.empty())
            player.setAvOffsetMs(std::atoi(avoff.c_str()));
        std::fprintf(stderr, "misterplexd: AV_PRESENT_LEAD_MS=%s AV_RESYNC_DROP_MS=%s\n",
                     leadSrc.c_str(),
                     drop.empty() ? "80(default)" : drop.c_str());
        // Raw video pipe capacity. Default ON (2 MiB). 0/off keeps kernel 64 KiB.
        // Startup banner probes a throwaway pipe and prints F_GETPIPE_SZ actual —
        // never the request alone (intent≠reality has bitten this banner before).
        {
            int rawPipeReq = misterplex::kDefaultRawVideoPipeBytes;
            auto rvp = loadConf(confPath, "RAW_VIDEO_PIPE_BYTES");
            if (!rvp.empty())
                rawPipeReq = misterplex::parseRawVideoPipeBytesConf(rvp);
            player.setRawVideoPipeBytes(rawPipeReq);
            int probe[2] = {-1, -1};
            misterplex::RawVideoPipeSizeResult probed{};
            if (::pipe(probe) == 0) {
                probed = misterplex::applyRawVideoPipeSize(probe[0], rawPipeReq);
                ::close(probe[0]);
                ::close(probe[1]);
            } else {
                probed.requested = rawPipeReq > 0 ? rawPipeReq : 0;
                probed.actual = -1;
                probed.set_errno = errno;
            }
            std::fprintf(stderr, "misterplexd: RAW_VIDEO_PIPE_BYTES %s\n",
                         misterplex::formatRawVideoPipeLog(probed).c_str());
        }
    }
    {
        // Idle/screensaver: without this the last frame of the previous video stays
        // latched in the frame store after playback ends.
        auto idle = loadConf(confPath, "IDLE_SCREEN");
        misterplex::IdleMode im = misterplex::IdleMode::Logo;
        if (idle == "black")
            im = misterplex::IdleMode::Black;
        else if (idle == "screensaver")
            im = misterplex::IdleMode::Screensaver;
        else if (idle == "last" || idle == "off")
            im = misterplex::IdleMode::LastFrame;
        // Anything else (empty, "logo", typos like "lastframe") → Logo default.
        player.setIdleMode(im);
        // OSD_CONTROL: auto|on|off (default auto). Auto applies F12 bits only when
        // live CONF_STR (UIO_GET_STRING) contains "O[15:14],Idle screen". Never uses
        // CORENAME/RBF filename. PLXS is transport only. Forced on is operator risk
        // on pre-v3. Forced off matches the old OSD_CONTROL=0 footgun intentionally.
        const auto osdRaw = loadConf(confPath, "OSD_CONTROL");
        const auto osdMode = misterplex::parseOsdControlMode(osdRaw);
        player.setOsdControlMode(osdMode);
        std::fprintf(stderr,
                     "misterplexd: OSD_CONTROL=%s (conf=%s) — auto applies only when "
                     "CONF_STR has O[15:14],Idle screen; on=force; off=F12 inert\n",
                     misterplex::osdControlModeName(osdMode),
                     osdRaw.empty() ? "(default auto)" : osdRaw.c_str());
        if (osdMode == misterplex::OsdControlMode::ForcedOff) {
            std::fprintf(stderr,
                         "misterplexd: OSD_CONTROL=off — F12 menu Idle Screen is inert; "
                         "only IDLE_SCREEN conf applies. Use OSD_CONTROL=auto on a v3+ "
                         "Idle-screen core, or on to force.\n");
        } else if (osdMode == misterplex::OsdControlMode::ForcedOn) {
            std::fprintf(stderr,
                         "misterplexd: OSD_CONTROL=on — IDLE_SCREEN conf is pre-OSD "
                         "fallback; applies mailbox or SPI status bits (unsafe on "
                         "pre-v3 CONF_STR).\n");
        } else {
            std::fprintf(stderr,
                         "misterplexd: OSD_CONTROL=auto — probing live CONF_STR via "
                         "UIO_GET_STRING; F12 Idle stays inert until Idle-screen marker "
                         "(fail closed). HDMI notice if pre-v3/absent.\n");
        }
        std::fprintf(stderr, "misterplexd: IDLE_SCREEN=%s AV_OFFSET_MS=%d\n",
                     idle.empty() ? "logo(default)" : idle.c_str(), player.avOffsetMs());
    }
    player.setLog([](const std::string& s) { logDaemon(s); });
    if (streamEnabled) {
        std::fprintf(stderr,
                     "misterplexd: STREAM=1 (annex-B → host I-recon F1 + F3; preferDirectH264; "
                     "PRESENT=%s STREAM_SKIP_RGB=%s — skip RGB only when PRESENT=fpga)\n",
                     presentMode.c_str(), streamSkipRgb.c_str());
    }
    std::fprintf(stderr, "misterplexd: DDR_MEM_SYNC=%s DDR_MEM_FLUSH=%s\n",
                 ddrMemSync ? "1" : "0", ddrMemFlush ? "1" : "0");
    std::fprintf(stderr, "misterplexd: DDR_FRAME_FORMAT=yuv420p\n");
    std::fprintf(stderr, "misterplexd: PRESENT_PROFILE=%s\n", presentProfile ? "1" : "0");
    std::fprintf(stderr,
                 "misterplexd: FFMPEG_SCALE=%s FFMPEG_SWS_FLAGS=%s "
                 "FFMPEG_SCALE_ASSUME_MATCH=%s DDR_YUV_FORCE_SCALE=%s "
                 "DDR_YUV_FORCE_SCALE_LAB=%s conf_off_requested=%s\n",
                 ffmpegScaleMode.c_str(),
                 ffmpegSwsFlags.empty() ? "(ffmpeg_default)" : ffmpegSwsFlags.c_str(),
                 ffmpegScaleAssumeMatch ? "1" : "0",
                 ddrYuvForceScale ? "1" : "0",
                 ddrYuvForceScaleLab ? "1" : "0",
                 ddrYuvForceScaleConfOff ? "1" : "0");
    if (ddrYuvForceScaleConfOff && !ddrYuvForceScaleLab) {
        std::fprintf(stderr,
                     "misterplexd: ERROR DDR_YUV_FORCE_SCALE=0 IGNORED — product code "
                     "default is ON. PMS library_media can claim 624x480 while delivering "
                     "624x350; without force-scale the reader desyncs (magenta wrap, "
                     "climbing drops). To disable for lab only set BOTH "
                     "DDR_YUV_FORCE_SCALE_LAB=1 and DDR_YUV_FORCE_SCALE=0.\n");
    } else if (ddrYuvForceScaleConfOff && ddrYuvForceScaleLab && !ddrYuvForceScale) {
        std::fprintf(stderr,
                     "misterplexd: WARN DDR_YUV_FORCE_SCALE=0 with LAB=1 — UNSAFE path "
                     "enabled; identity_skip only if delivery_verified=measured. "
                     "Expect desync if PMS delivers ≠ coded store.\n");
    }
    if (weak.burnSubtitles)
        std::fprintf(stderr, "misterplexd: SUBTITLES=burn (PMS universal)\n");
    else if (subtitleMode == "ffmpeg")
        std::fprintf(stderr, "misterplexd: SUBTITLES=ffmpeg (local files, STREAM=0)\n");
    std::fprintf(stderr, "misterplexd: PRESENT=%s (fpga required for core HDMI idle/OSD; "
                         "fb0 alone does not repaint the Plex frame store)\n",
                 presentMode.c_str());
    if (!player.initPresent()) {
        std::fprintf(stderr,
                     "misterplexd: ERROR present path failed (PRESENT=%s) — "
                     "companion may run but core HDMI idle/OSD will not update. "
                     "Need a loaded Plex.rbf + working FPGA SPI, or set PRESENT=none "
                     "for decode-only lab.\n",
                     presentMode.c_str());
    } else {
        // Paint the idle screen at boot so the core never shows a stale frame store.
        player.startIdle();
        player.startOsdPoll();
        player.startInputPoll();
    }

    // Lab A/V sync: play local file and exit (no companion / GDM).
    if (!playFile.empty()) {
        std::fprintf(stderr, "misterplexd: LAB play-file=%s seconds=%d\n", playFile.c_str(),
                     playSeconds);
        const auto sourceAspect = player.probeSourceAspect(playFile);
        if (!sourceAspect.valid || !player.setSourceAspect(sourceAspect)) {
            std::fprintf(stderr,
                         "misterplexd: play-file failed: source display aspect unavailable\n");
            return 1;
        }
        if (!player.play(playFile, 0, {}, playSeconds * 1000LL)) {
            std::fprintf(stderr, "misterplexd: play-file failed\n");
            player.stop();
            return exitReported(1, "site=main.cpp:lab-play-file-failed", &player);
        }
        // Wait up to playSeconds; exit early only after we have observed playing
        // then see it clear (natural EOF). Do not treat the pre-thread window as done.
        bool sawPlaying = false;
        for (int i = 0; i < playSeconds * 10; ++i) {
            if (player.playing())
                sawPlaying = true;
            else if (sawPlaying)
                break;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        player.stop();
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        const auto summary = player.lastPlaybackSummary();
        if (summary.deliveredFrames() <= 0) {
            std::fprintf(stderr,
                         "misterplexd: LAB play-file ERROR zero frames delivered "
                         "(raw=%lld presented=%lld recon=%lld totalBytes=%lld short_read=%d "
                         "got=%zu/%zu eof=%d stream=%d skip_rgb=%d). Check FFmpeg stderr/log, "
                         "source streams, and DDR/F1 delivery before grading captures.\n",
                         static_cast<long long>(summary.rawFrames),
                         static_cast<long long>(summary.presentedFrames),
                         static_cast<long long>(summary.reconFrames),
                         static_cast<long long>(summary.totalBytes), summary.shortRead ? 1 : 0,
                         summary.shortReadGot, summary.shortReadWant, summary.videoEof ? 1 : 0,
                         summary.streamEnabled ? 1 : 0, summary.skipRgb ? 1 : 0);
            return exitReported(2, "site=main.cpp:lab-play-file-zero-frames", &player);
        }
        std::fprintf(stderr,
                     "misterplexd: LAB play-file done frames=%lld presented=%lld recon=%lld "
                     "totalBytes=%lld\n",
                     static_cast<long long>(summary.rawFrames),
                     static_cast<long long>(summary.presentedFrames),
                     static_cast<long long>(summary.reconFrames),
                     static_cast<long long>(summary.totalBytes));
        return exitReported(0, "site=main.cpp:lab-play-file-done", &player);
    }

    misterplex::Companion comp;
    comp.setName(name);
    comp.setMachineId(machineId);
    comp.setPort(static_cast<uint16_t>(port));
    comp.setLog([](const std::string& s) { logDaemon(s); });

    misterplex::PmsTimelineReporter pmsTimeline;
    pmsTimeline.setLog([](const std::string& s) { logDaemon(s); });

    // plex.tv cast-target registration (opt-in). Uses the same client identifier
    // as GDM Resource-Identifier / --id so the account device list matches LAN.
    misterplex::PlexTvDeviceAnnouncer plexTv;
    plexTv.setLog([](const std::string& s) { logDaemon(s); });
    {
        misterplex::PlexTvDeviceIdentity plexId;
        plexId.clientIdentifier = machineId;
        plexId.product = "MiSTerPlex";
        plexId.version = "0.4.1";
        plexId.platform = "Linux";
        plexId.device = "MiSTer";
        plexId.deviceName = name;
        plexId.provides = "player";
        plexId.port = static_cast<uint16_t>(port);
        plexTv.configure(std::move(plexId), confToken, plexTvAnnounce);
    }

    // Session context for multi-base resolve + auto-next.
    std::mutex sessionMu;
    misterplex::PlayRequest lastPlay;
    std::string lastBase = defaultPms;
    std::string lastToken = confToken;
    uint64_t activeTimelineGeneration = 0;
    std::atomic<bool> autoNextInFlight{false};
    // Monotonic play generation: supersede in-flight async resolve when a newer
    // playMedia/auto-next arrives (P4-SCRUB out-of-order bind race).
    std::atomic<uint64_t> playGen{0};
    // Generation owned by the demux that may emit progress/EOF callbacks.
    // Pending playMedia requests advance playGen before the old demux stops.
    std::atomic<uint64_t> activePlaybackGeneration{0};
    // Serializes stop -> layout/DAR commit -> demux start. FpgaSpi layout changes
    // remap shared DDR and must never race an active presenter or a newer request.
    std::mutex playHandoffMu;

    auto contentResolutionForNextPlay = [&]() -> misterplex::ContentResolution {
        // Re-read apply gate each play: Auto may flip to LIVE after boot probe.
        if (player.osdApplyActive())
            return misterplex::contentResolutionFromOsdWord(player.lastOsdWord());
        return misterplex::contentResolutionFromCodedSize(decodeSize.width, decodeSize.height);
    };
    // FPGA present bank (v9 O[15:14]). May differ from content/PMS ladder for lab A/B.
    auto displayResolutionForNextPlay = [&]() -> misterplex::ContentResolution {
        if (player.osdApplyActive()) {
            const auto content = misterplex::contentResolutionFromOsdWord(player.lastOsdWord());
            return misterplex::displayResolutionFromOsdWord(player.lastOsdWord(), content);
        }
        return misterplex::contentResolutionFromCodedSize(decodeSize.width, decodeSize.height);
    };
    auto persistOsdResToConf = [&](const misterplex::ContentResolution& content,
                                   const misterplex::ContentResolution& display) {
        // Keep conf aligned with F12 so reboot/restart matches the menu.
        const int contentW = dimensionValue(content.width);
        const int contentH = dimensionValue(content.height);
        const int displayW = dimensionValue(display.width);
        const int displayH = dimensionValue(display.height);
        const std::string cGeom = std::to_string(contentW) + "x" + std::to_string(contentH);
        const std::string dGeom = std::to_string(displayW) + "x" + std::to_string(displayH);
        if (!upsertConfKey(confPath, "DECODE", dGeom))
            std::fprintf(stderr, "misterplexd: conf upsert DECODE failed path=%s\n",
                         confPath.c_str());
        if (!upsertConfKey(confPath, "TRANSCODE_PROFILE", content.label))
            std::fprintf(stderr, "misterplexd: conf upsert TRANSCODE_PROFILE failed\n");
        if (!upsertConfKey(confPath, "DISPLAY_RES", display.label))
            std::fprintf(stderr, "misterplexd: conf upsert DISPLAY_RES failed\n");
        if (!upsertConfKey(confPath, "CONTENT_RES", content.label))
            std::fprintf(stderr, "misterplexd: conf upsert CONTENT_RES failed\n");
        decodeSize = misterplex::CodedSize{misterplex::CodedWidth{displayW},
                                           misterplex::CodedHeight{displayH}};
        decodeSizeSource = "osd_persisted";
        std::fprintf(stderr,
                     "misterplexd: conf synced from OSD content=%s display=%s DECODE=%s "
                     "TRANSCODE_PROFILE=%s\n",
                     content.label, display.label, dGeom.c_str(), content.label);
    };

    auto resolveAgainstServers = [&](const misterplex::PlayRequest& req,
                                     const std::string& preferredBase, int64_t off,
                                     const misterplex::WeakLadder& weakForPlay, int matchW,
                                     int matchH) -> std::pair<misterplex::ResolveResult, std::string> {
        // Cast-pinned host must not authenticate with conf token (different PMS).
        std::string token;
        if (!req.token.empty())
            token = req.token;
        else if (req.address.empty())
            token = confToken;
        // Cast-selected base wins when address present.
        std::string selected =
            misterplex::buildPlexBase(req.protocol, req.address, req.port, preferredBase);
        if (selected.empty())
            selected = preferredBase.empty() ? defaultPms : preferredBase;

        auto tryBase = [&](const std::string& base) -> misterplex::ResolveResult {
            // STREAM=1: prefer direct H.264 Part for CAVLC host recon.
            // STREAM=0: weak universal by default. matchW/H are CONTENT bank for
            // direct-Part size match (not display present size).
            return misterplex::resolvePlayTarget(req.key, base, token, off, /*weakAlways=*/true,
                                                 weakForPlay,
                                                 /*preferDirectH264=*/streamEnabled, matchW,
                                                 matchH);
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

    auto prepareGeneratedPlay = [&](misterplex::PlayRequest& req) {
        std::lock_guard<std::mutex> handoff(playHandoffMu);
        const uint64_t parent = req.parentDispatchGeneration;
        if (parent == 0 || playGen.load() != parent) {
            std::fprintf(stderr,
                         "misterplexd: generated PLAY superseded before promotion key=%s\n",
                         req.key.c_str());
            return false;
        }
        uint64_t gen = 0;
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            if (lastPlay.dispatchGeneration != parent) {
                std::fprintf(
                    stderr,
                    "misterplexd: generated PLAY lost parent session before promotion key=%s\n",
                    req.key.c_str());
                return false;
            }
            gen = ++playGen;
            req.dispatchGeneration = gen;
            req.parentDispatchGeneration = 0;
            std::string requestBase;
            if (!req.address.empty()) {
                const std::string protocol =
                    req.protocol.empty() ? "http" : req.protocol;
                const std::string port = req.port.empty() ? "32400" : req.port;
                requestBase =
                    misterplex::buildPlexBase(protocol, req.address, port, "");
            }
            if (misterplex::pmsTimelineIdentityMatches(
                    misterplex::normalizePlexBase(requestBase),
                    req.serverMachineId,
                    misterplex::normalizePlexBase(lastBase),
                    lastPlay.serverMachineId) &&
                !lastToken.empty()) {
                req.token = lastToken;
            }
            lastPlay = req;
            lastToken = req.token;
        }
        comp.noteDispatchGeneration(gen);
        return true;
    };

    auto doPlay = [&](misterplex::PlayRequest req) {
        if (req.dispatchGeneration == 0 && !prepareGeneratedPlay(req))
            return;
        const uint64_t gen = req.dispatchGeneration;
        if (gen != playGen.load()) {
            std::fprintf(stderr, "misterplexd: PLAY superseded before resolve key=%s\n",
                         req.key.c_str());
            return;
        }
        int64_t off = req.offsetMs;
        const auto contentRes = contentResolutionForNextPlay();
        const auto displayRes = displayResolutionForNextPlay();
        const int contentW = dimensionValue(contentRes.width);
        const int contentH = dimensionValue(contentRes.height);
        const int displayW = dimensionValue(displayRes.width);
        const int displayH = dimensionValue(displayRes.height);
        // Partition key for instruments: lab argv vs conf vs OSD (parent fleet rule).
        if (player.osdApplyActive())
            player.setDecodeSizeSource("osd_content_display");
        else
            player.setDecodeSizeSource(decodeSizeSource);
        auto weakForPlay = weakForContentResolution(
            weak, contentRes, weakBitrateExplicit, weakQualityExplicit,
            weakH264ProfileExplicit);
        // Physical cap after tier/WEAK_BITRATE — never invents capacity when unset.
        applyLinkCapacityToWeak(weakForPlay, "play");
        std::fprintf(stderr,
                     "misterplexd: content=%s display=%s source=%s status_word=0x%04x "
                     "pms_videoResolution=%s bitrate=%d recommended_min_bitrate=%d "
                     "WEAK_BITRATE_explicit=%d link_capacity_kbps=%d "
                     "present=%dx%d decode_src=%s\n",
                     contentRes.label, displayRes.label,
                     player.osdApplyActive() ? "OSD content/display" : "conf/--decode",
                     player.lastOsdWord(), weakForPlay.videoResolution.c_str(),
                     weakForPlay.maxVideoBitrateKbps,
                     misterplex::recommendedMinVideoBitrateKbps(weakForPlay),
                     weakBitrateExplicit ? 1 : 0, linkCapacityKbps,
                     displayW, displayH,
                     player.decodeSizeSource().c_str());
        {
            std::string brAdv;
            if (misterplex::weakLadderBitrateBelowRecommended(weakForPlay, &brAdv)) {
                std::fprintf(stderr,
                             "misterplexd: WARN play bitrate_below_recommended %s "
                             "WEAK_BITRATE_explicit=%d (honored — not rejected)\n",
                             brAdv.c_str(), weakBitrateExplicit ? 1 : 0);
            }
        }
        auto [resolved, base] =
            resolveAgainstServers(req, defaultPms, off, weakForPlay, contentW, contentH);

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
            resolved.fpsNum = 30;
            resolved.fpsDen = 1;
            resolved.mediaWidth = 0;
            resolved.mediaHeight = 0;
            resolved.mediaAspectRatio.clear();
            resolved.pixelAspectRatio.clear();
            resolved.transcoded = false;
            resolved.sourceAspect = {4, 3, true};
            resolved.hasAudio = true;
        } else {
            std::fprintf(stderr, "misterplexd: resolved %s title=%s dur=%lld transcode=%d base=%s\n",
                         resolved.detail.c_str(), resolved.title.c_str(),
                         static_cast<long long>(resolved.durationMs),
                         resolved.transcoded ? 1 : 0, base.c_str());
        }

        // Expected delivery geometry for identity-scale decisions:
        // - universal transcode: we *request* weakForPlay.videoResolution — NOT
        //   verified delivery. PMS client profile only sets upperBound(w/h)
        //   (plex_resolve.cpp plexClientProfileExtra). delivery_verified=0.
        // - direct play: library Media/Stream WxH is a CLAIM only (basis=
        //   library_media). deliveryGeometryVerifiedFromBasis accepts ONLY
        //   "measured" — live silicon saw library_media=624x480 with measured=
        //   624x350 on the same asset.
        // - unknown: leave 0 so skip_identity still emits scale (safe).
        // Always re-set each play so a prior session cannot leak source dims.
        int expectW = 0, expectH = 0;
        const char* deliveryBasis = "unknown";
        if (resolved.transcoded) {
            if (std::sscanf(weakForPlay.videoResolution.c_str(), "%dx%d", &expectW, &expectH) ==
                    2 &&
                expectW > 0 && expectH > 0) {
                deliveryBasis = "transcode_request";
            } else {
                expectW = expectH = 0;
            }
        } else if (resolved.mediaWidth > 0 && resolved.mediaHeight > 0) {
            expectW = resolved.mediaWidth;
            expectH = resolved.mediaHeight;
            deliveryBasis = "library_media"; // claim — never sets delivery_verified
        }
        player.setFfmpegScaleSourceSize(expectW, expectH);
        // Play-time basis is never "measured" (that arrives later from ffmpeg
        // stderr). So delivery_verified stays 0 here; identity_skip needs
        // force-scale OFF + later measured match (or stays scaled).
        const bool deliveryVerified =
            misterplex::deliveryGeometryVerifiedFromBasis(deliveryBasis);
        player.setDeliveryGeometryVerified(deliveryVerified);

        const std::string decodeTarget = std::string(contentRes.label);
        const std::string requestedPms = weakForPlay.videoResolution;
        const std::string expectStr =
            (expectW > 0 && expectH > 0)
                ? (std::to_string(expectW) + "x" + std::to_string(expectH))
                : "unknown";
        // Predict ARM rescale from the same policy media_player will apply.
        // media_player compares expected_delivery to the *coded bank* (silicon
        // 624x480 for PRESENT=fpga|both), NOT to contentRes/DECODE (320x240).
        // Comparing to contentRes here falsely predicted arm_rescale=0 for the
        // shipping 320 path and hid the required scale+pad into the canvas.
        // YUV DDR force-scale default ON; identity_skip also needs verified delivery.
        const auto confScaleMode = misterplex::parseFfmpegScaleMode(ffmpegScaleMode);
        const bool wantFpgaDdrCanvas =
            (presentMode == "fpga" || presentMode == "both");
        const bool forceScale = wantFpgaDdrCanvas && ddrYuvForceScale;
        const auto scaleMode =
            misterplex::ffmpegScaleModeForDdrYuvPresent(confScaleMode, forceScale);
        const auto codedGeom =
            wantFpgaDdrCanvas
                ? misterplex::ddrFrameGeometryForFpgaPresent(
                      misterplex::CodedWidth{displayW}, misterplex::CodedHeight{displayH})
                : misterplex::makeDdrFrameGeometry(
                      misterplex::CodedWidth{displayW}, misterplex::CodedHeight{displayH});
        const int codedW = codedGeom.coded_width.get();
        const int codedH = codedGeom.coded_height.get();
        // Predict arm_rescale from the same buildFfmpegVideoFilter media_player uses
        // (Always+unverified exact → crop_pad scale_applied=0; FOAR only when needed).
        int armRescale = 1;
        bool hostFramesSourceAspect = false;
        if (scaleMode == misterplex::FfmpegScaleMode::Off) {
            armRescale = 0;
        } else {
            misterplex::FfmpegVfRequest pred;
            pred.coded_w = codedW;
            pred.coded_h = codedH;
            pred.display_w = codedGeom.display_width.get();
            pred.display_h = codedGeom.display_height.get();
            pred.crop_left = codedGeom.crop_left;
            pred.crop_top = codedGeom.crop_top;
            pred.scale_mode = scaleMode;
            pred.source_w = expectW;
            pred.source_h = expectH;
            pred.assume_source_matches_coded = ffmpegScaleAssumeMatch;
            pred.delivery_geometry_verified = deliveryVerified;
            pred.sws_flags = ffmpegSwsFlags;
            const auto predPlan = misterplex::buildFfmpegVideoFilter(pred);
            armRescale = predPlan.scale_applied ? 1 : 0;
            hostFramesSourceAspect =
                misterplex::ffmpegFilterFramesSourceAspect(predPlan);
        }
        // Greppable single-line geometry contract for parent device logs.
        // Keys: requested_pms expected_delivery decode_target arm_rescale
        // decode_target is the coded bank (624 on FPGA), content_tier is DECODE/OSD.
        const std::string libraryStr =
            (resolved.mediaWidth > 0 && resolved.mediaHeight > 0)
                ? (std::to_string(resolved.mediaWidth) + "x" +
                   std::to_string(resolved.mediaHeight))
                : "unknown";
        const std::string codedTarget =
            std::to_string(codedW) + "x" + std::to_string(codedH);
        // Predict square-pixel universal fit from library SAR/DAR (host math).
        // videoResolution is a ceiling — predicted_fit may be e.g. 624x350.
        const double contentDar = misterplex::resolveContentDar(
            resolved.mediaWidth, resolved.mediaHeight, resolved.pixelAspectRatio,
            resolved.mediaAspectRatio);
        int predW = 0, predH = 0;
        if (contentDar > 0.0 && codedW > 0 && codedH > 0) {
            const auto fit =
                misterplex::pmsSquarePixelFitInCeiling(contentDar, codedW, codedH);
            if (fit.ok) {
                predW = fit.w;
                predH = fit.h;
            }
        }
        const std::string predStr =
            (predW > 0 && predH > 0) ? (std::to_string(predW) + "x" + std::to_string(predH))
                                    : "unknown";
        const int sq480w =
            (contentDar > 0.0) ? misterplex::squarePixelWidthForHeight(contentDar, codedH) : 0;
        std::fprintf(stderr,
                     "misterplexd: GEOM requested_pms=%s expected_delivery=%s "
                     "delivery_basis=%s delivery_verified=%d decode_target=%s "
                     "content_tier=%s arm_rescale=%d yuv_ddr_force_scale=%d "
                     "aspect_owner=%s "
                     "transcoded=%d sws=%s scale_mode=%s library_media=%s "
                     "media_ar=%s sar=%s content_dar=%.4f predicted_square_fit=%s "
                     "square_px_w_at_coded_h=%d "
                     "note=videoResolution_is_ceiling_not_exact\n",
                     requestedPms.c_str(), expectStr.c_str(), deliveryBasis,
                     deliveryVerified ? 1 : 0, codedTarget.c_str(), decodeTarget.c_str(),
                     armRescale, forceScale ? 1 : 0,
                     hostFramesSourceAspect ? "host_canvas" : "native_scaler",
                     resolved.transcoded ? 1 : 0,
                     ffmpegSwsFlags.empty() ? "(ffmpeg_default)" : ffmpegSwsFlags.c_str(),
                     misterplex::ffmpegScaleModeName(scaleMode), libraryStr.c_str(),
                     resolved.mediaAspectRatio.empty() ? "-" : resolved.mediaAspectRatio.c_str(),
                     resolved.pixelAspectRatio.empty() ? "-" : resolved.pixelAspectRatio.c_str(),
                     contentDar, predStr.c_str(), sq480w);

        int resolvedFpsNum = resolved.fpsNum;
        int resolvedFpsDen = resolved.fpsDen;
        std::unique_lock<std::mutex> handoff;
        // Wire SOURCE_FPS / MATCH_SOURCE_HZ into play path (software Content FPS hint).
        const int effective =
            misterplex::applySourceFpsConf(sourceFpsConf, resolved.sourceFpsHint);
        if (effective > 0) {
            std::fprintf(stderr,
                         "misterplexd: Content FPS hint=%d (SOURCE_FPS=%s pms_vfr=%s "
                         "frameRate=%s resolved=%d) — exact pacing uses resolved rate; "
                         "switchres TODO\n",
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

        // Exact rational rate for A/V pacing. This is deliberately NOT the bucketed
        // hint above: PMS reports Media@videoFrameRate="24p" for 23.976 content, and
        // pacing that at 24 costs ~1 ms/s of lipsync drift.
        misterplex::applyContentFpsConf(loadConf(confPath, "AV_CONTENT_FPS"),
                                        resolvedFpsNum, resolvedFpsDen);
        std::fprintf(stderr, "misterplexd: content fps exact=%d/%d (pms frameRate=%s vfr=%s)\n",
                     resolvedFpsNum, resolvedFpsDen,
                     resolved.frameRate.empty() ? "-" : resolved.frameRate.c_str(),
                     resolved.videoFrameRate.empty() ? "-" : resolved.videoFrameRate.c_str());
        if (!resolved.sourceAspect.valid) {
            resolved.sourceAspect =
                player.probeSourceAspect(resolved.playable, resolved.httpHeaders);
            if (resolved.sourceAspect.valid) {
                std::fprintf(stderr,
                             "misterplexd: source aspect probed from stream=%u:%u\n",
                             resolved.sourceAspect.x, resolved.sourceAspect.y);
            }
        }

        // Plex Web may send only containerKey=/playQueues/N. A ratingKey is not a
        // playQueueItemID; inventing one makes the controller index a nonexistent
        // queue row and discard otherwise advancing timeline polls.
        std::string resolvedPlayQueueItemId = req.playQueueItemId;
        std::string resolvedPlayQueueId = req.playQueueId;
        std::string resolvedPlayQueueVersion = req.playQueueVersion;
        std::string resolvedContainerKey = req.containerKey;
        if (resolvedPlayQueueItemId.empty()) {
            std::string queueRef = req.containerKey;
            if (queueRef.empty() && !req.playQueueId.empty())
                queueRef = "/playQueues/" + req.playQueueId;
            std::string queueToken = req.token;
            if (queueToken.empty() && req.address.empty())
                queueToken = confToken;
            if (!queueRef.empty() && queueRef.find("/playQueues/") != std::string::npos) {
                const auto queue =
                    misterplex::fetchPlayQueue(queueRef, base, queueToken, req.key, {});
                if (queue.ok && queue.currentIndex >= 0 &&
                    static_cast<size_t>(queue.currentIndex) < queue.items.size()) {
                    const auto& item = queue.items[static_cast<size_t>(queue.currentIndex)];
                    const bool keyMatches =
                        item.key == req.key ||
                        (!item.ratingKey.empty() &&
                         (item.ratingKey == resolved.ratingKey ||
                          req.key.find(item.ratingKey) != std::string::npos));
                    if (keyMatches && !item.playQueueItemId.empty()) {
                        resolvedPlayQueueItemId = item.playQueueItemId;
                        if (!queue.playQueueId.empty())
                            resolvedPlayQueueId = queue.playQueueId;
                        if (!queue.playQueueVersion.empty())
                            resolvedPlayQueueVersion = queue.playQueueVersion;
                        if (!queue.containerKey.empty())
                            resolvedContainerKey = queue.containerKey + "?own=1";
                        std::fprintf(stderr,
                                     "misterplexd: play queue bound id=%s item=%s version=%s\n",
                                     resolvedPlayQueueId.c_str(),
                                     resolvedPlayQueueItemId.c_str(),
                                     resolvedPlayQueueVersion.empty()
                                         ? "-"
                                         : resolvedPlayQueueVersion.c_str());
                    }
                } else {
                    std::fprintf(stderr,
                                 "misterplexd: play queue identity unavailable: %s\n",
                                 queue.detail.c_str());
                }
            }
        }

        handoff = std::unique_lock<std::mutex>(playHandoffMu);
        if (gen != playGen.load() || !comp.acceptsPlayRequest(req)) {
            std::fprintf(stderr,
                         "misterplexd: PLAY superseded before aspect commit key=%s\n",
                         req.key.c_str());
            return;
        }
        player.stop();
        activePlaybackGeneration.store(0);
        FpgaWorkerHandoff fpgaWorkers(player);
        // Present/DDR bank follows display; PMS ladder follows content.
        player.setDecodeSize(misterplex::CodedSize{
            misterplex::CodedWidth{displayW}, misterplex::CodedHeight{displayH}});
        player.setContentFpsRational(resolvedFpsNum, resolvedFpsDen);
        const auto presentationAspect = misterplex::sourceAspectForPresentation(
            resolved.sourceAspect, codedGeom.presented_width.get(),
            codedGeom.presented_height.get(),
            wantFpgaDdrCanvas && hostFramesSourceAspect);
        bool sourceAspectPublished =
            player.setSourceAspect(resolved.sourceAspect, presentationAspect);
        if (!sourceAspectPublished && (displayW != contentW || displayH != contentH)) {
            std::fprintf(
                stderr,
                "misterplexd: source aspect display layout ACK failed; retrying content "
                "layout %dx%d\n",
                contentW, contentH);
            player.setDecodeSize(misterplex::CodedSize{
                misterplex::CodedWidth{contentW}, misterplex::CodedHeight{contentH}});
            sourceAspectPublished =
                player.setSourceAspect(resolved.sourceAspect, presentationAspect);
        }
        if (!sourceAspectPublished) {
            std::fprintf(stderr,
                         "misterplexd: PLAY rejected: source aspect unknown or FPGA ACK "
                         "did not match\n");
            return;
        }
        player.setSourceMediaSize(resolved.mediaWidth, resolved.mediaHeight);
        player.setSourceHasAudio(resolved.hasAudio);
        if (resolved.mediaWidth > 0 && resolved.mediaHeight > 0) {
            std::fprintf(stderr,
                         "misterplexd: pms source media=%dx%d decode=%dx%d scale=%s "
                         "hasAudio=%d\n",
                         resolved.mediaWidth, resolved.mediaHeight, player.decodeW(),
                         player.decodeH(),
                         (resolved.mediaWidth == player.decodeW() &&
                          resolved.mediaHeight == player.decodeH())
                             ? "identity_match_bank"
                             : "scale_or_pad",
                         resolved.hasAudio ? 1 : 0);
        } else {
            std::fprintf(stderr, "misterplexd: pms hasAudio=%d\n",
                         resolved.hasAudio ? 1 : 0);
        }

        if (!req.offsetPresent && resolved.viewOffsetMs > 0) {
            // PMS continue-watching offset when cast omitted offset=. playMedia already
            // planted scrubTarget at 0; demux will start at viewOffset. Re-plant so the
            // companion hold matches the real start (avoids far-ahead freeze at 0:00).
            off = resolved.viewOffsetMs;
            std::fprintf(stderr,
                         "misterplexd: applying PMS viewOffsetMs=%lld (cast offset absent)\n",
                         static_cast<long long>(off));
        }

        misterplex::PlayRequest bound = req;
        if (bound.ratingKey.empty())
            bound.ratingKey = resolved.ratingKey;
        if (bound.playQueueItemId.empty())
            bound.playQueueItemId = resolvedPlayQueueItemId;
        if (bound.playQueueId.empty())
            bound.playQueueId = resolvedPlayQueueId;
        if (bound.playQueueVersion.empty())
            bound.playQueueVersion = resolvedPlayQueueVersion;
        if (bound.containerKey.empty())
            bound.containerKey = resolvedContainerKey;
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
            // An identity-qualified control can rotate the pending PMS token
            // while resolve is in flight. Adopt it only for this exact play
            // generation; never borrow credentials from an older/newer cast.
            if (lastPlay.dispatchGeneration == gen && !lastToken.empty())
                bound.token = lastToken;
        }

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

        // Re-base companion plant to the demux start (viewOffset / in-flight seek).
        // setState(buffering) alone cannot move time while an older plant holds.
        // (0abee0b6 — stop Web scrubber freeze at 0:00 when demux is ahead of plant)
        comp.seedPlaybackPosition(startAt, resolved.durationMs);

        // Ensure timeline immediately reports duration + time for scrubber (seekRange).
        comp.setState("buffering", startAt, resolved.durationMs);

        if (gen != playGen.load() || !comp.wantPlay()) {
            std::fprintf(stderr, "misterplexd: PLAY superseded before player.play key=%s\n",
                         bound.key.c_str());
            return;
        }

        // Commit session context only when we are about to start demux. Writing
        // lastPlay earlier can resurrect a queue bind if stop cleared it mid-flight.
        // setPlayQueued already planted a provisional lastPlay for skip-during-resolve.
        // Final wantPlay/playGen gate under the same critical section as lastPlay
        // so stop cannot clear then get a zombie lastPlay + player.play.
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            if (gen != playGen.load() || !comp.wantPlay()) {
                std::fprintf(stderr, "misterplexd: PLAY superseded before demux key=%s\n",
                             bound.key.c_str());
                return;
            }
            // Serialize the final token snapshot with beginSession. An
            // identity-qualified refresh that arrived during resolve updated
            // lastToken for this generation; a later refresh blocks here until
            // the reporter has atomically promoted the same PMS session.
            if (lastPlay.dispatchGeneration == gen && !lastToken.empty())
                bound.token = lastToken;
            bool tokenFromConf = false;
            if (bound.token.empty() && req.address.empty() && !confToken.empty()) {
                bound.token = confToken;
                tokenFromConf = true;
            }
            lastPlay = bound;
            lastBase = base;
            lastToken = bound.token;

            // Timeline must target the server that issued playMedia, with THAT
            // request's credentials. The reporter promotion stays inside this
            // session lock so a control refresh cannot fall between the final
            // token snapshot and beginSession.
            misterplex::PmsTimelineSession timelineSession;
            timelineSession.baseUrl = base;
            timelineSession.token = bound.token;
            timelineSession.key = bound.key;
            timelineSession.ratingKey = bound.ratingKey;
            timelineSession.serverMachineIdentifier = bound.serverMachineId;
            timelineSession.playQueueItemId = bound.playQueueItemId;
            timelineSession.containerKey = bound.containerKey;
            timelineSession.clientIdentifier = machineId;
            timelineSession.product = "MiSTerPlex";
            timelineSession.version = "0.4.1";
            timelineSession.deviceName = name;
            const char* tokenSrc =
                bound.token.empty() ? "none" : (tokenFromConf ? "conf" : "cast");
            logDaemon("misterplexd: pms timeline session base=" + base +
                      " token_src=" + tokenSrc +
                      " ratingKey=" + timelineSession.ratingKey);
            pmsTimeline.beginSession(timelineSession, startAt, resolved.durationMs);
            activeTimelineGeneration = gen;
        }

        // resolved.playable keeps the real token for FFmpeg; only the log line is scrubbed.
        logDaemon("misterplexd: PLAY " + resolved.playable +
                  " off=" + std::to_string(startAt) +
                  " dur=" + std::to_string(resolved.durationMs) +
                  " maxVideoBitrate=" + std::to_string(weakForPlay.maxVideoBitrateKbps) +
                  " WEAK_BITRATE_explicit=" + std::to_string(weakBitrateExplicit ? 1 : 0));
        player.setLadderBitrateKbps(weakForPlay.maxVideoBitrateKbps);
        activePlaybackGeneration.store(gen);
        if (!player.play(resolved.playable, startAt, resolved.httpHeaders,
                         resolved.durationMs)) {
            uint64_t expected = gen;
            activePlaybackGeneration.compare_exchange_strong(expected, 0);
            std::fprintf(stderr, "misterplexd: PLAY failed to start demux key=%s\n",
                         bound.key.c_str());
            return;
        }
        fpgaWorkers.completePlayback();
    };

    // Live content/display-res change (OSD O[5:4] / O[15:14]): sync conf, retarget
    // PMS weak ladder, restart session at same playhead. No misterplexd process
    // restart required — conf write is for persistence across daemon restarts.
    player.setOnContentResolutionChanged(
        [&](const misterplex::ContentResolution& cr, bool playingNow) {
            const auto displayRes = displayResolutionForNextPlay();
            const int crW = dimensionValue(cr.width);
            const int crH = dimensionValue(cr.height);
            std::fprintf(stderr,
                         "misterplexd: content_res OSD→%s (%dx%d) display=%s playing=%d — "
                         "PMS ladder + conf sync (PRESENT=fpga DDR path)\n",
                         cr.label, crW, crH, displayRes.label, playingNow ? 1 : 0);
            persistOsdResToConf(cr, displayRes);
            if (!playingNow)
                return;
            const uint64_t sourceGeneration =
                activePlaybackGeneration.load();
            if (sourceGeneration == 0 || sourceGeneration != playGen.load()) {
                std::fprintf(
                    stderr,
                    "misterplexd: content_res restart ignored — active demux superseded\n");
                return;
            }
            misterplex::PlayRequest cur;
            {
                std::lock_guard<std::mutex> lk(sessionMu);
                if (lastPlay.dispatchGeneration != sourceGeneration)
                    return;
                cur = lastPlay;
            }
            if (cur.key.empty() && cur.ratingKey.empty()) {
                std::fprintf(stderr,
                             "misterplexd: content_res change ignored — no bound session\n");
                return;
            }
            const int64_t pos = player.positionMs();
            cur.offsetMs = pos > 0 ? pos : cur.offsetMs;
            cur.offsetPresent = true;
            cur.parentDispatchGeneration = cur.dispatchGeneration;
            cur.dispatchGeneration = 0;
            std::fprintf(stderr,
                         "misterplexd: content_res live restart key=%s offset_ms=%lld → "
                         "content=%s display=%s\n",
                         cur.key.empty() ? cur.ratingKey.c_str() : cur.key.c_str(),
                         static_cast<long long>(cur.offsetMs), cr.label, displayRes.label);
            // Async so we never restart from inside the OSD poller thread.
            std::thread([&, cur]() {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                doPlay(cur);
            }).detach();
        });

    // Shared play-queue step: delta=+1 (auto-next / skipNext), delta=-1 (skipPrevious).
    // Returns true when a new title was started via doPlay.
    auto tryQueueStep = [&](int delta, const char* tag,
                            uint64_t expectedParent = 0) -> bool {
        if (delta == 0)
            return false;
        // autoNext conf gates natural-EOF advance only; explicit skipNext/Prev always try.
        misterplex::PlayRequest cur;
        std::string base, token;
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            if (expectedParent != 0 &&
                lastPlay.dispatchGeneration != expectedParent) {
                std::fprintf(stderr,
                             "misterplexd: %s skip — playback generation changed\n",
                             tag);
                return false;
            }
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
        n.playQueueItemId = item.playQueueItemId;
        n.playQueueId = !q.playQueueId.empty() ? q.playQueueId : cur.playQueueId;
        n.playQueueVersion =
            !q.playQueueVersion.empty() ? q.playQueueVersion : cur.playQueueVersion;
        n.containerKey = !q.containerKey.empty() ? q.containerKey + "?own=1" : cur.containerKey;
        n.offsetMs = 0;
        n.offsetPresent = true; // do not apply continue-watching on queue step
        n.token = token;
        n.parentDispatchGeneration = cur.dispatchGeneration;
        n.dispatchGeneration = 0;
        std::fprintf(stderr, "misterplexd: %s → %s title=%s pqItem=%s\n", tag, n.key.c_str(),
                     item.title.c_str(), n.playQueueItemId.c_str());
        // Stage scrubber key before resolve so bindMedia key-match accepts this
        // item (and Web sees queue advance immediately).
        if (!prepareGeneratedPlay(n))
            return false;
        if (!comp.stagePlay(n))
            return false;
        doPlay(n);
        return true;
    };

    // Next-episode stub: on natural EOF, if playQueue has a next item, play it.
    auto tryAutoNext = [&](uint64_t expectedParent) -> bool {
        if (!autoNext)
            return false;
        return tryQueueStep(+1, "auto-next", expectedParent);
    };

    player.setProgress([&](const std::string& st, int64_t t, int64_t d) {
        const uint64_t eventGeneration =
            activePlaybackGeneration.load();
        if (eventGeneration == 0 || eventGeneration != playGen.load()) {
            std::fprintf(stderr,
                         "misterplexd: stale playback event ignored state=%s\n",
                         st.c_str());
            return;
        }
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            if (lastPlay.dispatchGeneration != eventGeneration ||
                activeTimelineGeneration != eventGeneration) {
                std::fprintf(stderr,
                             "misterplexd: unbound playback event ignored state=%s\n",
                             st.c_str());
                return;
            }
            if (st == "ended" || st == "stopped")
                pmsTimeline.endSession(t, d);
            else
                pmsTimeline.reportState(st, t, d);
        }
        if (st == "ended") {
            // Must not call player.play() on the media thread (join self). Schedule async.
            if (autoNextInFlight.exchange(true))
                return;
            if (!comp.setStateIfGeneration(eventGeneration, "buffering", t, d)) {
                autoNextInFlight.store(false);
                return;
            }
            // Keep scrubber alive while we decide; queue fetch is network-bound.
            std::thread([&, t, d, eventGeneration]() {
                bool advanced = false;
                try {
                    advanced = tryAutoNext(eventGeneration);
                } catch (...) {
                    std::fprintf(stderr, "misterplexd: auto-next exception\n");
                }
                autoNextInFlight.store(false);
                if (!advanced)
                    comp.endMediaSessionIfGeneration(eventGeneration, t, d);
            }).detach();
            return;
        }
        comp.setStateIfGeneration(eventGeneration, st, t, d);
    });

    // playMedia HTTP thread: bump playGen immediately so in-flight doPlay aborts
    // before the new onPlay_ thread even schedules (cast A→B race).
    comp.setPlayQueued([&](const misterplex::PlayRequest& request) {
        std::lock_guard<std::mutex> handoff(playHandoffMu);
        const uint64_t generation = ++playGen;
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            lastPlay = request;
            lastPlay.dispatchGeneration = generation;
            lastToken = request.token;
            if (!request.address.empty()) {
                const std::string protocol =
                    request.protocol.empty() ? "http" : request.protocol;
                const std::string port = request.port.empty() ? "32400" : request.port;
                lastBase =
                    misterplex::buildPlexBase(protocol, request.address, port, "");
            } else {
                lastBase.clear();
            }
        }
        comp.noteDispatchGeneration(generation);
        return generation;
    });

    // Keep PMS /:/timeline auth in lock-step with cast-supplied tokens.
    comp.setTokenUpdate([&](const misterplex::TokenUpdate& update) {
        if (update.token.empty())
            return;
        std::string expectedBase;
        if (!update.address.empty()) {
            const std::string protocol =
                update.protocol.empty() ? "http" : update.protocol;
            const std::string port = update.port.empty() ? "32400" : update.port;
            expectedBase =
                misterplex::buildPlexBase(protocol, update.address, port, "");
        }
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            if (!misterplex::pmsTimelineIdentityMatches(
                    misterplex::normalizePlexBase(expectedBase),
                    update.serverMachineId,
                    misterplex::normalizePlexBase(lastBase),
                    lastPlay.serverMachineId))
                return;
            lastToken = update.token;
            lastPlay.token = update.token;
            if (activeTimelineGeneration == lastPlay.dispatchGeneration) {
                pmsTimeline.updateToken(update.token, expectedBase,
                                        update.serverMachineId);
            }
        }
    });

    // Pending identity was planted synchronously by setPlayQueued before ACK.
    // The detached callback must not overwrite a newer generation.
    comp.setPlay([&](const misterplex::PlayRequest& req) {
        if (req.dispatchGeneration != playGen.load())
            return;
        doPlay(req);
    });

    comp.setPause([&]() { player.pause(); });
    comp.setResume([&]() { player.resume(); });
    comp.setStop([&]() {
        // Invalidate in-flight doPlay (resolve/bind/player.play) so a late
        // playMedia cannot restart demux after stop. clearMedia already cleared
        // wantPlay_; bindMedia and wantPlay re-checks will also abort.
        {
            std::lock_guard<std::mutex> handoff(playHandoffMu);
            const uint64_t generation = ++playGen;
            activePlaybackGeneration.store(0);
            comp.noteDispatchGeneration(generation);
            player.stop();
        }
        // Drop session bind so a post-stop skip cannot fetch the old play-queue.
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            lastPlay = misterplex::PlayRequest{};
            lastBase.clear();
            activeTimelineGeneration = 0;
        }
    });
    // Async seek: demux restart joins the media thread — never block companion HTTP
    // (Web scrubber thumb / step / skipPrevious restart@0 would otherwise stall ACKs).
    // seekGen + seekMu: serialize demux restarts and drop superseded offsets so a
    // late drained seekMs(old) cannot restart at 0 after a newer scrub plant.
    // Product STREAM=0 cast uses PMS universal with offset= baked into the URL.
    // Re-resolve + fresh play at the new offset (not FFmpeg -ss on a stale universal).
    // Local files / direct Parts still use player.seekMs → -ss.
    std::atomic<uint64_t> seekGen{0};
    std::mutex seekMu;
    auto seekAsync = [&](int64_t ms, uint64_t expectedParent = 0) {
        const uint64_t g = ++seekGen;
        uint64_t parentGeneration = 0;
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            parentGeneration = lastPlay.dispatchGeneration;
            if (expectedParent != 0 &&
                parentGeneration != expectedParent) {
                return;
            }
        }
        std::thread([&, ms, g, parentGeneration]() {
            std::lock_guard<std::mutex> lock(seekMu);
            if (g != seekGen.load())
                return; // superseded while waiting for prior seekMs
            try {
                misterplex::PlayRequest cur;
                {
                    std::lock_guard<std::mutex> sl(sessionMu);
                    if (lastPlay.dispatchGeneration != parentGeneration)
                        return;
                    cur = lastPlay;
                }
                const bool libraryKey =
                    !cur.key.empty() &&
                    (cur.key.rfind("/library", 0) == 0 || cur.key.find("library/metadata") != std::string::npos);
                if (libraryKey) {
                    cur.offsetMs = ms < 0 ? 0 : ms;
                    cur.offsetPresent = true;
                    cur.parentDispatchGeneration = parentGeneration;
                    cur.dispatchGeneration = 0;
                    std::fprintf(stderr,
                                 "misterplexd: seek re-resolve key=%s offMs=%lld\n",
                                 cur.key.c_str(), static_cast<long long>(cur.offsetMs));
                    // doPlay re-resolves universal with offset=seconds and restarts demux.
                    doPlay(cur);
                } else {
                    // Local path / testsrc / non-library: demux -ss on same URL.
                    player.seekMs(ms);
                }
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
        uint64_t commandGeneration = 0;
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            commandGeneration = lastPlay.dispatchGeneration;
        }
        if (commandGeneration == 0)
            return;
        if (autoNextInFlight.exchange(true))
            return;
        std::thread([&, commandGeneration]() {
            try {
                if (!tryQueueStep(+1, "skipNext", commandGeneration))
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
        uint64_t commandGeneration = 0;
        {
            std::lock_guard<std::mutex> lock(sessionMu);
            commandGeneration = lastPlay.dispatchGeneration;
        }
        if (commandGeneration == 0)
            return;
        constexpr int64_t kRestartThresholdMs = 3000;
        if (t > kRestartThresholdMs) {
            std::fprintf(stderr, "misterplexd: skipPrevious restart@0 (t=%lld)\n",
                         static_cast<long long>(t));
            seekAsync(0, commandGeneration);
            return;
        }
        // Near start: try queue previous (network). Guard concurrent skip/auto-next.
        if (autoNextInFlight.exchange(true))
            return;
        std::thread([&, t, commandGeneration]() {
            try {
                if (!tryQueueStep(-1, "skipPrevious",
                                  commandGeneration)) {
                    if (t > 0) {
                        if (playGen.load() != commandGeneration) {
                            std::fprintf(
                                stderr,
                                "misterplexd: skipPrevious fallback dropped — "
                                "playback generation changed\n");
                            autoNextInFlight.store(false);
                            return;
                        }
                        // Queue lookup is network-bound. If the user scrubbed away
                        // while it was in flight, do not clobber the new plant with
                        // a stale restart@0 (unit: plant 40s after skipPrev@1.5s).
                        const int64_t nowT = comp.timelineTimeMs();
                        const int64_t drift = nowT > t ? nowT - t : t - nowT;
                        if (drift > kRestartThresholdMs && nowT > kRestartThresholdMs) {
                            std::fprintf(stderr,
                                         "misterplexd: skipPrevious no prev — drop stale "
                                         "restart@0 (was t=%lld now=%lld)\n",
                                         static_cast<long long>(t),
                                         static_cast<long long>(nowT));
                        } else {
                            std::fprintf(stderr,
                                         "misterplexd: skipPrevious no prev — restart@0 (t=%lld)\n",
                                         static_cast<long long>(t));
                            seekAsync(0, commandGeneration);
                        }
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
        return exitReported(1, "site=main.cpp:companion-start-failed", &player);
    }

    misterplex::deathBreadcrumbUpdate(misterplex::DeathState::Idle, 0, 0, 0, /*force=*/true);

    // Fail-soft: logs skip/success/failure; never blocks companion or playback.
    plexTv.start();

    if (defaultPms.empty()) {
        std::fprintf(stderr,
                     "misterplexd: no default Plex server configured; set PLEX_BASE in %s "
                     "or pass --pms URL. Cast clients that include a server address can still "
                     "select a server per play.\n",
                     confPath.c_str());
    }
    // Banner: never print profile_name as if it were a second geometry next to
    // decode_bank (that read as "weak=480p/624x480" vs "decode=320x240").
    std::fprintf(stderr,
                 "misterplexd: running git_rev=%s name=%s id=%s port=%d pms=%s servers=%zu "
                 "decode_bank=%s decode_source=%s pms_request_geometry=%s "
                 "pms_bitrate_kbps=%d profile_name=%s h264=%s@L%d present=%s "
                 "auto_next=%d subs=%s\n",
                 kMisterplexGitRev,
                 name.c_str(), machineId.c_str(), port,
                 defaultPms.empty() ? "(unset)" : defaultPms.c_str(), servers.size(),
                 decodeSize.wxh().c_str(), decodeSizeSource.c_str(),
                 weak.videoResolution.c_str(), weak.maxVideoBitrateKbps,
                 weak.profileName.c_str(), weak.h264Profile.c_str(), weak.h264Level,
                 presentMode.c_str(), autoNext ? 1 : 0, subtitleMode.c_str());
    for (size_t i = 0; i < servers.size(); ++i)
        std::fprintf(stderr, "misterplexd:   server[%zu]=%s%s\n", i, servers[i].c_str(),
                     i == 0 ? " (default)" : "");

    // Watchdog: an SPI critical section SIGSTOPs Main only long enough to prove
    // it is parked between its own transactions, but if that window is ever
    // leaked — a hang inside the section, a thread killed mid-flight — Main
    // stays stopped and the user loses F12 with no way back. Sweeping /proc
    // twice a second costs nothing and touches no SPI, so it can never make
    // things worse. This only ever sends SIGCONT: misterplexd does not start,
    // stop, or reload Main.
    unsigned tick = 0;
    while (!g_stop.load(std::memory_order_acquire)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        if (++tick % 3 != 0)
            continue;
        misterplex::FpgaSpi::resumeStrandedMain();
        // Optional auto ladder step-down: consumes LADDER_STEPDOWN_RECOMMENDED.
        // Geometry unchanged; bitrate only. Not a hardcoded link speed.
        if (autoLadderStepdown) {
            const int nextBr = player.takeLadderStepdownKbps();
            if (nextBr > 0 && player.playing()) {
                const uint64_t sourceGeneration =
                    activePlaybackGeneration.load();
                if (sourceGeneration == 0 ||
                    sourceGeneration != playGen.load()) {
                    std::fprintf(
                        stderr,
                        "misterplexd: AUTO_LADDER_STEPDOWN drop stale playback trigger\n");
                    continue;
                }
                misterplex::PlayRequest cur;
                {
                    std::lock_guard<std::mutex> lock(sessionMu);
                    if (lastPlay.dispatchGeneration != sourceGeneration)
                        continue;
                    cur = lastPlay;
                }
                const int64_t pos = player.positionMs();
                weak.maxVideoBitrateKbps = nextBr;
                weakBitrateExplicit = true;
                cur.offsetMs = pos > 0 ? pos : 0;
                cur.offsetPresent = true;
                cur.parentDispatchGeneration = cur.dispatchGeneration;
                cur.dispatchGeneration = 0;
                std::fprintf(stderr,
                             "misterplexd: AUTO_LADDER_STEPDOWN apply next_bitrate_kbps=%d "
                             "pos_ms=%lld geometry_unchanged=1 tag=measured\n",
                             nextBr, static_cast<long long>(pos));
                doPlay(cur);
            } else if (nextBr > 0) {
                // Not playing — still adopt for the next cast.
                weak.maxVideoBitrateKbps = nextBr;
                weakBitrateExplicit = true;
                std::fprintf(stderr,
                             "misterplexd: AUTO_LADDER_STEPDOWN adopt_idle next_bitrate_kbps=%d\n",
                             nextBr);
            }
        }
        // Throttled heartbeat so misterplexd.last is never hours-stale after a kill.
        if ((tick % 25) == 0) {
            misterplex::deathBreadcrumbUpdate(
                player.playing() ? (player.paused() ? misterplex::DeathState::Paused
                                                    : misterplex::DeathState::Playing)
                                 : misterplex::DeathState::Idle,
                player.lifetimeFrames(), player.lifetimePresents(), player.positionMs(),
                /*force=*/false);
        }
    }

    // g_stop is set only by SIGINT/SIGTERM handlers → orderly return 0.
    // rc=0 is therefore NOT proof of "voluntary idle exit"; it is the handled-signal path.
    const int stopSig = g_stopSig.load(std::memory_order_relaxed);
    const int stopCode = g_stopSiCode.load(std::memory_order_relaxed);
    const int stopPid = g_stopSiPid.load(std::memory_order_relaxed);
    char why[192];
    std::snprintf(why, sizeof(why),
                  "site=main.cpp:main_loop_g_stop sig=%d si_code=%d si_pid=%d "
                  "(handled→WIFEXITED 0; not WIFSIGNALED)",
                  stopSig, stopCode, stopPid);
    std::fprintf(stderr,
                 "misterplexd: main_loop exit pending — %s lifetime_frames=%lld "
                 "lifetime_presents=%lld lifetime_drops=%lld\n",
                 why, static_cast<long long>(player.lifetimeFrames()),
                 static_cast<long long>(player.lifetimePresents()),
                 static_cast<long long>(player.lifetimeDrops()));

    player.stop();
    pmsTimeline.stopAndFlush();
    plexTv.stop();
    comp.stop();
    // Last chance on the way out: a window leaked during teardown would
    // otherwise outlive us.
    misterplex::FpgaSpi::resumeStrandedMain();
    return exitReported(0, why, &player);
}
