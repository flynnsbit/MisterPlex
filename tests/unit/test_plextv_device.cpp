// Unit tests for plex.tv player device registration (no network).
#include "plextv_device.hpp"
#include "plex_resolve.hpp"

#include <cstdio>
#include <map>
#include <string>
#include <vector>

static int fails = 0;
#define CHECK(cond)                                                                              \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                 \
            ++fails;                                                                             \
        }                                                                                        \
    } while (0)

static std::string header(const misterplex::PlexTvHttpRequest& req, const std::string& name) {
    for (const auto& h : req.headers) {
        if (h.first == name)
            return h.second;
    }
    return {};
}

static std::map<std::string, std::string> formParams(const std::string& body) {
    std::map<std::string, std::string> out;
    size_t q = 0;
    while (q < body.size()) {
        auto amp = body.find('&', q);
        auto part = body.substr(q, amp == std::string::npos ? std::string::npos : amp - q);
        auto eq = part.find('=');
        if (eq != std::string::npos)
            out[part.substr(0, eq)] = misterplex::urlDecode(part.substr(eq + 1));
        if (amp == std::string::npos)
            break;
        q = amp + 1;
    }
    return out;
}

int main() {
    using namespace misterplex;

    PlexTvDeviceIdentity id;
    id.clientIdentifier = "misterplex-dev";
    id.product = "MiSTerPlex";
    id.version = "0.2.0";
    id.platform = "Linux";
    id.device = "MiSTer";
    id.deviceName = "MiSTerPlex";
    id.provides = "player";
    id.port = 3005;

    // --- buildPlexTvRegisterRequest: happy path ---
    PlexTvHttpRequest req;
    CHECK(buildPlexTvRegisterRequest(id, "unit-token", "player.local", req));
    CHECK(req.method == "POST");
    CHECK(req.url == "https://plex.tv/devices.xml");
    CHECK(header(req, "X-Plex-Client-Identifier") == "misterplex-dev");
    CHECK(header(req, "X-Plex-Product") == "MiSTerPlex");
    CHECK(header(req, "X-Plex-Version") == "0.2.0");
    CHECK(header(req, "X-Plex-Platform") == "Linux");
    CHECK(header(req, "X-Plex-Device") == "MiSTer");
    CHECK(header(req, "X-Plex-Device-Name") == "MiSTerPlex");
    CHECK(header(req, "X-Plex-Provides") == "player");
    CHECK(header(req, "X-Plex-Token") == "unit-token");
    CHECK(header(req, "Content-Type") == "application/x-www-form-urlencoded");
    CHECK(header(req, "Accept") == "application/xml");

    auto form = formParams(req.body);
    CHECK(form["Connection[][protocol]"] == "http");
    CHECK(form["Connection[][address]"] == "player.local");
    CHECK(form["Connection[][port]"] == "3005");
    CHECK(form["Connection[][uri]"] == "http://player.local:3005");
    CHECK(form["Connection[][local]"] == "1");

    // Identifier stability: same inputs → same client identifier header.
    PlexTvHttpRequest req2;
    CHECK(buildPlexTvRegisterRequest(id, "unit-token", "player.local", req2));
    CHECK(header(req2, "X-Plex-Client-Identifier") == header(req, "X-Plex-Client-Identifier"));
    CHECK(header(req2, "X-Plex-Client-Identifier") == "misterplex-dev");

    // Missing token / id / address → refuse to build.
    PlexTvHttpRequest bad;
    CHECK(!buildPlexTvRegisterRequest(id, "", "player.local", bad));
    PlexTvDeviceIdentity noId = id;
    noId.clientIdentifier.clear();
    CHECK(!buildPlexTvRegisterRequest(noId, "unit-token", "player.local", bad));
    CHECK(!buildPlexTvRegisterRequest(id, "unit-token", "", bad));

    // --- unregister builder ---
    PlexTvHttpRequest unreg;
    CHECK(buildPlexTvUnregisterRequest("unit-token", "misterplex-dev", "4242", unreg));
    CHECK(unreg.method == "DELETE");
    CHECK(unreg.url == "https://plex.tv/devices/4242.xml");
    CHECK(header(unreg, "X-Plex-Token") == "unit-token");
    CHECK(header(unreg, "X-Plex-Client-Identifier") == "misterplex-dev");
    CHECK(unreg.body.empty());
    CHECK(!buildPlexTvUnregisterRequest("", "misterplex-dev", "4242", unreg));
    CHECK(!buildPlexTvUnregisterRequest("unit-token", "misterplex-dev", "", unreg));

    // --- parse device id ---
    CHECK(parsePlexTvDeviceId(
              "<MediaContainer><Device id=\"99\" name=\"MiSTerPlex\" "
              "clientIdentifier=\"misterplex-dev\" provides=\"player\"/></MediaContainer>") ==
          "99");
    CHECK(parsePlexTvDeviceId("<Device name=\"x\"/>").empty());
    CHECK(parsePlexTvDeviceId("").empty());

    // --- announcer: disabled / no token (mock HTTP must never fire) ---
    int httpCalls = 0;
    PlexTvDeviceAnnouncer off(
        [&](const PlexTvHttpRequest&, std::string*) -> int {
            ++httpCalls;
            return 200;
        },
        /*async=*/false);
    std::vector<std::string> logs;
    off.setLog([&](const std::string& s) { logs.push_back(s); });
    off.configure(id, "unit-token", /*enabled=*/false);
    off.start();
    CHECK(httpCalls == 0);
    CHECK(!logs.empty());
    CHECK(logs[0].find("PLEXTV_ANNOUNCE off") != std::string::npos);
    off.stop();

    logs.clear();
    httpCalls = 0;
    PlexTvDeviceAnnouncer noTok(
        [&](const PlexTvHttpRequest&, std::string*) -> int {
            ++httpCalls;
            return 200;
        },
        /*async=*/false);
    noTok.setLog([&](const std::string& s) { logs.push_back(s); });
    noTok.configure(id, "", /*enabled=*/true);
    noTok.start();
    CHECK(httpCalls == 0);
    CHECK(!logs.empty());
    CHECK(logs[0].find("PLEX_TOKEN missing") != std::string::npos);
    noTok.stop();

    // --- announcer: mock success path (uses real detectLanIpv4; may fail offline) ---
    // We only assert that when HTTP is invoked the request carries stable identity.
    // If LAN detect fails in this environment, announcer logs failure and does not crash.
    logs.clear();
    httpCalls = 0;
    PlexTvHttpRequest lastReq;
    PlexTvDeviceAnnouncer on(
        [&](const PlexTvHttpRequest& r, std::string* body) -> int {
            ++httpCalls;
            lastReq = r;
            if (body)
                *body = "<Device id=\"777\" clientIdentifier=\"misterplex-dev\" provides=\"player\"/>";
            return 201;
        },
        /*async=*/false);
    on.setLog([&](const std::string& s) { logs.push_back(s); });
    on.configure(id, "unit-token", /*enabled=*/true);
    on.start();
    // Either succeeded (LAN available) or failed soft on LAN detect — never throw/crash.
    CHECK(!logs.empty());
    bool sawOutcome = false;
    for (const auto& l : logs) {
        if (l.find("registration succeeded") != std::string::npos ||
            l.find("registration failed") != std::string::npos ||
            l.find("could not detect LAN") != std::string::npos) {
            sawOutcome = true;
        }
    }
    CHECK(sawOutcome);
    if (httpCalls > 0) {
        CHECK(header(lastReq, "X-Plex-Client-Identifier") == "misterplex-dev");
        CHECK(header(lastReq, "X-Plex-Provides") == "player");
        CHECK(lastReq.url == "https://plex.tv/devices.xml");
        CHECK(lastReq.method == "POST");
    }
    on.stop();

    // Refresh interval constant is conservative (5 min).
    CHECK(PlexTvDeviceAnnouncer::kRefreshInterval.count() == 300);
    CHECK(PlexTvDeviceAnnouncer::kInitialBackoff.count() == 30);
    CHECK(PlexTvDeviceAnnouncer::kMaxBackoff.count() >= 300);

    if (fails) {
        std::fprintf(stderr, "test_plextv_device: %d failures\n", fails);
        return 1;
    }
    std::printf("test_plextv_device: OK\n");
    return 0;
}
