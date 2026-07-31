// Unit tests for plex.tv player registration (request construction + ID safety).
// No live plex.tv calls — HTTP is fully mocked.

#include "plextv_device.hpp"

#include <atomic>
#include <chrono>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace misterplex;

static int g_fails = 0;

#define EXPECT_TRUE(cond)                                                                          \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            std::cerr << "FAIL " << __FILE__ << ":" << __LINE__ << " EXPECT_TRUE(" << #cond        \
                      << ")\n";                                                                    \
            ++g_fails;                                                                             \
        }                                                                                          \
    } while (0)

#define EXPECT_EQ(a, b)                                                                            \
    do {                                                                                           \
        auto _a = (a);                                                                             \
        auto _b = (b);                                                                             \
        if (!(_a == _b)) {                                                                         \
            std::cerr << "FAIL " << __FILE__ << ":" << __LINE__ << " EXPECT_EQ(" << #a << ", "     \
                      << #b << ") got left=" << _a << " right=" << _b << "\n";                     \
            ++g_fails;                                                                             \
        }                                                                                          \
    } while (0)

#define EXPECT_NE(a, b)                                                                            \
    do {                                                                                           \
        auto _a = (a);                                                                             \
        auto _b = (b);                                                                             \
        if (_a == _b) {                                                                            \
            std::cerr << "FAIL " << __FILE__ << ":" << __LINE__ << " EXPECT_NE(" << #a << ", "     \
                      << #b << ") both=" << _a << "\n";                                            \
            ++g_fails;                                                                             \
        }                                                                                          \
    } while (0)

static bool hasHeader(const PlexTvHttpRequest& r, const std::string& k, const std::string& v) {
    for (const auto& h : r.headers) {
        if (h.first == k && h.second == v)
            return true;
    }
    return false;
}

static PlexTvDeviceIdentity sampleId() {
    PlexTvDeviceIdentity id;
    id.clientIdentifier = "misterplex-dev";
    id.product = "MiSTerPlex";
    id.version = "0.2.0";
    id.platform = "Linux";
    id.device = "MiSTer";
    id.deviceName = "MiSTerPlex";
    id.provides = "player";
    id.port = 3005;
    return id;
}

// --- Collision-safety: identifier must be non-empty, stable, misterplex-prefixed,
//     and distinct from PMS / banned defaults. ---------------------------------

static void test_id_empty_rejected() {
    EXPECT_TRUE(!isSafePlexTvClientIdentifier(""));
    EXPECT_TRUE(plexTvClientIdentifierUnsafeReason("").find("empty") != std::string::npos);
}

static void test_id_default_misterplex_1_banned() {
    // main.cpp default when --id omitted — must never hit plex.tv.
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("misterplex-1"));
    const auto why = plexTvClientIdentifierUnsafeReason("misterplex-1");
    EXPECT_TRUE(why.find("banned") != std::string::npos);
}

static void test_id_generic_slugs_banned() {
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("misterplex"));
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("misterplex-"));
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("chrome"));
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("plex"));
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("player"));
}

static void test_id_requires_misterplex_prefix() {
    // Hex-style PMS machineIdentifiers must never be accepted as player IDs.
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("4edd44aa-bbbb-cccc-dddd-eeeeeeeeeeee"));
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("4edd44aabbbbccccddddeeeeeeeeeeee"));
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("android-tv-shield"));
    const auto why = plexTvClientIdentifierUnsafeReason("4edd44aa");
    EXPECT_TRUE(why.find("misterplex-") != std::string::npos);
}

static void test_id_suffix_min_length() {
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("misterplex-ab")); // 2-char suffix
    EXPECT_TRUE(isSafePlexTvClientIdentifier("misterplex-abc")); // 3-char suffix
    EXPECT_TRUE(isSafePlexTvClientIdentifier("misterplex-dev")); // deploy default
}

