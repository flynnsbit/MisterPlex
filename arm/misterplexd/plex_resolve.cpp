#include "plex_resolve.hpp"

#include "libmisterplex/h264_fabric_stream_gate.hpp"
#include "libmisterplex/osd_menu.hpp"
#include "libmisterplex/pms_delivery_geom.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <sstream>
#include <vector>

namespace misterplex {
namespace {

std::string shellQuote(const std::string& s) {
    std::string o = "'";
    for (char c : s) {
        if (c == '\'')
            o += "'\\''";
        else
            o += c;
    }
    o += "'";
    return o;
}

std::string httpGet(const std::string& url, int timeoutSec = 15,
                    const std::string& extraHeaders = {}, bool defaultIdentity = true) {
    // Prefer curl (present on MiSTer); -k for plex.direct certs.
    std::ostringstream cmd;
    cmd << "curl -sS -g -k -L --http1.1 --connect-timeout 6 --max-time " << timeoutSec
        << " -H 'Accept: application/xml'";
    if (defaultIdentity) {
        cmd << " -H 'X-Plex-Client-Identifier: misterplex'"
            << " -H 'X-Plex-Product: Plex Web'"
            << " -H 'X-Plex-Version: 4.125.0'"
            << " -H 'X-Plex-Platform: Chrome'"
            << " -H 'X-Plex-Platform-Version: 120.0'"
            << " -H 'X-Plex-Device: Linux'"
            << " -H 'X-Plex-Device-Name: Chrome'"
            << " -H 'X-Plex-Client-Profile-Name: MiSTerPlex'"
            << " -H 'X-Plex-Model: bundled'"
            << " -H 'X-Plex-Provides: player'";
    }
    if (!extraHeaders.empty())
        cmd << extraHeaders;
    cmd << " " << shellQuote(url) << " 2>/dev/null";
    FILE* p = popen(cmd.str().c_str(), "r");
    if (!p)
        return {};
    std::string out;
    char buf[4096];
    while (fgets(buf, sizeof(buf), p))
        out += buf;
    pclose(p);
    return out;
}

std::string curlHeaderArgs(const std::vector<std::pair<std::string, std::string>>& headers) {
    std::ostringstream args;
    for (const auto& h : headers) {
        if (h.first.empty())
            continue;
        args << " -H " << shellQuote(h.first + ": " + h.second);
    }
    return args.str();
}

bool hasHeader(const std::vector<std::pair<std::string, std::string>>& headers,
               const char* name) {
    for (const auto& h : headers) {
        if (h.first == name)
            return true;
    }
    return false;
}

std::string makeSessionId() {
    static std::atomic<uint32_t> n{1};
    std::ostringstream o;
    o << "mplex-" << std::hex << (n.fetch_add(1) * 2654435761u);
    return o.str();
}

std::string hostOnly(const std::string& hostOrUrl) {
    std::string h = hostOrUrl;
    if (auto p = h.find("://"); p != std::string::npos)
        h = h.substr(p + 3);
    if (auto p = h.find('/'); p != std::string::npos)
        h = h.substr(0, p);
    if (auto p = h.find(':'); p != std::string::npos)
        h = h.substr(0, p);
    return h;
}

bool isUnreachableHost(const std::string& hostOrUrl) {
    const std::string h = hostOnly(hostOrUrl);
    if (h.rfind("172.17.", 0) == 0 || h.rfind("172.18.", 0) == 0 ||
        h.rfind("172.20.", 0) == 0 || h.rfind("172.21.", 0) == 0)
        return true;
    if (h.find("172-17-") != std::string::npos || h.find("172-18-") != std::string::npos ||
        h.find("172-20-") != std::string::npos || h.find("172-21-") != std::string::npos)
        return true;
    return false;
}

std::string attr(const std::string& xml, const char* tag, const char* name) {
    // First occurrence of <tag ... name="..."
    const std::string open = std::string("<") + tag;
    auto tpos = xml.find(open);
    if (tpos == std::string::npos)
        return {};
    auto end = xml.find('>', tpos);
    if (end == std::string::npos)
        return {};
    const std::string slice = xml.substr(tpos, end - tpos);
    const std::string key = std::string(name) + "=\"";
    auto p = slice.find(key);
    if (p == std::string::npos)
        return {};
    p += key.size();
    auto e = slice.find('"', p);
    if (e == std::string::npos)
        return {};
    return slice.substr(p, e - p);
}

// Attr from a free-form XML slice (first name="..." only).
std::string attrIn(const std::string& slice, const char* name) {
    const std::string key = std::string(name) + "=\"";
    auto p = slice.find(key);
    if (p == std::string::npos)
        return {};
    p += key.size();
    auto e = slice.find('"', p);
    if (e == std::string::npos)
        return {};
    return slice.substr(p, e - p);
}

std::string lowerCopy(std::string s) {
    for (char& c : s)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// H.264/AVC direct Part is preferred for STREAM host CAVLC recon (Baseline/Main).
bool videoCodecIsH264(const std::string& codecRaw) {
    const std::string c = lowerCopy(codecRaw);
    if (c.empty())
        return false;
    return c.find("h264") != std::string::npos || c.find("avc") != std::string::npos ||
           c.find("x264") != std::string::npos;
}

} // namespace

const std::vector<PlexTranscodeProfile>& plexTranscodeProfiles() {
    static const std::vector<PlexTranscodeProfile> profiles = [] {
        const auto p240 = contentResolutionFor240p();
        const auto p360 = contentResolutionFor360pFabric720p();
        const auto p480 = contentResolutionFor480p();
        const auto p540 = contentResolutionFor540pFabric720p();
        const auto p720 = contentResolutionFor720p();
        return std::vector<PlexTranscodeProfile>{
            {"240p", p240.label, p240.weakBitrateKbps, 40, "baseline", 30},
            // 360p: motion 720p glass (exact 2×). maxBR knee 1000; weak 1500.
            // No fps Extra cap — pass-through 29.97 is the point of this tier.
            {"360p", p360.label, p360.weakBitrateKbps, 50, "baseline", kPlex360pH264Level},
            {"480p", p480.label, p480.weakBitrateKbps, 60, "baseline", 30},
            // 540p: shippable 720p *glass* source (parent decode+copy PASS). Match
            // name "540p" / "960x540". L3.1 required (MaxFS). Bitrate = quality default.
            {"540p", p540.label, p540.weakBitrateKbps, 65, "baseline", kPlex540pH264Level},
            // quality 70: lab decision matrix used 60–70; bitrate is the geometry gate.
            // True 720p *source* — ARM+CPU copy fails; DMA upgrade path.
            {"720p", p720.label, p720.weakBitrateKbps, 70, "baseline", kPlex720pH264Level},
        };
    }();
    return profiles;
}

std::string normalizePlexBase(const std::string& raw) {
    std::string s = raw;
    // trim
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t' || s.front() == '\r' ||
                          s.front() == '\n'))
        s.erase(s.begin());
    while (!s.empty() && (s.back() == ' ' || s.back() == '\t' || s.back() == '\r' ||
                          s.back() == '\n' || s.back() == '/'))
        s.pop_back();
    if (s.empty())
        return {};
    if (s.find("://") == std::string::npos) {
        // bare host or host:port → assume http
        s = "http://" + s;
    }
    // strip trailing slash again after scheme
    while (!s.empty() && s.back() == '/')
        s.pop_back();
    // If no port in authority, default PMS :32400 (skip if user omitted intentionally
    // for reverse-proxy with scheme-only host — rare; LAN always wants 32400).
    auto scheme = s.find("://");
    if (scheme != std::string::npos) {
        auto hostStart = scheme + 3;
        auto slash = s.find('/', hostStart);
        std::string auth =
            (slash == std::string::npos) ? s.substr(hostStart) : s.substr(hostStart, slash - hostStart);
        // IPv6 in brackets or host:port
        bool hasPort = false;
        if (!auth.empty() && auth.front() == '[') {
            auto br = auth.find(']');
            hasPort = (br != std::string::npos && br + 1 < auth.size() && auth[br + 1] == ':');
        } else {
            hasPort = (auth.rfind(':') != std::string::npos);
        }
        if (!hasPort && !auth.empty())
            s = s.substr(0, hostStart) + auth + ":32400" +
                (slash == std::string::npos ? std::string() : s.substr(slash));
    }
    return s;
}

std::vector<std::string> parsePlexServerList(const std::string& csvOrSingle) {
    std::vector<std::string> out;
    std::string cur;
    auto flush = [&]() {
        auto n = normalizePlexBase(cur);
        cur.clear();
        if (n.empty())
            return;
        for (const auto& e : out) {
            if (e == n)
                return;
        }
        out.push_back(n);
    };
    for (char c : csvOrSingle) {
        if (c == ',' || c == ';' || c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            flush();
        } else {
            cur.push_back(c);
        }
    }
    flush();
    return out;
}

