// RED-before-GREEN: silent foreign-root conf/ffmpeg fallback must be impossible.
//
// Against the OLD policy (legacyDefaultConfPathIgnoringExe), a daemon running from
// …/misterplex_v2/bin always "defaults" to /media/fat/misterplex/misterplex.conf
// (DECODE=320x240 class) when the v2 conf is missing — daily-driver trap parent
// confirmed in retained logs (1x DECODE adopted from v1 conf).
//
// GREEN policy (resolveConfPath): missing install conf → fail, never foreign root.
// Host-only; temp roots under .agent-work; no device; conf never modified on box.

#include "libmisterplex/install_paths.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

int g_fails = 0;

void expect(bool cond, const char* msg) {
    if (!cond) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        ++g_fails;
    } else {
        std::fprintf(stderr, "ok: %s\n", msg);
    }
}

std::string mktempdir() {
    const char* base =
        "/home/flynnsbit/Projects/MisterPlex/.worktrees/w-480-delivery/.agent-work/"
        "w-480-delivery";
    ::mkdir("/home/flynnsbit/Projects/MisterPlex/.worktrees/w-480-delivery/.agent-work",
            0755);
    ::mkdir(base, 0755);
    std::string tmpl = std::string(base) + "/ipathsXXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    char* p = ::mkdtemp(buf.data());
    if (!p)
        return {};
    return std::string(p);
}

void write_file(const std::string& path, const std::string& body) {
    std::ofstream o(path.c_str(), std::ios::binary | std::ios::trunc);
    o << body;
}

struct FakeFs {
    std::vector<std::string> present;
    bool operator()(const std::string& p) const {
        for (const auto& x : present) {
            if (x == p)
                return true;
        }
        return false;
    }
};

void rm_rf_best_effort(const std::string& dir) {
    ::unlink((dir + "/misterplex.conf").c_str());
    ::unlink((dir + "/bin/ffmpeg").c_str());
    ::rmdir((dir + "/bin").c_str());
    ::rmdir(dir.c_str());
}

} // namespace

