// Install-root path policy for misterplexd conf + ffmpeg.
//
// Parent 2026-08-01: compiled-in defaults pointed at /media/fat/misterplex/ even
// when the live binary was /media/fat/misterplex_v2/bin/misterplexd. If the v2
// conf was missing, the daemon silently adopted v1 DECODE=320x240 + v1 ffmpeg —
// a silent quarter-resolution regression on the daily driver.
//
// Policy (product):
//   install_root = parent of bin/ when exe is $ROOT/bin/misterplexd
//   conf:  --conf if set (must be readable; must live under install_root unless
//          allow_foreign_conf); else $ROOT/misterplex.conf (must be readable).
//          NEVER fall back to a hardcoded foreign root.
//   ffmpeg: --ffmpeg if set; else conf FFMPEG= if set; else $ROOT/bin/ffmpeg
//          if X_OK; else missing (loud). NEVER probe the other install root.
//
// Pure header — unit-tested with injectable existence predicates (temp roots).
#pragma once

#include <string>

namespace misterplex {

// $ROOT/bin/misterplexd → $ROOT; $ROOT/misterplexd → $ROOT; bare name → "".
inline std::string installRootFromExePath(const std::string& exePath) {
    if (exePath.empty())
        return {};
    std::string p = exePath;
    // Drop trailing slashes.
    while (p.size() > 1 && p.back() == '/')
        p.pop_back();
    const auto slash = p.find_last_of('/');
    if (slash == std::string::npos)
        return {};
    std::string dir = p.substr(0, slash); // .../bin or $ROOT
    if (dir.empty())
        return "/";
    const auto bslash = dir.find_last_of('/');
    const std::string base = (bslash == std::string::npos) ? dir : dir.substr(bslash + 1);
    if (base == "bin") {
        if (bslash == std::string::npos)
            return ".";
        if (bslash == 0)
            return "/";
        return dir.substr(0, bslash);
    }
    return dir;
}

// Conf file path → install root (dirname of conf).
inline std::string installRootFromConfPath(const std::string& confPath) {
    if (confPath.empty())
        return {};
    std::string p = confPath;
    while (p.size() > 1 && p.back() == '/')
        p.pop_back();
    const auto slash = p.find_last_of('/');
    if (slash == std::string::npos)
        return ".";
    if (slash == 0)
        return "/";
    return p.substr(0, slash);
}

// Normalize for root equality (no trailing slash; empty stays empty).
inline std::string normalizeInstallRoot(std::string r) {
    while (r.size() > 1 && r.back() == '/')
        r.pop_back();
    return r;
}

inline bool installRootsEqual(const std::string& a, const std::string& b) {
    return normalizeInstallRoot(a) == normalizeInstallRoot(b);
}

enum class ConfPathSource {
    Cli,
    InstallRoot,
    Missing,
    ForeignCli,
    UnreadableCli,
    NoInstallRoot,
};

inline const char* confPathSourceName(ConfPathSource s) {
    switch (s) {
    case ConfPathSource::Cli:
        return "cli";
    case ConfPathSource::InstallRoot:
        return "install_root";
    case ConfPathSource::Missing:
        return "missing_install_conf";
    case ConfPathSource::ForeignCli:
        return "foreign_cli_conf";
    case ConfPathSource::UnreadableCli:
        return "unreadable_cli_conf";
    case ConfPathSource::NoInstallRoot:
        return "no_install_root";
    }
    return "unknown";
}

struct ConfPathPlan {
    bool ok = false;
    int exit_code = 0; // 0 ok; 12 policy refuse (foreign/missing)
    std::string conf_path;
    std::string install_root;
    ConfPathSource source = ConfPathSource::Missing;
    std::string detail; // greppable machine token + human fragment
};

// readable(path) → true if conf can be opened for read.
// allow_foreign_conf: lab escape when --conf intentionally points outside install_root.
template <typename ReadableFn>
ConfPathPlan resolveConfPath(const std::string& installRoot, const std::string& cliConf,
                             bool allow_foreign_conf, ReadableFn readable) {
    ConfPathPlan plan;
    plan.install_root = normalizeInstallRoot(installRoot);
    if (plan.install_root.empty()) {
        plan.ok = false;
        plan.exit_code = 12;
        plan.source = ConfPathSource::NoInstallRoot;
        plan.detail = "CONF_RESOLVE_FAIL reason=no_install_root "
                      "(cannot derive $ROOT from exe; pass --conf under install root)";
        return plan;
    }

    if (!cliConf.empty()) {
        if (!readable(cliConf)) {
            plan.ok = false;
            plan.exit_code = 12;
            plan.source = ConfPathSource::UnreadableCli;
            plan.conf_path = cliConf;
            plan.detail = "CONF_RESOLVE_FAIL reason=unreadable_cli_conf path=" + cliConf;
            return plan;
        }
        const std::string confRoot = normalizeInstallRoot(installRootFromConfPath(cliConf));
        if (!installRootsEqual(confRoot, plan.install_root) && !allow_foreign_conf) {
            plan.ok = false;
            plan.exit_code = 12;
            plan.source = ConfPathSource::ForeignCli;
            plan.conf_path = cliConf;
            plan.detail =
                "CONF_RESOLVE_FAIL reason=foreign_cli_conf path=" + cliConf +
                " conf_root=" + confRoot + " install_root=" + plan.install_root +
                " — refusing silent cross-root conf (DECODE/ffmpeg pair break). "
                "Lab escape: MISTERPLEX_ALLOW_FOREIGN_CONF=1";
            return plan;
        }
        plan.ok = true;
        plan.conf_path = cliConf;
        plan.source = ConfPathSource::Cli;
        plan.detail = std::string("CONF_RESOLVE_OK source=cli path=") + cliConf +
                      (allow_foreign_conf && !installRootsEqual(confRoot, plan.install_root)
                           ? " foreign=1"
                           : " foreign=0");
        return plan;
    }

    const std::string candidate = plan.install_root + "/misterplex.conf";
    if (readable(candidate)) {
        plan.ok = true;
        plan.conf_path = candidate;
        plan.source = ConfPathSource::InstallRoot;
        plan.detail = "CONF_RESOLVE_OK source=install_root path=" + candidate;
        return plan;
    }

    // HARD REFUSE — do not fall back to /media/fat/misterplex/misterplex.conf.
    plan.ok = false;
    plan.exit_code = 12;
    plan.source = ConfPathSource::Missing;
    plan.conf_path = candidate;
    plan.detail =
        "CONF_RESOLVE_FAIL reason=missing_install_conf expected=" + candidate +
        " install_root=" + plan.install_root +
        " — refusing silent fallback to a foreign root (would adopt alien DECODE/ffmpeg)";
    return plan;
}

enum class FfmpegPathSource {
    Cli,
    ConfKey,
    InstallRootBin,
    Missing,
};

inline const char* ffmpegPathSourceName(FfmpegPathSource s) {
    switch (s) {
    case FfmpegPathSource::Cli:
        return "cli";
    case FfmpegPathSource::ConfKey:
        return "conf_FFMPEG";
    case FfmpegPathSource::InstallRootBin:
        return "install_root_bin";
    case FfmpegPathSource::Missing:
        return "missing";
    }
    return "unknown";
}

struct FfmpegPathPlan {
    bool ok = false;
    int exit_code = 0; // 0 ok; 13 missing ffmpeg beside install
    std::string ffmpeg_path;
    FfmpegPathSource source = FfmpegPathSource::Missing;
    std::string detail;
};

// executable(path) → true if X_OK (or test stand-in).
// cliFfmpeg: from --ffmpeg (empty if unset).
// confFfmpeg: from conf FFMPEG= after conf is loaded (empty if unset).
// require_executable: if true, missing/non-exec → fail (startup gate).
template <typename ExecFn>
FfmpegPathPlan resolveFfmpegPath(const std::string& installRoot, const std::string& cliFfmpeg,
                                 const std::string& confFfmpeg, bool require_executable,
                                 ExecFn executable) {
    FfmpegPathPlan plan;
    const std::string root = normalizeInstallRoot(installRoot);

    auto accept = [&](const std::string& path, FfmpegPathSource src) -> FfmpegPathPlan {
        FfmpegPathPlan p;
        p.ffmpeg_path = path;
        p.source = src;
        if (path.empty()) {
            p.ok = false;
            p.exit_code = 13;
            p.detail = "FFMPEG_RESOLVE_FAIL reason=empty source=" +
                       std::string(ffmpegPathSourceName(src));
            return p;
        }
        if (require_executable && !executable(path)) {
            p.ok = false;
            p.exit_code = 13;
            p.detail = "FFMPEG_RESOLVE_FAIL reason=not_executable path=" + path +
                       " source=" + ffmpegPathSourceName(src);
            return p;
        }
        p.ok = true;
        p.detail = std::string("FFMPEG_RESOLVE_OK source=") + ffmpegPathSourceName(src) +
                   " path=" + path;
        return p;
    };

    if (!cliFfmpeg.empty())
        return accept(cliFfmpeg, FfmpegPathSource::Cli);
    if (!confFfmpeg.empty())
        return accept(confFfmpeg, FfmpegPathSource::ConfKey);

    if (!root.empty()) {
        const std::string beside = root + "/bin/ffmpeg";
        if (executable(beside))
            return accept(beside, FfmpegPathSource::InstallRootBin);
        if (require_executable) {
            plan.ok = false;
            plan.exit_code = 13;
            plan.source = FfmpegPathSource::Missing;
            plan.ffmpeg_path = beside;
            plan.detail =
                "FFMPEG_RESOLVE_FAIL reason=missing_install_ffmpeg expected=" + beside +
                " — refusing probe of foreign /media/fat/misterplex/bin/ffmpeg";
            return plan;
        }
        // Soft: return expected path for logging; play will fail later.
        plan.ok = true;
        plan.ffmpeg_path = beside;
        plan.source = FfmpegPathSource::InstallRootBin;
        plan.detail = "FFMPEG_RESOLVE_SOFT path=" + beside + " x_ok=0";
        return plan;
    }

    plan.ok = false;
    plan.exit_code = 13;
    plan.source = FfmpegPathSource::Missing;
    plan.detail = "FFMPEG_RESOLVE_FAIL reason=no_install_root";
    return plan;
}

// Legacy compiled-in defaults (DOCUMENTATION + red-team only — not used by product resolve).
inline constexpr const char* kLegacyDefaultConfPath = "/media/fat/misterplex/misterplex.conf";
inline constexpr const char* kLegacyDefaultFfmpegPath = "/media/fat/misterplex/bin/ffmpeg";
inline constexpr const char* kLegacyDefaultFfmpegPathV2 = "/media/fat/misterplex_v2/bin/ffmpeg";

// OLD behavior (pre-fix): default conf/ffmpeg are always the v1 hardcoded paths,
// even when exe lives under misterplex_v2. Used only by red-before-green unit tests.
inline std::string legacyDefaultConfPathIgnoringExe(const std::string& /*exePath*/) {
    return kLegacyDefaultConfPath;
}

inline std::string legacyDefaultFfmpegPathIgnoringExe(const std::string& /*exePath*/) {
    return kLegacyDefaultFfmpegPath;
}

} // namespace misterplex