std::vector<std::string> mergePlexServers(const std::string& serversCsv,
                                          const std::vector<std::string>& baseLines) {
    std::vector<std::string> out = parsePlexServerList(serversCsv);
    for (const auto& line : baseLines) {
        for (const auto& n : parsePlexServerList(line)) {
            bool seen = false;
            for (const auto& e : out) {
                if (e == n) {
                    seen = true;
                    break;
                }
            }
            if (!seen)
                out.push_back(n);
        }
    }
    return out;
}

std::string urlDecode(const std::string& in) {
    std::string out;
    out.reserve(in.size());
    for (size_t i = 0; i < in.size(); ++i) {
        if (in[i] == '%' && i + 2 < in.size() && std::isxdigit(static_cast<unsigned char>(in[i + 1])) &&
            std::isxdigit(static_cast<unsigned char>(in[i + 2]))) {
            auto hex = in.substr(i + 1, 2);
            out.push_back(static_cast<char>(std::strtol(hex.c_str(), nullptr, 16)));
            i += 2;
        } else if (in[i] == '+') {
            out.push_back(' ');
        } else {
            out.push_back(in[i]);
        }
    }
    return out;
}

std::string urlEncodeQuery(const std::string& s) {
    std::ostringstream o;
    o << std::uppercase;
    for (unsigned char c : s) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~')
            o << static_cast<char>(c);
        else {
            o << '%' << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(c)
              << std::dec;
        }
    }
    return o.str();
}

namespace {

bool parseResolution(const std::string& res, int& w, int& h) {
    w = h = 0;
    return std::sscanf(res.c_str(), "%dx%d", &w, &h) == 2 && w > 0 && h > 0;
}

} // namespace

bool applyPlexTranscodeProfile(const std::string& nameOrResolution, WeakLadder& weak) {
    for (const auto& p : plexTranscodeProfiles()) {
        if (nameOrResolution == p.name || nameOrResolution == p.videoResolution) {
            weak.profileName = p.name;
            weak.videoResolution = p.videoResolution;
            weak.maxVideoBitrateKbps = p.maxVideoBitrateKbps;
            weak.videoQuality = p.videoQuality;
            weak.videoCodec = "h264";
            weak.audioCodec = "aac";
            weak.h264Profile = p.h264Profile;
            weak.h264Level = p.h264Level;
            // 540p serial budget fails at 29.97; pin PMS to 24 via Extra (measured).
            // 360p leaves 0 so 29.97 pass-through (motion tier / no judder).
            // Other tiers leave 0 (MiSTerPlex.xml UpperBound 30 allows pass-through).
            weak.maxVideoFrameRate =
                (p.name == "540p") ? kPlex540pMaxVideoFrameRate : 0;
            return true;
        }
    }
    return false;
}

bool validateWeakLadder(const WeakLadder& weak, std::string* why) {
    int w = 0, h = 0;
    auto fail = [&](const std::string& msg) {
        if (why)
            *why = msg;
        return false;
    };
    if (!parseResolution(weak.videoResolution, w, h))
        return fail("videoResolution must be WxH");
    if (weak.videoCodec != "h264")
        return fail("videoCodec must be h264");
    if (weak.audioCodec != "aac")
        return fail("audioCodec must be aac");
    if (weak.h264Profile != kPlexH264ProfilePin)
        return fail("H.264 profile must be baseline (fabric CAVLC pin; no High/CABAC)");
    const bool isPath720 = (w == kPlex720pCodedWidth.get() && h == kPlex720pCodedHeight.get());
    const bool isPath540 = (w == kPlex540pCodedWidth.get() && h == kPlex540pCodedHeight.get());
    const bool isPath360 = (w == kPlex360pCodedWidth.get() && h == kPlex360pCodedHeight.get());
    // Product decoder ceiling is L3.0 (parent rk=7 SoT). 540p still allows L3.1
    // request pin for MaxFS on that tier only; 720p is L3.0.
    const int maxLevel = isPath540 ? kPlex540pH264Level : 30;
    if (weak.h264Level > maxLevel) {
        if (isPath540)
            return fail("H.264 level must not exceed 3.1 for the 540p path tier");
        return fail("H.264 level must not exceed 3.0 for the current decoder");
    }
    // Geometry ceiling is exact path-720 (1280x720) — lifted from the old
    // 640x480-only table on main. Do NOT delete this guard (gate self-weakening).
    if (w > kPlex720pCodedWidth.get() || h > kPlex720pCodedHeight.get())
        return fail("built-in path profiles stop at " +
                    std::to_string(kPlex720pCodedWidth.get()) + "x" +
                    std::to_string(kPlex720pCodedHeight.get()));
    if (w >= kPlex480pCodedWidth.get() || h >= kPlex480pCodedHeight.get() || isPath360) {
        // Legacy DDR max 640x480. Exact path-720/540/360 are the only allowed
        // geometries above / outside the 480 canvas contract.
        if (w > kDdrFrameStoreMaxWidth.get() || h > kDdrFrameStoreMaxHeight.get()) {
            if (!isPath720 && !isPath540 && !isPath360)
                return fail("current DDR-backed profiles stop at " +
                            std::to_string(kDdrFrameStoreMaxWidth.get()) + "x" +
                            std::to_string(kDdrFrameStoreMaxHeight.get()) +
                            " (path 360p=640x360, 540p=960x540 or 720p=1280x720 only)");
        }
        // 480p bitrate floors stay soft (recommendedMin only). A hard 2000 reject
        // once forced PMS above slow links and silently fell the ladder to 240p.
    }
    // Geometry knees (lab-measured): below these PMS returns the wrong *raster*
    // (720→720x404, 540→720x404, 360→sub-360), not merely a softer picture.
    // Enforce so WEAK_BITRATE cannot silently re-open the trap.
    if (isPath720 && weak.maxVideoBitrateKbps < kPmsTrue720pMinBitrateKbpsMeasured)
        return fail("720p maxVideoBitrate must be >=" +
                    std::to_string(kPmsTrue720pMinBitrateKbpsMeasured) +
                    " (lab knee; lower yields 720x404 not 1280x720)");
    if (isPath540 && weak.maxVideoBitrateKbps < kPmsTrue540pMinBitrateKbpsMeasured)
        return fail("540p maxVideoBitrate must be >=" +
                    std::to_string(kPmsTrue540pMinBitrateKbpsMeasured) +
                    " (lab knee; lower yields 720x404 not 960x540)");
    if (isPath360 && weak.maxVideoBitrateKbps < kPmsTrue360pMinBitrateKbpsMeasured)
        return fail("360p maxVideoBitrate must be >=" +
                    std::to_string(kPmsTrue360pMinBitrateKbpsMeasured) +
                    " (lab knee; lower yields sub-360 delivery)");
    if (weak.videoQuality <= 0 || weak.maxVideoBitrateKbps <= 0)
        return fail("videoQuality and maxVideoBitrate must be positive");
    return true;
}

int recommendedMinVideoBitrateKbps(const WeakLadder& weak) {
    int w = 0, h = 0;
    if (!parseResolution(weak.videoResolution, w, h))
        return 0;
    // Defaults from osd_menu.hpp ladder constants — quality/ARM-margin heuristics,
    // not H.264 level contracts. 720p floor is measured (true 1280x720 needs ≥3100).
    if (w == kPlex720pCodedWidth.get() && h == kPlex720pCodedHeight.get())
        return kPlex720pWeakBitrateKbps;
    if (w == kPlex540pCodedWidth.get() && h == kPlex540pCodedHeight.get())
        return kPlex540pWeakBitrateKbps;
    if (w == kPlex360pCodedWidth.get() && h == kPlex360pCodedHeight.get())
        return kPlex360pWeakBitrateKbps;
    // 480p default = kPlex480pWeakBitrateKbps (2000).
    if (w >= kPlex480pCodedWidth.get() || h >= kPlex480pCodedHeight.get())
        return kPlex480pWeakBitrateKbps;
    // Legacy 240p path used a soft floor of 750 below the 1000 default.
    return 750;
}

