// Stream supply ratio: audio content time advanced vs wall time advanced.
//
// WHY (parent RCA, 480p "frames dropped"):
//   Link capacity 1.56 Mbit/s vs PMS floor 2000 kbit/s → stream arrives <½ RT.
//   Daemon still printed clock=av-lock av_drift_ms=… desync_risk=0. The only
//   number that separated healthy from broken was:
//     starved:  audio_s/wall_s = 33.42/72.58 = 0.460
//     healthy:  audio_s/wall_s = 69.94/70.43 = 0.993
//   Those are CUMULATIVE. Product must emit an INTERVAL ratio (Δaudio/Δwall)
//   so a late recovery is not masked by a good start (vfps cumulative lesson).
//
// DERIVATION OF INPUTS (must stay honest — quote media_player.cpp):
//   audio_s = audioBytes_ / (48000 * 4)
//     audioBytes_ increments ONLY on MrAudio ::write of PCM (S16_LE stereo)
//     after the start gate opens (hold path does not count held bytes).
//     NOT a servo setpoint. NOT pinned to wall by construction of the counter
//     itself. The pump *paces* writes to ~48 kHz wall so under full supply
//     audio_s tracks wall; under starved ffmpeg input, fewer bytes arrive and
//     audio_s lags wall. That lag is the signal.
//   wall_s  = (steady_now - t0).count() seconds, t0 armed at first complete
//     video frame (A/V audio_release). Session-relative, not process uptime.
//
// NOT A/V LIPSYNC. This is content-supply vs wall. Orthogonal to
// av_drift_ms (servo deadband / AV_PRESENT_LEAD_MS readout) and to
// desync_risk (raw pipe geometry identity_skip mismatch).
//
// Rule 0: missing/not-established → NO-DATA, never 0.0.
// Every emitted field tagged measured | caller_supplied | DEFAULT_ASSUMED | NO-DATA.
#pragma once

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