static void test_id_foreign_denylist() {
    std::vector<std::string> foreign = {"misterplex-dev", "4edd44aa"};
    // Even a well-formed player id is refused if it collides with a known PMS id.
    EXPECT_TRUE(!isSafePlexTvClientIdentifier("misterplex-dev", foreign));
    EXPECT_TRUE(plexTvClientIdentifierUnsafeReason("misterplex-dev", foreign).find("denylist") !=
                std::string::npos);
    // Distinct player id still ok.
    EXPECT_TRUE(isSafePlexTvClientIdentifier("misterplex-lab2", foreign));
}

static void test_id_stable_across_restarts() {
    // Stability: same configured --id yields the same clientIdentifier every time
    // (no random UUID generation in this module).
    const auto a = sampleId();
    const auto b = sampleId();
    EXPECT_EQ(a.clientIdentifier, b.clientIdentifier);
    EXPECT_EQ(a.clientIdentifier, std::string("misterplex-dev"));
    EXPECT_TRUE(isSafePlexTvClientIdentifier(a.clientIdentifier));
}

static void test_id_distinct_from_pms_style() {
    const std::string player = "misterplex-dev";
    const std::string pms = "4edd44aabbbbccccddddeeeeeeeeeeee";
    EXPECT_NE(player, pms);
    EXPECT_TRUE(isSafePlexTvClientIdentifier(player));
    EXPECT_TRUE(!isSafePlexTvClientIdentifier(pms));
}

// --- Request construction -----------------------------------------------------

static void test_build_register_get_resources() {
    PlexTvHttpRequest req;
    EXPECT_TRUE(buildPlexTvRegisterRequest(sampleId(), "unit-test-token", req));
    EXPECT_EQ(req.method, std::string("GET"));
    EXPECT_EQ(req.url, std::string(PlexTvDeviceAnnouncer::kRegisterUrl));
    EXPECT_TRUE(req.url.find("api/v2/resources") != std::string::npos);
    EXPECT_TRUE(req.body.empty());
    EXPECT_TRUE(hasHeader(req, "X-Plex-Client-Identifier", "misterplex-dev"));
    EXPECT_TRUE(hasHeader(req, "X-Plex-Product", "MiSTerPlex"));
    EXPECT_TRUE(hasHeader(req, "X-Plex-Version", "0.2.0"));
    EXPECT_TRUE(hasHeader(req, "X-Plex-Platform", "Linux"));
    EXPECT_TRUE(hasHeader(req, "X-Plex-Device", "MiSTer"));
    EXPECT_TRUE(hasHeader(req, "X-Plex-Device-Name", "MiSTerPlex"));
    EXPECT_TRUE(hasHeader(req, "X-Plex-Provides", "player"));
    EXPECT_TRUE(hasHeader(req, "X-Plex-Token", "unit-test-token"));
    EXPECT_TRUE(hasHeader(req, "Accept", "application/json"));
    // Must NOT target the dead devices.xml endpoint.
    EXPECT_TRUE(req.url.find("devices.xml") == std::string::npos);
}

static void test_build_rejects_empty_token() {
    PlexTvHttpRequest req;
    EXPECT_TRUE(!buildPlexTvRegisterRequest(sampleId(), "", req));
}

static void test_build_rejects_unsafe_id() {
    PlexTvHttpRequest req;
    auto id = sampleId();
    id.clientIdentifier = "misterplex-1";
    EXPECT_TRUE(!buildPlexTvRegisterRequest(id, "unit-test-token", req));
    id.clientIdentifier = "";
    EXPECT_TRUE(!buildPlexTvRegisterRequest(id, "unit-test-token", req));
    id.clientIdentifier = "4edd44aa";
    EXPECT_TRUE(!buildPlexTvRegisterRequest(id, "unit-test-token", req));
}

static void test_body_mentions_client_json_and_xml() {
    const std::string json =
        R"([{"name":"SHIELD","clientIdentifier":"b9545fb9","provides":"player"},)"
        R"({"name":"MiSTerPlex","clientIdentifier":"misterplex-dev","provides":"player"}])";
    EXPECT_TRUE(plexTvResourcesBodyMentionsClient(json, "misterplex-dev"));
    EXPECT_TRUE(!plexTvResourcesBodyMentionsClient(json, "misterplex-other"));

    const std::string xml =
        R"(<MediaContainer><Device clientIdentifier="misterplex-dev" provides="player"/></MediaContainer>)";
    EXPECT_TRUE(plexTvResourcesBodyMentionsClient(xml, "misterplex-dev"));
}