bool weakLadderBitrateBelowRecommended(const WeakLadder& weak, std::string* detail) {
    const int floor = recommendedMinVideoBitrateKbps(weak);
    if (floor <= 0 || weak.maxVideoBitrateKbps <= 0)
        return false;
    if (weak.maxVideoBitrateKbps >= floor)
        return false;
    if (detail) {
        *detail = "maxVideoBitrateKbps=" + std::to_string(weak.maxVideoBitrateKbps) +
                  " < recommended_min=" + std::to_string(floor) +
                  " for videoResolution=" + weak.videoResolution +
                  " (quality/link heuristic — explicit WEAK_BITRATE wins; not a decoder fail)";
    }
    return true;
}

int nextLowerLadderBitrateKbps(int currentKbps) {
    // Fixed descending steps — no link-speed constant. Geometry unchanged.
    // 4000/3500/3100: path-720p universal (lab: 3000→720x404; 3100→1280x720).
    // 1500 is the parent decode-optimal content/DP tier for already-1280x720 —
    // stepping to 1500 on universal loses true 720 geometry.
    // Absolute floor 400 keeps validateWeakLadder positive without inventing capacity.
    static constexpr int kSteps[] = {4000, 3500, 3100, 3000, 2500, 2000, 1500, 1000, 750, 500, 400};
    if (currentKbps <= kSteps[sizeof(kSteps) / sizeof(kSteps[0]) - 1])
        return 0; // already at floor — cannot step
    for (int s : kSteps) {
        if (s < currentKbps)
            return s;
    }
    return 0;
}

bool starveStepdownReady(int consecutiveStarvedSamples, int minConsecutive) {
    if (minConsecutive <= 0)
        minConsecutive = kStarveStepdownMinConsecutive;
    return consecutiveStarvedSamples >= minConsecutive;
}

int applyLinkCapacityCapKbps(int requestedKbps, int capacityKbps, int headroomPct) {
    if (requestedKbps <= 0)
        return requestedKbps;
    if (capacityKbps <= 0)
        return requestedKbps; // unset — do not invent capacity
    int pct = headroomPct;
    if (pct <= 0 || pct > 100)
        pct = kLinkCapacityHeadroomPctDefault;
    // Integer kbps; parent measured ~1153 kbit/s goodput — never hardcoded here.
    int cap = (capacityKbps * pct) / 100;
    if (cap < 1)
        cap = 1;
    return requestedKbps < cap ? requestedKbps : cap;
}

std::string plexClientProfileFrameRateExtra(const WeakLadder& weak) {
    if (weak.maxVideoFrameRate <= 0)
        return {};
    // Lab PMS (rk142 29.97 source @ 960x540): this form yields decision
    // frameRate=24 and ffprobe r_frame_rate=24/1. Query maxFrameRate= is ignored.
    std::ostringstream o;
    o << "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.frameRate"
      << "&value=" << weak.maxVideoFrameRate << "&isRequired=true)+"
      << "add-limitation(scope=videoTranscodeTarget&scopeName=h264&scopeType=videoCodec"
      << "&context=streaming&protocol=http&type=upperBound&name=video.frameRate"
      << "&value=" << weak.maxVideoFrameRate << "&isRequired=true)";
    return o.str();
}

std::string plexClientProfileExtra(const WeakLadder& weak) {
    int w = 0, h = 0;
    parseResolution(weak.videoResolution, w, h);
    std::ostringstream o;
    o << "add-transcode-target(type=videoProfile&context=streaming&protocol=http"
      // PMS universal/start.mp4 is the HTTP entrypoint, but its working
      // streaming transcode target is TS; advertising mp4 here can make PMS
      // return an empty video/mp4 response.
      << "&container=mpegts&videoCodec=" << weak.videoCodec << "&audioCodec=" << weak.audioCodec
      << "&replace=true)+"
      << "add-transcode-target-audio-codec(type=videoProfile&context=streaming&protocol=http"
      << "&audioCodec=" << weak.audioCodec << "&replace=true)+"
      << "add-limitation(scope=videoCodec&scopeName=h264&type=match&name=video.profile"
      << "&list=" << kPlexH264ProfilePin << "&replace=true)+"
      << "add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.level"
      << "&value=" << weak.h264Level << "&replace=true)+"
      << "add-limitation(scope=videoTranscodeTarget&scopeName=h264&scopeType=videoCodec"
      << "&context=streaming&protocol=http&type=match&name=video.profile"
      << "&list=" << kPlexH264ProfilePin << "&isRequired=true)+"
      << "add-limitation(scope=videoTranscodeTarget&scopeName=h264&scopeType=videoCodec"
      << "&context=streaming&protocol=http&type=upperBound&name=video.level"
      << "&value=" << weak.h264Level << "&isRequired=true)";
    if (w > 0 && h > 0) {
        o << "+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.width"
          << "&value=" << w << "&replace=true)"
          << "+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.height"
          << "&value=" << h << "&replace=true)";
    }
    const std::string fr = plexClientProfileFrameRateExtra(weak);
    if (!fr.empty())
        o << "+" << fr;
    return o.str();
}

std::string plexClientCapabilities(const WeakLadder& weak) {
    int w = 0, h = 0;
    parseResolution(weak.videoResolution, w, h);
    std::ostringstream o;
    o << "protocols=http-streaming-video,http-mp2t-video;"
      << "videoDecoders=h264{profile:" << kPlexH264ProfilePin << "&resolution:" << w << "x" << h
      << "&level:" << weak.h264Level << "};"
      << "audioDecoders=" << weak.audioCodec << "{channels:2}";
    return o.str();
}

std::string buildUniversalTranscodeUrl(const std::string& base,
                                       const std::string& metadataKey,
                                       const std::string& token,
                                       const std::string& session,
                                       int64_t offsetMs,
                                       const WeakLadder& weak) {
    std::ostringstream q;
    // videoResolution=WxH is a CEILING for PMS aspect-preserving square-pixel
    // fit, not an exact coded size. There is no universal query param that pins
    // exact delivered height (lab decision matrix, RK6). Anamorphic 16:9 DAR
    // sources fit to ~624x350 inside 624x480. directPlay is forced off here;
    // STREAM preferDirectH264 uses the Part path instead (can keep coded 624x480).
    q << base << "/video/:/transcode/universal/start.mp4"
      << "?hasMDE=1"
      << "&path=" << urlEncodeQuery(metadataKey)
      << "&mediaIndex=0&partIndex=0"
      << "&protocol=http&fastSeek=1"
      << "&directPlay=0&directStream=0"
      << "&subtitleSize=100&audioBoost=100&location=lan&copyts=1"
      << "&session=" << urlEncodeQuery(session)
      << "&videoQuality=" << weak.videoQuality
      << "&videoResolution=" << urlEncodeQuery(weak.videoResolution)
      << "&maxVideoBitrate=" << weak.maxVideoBitrateKbps
      << "&videoCodec=" << urlEncodeQuery(weak.videoCodec)
      << "&audioCodec=" << urlEncodeQuery(weak.audioCodec)
      // Request preference only (lab PMS may ignore — measured High on rk118/119).
      // Bitstream gate routes Refuse* → ARM FFmpeg; do not treat pin as delivery.
      << "&videoProfile=" << urlEncodeQuery(kPlexH264ProfilePin)
      << "&videoLevel=" << weak.h264Level;
    // Phase 4: PMS-side burn-in (preferred over dual-A9 FFmpeg subtitles filter).
    if (weak.burnSubtitles) {
        q << "&subtitles=burn";
        if (weak.subtitleStreamId >= 0)
            q << "&subtitleStreamID=" << weak.subtitleStreamId;
    }
    // PMS universal offset is SECONDS (companion / scrubber use ms).
    const int64_t offSec = universalOffsetSeconds(offsetMs);
    if (offSec > 0)
        q << "&offset=" << offSec;
    if (!token.empty())
        q << "&X-Plex-Token=" << urlEncodeQuery(token);
    return q.str();
}

std::string plexFfmpegHeaders(const std::string& sessionId, const std::string& token) {
    return plexFfmpegHeaders(sessionId, token, WeakLadder{});
}

