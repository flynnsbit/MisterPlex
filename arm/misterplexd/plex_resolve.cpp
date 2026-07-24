#include "plex_resolve.hpp"

#include <atomic>
#include <cctype>
#include <cstdio>
#include <iomanip>
#include <sstream>

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
                    const std::string& extraHeaders = {}) {
    // Prefer curl (present on MiSTer); -k for plex.direct certs.
    std::ostringstream cmd;
    cmd << "curl -sS -g -k -L --http1.1 --connect-timeout 6 --max-time " << timeoutSec
        << " -H 'Accept: application/xml'"
        << " -H 'X-Plex-Client-Identifier: misterplex'"
        << " -H 'X-Plex-Product: Plex Web'"
        << " -H 'X-Plex-Version: 4.125.0'"
        << " -H 'X-Plex-Platform: Chrome'"
        << " -H 'X-Plex-Platform-Version: 120.0'"
        << " -H 'X-Plex-Device: Linux'"
        << " -H 'X-Plex-Device-Name: Chrome'"
        << " -H 'X-Plex-Client-Profile-Name: Chrome'"
        << " -H 'X-Plex-Model: bundled'"
        << " -H 'X-Plex-Provides: player'";
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

std::string buildUniversal(const std::string& base, const std::string& metadataKey,
                           const std::string& token, const std::string& session,
                           int64_t offsetMs) {
    // Dual-A9 safe ladder: 320x240 @ ~1 Mbps
    std::ostringstream q;
    q << base << "/video/:/transcode/universal/start.mp4"
      << "?hasMDE=1"
      << "&path=" << urlEncodeQuery(metadataKey)
      << "&mediaIndex=0&partIndex=0"
      << "&protocol=http&fastSeek=1"
      << "&directPlay=0&directStream=0"
      << "&subtitleSize=100&audioBoost=100&location=lan&copyts=1"
      << "&session=" << urlEncodeQuery(session)
      << "&videoQuality=40"
      << "&videoResolution=" << urlEncodeQuery("320x240")
      << "&maxVideoBitrate=1000";
    // PMS universal offset is SECONDS
    if (offsetMs > 0)
        q << "&offset=" << ((offsetMs + 500) / 1000);
    if (!token.empty())
        q << "&X-Plex-Token=" << urlEncodeQuery(token);
    return q.str();
}

} // namespace

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

std::string plexFfmpegHeaders(const std::string& sessionId, const std::string& token) {
    std::ostringstream o;
    o << "X-Plex-Client-Identifier: misterplex\r\n"
      << "X-Plex-Product: Plex Web\r\n"
      << "X-Plex-Version: 4.125.0\r\n"
      << "X-Plex-Platform: Chrome\r\n"
      << "X-Plex-Platform-Version: 120.0\r\n"
      << "X-Plex-Device: Linux\r\n"
      << "X-Plex-Device-Name: Chrome\r\n"
      << "X-Plex-Client-Profile-Name: Chrome\r\n"
      << "X-Plex-Model: bundled\r\n"
      << "X-Plex-Provides: player\r\n"
      << "X-Plex-Session-Identifier: " << sessionId << "\r\n";
    if (!token.empty())
        o << "X-Plex-Token: " << token << "\r\n";
    return o.str();
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

    std::ostringstream decisionUrl;
    decisionUrl << base << "/video/:/transcode/universal/decision?hasMDE=1&path=" << path
                << "&mediaIndex=0&partIndex=0&protocol=http&fastSeek=1&directPlay=0&directStream=0"
                << "&location=lan&session=" << urlEncodeQuery(sessionId)
                << "&videoQuality=40&videoResolution=320x240&maxVideoBitrate=1000";
    if (!token.empty())
        decisionUrl << "&X-Plex-Token=" << urlEncodeQuery(token);

    std::ostringstream sessHdr;
    sessHdr << " -H 'X-Plex-Session-Identifier: " << sessionId << "' ";
    const std::string body = httpGet(decisionUrl.str(), 20, sessHdr.str());
    if (body.empty())
        return false;
    if (body.find("unable to find a matching profile") != std::string::npos)
        return false;
    return body.find("MediaContainer") != std::string::npos ||
           body.find("transcodeDecisionCode") != std::string::npos;
}

ResolveResult resolvePlayTarget(const std::string& rawKeyOrPath, const std::string& plexBase,
                                const std::string& token, int64_t offsetMs, bool weakAlways) {
    ResolveResult r;
    std::string key = urlDecode(rawKeyOrPath);
    if (key.empty() || key == "test" || key == "testsrc") {
        r.ok = true;
        r.playable = "testsrc";
        r.detail = "test pattern";
        r.durationMs = 120000;
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
    if (!xml.empty()) {
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
    }

    // Prefer weak universal for dual A9
    if (weakAlways && key.rfind("/library", 0) == 0) {
        const std::string session = makeSessionId();
        const std::string start =
            buildUniversal(plexBase, key, token, session, offsetMs > 0 ? offsetMs : 0);
        if (ensureUniversalDecision(start, session, token)) {
            r.ok = true;
            r.transcoded = true;
            r.playable = start;
            r.httpHeaders = plexFfmpegHeaders(session, token);
            r.detail = "PMS universal weak " + key;
            return r;
        }
        r.detail = "universal decision failed; trying direct part";
    }

    // Fallback: direct Part stream URL from metadata
    if (!xml.empty()) {
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
            return r;
        }
        auto file = attr(xml, "Part", "file");
        if (!file.empty()) {
            r.playable = urlDecode(file);
            r.ok = true;
            r.detail = "Part file path";
            return r;
        }
    }

    if (r.detail.empty())
        r.detail = "resolve failed for " + key;
    return r;
}

} // namespace misterplex