// --- Announcer behaviour (mocked HTTP) ----------------------------------------

static void test_disabled_skips_http() {
    std::atomic<int> calls{0};
    std::mutex logMu;
    std::vector<std::string> logs;
    PlexTvDeviceAnnouncer a(
        [&](const PlexTvHttpRequest&, std::string*) {
            calls.fetch_add(1);
            return 200;
        },
        /*async=*/false);
    a.setLog([&](const std::string& s) {
        std::lock_guard<std::mutex> lock(logMu);
        logs.push_back(s);
    });
    a.configure(sampleId(), "unit-test-token", /*enabled=*/false);
    a.start();
    EXPECT_EQ(calls.load(), 0);
    bool saw = false;
    for (const auto& l : logs)
        if (l.find("PLEXTV_ANNOUNCE off") != std::string::npos)
            saw = true;
    EXPECT_TRUE(saw);
}

static void test_missing_token_skips_http() {
    std::atomic<int> calls{0};
    std::mutex logMu;
    std::vector<std::string> logs;
    PlexTvDeviceAnnouncer a(
        [&](const PlexTvHttpRequest&, std::string*) {
            calls.fetch_add(1);
            return 200;
        },
        /*async=*/false);
    a.setLog([&](const std::string& s) {
        std::lock_guard<std::mutex> lock(logMu);
        logs.push_back(s);
    });
    a.configure(sampleId(), "", /*enabled=*/true);
    a.start();
    EXPECT_EQ(calls.load(), 0);
    bool saw = false;
    for (const auto& l : logs)
        if (l.find("PLEX_TOKEN missing") != std::string::npos)
            saw = true;
    EXPECT_TRUE(saw);
}

static void test_unsafe_id_refuses_network() {
    std::atomic<int> calls{0};
    std::mutex logMu;
    std::vector<std::string> logs;
    PlexTvDeviceAnnouncer a(
        [&](const PlexTvHttpRequest&, std::string*) {
            calls.fetch_add(1);
            return 200;
        },
        /*async=*/false);
    a.setLog([&](const std::string& s) {
        std::lock_guard<std::mutex> lock(logMu);
        logs.push_back(s);
    });
    auto id = sampleId();
    id.clientIdentifier = "misterplex-1"; // banned default
    a.configure(id, "unit-test-token", /*enabled=*/true);
    a.start();
    EXPECT_EQ(calls.load(), 0);
    bool saw = false;
    for (const auto& l : logs)
        if (l.find("unsafe clientIdentifier") != std::string::npos)
            saw = true;
    EXPECT_TRUE(saw);
}

static void test_success_logs_startup() {
    std::atomic<int> calls{0};
    std::mutex logMu;
    std::vector<std::string> logs;
    PlexTvDeviceAnnouncer a(
        [&](const PlexTvHttpRequest& req, std::string* body) {
            calls.fetch_add(1);
            EXPECT_EQ(req.method, std::string("GET"));
            EXPECT_TRUE(req.url.find("api/v2/resources") != std::string::npos);
            EXPECT_TRUE(hasHeader(req, "X-Plex-Client-Identifier", "misterplex-dev"));
            EXPECT_TRUE(hasHeader(req, "X-Plex-Provides", "player"));
            if (body) {
                *body = R"([{"clientIdentifier":"misterplex-dev","provides":"player"}])";
            }
            return 200;
        },
        /*async=*/false);
    a.setLog([&](const std::string& s) {
        std::lock_guard<std::mutex> lock(logMu);
        logs.push_back(s);
    });
    a.configure(sampleId(), "unit-test-token", /*enabled=*/true);
    a.start();
    a.stop();
    EXPECT_EQ(calls.load(), 1);
    bool saw = false;
    for (const auto& l : logs) {
        if (l.find("registration succeeded") != std::string::npos &&
            l.find("http_status=200") != std::string::npos &&
            l.find("clientIdentifier=misterplex-dev") != std::string::npos &&
            l.find("(startup)") != std::string::npos)
            saw = true;
    }
    EXPECT_TRUE(saw);
}