std::string plexFfmpegHeaders(const std::string& sessionId, const std::string& token,
                              const WeakLadder& weak) {
    std::ostringstream o;
    o << "X-Plex-Client-Identifier: misterplex\r\n"
      << "X-Plex-Product: Plex Web\r\n"
      << "X-Plex-Version: 4.125.0\r\n"
      << "X-Plex-Platform: Chrome\r\n"
      << "X-Plex-Platform-Version: 120.0\r\n"
      << "X-Plex-Device: Linux\r\n"
      << "X-Plex-Device-Name: Chrome\r\n"
      << "X-Plex-Client-Profile-Name: " << weak.clientProfileName << "\r\n"
      << "X-Plex-Model: bundled\r\n"
      << "X-Plex-Provides: player\r\n";
    // With the server-side MiSTerPlex.xml profile installed, a *full* Profile-Extra
    // is counterproductive: it overrides the XML transcode target and drops the
    // VideoEncodeFlags that force Baseline/CAVLC/ref=1.
    // Frame-rate-only Extra is the measured exception: caps 29.97→24 while
    // retaining Constrained Baseline (rk142 + MiSTerPlex, 2026-08-03).
    if (weak.clientProfileName != "MiSTerPlex") {
        o << "X-Plex-Client-Capabilities: " << plexClientCapabilities(weak) << "\r\n"
          << "X-Plex-Client-Profile-Extra: " << plexClientProfileExtra(weak) << "\r\n";
    } else if (weak.maxVideoFrameRate > 0) {
        o << "X-Plex-Client-Profile-Extra: " << plexClientProfileFrameRateExtra(weak)
          << "\r\n";
    }
    o << "X-Plex-Session-Identifier: " << sessionId << "\r\n";
    if (!token.empty())
        o << "X-Plex-Token: " << token << "\r\n";
    return o.str();
}

bool plexClientIdentityHeadersComplete(const std::string& headerBlockCrLf) {
    // Parent-measured: omitting the full client identity set → HTTP 400 empty body
    // on universal/decision. Detect incompleteness rather than treating empty as
    // "try another path" that might silently force-xcode.
    static const char* kRequired[] = {
        "X-Plex-Client-Identifier:", "X-Plex-Product:", "X-Plex-Version:",
        "X-Plex-Platform:",         "X-Plex-Device:",  "X-Plex-Device-Name:",
        "X-Plex-Client-Profile-Name:",
    };
    for (const char* need : kRequired) {
        if (headerBlockCrLf.find(need) == std::string::npos)
            return false;
    }
    return true;
}

std::string plexThinClientIdentityHeadersForTest(const std::string& sessionId,
                                                 const std::string& token) {
    // Deliberately incomplete — only session (+ optional token). Parent 400 trap.
    std::ostringstream o;
    o << "X-Plex-Session-Identifier: " << sessionId << "\r\n";
    if (!token.empty())
        o << "X-Plex-Token: " << token << "\r\n";
    return o.str();
}

std::string buildUniversalDecisionUrl(const std::string& base, const std::string& metadataKey,
                                      const std::string& token, const std::string& session,
                                      const WeakLadder& weak, bool allow_direct) {
    std::ostringstream q;
    q << base << "/video/:/transcode/universal/decision"
      << "?hasMDE=1"
      << "&path=" << urlEncodeQuery(metadataKey)
      << "&mediaIndex=0&partIndex=0"
      << "&protocol=http&fastSeek=1"
      << (allow_direct ? "&directPlay=1&directStream=1" : "&directPlay=0&directStream=0")
      << "&location=lan"
      << "&session=" << urlEncodeQuery(session)
      << "&videoQuality=" << weak.videoQuality
      << "&videoResolution=" << urlEncodeQuery(weak.videoResolution)
      << "&maxVideoBitrate=" << weak.maxVideoBitrateKbps
      << "&videoCodec=" << urlEncodeQuery(weak.videoCodec)
      << "&audioCodec=" << urlEncodeQuery(weak.audioCodec)
      << "&videoProfile=" << urlEncodeQuery(kPlexH264ProfilePin)
      << "&videoLevel=" << weak.h264Level;
    if (!token.empty())
        q << "&X-Plex-Token=" << urlEncodeQuery(token);
    return q.str();
}