namespace misterplex {

// Parent lab anchors (caller will treat these as measured fixtures in the unit):
//   starved_ratio = 33.42/72.58 ≈ 0.4603
//   healthy_ratio = 69.94/70.43 ≈ 0.9930
//
// Default ok_min = 0.90:
//   - Healthy control sits at ~0.993 (≈0.7% deficit — pacing/quantisation).
//   - Starved case sits at ~0.46 (54% deficit — unmistakable).
//   - 0.90 means >10% content deficit per wall second. After 60 s wall that is
//     ≥6 s of missing content — user-visible under-production / drops.
//   - Chosen as the midpoint band edge between the two measured clusters, biased
//     toward not false-alarming brief jitter (0.95 would also work; 0.90 is the
//     more conservative "starved" call). Configurable — not sacred.
// tag on the default: DEFAULT_ASSUMED (conf/env may override → caller_supplied).
inline constexpr double kDefaultSupplyRatioOkMin = 0.90;

// Session wall must clear this before cumulative ratio is scoreable.
// Startup: t0 just armed, audio hold draining — cumulative is meaningless.
inline constexpr double kSupplyRatioMinWallS = 3.0;

// Interval Δwall must clear this (log period is ~1 s; allow scheduler slack).
inline constexpr double kSupplyRatioMinDWallS = 0.40;

enum class SupplyRatioClass {
    NoData = 0,
    Ok = 1,
    Starved = 2,
};

struct SupplyRatioResult {
    bool interval_established = false;
    bool cumulative_established = false;
    double d_audio_s = 0.0;
    double d_wall_s = 0.0;
    double interval_ratio = 0.0;    // only valid if interval_established
    double cumulative_ratio = 0.0;  // only valid if cumulative_established
    double audio_s = 0.0;
    double wall_s = 0.0;
    double ok_min = kDefaultSupplyRatioOkMin;
    const char* ok_min_src = "DEFAULT_ASSUMED";
    SupplyRatioClass cls = SupplyRatioClass::NoData;
    const char* class_str = "NO-DATA";
    const char* reason = "unset"; // startup|paused|audio_off|no_prev|d_wall_le0|ok|starved|…
};

inline const char* supplyRatioClassStr(SupplyRatioClass c) {
    switch (c) {
    case SupplyRatioClass::Ok:
        return "ok";
    case SupplyRatioClass::Starved:
        return "starved";
    case SupplyRatioClass::NoData:
    default:
        return "NO-DATA";
    }
}

// Pure classifier. prev_valid=false → interval NO-DATA (first sample).
// paused_in_window: if either endpoint was paused, refuse to score (NO-DATA).
// audio_active: MrAudio path live; if false, audio_s is not a supply proxy.
inline SupplyRatioResult computeSupplyRatio(bool prev_valid, double prev_audio_s,
                                            double prev_wall_s, double audio_s,
                                            double wall_s, bool audio_active,
                                            bool paused_in_window, double ok_min,
                                            const char* ok_min_src) {
    SupplyRatioResult r;
    r.audio_s = audio_s;
    r.wall_s = wall_s;
    r.ok_min = ok_min;
    r.ok_min_src = (ok_min_src && ok_min_src[0]) ? ok_min_src : "DEFAULT_ASSUMED";

    if (!audio_active) {
        r.reason = "audio_off";
        r.cls = SupplyRatioClass::NoData;
        r.class_str = supplyRatioClassStr(r.cls);
        return r;
    }
    if (paused_in_window) {
        r.reason = "paused";
        r.cls = SupplyRatioClass::NoData;
        r.class_str = supplyRatioClassStr(r.cls);
        return r;
    }
    if (!(wall_s > 0.0) || !std::isfinite(wall_s) || !std::isfinite(audio_s)) {
        r.reason = "wall_or_audio_invalid";
        r.cls = SupplyRatioClass::NoData;
        r.class_str = supplyRatioClassStr(r.cls);
        return r;
    }

    // Cumulative (explicitly labelled in formatter). Scoreable only after min wall.
    if (wall_s >= kSupplyRatioMinWallS && audio_s >= 0.0) {
        r.cumulative_established = true;
        r.cumulative_ratio = audio_s / wall_s;
    }

    if (!prev_valid) {
        r.reason = "no_prev";
        // Prefer cumulative class if established, else pure NO-DATA.
        if (r.cumulative_established) {
            // First tick after arm: interval not ready; do NOT classify from cum alone
            // on the media line's primary field — interval is the product metric.
            r.reason = "no_prev_interval";
        }
        r.cls = SupplyRatioClass::NoData;
        r.class_str = supplyRatioClassStr(r.cls);
        return r;
    }

    r.d_audio_s = audio_s - prev_audio_s;
    r.d_wall_s = wall_s - prev_wall_s;
    if (!(r.d_wall_s >= kSupplyRatioMinDWallS) || !std::isfinite(r.d_wall_s)) {
        r.reason = "d_wall_le0";
        r.cls = SupplyRatioClass::NoData;
        r.class_str = supplyRatioClassStr(r.cls);
        return r;
    }
    if (!(r.d_audio_s >= 0.0) || !std::isfinite(r.d_audio_s)) {
        // Negative Δaudio is a counter reset (seek/respawn) — not a ratio.
        r.reason = "d_audio_reset_or_invalid";
        r.cls = SupplyRatioClass::NoData;
        r.class_str = supplyRatioClassStr(r.cls);
        return r;
    }

    r.interval_established = true;
    r.interval_ratio = r.d_audio_s / r.d_wall_s;
    if (r.interval_ratio + 1e-15 < ok_min) {
        r.cls = SupplyRatioClass::Starved;
        r.reason = "starved";
    } else {
        r.cls = SupplyRatioClass::Ok;
        r.reason = "ok";
    }
    r.class_str = supplyRatioClassStr(r.cls);
    return r;
}

// Convenience overload with default threshold.
inline SupplyRatioResult computeSupplyRatio(bool prev_valid, double prev_audio_s,
                                            double prev_wall_s, double audio_s,
                                            double wall_s, bool audio_active,
                                            bool paused_in_window) {
    return computeSupplyRatio(prev_valid, prev_audio_s, prev_wall_s, audio_s, wall_s,
                              audio_active, paused_in_window, kDefaultSupplyRatioOkMin,
                              "DEFAULT_ASSUMED");
}

// Gate exit codes for host red-before-green and parent log scorers.
//   0 = ok (interval established and class=ok)
//   2 = starved (interval established and class=starved) — hard FAIL, never 77
//  77 = NO-DATA / not established — never a pass, never a defect verdict
inline int supplyRatioGateRc(const SupplyRatioResult& r) {
    if (!r.interval_established || r.cls == SupplyRatioClass::NoData)
        return 77;
    if (r.cls == SupplyRatioClass::Starved)
        return 2;
    return 0;
}

// Telemetry fragment for the media: line (no leading space required by caller).
inline std::string formatSupplyRatioFragment(const SupplyRatioResult& r) {
    char cum[32];
    if (r.cumulative_established)
        std::snprintf(cum, sizeof(cum), "%.3f", r.cumulative_ratio);
    else
        std::snprintf(cum, sizeof(cum), "NO-DATA");

    char buf[512];
    if (r.interval_established) {
        std::snprintf(buf, sizeof(buf),
                      "supply_ratio=%.3f src=d_audio_s/d_wall_s "
                      "supply_ratio_class=%s supply_ratio_reason=%s "
                      "d_audio_s=%.3f d_wall_s=%.3f "
                      "supply_ratio_ok_min=%.3f supply_ratio_ok_min_src=%s "
                      "supply_ratio_cum=%s supply_ratio_cum_src=audio_s/wall_s "
                      "supply_ratio_tag=measured",
                      r.interval_ratio, r.class_str, r.reason, r.d_audio_s, r.d_wall_s,
                      r.ok_min, r.ok_min_src, cum);
    } else {
        char da[32], dw[32];
        if (r.d_wall_s != 0.0 || r.d_audio_s != 0.0) {
            std::snprintf(da, sizeof(da), "%.3f", r.d_audio_s);
            std::snprintf(dw, sizeof(dw), "%.3f", r.d_wall_s);
        } else {
            std::snprintf(da, sizeof(da), "NO-DATA");
            std::snprintf(dw, sizeof(dw), "NO-DATA");
        }
        std::snprintf(buf, sizeof(buf),
                      "supply_ratio=NO-DATA src=d_audio_s/d_wall_s "
                      "supply_ratio_class=NO-DATA supply_ratio_reason=%s "
                      "d_audio_s=%s d_wall_s=%s "
                      "supply_ratio_ok_min=%.3f supply_ratio_ok_min_src=%s "
                      "supply_ratio_cum=%s supply_ratio_cum_src=audio_s/wall_s "
                      "supply_ratio_tag=NO-DATA",
                      r.reason, da, dw, r.ok_min, r.ok_min_src, cum);
    }
    return std::string(buf);
}

// clock_master replacement for the hardcoded clock=av-lock literal.
// audio path uses audibleClockMs(audioBytes, queued); else wall since t0.
inline const char* clockMasterLabel(bool audio_master) {
    return audio_master ? "audio" : "wall";
}

inline std::string formatClockMasterFragment(bool audio_master) {
    // NEVER emit clock=av-lock — that was a hardcoded literal with zero information.
    char buf[160];
    std::snprintf(buf, sizeof(buf),
                  "clock_master=%s clock_master_src=%s "
                  "clock_av_lock=REMOVED_was_hardcoded_literal",
                  clockMasterLabel(audio_master),
                  audio_master ? "audibleClockMs_audioBytes_minus_queued"
                               : "steady_since_t0_first_video");
    return std::string(buf);
}

// desync_risk is PIPE geometry, not A/V. Keep the field greppable; pin the scope.
inline std::string formatDesyncRiskFragment(bool risk) {
    char buf[200];
    std::snprintf(buf, sizeof(buf),
                  "desync_risk=%d desync_risk_der=pipeDesyncRisk_identity_skip_and_"
                  "producer_bytes_ne_reader "
                  "desync_risk_scope=raw_pipe_geometry_NOT_av_supply",
                  risk ? 1 : 0);
    return std::string(buf);
}

} // namespace misterplex