int main() {
    using misterplex::ConfPathSource;
    using misterplex::FfmpegPathSource;
    using misterplex::installRootFromExePath;
    using misterplex::kLegacyDefaultConfPath;
    using misterplex::kLegacyDefaultFfmpegPath;
    using misterplex::legacyDefaultConfPathIgnoringExe;
    using misterplex::legacyDefaultFfmpegPathIgnoringExe;
    using misterplex::resolveConfPath;
    using misterplex::resolveFfmpegPath;

    // --- RED baseline: old policy always returns v1 paths, independent of exe ---
    {
        const std::string old =
            legacyDefaultConfPathIgnoringExe("/media/fat/misterplex_v2/bin/misterplexd");
        expect(old == kLegacyDefaultConfPath,
               "RED baseline: legacyDefaultConfPathIgnoringExe is always v1 conf");
        const std::string oldff =
            legacyDefaultFfmpegPathIgnoringExe("/media/fat/misterplex_v2/bin/misterplexd");
        expect(oldff == kLegacyDefaultFfmpegPath,
               "RED baseline: legacyDefaultFfmpegPathIgnoringExe is always v1 ffmpeg");
    }

    // --- install_root from exe ---
    {
        expect(installRootFromExePath("/media/fat/misterplex_v2/bin/misterplexd") ==
                   "/media/fat/misterplex_v2",
               "installRootFromExePath strips /bin/misterplexd");
        expect(installRootFromExePath("/opt/mp/bin/misterplexd") == "/opt/mp",
               "installRootFromExePath works for non-fat paths");
    }

    // --- GREEN: missing install conf must FAIL, not adopt v1 ---
    {
        FakeFs fs;
        const auto plan = resolveConfPath("/media/fat/misterplex_v2", "", false, fs);
        expect(!plan.ok, "missing v2 conf → resolveConfPath fails");
        expect(plan.exit_code == 12, "missing install conf exit_code==12");
        expect(plan.source == ConfPathSource::Missing, "source=Missing");
        expect(plan.conf_path == "/media/fat/misterplex_v2/misterplex.conf",
               "fail reports expected install conf path (not foreign success path)");
        expect(plan.conf_path != std::string(kLegacyDefaultConfPath),
               "must not return kLegacyDefaultConfPath as the adopted conf");
    }

    // --- GREEN: present install conf is adopted ---
    {
        FakeFs fs;
        fs.present.push_back("/media/fat/misterplex_v2/misterplex.conf");
        const auto plan = resolveConfPath("/media/fat/misterplex_v2", "", false, fs);
        expect(plan.ok, "install conf present → ok");
        expect(plan.conf_path == "/media/fat/misterplex_v2/misterplex.conf",
               "install conf path is $root/misterplex.conf");
        expect(plan.source == ConfPathSource::InstallRoot, "source=InstallRoot");
    }

    // --- GREEN: foreign --conf is ERROR unless allow_foreign ---
    {
        FakeFs fs;
        fs.present.push_back("/media/fat/misterplex/misterplex.conf");
        const auto denied = resolveConfPath(
            "/media/fat/misterplex_v2", "/media/fat/misterplex/misterplex.conf", false, fs);
        expect(!denied.ok, "foreign --conf denied by default");
        expect(denied.exit_code == 12, "foreign conf exit_code==12");
        expect(denied.source == ConfPathSource::ForeignCli, "source=ForeignCli");

        const auto allowed = resolveConfPath(
            "/media/fat/misterplex_v2", "/media/fat/misterplex/misterplex.conf", true, fs);
        expect(allowed.ok, "foreign --conf allowed with allow_foreign");
        expect(allowed.source == ConfPathSource::Cli, "allowed foreign still source=Cli");
        expect(allowed.detail.find("foreign=1") != std::string::npos,
               "allowed foreign logs foreign=1 in detail");
    }

    // --- GREEN: same-root --conf ok ---
    {
        FakeFs fs;
        fs.present.push_back("/media/fat/misterplex_v2/custom.conf");
        const auto plan = resolveConfPath(
            "/media/fat/misterplex_v2", "/media/fat/misterplex_v2/custom.conf", false, fs);
        expect(plan.ok && plan.source == ConfPathSource::Cli,
               "same-root --conf is ok (source=Cli)");
    }

    // --- GREEN: ffmpeg never probes foreign root ---
    {
        FakeFs fs;
        fs.present.push_back("/media/fat/misterplex/bin/ffmpeg");
        const auto plan = resolveFfmpegPath("/media/fat/misterplex_v2", "", "", true, fs);
        expect(!plan.ok, "missing install ffmpeg fails even if v1 ffmpeg exists");
        expect(plan.exit_code == 13, "missing install ffmpeg exit_code==13");
        expect(plan.source == FfmpegPathSource::Missing, "ffmpeg source=Missing");
    }
    {
        FakeFs fs;
        fs.present.push_back("/media/fat/misterplex_v2/bin/ffmpeg");
        const auto plan = resolveFfmpegPath("/media/fat/misterplex_v2", "", "", true, fs);
        expect(plan.ok, "install ffmpeg present → ok");
        expect(plan.ffmpeg_path == "/media/fat/misterplex_v2/bin/ffmpeg",
               "ffmpeg is $install_root/bin/ffmpeg");
        expect(plan.source == FfmpegPathSource::InstallRootBin,
               "ffmpeg source=InstallRootBin");
    }
    {
        FakeFs fs;
        fs.present.push_back("/opt/custom/ffmpeg");
        const auto plan = resolveFfmpegPath(
            "/media/fat/misterplex_v2", "/opt/custom/ffmpeg", "", true, fs);
        expect(plan.ok && plan.source == FfmpegPathSource::Cli, "--ffmpeg wins");
    }
    {
        FakeFs fs;
        fs.present.push_back("/opt/conf-ff");
        const auto plan =
            resolveFfmpegPath("/media/fat/misterplex_v2", "", "/opt/conf-ff", true, fs);
        expect(plan.ok && plan.source == FfmpegPathSource::ConfKey,
               "conf FFMPEG= wins over install");
    }

    // --- Disk integration: temp roots (real access) ---
    {
        const std::string v2 = mktempdir();
        const std::string v1 = mktempdir();
        expect(!v2.empty() && !v1.empty(), "mkdtemp under .agent-work");
        if (!v2.empty() && !v1.empty()) {
            ::mkdir((v2 + "/bin").c_str(), 0755);
            ::mkdir((v1 + "/bin").c_str(), 0755);
            write_file(v1 + "/misterplex.conf", "DECODE=320x240\n");
            write_file(v1 + "/bin/ffmpeg", "#!/bin/true\n");
            ::chmod((v1 + "/bin/ffmpeg").c_str(), 0755);

            auto readable = [](const std::string& p) {
                return ::access(p.c_str(), R_OK) == 0;
            };
            auto execable = [](const std::string& p) {
                return ::access(p.c_str(), X_OK) == 0;
            };

            const auto confPlan = resolveConfPath(v2, "", false, readable);
            expect(!confPlan.ok,
                   "disk: v2 conf missing while v1 conf exists → FAIL (not adopt 320x240)");
            expect(confPlan.conf_path != (v1 + "/misterplex.conf"),
                   "disk: must not return v1 conf path");
            expect(legacyDefaultConfPathIgnoringExe(v2 + "/bin/misterplexd") ==
                       kLegacyDefaultConfPath,
                   "disk RED contrast: legacy helper still hardcodes v1");

            write_file(v2 + "/misterplex.conf", "DECODE=624x480\n");
            const auto confOk = resolveConfPath(v2, "", false, readable);
            expect(confOk.ok && confOk.conf_path == v2 + "/misterplex.conf",
                   "disk: v2 conf present → adopt v2");

            const auto ffFail = resolveFfmpegPath(v2, "", "", true, execable);
            expect(!ffFail.ok, "disk: only v1 ffmpeg → fail for v2 root");
            write_file(v2 + "/bin/ffmpeg", "#!/bin/true\n");
            ::chmod((v2 + "/bin/ffmpeg").c_str(), 0755);
            const auto ffOk = resolveFfmpegPath(v2, "", "", true, execable);
            expect(ffOk.ok && ffOk.ffmpeg_path == v2 + "/bin/ffmpeg",
                   "disk: v2 ffmpeg present → adopt v2 bin");

            rm_rf_best_effort(v2);
            rm_rf_best_effort(v1);
        }
    }

    if (g_fails) {
        std::fprintf(stderr, "test_install_paths: %d failure(s)\n", g_fails);
        return 1;
    }
    std::fprintf(stderr, "test_install_paths: ALL ok\n");
    return 0;
}