std::string plexParseDecisionAttr(const std::string& decisionXml) {
    // Prefer explicit decision="..." anywhere in the payload (VideoStream/Media).
    const std::string key = "decision=\"";
    auto p = decisionXml.find(key);
    if (p == std::string::npos)
        return {};
    p += key.size();
    auto e = decisionXml.find('"', p);
    if (e == std::string::npos || e <= p)
        return {};
    std::string s = decisionXml.substr(p, e - p);
    for (char& c : s)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

bool plexDecisionXmlIsDirectPlay(const std::string& decisionXml) {
    return plexParseDecisionAttr(decisionXml) == "directplay";
}

bool plexDecisionXmlIsTranscode(const std::string& decisionXml) {
    return plexParseDecisionAttr(decisionXml) == "transcode";
}

bool plexHttpGetNoBody(const std::string& url,
                       const std::vector<std::pair<std::string, std::string>>& headers,
                       int timeoutSec) {
    const bool defaultIdentity = !hasHeader(headers, "X-Plex-Client-Identifier");
    const std::string body = httpGet(url, timeoutSec, curlHeaderArgs(headers), defaultIdentity);
    return !body.empty();
}

std::string buildPlexBase(const std::string& protocol, const std::string& address,
                          const std::string& port, const std::string& lanFallback) {
    std::string addr = urlDecode(address);
    std::string proto = protocol.empty() ? "http" : protocol;
    std::string p = port.empty() ? "32400" : port;
    if (addr.empty() || isUnreachableHost(addr)) {
        if (!lanFallback.empty() && !isUnreachableHost(lanFallback)) {
            addr = lanFallback;
            // Prefer plain http for private LAN
            if (addr.find("://") == std::string::npos)
                return "http://" + addr + ":" + p;
            return addr;
        }
        return {};
    }
    // address may already be host:port or host
    if (addr.find("://") != std::string::npos)
        return addr;
    // plex.direct host often has embedded dashes; keep as-is
    if (addr.find(':') != std::string::npos)
        return proto + "://" + addr;
    return proto + "://" + addr + ":" + p;
}

bool ensureUniversalDecision(const std::string& startUrl, const std::string& sessionId,
                             const std::string& token) {
    return ensureUniversalDecision(startUrl, sessionId, token, WeakLadder{});
}

bool ensureUniversalDecision(const std::string& startUrl, const std::string& sessionId,
                             const std::string& token, const WeakLadder& weak) {
    if (startUrl.find("/video/:/transcode/universal/") == std::string::npos)
        return true;
    // Derive base + path from start URL
    auto pathPos = startUrl.find("/video/:/transcode/universal/start");
    if (pathPos == std::string::npos)
        return true;
    const std::string base = startUrl.substr(0, pathPos);
    // Extract path= from query
    auto pathEq = startUrl.find("path=");
    if (pathEq == std::string::npos)
        return true;
    pathEq += 5;
    auto pathEnd = startUrl.find('&', pathEq);
    std::string path = startUrl.substr(pathEq, pathEnd == std::string::npos ? std::string::npos
                                                                             : pathEnd - pathEq);

    // Mirror ladder params from start URL when present
    auto qparam = [&](const char* name) -> std::string {
        std::string key = std::string(name) + "=";
        auto p = startUrl.find(key);
        if (p == std::string::npos)
            return {};
        p += key.size();
        auto e = startUrl.find('&', p);
        return startUrl.substr(p, e == std::string::npos ? std::string::npos : e - p);
    };
    std::string vq = qparam("videoQuality");
    if (vq.empty())
        vq = "40";
    std::string vres = qparam("videoResolution");
    if (vres.empty())
        vres = "320x240";
    std::string br = qparam("maxVideoBitrate");
    if (br.empty())
        br = std::to_string(weak.maxVideoBitrateKbps);
    std::string vcodec = qparam("videoCodec");
    if (vcodec.empty())
        vcodec = weak.videoCodec;
    std::string acodec = qparam("audioCodec");
    if (acodec.empty())
        acodec = weak.audioCodec;
    // Always pin Baseline on the decision URL — ignore query overrides that
    // would request High/Main (fabric has no CABAC).
    std::string vprofile = kPlexH264ProfilePin;
    std::string vlevel = qparam("videoLevel");
    if (vlevel.empty())
        vlevel = std::to_string(weak.h264Level);

    std::ostringstream decisionUrl;
    decisionUrl << base << "/video/:/transcode/universal/decision?hasMDE=1&path=" << path
                << "&mediaIndex=0&partIndex=0&protocol=http&fastSeek=1&directPlay=0&directStream=0"
                << "&location=lan&session=" << urlEncodeQuery(sessionId)
                << "&videoQuality=" << vq << "&videoResolution=" << vres
                << "&maxVideoBitrate=" << br
                << "&videoCodec=" << vcodec << "&audioCodec=" << acodec
                << "&videoProfile=" << vprofile << "&videoLevel=" << vlevel;
    if (!token.empty())
        decisionUrl << "&X-Plex-Token=" << urlEncodeQuery(token);

    std::vector<std::pair<std::string, std::string>> decisionHeaders = {
        {"X-Plex-Session-Identifier", sessionId},
        {"X-Plex-Client-Profile-Name", weak.clientProfileName},
    };
    if (weak.clientProfileName != "MiSTerPlex") {
        decisionHeaders.push_back({"X-Plex-Client-Capabilities", plexClientCapabilities(weak)});
        decisionHeaders.push_back({"X-Plex-Client-Profile-Extra", plexClientProfileExtra(weak)});
    } else if (weak.maxVideoFrameRate > 0) {
        decisionHeaders.push_back(
            {"X-Plex-Client-Profile-Extra", plexClientProfileFrameRateExtra(weak)});
    }
    std::ostringstream sessHdr;
    sessHdr << curlHeaderArgs(decisionHeaders);
    const std::string body = httpGet(decisionUrl.str(), 20, sessHdr.str());
    if (body.empty())
        return false;
    if (body.find("unable to find a matching profile") != std::string::npos)
        return false;
    return body.find("MediaContainer") != std::string::npos ||
           body.find("transcodeDecisionCode") != std::string::npos;
}

bool mediaVideoIsH264(const std::string& plexMetadataXml) {
    if (plexMetadataXml.empty())
        return false;
    // Prefer Stream video codec when present; else Media@videoCodec.
    size_t pos = 0;
    while ((pos = plexMetadataXml.find("<Stream", pos)) != std::string::npos) {
        auto end = plexMetadataXml.find('>', pos);
        if (end == std::string::npos)
            break;
        const std::string tag = plexMetadataXml.substr(pos, end - pos);
        // PMS uses streamType="1" (video) and/or type="video"
        const bool isVideo = tag.find("streamType=\"1\"") != std::string::npos ||
                             tag.find("type=\"video\"") != std::string::npos;
        if (isVideo) {
            auto c = attrIn(tag, "codec");
            if (c.empty())
                c = attrIn(tag, "codecID");
            if (videoCodecIsH264(c))
                return true;
        }
        pos = end + 1;
    }
    return videoCodecIsH264(attr(plexMetadataXml, "Media", "videoCodec"));
}

ResolveResult resolvePlayTarget(const std::string& rawKeyOrPath, const std::string& plexBase,
                                const std::string& token, int64_t offsetMs, bool weakAlways,
                                const WeakLadder& weak, bool preferDirectH264) {
    ResolveResult r;
    std::string key = urlDecode(rawKeyOrPath);
    if (key.empty() || key == "test" || key == "testsrc") {
        r.ok = true;
        r.playable = "testsrc";
        r.detail = "test pattern";
        r.durationMs = 120000;
        r.sourceFpsHint = 30;
        r.fpsNum = 30;
        r.fpsDen = 1;
        return r;
    }

    // Direct http(s) or absolute non-library path
    if (key.rfind("http://", 0) == 0 || key.rfind("https://", 0) == 0) {
        r.ok = true;
        r.playable = key;
        r.detail = "direct URL";
        return r;
    }
    if (!key.empty() && key[0] == '/' && key.rfind("/library", 0) != 0 &&
        key.rfind("/playQueues", 0) != 0) {
        r.ok = true;
        r.playable = key;
        r.detail = "local path";
        return r;
    }

    // Normalize metadata key
    if (key.rfind("/library", 0) != 0 && key.find("library") != std::string::npos) {
        // sometimes "library/metadata/N"
        if (key[0] != '/')
            key = "/" + key;
    }

    if (plexBase.empty()) {
        r.detail = "no PMS base for key=" + key;
        return r;
    }
    if (token.empty()) {
        r.detail = "no token for key=" + key;
        // Still try without token (local unauth servers)
    }

    // Fetch metadata for title/duration/viewOffset
    std::string metaUrl = plexBase + key;
    if (metaUrl.find('?') == std::string::npos)
        metaUrl += "?";
    else
        metaUrl += "&";
    if (!token.empty())
        metaUrl += "X-Plex-Token=" + urlEncodeQuery(token);
    const std::string xml = httpGet(metaUrl, 12);
    // A 404 or 401 from PMS still returns a BODY (an HTML error page), so
    // "response is not empty" does not mean "item exists". Without this check a
    // ratingKey that was deleted or renumbered by a library re-scan sails
    // through every branch below, finds no Part, and lands on the test pattern —
    // which looks like a playback bug instead of a missing item, and silently
    // invalidates any measurement taken against it.
    const bool metaFound = xml.find("<MediaContainer") != std::string::npos;
    if (metaFound) {
        r.title = attr(xml, "Video", "title");
        if (r.title.empty())
            r.title = attr(xml, "Directory", "title");
        auto d = attr(xml, "Video", "duration");
        if (d.empty())
            d = attr(xml, "Media", "duration");
        if (!d.empty())
            r.durationMs = std::strtoll(d.c_str(), nullptr, 10);
        auto vo = attr(xml, "Video", "viewOffset");
        if (!vo.empty())
            r.viewOffsetMs = std::strtoll(vo.c_str(), nullptr, 10);
        r.ratingKey = attr(xml, "Video", "ratingKey");
        // Match-source-Hz / Content FPS: Media@videoFrameRate + video Stream@frameRate
        r.videoFrameRate = attr(xml, "Media", "videoFrameRate");
        if (r.videoFrameRate.empty())
            r.videoFrameRate = attr(xml, "Video", "videoFrameRate");
        // Fallback: any videoFrameRate="..." in the metadata payload
        if (r.videoFrameRate.empty()) {
            const std::string key = "videoFrameRate=\"";
            auto p = xml.find(key);
            if (p != std::string::npos) {
                p += key.size();
                auto e = xml.find('"', p);
                if (e != std::string::npos)
                    r.videoFrameRate = xml.substr(p, e - p);
            }
        }
        r.frameRate = attr(xml, "Stream", "frameRate");
        // Prefer video stream frameRate when Stream tags are mixed (first may be audio).
        // Scan all Stream open-tags for type="video" frameRate.
        {
            size_t sp = 0;
            while ((sp = xml.find("<Stream", sp)) != std::string::npos) {
                auto end = xml.find('>', sp);
                if (end == std::string::npos)
                    break;
                const std::string slice = xml.substr(sp, end - sp);
                if (slice.find("type=\"video\"") != std::string::npos) {
                    auto fr = attrIn(slice, "frameRate");
                    if (!fr.empty())
                        r.frameRate = fr;
                    break;
                }
                sp = end + 1;
            }
        }
        r.sourceFpsHint = contentFpsHint(r.videoFrameRate, r.frameRate);
        parseExactFps(r.videoFrameRate, r.frameRate, r.fpsNum, r.fpsDen);
        // Source asset geometry (library), for direct-play identity-scale + GEOM logs.
        // Also capture DAR/SAR — universal videoResolution is a ceiling; PMS
        // square-pixel aspect-fit uses display aspect (see pms_delivery_geom.hpp).
        {
            auto mw = attr(xml, "Media", "width");
            auto mh = attr(xml, "Media", "height");
            if (!mw.empty() && !mh.empty()) {
                r.mediaWidth = std::atoi(mw.c_str());
                r.mediaHeight = std::atoi(mh.c_str());
            }
            r.mediaAspectRatio = attr(xml, "Media", "aspectRatio");
            if (r.mediaWidth <= 0 || r.mediaHeight <= 0) {
                size_t sp = 0;
                while ((sp = xml.find("<Stream", sp)) != std::string::npos) {
                    auto end = xml.find('>', sp);
                    if (end == std::string::npos)
                        break;
                    const std::string slice = xml.substr(sp, end - sp);
                    const bool isVideo = slice.find("streamType=\"1\"") != std::string::npos ||
                                         slice.find("type=\"video\"") != std::string::npos;
                    if (isVideo) {
                        auto sw = attrIn(slice, "width");
                        auto sh = attrIn(slice, "height");
                        if (!sw.empty() && !sh.empty()) {
                            r.mediaWidth = std::atoi(sw.c_str());
                            r.mediaHeight = std::atoi(sh.c_str());
                        }
                        auto sar = attrIn(slice, "pixelAspectRatio");
                        if (!sar.empty())
                            r.pixelAspectRatio = sar;
                        if (r.mediaAspectRatio.empty()) {
                            auto ar = attrIn(slice, "aspectRatio");
                            if (!ar.empty())
                                r.mediaAspectRatio = ar;
                        }
                        break;
                    }
                    sp = end + 1;
                }
            } else {
                // Width/height from Media — still scan video Stream for SAR.
                size_t sp = 0;
                while ((sp = xml.find("<Stream", sp)) != std::string::npos) {
                    auto end = xml.find('>', sp);
                    if (end == std::string::npos)
                        break;
                    const std::string slice = xml.substr(sp, end - sp);
                    const bool isVideo = slice.find("streamType=\"1\"") != std::string::npos ||
                                         slice.find("type=\"video\"") != std::string::npos;
                    if (isVideo) {
                        auto sar = attrIn(slice, "pixelAspectRatio");
                        if (!sar.empty())
                            r.pixelAspectRatio = sar;
                        break;
                    }
                    sp = end + 1;
                }
            }
            if (r.mediaWidth < 0)
                r.mediaWidth = 0;
            if (r.mediaHeight < 0)
                r.mediaHeight = 0;
        }
    }

    // Two-regime (miss #13 + parent 720p): ≤1280×720 H.264 → try DP Part first
    // (rk=7 cheapest). Above 720 → universal 1280×720 tier (real PMS 720p profile).
    // preferDirectH264 is the conf allow flag (default true); geometry overrides.
    const bool metaOk = metaFound;
    const bool isH264 = metaOk && mediaVideoIsH264(xml);
    const bool wantDirect = preferDirectH264 && key.rfind("/library", 0) == 0;
    const bool multiPixel = weak.presentMultiPixel;
    // Optional profile tag for operator logs (High often implies CABAC sticky skip).
    auto videoProfileNote = [&]() -> std::string {
        if (!metaOk)
            return {};
        // Prefer video Stream profile, then Media@videoProfile / videoCodec.
        size_t sp = 0;
        while ((sp = xml.find("<Stream", sp)) != std::string::npos) {
            auto end = xml.find('>', sp);
            if (end == std::string::npos)
                break;
            const std::string slice = xml.substr(sp, end - sp);
            const bool isVideo = slice.find("streamType=\"1\"") != std::string::npos ||
                                 slice.find("type=\"video\"") != std::string::npos;
            if (isVideo) {
                auto p = attrIn(slice, "profile");
                if (p.empty())
                    p = attrIn(slice, "videoProfile");
                if (!p.empty())
                    return p;
                break;
            }
            sp = end + 1;
        }
        auto p = attr(xml, "Media", "videoProfile");
        if (p.empty())
            p = attr(xml, "Media", "videoCodec");
        return p;
    };
    const std::string profNote = videoProfileNote();
    r.videoProfile = profNote;
    const PlayDeliveryRegime regime = selectPlayDeliveryRegime(
        r.mediaWidth, r.mediaHeight, wantDirect, isH264, multiPixel);
    r.playRegime = playDeliveryRegimeName(regime);
    const bool directH264 = (regime == PlayDeliveryRegime::DirectPlaySd);
    // Direct Part bank geometry: pad-only align-up of media samples (rd-duck).
    // Must run BEFORE any DP return — source-aware PMS selection below is skipped
    // on preferDirect H.264 Part, which previously left storeWidth=0 and main kept
    // the configured tier canvas (ARM scale of 320×240 into 624×480).
    auto applyDirectPartNativeStore = [&]() {
        if (r.mediaWidth <= 0 || r.mediaHeight <= 0)
            return;
        const auto sel = selectDirectPartStoreGeometry(r.mediaWidth, r.mediaHeight);
        if (sel.store_w <= 0 || sel.store_h <= 0)
            return;
        r.requestWidth = sel.request_w;
        r.requestHeight = sel.request_h;
        r.storeWidth = sel.store_w;
        r.storeHeight = sel.store_h;
        r.sourceAwareApplied = true;
        r.sourceAwarePolicy = sel.policy ? sel.policy : "direct_part_native";
    };

    if (directH264) {
        const std::string profSuffix = profNote.empty() ? "" : (" profile=" + profNote);
        // Parent recipe: call /universal/decision with directPlay=1 + full identity
        // and require decision="directplay" before opening Part. Thin headers → 400
        // must not silently fall into xcode CABAC.
        bool dpGranted = false;
        std::string dpDecisionDetail;
        {
            WeakLadder weakDp = weak;
            // Decision ceiling only — PMS never upscales. Default 1280×720 so
            // native 720p assets stay DP-eligible (parent FACT content 720).
            if (weakDp.videoResolution.empty())
                weakDp.videoResolution =
                    routeBDefaultDecisionResolution(multiPixel);
            if (weakDp.maxVideoBitrateKbps <= 0)
                weakDp.maxVideoBitrateKbps = 20000;
            if (weakDp.videoQuality <= 0)
                weakDp.videoQuality = 100;
            const std::string sid = makeSessionId();
            const std::string hdrBlock = plexFfmpegHeaders(sid, token, weakDp);
            if (!plexClientIdentityHeadersComplete(hdrBlock)) {
                dpDecisionDetail = "DP decision skipped: thin identity headers (400 trap)";
            } else {
                const std::string decUrl =
                    buildUniversalDecisionUrl(plexBase, key, token, sid, weakDp,
                                              /*allow_direct=*/true);
                // Reuse curl identity; pass session header extras via extraHeaders.
                std::ostringstream extra;
                extra << " -H " << shellQuote("X-Plex-Session-Identifier: " + sid);
                if (weakDp.clientProfileName != "MiSTerPlex") {
                    extra << " -H "
                          << shellQuote("X-Plex-Client-Capabilities: " +
                                        plexClientCapabilities(weakDp));
                    extra << " -H "
                          << shellQuote("X-Plex-Client-Profile-Extra: " +
                                        plexClientProfileExtra(weakDp));
                }
                const std::string body = httpGet(decUrl, 20, extra.str());
                r.decisionAttr = plexParseDecisionAttr(body);
                if (body.empty()) {
                    dpDecisionDetail = "DP decision empty body (identity/400?)";
                } else if (plexDecisionXmlIsDirectPlay(body)) {
                    dpGranted = true;
                    r.decisionVerifiedDirectPlay = true;
                    dpDecisionDetail = "decision=directplay";
                } else {
                    dpDecisionDetail = "DP not granted decision=" +
                                       (r.decisionAttr.empty() ? "?" : r.decisionAttr);
                }
            }
        }
        if (dpGranted) {
            auto partKey = attr(xml, "Part", "key");
            if (!partKey.empty()) {
                if (partKey[0] != '/')
                    partKey = "/" + partKey;
                r.playable = plexBase + partKey;
                if (!token.empty())
                    r.playable += (r.playable.find('?') == std::string::npos ? "?" : "&") +
                                  std::string("X-Plex-Token=") + urlEncodeQuery(token);
                r.ok = true;
                r.transcoded = false;
                {
                    const auto fr = gateFabricFromPmsDelivery(false, profNote);
                    r.fabricRoute = fabricDecodeRouteStr(fabricDecodeRoute(fr));
                    r.detail = "direct H.264 Part (regime=direct_play_sd" + profSuffix +
                               " " + dpDecisionDetail + " fabric_route=" + r.fabricRoute +
                               " bitstream=pending_sps)";
                }
                applyDirectPartNativeStore();
                return r;
            }
            auto file = attr(xml, "Part", "file");
            if (!file.empty()) {
                r.playable = urlDecode(file);
                r.ok = true;
                r.transcoded = false;
                {
                    const auto fr = gateFabricFromPmsDelivery(false, profNote);
                    r.fabricRoute = fabricDecodeRouteStr(fabricDecodeRoute(fr));
                    r.detail = "direct H.264 Part file (regime=direct_play_sd" + profSuffix +
                               " " + dpDecisionDetail + " fabric_route=" + r.fabricRoute +
                               " bitstream=pending_sps)";
                }
                applyDirectPartNativeStore();
                return r;
            }
            // Decision said DP but Part missing — fall through.
            dpDecisionDetail += "; Part missing";
        }
        // Fall through to universal if DP not granted or Part missing
        r.playRegime = playDeliveryRegimeName(PlayDeliveryRegime::ForceUniversal);
        if (!dpDecisionDetail.empty())
            r.detail = dpDecisionDetail;
    }

    // Prefer weak universal for dual A9 (STREAM=0 cast path / non-H.264 STREAM)
    if (weakAlways && key.rfind("/library", 0) == 0) {
        // Source-aware request: selects target bank/request only.
        // rd-duck: universal remains arm_scale_fallback (delivery_verified=0,
        // force-scale, vf frozen pre-banner; PMS ±2 tweak can unalign delivery).
        // Do NOT treat this as fabric-native / ARM-scale-removed.
        // HD above 720 → real 720p PMS tier (never silent 540 forever).
        WeakLadder weakEff = weak;
        if (regime == PlayDeliveryRegime::TranscodeHd720) {
            r.playRegime = playDeliveryRegimeName(PlayDeliveryRegime::TranscodeHd720);
            int tw = 0, th = 0;
            const char* tier = routeBHdTranscodeTargetSize(multiPixel, &tw, &th);
            applyPlexTranscodeProfile(tier, weakEff);
            r.requestWidth = tw;
            r.requestHeight = th;
            r.storeWidth = tw;
            r.storeHeight = th;
            r.sourceAwareApplied = true;
            r.sourceAwarePolicy = "transcode_hd_720";
            if (!r.detail.empty())
                r.detail += "; ";
            r.detail += "PMS_HD_720 media=" + std::to_string(r.mediaWidth) + "x" +
                        std::to_string(r.mediaHeight) + " → request 1280x720";
            if (!routeBResolvedSizeLegal(r.requestWidth, r.requestHeight, 24, multiPixel)) {
                r.ok = false;
                r.detail = "PMS_CONTENT_CAP refuse: HD target " +
                           std::to_string(r.requestWidth) + "x" +
                           std::to_string(r.requestHeight) +
                           " exceeds 1280x720 content ceiling";
                return r;
            }
        } else if (r.mediaWidth > 0 && r.mediaHeight > 0) {
            int maxW = 0, maxH = 0;
            parseResolution(weak.videoResolution, maxW, maxH);
            // Ceiling itself must not exceed product content max (1280×720).
            if (maxW > kPmsContentMaxW)
                maxW = kPmsContentMaxW;
            if (maxH > kPmsContentMaxH)
                maxH = kPmsContentMaxH;
            const auto sel = selectSourceAwarePmsRequest(r.mediaWidth, r.mediaHeight, maxW, maxH);
            if (sel.request_w > 0 && sel.request_h > 0) {
                weakEff.videoResolution = sel.videoResolution;
                r.requestWidth = sel.request_w;
                r.requestHeight = sel.request_h;
                r.storeWidth = sel.store_w;
                r.storeHeight = sel.store_h;
                r.sourceAwareApplied = true;
                r.sourceAwarePolicy = sel.policy ? sel.policy : "";
            }
        } else if (!weak.videoResolution.empty()) {
            // No media meta — still snap the configured ceiling for store safety.
            int maxW = 0, maxH = 0;
            if (parseResolution(weak.videoResolution, maxW, maxH) && maxW > 0 && maxH > 0) {
                if (maxW > kPmsContentMaxW || maxH > kPmsContentMaxH) {
                    applyPlexTranscodeProfile("720p", weakEff);
                    maxW = kPmsContentMaxW;
                    maxH = kPmsContentMaxH;
                    if (!r.detail.empty())
                        r.detail += "; ";
                    r.detail += "PMS_CONTENT_CAP conf ladder → 1280x720";
                }
                const auto sel = selectSourceAwarePmsRequest(0, 0, maxW, maxH);
                weakEff.videoResolution = sel.videoResolution;
                r.requestWidth = sel.request_w;
                r.requestHeight = sel.request_h;
                r.storeWidth = sel.store_w;
                r.storeHeight = sel.store_h;
                r.sourceAwareApplied = true;
                r.sourceAwarePolicy = sel.policy ? sel.policy : "";
            }
        }
        const std::string session = makeSessionId();
        const std::string start = buildUniversalTranscodeUrl(plexBase, key, token, session,
                                                             offsetMs > 0 ? offsetMs : 0, weakEff);
        if (ensureUniversalDecision(start, session, token, weakEff)) {
            r.ok = true;
            r.transcoded = true;
            r.playable = start;
            r.httpHeaders = plexFfmpegHeaders(session, token, weakEff);
            if (!plexClientIdentityHeadersComplete(r.httpHeaders)) {
                r.ok = false;
                r.detail = "PMS universal headers incomplete (thin identity → HTTP 400 trap)";
                return r;
            }
            {
                // miss #15: xcode never fabric-eligible regardless of advertised profile.
                const auto fr = gateFabricFromPmsDelivery(true, profNote);
                r.fabricRoute = fabricDecodeRouteStr(fabricDecodeRoute(fr));
                r.decisionAttr = "transcode"; // universal start path
                r.detail = "PMS universal " + weakEff.profileName + " " + weakEff.videoResolution +
                           " regime=" + r.playRegime + " fabric_route=" + r.fabricRoute +
                           " (" + std::string(fr.reason ? fr.reason : "") + ") " + key;
            }
            // STREAM preferDirect fallthrough: operator can see why recon may hit CABAC.
            if (preferDirectH264) {
                if (!metaOk)
                    r.detail += " (STREAM preferDirect: no metadata)";
                else if (!isH264)
                    r.detail += " (STREAM preferDirect: source not H.264)";
                else
                    r.detail += " (STREAM preferDirect: H.264 Part missing → universal may be High/CABAC)";
            }
            return r;
        }
        r.detail = "universal decision failed; trying direct part";
    }

    // Fallback: direct Part stream URL from metadata
    if (metaFound) {
        auto partKey = attr(xml, "Part", "key");
        if (!partKey.empty()) {
            if (partKey[0] != '/')
                partKey = "/" + partKey;
            r.playable = plexBase + partKey;
            if (!token.empty())
                r.playable += (r.playable.find('?') == std::string::npos ? "?" : "&") +
                              std::string("X-Plex-Token=") + urlEncodeQuery(token);
            r.ok = true;
            r.detail = "direct Part stream";
            applyDirectPartNativeStore();
            return r;
        }
        auto file = attr(xml, "Part", "file");
        if (!file.empty()) {
            r.playable = urlDecode(file);
            r.ok = true;
            r.detail = "Part file path";
            applyDirectPartNativeStore();
            return r;
        }
    }

    if (!metaFound)
        r.detail = "no such item on PMS (" + key + " returned no MediaContainer — "
                   "deleted, renumbered by a library re-scan, or bad token)";
    if (r.detail.empty())
        r.detail = "resolve failed for " + key;
    return r;
}

PlayQueue fetchPlayQueue(const std::string& queueIdOrContainerKey, const std::string& plexBase,
                         const std::string& token, const std::string& currentKey,
                         const std::string& playQueueItemId) {
    PlayQueue q;
    std::string raw = urlDecode(queueIdOrContainerKey);
    std::string extraQuery;
    auto qmark = raw.find('?');
    if (qmark != std::string::npos) {
        extraQuery = raw.substr(qmark + 1);
        raw = raw.substr(0, qmark);
    }
    std::string id = raw;
    auto slash = id.find_last_of('/');
    if (slash != std::string::npos)
        id = id.substr(slash + 1);
    while (!id.empty() && !std::isdigit(static_cast<unsigned char>(id.back())))
        id.pop_back();
    if (id.empty() || !std::isdigit(static_cast<unsigned char>(id.front()))) {
        q.detail = "empty/invalid play queue id from '" + queueIdOrContainerKey + "'";
        return q;
    }

    std::string base = normalizePlexBase(plexBase);
    if (base.empty()) {
        q.detail = "no PMS base for play queue";
        return q;
    }

    std::string url = base + "/playQueues/" + id + "?";
    if (!extraQuery.empty())
        url += extraQuery + "&";
    else
        url += "own=1&";
    if (!token.empty())
        url += "X-Plex-Token=" + urlEncodeQuery(token);

    const std::string xml = httpGet(url, 20);
    if (xml.empty() || xml.find("MediaContainer") == std::string::npos) {
        q.detail = "play queue fetch failed id=" + id + " bytes=" + std::to_string(xml.size());
        return q;
    }

    q.containerKey = "/playQueues/" + id;
    q.playQueueId = id;
    {
        auto a = xml.find("playQueueID=\"");
        if (a != std::string::npos) {
            a += 13;
            auto b = xml.find('"', a);
            if (b != std::string::npos)
                q.playQueueId = xml.substr(a, b - a);
        }
        a = xml.find("playQueueVersion=\"");
        if (a != std::string::npos) {
            a += 18;
            auto b = xml.find('"', a);
            if (b != std::string::npos)
                q.playQueueVersion = xml.substr(a, b - a);
        }
    }

    size_t pos = 0;
    while ((pos = xml.find("<Video", pos)) != std::string::npos) {
        auto tagEnd = xml.find('>', pos);
        if (tagEnd == std::string::npos)
            break;
        size_t sliceEnd = tagEnd;
        auto end2 = xml.find("</Video>", pos);
        auto endSlash = xml.find("/>", pos);
        if (endSlash != std::string::npos && endSlash < tagEnd + 8)
            sliceEnd = endSlash;
        if (end2 != std::string::npos)
            sliceEnd = std::max(sliceEnd, end2);
        const std::string slice = xml.substr(pos, std::min<size_t>(4000, sliceEnd - pos + 8));

        QueueItem item;
        item.key = attrIn(slice, "key");
        item.ratingKey = attrIn(slice, "ratingKey");
        item.playQueueItemId = attrIn(slice, "playQueueItemID");
        if (item.playQueueItemId.empty())
            item.playQueueItemId = attrIn(slice, "playQueueItemId");
        item.title = attrIn(slice, "title");
        auto d = attrIn(slice, "duration");
        if (!d.empty())
            item.durationMs = std::strtoll(d.c_str(), nullptr, 10);
        if (!item.key.empty())
            q.items.push_back(item);
        pos = tagEnd + 1;
    }

    if (q.items.empty()) {
        q.detail = "play queue had no Video items";
        return q;
    }

    q.currentIndex = 0;
    if (!playQueueItemId.empty()) {
        for (size_t i = 0; i < q.items.size(); ++i) {
            if (q.items[i].playQueueItemId == playQueueItemId ||
                q.items[i].ratingKey == playQueueItemId ||
                q.items[i].key.find(playQueueItemId) != std::string::npos) {
                q.currentIndex = static_cast<int>(i);
                break;
            }
        }
    } else if (!currentKey.empty()) {
        for (size_t i = 0; i < q.items.size(); ++i) {
            if (q.items[i].key == currentKey ||
                (!q.items[i].ratingKey.empty() &&
                 currentKey.find(q.items[i].ratingKey) != std::string::npos)) {
                q.currentIndex = static_cast<int>(i);
                break;
            }
        }
    }

    q.ok = true;
    q.detail = "queue size=" + std::to_string(q.items.size()) +
               " index=" + std::to_string(q.currentIndex);
    return q;
}

namespace {

int bucketFps(double fps) {
    if (fps <= 0.0)
        return 0;
    // Nearest of OSD Content FPS options 12 / 24 / 30 / 60
    const int opts[] = {12, 24, 30, 60};
    int best = 24;
    double bestDiff = 1e9;
    for (int o : opts) {
        double d = std::fabs(fps - static_cast<double>(o));
        if (d < bestDiff) {
            bestDiff = d;
            best = o;
        }
    }
    // 23.976 → 24, 29.97 → 30, 59.94 → 60
    return best;
}

} // namespace

int contentFpsHint(const std::string& videoFrameRate, const std::string& frameRate) {
    // Prefer numeric stream frameRate
    if (!frameRate.empty()) {
        char* end = nullptr;
        double v = std::strtod(frameRate.c_str(), &end);
        if (end != frameRate.c_str() && v > 0.0)
            return bucketFps(v);
    }
    if (videoFrameRate.empty())
        return 0;
    std::string s = videoFrameRate;
    for (char& c : s)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    // Common PMS tokens
    if (s == "ntsc" || s.find("29.97") != std::string::npos || s == "30p" || s == "30")
        return 30;
    if (s == "pal" || s.find("25") == 0 || s == "25p")
        return 24; // nearest OSD bucket (no 25); cadence at 24 is less wrong than 30 for film-ish
    if (s == "24p" || s == "24" || s.find("23.9") != std::string::npos ||
        s.find("film") != std::string::npos)
        return 24;
    if (s == "60p" || s == "60" || s.find("59.9") != std::string::npos || s == "120p")
        return 60;
    if (s == "12p" || s == "12")
        return 12;
    // Strip trailing 'p' and parse number
    if (!s.empty() && (s.back() == 'p' || s.back() == 'i'))
        s.pop_back();
    char* end = nullptr;
    double v = std::strtod(s.c_str(), &end);
    if (end != s.c_str() && v > 0.0)
        return bucketFps(v);
    return 0;
}

int applySourceFpsConf(const std::string& sourceFpsConf, int resolvedHint) {
    std::string s = sourceFpsConf;
    // trim
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t'))
        s.erase(s.begin());
    while (!s.empty() && (s.back() == ' ' || s.back() == '\t' || s.back() == '\r'))
        s.pop_back();
    for (char& c : s)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (s.empty() || s == "auto")
        return resolvedHint;
    if (s == "off" || s == "0" || s == "none")
        return 0;
    char* end = nullptr;
    long v = std::strtol(s.c_str(), &end, 10);
    if (end != s.c_str() && v > 0)
        return bucketFps(static_cast<double>(v));
    return resolvedHint;
}

namespace {

struct FpsRational {
    int num;
    int den;
};

// Standard broadcast rates. 1001-denominator entries must snap exactly: treating
// 23.976 as 24 costs ~1 ms/s of lipsync drift (~234 ms by 3:54, ~5.5 s over 91 min).
constexpr FpsRational kStdFps[] = {
    {12, 1},        {15, 1},        {24000, 1001}, {24, 1},       {25, 1},
    {30000, 1001},  {30, 1},        {48, 1},       {50, 1},       {60000, 1001},
    {60, 1},
};

// Snap a decimal rate onto the standard family. Tolerance is well under the
// 23.976↔24 gap (0.024) so the NTSC pairs never collapse into each other.
bool snapStdFps(double v, int& num, int& den) {
    if (!(v > 0.0) || v > 1000.0)
        return false;
    for (const auto& f : kStdFps) {
        const double std_v = static_cast<double>(f.num) / static_cast<double>(f.den);
        if (std::fabs(v - std_v) <= 0.010) {
            num = f.num;
            den = f.den;
            return true;
        }
    }
    // Not a standard rate — keep it exact to 3 decimals rather than rounding to int.
    long n = std::lround(v * 1000.0);
    if (n <= 0)
        return false;
    num = static_cast<int>(n);
    den = 1000;
    return true;
}

std::string lowerTrim(const std::string& in) {
    std::string s = in;
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t'))
        s.erase(s.begin());
    while (!s.empty() && (s.back() == ' ' || s.back() == '\t' || s.back() == '\r'))
        s.pop_back();
    for (char& c : s)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

} // namespace

bool parseExactFps(const std::string& videoFrameRate, const std::string& frameRate,
                   int& num, int& den) {
    num = 0;
    den = 0;
    // Prefer the numeric video Stream@frameRate — it carries the real 23.976/29.97.
    if (!frameRate.empty()) {
        char* end = nullptr;
        double v = std::strtod(frameRate.c_str(), &end);
        if (end != frameRate.c_str() && v > 0.0 && snapStdFps(v, num, den))
            return true;
    }
    if (videoFrameRate.empty())
        return false;

    std::string s = lowerTrim(videoFrameRate);
    if (s.empty())
        return false;
    // PMS Media@videoFrameRate tokens. NTSC/PAL are film/broadcast families, not integers.
    if (s == "ntsc") {
        num = 30000;
        den = 1001;
        return true;
    }
    if (s == "pal") {
        num = 25;
        den = 1;
        return true;
    }
    if (s == "film" || s == "24p") {
        num = 24;
        den = 1;
        return true;
    }
    // Strip a trailing progressive/interlaced marker ("24p", "60i").
    if (s.back() == 'p' || s.back() == 'i')
        s.pop_back();
    char* end = nullptr;
    double v = std::strtod(s.c_str(), &end);
    if (end != s.c_str() && v > 0.0)
        return snapStdFps(v, num, den);
    return false;
}

bool applyContentFpsConf(const std::string& conf, int& num, int& den) {
    const std::string s = lowerTrim(conf);
    if (s.empty() || s == "auto")
        return false;
    if (s == "off" || s == "0" || s == "none") {
        num = 0;
        den = 0;
        return true;
    }
    // "24000/1001" rational form
    const auto slash = s.find('/');
    if (slash != std::string::npos) {
        char* e1 = nullptr;
        char* e2 = nullptr;
        const std::string ns = s.substr(0, slash);
        const std::string ds = s.substr(slash + 1);
        long n = std::strtol(ns.c_str(), &e1, 10);
        long d = std::strtol(ds.c_str(), &e2, 10);
        if (e1 != ns.c_str() && e2 != ds.c_str() && n > 0 && d > 0) {
            num = static_cast<int>(n);
            den = static_cast<int>(d);
            return true;
        }
        return false;
    }
    char* end = nullptr;
    double v = std::strtod(s.c_str(), &end);
    if (end != s.c_str() && v > 0.0)
        return snapStdFps(v, num, den);
    return false;
}

bool plexDeliveryProfileIsFabricSafe(const std::string& videoProfileAttr) {
    return plexVideoProfileAttrIsFabricSafe(videoProfileAttr);
}

bool plexDeliveryIsFabricEligible(bool is_transcoded, const std::string& advertisedVideoProfile) {
    return fabricDecodeRouteForPmsDecision(is_transcoded, advertisedVideoProfile) ==
           FabricDecodeRoute::FabricBitstreamEligible;
}

} // namespace misterplex