static void test_http_404_logs_failure() {
    std::mutex logMu;
    std::vector<std::string> logs;
    PlexTvDeviceAnnouncer a(
        [&](const PlexTvHttpRequest&, std::string*) { return 404; },
        /*async=*/false);
    a.setLog([&](const std::string& s) {
        std::lock_guard<std::mutex> lock(logMu);
        logs.push_back(s);
    });
    a.configure(sampleId(), "unit-test-token", /*enabled=*/true);
    a.start();
    a.stop();
    bool saw = false;
    for (const auto& l : logs)
        if (l.find("registration failed") != std::string::npos &&
            l.find("http_status=404") != std::string::npos)
            saw = true;
    EXPECT_TRUE(saw);
}

// GET resources 200 without our id is a list no-op, not registration success.
static void test_http_200_without_self_is_noop() {
    std::mutex logMu;
    std::vector<std::string> logs;
    PlexTvDeviceAnnouncer a(
        [&](const PlexTvHttpRequest&, std::string* body) {
            if (body)
                *body = R"([{"clientIdentifier":"someone-else","provides":"server"}])";
            return 200;
        },
        /*async=*/false);
    a.setLog([&](const std::string& s) {
        std::lock_guard<std::mutex> lock(logMu);
        logs.push_back(s);
    });
    a.configure(sampleId(), "unit-test-token", /*enabled=*/true);
    a.start();
    a.stop();
    bool sawNoop = false;
    bool sawSuccess = false;
    for (const auto& l : logs) {
        if (l.find("registration no-op") != std::string::npos &&
            l.find("self_in_body=0") != std::string::npos &&
            l.find("clientIdentifier_not_in_resources_body") != std::string::npos)
            sawNoop = true;
        if (l.find("registration succeeded") != std::string::npos)
            sawSuccess = true;
    }
    EXPECT_TRUE(sawNoop);
    EXPECT_TRUE(!sawSuccess);
}

static void test_token_not_echoed_in_logs() {
    std::mutex logMu;
    std::vector<std::string> logs;
    const std::string secret = "super-secret-plex-token-value-xyz";
    PlexTvDeviceAnnouncer a(
        [&](const PlexTvHttpRequest&, std::string* body) {
            if (body)
                *body = R"([{"clientIdentifier":"misterplex-dev"}])";
            return 200;
        },
        /*async=*/false);
    a.setLog([&](const std::string& s) {
        std::lock_guard<std::mutex> lock(logMu);
        logs.push_back(s);
    });
    a.configure(sampleId(), secret, /*enabled=*/true);
    a.start();
    a.stop();
    for (const auto& l : logs)
        EXPECT_TRUE(l.find(secret) == std::string::npos);
}

int main() {
    test_id_empty_rejected();
    test_id_default_misterplex_1_banned();
    test_id_generic_slugs_banned();
    test_id_requires_misterplex_prefix();
    test_id_suffix_min_length();
    test_id_foreign_denylist();
    test_id_stable_across_restarts();
    test_id_distinct_from_pms_style();
    test_build_register_get_resources();
    test_build_rejects_empty_token();
    test_build_rejects_unsafe_id();
    test_body_mentions_client_json_and_xml();
    test_disabled_skips_http();
    test_missing_token_skips_http();
    test_unsafe_id_refuses_network();
    test_success_logs_startup();
    test_http_404_logs_failure();
    test_http_200_without_self_is_noop();
    test_token_not_echoed_in_logs();

    if (g_fails != 0) {
        std::cerr << "test_plextv_device: " << g_fails << " failure(s)\n";
        return 1;
    }
    std::cout << "test_plextv_device: OK\n";
    return 0;
}
