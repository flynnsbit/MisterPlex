// Principled LINK_CAP_KBIT derivation and anti-oscillation policy.
//
// Does NOT invent a product default bitrate. Consumes measured 1 s window
// goodput samples (B/s) from a fixture ladder / greedy pull and produces a
// conf-ready kbit/s integer. Adaptive raise/lower requires multi-window
// hysteresis — required on unstable WiFi (parent: RTT 2.9–227 ms, intermittent
// "No route to host").
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace misterplex {

struct LinkCapRecommendation {
    int linkCapKbit = 0;          // 0 = refuse to recommend (NO-DATA)
    const char* statistic = "none";
    bool provisional = true;      // true if n < minWindows or single session
    int nWindows = 0;
    int64_t minBps = 0;
    int64_t p10Bps = 0;
    int64_t medianBps = 0;
    int64_t p95Bps = 0;
    std::string detail;
};

// Percentile on a sorted non-empty vector (rank = ceil(p * n) - 1 style).
inline int64_t sortedPercentile(const std::vector<int64_t>& sorted, double p) {
    if (sorted.empty())
        return 0;
    if (p <= 0.0)
        return sorted.front();
    if (p >= 1.0)
        return sorted.back();
    const double idx = p * static_cast<double>(sorted.size() - 1);
    const size_t lo = static_cast<size_t>(idx);
    const size_t hi = std::min(lo + 1, sorted.size() - 1);
    const double frac = idx - static_cast<double>(lo);
    return static_cast<int64_t>(std::llround(
        (1.0 - frac) * static_cast<double>(sorted[lo]) + frac * static_cast<double>(sorted[hi])));
}

// Convert B/s → kbit/s with headroom factor in (0,1]. Floor at 1 if positive.
inline int bpsToLinkCapKbit(int64_t bps, double headroom) {
    if (bps <= 0 || !(headroom > 0.0))
        return 0;
    if (headroom > 1.0)
        headroom = 1.0;
    const double kbit = (static_cast<double>(bps) * 8.0 / 1000.0) * headroom;
    if (kbit < 1.0)
        return 0;
    return static_cast<int>(std::llround(kbit));
}

// Principled statistic choice (answers parent open questions):
// - p95 alone is NOT entitled on unstable WiFi when min << p95 (parent min
//   45.7 KB/s vs p95 161.4 KB/s). A single 60 s observation is provisional.
// - Use max(min,1) floor path: recommend from p10 with headroom, never above
//   median*headroom, and never above p95 (sanity).
// - minWindows default 30 of 1 s windows (~30 s). Below that → provisional.
// - headroom default 0.85 leaves ~15% for audio + TCP overhead + jitter.
inline LinkCapRecommendation recommendLinkCapFromWindowBps(
    std::vector<int64_t> windowBps, double headroom = 0.85, int minWindows = 30) {
    LinkCapRecommendation r;
    // Drop non-positive windows (NO-DATA / idle gaps) — empty after filter is NO-DATA.
    windowBps.erase(std::remove_if(windowBps.begin(), windowBps.end(),
                                   [](int64_t v) { return v <= 0; }),
                    windowBps.end());
    r.nWindows = static_cast<int>(windowBps.size());
    if (windowBps.empty()) {
        r.detail = "NO-DATA empty_or_nonpositive_windows";
        r.statistic = "none";
        return r;
    }
    std::sort(windowBps.begin(), windowBps.end());
    r.minBps = windowBps.front();
    r.p10Bps = sortedPercentile(windowBps, 0.10);
    r.medianBps = sortedPercentile(windowBps, 0.50);
    r.p95Bps = sortedPercentile(windowBps, 0.95);
    r.provisional = (r.nWindows < minWindows);

    // Conservative core: p10 * headroom, capped by median * headroom (don't
    // ride a thin left tail if distribution is weird), never use p95 as the
    // request target on unstable links.
    const int fromP10 = bpsToLinkCapKbit(r.p10Bps, headroom);
    const int fromMed = bpsToLinkCapKbit(r.medianBps, headroom);
    int cap = fromP10;
    if (fromMed > 0 && (cap <= 0 || cap > fromMed))
        cap = fromMed;
    // If p10 is far below median (unstable), prefer min*headroom as a floor check
    // but do not raise above p10 path — already conservative.
    const int fromMin = bpsToLinkCapKbit(r.minBps, headroom);
    if (fromMin > 0 && cap > 0 && r.minBps * 2 < r.p95Bps) {
        // High dispersion: pull toward min/p10 band (already at p10).
        r.statistic = "p10_headroom_unstable";
    } else {
        r.statistic = "p10_headroom";
    }
    r.linkCapKbit = cap;
    r.detail = "n=" + std::to_string(r.nWindows) + " min_Bps=" + std::to_string(r.minBps) +
               " p10_Bps=" + std::to_string(r.p10Bps) + " median_Bps=" +
               std::to_string(r.medianBps) + " p95_Bps=" + std::to_string(r.p95Bps) +
               " headroom=" + std::to_string(headroom) +
               " provisional=" + (r.provisional ? "1" : "0") +
               " — p95 is diagnostic only, not the request target";
    return r;
}

// Adaptive hysteresis: never oscillate on WiFi blips.
// - Lower only after `lowerNeed` consecutive "starved" proposals below current.
// - Raise only after `raiseNeed` consecutive "healthy" proposals above current
//   by at least `raiseMarginFrac` (default 15%).
// - `sessionSticky`: once lowered in a session, refuse raises until next process.
struct LinkCapHysteresisState {
    int currentKbit = 0; // 0 = uninitialized
    int lowerStreak = 0;
    int raiseStreak = 0;
    bool loweredThisSession = false;
};

struct LinkCapHysteresisDecision {
    int nextKbit = 0;
    const char* action = "hold"; // hold | lower | raise | init
    bool changed = false;
};

inline LinkCapHysteresisDecision stepLinkCapHysteresis(LinkCapHysteresisState& st,
                                                       int proposedKbit,
                                                       bool supplyStarved,
                                                       bool supplyHealthy,
                                                       int lowerNeed = 3,
                                                       int raiseNeed = 10,
                                                       double raiseMarginFrac = 0.15,
                                                       bool sessionSticky = true) {
    LinkCapHysteresisDecision d;
    if (proposedKbit <= 0) {
        d.nextKbit = st.currentKbit;
        d.action = "hold";
        return d;
    }
    if (st.currentKbit <= 0) {
        st.currentKbit = proposedKbit;
        d.nextKbit = proposedKbit;
        d.action = "init";
        d.changed = true;
        return d;
    }
    d.nextKbit = st.currentKbit;

    if (supplyStarved && proposedKbit < st.currentKbit) {
        st.lowerStreak++;
        st.raiseStreak = 0;
        if (st.lowerStreak >= lowerNeed) {
            st.currentKbit = proposedKbit;
            st.lowerStreak = 0;
            st.loweredThisSession = true;
            d.nextKbit = proposedKbit;
            d.action = "lower";
            d.changed = true;
        }
        return d;
    }

    if (supplyHealthy && proposedKbit > st.currentKbit) {
        st.raiseStreak++;
        st.lowerStreak = 0;
        const double need = static_cast<double>(st.currentKbit) * (1.0 + raiseMarginFrac);
        if (sessionSticky && st.loweredThisSession) {
            d.action = "hold"; // no raise same session after a lower
            return d;
        }
        if (st.raiseStreak >= raiseNeed && static_cast<double>(proposedKbit) >= need) {
            st.currentKbit = proposedKbit;
            st.raiseStreak = 0;
            d.nextKbit = proposedKbit;
            d.action = "raise";
            d.changed = true;
        }
        return d;
    }

    // Mixed / neutral window — decay streaks slowly.
    st.lowerStreak = 0;
    st.raiseStreak = 0;
    d.action = "hold";
    return d;
}

// Effective bits/pixel diagnostic from *delivered* geometry (not request).
// PMS treats videoResolution as a ceiling — parent measured 624x350 vs 624x480.
// Returns 0 if inputs invalid. kbps is the *requested* maxVideoBitrate for scale.
inline double requestedBitsPerDeliveredPixel(int maxVideoBitrateKbps, int deliveredW,
                                             int deliveredH, double fps) {
    if (maxVideoBitrateKbps <= 0 || deliveredW <= 0 || deliveredH <= 0 || !(fps > 0.0))
        return 0.0;
    const double pixels = static_cast<double>(deliveredW) * static_cast<double>(deliveredH) * fps;
    if (!(pixels > 0.0))
        return 0.0;
    return (static_cast<double>(maxVideoBitrateKbps) * 1000.0) / pixels;
}

} // namespace misterplex
