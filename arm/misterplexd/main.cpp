// misterplexd — ARM-side daemon for MiSTerPlex.
// Phase 2: GDM + companion + FFmpeg → /dev/fb0 (FPGA scanout via MiSTer_fb).
// Phase 4: multi-server conf, auto next-episode, optional subtitle burn-in.

#include "companion.hpp"
#include "libmisterplex/coded_size.hpp"
#include "libmisterplex/conf_keys.hpp"
#include "libmisterplex/ffmpeg_vf.hpp"
#include "libmisterplex/osd_menu.hpp"
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
#include <unistd.h>
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

bool confTruthy(const std::string& v) { return misterplex::confTruthy(v); }

// All main-thread diagnostic lines go through here so a forgotten URL/token
// cannot land in misterplexd.log in cleartext.
void logDaemon(const std::string& s) {
    std::fprintf(stderr, "%s\n", misterplex::redactSensitive(s).c_str());
}

// Content tier (OSD O[4] / DECODE) is the product source of truth for the PMS
// ladder on each play. Re-apply the full named profile so profileName, quality,
// bitrate and H.264 caps track the tier — not only videoResolution.
misterplex::WeakLadder weakForContentResolution(const misterplex::WeakLadder& base,
                                                const misterplex::ContentResolution& res,
                                                bool bitrateExplicit) {
    misterplex::WeakLadder weak = base;
    const int keepBitrate = base.maxVideoBitrateKbps;
    if (!misterplex::applyPlexTranscodeProfile(res.label, weak)) {
        weak.profileName = "custom";
        weak.videoResolution = res.label;
        if (!bitrateExplicit)
            weak.maxVideoBitrateKbps = res.weakBitrateKbps;
    } else if (bitrateExplicit) {
        weak.maxVideoBitrateKbps = keepBitrate;
    }
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
    std::string name = misterplex::kPlayerDefaultName;
    std::string machineId = misterplex::kPlayerDefaultMachineId;
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
    // Defect A: YUV DDR present forces SkipIdentity→Always (see
    // ffmpegScaleModeForDdrYuvPresent) so native 480p never identity-skips.
    std::string ffmpegScaleMode = "skip_identity";
    std::string ffmpegSwsFlags; // empty = ffmpeg default when residual scale runs
    bool ffmpegScaleAssumeMatch = false;
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
    std::vector<std::string> servers;
    std::string defaultPms;
    int64_t skipForwardMs = 30000;
    int64_t skipBackMs = 10000;
    // Lab: --play-file PATH [--play-seconds N] plays a local file then exits (no GDM).
    std::string playFile;
    int playSeconds = 25;

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
                        "[--play-file PATH] [--play-seconds N]\n");
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
    std::string weakWhy;
    if (!misterplex::validateWeakLadder(weak, &weakWhy)) {
        std::fprintf(stderr, "misterplexd: invalid transcode profile (%s); falling back to 240p\n",
                     weakWhy.c_str());
        misterplex::applyPlexTranscodeProfile("240p", weak);
    }

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
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

    misterplex::MediaPlayer player;
    player.setFfmpegPath(ffmpeg);
    player.setDecodeSize(decodeSize);
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
                     lead.empty() ? "40(default)" : lead.c_str(),
                     drop.empty() ? "80(default)" : drop.c_str());
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
                 "FFMPEG_SCALE_ASSUME_MATCH=%s\n",
                 ffmpegScaleMode.c_str(),
                 ffmpegSwsFlags.empty() ? "(ffmpeg_default)" : ffmpegSwsFlags.c_str(),
                 ffmpegScaleAssumeMatch ? "1" : "0");
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
        if (!player.play(playFile, 0, {}, playSeconds * 1000LL)) {
            std::fprintf(stderr, "misterplexd: play-file failed\n");
            return 1;
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
            return 2;
        }
        std::fprintf(stderr,
                     "misterplexd: LAB play-file done frames=%lld presented=%lld recon=%lld "
                     "totalBytes=%lld\n",
                     static_cast<long long>(summary.rawFrames),
                     static_cast<long long>(summary.presentedFrames),
                     static_cast<long long>(summary.reconFrames),
                     static_cast<long long>(summary.totalBytes));
        return 0;
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
        plexId.product = misterplex::kPlayerProduct;
        plexId.version = misterplex::kPlayerVersion;
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
    std::atomic<bool> autoNextInFlight{false};
    // Monotonic play generation: supersede in-flight async resolve when a newer
    // playMedia/auto-next arrives (P4-SCRUB out-of-order bind race).
    std::atomic<uint64_t> playGen{0};

    auto contentResolutionForNextPlay = [&]() -> misterplex::ContentResolution {
        // Re-read apply gate each play: Auto may flip to LIVE after boot probe.
        if (player.osdApplyActive())
            return misterplex::contentResolutionFromOsdWord(player.lastOsdWord());
        return misterplex::contentResolutionFromCodedSize(decodeSize.width, decodeSize.height);
    };

    auto resolveAgainstServers = [&](const misterplex::PlayRequest& req,
                                     const std::string& preferredBase, int64_t off,
                                     const misterplex::WeakLadder& weakForPlay)
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
                                                 weakForPlay,
                                                 /*preferDirectH264=*/streamEnabled);
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
        const auto contentRes = contentResolutionForNextPlay();
        player.setDecodeSize(contentRes.width, contentRes.height);
        const auto weakForPlay =
            weakForContentResolution(weak, contentRes, weakBitrateExplicit);
        std::fprintf(stderr,
                     "misterplexd: content resolution=%s source=%s status_word=0x%04x "
                     "weak=%s bitrate=%d\n",
                     contentRes.label, player.osdApplyActive() ? "OSD O[4]" : "conf/--decode",
                     player.lastOsdWord(), weakForPlay.videoResolution.c_str(),
                     weakForPlay.maxVideoBitrateKbps);
        auto [resolved, base] = resolveAgainstServers(req, defaultPms, off, weakForPlay);

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
            resolved.transcoded = false;
        } else {
            std::fprintf(stderr, "misterplexd: resolved %s title=%s dur=%lld transcode=%d base=%s\n",
                         resolved.detail.c_str(), resolved.title.c_str(),
                         static_cast<long long>(resolved.durationMs),
                         resolved.transcoded ? 1 : 0, base.c_str());
        }

        // Expected delivery geometry for identity-scale decisions:
        // - universal transcode: PMS was asked for weakForPlay.videoResolution
        //   (not library Media WxH — that is the source asset, often 1080p).
        // - direct play: library Media/Stream WxH when known.
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
            deliveryBasis = "library_media";
        }
        player.setFfmpegScaleSourceSize(expectW, expectH);

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
        // Defect A: YUV DDR present forces SkipIdentity → Always (see
        // ffmpegScaleModeForDdrYuvPresent) so 480p never identity-skips.
        const auto confScaleMode = misterplex::parseFfmpegScaleMode(ffmpegScaleMode);
        const bool wantFpgaDdrCanvas =
            (presentMode == "fpga" || presentMode == "both");
        const auto scaleMode =
            wantFpgaDdrCanvas ? misterplex::ffmpegScaleModeForDdrYuvPresent(confScaleMode)
                              : confScaleMode;
        const auto codedGeom =
            wantFpgaDdrCanvas
                ? misterplex::ddrFrameGeometryForFpgaPresent(contentRes.width,
                                                              contentRes.height)
                : misterplex::makeDdrFrameGeometry(contentRes.width, contentRes.height);
        const int codedW = codedGeom.coded_width.get();
        const int codedH = codedGeom.coded_height.get();
        int armRescale = 1;
        if (scaleMode == misterplex::FfmpegScaleMode::Off) {
            armRescale = 0;
        } else if (scaleMode == misterplex::FfmpegScaleMode::SkipIdentity) {
            const bool knownMatch =
                expectW > 0 && expectH > 0 && expectW == codedW && expectH == codedH;
            const bool assumeMatch =
                ffmpegScaleAssumeMatch && !(expectW > 0 && expectH > 0);
            armRescale = (knownMatch || assumeMatch) ? 0 : 1;
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
        std::fprintf(stderr,
                     "misterplexd: GEOM requested_pms=%s expected_delivery=%s "
                     "delivery_basis=%s decode_target=%s content_tier=%s arm_rescale=%d "
                     "transcoded=%d sws=%s scale_mode=%s library_media=%s\n",
                     requestedPms.c_str(), expectStr.c_str(), deliveryBasis,
                     codedTarget.c_str(), decodeTarget.c_str(), armRescale,
                     resolved.transcoded ? 1 : 0,
                     ffmpegSwsFlags.empty() ? "(ffmpeg_default)" : ffmpegSwsFlags.c_str(),
                     misterplex::ffmpegScaleModeName(scaleMode), libraryStr.c_str());

        // Wire SOURCE_FPS / MATCH_SOURCE_HZ into play path (software Content FPS hint).
        {
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
            int fnum = resolved.fpsNum;
            int fden = resolved.fpsDen;
            misterplex::applyContentFpsConf(loadConf(confPath, "AV_CONTENT_FPS"), fnum, fden);
            player.setContentFpsRational(fnum, fden);
            std::fprintf(stderr, "misterplexd: content fps exact=%d/%d (pms frameRate=%s vfr=%s)\n",
                         fnum, fden,
                         resolved.frameRate.empty() ? "-" : resolved.frameRate.c_str(),
                         resolved.videoFrameRate.empty() ? "-" : resolved.videoFrameRate.c_str());
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

        misterplex::PmsTimelineSession timelineSession;
        timelineSession.baseUrl = base;
        timelineSession.token = bound.token.empty() ? confToken : bound.token;
        timelineSession.key = bound.key;
        timelineSession.ratingKey = bound.ratingKey;
        timelineSession.playQueueItemId = bound.playQueueItemId;
        timelineSession.containerKey = bound.containerKey;
        timelineSession.clientIdentifier = machineId;
        timelineSession.product = misterplex::kPlayerProduct;
        timelineSession.version = misterplex::kPlayerVersion;
        timelineSession.deviceName = name;
        pmsTimeline.beginSession(timelineSession, startAt, resolved.durationMs);

        // resolved.playable keeps the real token for FFmpeg; only the log line is scrubbed.
        logDaemon("misterplexd: PLAY " + misterplex::redactSensitive(resolved.playable) +
                  " off=" + std::to_string(startAt) +
                  " dur=" + std::to_string(resolved.durationMs));
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
            pmsTimeline.endSession(t, d);
            // Must not call player.play() on the media thread (join self). Schedule async.
            if (autoNextInFlight.exchange(true)) {
                comp.endMediaSession(t, d);
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
                    comp.endMediaSession(t, d);
            }).detach();
            return;
        }
        if (st == "stopped")
            pmsTimeline.endSession(t, d);
        else
            pmsTimeline.reportState(st, t, d);
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
    // seekGen + seekMu: serialize demux restarts and drop superseded offsets so a
    // late drained seekMs(old) cannot restart at 0 after a newer scrub plant.
    // Product STREAM=0 cast uses PMS universal with offset= baked into the URL.
    // Re-resolve + fresh play at the new offset (not FFmpeg -ss on a stale universal).
    // Local files / direct Parts still use player.seekMs → -ss.
    std::atomic<uint64_t> seekGen{0};
    std::mutex seekMu;
    auto seekAsync = [&](int64_t ms) {
        const uint64_t g = ++seekGen;
        std::thread([&, ms, g]() {
            std::lock_guard<std::mutex> lock(seekMu);
            if (g != seekGen.load())
                return; // superseded while waiting for prior seekMs
            try {
                misterplex::PlayRequest cur;
                {
                    std::lock_guard<std::mutex> sl(sessionMu);
                    cur = lastPlay;
                }
                const bool libraryKey =
                    !cur.key.empty() &&
                    (cur.key.rfind("/library", 0) == 0 || cur.key.find("library/metadata") != std::string::npos);
                if (libraryKey) {
                    cur.offsetMs = ms < 0 ? 0 : ms;
                    cur.offsetPresent = true;
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
                            seekAsync(0);
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
        return 1;
    }

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
                 "misterplexd: running name=%s id=%s port=%d pms=%s servers=%zu "
                 "decode_bank=%s decode_source=%s pms_request_geometry=%s "
                 "pms_bitrate_kbps=%d profile_name=%s h264=%s@L%d present=%s "
                 "auto_next=%d subs=%s\n",
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
    while (!g_stop.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        if (++tick % 3 != 0)
            continue;
        misterplex::FpgaSpi::resumeStrandedMain();
    }

    player.stop();
    pmsTimeline.stopAndFlush();
    plexTv.stop();
    comp.stop();
    // Last chance on the way out: a window leaked during teardown would
    // otherwise outlive us.
    misterplex::FpgaSpi::resumeStrandedMain();
    return 0;
}
